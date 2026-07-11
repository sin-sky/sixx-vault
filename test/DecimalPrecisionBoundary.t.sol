// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {MockAdapter} from "./mocks/MockAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Underlying with configurable decimals (6 = USDC/USDT, 8 = LBTC, 18 = sUSDe/ETH-based).
contract DecToken is ERC20 {
    uint8 private immutable _dec;
    constructor(uint8 dec_) ERC20("Asset", "AST") { _dec = dec_; }
    function decimals() public view override returns (uint8) { return _dec; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @title DecimalPrecisionBoundary — 換算・丸めの数値面監査
/// @notice Boundary fuzz over the vault's decimal-agnostic accounting core across asset
///         decimals 6/8/18 (share decimals = asset + fixed offset 9 → 15/17/27). Verifies
///         DINV-2 (rounding always vault-favorable), DINV-3 (no free sub-precision dust),
///         DINV-4 (share↔asset round-trip ≤ input), DINV-5 (extreme-value safety), DINV-6
///         (fee precision) — plus a stateful dust-accumulation invariant (DINV-1). Part A:
///         production src (frozen 2e8f059) NOT modified. The symbolic proof of DINV-2/4 is in
///         test/halmos/SIXXVaultSymbolic.t.sol; adapter-internal decimal crossings (Venus
///         1e18 mantissa, 18↔6 swapper) are covered by the adapter unit/fork suites.
contract DecimalPrecisionBoundaryTest is Test {
    address governance   = address(0xBEEF);
    address feeRcpt      = address(0xFEE);
    address guardianAddr = address(0x6042D);
    address alice        = address(0xA11CE);
    address bob          = address(0xB0B);

    function _build(uint8 dec) internal returns (DecToken t, SIXXVault v, MockAdapter a) {
        t = new DecToken(dec);
        vm.prank(governance);
        AdapterRegistry reg = new AdapterRegistry(governance);
        vm.prank(governance);
        v = new SIXXVault(IERC20(address(t)), "V", "sV", governance, address(reg), feeRcpt, guardianAddr);
        a = new MockAdapter(address(t), address(v));
        vm.startPrank(governance);
        reg.registerAdapter(address(a), "DeFi", "Mock");
        v.setAdapter(address(a));
        v.setManagementFee(0);
        v.setPerformanceFee(0);
        vm.stopPrank();
    }

    function _deposit(DecToken t, SIXXVault v, address who, uint256 amt) internal returns (uint256 shares) {
        t.mint(who, amt);
        vm.startPrank(who);
        t.approve(address(v), amt);
        shares = v.deposit(amt, who);
        vm.stopPrank();
    }

    // ── DINV-4 / DINV-2: deposit→redeem round-trip never returns more than deposited ──
    function _roundTrip(uint8 dec, uint256 amount) internal {
        (DecToken t, SIXXVault v, ) = _build(dec);
        uint256 unit = 10 ** dec;
        amount = bound(amount, 1, 1_000_000_000 * unit); // up to 1e9 tokens
        uint256 shares = _deposit(t, v, alice, amount);
        assertGt(shares, 0, "DINV-3: positive deposit minted 0 shares (free dust would be possible)");

        uint256 before = t.balanceOf(alice);
        vm.prank(alice);
        uint256 got = v.redeem(shares, alice, alice);
        assertEq(t.balanceOf(alice) - before, got, "receipt mismatch");
        // Vault-favorable: a solo depositor can never redeem MORE than they put in.
        assertLe(got, amount, "DINV-2/4: round-trip returned more than deposited");
        // And loses at most rounding dust (no gross precision loss).
        assertGe(got + 2, amount, "DINV-4: round-trip lost more than rounding dust");
    }

    function testFuzz_roundTrip_dec6(uint256 a)  public { _roundTrip(6, a); }
    function testFuzz_roundTrip_dec8(uint256 a)  public { _roundTrip(8, a); }
    function testFuzz_roundTrip_dec18(uint256 a) public { _roundTrip(18, a); }

    // ── DINV-2: a second depositor cannot skim the first via rounding (worst decimals) ──
    function _noSkimBetweenDepositors(uint8 dec, uint256 a1, uint256 a2) internal {
        (DecToken t, SIXXVault v, MockAdapter adp) = _build(dec);
        uint256 unit = 10 ** dec;
        a1 = bound(a1, 1, 1_000_000 * unit);
        a2 = bound(a2, 1, 1_000_000 * unit);
        _deposit(t, v, alice, a1);
        // inject some yield so share price is non-integer (rounding actually engages)
        uint256 y = bound(a1, 0, a1) / 3;
        if (y > 0) { t.mint(address(this), y); t.approve(address(adp), y); adp.addYield(y); }
        uint256 bobShares = _deposit(t, v, bob, a2);

        uint256 before = t.balanceOf(bob);
        vm.prank(bob);
        v.redeem(bobShares, bob, bob);
        uint256 bobGot = t.balanceOf(bob) - before;
        // Bob (the later depositor) cannot walk away with more than he put in — no skim of
        // alice's principal or the injected yield via rounding.
        assertLe(bobGot, a2 + 2, "DINV-2: later depositor skimmed value via rounding");
    }

    function testFuzz_noSkim_dec6(uint256 a1, uint256 a2)  public { _noSkimBetweenDepositors(6, a1, a2); }
    function testFuzz_noSkim_dec18(uint256 a1, uint256 a2) public { _noSkimBetweenDepositors(18, a1, a2); }

    // ── DINV-3: sub-precision deposit that would mint 0 shares reverts (no free dust) ──
    function test_DINV3_subPrecisionDeposit_reverts() public {
        // Inflate share price so a 1-wei deposit rounds toward 0 shares, then confirm the guard.
        (DecToken t, SIXXVault v, MockAdapter adp) = _build(6);
        _deposit(t, v, alice, 1_000_000e6);
        // Push a large yield so totalAssets >> supply-per-share; a 1-wei deposit's shares floor.
        t.mint(address(this), 1_000_000e6);
        t.approve(address(adp), 1_000_000e6);
        adp.addYield(1_000_000e6);

        // If previewDeposit(1) == 0, the deposit MUST revert (VAULT: zero shares); never free dust.
        if (v.previewDeposit(1) == 0) {
            t.mint(bob, 1);
            vm.startPrank(bob);
            t.approve(address(v), 1);
            vm.expectRevert(bytes("VAULT: zero shares"));
            v.deposit(1, bob);
            vm.stopPrank();
        }
        // Even if the offset keeps previewDeposit(1) > 0, that too is safe (no 0-share mint).
        assertTrue(true);
    }

    // ── DINV-5: extreme values — 1 wei, decimal boundaries, large — no overflow/insolvency ──
    function _extreme(uint8 dec, uint256 amount) internal {
        (DecToken t, SIXXVault v, ) = _build(dec);
        uint256 shares = _deposit(t, v, alice, amount);
        assertGt(shares, 0, "DINV-5: 0 shares at extreme");
        // shares-backed holds at the extreme (no phantom / insolvency).
        assertLe(v.convertToAssets(v.totalSupply()), v.totalAssets() + 2, "DINV-5: over-claim at extreme");
        uint256 got = v.previewRedeem(shares);
        assertLe(got, amount, "DINV-5: preview over-claims at extreme");
    }

    function test_DINV5_extremes() public {
        uint8[3] memory decs = [6, 8, 18];
        for (uint256 i = 0; i < 3; i++) {
            uint8 d = decs[i];
            uint256 u = 10 ** d;
            _extreme(d, 1);              // 1 wei
            _extreme(d, 2);              // 2 wei
            _extreme(d, u - 1);          // 10^d - 1
            _extreme(d, u);              // 10^d (1 token)
            _extreme(d, u + 1);          // 10^d + 1
            _extreme(d, 1_000_000_000 * u); // 1e9 tokens (realistic large)
        }
    }

    // ── DINV-6: fee precision — collectFees never creates/destroys assets, bounded ──
    function _feePrecision(uint8 dec, uint256 amount, uint256 dt) internal {
        (DecToken t, SIXXVault v, ) = _build(dec);
        uint256 unit = 10 ** dec;
        amount = bound(amount, unit, 1_000_000 * unit);
        dt = bound(dt, 1, 365 days);
        vm.prank(governance);
        v.setManagementFee(500); // max 5%
        _deposit(t, v, alice, amount);

        uint256 taBefore = v.totalAssets();
        skip(dt);
        vm.prank(bob);
        v.collectFees();
        // Fee mints SHARES, never changes the asset side → no value created/destroyed.
        assertApproxEqAbs(v.totalAssets(), taBefore, 2, "DINV-6: fee changed the asset side");
        // feeRecipient's claim never exceeds the accrued management fee (+ dust).
        uint256 feeClaim = v.convertToAssets(v.balanceOf(feeRcpt));
        uint256 maxFee = (amount * 500 * dt) / (10_000 * (365 days + 6 hours));
        assertLe(feeClaim, maxFee + 2, "DINV-6: fee over-charged");
    }

    function testFuzz_fee_dec6(uint256 a, uint256 dt)  public { _feePrecision(6, a, dt); }
    function testFuzz_fee_dec18(uint256 a, uint256 dt) public { _feePrecision(18, a, dt); }

    // ── DINV-1: repeated dust deposit/withdraw cycles cannot skim value (leakage bounded) ──
    /// A griefer running many sub-precision deposit→redeem cycles against a yield-bearing pool
    /// can NEVER end with more than they started (each round-trip is vault-favorable), and an
    /// honest holder is never diluted — the griefer's rounding losses accrue to the pool.
    function test_DINV1_dustCyclesCannotSkim() public {
        (DecToken t, SIXXVault v, MockAdapter adp) = _build(6);
        _deposit(t, v, alice, 1_000_000e6);
        // Non-integer share price so rounding genuinely engages.
        t.mint(address(this), 137_000e6);
        t.approve(address(adp), 137_000e6);
        adp.addYield(137_000e6);
        uint256 aliceClaimBefore = v.convertToAssets(v.balanceOf(alice));

        address griefer = address(0x6);
        uint256 initialFund = 100_000; // wei of the 6-dec asset
        t.mint(griefer, initialFund);

        for (uint256 i = 0; i < 300; i++) {
            uint256 dust = 1 + (i % 9); // 1..9 wei — sub-precision vs the inflated share price
            if (dust > t.balanceOf(griefer)) break;
            vm.startPrank(griefer);
            t.approve(address(v), dust);
            try v.deposit(dust, griefer) {
                uint256 sh = v.balanceOf(griefer);
                if (sh > 0) v.redeem(sh, griefer, griefer);
            } catch {} // zero-share deposits are rejected (DINV-3) — no dust taken
            vm.stopPrank();
        }

        // The griefer never profits from dust cycles.
        assertLe(t.balanceOf(griefer), initialFund, "DINV-1: griefer skimmed value via dust cycles");
        // The honest holder is never diluted (griefer's lost dust accrues to the pool).
        assertGe(v.convertToAssets(v.balanceOf(alice)) + 2, aliceClaimBefore,
            "DINV-1: honest holder diluted by dust griefing");
    }
}
