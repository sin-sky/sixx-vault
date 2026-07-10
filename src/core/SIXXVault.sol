// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISIXXVault} from "../interfaces/ISIXXVault.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IStrategyAdapter} from "../interfaces/IStrategyAdapter.sol";
import {IAdapterRegistry} from "../interfaces/IAdapterRegistry.sol";

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
    uint256 private constant MAX_PERFORMANCE_FEE = 3_000; // 30% hard cap
    uint256 private constant MAX_MANAGEMENT_FEE = 500;    // 5% hard cap

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

    /// @dev Amount of assets currently deployed to the active adapter
    uint256 private _totalDebt;
    /// @dev Timestamp of last fee collection
    uint256 private _lastHarvestTimestamp;

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
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public override(ERC4626, IERC4626) nonReentrant returns (uint256)
    {
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public override(ERC4626, IERC4626) nonReentrant returns (uint256)
    {
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public override(ERC4626, IERC4626) nonReentrant returns (uint256)
    {
        return super.redeem(shares, receiver, owner);
    }

    // =========================================
    // ERC-4626: totalAssets
    // =========================================

    /// @notice Vault balance + assets deployed to adapter
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        uint256 adapterAssets = activeAdapter != address(0)
            ? IStrategyAdapter(activeAdapter).totalAssets()
            : 0;
        return IERC20(asset()).balanceOf(address(this)) + adapterAssets;
    }

    // =========================================
    // ERC-4626: maxDeposit / maxMint
    // =========================================

    function maxDeposit(address) public view override(ERC4626, IERC4626) returns (uint256) {
        if (emergencyShutdown) return 0;
        return type(uint256).max;
    }

    function maxMint(address) public view override(ERC4626, IERC4626) returns (uint256) {
        if (emergencyShutdown) return 0;
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

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        // B: emergency shutdown waives the lock so users can withdraw immediately.
        if (!emergencyShutdown) {
            require(block.timestamp >= _lockedUntil[owner], "VAULT: still locked");
        }
        _recallFromAdapter(assets);
        super._withdraw(caller, receiver, owner, assets, shares);
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

    /// @dev Pull at least `assets` back to the vault from the adapter
    function _recallFromAdapter(uint256 assets) internal {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle >= assets) return;
        if (activeAdapter == address(0)) return;

        uint256 needed = assets - idle;
        uint256 available = IStrategyAdapter(activeAdapter).totalAssets();
        uint256 toWithdraw = needed > available ? available : needed;
        if (toWithdraw == 0) return;

        // M13-16: don't trust the adapter's return value blindly — measure the actual
        //         balance delta and require it covers the request, so an adapter that
        //         silently under-delivers reverts here (explicit) instead of causing a
        //         confusing shortfall later. Accounting stays sourced from real balance.
        uint256 balBefore = IERC20(asset()).balanceOf(address(this));
        IStrategyAdapter(activeAdapter).withdraw(toWithdraw, address(this));
        uint256 received = IERC20(asset()).balanceOf(address(this)) - balBefore;
        require(received >= toWithdraw, "VAULT: adapter shortfall");
        _totalDebt = _totalDebt > received ? _totalDebt - received : 0;
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
                try IStrategyAdapter(det).totalAssets() returns (uint256 b) { marked = b; }
                catch { marked = 0; }
                uint256 received;
                if (marked > 0) {
                    uint256 balBefore = IERC20(asset()).balanceOf(address(this));
                    try IStrategyAdapter(det).withdraw(marked, address(this)) { } catch { }
                    received = IERC20(asset()).balanceOf(address(this)) - balBefore;
                }
                emit AdapterForceDetached(det, marked, received);
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

    function setPerformanceFee(uint256 newFee) external onlyGovernance {
        require(newFee <= MAX_PERFORMANCE_FEE, "VAULT: fee too high");
        performanceFee = newFee;
    }

    function setManagementFee(uint256 newFee) external onlyGovernance {
        require(newFee <= MAX_MANAGEMENT_FEE, "VAULT: fee too high");
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
    function collectFees() external override returns (uint256 feeShares) {
        if (managementFee == 0 || feeRecipient == address(0)) return 0;

        uint256 elapsed = block.timestamp - _lastHarvestTimestamp;
        if (elapsed == 0) return 0;

        uint256 assets = totalAssets();
        uint256 supply = totalSupply();
        if (assets == 0 || supply == 0) {
            _lastHarvestTimestamp = block.timestamp;
            return 0;
        }

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
        _lastHarvestTimestamp = block.timestamp;
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
        // A: set the flag FIRST so shutdown always takes effect, then attempt the
        //    recall in try/catch. A frozen/broken adapter must not be able to brick
        //    the emergency valve. activeAdapter is unchanged, so on catch the funds
        //    stay counted in totalAssets() and are recoverable once the adapter
        //    unfreezes (users withdraw via _recallFromAdapter; deposits are blocked).
        emergencyShutdown = active;
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

    // =========================================
    // Governance: 2-step Transfer
    // =========================================

    function proposeGovernance(address newGovernance) external override onlyGovernance {
        require(newGovernance != address(0), "VAULT: zero address");
        pendingGovernance = newGovernance;
        emit GovernanceProposed(governance, newGovernance);
    }

    function acceptGovernance() external override {
        require(msg.sender == pendingGovernance, "VAULT: not pending governance");
        emit GovernanceAccepted(pendingGovernance);
        governance = pendingGovernance;
        pendingGovernance = address(0);
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
