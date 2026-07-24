// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {DCASpotAccumulator} from "../src/periphery/DCASpotAccumulator.sol";
import {IStableSwapper} from "../src/interfaces/IStableSwapper.sol";
import {IDCAPriceOracle} from "../src/interfaces/IDCAPriceOracle.sol";
import {MockUSDC} from "./SIXXVault.t.sol";

// ─────────────────────────────────────────────────────────────
// Mocks
// ─────────────────────────────────────────────────────────────

/// @dev 18-dec spot target (WETH/WBNB-like). Freely mintable for the swapper reserve.
contract MockTarget is ERC20 {
    constructor() ERC20("Mock Wrapped ETH", "mWETH") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @dev Controllable IDCAPriceOracle. Returns a settable expectedOut, or reverts.
contract MockOracle is IDCAPriceOracle {
    uint256 public out;
    bool public doRevert;
    function set(uint256 out_) external { out = out_; }
    function setRevert(bool r) external { doRevert = r; }
    function expectedOut(address, address, uint256) external view override returns (uint256) {
        require(!doRevert, "ORACLE: forced revert");
        return out;
    }
}

/// @dev Controllable IStableSwapper. Pulls tokenIn from caller, delivers a
///      configurable amount of tokenOut to `to`. Deliberately does NOT enforce
///      minOut itself (so the accumulator's own balance-delta guard is exercised),
///      and can lie about its return value and/or re-enter the accumulator.
contract MockSwapper is IStableSwapper {
    uint256 public mul = 1e12; // amountOut = amountIn * mul / div (USDC 6dec -> 18dec, 1:1 whole)
    uint256 public div = 1;
    uint256 public forcedDeliver = type(uint256).max; // if != max, deliver exactly this
    uint256 public forcedReturn;                       // if != 0, return this instead of delivered

    // re-entrancy attack config
    DCASpotAccumulator public sched;
    uint256 public planId;
    uint256 public keeperMinOut;
    bool public reenter;

    MockTarget public immutable target;
    constructor(MockTarget target_) { target = target_; }

    function setRate(uint256 m, uint256 d) external { mul = m; div = d; }
    function setForcedDeliver(uint256 v) external { forcedDeliver = v; }
    function setForcedReturn(uint256 v) external { forcedReturn = v; }
    function armReentry(DCASpotAccumulator s, uint256 pid, uint256 kmo) external {
        sched = s; planId = pid; keeperMinOut = kmo; reenter = true;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256, address to)
        external
        override
        returns (uint256)
    {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        if (reenter) {
            reenter = false; // one-shot
            sched.execute(planId, keeperMinOut); // must revert (ReentrancyGuard)
        }
        uint256 outAmt = (amountIn * mul) / div;
        uint256 deliver = forcedDeliver == type(uint256).max ? outAmt : forcedDeliver;
        // deliver spot to the user directly (destination fixed by accumulator)
        MockTarget(tokenOut).mint(to, deliver);
        return forcedReturn == 0 ? deliver : forcedReturn;
    }
}

// ─────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────

contract DCASpotAccumulatorUnitTest is Test {
    address governance = makeAddr("governance");
    address guardian   = makeAddr("guardian");
    address feeRcpt    = makeAddr("feeRecipient");
    address keeper     = makeAddr("keeper");
    address alice      = makeAddr("alice");
    address bob        = makeAddr("bob");
    address stranger   = makeAddr("stranger");

    MockUSDC   usdc;
    MockTarget weth;
    MockOracle oracle;
    MockSwapper swapper;
    DCASpotAccumulator acc;

    uint256 constant USDC_1 = 1e6;
    uint256 constant AMOUNT = 100 * USDC_1;   // 100 USDC / run
    uint256 constant INTERVAL = 30 days;
    uint256 constant CAP = 300 * USDC_1;      // 3 runs
    uint256 constant SLIPPAGE = 100;          // 1%
    // At mul=1e12/div=1, 100 USDC -> 100e18 target (mid).
    uint256 constant MID_OUT = 100e18;

    function setUp() public {
        usdc    = new MockUSDC();
        weth    = new MockTarget();
        oracle  = new MockOracle();
        swapper = new MockSwapper(weth);

        acc = new DCASpotAccumulator(governance, guardian, address(swapper), address(oracle), feeRcpt);
        vm.prank(governance);
        acc.setKeeper(keeper, true);

        oracle.set(MID_OUT); // fair expectedOut for a full 100 USDC run

        // Fund alice with USDC and set a BOUNDED allowance.
        usdc.mint(alice, 10_000 * USDC_1);
        vm.prank(alice);
        usdc.approve(address(acc), CAP);
    }

    function _createDefaultPlan() internal returns (uint256 planId) {
        vm.prank(alice);
        planId = acc.createPlan(address(usdc), address(weth), AMOUNT, INTERVAL, 0, 0, CAP, SLIPPAGE);
    }

    // ── createPlan validation ─────────────────────────────────

    function test_createPlan_setsOwnerAndFields() public {
        uint256 id = _createDefaultPlan();
        DCASpotAccumulator.Plan memory p = acc.getPlan(id);
        assertEq(p.owner, alice);
        assertEq(p.stable, address(usdc));
        assertEq(p.target, address(weth));
        assertTrue(p.active);
        assertEq(acc.plansOf(alice)[0], id);
    }

    function test_createPlan_revert_zeroStable() public {
        vm.prank(alice);
        vm.expectRevert("DCA: zero stable");
        acc.createPlan(address(0), address(weth), AMOUNT, INTERVAL, 0, 0, CAP, SLIPPAGE);
    }

    function test_createPlan_revert_zeroTarget() public {
        vm.prank(alice);
        vm.expectRevert("DCA: zero target");
        acc.createPlan(address(usdc), address(0), AMOUNT, INTERVAL, 0, 0, CAP, SLIPPAGE);
    }

    function test_createPlan_revert_sameToken() public {
        vm.prank(alice);
        vm.expectRevert("DCA: stable == target");
        acc.createPlan(address(usdc), address(usdc), AMOUNT, INTERVAL, 0, 0, CAP, SLIPPAGE);
    }

    function test_createPlan_revert_zeroAmount() public {
        vm.prank(alice);
        vm.expectRevert("DCA: zero amount");
        acc.createPlan(address(usdc), address(weth), 0, INTERVAL, 0, 0, CAP, SLIPPAGE);
    }

    function test_createPlan_revert_intervalTooShort() public {
        vm.prank(alice);
        vm.expectRevert("DCA: interval too short");
        acc.createPlan(address(usdc), address(weth), AMOUNT, 59 minutes, 0, 0, CAP, SLIPPAGE);
    }

    function test_createPlan_revert_maxTotalBelowRun() public {
        vm.prank(alice);
        vm.expectRevert("DCA: maxTotal < amountPerRun");
        acc.createPlan(address(usdc), address(weth), AMOUNT, INTERVAL, 0, 0, AMOUNT - 1, SLIPPAGE);
    }

    function test_createPlan_revert_slippageTooHigh() public {
        vm.prank(alice);
        vm.expectRevert("DCA: slippage too high");
        acc.createPlan(address(usdc), address(weth), AMOUNT, INTERVAL, 0, 0, CAP, 501);
    }

    function test_createPlan_revert_endTimeBeforeStart() public {
        vm.prank(alice);
        vm.expectRevert("DCA: endTime <= start");
        acc.createPlan(address(usdc), address(weth), AMOUNT, INTERVAL, block.timestamp + 100, block.timestamp + 50, CAP, SLIPPAGE);
    }

    // ── Happy path + non-custodial invariants ─────────────────

    function test_execute_deliversSpotToOwner_notContractOrKeeper() public {
        uint256 id = _createDefaultPlan();

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(keeper);
        acc.execute(id, 0);

        // Owner received the spot; accumulator/keeper hold nothing.
        assertEq(weth.balanceOf(alice), MID_OUT, "owner got spot");
        assertEq(weth.balanceOf(address(acc)), 0, "accumulator holds no target");
        assertEq(weth.balanceOf(keeper), 0, "keeper holds no target");
        assertEq(usdc.balanceOf(address(acc)), 0, "accumulator holds no stable");

        // Exactly AMOUNT pulled from alice.
        assertEq(aliceUsdcBefore - usdc.balanceOf(alice), AMOUNT, "pulled exactly amountPerRun");

        // Accounting.
        DCASpotAccumulator.Plan memory p = acc.getPlan(id);
        assertEq(p.totalPulled, AMOUNT);
        assertEq(p.totalBought, MID_OUT);
        assertEq(p.nextRun, block.timestamp + INTERVAL);
    }

    function test_execute_revert_notKeeper() public {
        uint256 id = _createDefaultPlan();
        vm.prank(stranger);
        vm.expectRevert("DCA: only keeper");
        acc.execute(id, 0);
    }

    function test_execute_revert_notDue_secondRunSameTime() public {
        uint256 id = _createDefaultPlan();
        vm.prank(keeper);
        acc.execute(id, 0);
        vm.prank(keeper);
        vm.expectRevert("DCA: not due");
        acc.execute(id, 0);
    }

    function test_execute_idempotentAcrossIntervals() public {
        uint256 id = _createDefaultPlan();
        vm.prank(keeper);
        acc.execute(id, 0);
        vm.warp(block.timestamp + INTERVAL);
        vm.prank(keeper);
        acc.execute(id, 0);
        assertEq(weth.balanceOf(alice), 2 * MID_OUT);
    }

    // ── Three-limit cap: maxTotal + final top-up ──────────────

    function test_execute_capEnforced_finalRunTopsUpRemainder() public {
        // maxTotal = 250 USDC, run = 100 -> runs of 100,100,50 then cap.
        vm.prank(alice);
        usdc.approve(address(acc), 250 * USDC_1);
        vm.prank(alice);
        uint256 id = acc.createPlan(address(usdc), address(weth), AMOUNT, INTERVAL, 0, 0, 250 * USDC_1, SLIPPAGE);

        // run 1
        oracle.set(MID_OUT);
        vm.prank(keeper); acc.execute(id, 0);
        // run 2
        vm.warp(block.timestamp + INTERVAL);
        vm.prank(keeper); acc.execute(id, 0);
        // run 3: only 50 USDC remains -> partial pull. oracle mid for 50 USDC = 50e18.
        vm.warp(block.timestamp + INTERVAL);
        oracle.set(50e18);
        vm.prank(keeper); acc.execute(id, 0);

        assertEq(acc.getPlan(id).totalPulled, 250 * USDC_1, "pulled exactly cap");
        assertEq(weth.balanceOf(alice), 250e18);

        // run 4: cap reached.
        vm.warp(block.timestamp + INTERVAL);
        vm.prank(keeper);
        vm.expectRevert("DCA: cap reached");
        acc.execute(id, 0);
    }

    // ── Slippage floor (oracle) + independent delivery re-check ─

    function test_execute_revert_swapperUnderDelivers_belowFloor() public {
        uint256 id = _createDefaultPlan();
        // floor = 100e18 * 9900/10000 = 99e18. Deliver 98e18 -> below floor.
        swapper.setForcedDeliver(98e18);
        vm.prank(keeper);
        vm.expectRevert("DCA: slippage");
        acc.execute(id, 0);
    }

    function test_execute_ok_deliveryExactlyAtFloor() public {
        uint256 id = _createDefaultPlan();
        swapper.setForcedDeliver(99e18); // exactly floor
        vm.prank(keeper);
        acc.execute(id, 0);
        assertEq(weth.balanceOf(alice), 99e18);
    }

    function test_execute_revert_swapperLiesReturnButUnderDelivers() public {
        uint256 id = _createDefaultPlan();
        // Return a huge value but only actually deliver 90e18 (below floor 99e18).
        swapper.setForcedDeliver(90e18);
        swapper.setForcedReturn(1_000e18);
        vm.prank(keeper);
        vm.expectRevert("DCA: slippage"); // balance-delta guard ignores the lie
        acc.execute(id, 0);
    }

    function test_execute_keeperMinOut_canTightenNotLoosen() public {
        uint256 id = _createDefaultPlan();
        // Mid delivery is 100e18. Keeper demands 101e18 (tighter than mid) -> under-delivered vs its own ask.
        vm.prank(keeper);
        vm.expectRevert("DCA: slippage");
        acc.execute(id, 101e18);

        // Keeper passing a LOOSE minOut (below floor) cannot weaken the oracle floor:
        // set swapper to deliver 98e18 (below floor 99e18); keeperMinOut=1 must still revert.
        swapper.setForcedDeliver(98e18);
        vm.prank(keeper);
        vm.expectRevert("DCA: slippage");
        acc.execute(id, 1);
    }

    function test_execute_revert_oracleReverts() public {
        uint256 id = _createDefaultPlan();
        oracle.setRevert(true);
        vm.prank(keeper);
        vm.expectRevert("ORACLE: forced revert");
        acc.execute(id, 0);
    }

    function test_execute_revert_oracleZero() public {
        uint256 id = _createDefaultPlan();
        oracle.set(0);
        vm.prank(keeper);
        vm.expectRevert("DCA: oracle zero");
        acc.execute(id, 0);
    }

    // ── Reentrancy ────────────────────────────────────────────

    function test_execute_reentrancyBlocked() public {
        uint256 id = _createDefaultPlan();
        swapper.armReentry(acc, id, 0);
        // The re-entrant execute() inside swap() must revert; the mock swapper does
        // not swallow it, so the whole tx reverts.
        vm.prank(keeper);
        vm.expectRevert(); // ReentrancyGuard (bubbles up)
        acc.execute(id, 0);
    }

    // ── Fee path ──────────────────────────────────────────────

    function test_execute_feeDeductedBeforeSwap() public {
        vm.prank(governance);
        acc.setPlatformFee(100); // 1%
        uint256 id = _createDefaultPlan();

        // spend = 99 USDC after 1% fee. Oracle mid for 99 USDC = 99e18.
        oracle.set(99e18); // floor = 99e18*0.99 = 98.01e18
        vm.prank(keeper);
        acc.execute(id, 0);

        assertEq(usdc.balanceOf(feeRcpt), 1 * USDC_1, "fee to recipient");
        // swapper delivered 99 USDC * 1e12 = 99e18 to alice.
        assertEq(weth.balanceOf(alice), 99e18);
    }

    // ── User sovereignty ──────────────────────────────────────

    function test_cancelPlan_stopsExecution() public {
        uint256 id = _createDefaultPlan();
        vm.prank(alice);
        acc.cancelPlan(id);
        vm.prank(keeper);
        vm.expectRevert("DCA: inactive plan");
        acc.execute(id, 0);
    }

    function test_cancelPlan_revert_notOwner() public {
        uint256 id = _createDefaultPlan();
        vm.prank(stranger);
        vm.expectRevert("DCA: not plan owner");
        acc.cancelPlan(id);
    }

    function test_userApproveZero_haltsPulls() public {
        uint256 id = _createDefaultPlan();
        vm.prank(alice);
        usdc.approve(address(acc), 0); // user-side unilateral kill switch
        vm.prank(keeper);
        vm.expectRevert(); // ERC20 insufficient allowance
        acc.execute(id, 0);
    }

    // ── executeBatch: skip invalid, process valid ─────────────

    function test_executeBatch_skipsNotDue_processesValid() public {
        uint256 id1 = _createDefaultPlan();
        // second plan for bob, funded/approved
        usdc.mint(bob, 10_000 * USDC_1);
        vm.prank(bob);
        usdc.approve(address(acc), CAP);
        vm.prank(bob);
        uint256 id2 = acc.createPlan(address(usdc), address(weth), AMOUNT, INTERVAL, 0, 0, CAP, SLIPPAGE);

        // run id1 once so it is NOT due; id2 still due.
        vm.prank(keeper); acc.execute(id1, 0);

        uint256[] memory ids = new uint256[](2);
        ids[0] = id1; // not due -> skipped
        ids[1] = id2; // due -> executed
        vm.prank(keeper);
        acc.executeBatch(ids);

        assertEq(weth.balanceOf(bob), MID_OUT, "bob plan executed");
        assertEq(weth.balanceOf(alice), MID_OUT, "alice unchanged (only run 1)");
    }

    function test_executeFromBatch_revert_notSelf() public {
        uint256 id = _createDefaultPlan();
        vm.prank(keeper);
        vm.expectRevert("DCA: only self");
        acc.executeFromBatch(id);
    }

    // ── Pause / roles ─────────────────────────────────────────

    function test_pause_blocksExecuteAndCreate() public {
        uint256 id = _createDefaultPlan();
        vm.prank(guardian);
        acc.pause();
        vm.prank(keeper);
        vm.expectRevert("DCA: paused");
        acc.execute(id, 0);
        vm.prank(alice);
        vm.expectRevert("DCA: paused");
        acc.createPlan(address(usdc), address(weth), AMOUNT, INTERVAL, 0, 0, CAP, SLIPPAGE);
    }

    function test_pause_onlyGovOrGuardian() public {
        vm.prank(stranger);
        vm.expectRevert("DCA: unauthorized");
        acc.pause();
    }

    function test_unpause_onlyGovernance() public {
        vm.prank(guardian);
        acc.pause();
        vm.prank(guardian);
        vm.expectRevert("DCA: only governance");
        acc.unpause();
        vm.prank(governance);
        acc.unpause();
        assertFalse(acc.paused());
    }

    function test_setKeeper_onlyGovernance() public {
        vm.prank(stranger);
        vm.expectRevert("DCA: only governance");
        acc.setKeeper(stranger, true);
    }

    function test_setSwapper_onlyGovernance_and_updates() public {
        MockSwapper s2 = new MockSwapper(weth);
        vm.prank(stranger);
        vm.expectRevert("DCA: only governance");
        acc.setSwapper(address(s2));
        vm.prank(governance);
        acc.setSwapper(address(s2));
        assertEq(address(acc.swapper()), address(s2));
    }

    function test_setOracle_onlyGovernance_and_updates() public {
        MockOracle o2 = new MockOracle();
        vm.prank(governance);
        acc.setOracle(address(o2));
        assertEq(address(acc.oracle()), address(o2));
    }

    function test_setPlatformFee_capEnforced() public {
        vm.prank(governance);
        vm.expectRevert("DCA: fee too high");
        acc.setPlatformFee(501);
    }

    // ── Governance rotation (M-4 2-step) ──────────────────────

    function test_governanceRotation_twoStep() public {
        vm.prank(governance);
        acc.proposeGovernance(bob);
        // old gov still in charge until accept
        vm.prank(bob);
        acc.acceptGovernance();
        assertEq(acc.governance(), bob);
    }

    // ── Rescue ────────────────────────────────────────────────

    function test_rescueToken_onlyGovernance() public {
        vm.prank(stranger);
        vm.expectRevert("DCA: only governance");
        acc.rescueToken(address(usdc), stranger);
    }

    function test_rescueToken_sweepsStray() public {
        usdc.mint(address(acc), 5 * USDC_1); // stray
        vm.prank(governance);
        uint256 amt = acc.rescueToken(address(usdc), governance);
        assertEq(amt, 5 * USDC_1);
        assertEq(usdc.balanceOf(governance), 5 * USDC_1);
    }

}
