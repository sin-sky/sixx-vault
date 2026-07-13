// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {FaultInjectingAdapter} from "./mocks/FaultInjectingAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract M4USDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
    function decimals() public pure override returns (uint8) { return 6; }
}

/// @title M-4 — adversarial code check of the ADR-007 exit path (pre-freeze battery)
/// @notice Confirms on the REAL SIXXVault: (1) the honest partial-fill does NOT degrade the
///         normal-operation happy path (exact to the wei), (2) large × repeated partial exits
///         cannot compound rounding into extractable value (splitting never beats one-shot),
///         (3) NO adapter failure mode reverts a legitimate exit (柱1), whatever the op.
contract ExitAdversarialM4Test is Test {
    uint256 constant U = 1e6;

    address governance   = address(0xBEEF);
    address feeRcpt      = address(0xFEE);
    address guardianAddr = address(0x6042D);

    M4USDC          usdc;
    AdapterRegistry registry;
    SIXXVault       vault;
    FaultInjectingAdapter adapter;

    function _deploy() internal {
        usdc = new M4USDC();
        vm.prank(governance);
        registry = new AdapterRegistry(governance);
        vm.prank(governance);
        vault = new SIXXVault(
            IERC20(address(usdc)), "SIXX Stable Yield", "sxUSDC",
            governance, address(registry), feeRcpt, guardianAddr
        );
        adapter = new FaultInjectingAdapter(address(usdc), address(vault), governance);
        vm.startPrank(governance);
        registry.registerAdapter(address(adapter), "DeFi", "Fault");
        vault.setAdapter(address(adapter));
        vm.stopPrank();
    }

    function _deposit(address who, uint256 amt) internal returns (uint256 shares) {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(vault), amt);
        shares = vault.deposit(amt, who);
        vm.stopPrank();
    }

    // ── (1) HAPPY PATH EXACTNESS — normal operation (idle=0, healthy adapter): the partial-fill
    //        machinery must deliver EXACTLY the ERC-4626 amount and fully burn, to the wei. ──
    function test_M4_happyPath_withdraw_exact() public {
        _deploy();
        address alice = address(0xA11CE);
        _deposit(alice, 1_000 * U);

        uint256 want = 400 * U;
        uint256 expShares = vault.previewWithdraw(want);
        uint256 shBefore = vault.balanceOf(alice);
        uint256 cashBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        uint256 got = vault.withdraw(want, alice, alice);

        assertEq(got, want, "withdraw delivers exactly the requested assets (no 1-wei loss)");
        assertEq(usdc.balanceOf(alice) - cashBefore, want, "cash received is exact");
        assertEq(shBefore - vault.balanceOf(alice), expShares, "burns exactly previewWithdraw shares");
    }

    function test_M4_happyPath_redeem_exact() public {
        _deploy();
        address alice = address(0xA11CE);
        uint256 shares = _deposit(alice, 1_000 * U);

        uint256 exp = vault.previewRedeem(shares);
        uint256 cashBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        uint256 got = vault.redeem(shares, alice, alice);

        assertEq(got, exp, "redeem delivers exactly previewRedeem (no degradation)");
        assertEq(usdc.balanceOf(alice) - cashBefore, exp, "cash received is exact");
        assertEq(vault.balanceOf(alice), 0, "full redeem burns all shares (no dust residual)");
    }

    // ── (2) REPEATED PARTIAL EXITS — the money-pump / theft test. Under a rate-limiting adapter
    //        (delivers 50%/call but destroys NO value — mark decrements only by delivered), an
    //        attacker who splits into many tiny exits must NOT be able to drain more than THEIR
    //        OWN deposit at the expense of a co-holder. Rounding is Ceil-on-burn (protocol-favor),
    //        so it can never compound into extraction of someone else's principal. ──
    function test_M4_repeatedPartial_cannotStealCoHolder() public {
        _deploy();
        address atk = address(0xA11ACC);
        address vic = address(0x7117);
        uint256 aShares = _deposit(atk, 1_000 * U);
        _deposit(vic, 1_000 * U); // total real backing = 2000, no loss (deliverBps only rate-limits)
        adapter.setDeliverBps(5_000);

        // Attacker drains aggressively: 100 tiny redeems + a final sweep of any residual.
        uint256 chunk = aShares / 100;
        uint256 cashBefore = usdc.balanceOf(atk);
        for (uint256 i = 0; i < 100; i++) {
            uint256 bal = vault.balanceOf(atk);
            uint256 r = bal < chunk ? bal : chunk;
            if (r == 0) break;
            vm.prank(atk);
            vault.redeem(r, atk, atk);
        }
        uint256 rem = vault.balanceOf(atk);
        if (rem > 0) { vm.prank(atk); vault.redeem(rem, atk, atk); }
        uint256 atkTotal = usdc.balanceOf(atk) - cashBefore;

        emit log_named_uint("attacker total cash (split-100)", atkTotal);
        // Hard solvency/theft bound: no real value was lost, so a holder can realize AT MOST their
        // own principal. Extracting > deposit would be stealing the co-holder's funds.
        assertLe(atkTotal, 1_000 * U + 5, "split exits cannot drain more than own deposit");
        // And the victim's claim survives: their shares still redeem for a fair remainder.
        assertGt(vault.balanceOf(vic), 0, "co-holder shares intact");
    }

    // ── (3) NEVER-REVERT MATRIX — no adapter failure mode may revert a legit exit (柱1). ──
    function _assertExitNeverReverts(uint8 mode, bool useRedeem) internal {
        _deploy();
        address u = address(0xE0A);
        uint256 shares = _deposit(u, 1_000 * U);

        // Seed idle FIRST (before any fault knob), so there is always SOMETHING to pay even when
        // the adapter later gives nothing. Faithful split: totalAssets unchanged.
        uint256 tvl = vault.totalAssets();
        vm.prank(address(vault));
        adapter.withdraw((tvl * 20) / 100, address(vault));

        // Now inject the failure mode for the actual user exit.
        if (mode == 1) adapter.setDeliverBps(0);          // delivers nothing
        else if (mode == 2) adapter.setDeliverBps(1);     // delivers ~0.01%
        else if (mode == 3) adapter.setRevertOnWithdraw(true);   // withdraw reverts
        else if (mode == 4) adapter.setRevertOnTotalAssets(true); // valuation reverts
        else if (mode == 5) {                              // both revert
            adapter.setRevertOnWithdraw(true);
            adapter.setRevertOnTotalAssets(true);
        }

        uint256 cashBefore = usdc.balanceOf(u);
        if (useRedeem) {
            vm.prank(u);
            vault.redeem(shares, u, u); // must not revert
        } else {
            uint256 mw = vault.maxWithdraw(u);
            if (mw > 0) { vm.prank(u); vault.withdraw(mw, u, u); } // must not revert
        }
        // 柱1: the call returned. Under any liquidity at all, the user took some cash; if the
        // valuation read itself reverts (mode 4/5) totalAssets degrades to _totalDebt and the
        // exit still must not revert.
        assertGe(usdc.balanceOf(u), cashBefore, "exit never reverts and never takes cash away");
    }

    function test_M4_neverReverts_redeem_allModes() public {
        for (uint8 m = 1; m <= 5; m++) _assertExitNeverReverts(m, true);
    }

    function test_M4_neverReverts_withdraw_allModes() public {
        for (uint8 m = 1; m <= 5; m++) _assertExitNeverReverts(m, false);
    }
}
