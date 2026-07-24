// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {DCAScheduler} from "../src/periphery/DCAScheduler.sol";

/// @title DCASchedulerForkTest
/// @notice Integration test against LIVE Ethereum mainnet state: real USDC and the
///         live "safe USDC term" SIXXVault (0x5292…b31). Proves the non-custodial
///         round-trip end-to-end — the scheduler pulls a bounded amount of the user's
///         real USDC, deposits into the real vault, and the user (not the scheduler)
///         ends up holding the vault shares and can redeem them back to USDC herself.
///
/// @dev Requires --fork-url $ETH_RPC_URL. Run isolated:
///        forge test --fork-url $ETH_RPC_URL --match-contract DCASchedulerForkTest -vvv
contract DCASchedulerForkTest is Test {
    // ── Ethereum mainnet ──────────────────────────────────────
    address internal constant USDC       = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant SAFE_VAULT  = 0x5292A8DCd18C6512137e8cA6C21dB0dc6b830b31;

    address governance = makeAddr("governance");
    address guardian   = makeAddr("guardian");
    address feeRcpt    = makeAddr("feeRecipient");
    address keeper     = makeAddr("keeper");
    address alice      = makeAddr("aliceFork");

    IERC20       usdc  = IERC20(USDC);
    IERC4626     vault = IERC4626(SAFE_VAULT);
    DCAScheduler sched;

    uint256 constant USDC_1  = 1e6;
    uint256 constant AMOUNT  = 100 * USDC_1;   // 100 USDC / run
    uint256 constant INTERVAL = 30 days;
    uint256 constant CAP     = 300 * USDC_1;   // 3 runs

    function setUp() public {
        // Sanity: confirm the live vault is USDC-denominated before we rely on it.
        require(block.chainid == 1, "fork ETH mainnet");
        require(vault.asset() == USDC, "vault asset != USDC");

        sched = new DCAScheduler(governance, guardian, feeRcpt);
        vm.prank(governance);
        sched.setKeeper(keeper, true);

        // Fund alice with real USDC and set a BOUNDED allowance to the scheduler.
        deal(USDC, alice, 10_000 * USDC_1);
        vm.prank(alice);
        usdc.approve(address(sched), CAP);
    }

    function test_fork_roundTrip_userOwnsSharesNotScheduler() public {
        // Skip gracefully if the live vault is in emergency shutdown at the pinned block.
        if (vault.maxDeposit(alice) < AMOUNT) {
            emit log("live vault maxDeposit < AMOUNT (shutdown?) - skipping deposit round-trip");
            return;
        }

        vm.prank(alice);
        uint256 planId = sched.createPlan(USDC, SAFE_VAULT, AMOUNT, INTERVAL, 0, 0, CAP);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        // ── Run 1 ──
        vm.prank(keeper);
        sched.execute(planId);

        // Shares are minted to ALICE, never to the scheduler or keeper (non-custodial).
        uint256 aliceShares = vault.balanceOf(alice);
        assertGt(aliceShares, 0, "alice got no shares");
        assertEq(vault.balanceOf(address(sched)), 0, "scheduler must hold no shares");
        assertEq(vault.balanceOf(keeper), 0, "keeper must hold no shares");
        // Scheduler custodies no USDC between txs.
        assertEq(usdc.balanceOf(address(sched)), 0, "scheduler must hold no USDC");
        // Exactly AMOUNT pulled from alice.
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore - AMOUNT, "wrong pull amount");

        // ── Run 2 (after interval) ──
        vm.warp(block.timestamp + INTERVAL);
        vm.prank(keeper);
        sched.execute(planId);
        assertGt(vault.balanceOf(alice), aliceShares, "shares did not grow on run 2");
        assertEq(usdc.balanceOf(address(sched)), 0);

        // ── User sovereignty: alice redeems her own shares back to USDC herself ──
        // (caller==receiver was never true on the DCA deposits, so alice is unlocked — H-3/H-4.)
        uint256 redeemable = vault.maxRedeem(alice);
        assertGt(redeemable, 0, "alice cannot redeem her own shares");
        vm.prank(alice);
        uint256 assetsOut = vault.redeem(redeemable, alice, alice);
        assertGt(assetsOut, 0, "redeem returned nothing");
        assertEq(vault.balanceOf(alice), 0, "alice still holds shares after full redeem");
    }

    function test_fork_allowanceIsHardCeiling() public {
        if (vault.maxDeposit(alice) < AMOUNT) {
            emit log("live vault maxDeposit < AMOUNT - skipping");
            return;
        }
        // Shrink allowance to a single run.
        vm.prank(alice);
        usdc.approve(address(sched), AMOUNT);

        vm.prank(alice);
        uint256 planId = sched.createPlan(USDC, SAFE_VAULT, AMOUNT, INTERVAL, 0, 0, CAP);

        vm.prank(keeper);
        sched.execute(planId); // consumes the whole allowance

        vm.warp(block.timestamp + INTERVAL);
        vm.prank(keeper);
        vm.expectRevert(); // allowance exhausted — keeper cannot pull beyond the user's approval
        sched.execute(planId);
    }
}
