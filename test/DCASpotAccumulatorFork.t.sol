// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DCASpotAccumulator} from "../src/periphery/DCASpotAccumulator.sol";
import {UniV3SpotSwapper} from "../src/periphery/UniV3SpotSwapper.sol";
import {ChainlinkDCAOracle} from "../src/periphery/ChainlinkDCAOracle.sol";

/// @title DCASpotAccumulatorForkTest
/// @notice Integration test against LIVE Ethereum mainnet: buys real WETH with real
///         USDC through the real Uniswap V3 SwapRouter, priced/floored by real
///         Chainlink feeds. Proves the non-custodial spot-DCA round trip end to end —
///         the accumulator pulls a bounded amount of the user's real USDC, swaps it,
///         and the USER (not the accumulator, not the keeper) ends up holding the WETH.
///
/// @dev Requires --fork-url $ETH_RPC_URL. Run isolated:
///        forge test --fork-url $ETH_RPC_URL --match-contract DCASpotAccumulatorForkTest -vvv
contract DCASpotAccumulatorForkTest is Test {
    // ── Ethereum mainnet ──────────────────────────────────────
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // 6 dec
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // 18 dec
    address internal constant UNIV3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564; // SwapRouter (has deadline)
    uint24  internal constant FEE_005 = 500; // USDC/WETH 0.05% pool

    address internal constant CL_ETH_USD  = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // 8 dec
    address internal constant CL_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6; // 8 dec

    address governance = makeAddr("governance");
    address guardian   = makeAddr("guardian");
    address feeRcpt    = makeAddr("feeRecipient");
    address keeper     = makeAddr("keeper");
    address alice      = makeAddr("aliceForkSpot");

    IERC20 usdc = IERC20(USDC);
    IERC20 weth = IERC20(WETH);

    ChainlinkDCAOracle oracle;
    UniV3SpotSwapper   swapper;
    DCASpotAccumulator acc;

    uint256 constant USDC_1   = 1e6;
    uint256 constant AMOUNT   = 100 * USDC_1; // 100 USDC / run
    // Short interval on purpose: this fork test warps time to prove periodicity, but
    // a fork cannot advance the Chainlink feed's updatedAt, so a long warp would look
    // "stale" (an artifact that never happens in production, where wall-clock advances
    // AND the feed keeps updating). 1h keeps the warped read within the staleness window.
    uint256 constant INTERVAL = 1 hours;
    uint256 constant CAP      = 300 * USDC_1; // 3 runs
    uint256 constant SLIPPAGE = 200;          // 2% (Chainlink mid vs pool + 0.05% fee headroom)

    function setUp() public {
        require(block.chainid == 1, "fork ETH mainnet");

        // Oracle: register USDC/USD and ETH/USD feeds with generous staleness for the pin.
        oracle = new ChainlinkDCAOracle(governance);
        vm.startPrank(governance);
        oracle.setFeed(USDC, CL_USDC_USD, 6, 2 days);
        oracle.setFeed(WETH, CL_ETH_USD, 18, 2 days);
        vm.stopPrank();

        // Swapper: real Uniswap V3 router, route USDC->WETH via the 0.05% pool.
        swapper = new UniV3SpotSwapper(UNIV3_ROUTER, governance);
        vm.prank(governance);
        swapper.setRoute(USDC, WETH, FEE_005);

        // Accumulator wired to the real swapper + oracle.
        acc = new DCASpotAccumulator(governance, guardian, address(swapper), address(oracle), feeRcpt);
        vm.prank(governance);
        acc.setKeeper(keeper, true);

        // Fund alice with real USDC and set a BOUNDED allowance.
        deal(USDC, alice, 10_000 * USDC_1);
        vm.prank(alice);
        usdc.approve(address(acc), CAP);
    }

    function test_fork_oracleReturnsSaneEthPerUsdc() public view {
        // 100 USDC should buy on the order of 0.02-0.06 WETH depending on ETH price.
        uint256 exp = oracle.expectedOut(USDC, WETH, AMOUNT);
        assertGt(exp, 0.005 ether, "expected WETH too low (ETH price sanity)");
        assertLt(exp, 1 ether, "expected WETH too high (ETH price sanity)");
    }

    function test_fork_spotBuy_userHoldsWethNotAccumulator() public {
        vm.prank(alice);
        uint256 planId = acc.createPlan(USDC, WETH, AMOUNT, INTERVAL, 0, 0, CAP, SLIPPAGE);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 aliceWethBefore = weth.balanceOf(alice); // 0
        uint256 expected = oracle.expectedOut(USDC, WETH, AMOUNT);

        // ── Run 1 ──
        vm.prank(keeper);
        acc.execute(planId, 0);

        // Exactly AMOUNT of USDC pulled from alice.
        assertEq(aliceUsdcBefore - usdc.balanceOf(alice), AMOUNT, "pulled exactly amountPerRun");

        // WETH delivered to ALICE, never held by the accumulator or keeper (non-custodial).
        uint256 bought = weth.balanceOf(alice) - aliceWethBefore;
        assertGt(bought, 0, "alice received WETH");
        assertGe(bought, (expected * (10_000 - SLIPPAGE)) / 10_000, "above oracle slippage floor");
        assertEq(weth.balanceOf(address(acc)), 0, "accumulator holds no WETH");
        assertEq(weth.balanceOf(keeper), 0, "keeper holds no WETH");
        assertEq(usdc.balanceOf(address(acc)), 0, "accumulator holds no USDC");
        assertEq(usdc.balanceOf(address(swapper)), 0, "swapper holds no USDC dust");

        // Accounting.
        DCASpotAccumulator.Plan memory p = acc.getPlan(planId);
        assertEq(p.totalPulled, AMOUNT);
        assertEq(p.totalBought, bought);
        assertEq(p.nextRun, block.timestamp + INTERVAL);

        // ── Run 2 (after interval) — proves periodic accumulation ──
        vm.warp(block.timestamp + INTERVAL);
        vm.prank(keeper);
        acc.execute(planId, 0);
        assertGt(weth.balanceOf(alice), bought, "second run accumulated more WETH");
        assertEq(acc.getPlan(planId).totalPulled, 2 * AMOUNT);
    }

    function test_fork_userCanCancelAndKeepControl() public {
        vm.prank(alice);
        uint256 planId = acc.createPlan(USDC, WETH, AMOUNT, INTERVAL, 0, 0, CAP, SLIPPAGE);
        vm.prank(alice);
        acc.cancelPlan(planId);
        vm.prank(keeper);
        vm.expectRevert("DCA: inactive plan");
        acc.execute(planId, 0);
        // Alice's USDC never left her wallet.
        assertEq(usdc.balanceOf(alice), 10_000 * USDC_1);
    }
}
