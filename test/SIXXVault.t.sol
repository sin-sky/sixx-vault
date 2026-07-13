// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
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

    /// Medium-A: setAdapter migration applies the same M13-16 balance-delta guard
    ///           as _recallFromAdapter — if the OLD adapter under-delivers on the
    ///           full recall, the switch reverts instead of stranding funds.
    function test_setAdapter_reverts_on_adapter_shortfall() public {
        FaultyAdapter faulty = new FaultyAdapter(address(usdc), address(vault));
        vm.startPrank(governance);
        registry.registerAdapter(address(faulty), "Test", "Faulty");
        vault.setAdapter(address(faulty)); // migrate mock -> faulty (no funds yet)
        vm.stopPrank();

        uint256 amount = 1_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice); // funds now held by the faulty adapter
        vm.stopPrank();

        assertGt(faulty.totalAssets(), 0, "faulty holds funds");
        faulty.setDeliverBps(9_000); // under-deliver 90% on the migration recall

        // Migrating to a fresh adapter must revert because the old one shorts the recall.
        MockAdapter fresh = new MockAdapter(address(usdc), address(vault));
        vm.startPrank(governance);
        registry.registerAdapter(address(fresh), "DeFi", "Mock v2");
        vm.expectRevert(bytes("VAULT: adapter shortfall"));
        vault.setAdapter(address(fresh));
        vm.stopPrank();
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

    /// @notice B-2 (Round 8): emergency shutdown must WAIVE the management-fee window — it
    ///         crystallizes fees earned before shutdown, then does not bill the non-productive
    ///         shutdown window to users exiting a broken strategy.
    function test_B2_shutdown_waivesManagementFeeWindow() public {
        vm.prank(governance);
        vault.setManagementFee(500); // 5%/yr (max) to make the effect measurable

        uint256 amount = 10_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();

        // Accrue a legitimate pre-shutdown fee window.
        vm.warp(block.timestamp + 30 days);

        // Guardian trips shutdown: pre-shutdown fee is crystallized while the vault is live.
        vm.prank(guardianAddr);
        vault.setEmergencyShutdown(true);
        uint256 feeAtShutdown = vault.balanceOf(feeRcpt);
        assertGt(feeAtShutdown, 0, "pre-shutdown fee must be crystallized at shutdown");

        // A long, non-productive shutdown window elapses.
        vm.warp(block.timestamp + 365 days);

        // Neither a permissionless collect nor an exit may bill the shutdown window.
        vault.collectFees();
        assertEq(vault.balanceOf(feeRcpt), feeAtShutdown, "shutdown window must not accrue fee");
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);
        assertEq(vault.balanceOf(feeRcpt), feeAtShutdown, "exit during shutdown must not be billed");

        // The waiver is temporary: after governance re-enables, accrual resumes from the lift.
        vm.prank(governance);
        vault.setEmergencyShutdown(false);
        vm.startPrank(bob);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, bob);
        vm.stopPrank();
        uint256 feeAfterReopen = vault.balanceOf(feeRcpt);
        vm.warp(block.timestamp + 365 days);
        vault.collectFees();
        assertGt(vault.balanceOf(feeRcpt), feeAfterReopen, "accrual must resume after shutdown lifts");
    }

    // ─────────────────────────────────────────────────────────
    // collectFees — elapsed == 0 path (mutation #42 regression guard)
    //   `if (elapsed == 0) return 0;` short-circuits fee accrual when no time
    //   has passed. These pin the observable behaviour: no fee, no mint, no
    //   revert, and no corruption of the last-harvest accounting.
    // ─────────────────────────────────────────────────────────

    /// @notice Collecting in the same block as the last harvest (elapsed == 0)
    ///         mints nothing, returns 0, and does not roll back / double-count accrual.
    function test_collectFees_zeroElapsed_deployTime_noop() public {
        vm.prank(governance);
        vault.setManagementFee(100); // 1% per year

        uint256 amount = 10_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();

        uint256 feeBefore    = vault.balanceOf(feeRcpt);
        uint256 supplyBefore = vault.totalSupply();

        // No time has passed since the constructor set _lastHarvestTimestamp.
        uint256 minted = vault.collectFees();

        assertEq(minted, 0, "elapsed==0 must mint 0 shares");
        assertEq(vault.balanceOf(feeRcpt), feeBefore, "feeRecipient balance unchanged");
        assertEq(vault.totalSupply(), supplyBefore, "totalSupply unchanged");

        // Accrual must not have been corrupted: a full year later collects a full
        // year's fee (≈1%), proving the last-harvest anchor was left at deploy time,
        // not silently advanced or rewound by the zero-elapsed call.
        vm.warp(block.timestamp + 365 days + 6 hours);
        uint256 mintedYear = vault.collectFees();
        assertGt(mintedYear, 0, "one year later a fee is collected");
        uint256 feeAssets = vault.convertToAssets(vault.balanceOf(feeRcpt));
        assertApproxEqRel(feeAssets, 100 * USDC_6, 0.01e18, "~1% of 10k after one year");
    }

    /// @notice A second collectFees in the same block as a successful collect is a no-op.
    function test_collectFees_doubleCollect_sameBlock_secondNoop() public {
        vm.prank(governance);
        vault.setManagementFee(100);

        uint256 amount = 10_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days + 6 hours);
        uint256 first = vault.collectFees();
        assertGt(first, 0, "first collect mints a year's fee");

        uint256 feeAfterFirst = vault.balanceOf(feeRcpt);

        // Same block → elapsed == 0 → must mint nothing more.
        uint256 second = vault.collectFees();
        assertEq(second, 0, "second same-block collect mints 0");
        assertEq(vault.balanceOf(feeRcpt), feeAfterFirst, "no double fee in same block");
    }

    /// @notice Boundary: one second of elapsed time yields a minimal, non-zero pro-rated fee.
    function test_collectFees_oneSecondElapsed_minimalProRata() public {
        vm.prank(governance);
        vault.setManagementFee(100);

        uint256 amount = 10_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + 1); // smallest possible positive elapsed
        uint256 minted = vault.collectFees();

        assertGt(minted, 0, "1s elapsed must accrue a minimal fee (not short-circuited)");
        // And it must be tiny relative to a full year's ~100 USDC.
        uint256 feeAssets = vault.convertToAssets(vault.balanceOf(feeRcpt));
        assertLt(feeAssets, 1 * USDC_6, "1s fee is dust vs a year's fee");
    }

    // ─────────────────────────────────────────────────────────
    // Additional mutation-kill regression guards (audit/MUTATION_TRIAGE.md)
    // ─────────────────────────────────────────────────────────

    /// @notice Part B P4: performance-fee accrual is not implemented, so setting any
    ///         nonzero rate must revert; setting 0 stays a harmless no-op. Kills the
    ///         RequireMutation that would weaken `newFee == 0` to `true`.
    function test_setPerformanceFee_notImplemented_rejectsNonzero() public {
        vm.prank(governance);
        vault.setPerformanceFee(0); // no-op — allowed
        assertEq(vault.performanceFee(), 0);

        vm.prank(governance);
        vm.expectRevert(bytes("VAULT: performance fee not implemented"));
        vault.setPerformanceFee(1); // any nonzero rate — must revert

        vm.prank(governance);
        vm.expectRevert(bytes("VAULT: performance fee not implemented"));
        vault.setPerformanceFee(3000);
    }

    /// @notice _totalDebt bookkeeping is decremented when funds are recalled from the adapter.
    ///         Kills the DeleteExpressionMutation that drops the `_totalDebt -= received` update.
    function test_totalDebt_decrementsOnRecall() public {
        uint256 amount = 1_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);
        vm.stopPrank();

        // After deploy, debt tracks the deployed principal.
        assertApproxEqAbs(vault.totalDebt(), amount, 2, "debt tracks deployed principal");

        // Full exit recalls everything → debt returns to ~0.
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        assertApproxEqAbs(vault.totalDebt(), 0, 2, "debt decremented on full recall");
    }

    /// @notice Partial recall decrements totalDebt() by exactly the recalled amount (not more,
    ///         not added). Pins the `_totalDebt - received` arithmetic where debt > received
    ///         strictly (full-exit hits the ==0 branch and can't distinguish the operator).
    function test_totalDebt_partialRecall_decrementsByRecalled() public {
        uint256 amount = 1_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);
        vm.stopPrank();
        assertApproxEqAbs(vault.totalDebt(), amount, 2, "debt = deployed principal");

        // Redeem half → recall ~half; debt must drop to ~half (strictly debt > received).
        vm.prank(alice);
        vault.redeem(shares / 2, alice, alice);
        assertApproxEqAbs(vault.totalDebt(), amount / 2, 3, "debt decremented by recalled amount");
    }

    /// @notice After a strategy migration, totalDebt() equals the freshly redeployed principal
    ///         (the reset-to-0 then redeploy). Pins the `_totalDebt = 0` reset in setAdapter.
    function test_totalDebt_resetThenRedeploy_onMigration() public {
        uint256 amount = 1_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();

        MockAdapter fresh = new MockAdapter(address(usdc), address(vault));
        vm.startPrank(governance);
        registry.registerAdapter(address(fresh), "DeFi", "Mock v2");
        vault.setAdapter(address(fresh)); // recall(=amount) → reset 0 → redeploy(amount)
        vm.stopPrank();

        // Exact (no tolerance): MockAdapter delivers 100%, so the reset-to-0 then redeploy
        // yields exactly `amount`. A tolerance would mask the `_totalDebt = 0 -> 1` mutation.
        assertEq(vault.totalDebt(), amount, "debt = redeployed principal after migration");
    }

    /// @notice setFeeRecipient rejects the zero address. Kills the RequireMutation that
    ///         weakens `newRecipient != address(0)` to `true`.
    function test_setFeeRecipient_rejectsZero() public {
        vm.prank(governance);
        vm.expectRevert(bytes("VAULT: zero address"));
        vault.setFeeRecipient(address(0));
    }

    /// @notice setManagementFee enforces the hard cap MAX_MANAGEMENT_FEE (500 bps).
    ///         Kills the RequireMutation weakening `newFee <= MAX_MANAGEMENT_FEE` to `true`.
    function test_setManagementFee_enforcesCap() public {
        vm.prank(governance);
        vault.setManagementFee(500); // exactly the cap — allowed
        vm.prank(governance);
        vm.expectRevert(bytes("VAULT: fee too high"));
        vault.setManagementFee(501); // over the cap — must revert
    }

    /// @notice Migration's balance-delta accounting excludes pre-existing idle: `received`
    ///         must be (balanceAfter - balanceBefore), so a shorting adapter still reverts the
    ///         migration even when the vault already holds idle assets. Kills the `-`->`+`
    ///         mutation on that subtraction (which would let idle mask an adapter shortfall).
    function test_setAdapter_migration_balanceDelta_excludesIdle() public {
        FaultyAdapter faulty = new FaultyAdapter(address(usdc), address(vault));
        vm.startPrank(governance);
        registry.registerAdapter(address(faulty), "Test", "Faulty");
        vault.setAdapter(address(faulty));
        vm.stopPrank();

        uint256 amount = 1_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice); // funds now in the faulty adapter
        vm.stopPrank();

        // Pre-existing idle in the vault (e.g. a donation) — must NOT mask a shortfall.
        usdc.mint(address(vault), amount);
        faulty.setDeliverBps(9_000); // adapter under-delivers 90% on the migration recall

        MockAdapter fresh = new MockAdapter(address(usdc), address(vault));
        vm.startPrank(governance);
        registry.registerAdapter(address(fresh), "DeFi", "Mock v2");
        vm.expectRevert(bytes("VAULT: adapter shortfall")); // received counts only the delta
        vault.setAdapter(address(fresh));
        vm.stopPrank();
    }

    /// @notice The constructor rejects a zero governance address. Kills the
    ///         DeleteExpressionMutation that drops the `governance_ != address(0)` guard.
    function test_constructor_rejectsZeroGovernance() public {
        vm.expectRevert(bytes("VAULT: zero governance"));
        new SIXXVault(
            IERC20(address(usdc)), "SIXX", "sx",
            address(0), address(registry), feeRcpt, guardianAddr
        );
    }

    /// @notice Depositing while the strategy is paused (activeAdapter == address(0)) holds
    ///         funds idle and does NOT attempt to push to the zero adapter. Kills the
    ///         IfStatementMutation on the `_deployToAdapter` `activeAdapter == address(0)`
    ///         short-circuit (removing it would try-push to address(0), revert-and-catch, and
    ///         emit AdapterDepositFailed). Note: the identical guard in `_recallFromAdapter` is
    ///         an unreachable defensive check — see audit/MUTATION_TRIAGE.md EQ-1.
    function test_deposit_whilePaused_holdsIdle_noFailureEvent() public {
        // Pause the strategy (explicit address(0) path — bypasses registry per H-1).
        vm.prank(governance);
        vault.setAdapter(address(0));

        uint256 amount = 1_000 * USDC_6;
        vm.recordLogs();
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();

        // Funds stay idle in the vault; totalAssets still reflects them.
        assertEq(usdc.balanceOf(address(vault)), amount, "funds held idle while paused");
        assertApproxEqAbs(vault.totalAssets(), amount, 1, "totalAssets reflects idle funds");

        // The guard must short-circuit — no push to address(0), so no failure event.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 failTopic = keccak256("AdapterDepositFailed(address,uint256)");
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != failTopic, "no AdapterDepositFailed while paused");
        }
    }

    // ─────────────────────────────────────────────────────────
    // Fee-fairness characterization (Threat Council finding #3, MEDIUM)
    //   Documents (does NOT fix) that collectFees is not checkpointed on
    //   deposit/withdraw: a late depositor is diluted for a fee that accrued
    //   before they joined. Fix (crystallize-on-interaction) is a core change
    //   requiring SHIN sign-off + re-audit (workspace ADR-007). These pin the
    //   current behaviour and quantify the unfairness.
    // ─────────────────────────────────────────────────────────

    /// @notice ADR-007 #3 FIX: a depositor who joins right before a fee collection is NOT
    ///         diluted for the prior-period fee. Bob's deposit crystallizes the accrued fee
    ///         (charging only the pre-existing holders) BEFORE his shares are minted, so he
    ///         enters at the post-fee NAV and a subsequent collectFees is a no-op for him.
    function test_collectFees_lateDepositor_notDiluted_afterCrystallize() public {
        vm.prank(governance);
        vault.setManagementFee(100); // 1% / yr

        uint256 amount = 10_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days + 6 hours); // fee accrues

        uint256 feeBefore = vault.balanceOf(feeRcpt);
        // Bob's deposit crystallizes Alice's accrued fee first (feeRecipient gets shares),
        // then mints Bob's shares at the post-fee NAV.
        vm.startPrank(bob);
        usdc.approve(address(vault), amount);
        uint256 bobShares = vault.deposit(amount, bob);
        vm.stopPrank();
        assertGt(vault.balanceOf(feeRcpt), feeBefore, "fee crystallized on deposit (Alice pays, not Bob)");

        uint256 bobValueBefore = vault.convertToAssets(bobShares);
        vault.collectFees(); // now a no-op for the just-consumed window
        uint256 bobValueAfter = vault.convertToAssets(bobShares);

        // Bob is not diluted: his value is unchanged (within share-rounding dust).
        assertApproxEqAbs(bobValueAfter, bobValueBefore, 2, "#3 fixed: late depositor not diluted");
        assertApproxEqRel(bobValueAfter, amount, 0.001e18, "Bob's stake ~= his deposit");
    }

    /// @notice ADR-007 #3: an exiting user cannot dodge the accrued fee — withdrawing
    ///         crystallizes it first, so the fee is charged before they leave.
    function test_collectFees_crystallizedOnWithdraw() public {
        vm.prank(governance);
        vault.setManagementFee(100);
        uint256 amount = 10_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days + 6 hours);
        assertEq(vault.balanceOf(feeRcpt), 0, "no fee minted yet");

        // Alice exits; the withdraw path must crystallize the fee first.
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        assertGt(vault.balanceOf(feeRcpt), 0, "fee crystallized on the exiting user's withdraw");
    }

    /// @notice ADR-007 #3: changing the fee rate crystallizes at the OLD rate first
    ///         (no retroactive re-pricing of the elapsed period).
    function test_setManagementFee_crystallizesAtOldRate() public {
        vm.prank(governance);
        vault.setManagementFee(100); // 1%
        uint256 amount = 10_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days + 6 hours);

        // Raising the rate must first collect the year at the OLD 1% (~100 USDC), not the new rate.
        vm.prank(governance);
        vault.setManagementFee(500); // 5%
        uint256 feeAssets = vault.convertToAssets(vault.balanceOf(feeRcpt));
        assertApproxEqRel(feeAssets, 100 * USDC_6, 0.02e18, "crystallized at old 1%, not new 5%");
    }

    /// @notice Permissionless collectFees at low TVL advances the fee anchor without minting
    ///         (assets==0 || supply==0 path). Benign today (no fee was due), but documents that
    ///         anyone can move `_lastHarvestTimestamp` — relevant once crystallize-on-interaction lands.
    function test_collectFees_permissionless_lowTVL_advancesAnchor_noMint() public {
        vm.prank(governance);
        vault.setManagementFee(100);

        // No deposits: totalSupply == 0.
        vm.warp(block.timestamp + 30 days);
        uint256 supplyBefore = vault.totalSupply();
        uint256 minted = vault.collectFees(); // anyone can call
        assertEq(minted, 0, "no mint when supply is 0");
        assertEq(vault.totalSupply(), supplyBefore, "supply unchanged");

        // Anchor advanced: a subsequent deposit + 1yr collects only ~1 year (not 1yr+30d).
        uint256 amount = 10_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();
        vm.warp(block.timestamp + 365 days + 6 hours);
        vault.collectFees();
        uint256 feeAssets = vault.convertToAssets(vault.balanceOf(feeRcpt));
        assertApproxEqRel(feeAssets, 100 * USDC_6, 0.02e18, "fee ~1yr, anchor was advanced by the low-TVL call");
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

    function test_guardian_can_shutdown_on() public {
        vm.prank(guardianAddr);
        vault.setEmergencyShutdown(true);
        assertTrue(vault.emergencyShutdown());
    }

    function test_guardian_cannot_shutdown_off() public {
        vm.prank(governance);
        vault.setEmergencyShutdown(true);
        vm.prank(guardianAddr);
        vm.expectRevert(bytes("VAULT: not governance"));
        vault.setEmergencyShutdown(false);
    }

    function test_governance_can_toggle_both() public {
        vm.prank(governance);
        vault.setEmergencyShutdown(true);
        assertTrue(vault.emergencyShutdown());
        vm.prank(governance);
        vault.setEmergencyShutdown(false);
        assertFalse(vault.emergencyShutdown());
    }

    function test_third_party_cannot_shutdown() public {
        vm.prank(alice);
        vm.expectRevert(bytes("VAULT: not guardian/gov"));
        vault.setEmergencyShutdown(true);
        vm.prank(alice);
        vm.expectRevert(bytes("VAULT: not governance"));
        vault.setEmergencyShutdown(false);
    }

    function test_guardian_shutdown_still_recalls_and_exempts_lock() public {
        // alice deposits -> funds pushed to adapter, alice locked
        uint256 amt = 1_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amt);
        vault.deposit(amt, alice);
        vm.stopPrank();
        // guardian triggers shutdown: recall from adapter + lock exemption
        vm.prank(guardianAddr);
        vault.setEmergencyShutdown(true);
        // alice can withdraw immediately despite lock (B), funds were recalled (A)
        uint256 maxW = vault.maxWithdraw(alice);
        assertGt(maxW, 0, "lock exempt under shutdown");
        vm.prank(alice);
        vault.withdraw(maxW, alice, alice);
    }
}
