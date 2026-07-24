// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {DCAScheduler} from "../src/periphery/DCAScheduler.sol";
import {MockUSDC} from "./SIXXVault.t.sol";

/// @notice M-1 (integration audit 2026-07-24): regression coverage for the
///         interaction between the canonical SIXXVault `depositCap` (3-C) and the
///         DCAScheduler deposit path. Wires a REAL SIXXVault (not Mock4626) as the
///         DCA target and asserts that when the cap is reached:
///           - a single execute() reverts and fully rolls back (user USDC retained,
///             plan.totalPulled unchanged),
///           - executeBatch() skips the capped plan while other plans still succeed,
///           - raising the cap lets the plan resume.
contract DCASchedulerDepositCapIntegrationTest is Test {
    address governance = makeAddr("governance");
    address guardian   = makeAddr("guardian");
    address feeRcpt    = makeAddr("feeRecipient");
    address keeper     = makeAddr("keeper");
    address alice      = makeAddr("alice");
    address bob        = makeAddr("bob");

    MockUSDC     usdc;
    SIXXVault    cappedVault; // depositCap set below one run
    SIXXVault    openVault;   // depositCap unlimited (default)
    DCAScheduler sched;

    uint256 constant USDC_1 = 1e6;
    uint256 constant AMOUNT = 100 * USDC_1;    // 100 USDC / run
    uint256 constant INTERVAL = 30 days;
    uint256 constant CAP_ALLOWANCE = 1_200 * USDC_1;
    uint256 constant DEPOSIT_CAP = 50 * USDC_1; // below one run → first deposit exceeds

    event ExecutionSkipped(uint256 indexed planId, bytes reason);

    function _newVault(string memory sym) internal returns (SIXXVault v) {
        vm.prank(governance);
        v = new SIXXVault(
            IERC20(address(usdc)), "SIXX Test", sym,
            governance, address(0) /* permissionless registry */, feeRcpt, guardian
        );
    }

    function setUp() public {
        usdc = new MockUSDC();
        cappedVault = _newVault("sxCAP");
        openVault   = _newVault("sxOPEN");

        // 3-C: cap the capped vault below one DCA run.
        vm.prank(governance);
        cappedVault.setDepositCap(DEPOSIT_CAP);

        sched = new DCAScheduler(governance, guardian, feeRcpt);
        vm.prank(governance);
        sched.setKeeper(keeper, true);

        usdc.mint(alice, 100_000 * USDC_1);
        usdc.mint(bob,   100_000 * USDC_1);
        vm.prank(alice);
        usdc.approve(address(sched), CAP_ALLOWANCE);
        vm.prank(bob);
        usdc.approve(address(sched), CAP_ALLOWANCE);
    }

    function _plan(address who, SIXXVault v) internal returns (uint256 id) {
        vm.prank(who);
        id = sched.createPlan(address(usdc), address(v), AMOUNT, INTERVAL, 0, 0, CAP_ALLOWANCE);
    }

    function _totalPulled(uint256 id) internal view returns (uint256 tp) {
        (,,,,,,,, , uint256 totalPulled,,) = sched.plans(id);
        tp = totalPulled;
    }

    // ── single execute reverts + rolls back at cap ────────────

    function test_singleExecute_revertsAndRollsBack_whenCapExceeded() public {
        uint256 id = _plan(alice, cappedVault);
        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(keeper);
        vm.expectRevert(); // OZ ERC4626ExceededMaxDeposit propagates through _execute
        sched.execute(id);

        // Full rollback: no USDC pulled, plan progress unchanged, vault empty.
        assertEq(usdc.balanceOf(alice), aliceBefore, "alice USDC must be retained");
        assertEq(_totalPulled(id), 0, "totalPulled must roll back");
        assertEq(cappedVault.totalAssets(), 0, "capped vault must stay empty");
    }

    // ── executeBatch skips capped plan, others succeed ────────

    function test_executeBatch_skipsCappedPlan_openPlanSucceeds() public {
        uint256 idCapped = _plan(alice, cappedVault);
        uint256 idOpen   = _plan(bob, openVault);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore   = usdc.balanceOf(bob);

        uint256[] memory ids = new uint256[](2);
        ids[0] = idCapped;
        ids[1] = idOpen;

        vm.prank(keeper);
        vm.expectEmit(true, false, false, false, address(sched));
        emit ExecutionSkipped(idCapped, "");
        sched.executeBatch(ids);

        // Capped plan skipped and rolled back.
        assertEq(usdc.balanceOf(alice), aliceBefore, "alice USDC retained (skipped)");
        assertEq(_totalPulled(idCapped), 0, "capped plan did not advance");
        assertEq(cappedVault.totalAssets(), 0, "capped vault empty");

        // Open plan executed normally in the same batch.
        assertEq(usdc.balanceOf(bob), bobBefore - AMOUNT, "bob USDC pulled");
        assertEq(_totalPulled(idOpen), AMOUNT, "open plan advanced");
        assertEq(openVault.totalAssets(), AMOUNT, "open vault funded");
        assertEq(openVault.balanceOf(bob), openVault.previewDeposit(AMOUNT), "bob got shares");
    }

    // ── raising the cap lets the plan resume ──────────────────

    function test_raisingCap_letsPlanResume() public {
        uint256 id = _plan(alice, cappedVault);

        // Blocked at the low cap.
        vm.prank(keeper);
        vm.expectRevert();
        sched.execute(id);

        // Governance raises the cap above one run.
        vm.prank(governance);
        cappedVault.setDepositCap(1_000 * USDC_1);

        vm.prank(keeper);
        sched.execute(id);

        assertEq(_totalPulled(id), AMOUNT, "plan advanced after cap raised");
        assertEq(cappedVault.totalAssets(), AMOUNT, "deposit landed");
        assertEq(cappedVault.balanceOf(alice), cappedVault.previewDeposit(AMOUNT), "alice got shares");
    }

    // ── partial headroom (cap between totalAssets and +1 run) also blocks ──

    function test_partialHeadroomBelowRun_blocks() public {
        // Raise cap to 150 so one run (100) fits, the second (→200) exceeds 150.
        vm.prank(governance);
        cappedVault.setDepositCap(150 * USDC_1);

        uint256 id = _plan(alice, cappedVault);

        vm.prank(keeper);
        sched.execute(id); // run 1 → 100 <= 150 OK
        assertEq(cappedVault.totalAssets(), AMOUNT);

        vm.warp(block.timestamp + INTERVAL);
        vm.prank(keeper);
        vm.expectRevert(); // run 2 → 200 > 150, headroom 50 < 100
        sched.execute(id);

        assertEq(_totalPulled(id), AMOUNT, "second run rolled back");
        assertEq(cappedVault.totalAssets(), AMOUNT, "vault unchanged after blocked run");
    }
}
