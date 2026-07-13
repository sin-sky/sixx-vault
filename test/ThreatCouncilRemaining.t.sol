// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {MockAdapter} from "./mocks/MockAdapter.sol";
import {FaultyAdapter} from "./mocks/FaultyAdapter.sol";
import {MockUSDC} from "./SIXXVault.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ThreatCouncilRemaining
/// @notice PoC suite for the SIXX Threat Council "remaining vectors" round:
///         ② access control · ③ rounding/shares/inflation · ④ oracle/price ·
///         ⑦ DoS/stranding · ⑧ signature/replay.
///         Part A only — no production code is modified. Each test either proves a
///         real exposure (would be escalated to Part B) or green-proves the existing
///         defense. See audit/THREAT_COUNCIL_REMAINING_2026-07-11.md for the mapping.
contract ThreatCouncilRemainingTest is Test {
    // ─── Actors ──────────────────────────────────────────────
    address governance   = address(0xBEEF);
    address alice        = address(0xA11CE);
    address bob          = address(0xB0B);
    address attacker     = address(0xBAD);
    address feeRcpt      = address(0xFEE);
    address guardianAddr = address(0x6042D);
    address stranger     = address(0x57A6E);

    // ─── Contracts ───────────────────────────────────────────
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
            IERC20(address(usdc)),
            "SIXX Stable Yield",
            "sxUSDC",
            governance,
            address(registry),
            feeRcpt,
            guardianAddr
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

    // ─── helpers ─────────────────────────────────────────────
    function _deposit(address who, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(who);
        usdc.approve(address(vault), amount);
        shares = vault.deposit(amount, who);
        vm.stopPrank();
    }

    // =====================================================================
    // ② ACCESS CONTROL — unauthorized-revert sweep (AC1/AC3)
    //    Every privileged mutator must revert for a non-authorized caller.
    // =====================================================================

    function test_AC_setAdapter_unauthorizedReverts() public {
        vm.prank(stranger);
        vm.expectRevert("VAULT: not governance");
        vault.setAdapter(address(0));
    }

    function test_AC_setLockPeriod_unauthorizedReverts() public {
        vm.prank(stranger);
        vm.expectRevert("VAULT: not governance");
        vault.setLockPeriod(1 days);
    }

    function test_AC_setPerformanceFee_unauthorizedReverts() public {
        vm.prank(stranger);
        vm.expectRevert("VAULT: not governance");
        vault.setPerformanceFee(100);
    }

    function test_AC_setManagementFee_unauthorizedReverts() public {
        vm.prank(stranger);
        vm.expectRevert("VAULT: not governance");
        vault.setManagementFee(100);
    }

    function test_AC_setFeeRecipient_unauthorizedReverts() public {
        vm.prank(stranger);
        vm.expectRevert("VAULT: not governance");
        vault.setFeeRecipient(stranger);
    }

    function test_AC_setGuardian_unauthorizedReverts() public {
        vm.prank(stranger);
        vm.expectRevert("VAULT: not governance");
        vault.setGuardian(stranger);
    }

    function test_AC_proposeGovernance_unauthorizedReverts() public {
        vm.prank(stranger);
        vm.expectRevert("VAULT: not governance");
        vault.proposeGovernance(stranger);
    }

    /// AC1: a random address can neither pause nor unpause.
    function test_AC_emergencyShutdown_activate_unauthorizedReverts() public {
        vm.prank(stranger);
        vm.expectRevert("VAULT: not guardian/gov");
        vault.setEmergencyShutdown(true);
    }

    /// AC9 (pause/unpause separation): the guardian may PAUSE but may NOT UNPAUSE.
    function test_AC_emergencyShutdown_guardianCannotUnpause() public {
        vm.prank(guardianAddr);
        vault.setEmergencyShutdown(true);            // guardian pauses OK
        assertTrue(vault.emergencyShutdown());

        vm.prank(guardianAddr);
        vm.expectRevert("VAULT: not governance");    // guardian cannot lift it
        vault.setEmergencyShutdown(false);

        vm.prank(governance);
        vault.setEmergencyShutdown(false);           // only governance can
        assertFalse(vault.emergencyShutdown());
    }

    /// AC2 defense: acceptGovernance is only callable by the pending address.
    function test_AC_acceptGovernance_onlyPending() public {
        vm.prank(governance);
        vault.proposeGovernance(alice);

        vm.prank(stranger);
        vm.expectRevert("VAULT: not pending governance");
        vault.acceptGovernance();
    }

    /// AC10 / registry: only governance can register or (de)activate adapters.
    function test_AC_registry_registerAdapter_unauthorizedReverts() public {
        vm.prank(stranger);
        vm.expectRevert("REGISTRY: not governance");
        registry.registerAdapter(address(0x1234), "DeFi", "X");
    }

    function test_AC_registry_setAdapterStatus_unauthorizedReverts() public {
        vm.prank(stranger);
        vm.expectRevert("REGISTRY: not governance");
        registry.setAdapterStatus(address(adapter), false);
    }

    /// AC (M-3 self-call boundary): the atomic-push helper is callable only by the
    /// vault itself; an external caller cannot drive vault funds into an adapter.
    function test_AC_atomicPushToAdapter_selfOnly() public {
        vm.prank(stranger);
        vm.expectRevert("VAULT: self only");
        vault.__atomicPushToAdapter(address(adapter), 1);
    }

    // ─── ② positive control: 2-step governance actually transfers power (AC7) ──
    function test_AC_twoStepGovernance_transfersPowerAtomically() public {
        // old gov still in control before acceptance
        vm.prank(governance);
        vault.proposeGovernance(alice);
        assertEq(vault.governance(), governance, "gov unchanged until accept");

        // old gov can still act; pending cannot yet
        vm.prank(alice);
        vm.expectRevert("VAULT: not governance");
        vault.setLockPeriod(1 days);

        // accept flips control
        vm.prank(alice);
        vault.acceptGovernance();
        assertEq(vault.governance(), alice, "gov transferred");
        assertEq(vault.pendingGovernance(), address(0), "pending cleared");

        // old gov now powerless; new gov empowered
        vm.prank(governance);
        vm.expectRevert("VAULT: not governance");
        vault.setLockPeriod(2 days);

        vm.prank(alice);
        vault.setLockPeriod(2 days);
        assertEq(vault.lockPeriod(), 2 days);
    }

    // =====================================================================
    // ③ ROUNDING / SHARES / INFLATION
    // =====================================================================

    /// RD1: classic first-depositor / donation inflation. With OZ v5 virtual shares
    ///      (_decimalsOffset()=9), an attacker who seeds 1 wei then donates a large
    ///      amount cannot rob a subsequent depositor: the victim must not lose a
    ///      meaningful fraction, and the attacker must not profit.
    function test_RD1_firstDepositorInflation_defended() public {
        // Attacker seeds the vault with the minimum and donates a large amount.
        uint256 seed = 1;                 // 1 wei of USDC
        uint256 donation = 10_000 * USDC_6;
        uint256 attackerSpent = seed + donation;

        uint256 aShares = _deposit(attacker, seed);
        // Direct donation to inflate share price (front-run the victim).
        vm.prank(attacker);
        usdc.transfer(address(vault), donation);

        // Victim deposits after the donation.
        uint256 victimDeposit = 1_000 * USDC_6;
        uint256 vShares = _deposit(bob, victimDeposit);

        // Victim must receive > 0 shares and be able to redeem ~all of their deposit.
        assertGt(vShares, 0, "victim minted zero shares (inflation succeeded)");
        uint256 victimRedeemable = vault.previewRedeem(vShares);
        // Allow at most 0.01% loss to rounding.
        assertGe(
            victimRedeemable,
            victimDeposit - victimDeposit / 10_000,
            "victim lost a meaningful fraction to inflation"
        );

        // Attacker must not profit: redeem everything they hold and compare to spend.
        uint256 attackerRedeemable = vault.previewRedeem(aShares);
        assertLe(attackerRedeemable, attackerSpent, "attacker profited from inflation");
    }

    /// RD3: dust attack — repeated tiny deposit/withdraw cycles must not let a user
    ///      extract value, and must not push the vault into insolvency.
    function test_RD3_dustCycles_noProfit_noInsolvency() public {
        // Seed some real liquidity first.
        _deposit(alice, 1_000 * USDC_6);

        uint256 startBal = usdc.balanceOf(attacker);
        vm.startPrank(attacker);
        for (uint256 i = 0; i < 200; i++) {
            uint256 amt = 3; // 3 wei of USDC — deliberately dust
            usdc.approve(address(vault), amt);
            uint256 sh = vault.deposit(amt, attacker);
            if (sh > 0) {
                // withdraw everything the shares are worth
                uint256 assetsOut = vault.previewRedeem(sh);
                if (assetsOut > 0) vault.redeem(sh, attacker, attacker);
                else vault.redeem(sh, attacker, attacker); // burns dust shares for 0
            }
        }
        vm.stopPrank();

        // Attacker never gains (rounding is vault-favorable).
        assertLe(usdc.balanceOf(attacker), startBal, "dust cycles produced a profit");

        // Vault stays solvent: everything the outstanding shares claim is backed.
        _assertSolvent();
    }

    /// RD4: a direct token donation (no shares minted) benefits existing holders and
    ///      never creates insolvency; the donor cannot reclaim more than they hold.
    function test_RD4_directDonation_noInsolvency_noShareTheft() public {
        _deposit(alice, 1_000 * USDC_6);
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 aliceBefore = vault.previewRedeem(aliceShares);

        // Attacker donates directly — mints no shares.
        vm.prank(attacker);
        usdc.transfer(address(vault), 5_000 * USDC_6);

        // Attacker holds no shares → cannot extract the donation.
        assertEq(vault.balanceOf(attacker), 0, "donation minted attacker shares");

        // Existing holder's claim only goes UP, and vault stays solvent.
        uint256 aliceAfter = vault.previewRedeem(aliceShares);
        assertGe(aliceAfter, aliceBefore, "donation reduced honest holder claim");
        _assertSolvent();
    }

    /// RD5 [FIXED — Part B P1]: a nonzero deposit that rounds to ZERO shares now
    ///      reverts (`VAULT: zero shares`) instead of silently taking dust assets for
    ///      0 shares. Proves the guard added to SIXXVault.deposit and that bob is not
    ///      charged. (Pre-fix: OZ v5 ERC-4626 took the dust — see REMEDIATION_PROPOSALS P1.)
    function test_RD5_zeroShareDeposit_nowReverts() public {
        // Drive price-per-share high enough that a 1-wei deposit truncates to 0 shares.
        _deposit(alice, 1);                              // 1 wei seed
        vm.prank(attacker);
        usdc.transfer(address(vault), 50_000 * USDC_6);  // huge donation → high pps

        uint256 tiny = 1; // 1 wei USDC
        assertEq(vault.previewDeposit(tiny), 0, "setup: expected a zero-share deposit");

        vm.startPrank(bob);
        usdc.approve(address(vault), tiny);
        uint256 balBefore = usdc.balanceOf(bob);
        vm.expectRevert("VAULT: zero shares");
        vault.deposit(tiny, bob);
        vm.stopPrank();

        assertEq(usdc.balanceOf(bob), balBefore, "reverted but funds moved");
        assertEq(vault.balanceOf(bob), 0, "bob holds no shares");
        _assertSolvent();
    }

    // =====================================================================
    // ④ ORACLE / PRICE — totalAssets is redemption/accounting-based, not spot.
    //    Flash-loan / donation to the *adapter* cannot inflate the vault NAV,
    //    because MockAdapter (like the real Aave/Venus/Ethena adapters) reports
    //    an internal accounting balance, not a token balance a stranger can bump.
    // =====================================================================

    function test_OR_adapterStrayDonation_doesNotInflateVaultNAV() public {
        _deposit(alice, 1_000 * USDC_6);
        uint256 navBefore = vault.totalAssets();
        uint256 ppsBefore = vault.convertToAssets(1e15); // price-per (1e15) shares

        // A stranger sends tokens straight to the adapter contract (simulating a flash
        // donation aimed at moving a spot-priced NAV). A redemption-based adapter does
        // not count stray tokens, so NAV must be unchanged.
        usdc.mint(stranger, 100_000 * USDC_6);
        vm.prank(stranger);
        usdc.transfer(address(adapter), 100_000 * USDC_6);

        assertEq(vault.totalAssets(), navBefore, "stray adapter tokens inflated NAV (spot-priced!)");
        assertEq(vault.convertToAssets(1e15), ppsBefore, "price-per-share moved via donation");
    }

    /// ④ + ③: an in-block "inflate then victim deposits" sequence cannot rob the
    ///      victim (share price is bounded by virtual shares, not a spot read).
    function test_OR_inBlockInflateThenVictim_cannotRob() public {
        // attacker seeds + inflates + victim deposits, all in one block (no warp).
        uint256 aShares = _deposit(attacker, 1);
        vm.prank(attacker);
        usdc.transfer(address(vault), 20_000 * USDC_6);
        uint256 vShares = _deposit(bob, 2_000 * USDC_6);

        assertGt(vShares, 0, "victim got 0 shares");
        assertGe(
            vault.previewRedeem(vShares),
            2_000 * USDC_6 - (2_000 * USDC_6) / 10_000,
            "victim robbed within the block"
        );
        assertLe(vault.previewRedeem(aShares), 20_000 * USDC_6 + 1, "attacker net profit");
    }

    // =====================================================================
    // ⑦ DoS / STRANDING — the exit valves must ALWAYS work, even with a
    //    broken adapter, and no vault-level permanent brick may exist.
    // =====================================================================

    function _swapToFaulty() internal returns (FaultyAdapter f) {
        f = new FaultyAdapter(address(usdc), address(vault));
        vm.startPrank(governance);
        registry.registerAdapter(address(f), "Test", "Faulty");
        vault.setAdapter(address(f)); // migrates funds from mock to faulty
        vm.stopPrank();
    }

    /// DoS3/DoS6: force-detach (setAdapter(0)) succeeds even when the adapter's
    ///            withdraw() reverts — governance can always pause to idle.
    function test_DoS_forceDetach_succeeds_whenWithdrawReverts() public {
        _deposit(alice, 1_000 * USDC_6);
        FaultyAdapter f = _swapToFaulty();
        f.setRevertOnWithdraw(true);

        vm.prank(governance);
        vault.setAdapter(address(0)); // must NOT revert
        assertEq(vault.activeAdapter(), address(0), "force-detach failed to unbrick");
    }

    /// DoS6: force-detach also survives an adapter whose totalAssets() reverts
    ///       (not-ready oracle / broken TWAP) — the mark read is try/caught.
    /// H-01: an UNREADABLE valuation at force-detach means the position could not be
    ///       marked at all — deposits MUST pause (nobody may mint against an unknown
    ///       NAV), the pause MUST surface through the max* views, and a deposit attempt
    ///       MUST revert and mint no shares (no dilution). Strengthened per 2nd review.
    function test_DoS_forceDetach_succeeds_whenTotalAssetsReverts() public {
        _deposit(alice, 1_000 * USDC_6);
        FaultyAdapter f = _swapToFaulty();
        f.setRevertOnTotalAssets(true);

        uint256 supplyBefore = vault.totalSupply();

        vm.prank(governance);
        vault.setAdapter(address(0));
        assertEq(vault.activeAdapter(), address(0), "detach bricked by reverting totalAssets");

        // H-01: unreadable NAV → deposits paused, reflected in the ERC-4626 max* views.
        assertTrue(vault.depositsPaused(), "H-01: deposits not paused after unreadable force-detach");
        assertEq(vault.maxDeposit(bob), 0, "H-01: maxDeposit not 0 while paused");
        assertEq(vault.maxMint(bob), 0, "H-01: maxMint not 0 while paused");

        // H-01: a deposit against the mismarked pool reverts and mints nothing (no dilution).
        //   maxDeposit()==0 → OZ v5 throws ERC4626ExceededMaxDeposit before the vault's own
        //   "VAULT: deposits paused" check (same ordering as emergency shutdown).
        vm.startPrank(bob);
        usdc.approve(address(vault), 1_000 * USDC_6);
        vm.expectRevert(abi.encodeWithSelector(
            bytes4(keccak256("ERC4626ExceededMaxDeposit(address,uint256,uint256)")),
            bob, uint256(1_000 * USDC_6), uint256(0)
        ));
        vault.deposit(1_000 * USDC_6, bob);
        vm.stopPrank();
        assertEq(vault.totalSupply(), supplyBefore, "H-01: shares minted against impaired pool");

        // reopenDeposits is the governance-confirmed valuation-recovery path.
        vm.prank(governance);
        vault.reopenDeposits();
        assertFalse(vault.depositsPaused(), "H-01: reopen failed");
    }

    /// DoS6: emergency shutdown flag is set regardless of adapter health — the valve
    ///       cannot be bricked by a frozen adapter (both withdraw & totalAssets revert).
    function test_DoS_emergencyShutdown_alwaysSets_evenWhenAdapterFullyFrozen() public {
        _deposit(alice, 1_000 * USDC_6);
        FaultyAdapter f = _swapToFaulty();
        f.setRevertOnWithdraw(true);
        f.setRevertOnTotalAssets(true);

        vm.prank(guardianAddr);
        vault.setEmergencyShutdown(true); // must NOT revert
        assertTrue(vault.emergencyShutdown(), "shutdown bricked by frozen adapter");

        // deposits are blocked while shut down (valve semantics)
        assertEq(vault.maxDeposit(alice), 0);
    }

    /// DoS7: a user withdraw reverts under a real shortfall (realizable < mark), BUT
    ///       that is a liveness pause, not a permanent brick — governance force-detach
    ///       then lets users exit pro-rata against whatever was realized. Proves the
    ///       "no permanent stuck at vault level" claim end-to-end.
    function test_DoS_shortfallPausesUser_thenForceDetachRestoresExit() public {
        _deposit(alice, 1_000 * USDC_6);
        _deposit(bob,   1_000 * USDC_6);
        FaultyAdapter f = _swapToFaulty();
        f.setDeliverBps(8_000); // adapter only returns 80% of any recall → realizable < mark

        // ADR-007 柱1: Alice's full-value withdraw is NOT paused by the shortfall — it partial-fills
        //   to the realizable ~80% with no revert (the old "VAULT: adapter shortfall" brick is gone).
        uint256 aliceAssets = vault.previewRedeem(vault.balanceOf(alice));
        vm.prank(alice);
        uint256 aliceEarly = vault.withdraw(aliceAssets, alice, alice);
        assertApproxEqRel(aliceEarly, (aliceAssets * 8_000) / 10_000, 0.02e18, "partial-fill ~80%, not paused");
        assertGt(vault.balanceOf(alice), 0, "unfilled remainder kept as residual shares (not stuck)");

        // Governance force-detaches: best-effort recall books the realized 80%.
        vm.prank(governance);
        vault.setAdapter(address(0));
        assertEq(vault.activeAdapter(), address(0));

        // Now BOTH users can exit — pro-rata against the reduced (haircut) NAV. No revert.
        uint256 aliceSh = vault.balanceOf(alice);
        uint256 bobSh   = vault.balanceOf(bob);
        vm.prank(alice);
        uint256 aliceOut = vault.redeem(aliceSh, alice, alice);
        vm.prank(bob);
        uint256 bobOut   = vault.redeem(bobSh, bob, bob);
        assertGt(aliceOut, 0, "alice permanently stuck");
        assertGt(bobOut,   0, "bob permanently stuck");
        // Vault fully drained after both exit (no residual stranded at vault level).
        assertLe(vault.totalSupply(), 1e15 + 1, "shares stranded"); // ~virtual dust only
    }

    /// DoS: after a force-detach the vault is fully operational again with a fresh
    ///      adapter — proving the brick is transient, not terminal.
    function test_DoS_vaultFullyOperational_afterForceDetachAndReattach() public {
        _deposit(alice, 1_000 * USDC_6);
        FaultyAdapter f = _swapToFaulty();
        f.setRevertOnWithdraw(true);

        vm.prank(governance);
        vault.setAdapter(address(0)); // pause to idle

        // Re-attach a healthy adapter and confirm deposit/withdraw both work.
        MockAdapter fresh = new MockAdapter(address(usdc), address(vault));
        vm.startPrank(governance);
        registry.registerAdapter(address(fresh), "DeFi", "Mock2");
        vault.setAdapter(address(fresh));
        vm.stopPrank();

        uint256 sh = _deposit(bob, 500 * USDC_6);
        assertGt(sh, 0, "vault not operational after reattach");
        vm.prank(bob);
        uint256 out = vault.redeem(sh, bob, bob);
        assertGt(out, 0, "cannot withdraw after reattach");
    }

    // =====================================================================
    // ⑧ SIGNATURE / REPLAY — the vault exposes NO signature surface.
    //    sxUSDC is plain OZ ERC20 (no ERC20Permit), so there is no EIP-712 domain,
    //    no nonces, and no cross-chain-replayable signed message at the vault.
    // =====================================================================

    function test_SG_vault_hasNoPermitFunction() public {
        // EIP-2612 permit(owner,spender,value,deadline,v,r,s) selector.
        bytes4 permitSel = bytes4(keccak256("permit(address,address,uint256,uint256,uint8,bytes32,bytes32)"));
        (bool ok, ) = address(vault).call(
            abi.encodeWithSelector(permitSel, alice, bob, 1, type(uint256).max, uint8(27), bytes32(0), bytes32(0))
        );
        assertFalse(ok, "vault unexpectedly exposes permit() - signature surface exists");
    }

    function test_SG_vault_hasNoDomainSeparator() public {
        bytes4 dsSel = bytes4(keccak256("DOMAIN_SEPARATOR()"));
        (bool ok, ) = address(vault).call(abi.encodeWithSelector(dsSel));
        assertFalse(ok, "vault exposes DOMAIN_SEPARATOR - unexpected signed-message surface");
    }

    function test_SG_vault_hasNoNonces() public {
        bytes4 nSel = bytes4(keccak256("nonces(address)"));
        (bool ok, ) = address(vault).call(abi.encodeWithSelector(nSel, alice));
        assertFalse(ok, "vault exposes nonces() - unexpected signed-message surface");
    }

    // =====================================================================
    // shared invariant
    // =====================================================================

    /// @dev Solvency: the assets the entire outstanding real supply can claim never
    ///      exceed the assets the vault actually reports. (Virtual shares make
    ///      convertToAssets(totalSupply) <= totalAssets by construction; assert it.)
    function _assertSolvent() internal view {
        uint256 supply = vault.totalSupply();
        uint256 claim = vault.convertToAssets(supply);
        assertLe(claim, vault.totalAssets(), "INSOLVENT: claims exceed assets");
    }
}
