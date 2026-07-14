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

/// @title Round-8 v2 arbiter F PoC — first-mover skim in the C-1 guard IDLE-ONLY branch via the
///        loss-blind mark burn price (NEW Medium, converged 4-finder, wei-level PoC).
/// @notice The C-1 guard (b835c09) made a reverting valuation take an IDLE-ONLY exit (fromAdapter=0).
///         The payout is the caller's honest idle pro-rata, BUT the partial-fill burn is still
///         `sBurn = _convertToShares(payout)`, which prices shares against `totalAssets()` — and on
///         a reverting valuation that degrades to the loss-blind `_totalDebt` (OVER-stated). So the
///         first idle-only exiter UNDER-burns shares, over-retains a residual, and after force-detach
///         claims MORE than fair — a permanent ~15% skim of the last exiter (ADR-007 柱4 violation:
///         burn must be at the REALIZABLE price to keep per-share value).
contract ExitSkewIdleOnlyBurnPriceFTest is Test {
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

    /// Symmetric 2 holders. Adapter suffers a realized loss; the vault also holds idle (donation /
    /// fee residue / prior partial recall). Valuation then reverts. Two SEQUENTIAL idle-only redeems
    /// followed by governance force-detach + residual redeems. Measure alice (first) vs bob (last).
    function test_F_idleOnly_burnPrice_firstMoverSkim() public {
        uint256 aS = _dep(alice, 10_000 * U);
        uint256 bS = _dep(bob,   10_000 * U);
        assertEq(usdc.balanceOf(address(vault)), 0, "all deployed, idle==0");
        assertEq(aS, bS, "symmetric holders");

        // Realized loss: adapter real backing 20k -> 6k. `_totalDebt` stays 20k (loss-blind).
        adapter.realizeLoss(14_000 * U, sink);
        assertEq(adapter.realBalance(), 6_000 * U, "adapter real = 6k");

        // Idle appears in the vault (3k) — donation / crystallized fee / prior partial recall.
        usdc.mint(address(vault), 3_000 * U);
        assertEq(usdc.balanceOf(address(vault)), 3_000 * U, "idle = 3k");

        // Total realizable = idle 3k + adapter 6k = 9k. Fair per symmetric holder = 4500.
        uint256 fair = 4_500 * U;

        // Oracle breaks: valuation reverts -> idle-only exits.
        adapter.setRevertOnTotalAssets(true);

        // --- Sequential idle-only redeems (partial fills against idle) ---
        vm.prank(alice); uint256 aGot1 = vault.redeem(aS, alice, alice);
        vm.prank(bob);   uint256 bGot1 = vault.redeem(bS, bob, bob);
        emit log_named_uint("alice idle-only got", aGot1);
        emit log_named_uint("bob   idle-only got", bGot1);
        emit log_named_uint("alice residual shares", vault.balanceOf(alice));
        emit log_named_uint("bob   residual shares", vault.balanceOf(bob));

        // --- Governance force-detach releases the adapter's real 6k to idle, writes off debt ---
        adapter.setRevertOnTotalAssets(false); // detach recall needs a readable withdraw path
        vm.prank(governance); vault.setAdapter(address(0));

        // --- Residual redeems against the recovered pool ---
        uint256 aRem = vault.balanceOf(alice);
        uint256 bRem = vault.balanceOf(bob);
        uint256 aGot2; uint256 bGot2;
        if (aRem > 0) { vm.prank(alice); aGot2 = vault.redeem(aRem, alice, alice); }
        if (bRem > 0) { vm.prank(bob);   bGot2 = vault.redeem(bRem, bob, bob); }

        uint256 aTotal = aGot1 + aGot2;
        uint256 bTotal = bGot1 + bGot2;
        emit log_named_uint("=== alice TOTAL", aTotal);
        emit log_named_uint("=== bob   TOTAL", bTotal);
        emit log_named_uint("=== fair each ", fair);

        // Value conserved (no print): total distributed <= 9k realizable.
        assertLe(aTotal + bTotal, 9_000 * U + 3, "no value printed");

        // FIX (F guard): under an unreadable valuation the idle-only exit realizes NOTHING (payout=0,
        //   sBurn=0), so there is NO first-mover skim — both symmetric holders recover their FAIR
        //   pro-rata after force-detach. Pre-fix this test showed alice 4735.96 / bob 4264.04
        //   (skim 471.9 ≈ 10.5%); the guard drives skim to 0 wei and haircut to 0 wei.
        assertEq(aGot1, 0, "F: no partial idle payout under revert (alice)");
        assertEq(bGot1, 0, "F: no partial idle payout under revert (bob)");
        assertEq(vault.balanceOf(alice), 0, "alice fully redeemed after detach");
        assertEq(vault.balanceOf(bob),   0, "bob fully redeemed after detach");

        // SKIM == 0 (wei-level): symmetric stakes -> identical realization, order-independent.
        assertApproxEqAbs(aTotal, bTotal, 3, "SKIM must be 0: first == last for symmetric holders");
        // NO HAIRCUT (wei-level): each recovers ~fair 4500; the whole 9k realizable is distributed,
        //   nothing stranded to the virtual shares.
        assertApproxEqAbs(aTotal, fair, 3, "no haircut: alice ~= fair 4500");
        assertApproxEqAbs(bTotal, fair, 3, "no haircut: bob ~= fair 4500");
        assertApproxEqAbs(aTotal + bTotal, 9_000 * U, 3, "no stranding: full realizable distributed");
    }
}
