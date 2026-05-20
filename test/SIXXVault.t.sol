// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {MockAdapter} from "./mocks/MockAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Minimal mock ERC-20 for unit tests (no fork needed)
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

contract SIXXVaultTest is Test {
    // ─── Actors ───────────────────────────────────────────────
    address governance = address(0xBEEF);
    address alice      = address(0xA11CE);
    address bob        = address(0xB0B);
    address feeRcpt    = address(0xFEE);

    // ─── Contracts ────────────────────────────────────────────
    MockUSDC       usdc;
    AdapterRegistry registry;
    SIXXVault      vault;
    MockAdapter    adapter;

    uint256 constant USDC_6 = 1e6; // 1 USDC

    // ─────────────────────────────────────────────────────────
    function setUp() public {
        // Deploy mock token
        usdc = new MockUSDC();

        // Deploy registry
        vm.prank(governance);
        registry = new AdapterRegistry(governance);

        // Deploy vault
        vm.prank(governance);
        vault = new SIXXVault(
            IERC20(address(usdc)),
            "SIXX Stable Yield",
            "sxUSDC",
            governance,
            address(registry),
            feeRcpt
        );

        // Deploy mock adapter (vault address known now)
        adapter = new MockAdapter(address(usdc), address(vault));

        // Register + activate adapter
        vm.startPrank(governance);
        registry.registerAdapter(address(adapter), "DeFi", "Mock");
        vault.setAdapter(address(adapter));
        vm.stopPrank();

        // Fund users
        usdc.mint(alice, 10_000 * USDC_6);
        usdc.mint(bob,   10_000 * USDC_6);
    }

    // ─────────────────────────────────────────────────────────
    // Basic Deposit / Withdraw
    // ─────────────────────────────────────────────────────────

    function test_deposit_mints_shares() public {
        uint256 amount = 1_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);
        vm.stopPrank();

        assertGt(shares, 0, "Should receive shares");
        assertEq(vault.balanceOf(alice), shares, "Alice share balance");
        assertApproxEqAbs(vault.totalAssets(), amount, 1, "totalAssets = deposit");
        // Assets should be deployed to adapter
        assertGt(adapter.totalAssets(), 0, "Adapter should hold assets");
        assertEq(usdc.balanceOf(address(vault)), 0, "Vault should be empty (all deployed)");
    }

    function test_withdraw_returns_assets() public {
        uint256 amount = 1_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);

        uint256 balBefore = usdc.balanceOf(alice);
        vault.redeem(shares, alice, alice);
        uint256 balAfter = usdc.balanceOf(alice);
        vm.stopPrank();

        assertApproxEqAbs(balAfter - balBefore, amount, 2, "Should recover deposit");
        assertApproxEqAbs(vault.totalAssets(), 0, 1, "Vault drained");
    }

    function test_multiple_depositors() public {
        uint256 amount = 1_000 * USDC_6;

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, bob);
        vm.stopPrank();

        assertApproxEqAbs(vault.totalAssets(), 2 * amount, 2, "2x deposit");
        // Both have roughly equal shares
        assertApproxEqRel(vault.balanceOf(alice), vault.balanceOf(bob), 1e16, "Equal shares");
    }

    // ─────────────────────────────────────────────────────────
    // Lock Period
    // ─────────────────────────────────────────────────────────

    function test_lock_period_blocks_early_withdraw() public {
        vm.prank(governance);
        vault.setLockPeriod(7 days);

        uint256 amount = 1_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);

        // Immediate withdrawal should revert
        vm.expectRevert("VAULT: still locked");
        vault.redeem(shares, alice, alice);
        vm.stopPrank();
    }

    function test_lock_period_allows_withdraw_after_expiry() public {
        vm.prank(governance);
        vault.setLockPeriod(7 days);

        uint256 amount = 1_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 days + 1);

        vm.startPrank(alice);
        uint256 withdrawn = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        assertApproxEqAbs(withdrawn, amount, 2, "Should withdraw after lock");
    }

    // ─────────────────────────────────────────────────────────
    // Emergency Shutdown
    // ─────────────────────────────────────────────────────────

    function test_emergency_shutdown_blocks_deposits() public {
        vm.prank(governance);
        vault.setEmergencyShutdown(true);

        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000 * USDC_6);
        // OZ v5: maxDeposit() returns 0 on shutdown → ERC4626ExceededMaxDeposit is thrown first
        vm.expectRevert(abi.encodeWithSelector(
            bytes4(keccak256("ERC4626ExceededMaxDeposit(address,uint256,uint256)")),
            alice, uint256(1_000 * USDC_6), uint256(0)
        ));
        vault.deposit(1_000 * USDC_6, alice);
        vm.stopPrank();
    }

    function test_emergency_shutdown_recalls_assets() public {
        uint256 amount = 1_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(vault)), 0, "All deployed before shutdown");

        vm.prank(governance);
        vault.setEmergencyShutdown(true);

        assertApproxEqAbs(
            usdc.balanceOf(address(vault)), amount, 2,
            "Assets recalled on shutdown"
        );
    }

    function test_emergency_shutdown_allows_withdrawal() public {
        uint256 amount = 1_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);
        vm.stopPrank();

        vm.prank(governance);
        vault.setEmergencyShutdown(true);

        vm.startPrank(alice);
        uint256 withdrawn = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        assertApproxEqAbs(withdrawn, amount, 2, "Should still withdraw in emergency");
    }

    // ─────────────────────────────────────────────────────────
    // Adapter Switch
    // ─────────────────────────────────────────────────────────

    function test_set_adapter_migrates_assets() public {
        uint256 amount = 1_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();

        assertGt(adapter.totalAssets(), 0, "Old adapter has assets");

        // Deploy new adapter
        MockAdapter newAdapter = new MockAdapter(address(usdc), address(vault));
        vm.startPrank(governance);
        registry.registerAdapter(address(newAdapter), "DeFi", "Mock v2");
        vault.setAdapter(address(newAdapter));
        vm.stopPrank();

        assertApproxEqAbs(adapter.totalAssets(), 0, 1, "Old adapter drained");
        assertGt(newAdapter.totalAssets(), 0, "New adapter has assets");
        assertApproxEqAbs(vault.totalAssets(), amount, 2, "Total assets preserved");
    }

    // ─────────────────────────────────────────────────────────
    // Governance Transfer
    // ─────────────────────────────────────────────────────────

    function test_governance_transfer_two_step() public {
        address newGov = address(0xDEAD);

        vm.prank(governance);
        vault.proposeGovernance(newGov);
        assertEq(vault.pendingGovernance(), newGov);

        // Old governance still works
        assertEq(vault.governance(), governance);

        // Accept from new governance
        vm.prank(newGov);
        vault.acceptGovernance();
        assertEq(vault.governance(), newGov);
        assertEq(vault.pendingGovernance(), address(0));
    }

    function test_non_pending_cannot_accept_governance() public {
        vm.prank(governance);
        vault.proposeGovernance(address(0xDEAD));

        vm.prank(alice);
        vm.expectRevert("VAULT: not pending governance");
        vault.acceptGovernance();
    }

    // ─────────────────────────────────────────────────────────
    // Management Fee
    // ─────────────────────────────────────────────────────────

    function test_management_fee_mints_shares() public {
        // Set 1% annual management fee
        vm.prank(governance);
        vault.setManagementFee(100); // 100 BPS = 1%

        uint256 amount = 10_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();

        uint256 feeSharesBefore = vault.balanceOf(feeRcpt);

        // Advance 1 year
        vm.warp(block.timestamp + 365 days + 6 hours);
        vault.collectFees();

        uint256 feeSharesAfter = vault.balanceOf(feeRcpt);
        assertGt(feeSharesAfter, feeSharesBefore, "Fee shares minted");

        // ~1% of 10k USDC = ~100 USDC worth of shares
        uint256 feeAssets = vault.convertToAssets(feeSharesAfter - feeSharesBefore);
        assertApproxEqRel(feeAssets, 100 * USDC_6, 0.01e18, "Fee ~1% of assets");
    }

    // ─────────────────────────────────────────────────────────
    // ERC-4626 Properties
    // ─────────────────────────────────────────────────────────

    function test_preview_deposit_matches_actual() public {
        uint256 amount = 500 * USDC_6;
        uint256 previewShares = vault.previewDeposit(amount);

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        uint256 actualShares = vault.deposit(amount, alice);
        vm.stopPrank();

        assertEq(previewShares, actualShares, "preview == actual");
    }

    function test_max_deposit_zero_on_shutdown() public {
        assertEq(vault.maxDeposit(alice), type(uint256).max);

        vm.prank(governance);
        vault.setEmergencyShutdown(true);

        assertEq(vault.maxDeposit(alice), 0);
    }
}
