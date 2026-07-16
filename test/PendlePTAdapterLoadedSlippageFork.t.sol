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
/// @notice Stresses the escalate#1 haircut floor against the ROUND-8 HARDENED SIXXVault
///         exit model (audit-scope aggregate). The existing vault-fork suite prices the
///         injected sUSDe->USDC leg at par / zero-impact, so the escalate#1 fail-close was
///         never exercised. Here the swapper applies a slippage on the FINAL sUSDe->USDC
///         hop that EXCEEDS `recallHaircutBps` (adapter reverts on the unmet floor), and we
///         assert the COMPOSED behaviour with the hardened core (ARCH_RULING, aggregation):
///
///           - The adapter's fail-close is atomic (PT sale + floored swap in one tx; a revert
///             on the swap rolls back the PT sale) — no funds ever move below the floor.
///           - USER paths (redeem/withdraw): the hardened core's `_exitRealize` ABSORBS the
///             adapter revert (try/catch) → payout == 0, shares RETAINED, PT intact, NO revert
///             (柱4: the claim is kept as a durable pro-rata share, recoverable later).
///           - `setAdapter(0)`: force-detach is best-effort → detach SUCCEEDS (never reverts),
///             PT retained in the detached adapter, `depositsPaused == true`, write-off booked.
///           - MIGRATION `setAdapter(!=0)`: STRICT `require(received >= adapterBal)` → the whole
///             rotation REVERTS (the one path that still surfaces the fail-close as a revert).
///
///         A par control (slip=0) proves the fail-close is caused by slippage, not the harness,
///         and a recovery test proves 柱4: after governance repairs the swapper, the retained
///         shares pay out. gap ② tie-in: even at the 3% MAX haircut a deep-slippage market
///         still can't realize (payout 0) — the cap cannot buy liquidity
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

    uint256 constant DEPOSIT         = 50_000e6; // 50,000 USDC
    uint256 constant DEFAULT_HAIRCUT = 50;       // 0.5% (adapter default)
    uint256 constant MAX_HAIRCUT     = 300;      // 3% (MAX_RECALL_HAIRCUT_BPS)
    // 25% impact on the floored sUSDe->USDC leg — far above any allowed haircut (<=3%),
    // so the end-to-end floor can never be met and the adapter withdraw reverts.
    uint256 constant DEEP_SLIP_BPS = 2_500;

    address governance   = makeAddr("governance");
    address feeRecipient = makeAddr("feeRecipient");
    address guardian     = makeAddr("guardian");
    address user         = makeAddr("user");

    AdapterRegistry   registry;
    SIXXVault         vault;
    PendlePTAdapter   adapter;
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

    function _deploy(uint256 exitSlipBps, uint256 haircutBps) internal {
        swapper = new LoadedExitSwapper(exitSlipBps);
        _fund(address(swapper));

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

    function _fund(address who) internal {
        deal(USDC, who, 20_000_000e6);
        deal(USDE, who, 20_000_000e18);
        deal(SUSDE, who, 20_000_000e18);
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
    // ① Full redeem under an unrealizable floor — hardened core ABSORBS the adapter
    //    revert: payout 0, shares RETAINED, PT intact, NO revert (柱4).
    // ─────────────────────────────────────────────────────────
    function test_fullRedeem_loadedSlippage_absorbedToZero() public onlyFork {
        _deploy(DEEP_SLIP_BPS, DEFAULT_HAIRCUT);
        _userDeposit(DEPOSIT);
        skip(2 days);

        uint256 shares = vault.balanceOf(user);
        uint256 navPre = vault.totalAssets();
        uint256 ptPre  = IERC20(PT).balanceOf(address(adapter));

        vm.prank(user);
        uint256 assetsOut = vault.redeem(shares, user, user); // does NOT revert

        assertEq(assetsOut, 0, "should realize nothing under an unmet floor");
        assertEq(IERC20(USDC).balanceOf(user), 0, "user received USDC on a 0-realize");
        assertEq(vault.balanceOf(user), shares, "shares must be RETAINED (claim kept)");
        assertEq(IERC20(PT).balanceOf(address(adapter)), ptPre, "PT moved below the floor");
        assertEq(vault.totalAssets(), navPre, "NAV changed on a 0-realize");
        assertEq(vault.activeAdapter(), address(adapter), "adapter detached unexpectedly");
    }

    // ─────────────────────────────────────────────────────────
    // 柱4 recovery: after governance repairs the swap route, the RETAINED shares pay out.
    // ─────────────────────────────────────────────────────────
    function test_fullRedeem_recoversAfterSwapperRepaired() public onlyFork {
        _deploy(DEEP_SLIP_BPS, DEFAULT_HAIRCUT);
        _userDeposit(DEPOSIT);
        skip(2 days);

        uint256 shares = vault.balanceOf(user);
        vm.prank(user);
        assertEq(vault.redeem(shares, user, user), 0, "precondition: 0-realize");
        assertEq(vault.balanceOf(user), shares, "precondition: shares retained");

        // Governance repairs the leg (swap to a par swapper).
        LoadedExitSwapper parSw = new LoadedExitSwapper(0);
        _fund(address(parSw));
        vm.prank(governance);
        adapter.setSwapper(address(parSw));

        // Same retained shares now realize > 0.
        uint256 navBefore = vault.totalAssets();
        vm.prank(user);
        uint256 assetsOut = vault.redeem(shares, user, user);
        assertGe(assetsOut, navBefore, "recovered redeem below reported NAV");
        assertGt(assetsOut, 0, "recovery did not pay out");
        assertEq(vault.balanceOf(user), 0, "shares not burned on recovery");
    }

    // ─────────────────────────────────────────────────────────
    // ③ Partial withdraw under an unrealizable floor — absorbed to 0, no revert.
    // ─────────────────────────────────────────────────────────
    function test_partialWithdraw_loadedSlippage_absorbedToZero() public onlyFork {
        _deploy(DEEP_SLIP_BPS, DEFAULT_HAIRCUT);
        _userDeposit(DEPOSIT);
        skip(1 days);

        uint256 shares = vault.balanceOf(user);
        uint256 ptPre  = IERC20(PT).balanceOf(address(adapter));

        vm.prank(user);
        vault.withdraw(15_000e6, user, user); // does NOT revert

        assertEq(IERC20(USDC).balanceOf(user), 0, "user received USDC on a 0-realize");
        assertEq(vault.balanceOf(user), shares, "shares changed on a 0-realize");
        assertEq(IERC20(PT).balanceOf(address(adapter)), ptPre, "PT moved below the floor");
    }

    // ─────────────────────────────────────────────────────────
    // setAdapter(0) force-detach under an unrealizable floor — best-effort, NEVER reverts:
    // detach succeeds, PT retained in the detached adapter, deposits paused, write-off booked.
    // ─────────────────────────────────────────────────────────
    function test_setAdapterZero_loadedSlippage_forceDetaches() public onlyFork {
        _deploy(DEEP_SLIP_BPS, DEFAULT_HAIRCUT);
        _userDeposit(DEPOSIT);
        skip(3 days);

        uint256 ptPre = IERC20(PT).balanceOf(address(adapter));

        vm.prank(governance);
        vault.setAdapter(address(0)); // force-detach, does NOT revert

        assertEq(vault.activeAdapter(), address(0), "force-detach did not complete");
        assertEq(IERC20(PT).balanceOf(address(adapter)), ptPre, "PT left the detached adapter");
        assertEq(IERC20(USDC).balanceOf(address(vault)), 0, "vault idle changed (nothing was recallable)");
        assertTrue(vault.depositsPaused(), "deposits not paused after a shortfall detach");

        // Deposits are blocked while the impaired position is written off. `depositsPaused`
        // drives `maxDeposit()==0`, so OZ ERC4626's max-deposit guard reverts first
        // (ERC4626ExceededMaxDeposit) — before the inner `VAULT: deposits paused` check. Either
        // way the deposit is refused; assert on the refusal, not the specific selector.
        deal(USDC, user, 1_000e6);
        vm.startPrank(user);
        IERC20(USDC).forceApprove(address(vault), 1_000e6);
        vm.expectRevert();
        vault.deposit(1_000e6, user);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────
    // MIGRATION setAdapter(!=0) under an unrealizable floor — STRICT guard: whole rotation
    // REVERTS (the one path that still surfaces the fail-close as a top-level revert).
    // ─────────────────────────────────────────────────────────
    function test_setAdapterMigration_loadedSlippage_reverts() public onlyFork {
        _deploy(DEEP_SLIP_BPS, DEFAULT_HAIRCUT);
        _userDeposit(DEPOSIT);
        skip(3 days);

        LoadedExitSwapper parSw = new LoadedExitSwapper(0);
        _fund(address(parSw));
        PendlePTAdapter adapter2 = new PendlePTAdapter(
            USDC, MARKET, ROUTER, PTORACLE, address(parSw), TWAP, address(vault), governance
        );

        uint256 ptPre = IERC20(PT).balanceOf(address(adapter));

        vm.startPrank(governance);
        registry.registerAdapter(address(adapter2), "DeFi", "Pendle (PT-sUSDe / Ethena) v2");
        vm.expectRevert(); // "VAULT: adapter shortfall" (or the adapter's own floor revert)
        vault.setAdapter(address(adapter2));
        vm.stopPrank();

        assertEq(vault.activeAdapter(), address(adapter), "migrated despite fail-close");
        assertEq(IERC20(PT).balanceOf(address(adapter)), ptPre, "source PT moved on a fail-close");
        assertEq(IERC20(PT).balanceOf(address(adapter2)), 0, "destination bought PT on a fail-close");
    }

    // ─────────────────────────────────────────────────────────
    // ② tie-in: even at the 3% MAX haircut, a deep-slippage market STILL cannot realize
    // → user redeem is absorbed to 0 (the hard cap cannot buy liquidity). The haircut must
    // be matched to the realizable round-trip and the cap validated against target AUM.
    // ─────────────────────────────────────────────────────────
    function test_maxHaircut_stillUnrealizableUnderDeepSlippage() public onlyFork {
        _deploy(DEEP_SLIP_BPS, MAX_HAIRCUT); // 3% cap, still << 25% slippage
        _userDeposit(DEPOSIT);
        skip(2 days);

        uint256 shares = vault.balanceOf(user);
        vm.prank(user);
        uint256 assetsOut = vault.redeem(shares, user, user);

        assertEq(assetsOut, 0, "3% cap unexpectedly realized under 25% impact");
        assertEq(IERC20(USDC).balanceOf(user), 0, "user received USDC despite 3% cap < impact");
        assertEq(vault.balanceOf(user), shares, "shares burned despite 0-realize");
    }
}

// ─────────────────────────────────────────────────────────────
// Test-only swapper: par on USDC/USDe legs (so deposit works), and a configurable impact on
// the FINAL sUSDe->USDC leg (the floored hop). slip=0 reproduces the par VaultForkSwapper;
// slip>haircut forces the adapter's min-out floor to revert (fail-close), which the hardened
// core then absorbs (user paths) or surfaces as a migration revert.
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
