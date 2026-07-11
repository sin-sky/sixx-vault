// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {PendlePTAdapter} from "../src/adapters/PendlePTAdapter.sol";
import {IStableSwapper} from "../src/interfaces/IStableSwapper.sol";
import {IPPtOracle, ISUSDeConvert} from "../src/interfaces/IPendleCore.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title PendlePTAdapterForkTest
/// @notice Integration tests for PendlePTAdapter against live Ethereum mainnet
///         state (PT-sUSDe market, expiry 2026-08-13). The REAL Pendle Router
///         and PT TWAP oracle are exercised (buy PT / sell PT / redeem PT / mark);
///         only the USDC<->USDe / sUSDe->USDC leg is mocked, because that leg is
///         the injected `IStableSwapper` — shared infra with Part A, not this
///         adapter's responsibility to prove.
///
///         The test contract plays the role of the vault (adapter.vault == this)
///         so the adapter's own logic is isolated from SIXXVault's
///         `received >= toWithdraw` guard (see PROGRESS_partB escalation #1).
///
///         RPC-gated: setUp self-forks from ETH_RPC_URL (env / .env / CI secret). With no
///         ETH_RPC_URL every test early-returns via `onlyFork` (no-op), so this suite is an
///         OPTIONAL cross-check. The always-on, fork-free regression for M-04 / M-05 is
///         `test/PendlePTAdapterAdversarial.t.sol`.
///
/// Run (requires ETH_RPC_URL in env/.env):
///   forge test --match-contract PendlePTAdapterForkTest -vvv
///   # or explicitly:  forge test --fork-url $ETH_RPC_URL --match-contract PendlePTAdapterForkTest -vvv
contract PendlePTAdapterForkTest is Test {
    using SafeERC20 for IERC20;

    // ─── Mainnet addresses (verified on-chain, T-B1) ───
    address constant USDC     = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDE     = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address constant SUSDE    = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address constant MARKET   = 0x177768caf9D0e036725A51D3f60d7E20F2D4D194;
    address constant PT       = 0x5A19fa369F2895dCD8d2cEE62E4Ceae58eF92BBb;
    address constant ROUTER   = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address constant PTORACLE = 0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2;
    uint256 constant EXPIRY   = 1786579200; // 2026-08-13 00:00:00 UTC
    uint32  constant TWAP     = 900;

    uint256 constant DEPOSIT = 10_000e6; // 10,000 USDC

    address governance = makeAddr("governance");
    address user       = makeAddr("user");

    PendlePTAdapter   adapter;
    MockStableSwapper swapper;

    /// @dev True only when an ETH_RPC_URL is present and the fork is live. When false,
    ///      every test early-returns via `onlyFork` (marked passed-but-empty), so this
    ///      suite is a no-op cross-check that runs ONLY when RPC/secrets are configured
    ///      (`.env` / CI secret ETH_RPC_URL). The always-on regression for the same M-04 /
    ///      M-05 findings lives in the fork-free `PendlePTAdapterAdversarialTest`.
    bool forked;

    function setUp() public {
        string memory url = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            forked = false;
            return;
        }
        vm.createSelectFork(url);
        // Only meaningful on mainnet before the market matures.
        require(block.chainid == 1, "ETH_RPC_URL not ETH mainnet");
        require(block.timestamp < EXPIRY, "fork past market expiry");
        forked = true;

        swapper = new MockStableSwapper();
        // Fund the swapper so it can pay out either side of every swap.
        deal(USDC, address(swapper), 5_000_000e6);
        deal(USDE, address(swapper), 5_000_000e18);
        deal(SUSDE, address(swapper), 5_000_000e18);

        adapter = new PendlePTAdapter(
            USDC, MARKET, ROUTER, PTORACLE, address(swapper), TWAP, address(this), governance
        );
    }

    /// @dev Skip the body unless a live fork was established (RPC-gated).
    modifier onlyFork() {
        if (!forked) return;
        _;
    }

    // ─── helpers ───

    /// @dev Emulate the vault push: transfer USDC to the adapter, then deposit.
    function _deposit(uint256 amt) internal {
        deal(USDC, address(this), amt);
        IERC20(USDC).safeTransfer(address(adapter), amt);
        adapter.deposit(amt);
    }

    // ─────────────────────────────────────────────────────────
    // Deposit: USDC -> USDe -> PT, marked at TWAP
    // ─────────────────────────────────────────────────────────

    function test_Deposit_BuysPT_AndMarksNearPrincipal() public onlyFork {
        _deposit(DEPOSIT);

        uint256 ptBal = IERC20(PT).balanceOf(address(adapter));
        assertGt(ptBal, 0, "no PT bought");

        // PT is a discount bond -> nominal PT count exceeds USDe put in.
        assertGt(ptBal, DEPOSIT * 1e12, "PT should exceed par notional");

        uint256 ta = adapter.totalAssets();
        // Marked value (discounted PT) is below principal but within a few %.
        assertLt(ta, DEPOSIT, "mark should be <= principal (discount)");
        assertGt(ta, (DEPOSIT * 97) / 100, "mark unexpectedly low");
    }

    /// @dev totalAssets() must use the configured 900s TWAP, capped at par, and
    ///      NOT the instantaneous spot. We reproduce the exact accounting formula
    ///      from the oracle and require an exact match.
    function test_TotalAssets_UsesTWAP_CappedAtPar() public onlyFork {
        _deposit(DEPOSIT);
        uint256 ptBal = IERC20(PT).balanceOf(address(adapter));

        uint256 twap = IPPtOracle(PTORACLE).getPtToAssetRate(MARKET, TWAP);
        assertLt(twap, 1e18, "PT TWAP should be a discount pre-maturity");
        uint256 rate = twap > 1e18 ? 1e18 : twap;
        uint256 expected = (ptBal * rate / 1e18) / 1e12; // USDe(18) -> USDC(6), truncated

        assertEq(adapter.totalAssets(), expected, "totalAssets != TWAP-capped mark");
    }

    // ─────────────────────────────────────────────────────────
    // Pre-maturity exit: sell PT on the AMM (market price)
    // ─────────────────────────────────────────────────────────

    function test_PreMaturity_FullExit_ViaAMM() public onlyFork {
        _deposit(DEPOSIT);
        skip(3 days);

        uint256 ta = adapter.totalAssets();
        uint256 got = adapter.withdraw(type(uint256).max, user);

        assertEq(IERC20(USDC).balanceOf(user), got, "recipient mismatch");
        assertApproxEqRel(IERC20(PT).balanceOf(address(adapter)), 0, 1e15, "PT not drained");
        // Early exit realizes near the mark, minus AMM + 2 stable legs slippage.
        assertGt(got, (ta * 98) / 100, "early exit realized too little");
        assertLe(got, ta + 1, "early exit realized above mark");
    }

    function test_PreMaturity_PartialExit() public onlyFork {
        _deposit(DEPOSIT);
        skip(1 days);

        uint256 want = 3_000e6;
        uint256 got = adapter.withdraw(want, user);
        // Partial exit should deliver at least the requested amount (buffer covers
        // slippage) and leave the remaining position invested.
        assertGe(got, want, "partial under-delivered");
        assertGt(IERC20(PT).balanceOf(address(adapter)), 0, "position fully drained on partial");
    }

    // ─────────────────────────────────────────────────────────
    // Post-maturity: redeem PT at par
    // ─────────────────────────────────────────────────────────

    function test_PostMaturity_Redeem_AtPar() public onlyFork {
        _deposit(DEPOSIT);

        // Jump to just after maturity.
        vm.warp(EXPIRY + 1);

        // Post-maturity mark == par (rate 1e18), so totalAssets ~= PT notional.
        uint256 ptBal = IERC20(PT).balanceOf(address(adapter));
        uint256 taPar = adapter.totalAssets();
        assertApproxEqAbs(taPar, ptBal / 1e12, 1, "par mark mismatch");

        uint256 got = adapter.withdraw(type(uint256).max, user);
        assertEq(IERC20(USDC).balanceOf(user), got, "recipient mismatch");
        // Par redemption realizes ~principal (minus only the sUSDe->USDC leg slippage).
        assertGt(got, (DEPOSIT * 99) / 100, "par redeem realized too little");
    }

    function test_Deposit_AfterMaturity_Reverts() public onlyFork {
        vm.warp(EXPIRY + 1);
        deal(USDC, address(this), DEPOSIT);
        IERC20(USDC).safeTransfer(address(adapter), DEPOSIT);
        vm.expectRevert(bytes("ADAPTER: matured"));
        adapter.deposit(DEPOSIT);
    }

    // ─────────────────────────────────────────────────────────
    // Slippage guard
    // ─────────────────────────────────────────────────────────

    function test_Slippage_Revert_OnHaircut() public onlyFork {
        // Tighten to 0 tolerance, then make the stable swapper skim 1%: the
        // USDC->USDe min-out can no longer be met -> deposit reverts.
        vm.prank(governance);
        adapter.setSlippageBps(0);
        swapper.setHaircutBps(100); // 1%

        deal(USDC, address(this), DEPOSIT);
        IERC20(USDC).safeTransfer(address(adapter), DEPOSIT);
        vm.expectRevert(); // MockStableSwapper: min out
        adapter.deposit(DEPOSIT);
    }

    function test_SetSlippage_CapEnforced() public onlyFork {
        vm.prank(governance);
        vm.expectRevert(bytes("ADAPTER: slippage too high"));
        adapter.setSlippageBps(301);
    }

    // ─────────────────────────────────────────────────────────
    // Access control / reentrancy
    // ─────────────────────────────────────────────────────────

    function test_OnlyVault_Deposit() public onlyFork {
        deal(USDC, address(adapter), DEPOSIT);
        vm.prank(user);
        vm.expectRevert(bytes("ADAPTER: only vault"));
        adapter.deposit(DEPOSIT);
    }

    function test_Reentrancy_Blocked() public onlyFork {
        // Deploy an adapter whose "vault" is a malicious swapper that reenters
        // deposit() from inside swap(). onlyVault passes (caller == vault), so the
        // ReentrancyGuard is what must stop it.
        ReentrantSwapper evil = new ReentrantSwapper();
        deal(USDC, address(evil), 1_000_000e6);
        deal(USDE, address(evil), 1_000_000e18);
        deal(SUSDE, address(evil), 1_000_000e18);

        PendlePTAdapter evilAdapter = new PendlePTAdapter(
            USDC, MARKET, ROUTER, PTORACLE, address(evil), TWAP, address(evil), governance
        );
        evil.arm(address(evilAdapter));

        deal(USDC, address(evilAdapter), DEPOSIT);
        vm.expectRevert(); // ReentrancyGuardReentrantCall
        evil.trigger(DEPOSIT);
    }

    function test_Rescue_CannotTouchPositionOrPrincipal() public onlyFork {
        _deposit(DEPOSIT);
        vm.startPrank(governance);
        vm.expectRevert(bytes("ADAPTER: cannot rescue position"));
        adapter.rescueToken(PT, governance);
        vm.expectRevert(bytes("ADAPTER: cannot rescue principal"));
        adapter.rescueToken(USDC, governance);
        vm.stopPrank();
    }

    function test_Metadata() public view onlyFork {
        assertEq(adapter.riskLevel(), 4);
        assertEq(adapter.asset(), USDC);
        assertEq(adapter.expiry(), EXPIRY);
        assertTrue(adapter.isActive());
        uint256 apy = adapter.estimatedAPY();
        // Live implied fixed APY should be a sane single-digit-% (bps).
        assertGt(apy, 100, "APY too low");
        assertLt(apy, 2000, "APY too high");
    }

    // ─────────────────────────────────────────────────────────
    // M-04: deposit must trust the ACTUAL USDe received, not the
    //       swapper's returned value.
    // ─────────────────────────────────────────────────────────

    /// A swapper that pulls the full USDC but delivers (and would report) less USDe than
    /// the par-referenced min-out must not let the adapter size a Pendle leg from the lie.
    /// The balance-delta check reverts the deposit instead.
    function test_M04_deposit_revertsWhenSwapperUnderDelivers() public onlyFork {
        ShortingSwapper evil = new ShortingSwapper();
        evil.setDeliverBps(5_000); // deliver only 50% of USDe, but return the full amount
        deal(USDE, address(evil), 5_000_000e18);

        vm.prank(governance);
        adapter.setSwapper(address(evil));

        deal(USDC, address(this), DEPOSIT);
        IERC20(USDC).safeTransfer(address(adapter), DEPOSIT);
        vm.expectRevert(bytes("ADAPTER: swap shortfall"));
        adapter.deposit(DEPOSIT);
    }

    /// A par-honest swapper (delivers exactly what it returns) still deposits fine — proves
    /// the M-04 delta check does not reject legitimate swaps.
    function test_M04_deposit_okWhenSwapperHonest() public onlyFork {
        _deposit(DEPOSIT);
        assertGt(IERC20(PT).balanceOf(address(adapter)), 0, "honest swap failed to build a position");
    }

    // ─────────────────────────────────────────────────────────
    // M-05: partial exit must survive slippage on BOTH lossy legs.
    // ─────────────────────────────────────────────────────────

    /// With a haircut on the second (sUSDe->USDC) leg equal to the per-leg tolerance, a
    /// partial exit must STILL deliver at least the requested amount — the compounded
    /// two-leg gross-up covers both legs, where a single-leg buffer would under-deliver
    /// and trip the vault's `received >= toWithdraw` guard.
    function test_M05_partialExit_twoLegSlippage_stillDelivers() public onlyFork {
        _deposit(DEPOSIT);
        skip(1 days);

        // Second leg loses a full per-leg tolerance (0.5%) on top of the AMM's own slippage.
        swapper.setHaircutBps(adapter.slippageBps());

        uint256 want = 3_000e6;
        uint256 got = adapter.withdraw(want, user);
        assertGe(got, want, "M-05: partial under-delivered despite two-leg gross-up");
        assertGt(IERC20(PT).balanceOf(address(adapter)), 0, "position fully drained on a partial exit");
    }
}

// ─────────────────────────────────────────────────────────────
// Test-only mocks
// ─────────────────────────────────────────────────────────────

/// @notice Par-rate stablecoin swapper for USDC/USDe/sUSDe used to isolate the
///         adapter from the (shared, injected) production DEX routing. Pays out
///         from balances pre-funded via `deal`. Optional haircut simulates
///         slippage for the min-out revert test.
contract MockStableSwapper is IStableSwapper {
    using SafeERC20 for IERC20;

    address constant USDC  = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDE  = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;

    uint256 public haircutBps;

    function setHaircutBps(uint256 bps) external {
        haircutBps = bps;
    }

    function _rawOut(address tokenIn, address tokenOut, uint256 amountIn) internal view returns (uint256) {
        if (tokenIn == USDC && tokenOut == USDE) return amountIn * 1e12;          // 6 -> 18, par
        if (tokenIn == USDE && tokenOut == USDC) return amountIn / 1e12;          // 18 -> 6, par
        if (tokenIn == SUSDE && tokenOut == USDC) {
            uint256 usde = ISUSDeConvert(SUSDE).convertToAssets(amountIn);        // sUSDe -> USDe (18)
            return usde / 1e12;                                                   // -> USDC (6)
        }
        if (tokenIn == USDC && tokenOut == SUSDE) {
            uint256 usde = amountIn * 1e12;
            uint256 perShare = ISUSDeConvert(SUSDE).convertToAssets(1e18);
            return usde * 1e18 / perShare;
        }
        revert("MockStableSwapper: pair");
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address to)
        external
        returns (uint256 amountOut)
    {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        amountOut = _rawOut(tokenIn, tokenOut, amountIn);
        amountOut = amountOut * (10_000 - haircutBps) / 10_000;
        require(amountOut >= minOut, "MockStableSwapper: min out");
        IERC20(tokenOut).safeTransfer(to, amountOut);
    }
}

/// @notice Swapper that reenters the adapter's deposit() from inside swap().
///         Also acts as the adapter's vault so onlyVault is satisfied and the
///         ReentrancyGuard is the only thing left to block the reentry.
contract ReentrantSwapper is IStableSwapper {
    using SafeERC20 for IERC20;

    address constant USDC  = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDE  = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;

    PendlePTAdapter public adapter;
    bool private _entered;

    function arm(address a) external {
        adapter = PendlePTAdapter(a);
    }

    function trigger(uint256 amt) external {
        adapter.deposit(amt);
    }

    function swap(address tokenIn, address, uint256 amountIn, uint256, address to)
        external
        returns (uint256)
    {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        if (!_entered) {
            _entered = true;
            // Reenter: caller == vault (this), so onlyVault passes; guard must trip.
            adapter.deposit(amountIn);
        }
        uint256 out = amountIn * 1e12; // USDC(6) -> USDe(18) par (only path reached)
        IERC20(USDE).safeTransfer(to, out);
        return out;
    }
}

/// @notice Malicious/faulty swapper for the M-04 test: pulls the full input and RETURNS
///         the honest par amount, but only DELIVERS `deliverBps` of it. Also ignores the
///         min-out, so only the adapter's own balance-delta check can catch the shortfall.
contract ShortingSwapper is IStableSwapper {
    using SafeERC20 for IERC20;

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;

    uint256 public deliverBps = 10_000;

    function setDeliverBps(uint256 bps) external {
        deliverBps = bps;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256, address to)
        external
        returns (uint256 amountOut)
    {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        // Only USDC->USDe is exercised by the deposit path under test.
        amountOut = tokenIn == USDC && tokenOut == USDE ? amountIn * 1e12 : amountIn;
        // Deliver less than reported; return the FULL (honest-looking) amount as the lie.
        IERC20(tokenOut).safeTransfer(to, (amountOut * deliverBps) / 10_000);
    }
}
