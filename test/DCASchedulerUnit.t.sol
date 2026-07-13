// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {DCAScheduler} from "../src/periphery/DCAScheduler.sol";
import {MockUSDC} from "./SIXXVault.t.sol";

/// @dev Minimal ERC-4626 vault used as the DCA deposit target. Mirrors the
///      SIXXVault external surface the scheduler depends on: asset() and
///      deposit(assets, receiver) minting shares to `receiver`.
contract Mock4626 is ERC4626 {
    constructor(IERC20 asset_) ERC20("Mock Vault", "mVLT") ERC4626(asset_) {}
}

/// @dev A malicious ERC-4626 whose deposit() re-enters the scheduler to prove
///      the ReentrancyGuard holds. It is itself registered as a keeper so the
///      re-entrant call clears the onlyKeeper gate and can only be stopped by
///      the reentrancy guard.
contract ReentrantVault is ERC4626 {
    DCAScheduler public sched;
    uint256 public targetPlanId;
    bool public attack;

    constructor(IERC20 asset_) ERC20("Reentrant Vault", "rVLT") ERC4626(asset_) {}

    function arm(DCAScheduler sched_, uint256 planId_) external {
        sched = sched_;
        targetPlanId = planId_;
        attack = true;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        if (attack) {
            attack = false; // one-shot
            sched.execute(targetPlanId); // should revert (ReentrancyGuard)
        }
        return super.deposit(assets, receiver);
    }
}

contract DCASchedulerUnitTest is Test {
    // ─── Actors ───────────────────────────────────────────────
    address governance = makeAddr("governance");
    address guardian   = makeAddr("guardian");
    address feeRcpt    = makeAddr("feeRecipient");
    address keeper     = makeAddr("keeper");
    address alice      = makeAddr("alice");
    address bob        = makeAddr("bob");
    address stranger   = makeAddr("stranger");

    MockUSDC      usdc;
    Mock4626      vault;
    DCAScheduler  sched;

    uint256 constant USDC_1 = 1e6;
    uint256 constant AMOUNT = 100 * USDC_1;   // 100 USDC / run
    uint256 constant INTERVAL = 30 days;
    uint256 constant CAP    = 1_200 * USDC_1; // 12 runs

    function setUp() public {
        usdc  = new MockUSDC();
        vault = new Mock4626(IERC20(address(usdc)));

        sched = new DCAScheduler(governance, guardian, feeRcpt);

        vm.prank(governance);
        sched.setKeeper(keeper, true);

        // Alice funds + approves scheduler for a bounded allowance (12 runs).
        usdc.mint(alice, 100_000 * USDC_1);
        vm.prank(alice);
        usdc.approve(address(sched), CAP);
    }

    // ─── helpers ──────────────────────────────────────────────
    function _createAlicePlan() internal returns (uint256 planId) {
        vm.prank(alice);
        planId = sched.createPlan(
            address(usdc), address(vault), AMOUNT, INTERVAL, 0, 0, CAP
        );
    }

    // ═══════════════════════════════════════════════════════════
    // createPlan validation
    // ═══════════════════════════════════════════════════════════

    function test_createPlan_success_setsOwnerAndFields() public {
        uint256 id = _createAlicePlan();
        (address owner_,, address v_, uint256 amt,,,, uint256 cap,,, uint256 nextRun, bool active) =
            sched.plans(id);
        assertEq(owner_, alice);
        assertEq(v_, address(vault));
        assertEq(amt, AMOUNT);
        assertEq(cap, CAP);
        assertEq(nextRun, block.timestamp);
        assertTrue(active);
        uint256[] memory ids = sched.plansOf(alice);
        assertEq(ids.length, 1);
        assertEq(ids[0], id);
    }

    function test_createPlan_reverts_zeroVault() public {
        vm.prank(alice);
        vm.expectRevert("DCA: zero vault");
        sched.createPlan(address(usdc), address(0), AMOUNT, INTERVAL, 0, 0, CAP);
    }

    function test_createPlan_reverts_assetVaultMismatch() public {
        MockUSDC other = new MockUSDC();
        vm.prank(alice);
        vm.expectRevert("DCA: asset/vault mismatch");
        sched.createPlan(address(other), address(vault), AMOUNT, INTERVAL, 0, 0, CAP);
    }

    function test_createPlan_reverts_zeroAmount() public {
        vm.prank(alice);
        vm.expectRevert("DCA: zero amount");
        sched.createPlan(address(usdc), address(vault), 0, INTERVAL, 0, 0, CAP);
    }

    function test_createPlan_reverts_intervalTooShort() public {
        vm.prank(alice);
        vm.expectRevert("DCA: interval too short");
        sched.createPlan(address(usdc), address(vault), AMOUNT, 59 minutes, 0, 0, CAP);
    }

    function test_createPlan_reverts_capBelowAmount() public {
        vm.prank(alice);
        vm.expectRevert("DCA: maxTotal < amountPerRun");
        sched.createPlan(address(usdc), address(vault), AMOUNT, INTERVAL, 0, 0, AMOUNT - 1);
    }

    function test_createPlan_reverts_endBeforeStart() public {
        vm.prank(alice);
        vm.expectRevert("DCA: endTime <= start");
        sched.createPlan(address(usdc), address(vault), AMOUNT, INTERVAL, block.timestamp + 100, block.timestamp + 50, CAP);
    }

    // ═══════════════════════════════════════════════════════════
    // execute — happy path & non-custodial invariants
    // ═══════════════════════════════════════════════════════════

    function test_execute_depositsToOwnerAndSchedulerHoldsNothing() public {
        uint256 id = _createAlicePlan();

        vm.prank(keeper);
        sched.execute(id);

        // Shares minted to alice (the owner), NOT to the scheduler or keeper.
        assertGt(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(address(sched)), 0);
        assertEq(vault.balanceOf(keeper), 0);
        // Scheduler custodies no underlying between txs.
        assertEq(usdc.balanceOf(address(sched)), 0);
        // Exactly AMOUNT pulled from alice.
        assertEq(usdc.balanceOf(alice), 100_000 * USDC_1 - AMOUNT);
        // Underlying assets sit inside the vault.
        assertEq(usdc.balanceOf(address(vault)), AMOUNT);

        (,,,,,,,, uint256 totalDeposited, uint256 totalPulled,,) = sched.plans(id);
        assertEq(totalDeposited, AMOUNT);
        assertEq(totalPulled, AMOUNT);
    }

    function test_execute_onlyKeeper() public {
        uint256 id = _createAlicePlan();
        vm.prank(stranger);
        vm.expectRevert("DCA: only keeper");
        sched.execute(id);
    }

    function test_execute_reverts_notDue_idempotencyWithinPeriod() public {
        uint256 id = _createAlicePlan();
        vm.prank(keeper);
        sched.execute(id);
        // Second call in the same period must revert (no double-pull).
        vm.prank(keeper);
        vm.expectRevert("DCA: not due");
        sched.execute(id);
    }

    function test_execute_succeeds_afterInterval() public {
        uint256 id = _createAlicePlan();
        vm.prank(keeper);
        sched.execute(id);
        vm.warp(block.timestamp + INTERVAL);
        vm.prank(keeper);
        sched.execute(id);
        assertEq(usdc.balanceOf(alice), 100_000 * USDC_1 - 2 * AMOUNT);
    }

    function test_execute_reverts_notStarted() public {
        vm.prank(alice);
        uint256 id = sched.createPlan(
            address(usdc), address(vault), AMOUNT, INTERVAL, block.timestamp + 10 days, 0, CAP
        );
        vm.prank(keeper);
        vm.expectRevert("DCA: not started"); // startTime guard fires before nextRun
        sched.execute(id);
    }

    function test_execute_reverts_afterDeadline() public {
        uint256 end = block.timestamp + 90 days;
        vm.prank(alice);
        uint256 id = sched.createPlan(
            address(usdc), address(vault), AMOUNT, INTERVAL, 0, end, CAP
        );
        vm.warp(end + 1);
        vm.prank(keeper);
        vm.expectRevert("DCA: plan expired");
        sched.execute(id);
    }

    // ═══════════════════════════════════════════════════════════
    // Hard ceilings — keeper cannot exceed user's limits
    // ═══════════════════════════════════════════════════════════

    function test_allowance_isHardCeiling_transferFromReverts() public {
        // Alice approves only a single run, then the plan is created for the full cap.
        vm.prank(alice);
        usdc.approve(address(sched), AMOUNT); // shrink allowance to 1 run
        uint256 id = _createAlicePlan();

        vm.prank(keeper);
        sched.execute(id); // 1st run consumes the whole allowance

        vm.warp(block.timestamp + INTERVAL);
        vm.prank(keeper);
        // 2nd run: allowance exhausted -> ERC20 transferFrom reverts. keeper cannot pull more.
        vm.expectRevert();
        sched.execute(id);
    }

    function test_cap_isHardCeiling_finalPartialTopUp() public {
        // Cap = 250 USDC with 100/run => runs of 100, 100, 50 (partial), then cap reached.
        uint256 cap = 250 * USDC_1;
        vm.prank(alice);
        usdc.approve(address(sched), cap);
        vm.prank(alice);
        uint256 id = sched.createPlan(address(usdc), address(vault), AMOUNT, INTERVAL, 0, 0, cap);

        vm.prank(keeper);
        sched.execute(id); // 100
        vm.warp(block.timestamp + INTERVAL);
        vm.prank(keeper);
        sched.execute(id); // 100
        vm.warp(block.timestamp + INTERVAL);
        vm.prank(keeper);
        sched.execute(id); // 50 (partial top-up to cap)

        (,,,,,,,, uint256 totalDeposited, uint256 totalPulled,,) = sched.plans(id);
        assertEq(totalPulled, cap);
        assertEq(totalDeposited, cap);

        // Next run: cap reached -> revert.
        vm.warp(block.timestamp + INTERVAL);
        vm.prank(keeper);
        vm.expectRevert("DCA: cap reached");
        sched.execute(id);
    }

    // ═══════════════════════════════════════════════════════════
    // User sovereignty — cancel & allowance revocation
    // ═══════════════════════════════════════════════════════════

    function test_cancel_onlyOwner() public {
        uint256 id = _createAlicePlan();
        vm.prank(bob);
        vm.expectRevert("DCA: not plan owner");
        sched.cancelPlan(id);
    }

    function test_cancel_blocksFurtherExecution() public {
        uint256 id = _createAlicePlan();
        vm.prank(alice);
        sched.cancelPlan(id);
        vm.prank(keeper);
        vm.expectRevert("DCA: inactive plan");
        sched.execute(id);
    }

    function test_userAllowanceRevocation_stopsExecution() public {
        uint256 id = _createAlicePlan();
        // User's ultimate kill-switch: revoke allowance directly on the token.
        vm.prank(alice);
        usdc.approve(address(sched), 0);
        vm.prank(keeper);
        vm.expectRevert(); // transferFrom fails — no contract call needed by the user.
        sched.execute(id);
    }

    // ═══════════════════════════════════════════════════════════
    // Reentrancy
    // ═══════════════════════════════════════════════════════════

    function test_execute_reentrancy_blocked() public {
        ReentrantVault rv = new ReentrantVault(IERC20(address(usdc)));
        vm.prank(alice);
        usdc.approve(address(sched), CAP);
        vm.prank(alice);
        uint256 id = sched.createPlan(address(usdc), address(rv), AMOUNT, INTERVAL, 0, 0, CAP);

        // Register the malicious vault as keeper so its re-entrant execute() clears
        // onlyKeeper and can only be stopped by the ReentrancyGuard.
        vm.prank(governance);
        sched.setKeeper(address(rv), true);
        rv.arm(sched, id);

        vm.prank(keeper);
        // Outer execute -> vault.deposit -> re-enters execute -> ReentrancyGuard reverts,
        // bubbling up to revert the whole tx.
        vm.expectRevert();
        sched.execute(id);
    }

    // ═══════════════════════════════════════════════════════════
    // Fees
    // ═══════════════════════════════════════════════════════════

    function test_fee_deductedBeforeDeposit() public {
        vm.prank(governance);
        sched.setPlatformFee(100); // 1%
        uint256 id = _createAlicePlan();

        vm.prank(keeper);
        sched.execute(id);

        uint256 expectedFee = AMOUNT / 100;          // 1%
        uint256 expectedDeposit = AMOUNT - expectedFee;
        assertEq(usdc.balanceOf(feeRcpt), expectedFee);
        assertEq(usdc.balanceOf(address(vault)), expectedDeposit);
        assertEq(usdc.balanceOf(address(sched)), 0);

        (,,,,,,,, uint256 totalDeposited, uint256 totalPulled,,) = sched.plans(id);
        assertEq(totalPulled, AMOUNT);
        assertEq(totalDeposited, expectedDeposit);
    }

    function test_setPlatformFee_reverts_aboveCap() public {
        vm.prank(governance);
        vm.expectRevert("DCA: fee too high");
        sched.setPlatformFee(501);
    }

    function test_setPlatformFee_onlyGovernance() public {
        vm.prank(stranger);
        vm.expectRevert("DCA: only governance");
        sched.setPlatformFee(50);
    }

    // ═══════════════════════════════════════════════════════════
    // Batch execution
    // ═══════════════════════════════════════════════════════════

    function test_executeBatch_processesDue_skipsNotDue() public {
        // Alice: due. Bob: created with future start -> not due (should be skipped).
        uint256 aliceId = _createAlicePlan();

        usdc.mint(bob, 10_000 * USDC_1);
        vm.prank(bob);
        usdc.approve(address(sched), CAP);
        vm.prank(bob);
        uint256 bobId = sched.createPlan(
            address(usdc), address(vault), AMOUNT, INTERVAL, block.timestamp + 10 days, 0, CAP
        );

        uint256[] memory ids = new uint256[](2);
        ids[0] = aliceId;
        ids[1] = bobId;

        vm.prank(keeper);
        sched.executeBatch(ids);

        // Alice executed, Bob skipped (not due).
        assertGt(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), 0);
    }

    function test_executeBatch_skipsFailing_oneBadDoesNotBlockOthers() public {
        // Alice ok. Bob has a plan but zero allowance -> transferFrom fails -> skipped.
        uint256 aliceId = _createAlicePlan();

        usdc.mint(bob, 10_000 * USDC_1);
        // Bob does NOT approve the scheduler.
        vm.prank(bob);
        uint256 bobId = sched.createPlan(address(usdc), address(vault), AMOUNT, INTERVAL, 0, 0, CAP);

        uint256[] memory ids = new uint256[](2);
        ids[0] = bobId;   // fails first
        ids[1] = aliceId; // must still execute
        vm.prank(keeper);
        sched.executeBatch(ids);

        assertGt(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), 0);
    }

    function test_executeFromBatch_notCallableExternally() public {
        uint256 id = _createAlicePlan();
        vm.prank(keeper);
        vm.expectRevert("DCA: only self");
        sched.executeFromBatch(id);
    }

    // ═══════════════════════════════════════════════════════════
    // Access control: keeper / governance / pause
    // ═══════════════════════════════════════════════════════════

    function test_setKeeper_onlyGovernance() public {
        vm.prank(stranger);
        vm.expectRevert("DCA: only governance");
        sched.setKeeper(stranger, true);
    }

    function test_revokedKeeper_cannotExecute() public {
        uint256 id = _createAlicePlan();
        vm.prank(governance);
        sched.setKeeper(keeper, false);
        vm.prank(keeper);
        vm.expectRevert("DCA: only keeper");
        sched.execute(id);
    }

    function test_pause_blocksExecuteAndCreate() public {
        uint256 id = _createAlicePlan();
        vm.prank(guardian);
        sched.pause();

        vm.prank(keeper);
        vm.expectRevert("DCA: paused");
        sched.execute(id);

        vm.prank(alice);
        vm.expectRevert("DCA: paused");
        sched.createPlan(address(usdc), address(vault), AMOUNT, INTERVAL, 0, 0, CAP);

        // governance unpauses -> execute works again.
        vm.prank(governance);
        sched.unpause();
        vm.prank(keeper);
        sched.execute(id);
        assertGt(vault.balanceOf(alice), 0);
    }

    function test_pause_onlyGovernanceOrGuardian() public {
        vm.prank(stranger);
        vm.expectRevert("DCA: unauthorized");
        sched.pause();
    }

    // ═══════════════════════════════════════════════════════════
    // Governance M-4 rotation
    // ═══════════════════════════════════════════════════════════

    function test_governance_2step_rotation() public {
        address newGov = makeAddr("newGov");
        vm.prank(governance);
        sched.proposeGovernance(newGov);
        assertEq(sched.pendingGovernance(), newGov);

        // old gov still in charge until accepted
        assertEq(sched.governance(), governance);

        vm.prank(newGov);
        sched.acceptGovernance();
        assertEq(sched.governance(), newGov);
        assertEq(sched.pendingGovernance(), address(0));
    }

    function test_acceptGovernance_onlyPending() public {
        address newGov = makeAddr("newGov");
        vm.prank(governance);
        sched.proposeGovernance(newGov);
        vm.prank(stranger);
        vm.expectRevert("DCA: not pending governance");
        sched.acceptGovernance();
    }

    // ═══════════════════════════════════════════════════════════
    // Rescue
    // ═══════════════════════════════════════════════════════════

    function test_rescueToken_onlyGovernance_recoversStray() public {
        MockUSDC stray = new MockUSDC();
        stray.mint(address(sched), 5 * USDC_1);

        vm.prank(stranger);
        vm.expectRevert("DCA: only governance");
        sched.rescueToken(address(stray), governance);

        vm.prank(governance);
        uint256 amt = sched.rescueToken(address(stray), governance);
        assertEq(amt, 5 * USDC_1);
        assertEq(stray.balanceOf(governance), 5 * USDC_1);
    }

    function test_isDue_reflectsState() public {
        uint256 id = _createAlicePlan();
        assertTrue(sched.isDue(id));
        vm.prank(keeper);
        sched.execute(id);
        assertFalse(sched.isDue(id)); // nextRun in the future
        vm.warp(block.timestamp + INTERVAL);
        assertTrue(sched.isDue(id));
    }
}
