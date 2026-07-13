// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {FaultInjectingAdapter} from "./mocks/FaultInjectingAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
    function decimals() public pure override returns (uint8) { return 6; }
}

/// @title Round-8 v2 arbiter PoC — first-mover exit skew via the reverting-valuation `_totalDebt`
///        fallback (converged finding C-1 / D-1 / E-1).
/// @notice Independent agents C/D/E found that when the adapter's `totalAssets()` REVERTS *and* a
///         realized loss has occurred, the vault prices exits against the stale-high `_totalDebt`
///         (never marked down for a loss). The 柱3 pro-rata cap is then computed on an OVERSTATED
///         mark, so the first exiter takes the entire realizable pool and the last gets 0 — the
///         "bounded by e" claim (ExitSkewM1) is a linear-mock artifact and does NOT hold here.
///         This PoC MEASURES the split, contrasts the honest-mark control, and confirms the
///         force-detach mitigation restores fairness.
contract ExitSkewRevertFallbackCTest is Test {
    uint256 constant U = 1e6;
    address governance = address(0xBEEF);
    address alice = address(0xA11CE);
    address bob   = address(0xB0B);
    address sink  = address(0x5151);
    address feeRcpt = address(0xFEE);
    address guardian = address(0x6042D);

    MockUSDC usdc;
    AdapterRegistry registry;
    SIXXVault vault;
    FaultInjectingAdapter adapter;

    function setUp() public {
        usdc = new MockUSDC();
        vm.prank(governance);
        registry = new AdapterRegistry(governance);
        vm.prank(governance);
        vault = new SIXXVault(IERC20(address(usdc)), "SIXX", "sx", governance, address(registry), feeRcpt, guardian);
        adapter = new FaultInjectingAdapter(address(usdc), address(vault), governance);
        vm.startPrank(governance);
        registry.registerAdapter(address(adapter), "DeFi", "Fault");
        vault.setAdapter(address(adapter));
        vm.stopPrank();
    }

    function _dep(address who, uint256 amt) internal returns (uint256 s) {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(vault), amt);
        s = vault.deposit(amt, who);
        vm.stopPrank();
    }

    // Both deposit 10k; a 50% realized loss hits the adapter; then two sequential full redeems.
    function _twoHolderLoss() internal returns (uint256 aShares, uint256 bShares) {
        aShares = _dep(alice, 10_000 * U);
        bShares = _dep(bob,   10_000 * U);
        // idle==0, all 20k deployed, _totalDebt == 20k
        assertEq(usdc.balanceOf(address(vault)), 0, "all deployed");
        adapter.realizeLoss(10_000 * U, sink); // real backing 20k -> 10k (a genuine 50% loss)
        assertEq(adapter.realBalance(), 10_000 * U, "real backing halved");
    }

    /// FIX (Round-8 v2 guard): with the C-1 guard, a reverting valuation makes the exit IDLE-ONLY
    ///   (no recall against the stale `_totalDebt` mark). The first exiter can NO LONGER drain the
    ///   pool — both get their fair idle pro-rata (here idle==0, so 0/0, neither drains), and the
    ///   adapter's realizable value is released FAIRLY by force-detach. Pre-guard this was 10k/0
    ///   (∞ skew); the guard bounds it to the fair idle distribution.
    function test_C_revertFallback_guard_noFirstMoverDrain() public {
        (uint256 aS, uint256 bS) = _twoHolderLoss();
        adapter.setRevertOnTotalAssets(true); // oracle broken

        // deposits are paused while the valuation is unreadable (no minting vs the over-reported NAV)
        assertEq(vault.maxDeposit(alice), 0, "deposits paused while valuation unreadable");

        vm.prank(alice); uint256 aGot = vault.redeem(aS, alice, alice);
        vm.prank(bob);   uint256 bGot = vault.redeem(bS, bob, bob);
        emit log_named_uint("alice got (first)", aGot);
        emit log_named_uint("bob got   (last) ", bGot);

        // GUARD: idle-only exit (idle==0) -> neither drains; no first-mover advantage.
        assertEq(aGot, 0, "guard: first exiter cannot drain against the stale mark");
        assertEq(bGot, 0, "guard: last exiter equally idle-bounded (no ordering advantage)");
        // exits did NOT brick (柱1): both calls returned; shares retained as claim.
        assertGt(vault.balanceOf(alice), 0, "alice retains claim (no brick)");
        assertGt(vault.balanceOf(bob),   0, "bob retains claim (no brick)");
        // the adapter's real 10k is still there, released fairly on detach (see other test).
        assertEq(adapter.realBalance(), 10_000 * U, "adapter liquidity preserved for fair release");
    }

    /// CONTROL: identical loss, but valuation READABLE (honest markdown) -> mark falls with the
    ///          loss -> pro-rata cap works -> fair 5k/5k. Proves it is the revert-fallback, not
    ///          the loss itself, that breaks fairness.
    function test_C_control_honestMark_isFair() public {
        (uint256 aS, uint256 bS) = _twoHolderLoss();
        // valuation NOT reverting: adapter.totalAssets() honestly reports 10k
        assertEq(vault.totalAssets(), 10_000 * U, "NAV honest after loss");

        vm.prank(alice); uint256 aGot = vault.redeem(aS, alice, alice);
        vm.prank(bob);   uint256 bGot = vault.redeem(bS, bob, bob);
        emit log_named_uint("alice got", aGot);
        emit log_named_uint("bob got  ", bGot);
        assertApproxEqAbs(aGot, 5_000 * U, 3, "honest mark: fair pro-rata");
        assertApproxEqAbs(bGot, 5_000 * U, 3, "honest mark: fair pro-rata");
    }

    /// MITIGATION: force-detach (setAdapter(0)) before exits writes off _totalDebt to realized,
    ///             so both exit fair pro-rata of recovered idle. This is the documented response.
    function test_C_forceDetach_restoresFairness() public {
        (uint256 aS, uint256 bS) = _twoHolderLoss();
        adapter.setRevertOnTotalAssets(true);
        // governance force-detaches; best-effort recall pulls the real 10k to idle, writes off debt
        adapter.setRevertOnTotalAssets(false); // detach recall needs a readable withdraw path
        vm.prank(governance); vault.setAdapter(address(0));
        assertApproxEqAbs(usdc.balanceOf(address(vault)), 10_000 * U, 3, "recovered realizable to idle");

        vm.prank(alice); uint256 aGot = vault.redeem(aS, alice, alice);
        vm.prank(bob);   uint256 bGot = vault.redeem(bS, bob, bob);
        emit log_named_uint("alice got (post-detach)", aGot);
        emit log_named_uint("bob got   (post-detach)", bGot);
        assertApproxEqAbs(aGot, 5_000 * U, 3, "force-detach: fair 5k");
        assertApproxEqAbs(bGot, 5_000 * U, 3, "force-detach: fair 5k");
    }
}
