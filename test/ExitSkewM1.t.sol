// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {FaultInjectingAdapter} from "./mocks/FaultInjectingAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract M1USDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
    function decimals() public pure override returns (uint8) { return 6; }
}

/// @title M-1 — first-mover skew as a FUNCTION of mark overstate rate (SHIN pre-freeze battery)
/// @notice PURE MEASUREMENT against the REAL ADR-007 exit path (mark-price burn kept, per SHIN).
///         Sweeps the adapter's deliverBps (realizable = deliverBps% of MARK; the un-delivered
///         slice stays counted in the mark = persistent overstatement). For each overstate rate
///         (= 1 / deliverBps) it runs the canonical 5-equal-holder ordered run and reports the
///         first/last received ratio. Answers: is the residual first-mover advantage BOUNDED,
///         or does it grow (linearly / unboundedly) as the oracle lies harder?
///
///         Model per run: idle = 30% of TVL, adapter mark = 70%, 5 equal users each redeem all.
contract ExitSkewM1Test is Test {
    uint256 constant U = 1e6;
    uint256 constant D = 10_000 * U;   // each user's deposit
    uint256 constant N = 5;

    address governance   = address(0xBEEF);
    address feeRcpt      = address(0xFEE);
    address guardianAddr = address(0x6042D);

    M1USDC          usdc;
    AdapterRegistry registry;
    SIXXVault       vault;
    FaultInjectingAdapter adapter;
    address[N] users;

    /// @dev Full fresh deploy + 30/70 idle split. Called once per sweep point so each run starts
    ///      from the identical clean state (exits consume state, so we cannot reuse).
    function _deployFresh() internal {
        usdc = new M1USDC();
        vm.prank(governance);
        registry = new AdapterRegistry(governance);
        vm.prank(governance);
        vault = new SIXXVault(
            IERC20(address(usdc)), "SIXX Stable Yield", "sxUSDC",
            governance, address(registry), feeRcpt, guardianAddr
        );
        adapter = new FaultInjectingAdapter(address(usdc), address(vault), governance);
        vm.startPrank(governance);
        registry.registerAdapter(address(adapter), "DeFi", "Fault");
        vault.setAdapter(address(adapter));
        vm.stopPrank();
    }

    struct Skew {
        uint256 first;
        uint256 last;
        uint256 ratioX1e4;   // first / last, scaled 1e4
        uint256 total;       // sum of cash delivered
        uint256 stuckCount;
    }

    function _seedUsers(uint256 idlePct) internal {
        for (uint256 i = 0; i < N; i++) {
            users[i] = address(uint160(0xE100 + i));
            usdc.mint(users[i], D);
            vm.startPrank(users[i]);
            usdc.approve(address(vault), D);
            vault.deposit(D, users[i]);
            vm.stopPrank();
        }
        // seed idle = idlePct% of TVL (faithful: totalAssets unchanged, liquidity split)
        uint256 tvl = vault.totalAssets();
        if (idlePct > 0) {
            vm.prank(address(vault));
            adapter.withdraw((tvl * idlePct) / 100, address(vault));
        }
    }

    function _runOnce(uint256 bps) internal returns (Skew memory s) {
        return _runOnce(bps, 30);
    }

    function _runOnce(uint256 bps, uint256 idlePct) internal returns (Skew memory s) {
        _deployFresh();
        _seedUsers(idlePct);
        adapter.setDeliverBps(bps);

        uint256[N] memory got;
        for (uint256 i = 0; i < N; i++) {
            uint256 sh = vault.balanceOf(users[i]);
            uint256 before = usdc.balanceOf(users[i]);
            vm.prank(users[i]);
            try vault.redeem(sh, users[i], users[i]) {
                got[i] = usdc.balanceOf(users[i]) - before;
                if (got[i] == 0) s.stuckCount++;
            } catch {
                got[i] = 0;
                s.stuckCount++;
            }
            s.total += got[i];
        }
        s.first = got[0];
        s.last = got[N - 1];
        s.ratioX1e4 = got[N - 1] == 0 ? type(uint256).max : (got[0] * 1e4) / got[N - 1];

        emit log_named_uint("deliverBps", bps);
        for (uint256 i = 0; i < N; i++) emit log_named_uint("  user cash", got[i]);
        emit log_named_uint("  first/last x1e4", s.ratioX1e4);
        emit log_named_uint("  total delivered", s.total);
        emit log_named_uint("  stuck", s.stuckCount);
    }

    /// A) skew as a function of overstate rate at the canonical idle=30%. deliverBps=0 is the
    ///    limit case (adapter fully dead) = the exact asymptote of the skew.
    function test_M1_skewVsOverstate_sweep() public {
        emit log_string("=== A) skew vs overstate rate (idle=30%, N=5) ===");
        uint256[7] memory bpsGrid = [uint256(9_000), 7_000, 5_000, 3_000, 1_000, 100, 0];
        for (uint256 k = 0; k < bpsGrid.length; k++) {
            Skew memory s = _runOnce(bpsGrid[k]);
            // 柱1 always holds: no exit reverts / strands, whatever the overstatement.
            assertEq(s.stuckCount, 0, "M1: honest partial-fill must never strand any exiter");
            // M-1 BOUND: the first-mover skew is bounded by e (~2.718x) for ANY overstate rate,
            //   because mark-price under-burn keeps supply high so late exiters keep a real
            //   pro-rata slice. Overstatement does NOT make it grow without bound.
            assertLt(s.ratioX1e4, 27_183, "M1: skew must stay bounded by e regardless of overstate");
        }
    }

    /// B) at the WORST overstatement (adapter fully dead, bps=0), how does the skew bound depend
    ///    on the idle buffer size? The idle fraction is the true determinant of the bound, NOT the
    ///    overstate rate — this isolates that.
    function test_M1_skewBound_vsIdleFraction_worstOverstate() public {
        emit log_string("=== B) skew bound vs idle fraction (bps=0 worst overstate, N=5) ===");
        uint256[5] memory idleGrid = [uint256(50), 30, 10, 5, 1];
        for (uint256 k = 0; k < idleGrid.length; k++) {
            Skew memory s = _runOnce(0, idleGrid[k]);
            emit log_named_uint("  ^ idlePct", idleGrid[k]);
            assertEq(s.stuckCount, 0, "M1: idle buffer always lets everyone take some cash");
            // Even as idle -> 0 the skew converges to (1-1/N)^-(N-1); for N=5 that is 2.4414x,
            //   still < e. The idle buffer only REDUCES skew below this cap; it never unbounds it.
            assertLt(s.ratioX1e4, 27_183, "M1: idle->0 skew still bounded by e");
        }
    }

    /// C) lock the closed-form: at the worst overstate (bps=0) and a near-zero idle buffer, the
    ///    measured first/last skew must match (1-1/N)^-(N-1) within tolerance, and that formula's
    ///    supremum over all N is e. This is the analytic anchor for the M-1 "bounded by e" claim.
    function test_M1_closedFormBound_matches() public {
        Skew memory s = _runOnce(0, 1); // adapter dead, idle ~1% -> near the idle->0 limit
        // (1-1/5)^-4 = (0.8)^-4 = 2.44140625 -> 24414 in x1e4 units. Allow 3% for the finite idle.
        assertApproxEqRel(s.ratioX1e4, 24_414, 0.03e18, "M1: matches (1-1/N)^-(N-1) closed form");
        assertLt(s.ratioX1e4, 27_183, "M1: below e for all N");
    }
}
