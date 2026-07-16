// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {PendlePTAdapter} from "../src/adapters/PendlePTAdapter.sol";
import {IStableSwapper} from "../src/interfaces/IStableSwapper.sol";
import {ISUSDeConvert} from "../src/interfaces/IPendleCore.sol";

/// @title PendlePTAdapterLoadedSlippageForkTest
/// @notice Closes escalate#1 review gaps ①/③ (and touches ②). The existing vault-fork
///         suite (`PendlePTAdapterVaultForkTest`) prices the injected sUSDe->USDC leg at
///         PAR / zero-impact, so the CORE escalate#1 claim was never actually stressed:
///
///           "a full recall / setAdapter migration FAILS CLOSED (reverts, no funds move)
///            when the market cannot realize the haircut NAV — the vault's M13-16 guard
///            (`received >= toWithdraw` / `received >= adapterBal`) is never silently shorted."
///
///         Here the injected swapper applies a slippage on the FINAL sUSDe->USDC hop that
///         EXCEEDS `recallHaircutBps`, and every exit path (full redeem / partial withdraw /
///         setAdapter(0) / setAdapter migration) is asserted to fail-close through the REAL
///         SIXXVault guard with ZERO state change (no USDC to the user, shares intact, PT
///         intact, adapter still attached). A par control (slip=0) proves the failure is
///         caused specifically by the slippage exceeding the haircut, not by the harness.
///
///         gap ② tie-in: even at the hard `MAX_RECALL_HAIRCUT_BPS = 300` (3%) cap, a
///         deep-slippage market still fail-closes — the cap cannot rescue liquidity, so the
///         haircut must be matched to the realizable round-trip for the bound position size
///         (see docs/operations/pendle-haircut-calibration.md).
///
/// Run:
///   forge test --fork-url $ETH_RPC_URL --fork-block-number 25500309 \
///     --match-contract PendlePTAdapterLoadedSlippageForkTest -vvv
contract PendlePTAdapterLoadedSlippageForkTest is Test {
    using SafeERC20 for IERC20;

    // ─── Mainnet addresses (same as PendlePTAdapterVaultForkTest) ───
    address constant USDC     = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDE     = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address constant SUSDE    = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address constant MARKET   = 0x177768caf9D0e036725A51D3f60d7E20F2D4D194;
    address constant PT       = 0x5A19fa369F2895dCD8d2cEE62E4Ceae58eF92BBb;
    address constant ROUTER   = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address constant PTORACLE = 0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2;
    uint256 constant EXPIRY   = 1786579200; // 2026-08-13 00:00:00 UTC
    uint32  constant TWAP     = 900;
    uint256 constant FORK_BLOCK = 25_500_309;

    uint256 constant DEPOSIT       = 50_000e6; // 50,000 USDC
    uint256 constant DEFAULT_HAIRCUT = 50;     // 0.5% (adapter default)
    uint256 constant MAX_HAIRCUT     = 300;    // 3% (MAX_RECALL_HAIRCUT_BPS)
    // 25% impact on the floored sUSDe->USDC leg — far above any allowed haircut (<=3%),
    // so the end-to-end floor can never be met and the exit must fail-close.
    uint256 constant DEEP_SLIP_BPS = 2_500;

    address governance   = makeAddr("governance");
    address feeRecipient = makeAddr("feeRecipient");
    address guardian     = makeAddr("guardian");
    address user         = makeAddr("user");

    AdapterRegistry  registry;
    SIXXVault        vault;
    PendlePTAdapter  adapter;
    LoadedExitSwapper swapper;
    bool forked;

    function setUp() public {
        string memory url = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(url).length == 0) { forked = false; return; }
        vm.createSelectFork(url, FORK_BLOCK);
        require(block.chainid == 1, "fork ETH mainnet");
        require(block.timestamp < EXPIRY, "fork before expiry");
        forked = true;
    }

    modifier onlyFork() {
        if (!forked) return;
        _;
    }

    /// @dev Build a fresh vault + adapter whose injected swapper applies `exitSlipBps`
    ///      slippage to the sUSDe->USDC leg, and set `haircutBps` on the adapter.
    function _deploy(uint256 exitSlipBps, uint256 haircutBps) internal {
        swapper = new LoadedExitSwapper(exitSlipBps);
        deal(USDC, address(swapper), 20_000_000e6);
        deal(USDE, address(swapper), 20_000_000e18);
        deal(SUSDE, address(swapper), 20_000_000e18);

        registry = new AdapterRegistry(governance);
        vault = new SIXXVault(
            IERC20(USDC), "SIXX Fixed Yield - PT-sUSDe", "sxPT",
            governance, address(registry), feeRecipient, guardian
        );
        adapter = new PendlePTAdapter(
            USDC, MARKET, ROUTER, PTORACLE, address(swapper), TWAP, address(vault), governance
        );

        vm.startPrank(governance);
        registry.registerAdapter(address(adapter), "DeFi", "Pendle (PT-sUSDe / Ethena)");
        vault.setAdapter(address(adapter));
        if (haircutBps != DEFAULT_HAIRCUT) adapter.setRecallHaircutBps(haircutBps);
        vm.stopPrank();
    }

    function _userDeposit(uint256 amt) internal {
        deal(USDC, user, amt);
        vm.startPrank(user);
        IERC20(USDC).forceApprove(address(vault), amt);
        vault.deposit(amt, user);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────
    // Control: par exit leg (slip=0) → full redeem SUCCEEDS.
    // Proves the fail-close below is caused by the slippage, not the harness.
    // ─────────────────────────────────────────────────────────
    function test_control_parExit_fullRedeem_succeeds() public onlyFork {
        _deploy(0, DEFAULT_HAIRCUT);
        _userDeposit(DEPOSIT);
        skip(2 days);

        uint256 shares = vault.balanceOf(user);
        uint256 navBefore = vault.totalAssets();
        vm.prank(user);
        uint256 assetsOut = vault.redeem(shares, user, user);

        assertGe(assetsOut, navBefore, "control: realized below reported NAV");
        assertGt(assetsOut, 0, "control: nothing withdrawn");
    }

    // ─────────────────────────────────────────────────────────
    // ① Full redeem fail-close (default haircut) — guard: received >= toWithdraw
    // ─────────────────────────────────────────────────────────
    function test_fullRedeem_loadedSlippage_failClose() public onlyFork {
        _deploy(DEEP_SLIP_BPS, DEFAULT_HAIRCUT);
        _userDeposit(DEPOSIT);
        skip(2 days);

        uint256 shares  = vault.balanceOf(user);
        uint256 navPre  = vault.totalAssets();
        uint256 ptPre   = IERC20(PT).balanceOf(address(adapter));

        vm.prank(user);
        vm.expectRevert(); // swapper min-out floor unmet → whole exit reverts
        vault.redeem(shares, user, user);

        // Fail-close: nothing moved.
        assertEq(IERC20(USDC).balanceOf(user), 0, "user received USDC on a fail-close");
        assertEq(vault.balanceOf(user), shares, "shares burned on a fail-close");
        assertEq(IERC20(PT).balanceOf(address(adapter)), ptPre, "PT moved on a fail-close");
        assertEq(vault.totalAssets(), navPre, "NAV changed on a fail-close");
    }

    // ─────────────────────────────────────────────────────────
    // ③ Partial withdraw fail-close — partial recall path (minUsdcOut = targetFromPt)
    // ─────────────────────────────────────────────────────────
    function test_partialWithdraw_loadedSlippage_failClose() public onlyFork {
        _deploy(DEEP_SLIP_BPS, DEFAULT_HAIRCUT);
        _userDeposit(DEPOSIT);
        skip(1 days);

        uint256 shares = vault.balanceOf(user);
        uint256 ptPre  = IERC20(PT).balanceOf(address(adapter));

        vm.prank(user);
        vm.expectRevert();
        vault.withdraw(15_000e6, user, user);

        assertEq(IERC20(USDC).balanceOf(user), 0, "user received USDC on a fail-close");
        assertEq(vault.balanceOf(user), shares, "shares changed on a fail-close");
        assertEq(IERC20(PT).balanceOf(address(adapter)), ptPre, "PT moved on a fail-close");
    }

    // ─────────────────────────────────────────────────────────
    // setAdapter(0) fail-close — guard: received >= adapterBal (pause strategy)
    // ─────────────────────────────────────────────────────────
    function test_setAdapterZero_loadedSlippage_failClose() public onlyFork {
        _deploy(DEEP_SLIP_BPS, DEFAULT_HAIRCUT);
        _userDeposit(DEPOSIT);
        skip(3 days);

        uint256 ptPre = IERC20(PT).balanceOf(address(adapter));

        vm.prank(governance);
        vm.expectRevert();
        vault.setAdapter(address(0));

        assertEq(vault.activeAdapter(), address(adapter), "adapter detached on a fail-close");
        assertEq(IERC20(PT).balanceOf(address(adapter)), ptPre, "PT moved on a fail-close");
        assertEq(IERC20(USDC).balanceOf(address(vault)), 0, "vault idle changed on a fail-close");
    }

    // ─────────────────────────────────────────────────────────
    // setAdapter migration fail-close — recall from the loaded adapter reverts first,
    // so the whole rotation aborts (the destination adapter's swapper is irrelevant).
    // ─────────────────────────────────────────────────────────
    function test_setAdapterMigration_loadedSlippage_failClose() public onlyFork {
        _deploy(DEEP_SLIP_BPS, DEFAULT_HAIRCUT);
        _userDeposit(DEPOSIT);
        skip(3 days);

        // Destination adapter uses a par swapper — never reached; recall fails first.
        LoadedExitSwapper parSw = new LoadedExitSwapper(0);
        deal(USDC, address(parSw), 20_000_000e6);
        deal(USDE, address(parSw), 20_000_000e18);
        deal(SUSDE, address(parSw), 20_000_000e18);
        PendlePTAdapter adapter2 = new PendlePTAdapter(
            USDC, MARKET, ROUTER, PTORACLE, address(parSw), TWAP, address(vault), governance
        );

        uint256 ptPre = IERC20(PT).balanceOf(address(adapter));

        vm.startPrank(governance);
        registry.registerAdapter(address(adapter2), "DeFi", "Pendle (PT-sUSDe / Ethena) v2");
        vm.expectRevert();
        vault.setAdapter(address(adapter2));
        vm.stopPrank();

        assertEq(vault.activeAdapter(), address(adapter), "migrated despite fail-close");
        assertEq(IERC20(PT).balanceOf(address(adapter)), ptPre, "source PT moved on a fail-close");
        assertEq(IERC20(PT).balanceOf(address(adapter2)), 0, "destination bought PT on a fail-close");
    }

    // ─────────────────────────────────────────────────────────
    // ② tie-in: even at the 3% MAX haircut, a deep-slippage market STILL fail-closes.
    // The hard cap cannot buy liquidity; the haircut must be matched to the realizable
    // round-trip for the bound size, and the cap validated against target AUM.
    // ─────────────────────────────────────────────────────────
    function test_maxHaircut_stillFailsUnderDeepSlippage() public onlyFork {
        _deploy(DEEP_SLIP_BPS, MAX_HAIRCUT); // 3% cap, still << 25% slippage
        _userDeposit(DEPOSIT);
        skip(2 days);

        uint256 shares = vault.balanceOf(user);
        vm.prank(user);
        vm.expectRevert();
        vault.redeem(shares, user, user);

        assertEq(IERC20(USDC).balanceOf(user), 0, "user received USDC despite 3% cap < impact");
        assertEq(vault.balanceOf(user), shares, "shares burned despite fail-close");
    }
}

// ─────────────────────────────────────────────────────────────
// Test-only swapper: par on USDC/USDe legs (so deposit works), and a configurable
// impact on the FINAL sUSDe->USDC leg (the floored hop). Pays from deal-funded balances.
// slip=0 reproduces the par VaultForkSwapper; slip>haircut forces the min-out floor to
// revert, exercising the adapter's fail-close valve and the vault's M13-16 guard.
// ─────────────────────────────────────────────────────────────
contract LoadedExitSwapper is IStableSwapper {
    using SafeERC20 for IERC20;

    address constant USDC  = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDE  = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    uint256 constant BPS   = 10_000;

    uint256 public immutable exitSlipBps; // applied ONLY to sUSDe->USDC

    constructor(uint256 exitSlipBps_) {
        exitSlipBps = exitSlipBps_;
    }

    function _rawOut(address tokenIn, address tokenOut, uint256 amountIn) internal view returns (uint256) {
        if (tokenIn == USDC && tokenOut == USDE) return amountIn * 1e12;   // 6 -> 18, par
        if (tokenIn == USDE && tokenOut == USDC) return amountIn / 1e12;   // 18 -> 6, par
        if (tokenIn == SUSDE && tokenOut == USDC) {
            uint256 usde = ISUSDeConvert(SUSDE).convertToAssets(amountIn); // sUSDe -> USDe (18)
            uint256 usdc = usde / 1e12;                                    // -> USDC (6), par
            return (usdc * (BPS - exitSlipBps)) / BPS;                     // apply configured impact
        }
        revert("LoadedExitSwapper: pair");
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address to)
        external
        returns (uint256 amountOut)
    {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        amountOut = _rawOut(tokenIn, tokenOut, amountIn);
        require(amountOut >= minOut, "LoadedExitSwapper: min out"); // fail-close valve
        IERC20(tokenOut).safeTransfer(to, amountOut);
    }
}
