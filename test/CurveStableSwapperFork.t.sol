// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {CurveStableSwapper} from "../src/periphery/CurveStableSwapper.sol";
import {PendlePTAdapter} from "../src/adapters/PendlePTAdapter.sol";
import {IStakedUSDeV2} from "../src/interfaces/IStakedUSDeV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title CurveStableSwapperForkTest
/// @notice Exercises the PRODUCTION CurveStableSwapper against live Ethereum
///         mainnet Curve state: each supported leg (USDC<->USDe, sUSDe->USDC,
///         USDC->sUSDe), the on-chain minOut revert, statelessness, and a
///         PendlePTAdapter round-trip driven by the REAL swapper (not the mock).
///
///   Run: forge test --fork-url $ETH_RPC_URL \
///          --fork-block-number 25500331 \
///          --match-contract CurveStableSwapper -vvv
///        (a self-contained createSelectFork fallback pins the block if
///         ETH_RPC_URL is exported, so --match-contract alone also works.)
contract CurveStableSwapperForkTest is Test {
    using SafeERC20 for IERC20;

    // ─── Mainnet addresses (verified on-chain 2026-07-10) ───
    address constant USDC      = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // 6 dec
    address constant USDE      = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3; // 18 dec
    address constant SUSDE     = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497; // 18 dec
    address constant CRVUSD    = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E; // 18 dec
    address constant ENTRYPOOL = 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72; // USDC/USDe
    address constant EXITPOOL1 = 0x57064F49Ad7123C92560882a45518374ad982e85; // sUSDe/crvUSD
    address constant EXITPOOL2 = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E; // USDC/crvUSD

    // ─── PendlePTAdapter (Part B) live refs (PT-sUSDe, expiry 2026-08-13) ───
    address constant MARKET   = 0x177768caf9D0e036725A51D3f60d7E20F2D4D194;
    address constant PT       = 0x5A19fa369F2895dCD8d2cEE62E4Ceae58eF92BBb;
    address constant ROUTER   = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address constant PTORACLE = 0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2;
    uint32  constant TWAP     = 900;

    uint256 constant FORK_BLOCK = 25500331;
    uint256 constant BPS = 10_000;

    CurveStableSwapper swapper;
    address governance = makeAddr("governance");
    address recipient  = makeAddr("recipient");

    // Baseline token balances of the swapper captured right after construction.
    // The deterministic CREATE address can coincidentally hold pre-existing
    // mainnet dust; the swapper's balance-delta accounting ignores it, so we
    // assert the swap adds NO residual (current == baseline) rather than == 0.
    uint256 baseUsdc;
    uint256 baseUsde;
    uint256 baseSusde;
    uint256 baseCrvusd;

    function setUp() public {
        // Self-contained fork (pins the block) when ETH_RPC_URL is set; otherwise
        // rely on the CLI --fork-url and just assert we are on mainnet.
        string memory url = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(url).length > 0) {
            vm.createSelectFork(url, FORK_BLOCK);
        }
        require(block.chainid == 1, "fork ETH mainnet");

        swapper = new CurveStableSwapper(USDC, USDE, SUSDE, CRVUSD, ENTRYPOOL, EXITPOOL1, EXITPOOL2);

        baseUsdc   = IERC20(USDC).balanceOf(address(swapper));
        baseUsde   = IERC20(USDE).balanceOf(address(swapper));
        baseSusde  = IERC20(SUSDE).balanceOf(address(swapper));
        baseCrvusd = IERC20(CRVUSD).balanceOf(address(swapper));
    }

    // ─── helpers ───

    /// @dev Fund `from`=this, approve the swapper, run swap, return output.
    function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        internal
        returns (uint256 out)
    {
        deal(tokenIn, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(swapper), amountIn);
        out = swapper.swap(tokenIn, tokenOut, amountIn, minOut, recipient);
    }

    /// @dev slippage in bps of `out` vs `fair` (0 if out >= fair, i.e. no loss).
    function _slipBps(uint256 fair, uint256 out) internal pure returns (uint256) {
        if (out >= fair) return 0;
        return ((fair - out) * BPS) / fair;
    }

    /// @dev The swap must leave NO residual: every token balance is unchanged
    ///      from the post-construction baseline (input fully consumed, output
    ///      fully forwarded, crvUSD intermediary fully spent).
    function _assertSwapperEmpty() internal view {
        assertEq(IERC20(USDC).balanceOf(address(swapper)),   baseUsdc,   "USDC residual");
        assertEq(IERC20(USDE).balanceOf(address(swapper)),   baseUsde,   "USDe residual");
        assertEq(IERC20(SUSDE).balanceOf(address(swapper)),  baseSusde,  "sUSDe residual");
        assertEq(IERC20(CRVUSD).balanceOf(address(swapper)), baseCrvusd, "crvUSD residual");
    }

    // ─────────────────────────────────────────────────────────
    // Construction: indices derived & bound from live coins()
    // ─────────────────────────────────────────────────────────
    function test_construction_derivesIndices() public view {
        // entry pool = USDe(0)/USDC(1) per PROGRESS route notes.
        assertEq(int256(swapper.entryUsdeIndex()), 0, "USDe idx");
        assertEq(int256(swapper.entryUsdcIndex()), 1, "USDC idx");
        // exit1 = crvUSD(0)/sUSDe(1)
        assertEq(int256(swapper.exit1CrvusdIndex()), 0, "crvUSD idx1");
        assertEq(int256(swapper.exit1SusdeIndex()),  1, "sUSDe idx1");
        // exit2 = USDC(0)/crvUSD(1)
        assertEq(int256(swapper.exit2UsdcIndex()),   0, "USDC idx2");
        assertEq(int256(swapper.exit2CrvusdIndex()), 1, "crvUSD idx2");
    }

    function test_construction_rejectsPoolWithoutToken() public {
        // exitPool2 (USDC/crvUSD) has no USDe → deriving a USDe index reverts.
        vm.expectRevert(bytes("SWAPPER: token not in pool"));
        new CurveStableSwapper(USDC, USDE, SUSDE, CRVUSD, EXITPOOL2, EXITPOOL1, EXITPOOL2);
    }

    // ─────────────────────────────────────────────────────────
    // Leg 1: USDC -> USDe (1 hop)
    // ─────────────────────────────────────────────────────────
    function test_leg_usdc_to_usde() public {
        uint256 amtIn = 10_000e6;
        uint256 fair  = amtIn * 1e12; // par, 6 -> 18 dec
        uint256 out   = _swap(USDC, USDE, amtIn, 0);

        assertEq(IERC20(USDE).balanceOf(recipient), out, "recipient credited");
        uint256 slip = _slipBps(fair, out);
        console2.log("USDC->USDe $10k slippage bps:", slip);
        assertLe(slip, 100, "USDC->USDe slippage > 1%");
        _assertSwapperEmpty();
    }

    // ─────────────────────────────────────────────────────────
    // Leg 2: USDe -> USDC (1 hop)
    // ─────────────────────────────────────────────────────────
    function test_leg_usde_to_usdc() public {
        uint256 amtIn = 10_000e18;
        uint256 fair  = amtIn / 1e12; // par, 18 -> 6 dec
        uint256 out   = _swap(USDE, USDC, amtIn, 0);

        assertEq(IERC20(USDC).balanceOf(recipient), out, "recipient credited");
        uint256 slip = _slipBps(fair, out);
        console2.log("USDe->USDC $10k slippage bps:", slip);
        assertLe(slip, 100, "USDe->USDC slippage > 1%");
        _assertSwapperEmpty();
    }

    // ─────────────────────────────────────────────────────────
    // Leg 3: sUSDe -> USDC (2 hops via crvUSD)
    // ─────────────────────────────────────────────────────────
    function test_leg_susde_to_usdc() public {
        // ~$10k of sUSDe (convertToAssets(1e18) ~ 1.24 USDe).
        uint256 amtIn = IStakedUSDeV2(SUSDE).convertToShares(10_000e18);
        uint256 fairUsde = IStakedUSDeV2(SUSDE).convertToAssets(amtIn);
        uint256 fair     = fairUsde / 1e12; // USDe -> USDC par

        uint256 out = _swap(SUSDE, USDC, amtIn, 0);

        assertEq(IERC20(USDC).balanceOf(recipient), out, "recipient credited");
        uint256 slip = _slipBps(fair, out);
        console2.log("sUSDe->USDC ~$10k slippage bps:", slip);
        assertLe(slip, 100, "sUSDe->USDC slippage > 1%");
        _assertSwapperEmpty();
    }

    // ─────────────────────────────────────────────────────────
    // Leg 4: USDC -> sUSDe (2 hops via crvUSD)
    // ─────────────────────────────────────────────────────────
    function test_leg_usdc_to_susde() public {
        uint256 amtIn = 10_000e6;
        // Fair sUSDe out for $10k: 10_000 USDe worth / assets-per-share.
        uint256 fair = IStakedUSDeV2(SUSDE).convertToShares(10_000e18);

        uint256 out = _swap(USDC, SUSDE, amtIn, 0);

        assertEq(IERC20(SUSDE).balanceOf(recipient), out, "recipient credited");
        uint256 slip = _slipBps(fair, out);
        console2.log("USDC->sUSDe $10k slippage bps:", slip);
        assertLe(slip, 100, "USDC->sUSDe slippage > 1%");
        _assertSwapperEmpty();
    }

    // ─────────────────────────────────────────────────────────
    // minOut enforced on-chain (single hop + two hop)
    // ─────────────────────────────────────────────────────────
    function test_minOut_revert_singleHop() public {
        uint256 amtIn = 10_000e6;
        // Demand 2x par out → unreachable → revert (Curve min_dy).
        deal(USDC, address(this), amtIn);
        IERC20(USDC).forceApprove(address(swapper), amtIn);
        vm.expectRevert();
        swapper.swap(USDC, USDE, amtIn, amtIn * 1e12 * 2, recipient);
    }

    function test_minOut_revert_twoHop() public {
        uint256 amtIn = IStakedUSDeV2(SUSDE).convertToShares(10_000e18);
        uint256 fair  = IStakedUSDeV2(SUSDE).convertToAssets(amtIn) / 1e12;
        deal(SUSDE, address(this), amtIn);
        IERC20(SUSDE).forceApprove(address(swapper), amtIn);
        vm.expectRevert();
        swapper.swap(SUSDE, USDC, amtIn, fair * 2, recipient); // 2x fair → unreachable
    }

    // ─────────────────────────────────────────────────────────
    // Guards: unsupported pair, zero args
    // ─────────────────────────────────────────────────────────
    function test_unsupportedPair_reverts() public {
        deal(USDE, address(this), 1e18);
        IERC20(USDE).forceApprove(address(swapper), 1e18);
        vm.expectRevert(bytes("SWAPPER: unsupported pair"));
        swapper.swap(USDE, SUSDE, 1e18, 0, recipient); // USDe->sUSDe not routed
    }

    function test_zeroAmount_reverts() public {
        vm.expectRevert(bytes("SWAPPER: zero amountIn"));
        swapper.swap(USDC, USDE, 0, 0, recipient);
    }

    function test_zeroRecipient_reverts() public {
        deal(USDC, address(this), 1e6);
        IERC20(USDC).forceApprove(address(swapper), 1e6);
        vm.expectRevert(bytes("SWAPPER: zero to"));
        swapper.swap(USDC, USDE, 1e6, 0, address(0));
    }

    // ─────────────────────────────────────────────────────────
    // Integration: PendlePTAdapter round-trip on the REAL swapper
    // (the vault role is played by this test contract)
    // ─────────────────────────────────────────────────────────
    function test_integration_pendleAdapter_roundTrip() public {
        uint256 DEPOSIT = 10_000e6;

        PendlePTAdapter adapter = new PendlePTAdapter(
            USDC, MARKET, ROUTER, PTORACLE, address(swapper), TWAP, address(this), governance
        );

        // Vault push: fund adapter with USDC, then deposit. USDC ->(swapper)-> USDe
        // ->(Pendle Router)-> PT, all on live state.
        deal(USDC, address(adapter), DEPOSIT);
        adapter.deposit(DEPOSIT);

        assertGt(IERC20(PT).balanceOf(address(adapter)), 0, "no PT bought");
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0, "USDC not fully deployed");
        _assertSwapperEmpty();

        uint256 markedTa = adapter.totalAssets();
        console2.log("totalAssets after $10k deposit (USDC):", markedTa);

        // Full exit: PT ->(Pendle)-> sUSDe ->(swapper 2-hop)-> USDC -> recipient.
        uint256 recBefore = IERC20(USDC).balanceOf(recipient);
        adapter.withdraw(type(uint256).max, recipient);
        uint256 got = IERC20(USDC).balanceOf(recipient) - recBefore;

        console2.log("round-trip USDC returned:", got);
        assertApproxEqRel(IERC20(PT).balanceOf(address(adapter)), 0, 1e15, "PT not drained");
        _assertSwapperEmpty();

        // Pre-maturity round-trip realizes ~deposit minus the PT-to-par discount
        // and two stable legs. Assert we recover within a sane band (>= 98%).
        assertGe(got, (DEPOSIT * 9800) / BPS, "round-trip recovered < 98%");
        // And the adapter reported NAV is realizable (drain >= marked value).
        assertGe(got, (markedTa * 9950) / BPS, "realized well below marked NAV");
    }
}
