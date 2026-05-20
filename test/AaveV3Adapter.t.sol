// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AaveV3USDCAdapter} from "../src/adapters/AaveV3USDCAdapter.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title AaveV3AdapterForkTest
/// @notice Integration tests against live Arbitrum One state.
///
/// Run:
///   forge test --fork-url $ARB_RPC_URL --match-contract AaveV3AdapterForkTest -vvv
///
/// Or pin to a block for reproducible results:
///   forge test --fork-url $ARB_RPC_URL --fork-block-number 300000000 -vvv
contract AaveV3AdapterForkTest is Test {
    // ─── Arbitrum One Addresses ───────────────────────────────
    address constant USDC      = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant AAVE_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address constant A_USDC    = 0x625E7708f30cA75bfd92586e17077590C60eb4cD;

    // ─── Actors ───────────────────────────────────────────────
    address governance = makeAddr("governance");
    address alice      = makeAddr("alice");
    address feeRcpt    = makeAddr("feeRecipient");

    // ─── Contracts ────────────────────────────────────────────
    AdapterRegistry    registry;
    SIXXVault          vault;
    AaveV3USDCAdapter  adapter;

    uint256 constant DEPOSIT = 1_000e6; // 1,000 USDC

    // ─────────────────────────────────────────────────────────
    function setUp() public {
        // Deploy registry
        vm.prank(governance);
        registry = new AdapterRegistry(governance);

        // Deploy vault
        vm.prank(governance);
        vault = new SIXXVault(
            IERC20(USDC),
            "SIXX Stable Yield",
            "sxUSDC",
            governance,
            address(registry),
            feeRcpt
        );

        // Deploy adapter
        adapter = new AaveV3USDCAdapter(
            USDC,
            AAVE_POOL,
            A_USDC,
            address(vault),
            governance,
            0 // referral code
        );

        // Register and activate
        vm.startPrank(governance);
        registry.registerAdapter(address(adapter), "DeFi", "Aave V3");
        vault.setAdapter(address(adapter));
        vm.stopPrank();

        // Fund alice via deal() — sets ERC-20 balance without needing a whale
        deal(USDC, alice, DEPOSIT * 10);
    }

    // ─────────────────────────────────────────────────────────
    // Smoke Test: deposit → check state
    // ─────────────────────────────────────────────────────────

    function test_smoke_deposit() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), DEPOSIT);
        uint256 shares = vault.deposit(DEPOSIT, alice);
        vm.stopPrank();

        console2.log("--- Smoke Deposit ---");
        console2.log("Shares received :", shares);
        console2.log("Vault totalAssets:", vault.totalAssets());
        console2.log("Adapter aUSDC   :", IERC20(A_USDC).balanceOf(address(adapter)));
        console2.log("Vault USDC idle :", IERC20(USDC).balanceOf(address(vault)));

        assertGt(shares, 0, "Shares must be > 0");
        // All assets deployed — vault idle should be 0
        assertEq(IERC20(USDC).balanceOf(address(vault)), 0, "Vault fully deployed");
        // aUSDC balance should approximate deposit (slight rounding)
        assertApproxEqAbs(adapter.totalAssets(), DEPOSIT, 2, "Adapter holds ~DEPOSIT");
        assertApproxEqAbs(vault.totalAssets(), DEPOSIT, 2, "totalAssets ~DEPOSIT");
    }

    // ─────────────────────────────────────────────────────────
    // Full round-trip: deposit → withdraw
    // ─────────────────────────────────────────────────────────

    function test_deposit_then_withdraw() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), DEPOSIT);
        uint256 shares = vault.deposit(DEPOSIT, alice);
        vm.stopPrank();

        uint256 usdcBefore = IERC20(USDC).balanceOf(alice);

        vm.startPrank(alice);
        uint256 withdrawn = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        uint256 usdcAfter = IERC20(USDC).balanceOf(alice);

        console2.log("--- Round-trip ---");
        console2.log("Deposited  :", DEPOSIT);
        console2.log("Withdrawn  :", withdrawn);
        console2.log("Net change :", usdcAfter - usdcBefore);

        // Allow 2 wei rounding
        assertApproxEqAbs(usdcAfter - usdcBefore, DEPOSIT, 2, "Full round-trip");
        assertApproxEqAbs(vault.totalAssets(), 0, 2, "Vault drained");
    }

    // ─────────────────────────────────────────────────────────
    // Time travel: yield accrual
    // ─────────────────────────────────────────────────────────

    function test_yield_accrual_30_days() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, alice);
        vm.stopPrank();

        uint256 assetsBefore = vault.totalAssets();

        // aUSDC accrues interest based on block.timestamp (Aave uses ray-math)
        vm.warp(block.timestamp + 30 days);

        uint256 assetsAfter = vault.totalAssets();

        console2.log("--- Yield Accrual (30 days) ---");
        console2.log("Assets before:", assetsBefore);
        console2.log("Assets after :", assetsAfter);
        if (assetsAfter >= assetsBefore) {
            console2.log("Yield earned :", assetsAfter - assetsBefore);
        }

        // aUSDC.balanceOf() returns principal + accrued interest
        assertGe(assetsAfter, assetsBefore, "Assets must not decrease");
    }

    // ─────────────────────────────────────────────────────────
    // Emergency shutdown
    // ─────────────────────────────────────────────────────────

    function test_emergency_shutdown_full_flow() public {
        // Deposit
        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), DEPOSIT);
        uint256 shares = vault.deposit(DEPOSIT, alice);
        vm.stopPrank();

        // Trigger shutdown
        vm.prank(governance);
        vault.setEmergencyShutdown(true);

        console2.log("--- Emergency Shutdown ---");
        console2.log("Vault USDC after shutdown :", IERC20(USDC).balanceOf(address(vault)));
        console2.log("Adapter aUSDC after shutdown:", adapter.totalAssets());

        assertApproxEqAbs(
            IERC20(USDC).balanceOf(address(vault)), DEPOSIT, 2,
            "Assets recalled to vault"
        );

        // New deposit should revert
        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), DEPOSIT);
        vm.expectRevert("VAULT: emergency shutdown");
        vault.deposit(DEPOSIT, alice);
        vm.stopPrank();

        // Existing holder can still withdraw
        vm.startPrank(alice);
        uint256 withdrawn = vault.redeem(shares, alice, alice);
        vm.stopPrank();
        assertApproxEqAbs(withdrawn, DEPOSIT, 2, "Can withdraw in emergency");
    }

    // ─────────────────────────────────────────────────────────
    // APY estimation
    // ─────────────────────────────────────────────────────────

    function test_estimated_apy() public view {
        uint256 apyBps = adapter.estimatedAPY();
        console2.log("--- Aave V3 USDC APY ---");
        console2.log("APY (basis points):", apyBps);
        console2.log("APY (%)           :", apyBps / 100);
        // Should be a sane value (0–50% = 0–5000 BPS)
        assertLe(apyBps, 5_000, "APY should be <= 50%");
    }

    // ─────────────────────────────────────────────────────────
    // Multiple depositors
    // ─────────────────────────────────────────────────────────

    function test_two_depositors_proportional_shares() public {
        address bob = makeAddr("bob");
        deal(USDC, bob, DEPOSIT * 10);

        // Alice deposits 1000
        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), DEPOSIT);
        uint256 sharesAlice = vault.deposit(DEPOSIT, alice);
        vm.stopPrank();

        // Bob deposits 2000 (2x)
        vm.startPrank(bob);
        IERC20(USDC).approve(address(vault), DEPOSIT * 2);
        uint256 sharesBob = vault.deposit(DEPOSIT * 2, bob);
        vm.stopPrank();

        console2.log("--- Two Depositors ---");
        console2.log("Alice shares:", sharesAlice);
        console2.log("Bob shares  :", sharesBob);
        console2.log("Total assets:", vault.totalAssets());

        // Bob should have ~2x Alice's shares
        assertApproxEqRel(sharesBob, sharesAlice * 2, 0.001e18, "Bob has 2x shares");
        assertApproxEqAbs(vault.totalAssets(), DEPOSIT * 3, 3, "Total = 3000 USDC");
    }
}
