// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SIXXVault} from "../../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../../src/core/AdapterRegistry.sol";
import {FaultInjectingAdapter} from "../mocks/FaultInjectingAdapter.sol";
import {StateTransitionHandler, IMintableERC20} from "./StateTransitionHandler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MafUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

/// @title MultiAdapterFault — 複数アダプター × 障害 相互作用監査（model A：単一 active・移行モデル）
/// @notice ARCHITECTURE (confirmed from src): the vault holds funds in exactly ONE
///         `activeAdapter` (or idle) at a time. Migration A→B fully recalls A (strict:
///         `require(received >= adapterBal)`) — no residual after a HEALTHY migration.
///         Force-detach A→0 is best-effort and MAY strand funds in A (written off, but
///         recoverable by re-attaching A). Retired/detached adapters are dormant (onlyVault;
///         the vault only calls the active one). rescueToken touches only `balanceOf(this)`,
///         and the registry holds no funds — so cross-adapter / cross-vault FUND
///         contamination is structurally impossible. Concurrent-distribution scenarios
///         (MB1..4) therefore do NOT arise; this suite audits the (A) migration surface.
///
///         Reuses StateTransitionHandler (a 4-adapter pool cycled via migrate/detach/reattach
///         with per-adapter fault state) for fuzz breadth, and adds multi-adapter MINV
///         invariants + deterministic MA1..MA4 chains.
///
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 40
/// forge-config: default.invariant.fail-on-revert = false
contract MultiAdapterFaultTest is StdInvariant, Test {
    MafUSDC         usdc;
    AdapterRegistry registry;
    SIXXVault       vault;
    StateTransitionHandler handler;
    FaultInjectingAdapter[] pool;

    address governance   = address(0xBEEF);
    address feeRcpt      = address(0xFEE);
    address guardianAddr = address(0x6042D);
    address alice        = address(0xA11CE);
    address bob          = address(0xB0B);

    uint256 constant TOL = 1e4;
    uint256 constant N = 4;

    function setUp() public {
        usdc = new MafUSDC();
        vm.prank(governance);
        registry = new AdapterRegistry(governance);
        vm.prank(governance);
        vault = new SIXXVault(
            IERC20(address(usdc)), "SIXX Stable Yield", "sxUSDC",
            governance, address(registry), feeRcpt, guardianAddr
        );

        FaultInjectingAdapter[] memory p = new FaultInjectingAdapter[](N);
        vm.startPrank(governance);
        for (uint256 i = 0; i < N; i++) {
            p[i] = new FaultInjectingAdapter(address(usdc), address(vault), governance);
            registry.registerAdapter(address(p[i]), "Test", "Fuzz");
            pool.push(p[i]);
        }
        vault.setAdapter(address(p[0]));
        vault.setManagementFee(0);
        vault.setPerformanceFee(0);
        vm.stopPrank();

        address[] memory actors = new address[](3);
        actors[0] = alice; actors[1] = bob; actors[2] = address(0xCAFE);
        handler = new StateTransitionHandler(
            vault, IMintableERC20(address(usdc)), registry, p, actors, governance
        );

        // Bias toward the migration surface (migrate / detach / reattach) × per-adapter faults.
        bytes4[] memory s = new bytes4[](22);
        uint256 k;
        s[k++] = StateTransitionHandler.attachOrMigrate.selector; // ×3
        s[k++] = StateTransitionHandler.attachOrMigrate.selector;
        s[k++] = StateTransitionHandler.attachOrMigrate.selector;
        s[k++] = StateTransitionHandler.forceDetach.selector;     // ×2
        s[k++] = StateTransitionHandler.forceDetach.selector;
        s[k++] = StateTransitionHandler.faultRevertTotalAssets.selector; // ×2
        s[k++] = StateTransitionHandler.faultRevertTotalAssets.selector;
        s[k++] = StateTransitionHandler.faultDeliverBps.selector;
        s[k++] = StateTransitionHandler.faultRevertWithdraw.selector;
        s[k++] = StateTransitionHandler.deposit.selector;         // ×2
        s[k++] = StateTransitionHandler.deposit.selector;
        s[k++] = StateTransitionHandler.redeem.selector;          // ×2
        s[k++] = StateTransitionHandler.redeem.selector;
        s[k++] = StateTransitionHandler.withdraw.selector;
        s[k++] = StateTransitionHandler.realizeLoss.selector;
        s[k++] = StateTransitionHandler.addYield.selector;
        s[k++] = StateTransitionHandler.shutdownOn.selector;
        s[k++] = StateTransitionHandler.shutdownOff.selector;
        s[k++] = StateTransitionHandler.reopenDeposits.selector;
        s[k++] = StateTransitionHandler.setManagementFee.selector;
        s[k++] = StateTransitionHandler.harvestVault.selector;
        s[k++] = StateTransitionHandler.transferShares.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: s}));
        targetContract(address(handler));
    }

    // ═════════════════════════ MINV invariants ═════════════════════════

    /// MINV-1 / MINV-5: the vault NAV counts ONLY idle + the ACTIVE adapter. A detached /
    /// retired adapter — even one still holding stranded funds or fully faulty — NEVER
    /// phantom-counts into the NAV (no cross-adapter contamination, no double-count).
    function invariant_MINV1_5_noPhantomCrossAdapter() public view {
        int256 ai = handler.activeIdx();
        uint256 idle = usdc.balanceOf(address(vault));
        uint256 activeContribution;
        if (ai >= 0) {
            FaultInjectingAdapter a = handler.pool(uint256(ai));
            // Under a reverting valuation the vault falls back to _totalDebt (H-02); otherwise
            // it reads the adapter's real balance. Either way, ONLY the active adapter counts.
            activeContribution = a.revertOnTotalAssets() ? vault.totalDebt() : a.realBalance();
        }
        assertLe(vault.totalAssets(), idle + activeContribution + TOL,
            "MINV-1/5: a detached/retired adapter was phantom-counted into NAV");
    }

    /// MINV-2: aggregate solvency — outstanding shares never claim more than the (honest,
    /// active-only) NAV. A faulty/detached adapter is excluded, never overstated.
    function invariant_MINV2_aggregateSolvency() public view {
        assertLe(vault.convertToAssets(vault.totalSupply()), vault.totalAssets() + TOL,
            "MINV-2: shares over-claim the honest NAV");
    }

    /// MINV-6: registry integrity — the active-adapter list stays bounded and enumerable
    /// regardless of any adapter's fault/retire state (L-03 cap holds; no revert).
    function invariant_MINV6_registryIntegrity() public view {
        address[] memory act = registry.getActiveAdapters();
        assertLe(act.length, registry.MAX_ADAPTERS(), "MINV-6: active list exceeded cap");
    }

    // ═════════════════════════ Deterministic MA chains ═════════════════════════

    function _deposit(address who, uint256 amt) internal returns (uint256 shares) {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(vault), amt);
        shares = vault.deposit(amt, who);
        vm.stopPrank();
    }

    function _redeemAll(address who) internal returns (uint256 got) {
        uint256 sh = vault.balanceOf(who);
        if (sh == 0) return 0;
        uint256 before = usdc.balanceOf(who);
        vm.prank(who);
        vault.redeem(sh, who, who);
        got = usdc.balanceOf(who) - before;
    }

    /// MA1 cross-isolation: after a healthy migration A→B, breaking the now-DETACHED A
    /// (revert everything) must not affect the active B — NAV stays readable, exit works.
    function test_MA1_crossIsolation_detachedFaultDoesNotAffectActive() public {
        _deposit(alice, 10_000e6);              // funds in pool[0]
        vm.prank(governance);
        vault.setAdapter(address(pool[1]));      // healthy migration → full recall from pool[0]
        assertEq(pool[0].realBalance(), 0, "MA1: healthy migration left residual in old adapter");

        // Fully break the detached pool[0].
        pool[0].setRevertOnTotalAssets(true);
        pool[0].setRevertOnWithdraw(true);
        pool[0].setDeliverBps(0);

        // Active pool[1] is unaffected.
        assertApproxEqAbs(vault.totalAssets(), 10_000e6, 2, "MA1: detached fault polluted NAV");
        uint256 got = _redeemAll(alice);
        assertApproxEqAbs(got, 10_000e6, 2, "MA1: detached-adapter fault blocked active exit");
    }

    /// MA2 residual non-interference + recovery: a lossy force-detach strands funds in the
    /// old adapter; while a new adapter is active the residual is NOT counted; re-attaching
    /// the old adapter recovers the residual with no dilution.
    function test_MA2_retiredResidual_excluded_thenRecovered() public {
        _deposit(alice, 10_000e6);
        pool[0].setDeliverBps(8_000);            // only 80% realizable on recall

        vm.prank(governance);
        vault.setAdapter(address(0));            // force-detach: ~8000 to idle, ~2000 stranded in pool[0]
        assertGt(pool[0].realBalance(), 0, "MA2: expected stranded residual");
        assertTrue(vault.depositsPaused(), "MA2: not paused after lossy detach");

        vm.prank(governance);
        vault.setAdapter(address(pool[1]));      // attach empty pool[1] → deploy recovered idle
        // Residual in the retired pool[0] must NOT be counted in NAV.
        assertLe(vault.totalAssets(),
            usdc.balanceOf(address(vault)) + pool[1].realBalance() + TOL,
            "MA2: retired-adapter residual polluted NAV");
        uint256 navAfterDetach = vault.totalAssets();

        // Recovery: re-attach the fund-holding pool[0] → residual re-enters, no new shares.
        uint256 supplyBefore = vault.totalSupply();
        vm.prank(governance);
        vault.setAdapter(address(pool[0]));      // migrate pool[1]→pool[0] (recall pool[1], deploy into pool[0] which still holds residual)
        assertEq(vault.totalSupply(), supplyBefore, "MA2: dilution on recovery");
        assertGt(vault.totalAssets(), navAfterDetach, "MA2: stranded residual not recovered on re-attach");
        assertApproxEqAbs(vault.totalAssets(), 10_000e6, 2, "MA2: recovery did not restore full principal");
    }

    /// MA3 re-attach old adapter round-trip A→B→A (A keeps funds): accounting restores, no dilution.
    function test_MA3_reattach_oldAdapter_noDilution() public {
        _deposit(alice, 6_000e6);
        _deposit(bob,   4_000e6);
        uint256 aliceSh = vault.balanceOf(alice);
        uint256 bobSh   = vault.balanceOf(bob);

        vm.startPrank(governance);
        vault.setAdapter(address(pool[1]));  // A→B (healthy full recall + redeploy)
        vault.setAdapter(address(pool[0]));  // B→A (healthy full recall + redeploy)
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), aliceSh, "MA3: alice shares changed");
        assertEq(vault.balanceOf(bob),   bobSh,   "MA3: bob shares changed");
        assertApproxEqAbs(vault.totalAssets(), 10_000e6, 2, "MA3: NAV not restored after round-trip");
        assertLe(vault.convertToAssets(vault.totalSupply()), vault.totalAssets() + TOL, "MA3: over-claim");
    }

    /// MA4 migration during fault: a strict migration A→B cannot read a reverting A → reverts
    /// (funds stay safe in A); the operator must force-detach A→0 (best-effort), then attach B
    /// (which reopens deposits). Proves H-01/H-02 consistency across adapters.
    function test_MA4_migrationDuringFault_strictRevert_thenForceDetachRecovers() public {
        _deposit(alice, 10_000e6);
        pool[0].setRevertOnTotalAssets(true);

        // Strict migration away from a reverting adapter is refused (funds not silently stranded).
        vm.prank(governance);
        vm.expectRevert(bytes("FIA: totalAssets reverts"));
        vault.setAdapter(address(pool[1]));

        // Force-detach (best-effort) always works and pauses.
        vm.prank(governance);
        vault.setAdapter(address(0));
        assertTrue(vault.depositsPaused(), "MA4: not paused after unreadable force-detach");

        // Attach a healthy adapter → reopens.
        vm.prank(governance);
        vault.setAdapter(address(pool[1]));
        assertFalse(vault.depositsPaused(), "MA4: pause not cleared on healthy attach");
    }
}
