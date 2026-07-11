// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PendlePTAdapter} from "../src/adapters/PendlePTAdapter.sol";
import {IStableSwapper} from "../src/interfaces/IStableSwapper.sol";
import {
    IPendleRouter,
    TokenInput,
    TokenOutput,
    ApproxParams,
    LimitOrderData
} from "../src/interfaces/IPendleRouter.sol";
import {MockUSDC} from "./SIXXVault.t.sol";

/// @title PendlePTAdapterAdversarialTest
/// @notice Adversarial, **fork-free** port of the two handoff-audit findings that the
///         PendlePTAdapter's own logic must defend — M-04 (deposit trusts the ACTUAL USDe
///         received, not the swapper's word) and M-05 (a partial exit crosses TWO
///         slippage-bounded legs and must still clear the vault's `received >= toWithdraw`
///         guard). The live Pendle Router / PT TWAP oracle / market are replaced by
///         deterministic mocks so the adapter's guards run under `forge test` with no RPC.
///
///         The fork suite `PendlePTAdapterForkTest` verifies the SAME two findings against
///         the real Pendle contracts; it is the optional, RPC-gated cross-check. This suite
///         is the always-on regression that pins the adapter's balance-delta and two-leg
///         gross-up arithmetic.
///
/// @dev The test contract plays the role of the vault (adapter.vault == this) so the
///      adapter's logic is isolated from SIXXVault's own guards — exactly as the fork suite
///      does (see PROGRESS_partB escalation #1).
///
///      Contract name deliberately omits "Fork" so `forge test --no-match-contract Fork`
///      (the non-fork gate in scripts/contract-audit.sh) runs it.
contract PendlePTAdapterAdversarialTest is Test {
    using SafeERC20 for IERC20;

    // ─── Mock protocol stack ───
    MockUSDC          usdc;   // 6 dec
    Mock18            usde;   // 18 dec
    MockSUSDe         susde;  // 18 dec, convertToAssets rate
    MockPT            pt;     // 18 dec, PT views
    MockSY            sy;
    MockPendleMarket  market;
    MockPtOracle      oracle;
    MockPendleRouter  router;
    MockStableSwapper swapper;

    PendlePTAdapter adapter;

    address governance = makeAddr("governance");
    address user       = makeAddr("user");

    // PT marked at 0.95 USDe/PT (pre-maturity discount); sUSDe worth 1.10 USDe.
    uint256 constant PT_RATE     = 0.95e18;
    uint256 constant SUSDE_RATE  = 1.10e18; // USDe per 1e18 sUSDe
    uint32  constant TWAP        = 900;
    uint256 constant EXPIRY      = 1786579200; // 2026-08-13, far past `block.timestamp==1`
    uint256 constant DEPOSIT     = 10_000e6;

    function setUp() public {
        usdc  = new MockUSDC();
        usde  = new Mock18("Ethena USDe", "USDe");
        susde = new MockSUSDe(SUSDE_RATE);
        pt    = new MockPT(EXPIRY);
        sy    = new MockSY(address(susde), address(usde));
        pt.wire(address(sy)); // PT.SY()/YT() cross-checks in the constructor
        market = new MockPendleMarket(address(sy), address(pt), pt.YT(), EXPIRY);
        oracle = new MockPtOracle(PT_RATE);
        router = new MockPendleRouter(
            address(usde), address(pt), address(susde), PT_RATE, SUSDE_RATE
        );
        swapper = new MockStableSwapper(
            address(usdc), address(usde), address(susde), SUSDE_RATE
        );

        // Fund the swapper so it can pay out either side of every swap.
        usde.mint(address(swapper), 5_000_000e18);
        usdc.mint(address(swapper), 5_000_000e6);
        susde.mint(address(swapper), 5_000_000e18);

        // Vault is `address(this)` so onlyVault is satisfied by the test harness.
        adapter = new PendlePTAdapter(
            address(usdc), address(market), address(router), address(oracle),
            address(swapper), TWAP, address(this), governance
        );
    }

    // ─── helpers ───

    /// @dev Emulate the vault push: transfer USDC to the adapter, then deposit.
    function _deposit(uint256 amt) internal returns (uint256) {
        usdc.mint(address(this), amt);
        IERC20(address(usdc)).safeTransfer(address(adapter), amt);
        return adapter.deposit(amt);
    }

    // ─────────────────────────────────────────────────────────
    // Baseline: honest round trip works against the mock stack.
    // ─────────────────────────────────────────────────────────

    /// A par-honest deposit builds a PT position marked near principal.
    function test_deposit_honest_buildsPositionMarkedNearPrincipal() public {
        _deposit(DEPOSIT);
        assertGt(pt.balanceOf(address(adapter)), 0, "no PT position built");
        // 10,000 USDC in, marked at TWAP (par-capped) -> ~10,000 USDC (truncation only).
        assertApproxEqAbs(adapter.totalAssets(), DEPOSIT, 2, "mark drifted from principal");
    }

    // ─────────────────────────────────────────────────────────
    // M-04: deposit must trust the ACTUAL USDe received (balance delta),
    //       never the swapper's returned/claimed value.
    // ─────────────────────────────────────────────────────────

    /// A swapper that pulls the full USDC but delivers less USDe than the par-referenced
    /// min-out (and ignores min-out entirely) must be caught by the adapter's own
    /// balance-delta check, reverting the deposit rather than sizing a short PT leg.
    function test_M04_deposit_revertsWhenSwapperUnderDelivers() public {
        ShortingSwapper evil = new ShortingSwapper(address(usdc), address(usde));
        evil.setDeliverBps(5_000); // deliver only 50% of the honest USDe amount
        usde.mint(address(evil), 5_000_000e18);

        vm.prank(governance);
        adapter.setSwapper(address(evil));

        usdc.mint(address(this), DEPOSIT);
        IERC20(address(usdc)).safeTransfer(address(adapter), DEPOSIT);
        vm.expectRevert(bytes("ADAPTER: swap shortfall"));
        adapter.deposit(DEPOSIT);
    }

    /// The PT leg is independently protected: a router that under-mints PT (relative to the
    /// adapter's min-out) is caught by the PT balance-delta check, not by trusting the
    /// router's reported `netPtOut`.
    function test_M04_deposit_revertsWhenRouterUnderMintsPt() public {
        router.setPtDeliverBps(5_000); // mint only 50% of the fair PT out

        usdc.mint(address(this), DEPOSIT);
        IERC20(address(usdc)).safeTransfer(address(adapter), DEPOSIT);
        vm.expectRevert(bytes("ADAPTER: pt shortfall"));
        adapter.deposit(DEPOSIT);
    }

    /// A par-honest swapper (delivers exactly the honest amount) deposits fine — proves the
    /// M-04 delta checks do not reject legitimate swaps.
    function test_M04_deposit_okWhenSwapperHonest() public {
        _deposit(DEPOSIT);
        assertGt(pt.balanceOf(address(adapter)), 0, "honest swap failed to build a position");
    }

    // ─────────────────────────────────────────────────────────
    // M-05: a partial exit crosses TWO slippage-bounded legs
    //       (PT->sUSDe, then sUSDe->USDC) and must STILL deliver >= request.
    // ─────────────────────────────────────────────────────────

    /// With BOTH legs losing value — the PT->sUSDe AMM leg takes a small haircut and the
    /// sUSDe->USDC swapper leg loses the full per-leg tolerance — a partial exit must still
    /// deliver at least the requested amount. The compounded (1-slip)^2 gross-up covers both
    /// legs; a single-leg buffer would under-deliver and trip the vault's guard.
    function test_M05_partialExit_twoLegSlippage_stillDelivers() public {
        _deposit(DEPOSIT);

        // Leg 1 (router, PT->sUSDe): a small AMM haircut, as a real market would take.
        router.setLegHaircutBps(2);
        // Leg 2 (swapper, sUSDe->USDC): loses a full per-leg tolerance on top.
        swapper.setHaircutBps(adapter.slippageBps());

        uint256 want = 3_000e6;
        uint256 got = adapter.withdraw(want, user);

        assertGe(got, want, "M-05: partial under-delivered despite two-leg gross-up");
        assertEq(usdc.balanceOf(user), got, "recipient did not receive the delivered USDC");
        assertGt(pt.balanceOf(address(adapter)), 0, "position fully drained on a partial exit");
    }

    /// Control: with a single-leg-sized buffer the SAME two-leg loss WOULD under-deliver.
    /// This pins WHY the compounded gross-up is required rather than an accidental pass.
    /// We reproduce the adapter's arithmetic with a single-leg buffer and show it lands
    /// below `want`, then assert the adapter (two-leg buffer) lands at/above it.
    function test_M05_singleLegBufferWouldUnderDeliver() public {
        _deposit(DEPOSIT);
        uint256 slip = adapter.slippageBps();
        router.setLegHaircutBps(2);
        swapper.setHaircutBps(slip);

        uint256 want = 3_000e6;
        uint256 ptBal = pt.balanceOf(address(adapter));
        uint256 ta = adapter.totalAssets();

        // Single-leg gross-up (the pre-M-05 behaviour): buffer only one leg.
        uint256 slipDenom = 10_000 - slip;
        uint256 singleBuffered = (want * 10_000 + slipDenom - 1) / slipDenom;
        uint256 ptSingle = (ptBal * singleBuffered) / ta;

        // What a single-leg exit of that slice would actually realize through both legs.
        uint256 fairUsde   = (ptSingle * PT_RATE) / 1e18;
        uint256 leg1Susde  = ((fairUsde * 1e18) / SUSDE_RATE) * (10_000 - 2) / 10_000;
        uint256 leg2Usdc   = (((leg1Susde * SUSDE_RATE) / 1e18) / 1e12) * (10_000 - slip) / 10_000;
        assertLt(leg2Usdc, want, "control: single-leg buffer unexpectedly covered both legs");

        // The adapter's two-leg buffer, same conditions, clears the request.
        uint256 got = adapter.withdraw(want, user);
        assertGe(got, want, "two-leg gross-up failed to cover both legs");
    }
}

// ─────────────────────────────────────────────────────────────
// Test-only mock protocol stack (fork-free)
// ─────────────────────────────────────────────────────────────

/// @dev Generic freely-mintable 18-decimal ERC20 (USDe).
contract Mock18 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

/// @dev Minimal StakedUSDeV2 (sUSDe): 18-dec ERC20 with a fixed ERC-4626 rate
///      (USDe per 1e18 sUSDe). Freely mintable so the router can settle exits.
contract MockSUSDe is ERC20 {
    uint256 public rate; // USDe (1e18) per 1e18 sUSDe
    constructor(uint256 rate_) ERC20("Staked USDe", "sUSDe") { rate = rate_; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return (shares * rate) / 1e18;
    }
}

/// @dev Pendle principal token: 18-dec ERC20 + the PT/SY/YT/expiry views the adapter
///      cross-checks at construction. Freely mintable so the router can settle deposits.
contract MockPT is ERC20 {
    uint256 public immutable expiry;
    address public sy;
    address public immutable YT;

    constructor(uint256 expiry_) ERC20("PT sUSDe", "PT") {
        expiry = expiry_;
        YT = address(new DummyYT());
    }
    function wire(address sy_) external { sy = sy_; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
    function SY() external view returns (address) { return sy; }
    function isExpired() external view returns (bool) { return block.timestamp >= expiry; }
}

/// @dev Inert YT placeholder — only its address is referenced.
contract DummyYT {}

/// @dev Pendle SY (SY-sUSDe): yieldToken() = sUSDe, assetInfo().assetAddress = USDe.
contract MockSY {
    address public immutable yieldToken;
    address public immutable usde;
    constructor(address susde_, address usde_) { yieldToken = susde_; usde = usde_; }
    function assetInfo() external view returns (uint8 assetType, address assetAddress, uint8 assetDecimals) {
        return (0, usde, 18);
    }
}

/// @dev Pendle market: readTokens() + expiry() consistency the constructor asserts.
contract MockPendleMarket {
    address public immutable sy;
    address public immutable pt;
    address public immutable yt;
    uint256 public immutable expiry;
    constructor(address sy_, address pt_, address yt_, uint256 expiry_) {
        sy = sy_; pt = pt_; yt = yt_; expiry = expiry_;
    }
    function readTokens() external view returns (address, address, address) { return (sy, pt, yt); }
    function isExpired() external view returns (bool) { return block.timestamp >= expiry; }
}

/// @dev Pendle PT TWAP oracle: fixed PtToAssetRate, oracle always "ready".
contract MockPtOracle {
    uint256 public rate; // PT->USDe, 1e18 = par
    constructor(uint256 rate_) { rate = rate_; }
    function setRate(uint256 r) external { rate = r; }
    function getPtToAssetRate(address, uint32) external view returns (uint256) { return rate; }
    function getOracleState(address, uint32) external pure returns (bool, uint16, bool) {
        return (false, 0, true); // increaseCardinality=false, oldestObservationSatisfied=true
    }
}

/// @dev Pendle Router V4 subset. Deterministic conversions consistent with the oracle
///      rate and the sUSDe rate, so the adapter's min-out / balance-delta guards get an
///      honest counterparty by default. Adversarial knobs:
///        - setPtDeliverBps  : under-mint PT on deposit (M-04 second guard)
///        - setLegHaircutBps : haircut the PT->sUSDe exit leg (M-05 first lossy leg)
contract MockPendleRouter is IPendleRouter {
    using SafeERC20 for IERC20;

    address public immutable usde;
    MockPT   public immutable pt;
    MockSUSDe public immutable susde;
    uint256 public immutable ptRate;    // PT->USDe, 1e18
    uint256 public immutable susdeRate; // USDe per 1e18 sUSDe

    uint256 public ptDeliverBps  = 10_000; // deposit: PT minted vs fair
    uint256 public legHaircutBps = 0;      // exit: haircut on PT->sUSDe

    constructor(address usde_, address pt_, address susde_, uint256 ptRate_, uint256 susdeRate_) {
        usde = usde_; pt = MockPT(pt_); susde = MockSUSDe(susde_);
        ptRate = ptRate_; susdeRate = susdeRate_;
    }

    function setPtDeliverBps(uint256 bps) external { ptDeliverBps = bps; }
    function setLegHaircutBps(uint256 bps) external { legHaircutBps = bps; }

    /// USDe -> PT (buy PT). Pulls USDe from the caller (adapter), mints PT to receiver.
    function swapExactTokenForPt(
        address receiver,
        address /*market*/,
        uint256 /*minPtOut*/,
        ApproxParams calldata /*guess*/,
        TokenInput calldata input,
        LimitOrderData calldata /*limit*/
    ) external payable returns (uint256 netPtOut, uint256, uint256) {
        IERC20(input.tokenIn).safeTransferFrom(msg.sender, address(this), input.netTokenIn);
        uint256 fairPt = (input.netTokenIn * 1e18) / ptRate;
        netPtOut = (fairPt * ptDeliverBps) / 10_000;
        // Honest router enforces its own min-out; the adversarial short is what the
        // adapter's balance-delta check exists to catch, so allow it through here.
        pt.mint(receiver, netPtOut);
        return (netPtOut, 0, 0);
    }

    /// PT -> sUSDe (sell PT, pre-maturity). Pulls PT, delivers sUSDe (less leg haircut).
    function swapExactPtForToken(
        address receiver,
        address /*market*/,
        uint256 exactPtIn,
        TokenOutput calldata output,
        LimitOrderData calldata /*limit*/
    ) external returns (uint256 netTokenOut, uint256, uint256) {
        IERC20(address(pt)).safeTransferFrom(msg.sender, address(this), exactPtIn);
        netTokenOut = _ptToSusde(exactPtIn);
        require(netTokenOut >= output.minTokenOut, "ROUTER: insufficient out");
        susde.mint(receiver, netTokenOut);
        return (netTokenOut, 0, 0);
    }

    /// PT -> sUSDe (redeem, post-maturity par). Pulls PT, delivers sUSDe at par.
    function redeemPyToToken(
        address receiver,
        address /*YT*/,
        uint256 netPyIn,
        TokenOutput calldata output
    ) external returns (uint256 netTokenOut, uint256) {
        IERC20(address(pt)).safeTransferFrom(msg.sender, address(this), netPyIn);
        uint256 fairUsde = netPyIn; // par
        netTokenOut = (fairUsde * 1e18) / susdeRate;
        require(netTokenOut >= output.minTokenOut, "ROUTER: insufficient out");
        susde.mint(receiver, netTokenOut);
        return (netTokenOut, 0);
    }

    function _ptToSusde(uint256 ptIn) internal view returns (uint256) {
        uint256 fairUsde = (ptIn * ptRate) / 1e18;
        uint256 fairSusde = (fairUsde * 1e18) / susdeRate;
        return (fairSusde * (10_000 - legHaircutBps)) / 10_000;
    }
}

/// @dev Par-rate stablecoin swapper for USDC/USDe/sUSDe. Pays from pre-minted balances.
///      Optional haircut simulates the second-leg (sUSDe->USDC) slippage for M-05.
contract MockStableSwapper is IStableSwapper {
    using SafeERC20 for IERC20;

    address public immutable usdc;
    address public immutable usde;
    address public immutable susde;
    uint256 public immutable susdeRate;
    uint256 public haircutBps;

    constructor(address usdc_, address usde_, address susde_, uint256 susdeRate_) {
        usdc = usdc_; usde = usde_; susde = susde_; susdeRate = susdeRate_;
    }

    function setHaircutBps(uint256 bps) external { haircutBps = bps; }

    function _rawOut(address tokenIn, address tokenOut, uint256 amountIn) internal view returns (uint256) {
        if (tokenIn == usdc && tokenOut == usde) return amountIn * 1e12;   // 6 -> 18 par
        if (tokenIn == usde && tokenOut == usdc) return amountIn / 1e12;   // 18 -> 6 par
        if (tokenIn == susde && tokenOut == usdc) {                        // sUSDe -> USDe -> USDC
            return ((amountIn * susdeRate) / 1e18) / 1e12;
        }
        revert("MockStableSwapper: pair");
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address to)
        external
        returns (uint256 amountOut)
    {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        amountOut = _rawOut(tokenIn, tokenOut, amountIn);
        amountOut = (amountOut * (10_000 - haircutBps)) / 10_000;
        require(amountOut >= minOut, "MockStableSwapper: min out");
        IERC20(tokenOut).safeTransfer(to, amountOut);
    }
}

/// @dev Malicious/faulty swapper for M-04: pulls the full input, ignores min-out, and
///      DELIVERS only `deliverBps` of the honest USDe. Only the adapter's own balance-delta
///      check can catch the shortfall (the returned value is a lie the adapter never trusts).
contract ShortingSwapper is IStableSwapper {
    using SafeERC20 for IERC20;

    address public immutable usdc;
    address public immutable usde;
    uint256 public deliverBps = 10_000;

    constructor(address usdc_, address usde_) { usdc = usdc_; usde = usde_; }
    function setDeliverBps(uint256 bps) external { deliverBps = bps; }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256, address to)
        external
        returns (uint256 amountOut)
    {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        // Only USDC->USDe is exercised by the deposit path under test.
        amountOut = (tokenIn == usdc && tokenOut == usde) ? amountIn * 1e12 : amountIn;
        // Deliver less than the (honest-looking) returned amount.
        IERC20(tokenOut).safeTransfer(to, (amountOut * deliverBps) / 10_000);
    }
}
