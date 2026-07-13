// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {PhantomMarkAdapter} from "./mocks/PhantomMarkAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract PCUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
    function decimals() public pure override returns (uint8) { return 6; }
}

/// @title I-2 — measure design (c) as PRODUCTION-IMPLEMENTED under an OVERSTATED mark
/// @notice SHIN's premise (GO decision): "価値の公平(全員 6,500 均等)は (c) で達成済み".
///         This suite re-measures that claim on the REAL SIXXVault._exitRealize path (not the
///         pure D-2 model) in the exact regime E1 flagged as dangerous: adapter MARK (35_000)
///         overstates realizable tokens (17_500). The D-2 (c) model achieved 6_500×5 because it
///         clamped entitlement to `idle + realizable`. The production code clamps the ADAPTER
///         RECALL to `mark × shares/supply` (pro-rata of the OVERSTATED mark) and pays
///         `min(request, idle_pro_rata + actually_recalled)`. The question: does that reproduce
///         the D-2 model's fairness, or does it let early callers drain the shared realizable
///         buffer (first-come value advantage)?
contract ExitFairnessProdCTest is Test {
    PCUSDC          usdc;
    AdapterRegistry registry;
    SIXXVault       vault;
    PhantomMarkAdapter adapter;

    address governance   = address(0xBEEF);
    address feeRcpt      = address(0xFEE);
    address guardianAddr = address(0x6042D);
    address sink         = address(0xDEAD);

    uint256 constant U = 1e6;
    uint256 constant D = 10_000 * U; // each user's deposit
    uint256 constant N = 5;
    address[N] users;

    function _fresh() internal {
        usdc = new PCUSDC();
        vm.prank(governance);
        registry = new AdapterRegistry(governance);
        vm.prank(governance);
        vault = new SIXXVault(
            IERC20(address(usdc)), "SIXX Stable Yield", "sxUSDC",
            governance, address(registry), feeRcpt, guardianAddr
        );
        adapter = new PhantomMarkAdapter(address(usdc), address(vault), governance);
        vm.startPrank(governance);
        registry.registerAdapter(address(adapter), "DeFi", "Phantom");
        vault.setAdapter(address(adapter));
        vm.stopPrank();
        for (uint256 i = 0; i < N; i++) {
            users[i] = address(uint160(0xC100 + i));
            usdc.mint(users[i], D);
            vm.startPrank(users[i]);
            usdc.approve(address(vault), D);
            vault.deposit(D, users[i]);
            vm.stopPrank();
        }
        // Split liquidity 30% idle / 70% deployed (faithful: totalAssets unchanged).
        uint256 tvl = vault.totalAssets();
        vm.prank(address(vault));
        adapter.withdraw((tvl * 30) / 100, address(vault));
    }

    /// Overstate the mark: move `phantomAmt` of adapter tokens out (unrealizable) but keep mark.
    function _injectPhantom(uint256 phantomAmt) internal {
        adapter.makePhantom(phantomAmt, sink);
    }

    struct Outcome {
        uint256[N] received;
        uint256    total;
        uint256    minR;
        uint256    maxR;
    }

    function _runAllRedeem(string memory label) internal returns (Outcome memory o) {
        emit log_string(label);
        o.minR = type(uint256).max;
        for (uint256 i = 0; i < N; i++) {
            uint256 sh = vault.balanceOf(users[i]);
            uint256 before = usdc.balanceOf(users[i]);
            vm.prank(users[i]);
            try vault.redeem(sh, users[i], users[i]) {} catch { emit log("  REVERTED"); }
            uint256 got = usdc.balanceOf(users[i]) - before;
            o.received[i] = got;
            o.total += got;
            if (got < o.minR) o.minR = got;
            if (got > o.maxR) o.maxR = got;
            emit log_named_uint("  user cash", got);
            emit log_named_uint("  residual shares kept", vault.balanceOf(users[i]));
        }
        emit log_named_uint("  TOTAL cash paid", o.total);
        emit log_named_uint("  min received", o.minR);
        emit log_named_uint("  max received", o.maxR);
        emit log_named_uint("  max/min ratio x1e4", o.minR == 0 ? type(uint256).max : (o.maxR * 1e4) / o.minR);
    }

    // ── The headline measurement: mark=35_000 but realizable=17_500 (idle 15_000). ──
    // D-2 model (c) promised 6_500×5. What does the PRODUCTION path deliver?
    function test_prodC_phantomMark_5userRun() public {
        _fresh();
        // After the 30% pull: idle=15_000, adapter real=mark=35_000. Make half the mark phantom.
        _injectPhantom(17_500 * U); // adapter real=17_500, mark still 35_000
        assertEq(adapter.realBalance(), 17_500 * U, "setup: realizable 17_500");
        assertEq(adapter.totalAssets(), 35_000 * U, "setup: mark overstates to 35_000");
        assertEq(usdc.balanceOf(address(vault)), 15_000 * U, "setup: idle 15_000");

        Outcome memory o = _runAllRedeem("=== PROD (c): mark 35k / realizable 17.5k / idle 15k ===");

        // Real distributable value = idle 15_000 + realizable 17_500 = 32_500 -> fair share 6_500.
        // Document what actually happened. If the design goal held, all five ~= 6_500.
        emit log_named_uint("  FAIR pro-rata of realizable (expected by design c)", 6_500 * U);
        // Total cash can never exceed real distributable value (solvency floor).
        assertLe(o.total, 32_500 * U + 3, "cash paid exceeds real distributable value (solvency breach!)");
    }

    // ── Control: HONEST mark (mark == realizable). Design (c) fairness SHOULD hold here. ──
    function test_prodC_honestMark_fullLiquidity_control() public {
        _fresh();
        // No phantom: idle 15_000, adapter real=mark=35_000, everyone can be paid in full.
        Outcome memory o = _runAllRedeem("=== CONTROL: honest mark, full liquidity ===");
        for (uint256 i = 0; i < N; i++) {
            assertApproxEqAbs(o.received[i], 10_000 * U, 2, "honest+liquid: everyone full & equal");
        }
    }

    // ── Whale boundedness (G-1): one big holder splitting into many partial redeems must NOT
    //    extract more total than a single redeem would (no rounding-leak accumulation). ──
    function test_prodC_whale_repeatedPartial_notMoreThanSingle() public {
        // Path A: whale redeems everything in ONE call.
        _fresh();
        _injectPhantom(17_500 * U);
        address whale = users[0];
        uint256 shA = vault.balanceOf(whale);
        uint256 beforeA = usdc.balanceOf(whale);
        vm.prank(whale);
        vault.redeem(shA, whale, whale);
        uint256 singleCash = usdc.balanceOf(whale) - beforeA;
        emit log_named_uint("whale single-redeem cash", singleCash);

        // Path B: fresh identical state; whale redeems in 20 equal partial chunks.
        _fresh();
        _injectPhantom(17_500 * U);
        whale = users[0];
        uint256 shB = vault.balanceOf(whale);
        uint256 beforeB = usdc.balanceOf(whale);
        uint256 chunk = shB / 20;
        for (uint256 k = 0; k < 20; k++) {
            uint256 r = vault.balanceOf(whale);
            uint256 use = k == 19 ? r : chunk;
            if (use == 0) break;
            vm.prank(whale);
            try vault.redeem(use, whale, whale) {} catch {}
        }
        uint256 splitCash = usdc.balanceOf(whale) - beforeB;
        emit log_named_uint("whale 20-chunk cash", splitCash);

        // Boundedness: splitting must not pay the whale MORE than a single exit (allow dust).
        assertLe(splitCash, singleCash + 3, "G-1: repeated partial exits over-extract vs single");
    }
}
