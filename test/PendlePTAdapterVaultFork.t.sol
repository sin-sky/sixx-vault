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

/// @title PendlePTAdapterVaultForkTest
/// @notice Integration of PendlePTAdapter with a REAL SIXXVault + AdapterRegistry
///         against live Ethereum mainnet (PT-sUSDe, expiry 2026-08-13). Unlike the
///         adapter-only fork suite (PendlePTAdapterForkTest), this exercises the
///         vault's M13-16 shortfall guards end-to-end:
///           - `_recallFromAdapter` : `received >= toWithdraw`  (user withdraw)
///           - `setAdapter`         : `received >= adapterBal`   (migration)
///         The whole point of escalate#1: with the recall-haircut, a PRE-MATURITY
///         full recall / migration now PASSES these guards (was structurally
///         reverting before). Post-maturity par redemption is covered too.
///
///         Only the shared, injected `IStableSwapper` leg is mocked (par rate over
///         USDC/USDe/sUSDe, pre-funded via `deal`) — the same isolation the
///         adapter-only suite uses. The REAL Pendle router + PT TWAP oracle drive
///         the PT economics.
///
/// Run:
///   forge test --fork-url $ETH_RPC_URL --fork-block-number 25500309 \
///     --match-contract PendlePTAdapterVaultForkTest -vvv
contract PendlePTAdapterVaultForkTest is Test {
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
    uint256 constant FORK_BLOCK = 25_500_309;

    uint256 constant DEPOSIT = 50_000e6; // 50,000 USDC

    address governance   = makeAddr("governance");
    address feeRecipient = makeAddr("feeRecipient");
    address guardian     = makeAddr("guardian");
    address user         = makeAddr("user");

    AdapterRegistry registry;
    SIXXVault       vault;
    PendlePTAdapter adapter;
    VaultForkSwapper swapper;
    bool forked;

    function setUp() public {
        string memory url = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(url).length == 0) { forked = false; return; }
        vm.createSelectFork(url, FORK_BLOCK);
        require(block.chainid == 1, "fork ETH mainnet");
        require(block.timestamp < EXPIRY, "fork before expiry");
        forked = true;

        swapper = new VaultForkSwapper();
        deal(USDC, address(swapper), 20_000_000e6);
        deal(USDE, address(swapper), 20_000_000e18);
        deal(SUSDE, address(swapper), 20_000_000e18);

        registry = new AdapterRegistry(governance);
        vault = new SIXXVault(
            IERC20(USDC), "SIXX Fixed Yield - PT-sUSDe", "sxPT",
            governance, address(registry), feeRecipient, guardian
        );
        adapter = _newAdapter();

        // Governance wiring: register + activate the adapter on the vault.
        vm.startPrank(governance);
        registry.registerAdapter(address(adapter), "DeFi", "Pendle (PT-sUSDe / Ethena)");
        vault.setAdapter(address(adapter)); // activeAdapter was 0 → no recall, idle 0 → no deploy
        vm.stopPrank();
    }

    modifier onlyFork() {
        if (!forked) return;
        _;
    }

    function _newAdapter() internal returns (PendlePTAdapter a) {
        a = new PendlePTAdapter(
            USDC, MARKET, ROUTER, PTORACLE, address(swapper), TWAP, address(vault), governance
        );
    }

    /// @dev User deposits into the vault; the vault auto-deploys to the adapter.
    function _userDeposit(uint256 amt) internal {
        deal(USDC, user, amt);
        vm.startPrank(user);
        IERC20(USDC).forceApprove(address(vault), amt);
        vault.deposit(amt, user);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────
    // Deposit routes through the vault into the adapter (buys PT)
    // ─────────────────────────────────────────────────────────

    function test_vault_deposit_deploysToAdapter() public onlyFork {
        _userDeposit(DEPOSIT);

        assertEq(IERC20(USDC).balanceOf(address(vault)), 0, "vault should hold no idle USDC");
        assertGt(IERC20(PT).balanceOf(address(adapter)), 0, "adapter holds no PT");
        // Vault NAV == adapter NAV (haircut, discounted PT) — below principal, close to it.
        uint256 nav = vault.totalAssets();
        assertEq(nav, adapter.totalAssets(), "vault NAV != adapter NAV");
        assertLt(nav, DEPOSIT, "NAV should be <= principal (discount + haircut)");
        assertGt(nav, (DEPOSIT * 96) / 100, "NAV unexpectedly low");
    }

    // ─────────────────────────────────────────────────────────
    // PRE-MATURITY full user withdraw — `received >= toWithdraw`
    // ─────────────────────────────────────────────────────────

    function test_vault_fullRedeem_preMaturity_passesGuard() public onlyFork {
        _userDeposit(DEPOSIT);
        skip(2 days);

        uint256 shares = vault.balanceOf(user);
        uint256 navBefore = vault.totalAssets();

        // Full redeem: vault._recallFromAdapter must clear the M13-16 shortfall
        // guard on a 100% pull (this reverted pre-haircut).
        vm.prank(user);
        uint256 assetsOut = vault.redeem(shares, user, user);

        assertEq(IERC20(USDC).balanceOf(user), assetsOut, "user USDC mismatch");
        assertGt(assetsOut, 0, "nothing withdrawn");
        // Received at least the reported NAV (the guard's requirement).
        assertGe(assetsOut, navBefore, "full redeem realized below reported NAV");
        // PT is (near) fully drained.
        assertApproxEqRel(IERC20(PT).balanceOf(address(adapter)), 0, 1e15, "PT not drained");
    }

    // ─────────────────────────────────────────────────────────
    // PRE-MATURITY partial user withdraw — partial recall path
    // ─────────────────────────────────────────────────────────

    function test_vault_partialWithdraw_preMaturity() public onlyFork {
        _userDeposit(DEPOSIT);
        skip(1 days);

        uint256 want = 15_000e6;
        uint256 userBefore = IERC20(USDC).balanceOf(user);
        vm.prank(user);
        vault.withdraw(want, user, user);

        assertEq(IERC20(USDC).balanceOf(user) - userBefore, want, "user did not receive exact request");
        assertGt(IERC20(PT).balanceOf(address(adapter)), 0, "position fully drained on partial");
    }

    // ─────────────────────────────────────────────────────────
    // PRE-MATURITY setAdapter migration — `received >= adapterBal`
    // ─────────────────────────────────────────────────────────

    function test_vault_setAdapter_migration_preMaturity_passesGuard() public onlyFork {
        _userDeposit(DEPOSIT);
        skip(3 days);

        PendlePTAdapter adapter2 = _newAdapter();
        vm.startPrank(governance);
        registry.registerAdapter(address(adapter2), "DeFi", "Pendle (PT-sUSDe / Ethena) v2");
        // Recalls 100% from adapter (guard: received >= adapterBal) then redeploys
        // the recalled USDC into adapter2 (which buys fresh PT).
        vault.setAdapter(address(adapter2));
        vm.stopPrank();

        assertEq(vault.activeAdapter(), address(adapter2), "adapter not rotated");
        assertApproxEqRel(IERC20(PT).balanceOf(address(adapter)), 0, 1e15, "old adapter not drained");
        assertGt(IERC20(PT).balanceOf(address(adapter2)), 0, "new adapter holds no PT");
        assertEq(IERC20(USDC).balanceOf(address(vault)), 0, "vault should be fully redeployed");
        // NAV preserved across the migration within round-trip slippage.
        assertGt(vault.totalAssets(), (DEPOSIT * 95) / 100, "NAV lost in migration");
    }

    /// @dev Migration to address(0) (pause strategy): cleanest exercise of the
    ///      `received >= adapterBal` guard — recalls 100% to idle, no redeploy.
    function test_vault_setAdapter_toZero_recallsAll_passesGuard() public onlyFork {
        _userDeposit(DEPOSIT);
        skip(3 days);

        uint256 adapterBal = adapter.totalAssets();
        vm.prank(governance);
        vault.setAdapter(address(0));

        assertEq(vault.activeAdapter(), address(0), "strategy not paused");
        assertApproxEqRel(IERC20(PT).balanceOf(address(adapter)), 0, 1e15, "adapter not drained");
        // Recalled USDC now idle in the vault, >= the reported adapter NAV.
        assertGe(IERC20(USDC).balanceOf(address(vault)), adapterBal, "recall shorted the vault");
    }

    // ─────────────────────────────────────────────────────────
    // POST-MATURITY full redeem — par redemption path via the vault
    // ─────────────────────────────────────────────────────────

    function test_vault_fullRedeem_postMaturity_par() public onlyFork {
        _userDeposit(DEPOSIT);

        vm.warp(EXPIRY + 1);

        uint256 shares = vault.balanceOf(user);
        uint256 navBefore = vault.totalAssets();
        vm.prank(user);
        uint256 assetsOut = vault.redeem(shares, user, user);

        assertGe(assetsOut, navBefore, "par redeem realized below reported NAV");
        // Par redemption recovers ~principal (minus only the sUSDe->USDC leg).
        assertGt(assetsOut, (DEPOSIT * 98) / 100, "par redeem realized too little");
        assertApproxEqRel(IERC20(PT).balanceOf(address(adapter)), 0, 1e15, "PT not drained");
    }
}

// ─────────────────────────────────────────────────────────────
// Test-only par swapper (USDC/USDe/sUSDe), pays from deal-funded balances.
// ─────────────────────────────────────────────────────────────
contract VaultForkSwapper is IStableSwapper {
    using SafeERC20 for IERC20;

    address constant USDC  = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDE  = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;

    function _rawOut(address tokenIn, address tokenOut, uint256 amountIn) internal view returns (uint256) {
        if (tokenIn == USDC && tokenOut == USDE) return amountIn * 1e12;   // 6 -> 18, par
        if (tokenIn == USDE && tokenOut == USDC) return amountIn / 1e12;   // 18 -> 6, par
        if (tokenIn == SUSDE && tokenOut == USDC) {
            uint256 usde = ISUSDeConvert(SUSDE).convertToAssets(amountIn); // sUSDe -> USDe (18)
            return usde / 1e12;                                           // -> USDC (6)
        }
        revert("VaultForkSwapper: pair");
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address to)
        external
        returns (uint256 amountOut)
    {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        amountOut = _rawOut(tokenIn, tokenOut, amountIn);
        require(amountOut >= minOut, "VaultForkSwapper: min out");
        IERC20(tokenOut).safeTransfer(to, amountOut);
    }
}
