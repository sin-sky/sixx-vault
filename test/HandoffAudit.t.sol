// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {HarvestAdapter} from "./mocks/HarvestAdapter.sol";
import {MockAdapter} from "./mocks/MockAdapter.sol";
import {MockUSDC} from "./SIXXVault.t.sol";
import {ISIXXVault} from "../src/interfaces/ISIXXVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title HandoffAudit
/// @notice Behavior tests pinning the SHIN-approved remediation of the independent
///         handoff audit (SIXX_Vault_Handoff_Audit_Report.md): M-01/M-02/M-03 on the
///         vault, plus the "Test Coverage Gaps" the report called out for the vault core.
///         Pendle-adapter items (M-04/M-05) live in the fork suite by project convention.
contract HandoffAuditTest is Test {
    address governance   = address(0xBEEF);
    address alice        = address(0xA11CE);
    address bob          = address(0xB0B);
    address carol        = address(0xCA401);
    address feeRcpt      = address(0xFEE);
    address guardianAddr = address(0x6042D);
    address lossSink     = address(0xDEAD);

    MockUSDC        usdc;
    AdapterRegistry registry;
    SIXXVault       vault;
    HarvestAdapter  adapter;

    uint256 constant USDC_6 = 1e6;
    uint256 constant PERIOD = 8 hours; // PROFIT_UNLOCK_PERIOD

    function setUp() public {
        usdc = new MockUSDC();
        vm.prank(governance);
        registry = new AdapterRegistry(governance);
        vm.prank(governance);
        vault = new SIXXVault(
            IERC20(address(usdc)), "SIXX Stable Yield", "sxUSDC",
            governance, address(registry), feeRcpt, guardianAddr
        );
        adapter = new HarvestAdapter(address(usdc), address(vault));
        vm.startPrank(governance);
        registry.registerAdapter(address(adapter), "DeFi", "Harvest");
        vault.setAdapter(address(adapter));
        vm.stopPrank();

        usdc.mint(alice, 100_000 * USDC_6);
        usdc.mint(bob,   100_000 * USDC_6);
        // This contract funds discrete rewards into the HarvestAdapter.
        usdc.mint(address(this), 1_000_000 * USDC_6);
        usdc.approve(address(adapter), type(uint256).max);
    }

    // ─── helpers ─────────────────────────────────────────────────────────
    function _deposit(address who, uint256 amt) internal returns (uint256 shares) {
        vm.startPrank(who);
        usdc.approve(address(vault), amt);
        shares = vault.deposit(amt, who);
        vm.stopPrank();
    }

    function _harvestReward(uint256 reward) internal returns (uint256 profit) {
        if (reward > 0) adapter.addReward(reward);
        profit = vault.harvest();
    }

    // =====================================================================
    // M-01 — management fee 0 -> nonzero must NOT charge the zero-fee window
    // =====================================================================

    /// Enabling a nonzero management fee after a long zero-fee period must only
    /// charge going forward. The stale fee anchor (never advanced while fee == 0)
    /// previously let the first post-enable collect bill the whole elapsed window.
    function test_M01_enableFromZero_noRetroactiveCharge() public {
        _deposit(alice, 10_000 * USDC_6);

        // 180 days pass with the fee at zero.
        skip(180 days);
        assertEq(vault.balanceOf(feeRcpt), 0, "fee minted while rate was zero");

        // Enable 2%/yr, then crystallize in the SAME block.
        vm.prank(governance);
        vault.setManagementFee(200);
        vault.collectFees();

        // With the fix the anchor was advanced at enable-time → zero elapsed → zero fee.
        // Without it, this collect would bill ~180 days of the new rate to feeRcpt.
        assertEq(vault.balanceOf(feeRcpt), 0, "M-01: retroactive fee charged over zero-fee window");

        // Sanity: the fee still accrues on time that elapses AFTER enabling.
        skip(365 days + 6 hours);
        vault.collectFees();
        assertGt(vault.balanceOf(feeRcpt), 0, "fee failed to accrue going forward");
    }

    // =====================================================================
    // M-02 — a permissionless zero-profit harvest must not extend the unlock
    // =====================================================================

    function test_M02_zeroProfitHarvest_doesNotExtendUnlock() public {
        _deposit(alice, 10_000 * USDC_6);

        uint256 t0 = block.timestamp;
        uint256 reward = 1_000 * USDC_6;
        assertEq(_harvestReward(reward), reward, "first harvest should realize the reward");
        assertEq(vault.lockedProfit(), reward, "reward not locked");

        // Halfway through the 8h window.
        skip(4 hours);
        uint256 lpMid = vault.lockedProfit();
        assertApproxEqAbs(lpMid, reward / 2, 2, "half the profit should remain locked");

        // Anyone calls harvest() with no new profit — must be a no-op on the schedule.
        assertEq(_harvestReward(0), 0, "no new profit expected");
        assertEq(vault.lockedProfit(), lpMid, "zero-profit harvest changed the locked amount");

        // The original schedule must still fully unlock at t0 + PERIOD, NOT be pushed out.
        vm.warp(t0 + PERIOD + 1);
        assertEq(vault.lockedProfit(), 0, "M-02: zero-profit harvest extended the unlock tail");
    }

    /// Profit-streaming rollover: a positive harvest before the first window fully
    /// unlocks carries the still-locked remainder plus the new profit, and restarts.
    function test_M02_streamingRollover_consecutivePositiveHarvests() public {
        _deposit(alice, 10_000 * USDC_6);

        uint256 r1 = 1_000 * USDC_6;
        _harvestReward(r1);
        skip(4 hours);
        uint256 remain = vault.lockedProfit(); // ~r1/2

        uint256 r2 = 600 * USDC_6;
        assertEq(_harvestReward(r2), r2, "second harvest should realize r2");
        assertApproxEqAbs(vault.lockedProfit(), remain + r2, 2, "rollover did not carry remainder + new profit");

        // From this restart it unlocks over a fresh PERIOD.
        skip(PERIOD + 1);
        assertEq(vault.lockedProfit(), 0, "rollover failed to fully unlock");
        assertApproxEqAbs(
            vault.totalAssets(), (10_000 + 1_000 + 600) * USDC_6, 2, "principal + both rewards not fully vested"
        );
    }

    // =====================================================================
    // M-03 — force-detach writeoff clears locked profit and pauses deposits
    // =====================================================================

    function test_M03_forceDetachWriteoff_clearsLockedProfit_pausesDeposits() public {
        _deposit(alice, 10_000 * USDC_6);
        _harvestReward(2_000 * USDC_6);
        assertEq(vault.lockedProfit(), 2_000 * USDC_6, "profit not locked");

        // Adapter now under-delivers: a force-detach best-effort recall writes off 20%.
        adapter.setDeliverBps(8_000);
        vm.prank(governance);
        vault.setAdapter(address(0)); // force-detach

        // Locked profit cleared → totalAssets reflects the honest recalled balance,
        // NOT a near-zero clamp against a stale buffer.
        assertEq(vault.lockedProfit(), 0, "M-03: locked profit not cleared on writeoff");
        assertTrue(vault.depositsPaused(), "M-03: deposits not paused after writeoff");
        assertApproxEqAbs(vault.totalAssets(), 9_600 * USDC_6, 2, "totalAssets should equal honest raw");

        // Deposits are blocked until governance reopens. H-01: the pause now also
        //   surfaces through maxDeposit()==0, so OZ v5 throws ERC4626ExceededMaxDeposit
        //   before the vault's own "VAULT: deposits paused" check (same ordering as shutdown).
        assertEq(vault.maxDeposit(bob), 0, "pause not reflected in maxDeposit");
        vm.startPrank(bob);
        usdc.approve(address(vault), 1_000 * USDC_6);
        vm.expectRevert(abi.encodeWithSelector(
            bytes4(keccak256("ERC4626ExceededMaxDeposit(address,uint256,uint256)")),
            bob, uint256(1_000 * USDC_6), uint256(0)
        ));
        vault.deposit(1_000 * USDC_6, bob);
        vm.stopPrank();

        // Explicit governance reopen (strategy stays idle).
        vm.prank(governance);
        vault.reopenDeposits();
        assertFalse(vault.depositsPaused(), "reopen failed");
        assertGt(_deposit(bob, 1_000 * USDC_6), 0, "deposit blocked after reopen");
    }

    /// Attaching a healthy adapter after a lossy detach also re-opens deposits.
    function test_M03_healthyReattach_autoReopensDeposits() public {
        _deposit(alice, 10_000 * USDC_6);
        _harvestReward(2_000 * USDC_6);
        adapter.setDeliverBps(8_000);

        vm.prank(governance);
        vault.setAdapter(address(0));
        assertTrue(vault.depositsPaused(), "not paused after writeoff");

        MockAdapter fresh = new MockAdapter(address(usdc), address(vault));
        vm.startPrank(governance);
        registry.registerAdapter(address(fresh), "DeFi", "Fresh");
        vault.setAdapter(address(fresh)); // healthy reattach == governance reopen
        vm.stopPrank();

        assertFalse(vault.depositsPaused(), "healthy reattach did not reopen deposits");
        assertGt(_deposit(bob, 1_000 * USDC_6), 0, "deposit blocked after reattach");
    }

    /// The locked-profit-suppressed-denominator hazard: a loss drops raw assets
    /// at/under the still-locked buffer, so totalAssets() clamps to zero. A deposit
    /// must be refused here (would mint against ~0 denominator), then re-enabled once
    /// the buffer decays away.
    function test_M03_impairedDenominator_blocksDeposit_thenRecovers() public {
        _deposit(alice, 1_000 * USDC_6);
        _harvestReward(5_000 * USDC_6); // lockedProfit = 5000, raw = 6000

        // Realized loss on principal: raw falls to 500, still-locked buffer is 5000.
        adapter.simulateLoss(5_500 * USDC_6, lossSink);
        assertGt(vault.lockedProfit(), 0, "buffer should still be locked");
        assertEq(vault.totalAssets(), 0, "expected locked-profit-clamped zero denominator");

        vm.startPrank(bob);
        usdc.approve(address(vault), 1_000 * USDC_6);
        vm.expectRevert("VAULT: assets impaired");
        vault.deposit(1_000 * USDC_6, bob);
        vm.stopPrank();

        // Once the buffer fully decays, the honest (reduced) NAV is positive again and
        // deposits resume at fair pricing.
        skip(PERIOD + 1);
        assertEq(vault.lockedProfit(), 0, "buffer failed to decay");
        assertGt(vault.totalAssets(), 0, "honest NAV should be positive after decay");
        assertGt(_deposit(bob, 1_000 * USDC_6), 0, "deposit still blocked after recovery");
    }

    // =====================================================================
    // Non-custodial: an approved third-party caller redeems to a DISTINCT
    // receiver; assets go only to that receiver — no product/keeper wallet.
    // =====================================================================

    function test_nonCustodial_thirdPartyRedeem_toDistinctReceiver() public {
        uint256 aliceShares = _deposit(alice, 5_000 * USDC_6);

        // Alice approves bob to spend her vault shares.
        vm.prank(alice);
        vault.approve(bob, aliceShares);

        uint256 carolBefore = usdc.balanceOf(carol);
        // Bob (caller) redeems Alice's (owner) shares, delivering to Carol (receiver).
        vm.prank(bob);
        uint256 out = vault.redeem(aliceShares, carol, alice);

        assertGt(out, 0, "no assets realized");
        assertEq(usdc.balanceOf(carol) - carolBefore, out, "receiver did not get exactly the realized assets");
        assertEq(vault.balanceOf(alice), 0, "owner shares not burned");
        assertEq(usdc.balanceOf(bob), 100_000 * USDC_6, "caller wallet received assets (custodial leak)");
        // Nothing stranded at the vault or a product wallet.
        assertEq(usdc.balanceOf(address(vault)), 0, "assets stranded in vault");
        assertEq(adapter.totalAssets(), 0, "assets stranded in adapter");
    }
}
