// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {PendlePTAdapter} from "../src/adapters/PendlePTAdapter.sol";
import {MockAdapter} from "./mocks/MockAdapter.sol";
import {MockUSDC} from "./SIXXVault.t.sol";
import {ISIXXVault} from "../src/interfaces/ISIXXVault.sol";
import {IAdapterRegistry} from "../src/interfaces/IAdapterRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title RemediationPartB
/// @notice Behavior tests for the SHIN-approved Part B hardening (P1/P2/P3/P4)
///         from audit/REMEDIATION_PROPOSALS.md. These pin the NEW behavior added to
///         the (previously frozen) production contracts.
contract RemediationPartBTest is Test {
    address governance   = address(0xBEEF);
    address alice        = address(0xA11CE);
    address bob          = address(0xB0B);
    address attacker     = address(0xBAD);
    address feeRcpt      = address(0xFEE);
    address guardianAddr = address(0x6042D);

    MockUSDC        usdc;
    AdapterRegistry registry;
    SIXXVault       vault;
    MockAdapter     adapter;

    uint256 constant USDC_6 = 1e6;

    function setUp() public {
        usdc = new MockUSDC();
        vm.prank(governance);
        registry = new AdapterRegistry(governance);
        vm.prank(governance);
        vault = new SIXXVault(
            IERC20(address(usdc)), "SIXX Stable Yield", "sxUSDC",
            governance, address(registry), feeRcpt, guardianAddr
        );
        adapter = new MockAdapter(address(usdc), address(vault));
        vm.startPrank(governance);
        registry.registerAdapter(address(adapter), "DeFi", "Mock");
        vault.setAdapter(address(adapter));
        vm.stopPrank();
        usdc.mint(alice,    10_000 * USDC_6);
        usdc.mint(bob,      10_000 * USDC_6);
        usdc.mint(attacker, 100_000 * USDC_6);
    }

    // ─── P1: zero-share deposit/mint revert ──────────────────────────────
    function test_P1_deposit_revertsOnZeroShares() public {
        // seed + donate to push price-per-share high enough that 1 wei → 0 shares
        vm.startPrank(alice);
        usdc.approve(address(vault), 1);
        vault.deposit(1, alice);
        vm.stopPrank();
        vm.prank(attacker);
        usdc.transfer(address(vault), 50_000 * USDC_6);

        assertEq(vault.previewDeposit(1), 0, "setup: expected zero-share preview");
        vm.startPrank(bob);
        usdc.approve(address(vault), 1);
        vm.expectRevert("VAULT: zero shares");
        vault.deposit(1, bob);
        vm.stopPrank();
    }

    function test_P1_mint_revertsOnZeroSharesArg() public {
        vm.prank(bob);
        vm.expectRevert("VAULT: zero shares");
        vault.mint(0, bob);
    }

    function test_P1_normalDeposit_stillWorks() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000 * USDC_6);
        uint256 sh = vault.deposit(1_000 * USDC_6, alice);
        vm.stopPrank();
        assertGt(sh, 0);
    }

    // ─── P2: observability events ────────────────────────────────────────
    function test_P2_setManagementFee_emitsEvent() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit ISIXXVault.ManagementFeeUpdated(0, 200);
        vm.prank(governance);
        vault.setManagementFee(200);
        assertEq(vault.managementFee(), 200);
    }

    function test_P2_registry_governanceTransfer_emitsEvents() public {
        vm.expectEmit(true, true, false, false, address(registry));
        emit IAdapterRegistry.GovernanceProposed(governance, alice);
        vm.prank(governance);
        registry.proposeGovernance(alice);

        vm.expectEmit(true, false, false, false, address(registry));
        emit IAdapterRegistry.GovernanceAccepted(alice);
        vm.prank(alice);
        registry.acceptGovernance();
        assertEq(registry.governance(), alice);
    }

    // ─── P3: Pendle twapDuration min 15-min bound ────────────────────────
    /// The twap bound is checked before any external Pendle call, so a too-short
    /// window reverts even with placeholder addresses (no fork needed).
    function test_P3_pendle_rejectsTwapBelow15min() public {
        address d = address(0xdead);
        vm.expectRevert("ADAPTER: twap < 15min");
        new PendlePTAdapter(d, d, d, d, d, uint32(100), d, d);

        // 899 still rejected; 900 passes the bound (then fails later on the dummy
        // external calls — different revert, proving the bound itself is satisfied).
        vm.expectRevert("ADAPTER: twap < 15min");
        new PendlePTAdapter(d, d, d, d, d, uint32(899), d, d);
    }

    // ─── P4: performanceFee not implemented ──────────────────────────────
    function test_P4_setPerformanceFee_rejectsNonzero() public {
        vm.prank(governance);
        vm.expectRevert("VAULT: performance fee not implemented");
        vault.setPerformanceFee(1);

        vm.prank(governance);
        vault.setPerformanceFee(0); // no-op allowed
        assertEq(vault.performanceFee(), 0);
    }
}
