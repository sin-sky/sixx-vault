// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SIXXVault} from "../../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../../src/core/AdapterRegistry.sol";
import {FaultInjectingAdapter} from "../mocks/FaultInjectingAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMintableERC20 is IERC20 {
    function mint(address to, uint256 amount) external;
}

/// @title StateTransitionHandler
/// @notice Drives the vault through fuzzed sequences that mix EVERY lifecycle operation
///         (user + governance + keeper) with adapter fault toggles injected between steps —
///         the "state transition × fault injection" surface from which H-01/H-02 emerged.
///         Ghost variables and violation flags let the invariant contract assert the nine
///         fund-protection invariants over every reached state.
/// @dev A small POOL of pre-registered fault adapters is cycled for migrate/reattach (keeps
///      registrations under MAX_ADAPTERS and models reattaching a previously-used adapter).
contract StateTransitionHandler is Test {
    SIXXVault       public immutable vault;
    IMintableERC20  public immutable usdc;
    AdapterRegistry public immutable registry;
    address         public immutable governance;

    FaultInjectingAdapter[] public pool;
    int256  public activeIdx; // index into pool of the active adapter, or -1 if detached

    address[] public actors;

    // ─── Ghost accounting (underlying units) ───
    uint256 public ghost_deposited;
    uint256 public ghost_withdrawn;
    uint256 public ghost_yield;

    // ─── Invariant violation flags (asserted between calls) ───
    /// INV-1: an exit reverted while the adapter could deliver (funds realizable) — a real
    ///        liveness breach, distinct from the documented frozen/lossy pause.
    bool public ghost_exitBlockedDespiteRealizable;
    /// INV-1: redeem reported assets but the recipient received none.
    bool public ghost_receiptMismatch;
    /// INV-5: a deposit minted shares while deposits were paused / shut down.
    bool public ghost_mintWhilePaused;

    // ─── Coverage (afterInvariant anti-vacuous checks) ───
    bool    public ghost_faultInjectedEver;         // any fault knob was ever turned on
    uint256 public ghost_exitsUnderTotalAssetsRevert; // successful exits while totalAssets() reverted
    uint256 public ghost_forceDetaches;
    uint256 public ghost_reattaches;
    uint256 public ghost_shutdowns;

    // ─── Call counters ───
    uint256 public callsDeposit;
    uint256 public callsExit;
    uint256 public callsTransfer;

    uint256 internal constant MAX_ACTION = 1_000_000 * 1e6; // 1M USDC per action

    constructor(
        SIXXVault vault_,
        IMintableERC20 usdc_,
        AdapterRegistry registry_,
        FaultInjectingAdapter[] memory pool_,
        address[] memory actors_,
        address governance_
    ) {
        vault = vault_;
        usdc = usdc_;
        registry = registry_;
        governance = governance_;
        for (uint256 i = 0; i < pool_.length; i++) pool.push(pool_[i]);
        actors = actors_;
        activeIdx = 0; // setUp attaches pool[0]
    }

    // ─── helpers ───
    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function _active() internal view returns (FaultInjectingAdapter) {
        if (activeIdx < 0) return FaultInjectingAdapter(address(0));
        return pool[uint256(activeIdx)];
    }

    function _totalAssetsReverts() internal view returns (bool) {
        if (activeIdx < 0) return false;
        return pool[uint256(activeIdx)].revertOnTotalAssets();
    }

    /// @dev The active adapter can deliver a withdraw in full (or there is no adapter → exit
    ///      is served from idle). A frozen (revertOnWithdraw) or lossy (deliverBps<100%)
    ///      adapter is the documented liveness pause, NOT an INV-1 breach.
    function _exitFunctional() internal view returns (bool) {
        if (activeIdx < 0) return true;
        FaultInjectingAdapter a = pool[uint256(activeIdx)];
        return !a.revertOnWithdraw() && a.deliverBps() == 10_000;
    }

    // ═════════════════════════ USER ACTIONS ═════════════════════════

    function deposit(uint256 actorSeed, uint256 amount) external {
        address who = _actor(actorSeed);
        amount = bound(amount, 0, MAX_ACTION);
        if (amount == 0) return;
        usdc.mint(who, amount);

        bool wasPaused = vault.depositsPaused() || vault.emergencyShutdown();
        uint256 supplyBefore = vault.totalSupply();

        vm.startPrank(who);
        usdc.approve(address(vault), amount);
        try vault.deposit(amount, who) {
            ghost_deposited += amount;
            if (wasPaused && vault.totalSupply() > supplyBefore) ghost_mintWhilePaused = true;
            callsDeposit++;
        } catch {}
        vm.stopPrank();
    }

    function mint(uint256 actorSeed, uint256 shares) external {
        address who = _actor(actorSeed);
        shares = bound(shares, 0, 1_000_000 * 1e15); // 15-dec shares
        if (shares == 0) return;
        uint256 cost = vault.previewMint(shares);
        if (cost == 0 || cost > MAX_ACTION) return;
        usdc.mint(who, cost);

        bool wasPaused = vault.depositsPaused() || vault.emergencyShutdown();
        uint256 supplyBefore = vault.totalSupply();

        vm.startPrank(who);
        usdc.approve(address(vault), cost);
        try vault.mint(shares, who) {
            ghost_deposited += cost;
            if (wasPaused && vault.totalSupply() > supplyBefore) ghost_mintWhilePaused = true;
            callsDeposit++;
        } catch {}
        vm.stopPrank();
    }

    function redeem(uint256 actorSeed, uint256 shares) external {
        address who = _actor(actorSeed);
        uint256 bal = vault.balanceOf(who);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        _exit(who, who, shares, true);
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address who = _actor(actorSeed);
        uint256 maxA = vault.maxWithdraw(who);
        if (maxA == 0) return;
        amount = bound(amount, 1, maxA);
        _exit(who, who, amount, false);
    }

    /// @dev Third-party exit: `owner` approves `spender`, spender redeems owner's shares.
    function thirdPartyRedeem(uint256 ownerSeed, uint256 spenderSeed, uint256 shares) external {
        address owner_ = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 bal = vault.balanceOf(owner_);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        vm.prank(owner_);
        vault.approve(spender, shares);
        _exitFrom(spender, owner_, owner_, shares, true);
    }

    /// @dev ERC-20 share transfer to a third party (lock is 0 in this harness).
    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        if (from == to) return;
        uint256 bal = vault.balanceOf(from);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(from);
        try vault.transfer(to, amount) { callsTransfer++; } catch {}
    }

    function _exit(address caller, address owner_, uint256 amountOrShares, bool isRedeem) internal {
        _exitFrom(caller, caller, owner_, amountOrShares, isRedeem);
    }

    function _exitFrom(address caller, address /*spender*/, address owner_, uint256 amountOrShares, bool isRedeem)
        internal
    {
        bool taReverts = _totalAssetsReverts();
        // What the vault will TRY to deliver vs what is ACTUALLY recoverable right now. An
        // exit that reverts is an INV-1 breach ONLY when the claim is genuinely recoverable
        // (funds exist AND the adapter can deliver them). A revert because a realized loss has
        // left the claim unbacked (claim > recoverable) is the documented force-detach-recovery
        // case, NOT a liveness breach — so it must not be flagged.
        uint256 claimable = isRedeem ? vault.previewRedeem(amountOrShares) : amountOrShares;
        uint256 recoverable = usdc.balanceOf(address(vault));
        if (_exitFunctional() && activeIdx >= 0) recoverable += pool[uint256(activeIdx)].realBalance();

        uint256 before = usdc.balanceOf(owner_);
        vm.prank(caller);
        if (isRedeem) {
            try vault.redeem(amountOrShares, owner_, owner_) returns (uint256 assets) {
                uint256 got = usdc.balanceOf(owner_) - before;
                ghost_withdrawn += got;
                if (assets > 0 && got == 0) ghost_receiptMismatch = true; // INV-1 receipt
                if (taReverts && got > 0) ghost_exitsUnderTotalAssetsRevert++;
                callsExit++;
            } catch {
                if (claimable > 0 && claimable <= recoverable) ghost_exitBlockedDespiteRealizable = true; // INV-1 breach
            }
        } else {
            try vault.withdraw(amountOrShares, owner_, owner_) returns (uint256) {
                uint256 got = usdc.balanceOf(owner_) - before;
                ghost_withdrawn += got;
                if (taReverts && got > 0) ghost_exitsUnderTotalAssetsRevert++;
                callsExit++;
            } catch {
                if (claimable > 0 && claimable <= recoverable) ghost_exitBlockedDespiteRealizable = true;
            }
        }
    }

    // ═════════════════════════ YIELD / LOSS / HARVEST ═════════════════════════

    function addYield(uint256 amount) external {
        if (activeIdx < 0) return;
        if (vault.totalAssets() == 0) return;
        amount = bound(amount, 0, MAX_ACTION / 100);
        if (amount == 0) return;
        FaultInjectingAdapter a = _active();
        usdc.mint(address(this), amount);
        usdc.approve(address(a), amount);
        try a.addYield(amount) { ghost_yield += amount; } catch {}
    }

    function realizeLoss(uint256 amount) external {
        if (activeIdx < 0) return;
        amount = bound(amount, 0, MAX_ACTION / 50);
        if (amount == 0) return;
        // burn to a sink (address(0xDEAD)); reduces the adapter's real backing.
        try _active().realizeLoss(amount, address(0xDEAD)) {} catch {}
    }

    function harvestVault() external {
        try vault.harvest() {} catch {}
    }

    // ═════════════════════════ GOVERNANCE ACTIONS ═════════════════════════

    function setManagementFee(uint256 bps) external {
        bps = bound(bps, 0, 500);
        vm.prank(governance);
        try vault.setManagementFee(bps) {} catch {}
    }

    function setPerformanceFee(uint256 bps) external {
        // vault rejects any nonzero perf fee (not implemented) — exercise both paths.
        bps = bound(bps, 0, 1);
        vm.prank(governance);
        try vault.setPerformanceFee(bps) {} catch {}
    }

    function collectFees() external {
        try vault.collectFees() {} catch {}
    }

    /// @dev Attach or migrate to a pool adapter (healthy re-attach also reopens deposits).
    function attachOrMigrate(uint256 seed) external {
        uint256 j = bound(seed, 0, pool.length - 1);
        if (activeIdx >= 0 && uint256(activeIdx) == j) return;
        vm.prank(governance);
        try vault.setAdapter(address(pool[j])) {
            if (activeIdx < 0) ghost_reattaches++;
            activeIdx = int256(j);
        } catch {}
    }

    function forceDetach() external {
        if (activeIdx < 0) return;
        vm.prank(governance);
        try vault.setAdapter(address(0)) { activeIdx = -1; ghost_forceDetaches++; } catch {}
    }

    function shutdownOn() external {
        vm.prank(governance);
        try vault.setEmergencyShutdown(true) { ghost_shutdowns++; } catch {}
    }

    function shutdownOff() external {
        vm.prank(governance);
        try vault.setEmergencyShutdown(false) {} catch {}
    }

    function reopenDeposits() external {
        vm.prank(governance);
        try vault.reopenDeposits() {} catch {}
    }

    // ═════════════════════════ FAULT INJECTION ═════════════════════════

    function faultRevertTotalAssets(bool v) external {
        if (activeIdx < 0) return;
        _active().setRevertOnTotalAssets(v);
        if (v) ghost_faultInjectedEver = true;
    }

    function faultRevertWithdraw(bool v) external {
        if (activeIdx < 0) return;
        _active().setRevertOnWithdraw(v);
        if (v) ghost_faultInjectedEver = true;
    }

    function faultDeliverBps(uint256 bps) external {
        if (activeIdx < 0) return;
        bps = bound(bps, 5_000, 10_000);
        _active().setDeliverBps(bps);
        if (bps < 10_000) ghost_faultInjectedEver = true;
    }

    // ─── views ───
    function netValueIn() external view returns (uint256) {
        return ghost_deposited + ghost_yield;
    }
}
