// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ChainlinkDCAOracle} from "../src/periphery/ChainlinkDCAOracle.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";

/// @dev Fully controllable Chainlink AggregatorV3 mock. `decimals` is fixed at
///      construction; the round tuple is set per test to exercise every guard.
contract MockAggregatorV3 is IAggregatorV3 {
    uint8 internal _decimals;
    uint80 public roundId;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public answeredInRound;

    constructor(uint8 d) {
        _decimals = d;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function set(uint80 roundId_, int256 answer_, uint256 updatedAt_, uint80 answeredInRound_) external {
        roundId = roundId_;
        answer = answer_;
        startedAt = updatedAt_;
        updatedAt = updatedAt_;
        answeredInRound = answeredInRound_;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}

contract ChainlinkDCAOracleUnitTest is Test {
    address governance = makeAddr("governance");
    address stranger   = makeAddr("stranger");

    // Token *keys* only — the oracle never calls the token; decimals are supplied
    // to setFeed. So plain labels suffice.
    address USDC = makeAddr("USDC"); // 6 dec
    address WETH = makeAddr("WETH"); // 18 dec
    address WBTC = makeAddr("WBTC"); // 8 dec

    uint32 constant STALENESS = 1 hours;
    uint256 constant NOW = 1_000_000_000;

    ChainlinkDCAOracle oracle;
    MockAggregatorV3 usdcUsd; // 8 dec, $1
    MockAggregatorV3 ethUsd;  // 8 dec, $2000
    MockAggregatorV3 btcUsd;  // 8 dec, $50000

    function setUp() public {
        vm.warp(NOW);
        oracle = new ChainlinkDCAOracle(governance);

        usdcUsd = new MockAggregatorV3(8);
        ethUsd  = new MockAggregatorV3(8);
        btcUsd  = new MockAggregatorV3(8);

        // Fresh, healthy rounds.
        usdcUsd.set(1, 1e8, NOW, 1);            // $1
        ethUsd.set(1, 2000e8, NOW, 1);          // $2000
        btcUsd.set(1, 50_000e8, NOW, 1);        // $50000

        vm.startPrank(governance);
        oracle.setFeed(USDC, address(usdcUsd), 6, STALENESS);
        oracle.setFeed(WETH, address(ethUsd), 18, STALENESS);
        oracle.setFeed(WBTC, address(btcUsd), 8, STALENESS);
        vm.stopPrank();
    }

    // ── expectedOut: decimals correctness ─────────────────────

    function test_expectedOut_usdcToWeth_18dec() public view {
        // 100 USDC @ $1 / ETH @ $2000 = 0.05 WETH (18 dec).
        uint256 out = oracle.expectedOut(USDC, WETH, 100 * 1e6);
        assertEq(out, 0.05 ether); // 5e16
    }

    function test_expectedOut_usdcToWbtc_8dec() public view {
        // 100 USDC @ $1 / BTC @ $50000 = 0.002 BTC (8 dec) = 200000.
        uint256 out = oracle.expectedOut(USDC, WBTC, 100 * 1e6);
        assertEq(out, 200_000);
    }

    function test_expectedOut_scalesLinearlyWithAmount() public view {
        uint256 a = oracle.expectedOut(USDC, WETH, 100 * 1e6);
        uint256 b = oracle.expectedOut(USDC, WETH, 250 * 1e6);
        assertEq(b, (a * 250) / 100);
    }

    // ── expectedOut: unregistered feeds ───────────────────────

    function test_expectedOut_revert_noFeedIn() public {
        address unknown = makeAddr("unknown");
        vm.expectRevert("ORACLE: no feed in");
        oracle.expectedOut(unknown, WETH, 1e6);
    }

    function test_expectedOut_revert_noFeedOut() public {
        address unknown = makeAddr("unknown");
        vm.expectRevert("ORACLE: no feed out");
        oracle.expectedOut(USDC, unknown, 1e6);
    }

    // ── _readPrice guards (exercised via the IN feed = USDC) ──

    function test_readPrice_revert_nonPositiveAnswer() public {
        usdcUsd.set(2, 0, NOW, 2); // answer == 0
        vm.expectRevert("ORACLE: non-positive price");
        oracle.expectedOut(USDC, WETH, 1e6);
    }

    function test_readPrice_revert_negativeAnswer() public {
        usdcUsd.set(2, -1, NOW, 2);
        vm.expectRevert("ORACLE: non-positive price");
        oracle.expectedOut(USDC, WETH, 1e6);
    }

    function test_readPrice_revert_updatedAtZero() public {
        usdcUsd.set(2, 1e8, 0, 2); // updatedAt == 0 (round not complete)
        vm.expectRevert("ORACLE: round not complete");
        oracle.expectedOut(USDC, WETH, 1e6);
    }

    function test_readPrice_revert_answeredInRoundBehind() public {
        usdcUsd.set(5, 1e8, NOW, 4); // answeredInRound < roundId
        vm.expectRevert("ORACLE: stale round");
        oracle.expectedOut(USDC, WETH, 1e6);
    }

    function test_readPrice_revert_staleByTime() public {
        usdcUsd.set(2, 1e8, NOW - STALENESS - 1, 2); // just past the window
        vm.expectRevert("ORACLE: stale price");
        oracle.expectedOut(USDC, WETH, 1e6);
    }

    function test_readPrice_ok_atStalenessBoundary() public {
        usdcUsd.set(2, 1e8, NOW - STALENESS, 2); // exactly at the edge = still valid
        uint256 out = oracle.expectedOut(USDC, WETH, 100 * 1e6);
        assertEq(out, 0.05 ether);
    }

    function test_readPrice_guardAppliesToOutFeed_too() public {
        // IN healthy, OUT (ETH) stale -> still reverts.
        ethUsd.set(2, 2000e8, NOW - STALENESS - 1, 2);
        vm.expectRevert("ORACLE: stale price");
        oracle.expectedOut(USDC, WETH, 1e6);
    }

    // ── setFeed access control + validation ───────────────────

    function test_setFeed_onlyGovernance() public {
        vm.prank(stranger);
        vm.expectRevert("ORACLE: only governance");
        oracle.setFeed(USDC, address(usdcUsd), 6, STALENESS);
    }

    function test_setFeed_revert_zeroToken() public {
        vm.prank(governance);
        vm.expectRevert("ORACLE: zero token");
        oracle.setFeed(address(0), address(usdcUsd), 6, STALENESS);
    }

    function test_setFeed_revert_zeroAggregator() public {
        vm.prank(governance);
        vm.expectRevert("ORACLE: zero aggregator");
        oracle.setFeed(USDC, address(0), 6, STALENESS);
    }

    function test_setFeed_revert_zeroStaleness() public {
        vm.prank(governance);
        vm.expectRevert("ORACLE: zero staleness");
        oracle.setFeed(USDC, address(usdcUsd), 6, 0);
    }

    function test_setFeed_capturesFeedDecimals() public {
        vm.prank(governance);
        oracle.setFeed(WETH, address(ethUsd), 18, STALENESS);
        (, , uint8 feedDecimals, , bool set) = oracle.feeds(WETH);
        assertTrue(set);
        assertEq(feedDecimals, 8);
    }

    // ── governance rotation (M-4 2-step) ──────────────────────

    function test_governanceRotation_twoStep() public {
        address newGov = makeAddr("newGov");
        vm.prank(governance);
        oracle.proposeGovernance(newGov);
        vm.prank(newGov);
        oracle.acceptGovernance();
        assertEq(oracle.governance(), newGov);
    }
}
