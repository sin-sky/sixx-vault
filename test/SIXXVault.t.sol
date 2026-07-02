// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {MockAdapter} from "./mocks/MockAdapter.sol";
import {FaultyAdapter} from "./mocks/FaultyAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ISIXXVault} from "../src/interfaces/ISIXXVault.sol";

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
    address guardianAddr = address(0x6042D);

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
            feeRcpt,
            guardianAddr
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

        // H-4: maxRedeem returns 0 while locked → OZ's outer guard fires first
        vm.expectRevert(abi.encodeWithSelector(
            bytes4(keccak256("ERC4626ExceededMaxRedeem(address,uint256,uint256)")),
            alice, shares, uint256(0)
        ));
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

    /// B: emergency shutdown waives the lock so a locked user can exit immediately.
    function test_emergency_shutdown_waives_lock() public {
        vm.prank(governance);
        vault.setLockPeriod(7 days);

        uint256 amount = 1_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice); // alice now locked for 7 days
        vm.stopPrank();

        // Sanity: still locked, so maxRedeem is 0 before shutdown.
        assertEq(vault.maxRedeem(alice), 0, "locked before shutdown");

        vm.prank(governance);
        vault.setEmergencyShutdown(true);

        // Lock is waived under shutdown → redeem succeeds immediately (well within 7 days).
        assertGt(vault.maxRedeem(alice), 0, "lock waived under shutdown");
        vm.prank(alice);
        uint256 withdrawn = vault.redeem(shares, alice, alice);
        assertApproxEqAbs(withdrawn, amount, 2, "locked user exits under shutdown");
    }

    /// A: a reverting adapter must not brick the emergency shutdown.
    function test_emergency_shutdown_succeeds_when_recall_reverts() public {
        FaultyAdapter faulty = new FaultyAdapter(address(usdc), address(vault));
        vm.startPrank(governance);
        registry.registerAdapter(address(faulty), "Test", "Faulty");
        vault.setAdapter(address(faulty)); // switch active adapter to faulty (no funds yet)
        vm.stopPrank();

        uint256 amount = 1_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice); // funds now in faulty adapter
        vm.stopPrank();

        faulty.setRevertOnWithdraw(true); // adapter is now "frozen"

        // With withdraw forced to revert, the only way shutdown can succeed is via the
        // try/catch (A). If recall were a direct call, this tx would revert.
        vm.prank(governance);
        vault.setEmergencyShutdown(true);

        assertTrue(vault.emergencyShutdown(), "shutdown took effect despite recall failure");
    }

    /// M13-16: recall reverts if the adapter silently under-delivers.
    function test_recall_reverts_on_adapter_shortfall() public {
        FaultyAdapter faulty = new FaultyAdapter(address(usdc), address(vault));
        vm.startPrank(governance);
        registry.registerAdapter(address(faulty), "Test", "Faulty");
        vault.setAdapter(address(faulty));
        vm.stopPrank();

        uint256 amount = 1_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);
        vm.stopPrank();

        faulty.setDeliverBps(9_000); // deliver only 90% of what is requested

        vm.prank(alice);
        vm.expectRevert(bytes("VAULT: adapter shortfall"));
        vault.redeem(shares, alice, alice);
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

    // ─────────────────────────────────────────────────────────
    // Audit Regression Tests (AUDIT_FIXPLAN)
    // ─────────────────────────────────────────────────────────

    /// @dev H-2: share transfers must revert while the sender is locked,
    ///      otherwise users could move shares to a fresh address and
    ///      bypass the lock by redeeming there.
    function test_lockBypassViaTransfer() public {
        vm.prank(governance);
        vault.setLockPeriod(7 days);

        uint256 amount = 1_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);

        vm.expectRevert("VAULT: still locked");
        vault.transfer(bob, shares);
        vm.stopPrank();

        // After the lock expires, the same transfer succeeds.
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(alice);
        vault.transfer(bob, shares);
        assertEq(vault.balanceOf(bob), shares, "transfer ok after lock expires");
    }

    /// @dev H-3: a third party must NOT be able to extend someone else's
    ///      lock by depositing on their behalf — otherwise an attacker
    ///      could grief a victim by perpetually re-locking their funds.
    function test_lockGriefingByAttacker() public {
        vm.prank(governance);
        vault.setLockPeriod(7 days);

        uint256 amount = 1_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();
        uint256 originalLock = vault.lockedUntil(alice);

        // 6 days in, the attacker (bob) deposits with receiver = alice.
        vm.warp(block.timestamp + 6 days);
        vm.startPrank(bob);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice); // caller != receiver
        vm.stopPrank();

        assertEq(
            vault.lockedUntil(alice),
            originalLock,
            "attacker must not be able to extend victim's lock"
        );

        // And alice can withdraw at the originally-scheduled time.
        vm.warp(originalLock + 1);
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);
    }

    /// @dev H-4: maxWithdraw / maxRedeem must surface the lock state so
    ///      integrators and ERC-4626 previews see 0 capacity while the
    ///      owner is locked (and recover once the lock expires).
    function test_maxWithdraw_returnsZeroWhenLocked() public {
        vm.prank(governance);
        vault.setLockPeriod(7 days);

        uint256 amount = 1_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();

        assertEq(vault.maxWithdraw(alice), 0, "maxWithdraw == 0 while locked");
        assertEq(vault.maxRedeem(alice),   0, "maxRedeem == 0 while locked");

        vm.warp(block.timestamp + 7 days + 1);

        assertGt(vault.maxWithdraw(alice), 0, "maxWithdraw recovers after lock");
        assertGt(vault.maxRedeem(alice),   0, "maxRedeem recovers after lock");
    }

    /// @dev H-1: setAdapter must reject any adapter not whitelisted in
    ///      the AdapterRegistry. address(0) remains valid as the
    ///      explicit "pause strategy" path.
    function test_setAdapter_rejectsUnregisteredAdapter() public {
        MockAdapter rogue = new MockAdapter(address(usdc), address(vault));
        // intentionally NOT registered

        vm.prank(governance);
        vm.expectRevert("VAULT: adapter not whitelisted");
        vault.setAdapter(address(rogue));

        // Sanity: address(0) still works (pause strategy).
        vm.prank(governance);
        vault.setAdapter(address(0));
        assertEq(vault.activeAdapter(), address(0));
    }

    /// @dev M-1: collectFees must use the dilution formula
    ///        feeShares = feeAssets * supply / (assets - feeAssets)
    ///      so that, AFTER minting, the fee recipient owns exactly
    ///      feeAssets worth of the existing pool. The previous (buggy)
    ///      implementation used previewDeposit, which under-mints
    ///      because feeAssets is already part of totalAssets().
    function test_collectFees_dilutionMath() public {
        vm.prank(governance);
        vault.setManagementFee(100); // 1% per year

        uint256 amount = 10_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();

        uint256 assetsBefore = vault.totalAssets();
        uint256 supplyBefore = vault.totalSupply();

        // Advance exactly one SECS_PER_YEAR (per SIXXVault.sol).
        vm.warp(block.timestamp + 365 days + 6 hours);
        vault.collectFees();

        uint256 feeShares = vault.balanceOf(feeRcpt);

        // The contract's feeAssets simplifies to assets * mgmtFee / MAX_BPS
        // because elapsed == SECS_PER_YEAR cancels exactly.
        uint256 expectedFeeAssets  = (assetsBefore * 100) / 10_000;
        uint256 expectedFeeShares  =
            (expectedFeeAssets * supplyBefore) / (assetsBefore - expectedFeeAssets);

        assertEq(
            feeShares,
            expectedFeeShares,
            "feeShares must follow the dilution formula, not previewDeposit"
        );

        // Reject the previewDeposit shape (feeAssets * supply / assets),
        // which would always be strictly smaller than the correct value.
        uint256 buggyFeeShares = (expectedFeeAssets * supplyBefore) / assetsBefore;
        assertGt(
            feeShares,
            buggyFeeShares,
            "dilution formula must over-mint vs the buggy previewDeposit shape"
        );

        // After minting, the fee recipient's stake value should equal
        // exactly feeAssets (within OZ virtual-shares rounding).
        uint256 feeValue = vault.convertToAssets(feeShares);
        assertApproxEqAbs(
            feeValue,
            expectedFeeAssets,
            2,
            "post-mint feeRecipient stake must equal accrued feeAssets"
        );
    }

    // M-3 event mirror — re-declared so vm.expectEmit can match its signature.
    event AdapterDepositFailed(address indexed adapter, uint256 amount);

    /// @dev M-3: a reverting adapter must not be able to brick user
    ///      deposits. The vault wraps transfer + adapter.deposit in a
    ///      self-call, so on revert both are rolled back: funds stay idle
    ///      in the vault, no funds get stranded in the adapter, and the
    ///      outer ERC-4626 deposit still succeeds.
    function test_deposit_survivesAdapterRevert() public {
        vm.mockCallRevert(
            address(adapter),
            abi.encodeWithSelector(MockAdapter.deposit.selector),
            "ADAPTER: forced revert"
        );

        uint256 amount = 1_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);

        vm.expectEmit(true, false, false, true, address(vault));
        emit AdapterDepositFailed(address(adapter), amount);

        uint256 shares = vault.deposit(amount, alice);
        vm.stopPrank();

        assertGt(shares, 0, "deposit must succeed despite adapter revert");
        assertEq(
            usdc.balanceOf(address(vault)),
            amount,
            "assets stay idle in the vault on adapter revert"
        );
        assertEq(
            usdc.balanceOf(address(adapter)),
            0,
            "no funds may be stranded in the adapter"
        );
        assertEq(vault.totalAssets(), amount, "totalAssets matches the deposit");
    }

    // ─────────────────────────────────────────────────────────
    // Guardian (C-1)
    // ─────────────────────────────────────────────────────────

    function test_constructor_reverts_on_zero_guardian() public {
        vm.expectRevert(bytes("VAULT: zero guardian"));
        new SIXXVault(
            IERC20(address(usdc)), "n", "s", governance, address(registry), feeRcpt, address(0)
        );
    }

    function test_guardian_initialized() public view {
        assertEq(vault.guardian(), guardianAddr);
    }

    function test_setGuardian_only_governance() public {
        vm.prank(alice);
        vm.expectRevert(bytes("VAULT: not governance"));
        vault.setGuardian(bob);
    }

    function test_setGuardian_rejects_zero() public {
        vm.prank(governance);
        vm.expectRevert(bytes("VAULT: zero guardian"));
        vault.setGuardian(address(0));
    }

    function test_setGuardian_updates_and_emits() public {
        vm.expectEmit(true, true, false, false);
        emit ISIXXVault.GuardianChanged(guardianAddr, bob);
        vm.prank(governance);
        vault.setGuardian(bob);
        assertEq(vault.guardian(), bob);
    }
}
