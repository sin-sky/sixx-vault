// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISIXXVault} from "../interfaces/ISIXXVault.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IStrategyAdapter} from "../interfaces/IStrategyAdapter.sol";
import {IAdapterRegistry} from "../interfaces/IAdapterRegistry.sol";
import {ITimelockMinDelay} from "../interfaces/ITimelockMinDelay.sol";

/// @dev M-03 (3rd review): the binding getters every SIXX adapter exposes, used by
///      setAdapter to verify an incoming adapter points back at THIS vault and shares the
///      vault's governance before it is activated. Kept separate from IStrategyAdapter so
///      the check can be best-effort for governance() (test mocks may omit it).
interface IAdapterBindings {
    function vault() external view returns (address);
    function governance() external view returns (address);
}

/// @title SIXXVault
/// @notice ERC-4626 compliant tokenized vault with pluggable yield strategy adapters.
///         Supports lock periods, management fees, emergency shutdown, and 2-step governance.
/// @dev Deployed per asset (e.g. one vault for USDC, one for WETH).
///      Strategy can be swapped by governance without changing the vault address.
contract SIXXVault is ERC4626, ReentrancyGuard, ISIXXVault {
    using SafeERC20 for IERC20;

    // =========================================
    // Constants
    // =========================================

    uint256 private constant MAX_BPS = 10_000;
    /// @dev ~365.25 days in seconds
    uint256 private constant SECS_PER_YEAR = 365 days + 6 hours;
    uint256 private constant MAX_MANAGEMENT_FEE = 500;    // 5% hard cap
    /// @dev ADR-007 #2: window over which harvested profit unlocks linearly (JIT defense).
    uint256 private constant PROFIT_UNLOCK_PERIOD = 8 hours;

    // =========================================
    // State Variables
    // =========================================

    address public override governance;
    address public override pendingGovernance;
    address public override activeAdapter;
    address public override adapterRegistry;
    address public override guardian;

    uint256 public override lockPeriod;
    uint256 public override performanceFee;
    uint256 public override managementFee;
    address public override feeRecipient;
    bool public override emergencyShutdown;

    /// @dev M-03: set true when a force-detach (setAdapter(address(0))) realizes a
    ///      writeoff (recalled < marked NAV). While true, deposits are blocked so nobody
    ///      can mint against an impaired pool before governance has assessed the loss.
    ///      Cleared by attaching a healthy adapter (setAdapter(newAdapter)) or by the
    ///      explicit reopenDeposits().
    bool public override depositsPaused;

    /// @dev Amount of assets currently deployed to the active adapter
    uint256 private _totalDebt;
    /// @dev Timestamp of last fee collection
    uint256 private _lastHarvestTimestamp;

    /// @dev ADR-007 #2: profit locked at the last harvest, released linearly over
    ///      PROFIT_UNLOCK_PERIOD, and the timestamp of that harvest.
    uint256 private _lockedProfit;
    uint256 private _lastReport;

    /// @dev Maps user address to the unix timestamp they can next withdraw
    mapping(address => uint256) private _lockedUntil;

    // =========================================
    // Constructor
    // =========================================

    /// @param asset_           Underlying ERC-20 token (e.g. USDC)
    /// @param name_            Share token name (e.g. "SIXX Stable Yield")
    /// @param symbol_          Share token symbol (e.g. "sxUSDC")
    /// @param governance_      Initial governance address (SHIN EOA → Gnosis Safe later)
    /// @param adapterRegistry_ AdapterRegistry contract address (address(0) = permissionless for testing)
    /// @param feeRecipient_    Address receiving management/performance fees
    /// @param guardian_        Address allowed to trigger emergency shutdown immediately
    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address governance_,
        address adapterRegistry_,
        address feeRecipient_,
        address guardian_
    ) ERC4626(asset_) ERC20(name_, symbol_) {
        require(governance_ != address(0), "VAULT: zero governance");
        require(feeRecipient_ != address(0), "VAULT: zero fee recipient");
        require(guardian_ != address(0), "VAULT: zero guardian");
        governance = governance_;
        adapterRegistry = adapterRegistry_;
        feeRecipient = feeRecipient_;
        guardian = guardian_;
        _lastHarvestTimestamp = block.timestamp;
        _lastReport = block.timestamp;
    }

    // =========================================
    // Modifiers
    // =========================================

    modifier onlyGovernance() {
        require(msg.sender == governance, "VAULT: not governance");
        _;
    }

    // =========================================
    // ERC-4626: Public entry points (nonReentrant)
    // =========================================

    function deposit(uint256 assets, address receiver)
        public override(ERC4626, IERC4626) nonReentrant returns (uint256)
    {
        _collectFees(); // ADR-007 #3: crystallize before conversion
        uint256 shares = super.deposit(assets, receiver);
        // Part B P1 (RD5): reject a deposit that rounds to zero shares so assets are
        // never taken for nothing (OZ v5 ERC-4626 has no such guard). Self-inflicted
        // dust only, but made an explicit revert for cleanliness.
        require(shares > 0, "VAULT: zero shares");
        return shares;
    }

    function mint(uint256 shares, address receiver)
        public override(ERC4626, IERC4626) nonReentrant returns (uint256)
    {
        require(shares > 0, "VAULT: zero shares"); // Part B P1 (RD5): symmetric guard
        _collectFees();
        return super.mint(shares, receiver);
    }

    /// @dev ADR-007 (design c): exits are honest partial-fills clamped to the caller's pro-rata
    ///      of realizable liquidity. They NEVER revert on an adapter shortfall (柱1); each caller
    ///      is capped at its pro-rata share so no early exiter can monopolize idle/realizable
    ///      liquidity (柱3); only the shares matching the cash actually paid are burned, so any
    ///      unpaid remainder is retained as ordinary share = a durable pro-rata claim (柱4).
    ///      The return value is the ACTUAL payout (may be < previewWithdraw under impairment —
    ///      an upper estimate that never over-delivers is preferred to an ERC-4626-exact preview).
    function withdraw(uint256 assets, address receiver, address owner)
        public override(ERC4626, IERC4626) nonReentrant returns (uint256)
    {
        _collectFees();
        // ERC-4626 compliance: same custom error super.withdraw would raise (lock surfaces here
        //   because maxWithdraw returns 0 while locked, H-4).
        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) revert ERC4626ExceededMaxWithdraw(owner, assets, maxAssets);
        if (!emergencyShutdown) require(block.timestamp >= _lockedUntil[owner], "VAULT: still locked");
        uint256 shares = previewWithdraw(assets);
        (uint256 payout, uint256 sBurn) = _exitRealize(assets, shares);
        _completeExit(_msgSender(), receiver, owner, payout, sBurn);
        return payout;
    }

    function redeem(uint256 shares, address receiver, address owner)
        public override(ERC4626, IERC4626) nonReentrant returns (uint256)
    {
        _collectFees();
        uint256 maxShares = maxRedeem(owner);
        if (shares > maxShares) revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        if (!emergencyShutdown) require(block.timestamp >= _lockedUntil[owner], "VAULT: still locked");
        uint256 assets = convertToAssets(shares);
        (uint256 payout, uint256 sBurn) = _exitRealize(assets, shares);
        _completeExit(_msgSender(), receiver, owner, payout, sBurn);
        return payout;
    }

    // =========================================
    // ERC-4626: totalAssets
    // =========================================

    /// @notice Vault balance + assets deployed to adapter, minus still-locked profit.
    /// @dev ADR-007 #2: subtract the unreleased portion of the last harvest so a
    ///      just-in-time depositor cannot mint against yield that has not yet vested.
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        // H-02 (3rd review): totalAssets() MUST NOT revert. ERC-4626 withdraw/redeem
        //   conversion, previews, and _collectFees all read it — a reverting adapter
        //   valuation (broken oracle / not-ready TWAP) would otherwise brick every exit.
        //   On read failure, degrade to the last booked debt (_totalDebt) so reads stay
        //   live and users can always exit against whatever the adapter can realize; the
        //   honest partial-fill exit (_exitRealize) pays only what is actually recalled.
        uint256 adapterAssets;
        if (activeAdapter != address(0)) {
            try IStrategyAdapter(activeAdapter).totalAssets() returns (uint256 a) {
                adapterAssets = a;
            } catch {
                adapterAssets = _totalDebt;
            }
        }
        uint256 raw = IERC20(asset()).balanceOf(address(this)) + adapterAssets;
        uint256 lp = lockedProfit();
        return raw > lp ? raw - lp : 0;
    }

    /// @notice True unless the active adapter's valuation is currently unreadable (reverting).
    /// @dev C-1/D-1/E-1 guard (Round-8 v2): when `adapter.totalAssets()` reverts, `totalAssets()`
    ///      degrades to the loss-blind `_totalDebt`, which OVER-reports NAV after a realized loss.
    ///      Detection is a direct try/catch — it is `false` ONLY when the call actually reverts, so
    ///      it can never false-positive and degrade a healthy adapter. Used to (a) idle-only the
    ///      exit recall and (b) pause deposits, so no exit prices against, and no depositor mints
    ///      against, a stale overstated mark. Force-detach (writes `_totalDebt` to realized) clears it.
    function _adapterValuationReadable() internal view returns (bool) {
        address a = activeAdapter;
        if (a == address(0)) return true; // already detached: idle-only is the state, not a fault
        try IStrategyAdapter(a).totalAssets() returns (uint256) {
            return true;
        } catch {
            return false;
        }
    }

    /// @notice Amount of harvested profit still locked; degrades linearly to 0 over
    ///         PROFIT_UNLOCK_PERIOD after the last harvest.
    function lockedProfit() public view override returns (uint256) {
        uint256 elapsed = block.timestamp - _lastReport;
        if (elapsed >= PROFIT_UNLOCK_PERIOD) return 0;
        return (_lockedProfit * (PROFIT_UNLOCK_PERIOD - elapsed)) / PROFIT_UNLOCK_PERIOD;
    }

    /// @notice Realize adapter profit and lock it for linear release (permissionless).
    /// @dev ADR-007 #2 structural JIT defense. Any discrete gain the adapter recognizes
    ///      during harvest() is measured as a balance delta and added to the locked buffer,
    ///      which unlocks over PROFIT_UNLOCK_PERIOD. Continuous-accrual adapters harvest to a
    ///      no-op (delta 0), so this leaves their behaviour unchanged.
    function harvest() external override nonReentrant returns (uint256 profit) {
        address adapter_ = activeAdapter;
        if (adapter_ != address(0)) {
            uint256 beforeBal = IStrategyAdapter(adapter_).totalAssets();
            IStrategyAdapter(adapter_).harvest();
            uint256 afterBal = IStrategyAdapter(adapter_).totalAssets();
            if (afterBal > beforeBal) profit = afterBal - beforeBal;
        }
        // M-02: only carry-and-restart the unlock clock when new profit was actually
        //   realized. harvest() is permissionless; a zero-profit call must NOT reset
        //   _lastReport, or anyone could repeatedly re-extend the release tail of
        //   already-locked profit (suppressing totalAssets() to grief exiting holders).
        //   With profit == 0 the existing linear schedule is preserved untouched.
        if (profit > 0) {
            // Carry the still-locked remainder + the new profit; restart the unlock clock.
            _lockedProfit = lockedProfit() + profit;
            _lastReport = block.timestamp;
            emit ProfitLocked(profit, _lockedProfit);
        }
    }

    // =========================================
    // ERC-4626: maxDeposit / maxMint
    // =========================================

    function maxDeposit(address) public view override(ERC4626, IERC4626) returns (uint256) {
        // H-01: surface the post-force-detach deposit pause (impaired/unreadable NAV)
        //   through the ERC-4626 view, matching the `_deposit` revert, so previews and
        //   integrators see 0 capacity while paused.
        // C-1 guard: also pause while the adapter valuation is UNREADABLE — else a depositor
        //   would mint against the over-reported stale-`_totalDebt` NAV.
        if (emergencyShutdown || depositsPaused || !_adapterValuationReadable()) return 0;
        return type(uint256).max;
    }

    function maxMint(address) public view override(ERC4626, IERC4626) returns (uint256) {
        if (emergencyShutdown || depositsPaused || !_adapterValuationReadable()) return 0;
        return type(uint256).max;
    }

    /// @dev H-4: Surface the lock state through the ERC-4626 max* views so that
    ///      integrators and previews see 0 capacity while the owner is locked.
    ///      B: emergency shutdown waives the lock so users can exit immediately
    ///      (matches the "safe withdrawal by users" intent of shutdown).
    function maxWithdraw(address owner) public view override(ERC4626, IERC4626) returns (uint256) {
        if (!emergencyShutdown && _lockedUntil[owner] > block.timestamp) return 0;
        return super.maxWithdraw(owner);
    }

    function maxRedeem(address owner) public view override(ERC4626, IERC4626) returns (uint256) {
        if (!emergencyShutdown && _lockedUntil[owner] > block.timestamp) return 0;
        return super.maxRedeem(owner);
    }

    // =========================================
    // ERC-4626: Internal hooks
    // =========================================

    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        require(!emergencyShutdown, "VAULT: emergency shutdown");
        // M-03: refuse deposits while paused after a lossy force-detach (governance must
        //   reopen). Separately, block the specific hazard the finding describes — a deposit
        //   minting against a locked-profit-SUPPRESSED denominator: raw assets have fallen
        //   at/under the still-locked buffer, so totalAssets() clamps toward zero and a dust
        //   depositor could mint cheaply, then benefit as the buffer decays / assets recover.
        //   Only the locked-profit artifact is guarded (lp > 0); a plain zero-NAV from a
        //   fully-stuck adapter is the documented force-detach writeoff tradeoff, out of
        //   this finding's scope, and stays governed by the existing recovery model.
        require(!depositsPaused, "VAULT: deposits paused");
        uint256 lp = lockedProfit();
        if (lp > 0) {
            uint256 rawAssets = IERC20(asset()).balanceOf(address(this)) +
                (activeAdapter != address(0) ? IStrategyAdapter(activeAdapter).totalAssets() : 0);
            require(rawAssets > lp, "VAULT: assets impaired");
        }
        super._deposit(caller, receiver, assets, shares);

        // H-3: Only extend the receiver's lock when they deposit for themselves.
        //      Prevents a griefer from depositing on behalf of a victim to
        //      re-extend that victim's lock and freeze their funds.
        if (lockPeriod > 0 && caller == receiver) {
            uint256 newLock = block.timestamp + lockPeriod;
            if (newLock > _lockedUntil[receiver]) {
                _lockedUntil[receiver] = newLock;
            }
        }

        // Push idle assets to adapter
        _deployToAdapter();
    }

    /// @dev ADR-007 (design c) exit core. Recall the caller's PRO-RATA slice of the adapter
    ///      honestly (best-effort, NEVER revert), pay pro-rata idle + what was realized, and
    ///      compute the shares to burn from the cash actually paid.
    /// @param requestedAssets the caller's mark-based claim (redeem) or requested amount (withdraw)
    /// @param shares          the shares the caller offered to burn (upper bound on sBurn)
    /// @return payout the cash actually delivered (<= requestedAssets); may be a partial fill
    /// @return sBurn  shares to burn == convertToShares(payout), capped at `shares` (residual kept)
    function _exitRealize(uint256 requestedAssets, uint256 shares)
        internal
        returns (uint256 payout, uint256 sBurn)
    {
        uint256 supply = totalSupply();
        uint256 idle0 = IERC20(asset()).balanceOf(address(this));
        // 柱3: the caller may draw at most its pro-rata of idle — never the whole idle buffer.
        uint256 idleShare = supply == 0 ? idle0 : Math.mulDiv(idle0, shares, supply);

        uint256 fromAdapter;
        bool valuationReadable = true;
        if (activeAdapter != address(0)) {
            // C-1/D-1/E-1 guard (Round-8 v2): recall ONLY against a READABLE valuation. The whole
            //   recall lives inside the `totalAssets()` try — if the adapter valuation reverts we
            //   take the catch and realize NOTHING here (see the F guard below). This still
            //   satisfies F-2/柱1 (a broken oracle NEVER bricks the exit — the call returns without
            //   reverting), but it no longer prices the recall against the stale, loss-blind
            //   `_totalDebt`: that over-stated mark let the FIRST exiter drain the whole realizable
            //   pool while the last got 0 (skew ∞). Under an unreadable valuation the adapter's
            //   realizable value is unknown, so it is released FAIRLY by governance force-detach
            //   (which writes `_totalDebt` down to realized), not first-come-first-served here.
            try IStrategyAdapter(activeAdapter).totalAssets() returns (uint256 mark) {
                // 柱3: cap the recall at the caller's pro-rata slice of the mark. F-3 (INV-3): also
                //   cap at what is actually NEEDED (requestedAssets - idleShare). The mark can exceed
                //   realizable NAV by still-locked profit (totalAssets subtracts lockedProfit, the
                //   recall does not); recalling raw pro-rata would strand that in idle (non-custody).
                uint256 wantAdapter;
                if (supply != 0) {
                    uint256 proRata = Math.mulDiv(mark, shares, supply);
                    uint256 need = requestedAssets > idleShare ? requestedAssets - idleShare : 0;
                    wantAdapter = proRata < need ? proRata : need;
                }
                if (wantAdapter > 0) {
                    uint256 balBefore = idle0;
                    // 柱1: honest partial-fill — pull best-effort and NEVER revert on a shortfall.
                    //   The realized delta (not the adapter's word) is the source of truth (M13-16).
                    try IStrategyAdapter(activeAdapter).withdraw(wantAdapter, address(this)) {} catch {}
                    uint256 balNow = IERC20(asset()).balanceOf(address(this));
                    fromAdapter = balNow > balBefore ? balNow - balBefore : 0;
                    _totalDebt = _totalDebt > fromAdapter ? _totalDebt - fromAdapter : 0;
                }
            } catch {
                valuationReadable = false;
            }
        }

        // F guard (Round-8 v2 arbiter — supersedes the C-1 "idle still pays" behavior): under an
        //   UNREADABLE valuation on a STILL-ATTACHED adapter, realize NOTHING (payout=0, sBurn=0)
        //   and retain the full claim. 柱4 requires burning shares at the REALIZABLE price so
        //   per-share value is preserved; but the frozen adapter's realizable NAV (idle + R) is
        //   UNKNOWN while the valuation reverts, so ANY partial idle payout must be priced against
        //   an unknown denominator. Pricing it at the loss-blind mark (`_totalDebt`) under-burns
        //   the first exiter's shares → over-retained residual → a permanent first-mover skim of
        //   the last exiter after force-detach (ExitSkewIdleOnlyBurnPriceF). Pricing it at the
        //   idle-only NAV burns the whole offered stake → strands the adapter claim (F-1 haircut).
        //   Neither is fair, so we realize 0 here: the exit NEVER bricks (returns without reverting,
        //   claim retained), and the adapter's realizable value is released FAIRLY, order-independent,
        //   by governance force-detach (which sets activeAdapter=0 and writes `_totalDebt` to realized,
        //   after which idle pays pro-rata below). Normal idle payout is unaffected — it runs only when
        //   the valuation is readable, or after detach (activeAdapter==0 ⇒ valuationReadable stays true).
        //
        //   EXEMPTION — emergency shutdown: shutdown already force-recalled the adapter to idle and
        //   set `_totalDebt = 0` (setEmergencyShutdown), so the loss-blind over-statement that this
        //   guard defends against cannot exist under shutdown: the mark fallback (idle + `_totalDebt`)
        //   equals real idle, so pricing the idle payout at it is fair (no first-mover skim is
        //   reachable — either the recall delivered and `_totalDebt==0`, or it did not and idle==0).
        //   Blocking here instead would re-brick the emergency valve (H-02) for a post-shutdown
        //   oracle break, stranding already-recalled idle behind a governance action. So under
        //   shutdown we fall through and pay the idle pro-rata as before.
        if (!valuationReadable && !emergencyShutdown) {
            return (0, 0);
        }

        // Pro-rata of realizable liquidity actually on hand for this caller.
        uint256 realizable = idleShare + fromAdapter;
        payout = requestedAssets < realizable ? requestedAssets : realizable;

        if (payout >= requestedAssets) {
            sBurn = shares; // full fill → burn exactly what was offered
        } else {
            // Partial fill: burn only the shares matching the cash paid (Ceil = protocol-favour,
            // so a partial exiter can never dust-burn too few shares for the cash received).
            sBurn = _convertToShares(payout, Math.Rounding.Ceil);
            if (sBurn > shares) sBurn = shares; // 柱4: residual = shares - sBurn stays as the claim
        }
    }

    /// @dev Burn the resolved shares (allowance charged on sBurn, not the offered shares) and
    ///      deliver the cash. H-2: burns are lock-exempt in _update; the caller's lock was
    ///      already checked in withdraw/redeem.
    function _completeExit(address caller, address receiver, address owner, uint256 payout, uint256 sBurn)
        internal
    {
        if (caller != owner) {
            _spendAllowance(owner, caller, sBurn);
        }
        _burn(owner, sBurn);
        IERC20(asset()).safeTransfer(receiver, payout);
        emit Withdraw(caller, receiver, owner, payout, sBurn);
    }

    /// @dev H-2: Block share transfers between users while sender is locked.
    ///      Mints (from == 0) and burns (to == 0) are exempt; the burn path is
    ///      already gated by _withdraw's lock check.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            require(block.timestamp >= _lockedUntil[from], "VAULT: still locked");
        }
        super._update(from, to, value);
    }

    // =========================================
    // Internal: Adapter I/O
    // =========================================

    /// @dev Transfer all idle vault balance to the active adapter
    function _deployToAdapter() internal {
        if (activeAdapter == address(0)) return;
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle == 0) return;

        address adapter_ = activeAdapter;
        // M-3: Wrap transfer + adapter.deposit() in an external self-call so
        //      that a reverting adapter rolls the safeTransfer back as well
        //      — funds stay idle in the vault and the outer user deposit
        //      still succeeds. Governance can then swap or recover the
        //      faulty adapter.
        try this.__atomicPushToAdapter(adapter_, idle) {
            _totalDebt += idle;
        } catch {
            emit AdapterDepositFailed(adapter_, idle);
        }
    }

    /// @dev M-3 helper: external boundary so try/catch can roll back the
    ///      transfer and adapter call atomically. Only callable by the
    ///      contract itself.
    function __atomicPushToAdapter(address adapter, uint256 amount) external {
        require(msg.sender == address(this), "VAULT: self only");
        IERC20(asset()).safeTransfer(adapter, amount);
        IStrategyAdapter(adapter).deposit(amount);
    }

    // =========================================
    // Governance: Adapter Management
    // =========================================

    /// @notice Switch the active strategy adapter
    /// @dev Recalls 100% of assets from old adapter first.
    ///      Deploys to new adapter immediately after switch.
    function setAdapter(address newAdapter) external override onlyGovernance nonReentrant {
        // H-1: Enforce registry whitelist when a registry is configured.
        //      address(0) is allowed (pauses the strategy) and bypasses the check.
        if (newAdapter != address(0) && adapterRegistry != address(0)) {
            require(
                IAdapterRegistry(adapterRegistry).isActive(newAdapter),
                "VAULT: adapter not whitelisted"
            );
        }

        // M-03 (3rd review): verify the incoming adapter is bound to THIS vault and the same
        //   asset before activating it — a misconfigured/foreign adapter must not be wired in.
        //   governance() is best-effort: adapters that expose it must share the vault's
        //   governance (the Timelock); test mocks that omit it are skipped.
        if (newAdapter != address(0)) {
            require(IStrategyAdapter(newAdapter).asset() == asset(), "VAULT: adapter asset mismatch");
            require(IAdapterBindings(newAdapter).vault() == address(this), "VAULT: adapter vault mismatch");
            try IAdapterBindings(newAdapter).governance() returns (address g) {
                require(g == governance, "VAULT: adapter governance mismatch");
            } catch {}
        }

        // Recall everything from current adapter
        if (activeAdapter != address(0)) {
            if (newAdapter == address(0)) {
                // ADR-007 #1 — FORCE-DETACH (pause to idle): best-effort recall so
                //   governance can ALWAYS pause, even when the adapter under-delivers or
                //   its totalAssets() reverts (a depeg / not-ready oracle must not freeze
                //   the pause valve). The realized amount is booked; any unrecovered
                //   remainder is written off from NAV — a deliberate, timelocked
                //   governance action surfaced via AdapterForceDetached.
                address det = activeAdapter;
                uint256 marked;
                // H-01: track whether the NAV read actually succeeded. A reverting
                //   totalAssets() (broken oracle / not-ready TWAP) yields marked = 0 AND
                //   navReadOk = false — an UNKNOWN valuation, not a genuine zero. Deposits
                //   must pause in that case too (see below), or a depositor could mint
                //   against a pool whose stranded value is uncounted.
                bool navReadOk;
                try IStrategyAdapter(det).totalAssets() returns (uint256 b) { marked = b; navReadOk = true; }
                catch { marked = 0; navReadOk = false; }
                uint256 received;
                if (marked > 0) {
                    uint256 balBefore = IERC20(asset()).balanceOf(address(this));
                    try IStrategyAdapter(det).withdraw(marked, address(this)) { } catch { }
                    received = IERC20(asset()).balanceOf(address(this)) - balBefore;
                }
                emit AdapterForceDetached(det, marked, received);
                // H-01: record the unreadable-valuation case explicitly so governance and
                //   integrators can see WHY deposits paused (marked == 0 alone is ambiguous
                //   with a genuinely-empty adapter).
                if (!navReadOk) emit AdapterNavUnreadableOnDetach(det);
                // M-03 / H-01: pause deposits when the recall realized a shortfall (NAV
                //   written off) OR the NAV could not be read at all (unknown impairment).
                //   In both cases any profit still locked from a prior harvest is not real —
                //   clear it so totalAssets() reflects the honest raw balance (rather than
                //   clamping toward zero against a stale buffer), and pause deposits so nobody
                //   mints against the impaired/unknown pool until governance reopens (a
                //   healthy reattach or reopenDeposits() once valuation is confirmed recovered).
                if (!navReadOk || received < marked) {
                    _lockedProfit = 0;
                    _lastReport = block.timestamp;
                    depositsPaused = true;
                    emit DepositsPausedSet(true);
                }
            } else {
                // MIGRATION (unchanged, strict) — M13-16 (Medium-A): apply the
                //   balance-delta guard. Require the real amount received covers the full
                //   recall, so an adapter that silently under-delivers reverts here instead
                //   of letting the vault switch to a NEW adapter with funds stranded. To
                //   pause a shorting/frozen adapter, use setAdapter(address(0)) (force-detach
                //   above) or emergency shutdown.
                uint256 adapterBal = IStrategyAdapter(activeAdapter).totalAssets();
                if (adapterBal > 0) {
                    uint256 balBefore = IERC20(asset()).balanceOf(address(this));
                    IStrategyAdapter(activeAdapter).withdraw(adapterBal, address(this));
                    uint256 received = IERC20(asset()).balanceOf(address(this)) - balBefore;
                    require(received >= adapterBal, "VAULT: adapter shortfall");
                }
            }
            _totalDebt = 0;
        }

        address oldAdapter = activeAdapter;
        activeAdapter = newAdapter;
        emit AdapterUpdated(oldAdapter, newAdapter);

        // Deploy to new adapter (skip if address(0) = pause strategy)
        if (newAdapter != address(0)) {
            // M-03: attaching a healthy strategy is governance re-opening after a lossy
            //   detach — lift the deposit pause (a no-op when it was never set).
            if (depositsPaused) {
                depositsPaused = false;
                emit DepositsPausedSet(false);
            }
            _deployToAdapter();
        }
    }

    // =========================================
    // Governance: Lock Period
    // =========================================

    function setLockPeriod(uint256 newPeriod) external override onlyGovernance {
        emit LockPeriodUpdated(lockPeriod, newPeriod);
        lockPeriod = newPeriod;
    }

    // =========================================
    // Governance: Fees
    // =========================================

    /// @dev Part B P4: performance-fee accrual is NOT implemented — only the
    ///      management fee is ever collected. Reject any attempt to enable a nonzero
    ///      rate so the dead field can never silently take effect. Setting 0 is a
    ///      harmless no-op (kept callable so tooling/harnesses can normalize state).
    function setPerformanceFee(uint256 newFee) external onlyGovernance {
        require(newFee == 0, "VAULT: performance fee not implemented");
        performanceFee = newFee; // always 0
    }

    function setManagementFee(uint256 newFee) external onlyGovernance {
        _collectFees(); // ADR-007 #3: crystallize at the old rate before changing (no retroactive fee)
        require(newFee <= MAX_MANAGEMENT_FEE, "VAULT: fee too high");
        // M-01: while managementFee == 0, _collectFees() early-returns WITHOUT advancing
        //   _lastHarvestTimestamp (nothing accrues at a zero rate), so the fee anchor is
        //   left stale across the whole zero-fee window. Enabling a nonzero rate would then
        //   let the next collect charge the new rate retroactively over that elapsed zero-fee
        //   period, diluting existing LPs. Advance the anchor here so a 0->nonzero change only
        //   ever applies going forward.
        if (managementFee == 0) {
            _lastHarvestTimestamp = block.timestamp;
        }
        emit ManagementFeeUpdated(managementFee, newFee); // Part B P2: observability
        managementFee = newFee;
    }

    function setFeeRecipient(address newRecipient) external onlyGovernance {
        require(newRecipient != address(0), "VAULT: zero address");
        feeRecipient = newRecipient;
    }

    // =========================================
    // Fee Collection (permissionless — anyone can trigger)
    // =========================================

    /// @notice Collect accrued management fees by minting shares to feeRecipient
    function collectFees() external override nonReentrant returns (uint256 feeShares) {
        return _collectFees();
    }

    /// @dev ADR-007 #3: crystallize accrued management fee. Called at the start of every
    ///      deposit/mint/withdraw/redeem (before the ERC-4626 conversion) and before a fee-rate
    ///      change, so the fee is charged on the pool/time that actually earned it — a late
    ///      depositor is not diluted for a period they were absent, and an exiting user cannot
    ///      dodge their share. CEI: the fee anchor is advanced before the mint.
    function _collectFees() internal returns (uint256 feeShares) {
        if (managementFee == 0 || feeRecipient == address(0)) return 0;
        // B-2 (Round 8): freeze management-fee accrual during emergency shutdown. Management
        //   fee is a time-based AUM fee; billing it across a window in which the strategy is
        //   shut down (broken/idle) would dilute users trying to exit — least defensible exactly
        //   when trust is lowest. setEmergencyShutdown crystallizes the fee up to the shutdown
        //   instant (while still live) and resets the anchor on re-enable, so the shutdown window
        //   is WAIVED, not billed retroactively on the first post-recovery interaction.
        if (emergencyShutdown) return 0;

        uint256 elapsed = block.timestamp - _lastHarvestTimestamp;
        if (elapsed == 0) return 0;

        uint256 assets = totalAssets();
        uint256 supply = totalSupply();
        // Advance the anchor first (CEI): the fee window is consumed regardless of the mint.
        _lastHarvestTimestamp = block.timestamp;
        if (assets == 0 || supply == 0) return 0;

        // Pro-rated management fee
        uint256 feeAssets = (assets * managementFee * elapsed) / (MAX_BPS * SECS_PER_YEAR);
        if (feeAssets > 0 && feeAssets < assets) {
            // M-1: feeAssets is already part of totalAssets() (accrued yield
            //      already in the vault), so previewDeposit would under-mint.
            //      Use the dilution formula so that after minting, feeRecipient
            //      owns exactly feeAssets worth of the existing pool.
            feeShares = (feeAssets * supply) / (assets - feeAssets);
            if (feeShares > 0) {
                _mint(feeRecipient, feeShares);
                emit FeeCollected(feeRecipient, feeShares, feeAssets);
            }
        }
    }

    // =========================================
    // Governance: Emergency Shutdown
    // =========================================

    function setEmergencyShutdown(bool active) external override nonReentrant {
        if (active) {
            require(msg.sender == guardian || msg.sender == governance, "VAULT: not guardian/gov");
        } else {
            require(msg.sender == governance, "VAULT: not governance");
        }
        // B-2 (Round 8): manage the fee-accrual anchor across the shutdown boundary so the
        //   non-productive shutdown window is never billed (see _collectFees' shutdown freeze).
        if (active) {
            _collectFees();                          // crystallize fees earned BEFORE shutdown (still live)
        } else {
            _lastHarvestTimestamp = block.timestamp; // resume accrual from re-enable; waive the shutdown window
        }
        // A: set the flag FIRST so shutdown always takes effect, then attempt the
        //    recall in try/catch. A frozen/broken adapter must not be able to brick
        //    the emergency valve. activeAdapter is unchanged, so on catch the funds
        //    stay counted in totalAssets() and are recoverable once the adapter
        //    unfreezes (users withdraw via the honest partial-fill exit; deposits are blocked).
        emergencyShutdown = active;
        // R8-1 (Round 8, revised): shutdown deliberately does NOT clear _lockedProfit.
        //   Clearing it lifts totalAssets() by the locked amount in the same tx the guardian
        //   broadcasts; that tx is mempool-visible, so an attacker front-runs it with a
        //   deposit priced against the (still) suppressed NAV and redeems right after — the
        //   withdraw lock is waived under shutdown — skimming the just-released profit that
        //   belongs to existing holders. PoC (ProfitStreaming.t.sol::test_B1_shutdownJIT_*)
        //   measured extraction up to the FULL locked profit (≈500 at equal stake, ≈990 for a
        //   whale, per 1_000 reward). Retaining the linear unlock keeps extraction at 0: the
        //   "suppressed" NAV during the exit rush IS the intended anti-JIT streaming behavior;
        //   the profit stays in the vault (value-conserving) and vests to remaining holders
        //   over PROFIT_UNLOCK_PERIOD. This is why shutdown differs from the force-detach path,
        //   where the mark is realized against a departing adapter rather than opened to a JIT.
        if (active && activeAdapter != address(0)) {
            // Recall all assets to vault for safe withdrawal by users.
            // ADR-007 #1: read the mark defensively — a reverting totalAssets() (e.g. a
            // not-ready oracle) must NOT brick the emergency valve. On failure, skip the
            // recall; activeAdapter is unchanged so the funds stay counted in totalAssets()
            // and remain recoverable once the adapter unfreezes.
            try IStrategyAdapter(activeAdapter).totalAssets() returns (uint256 adapterBal) {
                if (adapterBal > 0) {
                    try IStrategyAdapter(activeAdapter).withdraw(adapterBal, address(this)) {
                        _totalDebt = 0;
                    } catch {
                        emit AdapterRecallFailed(activeAdapter, adapterBal);
                    }
                }
            } catch {
                emit AdapterRecallFailed(activeAdapter, 0);
            }
        }
        emit EmergencyShutdown(active);
    }

    /// @notice M-03: Explicitly lift the deposit pause set by a lossy force-detach while
    ///         the strategy stays idle (activeAdapter == address(0)). Attaching a healthy
    ///         adapter reopens automatically; this is the stay-paused-strategy path.
    function reopenDeposits() external override onlyGovernance {
        depositsPaused = false;
        emit DepositsPausedSet(false);
    }

    // =========================================
    // Governance: 2-step Transfer
    // =========================================

    function proposeGovernance(address newGovernance) external override onlyGovernance {
        require(newGovernance != address(0), "VAULT: zero address");
        // M-02 (3rd review) / F-1: on every PRODUCTION chain, governance MUST be a
        //   TimelockController with >= 48h delay — never a hot EOA. Off-production
        //   (testnets/local) keeps EOA governance for iteration. Complements the
        //   mainnet-gate G1 manual check. The production set must match the chains the
        //   deploy script wires with a real 2-of-3 Safe + Timelock (see _isProductionChain).
        if (_isProductionChain()) {
            // Must be a contract first (an EOA staticcall returns empty data, which would
            // fail to decode BEFORE reaching the catch), then a Timelock with >= 48h delay.
            require(newGovernance.code.length > 0, "VAULT: mainnet gov must be a Timelock");
            try ITimelockMinDelay(newGovernance).getMinDelay() returns (uint256 d) {
                require(d >= 48 hours, "VAULT: mainnet gov timelock < 48h");
            } catch {
                revert("VAULT: mainnet gov must be a Timelock");
            }
        }
        pendingGovernance = newGovernance;
        emit GovernanceProposed(governance, newGovernance);
    }

    function acceptGovernance() external override {
        require(msg.sender == pendingGovernance, "VAULT: not pending governance");
        emit GovernanceAccepted(pendingGovernance);
        governance = pendingGovernance;
        pendingGovernance = address(0);
    }

    /// @dev F-1: chains where governance MUST be a >= 48h Timelock (M-02). This set
    ///      MUST track the production mainnets the deploy script wires with a real
    ///      2-of-3 Safe + TimelockController: Ethereum (1), Arbitrum One (42161),
    ///      BNB Chain (56). Arbitrum One is this vault's PRIMARY chain, so gating on
    ///      chainid==1 alone left the M-02 detection window unenforced where it matters
    ///      most. Testnets/local (Sepolia, Arb Sepolia, BNB testnet, 31337) are excluded
    ///      so EOA governance stays usable for iteration.
    function _isProductionChain() private view returns (bool) {
        uint256 id = block.chainid;
        return id == 1 || id == 42161 || id == 56;
    }

    // =========================================
    // Governance: Guardian
    // =========================================

    function setGuardian(address newGuardian) external override onlyGovernance {
        require(newGuardian != address(0), "VAULT: zero guardian");
        emit GuardianChanged(guardian, newGuardian);
        guardian = newGuardian;
    }

    // =========================================
    // View
    // =========================================

    function lockedUntil(address user) external view override returns (uint256) {
        return _lockedUntil[user];
    }

    function totalDebt() external view returns (uint256) {
        return _totalDebt;
    }

    // =========================================
    // Inflation Attack Protection
    // =========================================

    /// @dev Virtual shares offset (OZ v5).
    ///      For USDC (6 decimals): offset=9 → shares have 15 decimals.
    ///      Makes first-deposit inflation attack economically infeasible.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 9;
    }
}
