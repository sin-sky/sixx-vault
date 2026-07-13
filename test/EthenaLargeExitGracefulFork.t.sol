// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {EthenaSUSDeAdapter} from "../src/adapters/EthenaSUSDeAdapter.sol";
import {IStakedUSDeV2} from "../src/interfaces/IStakedUSDeV2.sol";

/// @title EthenaLargeExitGracefulForkTest
/// @notice PRE-FREEZE mandatory (ADR-007 柱1): prove that a large Ethena exit whose Curve exit
///         route exceeds pool depth (M-2: ~$500k → +44% realizable<mark, adapter min_dy reverts)
///         is an HONEST PARTIAL FILL at the VAULT level — it must NEVER brick (propagate the
///         adapter revert), must preserve the caller's unpaid claim as residual shares, and the
///         position must remain drainable via smaller exits.
///         Real ETH mainnet fork @ 25500331 (healthy peg — where $500k already shows +44% gap).
contract EthenaLargeExitGracefulForkTest is Test {
    address constant USDC      = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant SUSDE     = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address constant CRVUSD    = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant ENTRYPOOL = 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72;
    address constant EXITPOOL1 = 0x57064F49Ad7123C92560882a45518374ad982e85;
    address constant EXITPOOL2 = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;
    uint256 constant FORK_BLOCK = 25_500_331;
    uint256 constant U = 1e6;

    address governance = makeAddr("governance");
    address alice      = makeAddr("alice");
    address feeRcpt    = makeAddr("feeRecipient");
    address guardian   = makeAddr("guardian");

    AdapterRegistry registry;
    SIXXVault vault;
    EthenaSUSDeAdapter adapter;
    bool forked;

    function setUp() public {
        string memory url = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(url).length == 0) { forked = false; return; }
        vm.createSelectFork(url, FORK_BLOCK);
        forked = true;

        vm.prank(governance);
        registry = new AdapterRegistry(governance);
        vm.prank(governance);
        vault = new SIXXVault(
            IERC20(USDC), "SIXX High Yield", "sxhUSDC",
            governance, address(registry), feeRcpt, guardian
        );
        adapter = new EthenaSUSDeAdapter(
            USDC, SUSDE, CRVUSD, ENTRYPOOL, EXITPOOL1, EXITPOOL2,
            address(vault), governance, 800
        );
        vm.startPrank(governance);
        registry.registerAdapter(address(adapter), "DeFi", "Ethena");
        vault.setAdapter(address(adapter));
        vm.stopPrank();
    }

    modifier onlyFork() { if (!forked) return; _; }

    /// Deposit a modest amount the entry pool can handle, then inflate the position to a
    /// depth-exceeding size by dealing sUSDe directly to the adapter (mirrors the adapter's own
    /// oversized-exit fork test). Alice ends up the sole holder of a ~`targetUsdc` position.
    function _buildOversizedPosition(uint256 seedUsdc, uint256 targetUsdc) internal {
        deal(USDC, alice, seedUsdc);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), seedUsdc);
        vault.deposit(seedUsdc, alice);
        vm.stopPrank();
        // top up sUSDe so adapter.totalAssets() ~= targetUsdc (haircut'd)
        uint256 wantUsde = targetUsdc * 1e12; // USDC 6dec -> USDe 18dec par
        uint256 haveShares = IERC20(SUSDE).balanceOf(address(adapter));
        uint256 targetShares = IStakedUSDeV2(SUSDE).convertToShares(wantUsde);
        if (targetShares > haveShares) {
            deal(SUSDE, address(adapter), targetShares);
        }
    }

    // ── A) Oversized full exit must be GRACEFUL, never brick ─────────────────
    function test_A_oversizedFullExit_isGraceful_noBrick() public onlyFork {
        _buildOversizedPosition(50_000 * U, 500_000 * U);

        uint256 nav = adapter.totalAssets();
        emit log_named_uint("adapter NAV (haircut, 6dec)", nav);
        assertGt(nav, 400_000 * U, "position is depth-exceeding");

        uint256 sharesBefore = vault.balanceOf(alice);
        uint256 maxW = vault.maxWithdraw(alice);
        emit log_named_uint("alice maxWithdraw (mark-based)", maxW);

        // THE CHECK: a full-size exit whose single-shot recall blows the Curve min_dy must NOT
        // revert. The vault's 柱1 try/catch swallows the adapter revert → honest partial fill.
        vm.prank(alice);
        uint256 got = vault.withdraw(maxW, alice, alice);
        emit log_named_uint("oversized full-exit payout", got);

        uint256 sharesAfter = vault.balanceOf(alice);
        emit log_named_uint("alice claim shares retained", sharesAfter);

        // Graceful invariants:
        //  1. no brick (we got here);
        //  2. only shares matching cash actually paid are burned — the unpaid remainder is a
        //     durable pro-rata claim (柱4);
        //  3. the vault booked no phantom idle beyond what it paid.
        assertLe(got, maxW, "never over-delivers");
        assertGt(sharesAfter, 0, "unpaid remainder retained as claim shares (no brick, no total burn)");
        // shares burned ~ convertToShares(got); with got==0 no shares burn.
        if (got == 0) {
            assertEq(sharesAfter, sharesBefore, "0-fill burns 0 shares");
        } else {
            assertLt(sharesAfter, sharesBefore, "partial fill burns only the paid slice");
        }
        assertEq(IERC20(USDC).balanceOf(address(vault)), 0, "no stranded idle in vault");
    }

    // ── B) The position stays drainable via depth-fitting chunk exits ────────
    function test_B_oversizedPosition_drainsViaChunks() public onlyFork {
        _buildOversizedPosition(50_000 * U, 300_000 * U);

        uint256 navStart = adapter.totalAssets();
        emit log_named_uint("start NAV (6dec)", navStart);

        uint256 chunk = 60_000 * U; // comfortably within exit-pool depth at this block
        uint256 totalGot;
        uint256 fills;
        for (uint256 i = 0; i < 4; i++) {
            uint256 mw = vault.maxWithdraw(alice);
            if (mw == 0) break;
            uint256 req = chunk < mw ? chunk : mw;
            vm.prank(alice);
            uint256 got = vault.withdraw(req, alice, alice);
            emit log_named_uint("chunk req", req);
            emit log_named_uint("chunk got", got);
            if (got > 0) { totalGot += got; fills++; }
        }
        emit log_named_uint("total drained via chunks", totalGot);
        emit log_named_uint("successful chunk fills", fills);
        assertGe(fills, 2, "position must be drainable in depth-fitting chunks");
        assertGt(totalGot, 100_000 * U, "chunked exits realize meaningful cash");
    }
}
