// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {MockAdapter} from "./mocks/MockAdapter.sol";
import {HarvestAdapter} from "./mocks/HarvestAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TaxUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

/// @title TimeAxisExtremes — 時間軸極値監査（fee accrual / locked-profit / timestamp 境界）
/// @notice vm.warp extreme-boundary sweep of the vault's time-dependent mechanisms:
///         management-fee accrual (`elapsed`-prorated, bounded by the feeAssets<assets guard),
///         locked-profit linear unlock (8h window), and block.timestamp arithmetic. Verifies
///         TINV-1 (fee bounded — never eats principal), TINV-2 (zero-elapsed = zero fee,
///         proportional, no double-charge), TINV-3 (unlock window boundaries + rollover +
///         M-02 zero-profit no-extension), TINV-4 (timestamp robustness: zero / near-max / no
///         overflow/underflow), TINV-5 (no time-based skim across the unlock tail), TINV-7
///         (solvency over time). Part A: production src (frozen 2e8f059) NOT modified.
///
/// @dev The STATEFUL time×fee×harvest surface (warp × deposit/withdraw/harvest/fee-toggle in
///      random order) is already fuzzed by SIXXVaultInvariant. This suite pins the EXTREME
///      boundaries that need explicit warps. No on-chain DCA scheduler exists (off-chain per
///      SCOPE §3 → TINV-6 N/A); Ethena's 7-day cooldown is intentionally bypassed (instant DEX
///      exit → N/A). Constants: SECS_PER_YEAR = 365d+6h, PROFIT_UNLOCK_PERIOD = 8h, MAX fee 5%.
contract TimeAxisExtremesTest is Test {
    address governance   = address(0xBEEF);
    address feeRcpt      = address(0xFEE);
    address guardianAddr = address(0x6042D);
    address alice        = address(0xA11CE);
    address bob          = address(0xB0B);

    uint256 constant USDC = 1e6;
    uint256 constant YEAR = 365 days + 6 hours; // SECS_PER_YEAR
    uint256 constant UNLOCK = 8 hours;          // PROFIT_UNLOCK_PERIOD

    function _buildMock() internal returns (TaxUSDC t, SIXXVault v, MockAdapter a) {
        t = new TaxUSDC();
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

    function _buildHarvest() internal returns (TaxUSDC t, SIXXVault v, HarvestAdapter a) {
        t = new TaxUSDC();
        vm.prank(governance);
        AdapterRegistry reg = new AdapterRegistry(governance);
        vm.prank(governance);
        v = new SIXXVault(IERC20(address(t)), "V", "sV", governance, address(reg), feeRcpt, guardianAddr);
        a = new HarvestAdapter(address(t), address(v));
        vm.startPrank(governance);
        reg.registerAdapter(address(a), "DeFi", "Harvest");
        v.setAdapter(address(a));
        vm.stopPrank();
    }

    function _deposit(TaxUSDC t, SIXXVault v, address who, uint256 amt) internal returns (uint256 sh) {
        t.mint(who, amt);
        vm.startPrank(who);
        t.approve(address(v), amt);
        sh = v.deposit(amt, who);
        vm.stopPrank();
    }

    // ── TINV-1 / TINV-7: fee bounded for ANY elapsed (never eats principal, solvency holds) ──
    function testFuzz_TINV1_feeBounded_anyElapsed(uint256 dt, uint256 amount) public {
        (TaxUSDC t, SIXXVault v, ) = _buildMock();
        amount = bound(amount, 1e6, 1_000_000_000 * USDC);
        dt = bound(dt, 0, 10_000 * YEAR); // 0 .. 10,000 years
        vm.prank(governance);
        v.setManagementFee(500); // 5% max
        _deposit(t, v, alice, amount);

        skip(dt);
        // MUST NOT revert / overflow at any elapsed.
        v.collectFees();
        // Fee is bounded: the vault never becomes insolvent and shares never over-claim.
        assertLe(v.convertToAssets(v.totalSupply()), v.totalAssets() + 2, "TINV-1/7: insolvent after fee");
        // feeRecipient's claim never exceeds the pool (principal is never eaten to zero).
        assertLt(v.convertToAssets(v.balanceOf(feeRcpt)), v.totalAssets() + 1, "TINV-1: fee exceeded assets");
        // alice can still exit with something.
        uint256 aliceSh = v.balanceOf(alice);
        uint256 before = t.balanceOf(alice);
        vm.prank(alice);
        v.redeem(aliceSh, alice, alice);
        assertGt(t.balanceOf(alice) - before, 0, "TINV-1: principal fully eaten by fee");
    }

    // ── TINV-2: zero elapsed = zero fee; proportional; no double-charge across two collects ──
    function test_TINV2_zeroElapsed_and_noDoubleCharge() public {
        (TaxUSDC t, SIXXVault v, ) = _buildMock();
        vm.prank(governance);
        v.setManagementFee(500);
        _deposit(t, v, alice, 1_000_000 * USDC);

        // Zero elapsed → zero fee (same block).
        uint256 supplyBefore = v.totalSupply();
        v.collectFees();
        assertEq(v.totalSupply(), supplyBefore, "TINV-2: fee charged at zero elapsed");

        // Charge over a window, then immediately collect again → second collect is ~0 (no double).
        skip(180 days);
        v.collectFees();
        uint256 feeSh1 = v.balanceOf(feeRcpt);
        v.collectFees(); // immediately again, elapsed ~0
        assertEq(v.balanceOf(feeRcpt), feeSh1, "TINV-2: double-charge on back-to-back collect");
        assertGt(feeSh1, 0, "fee window did not accrue");
    }

    // ── TINV-3: locked-profit unlock window boundaries + rollover + M-02 zero-profit no-extend ──
    function test_TINV3_unlockWindow_boundaries() public {
        (TaxUSDC t, SIXXVault v, HarvestAdapter a) = _buildHarvest();
        _deposit(t, v, alice, 10_000 * USDC);
        // fund + realize a discrete profit → locked.
        t.mint(address(this), 2_000 * USDC);
        t.approve(address(a), 2_000 * USDC);
        a.addReward(2_000 * USDC);
        v.harvest();
        assertApproxEqAbs(v.lockedProfit(), 2_000 * USDC, 2, "T=0: not fully locked");

        skip(UNLOCK - 1);
        assertGt(v.lockedProfit(), 0, "t=window-1: prematurely fully unlocked");
        skip(1); // t == UNLOCK exactly
        assertEq(v.lockedProfit(), 0, "t=window: not fully unlocked");
        skip(1 days); // t > window
        assertEq(v.lockedProfit(), 0, "t>window: locked profit reappeared");
    }

    function test_TINV3_zeroProfitHarvest_noWindowExtension() public {
        (TaxUSDC t, SIXXVault v, HarvestAdapter a) = _buildHarvest();
        _deposit(t, v, alice, 10_000 * USDC);
        t.mint(address(this), 1_000 * USDC);
        t.approve(address(a), 1_000 * USDC);
        a.addReward(1_000 * USDC);
        v.harvest();
        skip(UNLOCK / 2);
        uint256 lpMid = v.lockedProfit();
        v.harvest(); // zero new profit — must NOT restart the window (M-02)
        assertEq(v.lockedProfit(), lpMid, "M-02: zero-profit harvest changed locked amount");
        skip(UNLOCK / 2);
        assertEq(v.lockedProfit(), 0, "M-02: zero-profit harvest extended the unlock tail");
    }

    // ── TINV-4: timestamp robustness — zero elapsed / near-max warp, no overflow/underflow ──
    function test_TINV4_nearMaxTimestamp_noOverflow() public {
        (TaxUSDC t, SIXXVault v, ) = _buildMock();
        vm.prank(governance);
        v.setManagementFee(500);
        _deposit(t, v, alice, 1_000_000 * USDC);
        // Warp to a far-future but physically-representable timestamp (year ~5000).
        vm.warp(block.timestamp + 3000 * YEAR);
        v.collectFees();       // must not overflow/revert
        v.totalAssets();       // lockedProfit() arithmetic must not underflow
        assertLe(v.convertToAssets(v.totalSupply()), v.totalAssets() + 2, "TINV-4: insolvent at far-future");
        // exit still works.
        uint256 aliceSh = v.balanceOf(alice);
        uint256 before = t.balanceOf(alice);
        vm.prank(alice);
        v.redeem(aliceSh, alice, alice);
        assertGt(t.balanceOf(alice) - before, 0, "TINV-4: exit blocked at far-future");
    }

    // ── TINV-5: no time-based skim — a JIT depositor across the unlock tail cannot skim ──
    function testFuzz_TINV5_noSkimAcrossUnlockTail(uint256 warpInto) public {
        (TaxUSDC t, SIXXVault v, HarvestAdapter a) = _buildHarvest();
        _deposit(t, v, alice, 10_000 * USDC);
        t.mint(address(this), 5_000 * USDC);
        t.approve(address(a), 5_000 * USDC);
        a.addReward(5_000 * USDC);
        v.harvest(); // 5,000 locked over 8h

        warpInto = bound(warpInto, 0, UNLOCK); // enter somewhere in the unlock window
        skip(warpInto);
        uint256 bobShares = _deposit(t, v, bob, 10_000 * USDC); // JIT enters mid-unlock
        // Bob exits immediately → must not skim the still-locked profit he did not earn.
        uint256 before = t.balanceOf(bob);
        vm.prank(bob);
        v.redeem(bobShares, bob, bob);
        uint256 bobGot = t.balanceOf(bob) - before;
        assertLe(bobGot, 10_000 * USDC + 2, "TINV-5: JIT depositor skimmed locked profit via timing");
    }

    // ── TINV-2 (fuzz): fee is monotonic in elapsed (longer window ⇒ >= fee), never negative ──
    function testFuzz_TINV2_feeMonotonicInElapsed(uint256 dt1, uint256 dt2) public {
        dt1 = bound(dt1, 1 days, 2 * YEAR);
        dt2 = bound(dt2, dt1, 4 * YEAR); // dt2 >= dt1
        uint256 fee1 = _feeOver(dt1);
        uint256 fee2 = _feeOver(dt2);
        assertGe(fee2 + 1, fee1, "TINV-2: fee not monotonic in elapsed");
    }

    function _feeOver(uint256 dt) internal returns (uint256 feeShares) {
        (TaxUSDC t, SIXXVault v, ) = _buildMock();
        vm.prank(governance);
        v.setManagementFee(500);
        _deposit(t, v, alice, 1_000_000 * USDC);
        skip(dt);
        v.collectFees();
        feeShares = v.balanceOf(feeRcpt);
    }
}
