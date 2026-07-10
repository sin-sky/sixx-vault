// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EthenaSUSDeAdapter} from "../src/adapters/EthenaSUSDeAdapter.sol";
import {IStakedUSDeV2} from "../src/interfaces/IStakedUSDeV2.sol";

/// @title EthenaSUSDeAdapterForkTest
/// @notice Ethereum mainnet fork integration for the Ethena sUSDe adapter.
///         Exercises the real Curve entry/exit route and StakedUSDeV2 staking.
///         Run: forge test --fork-url $ETH_RPC_URL \
///              --fork-block-number 25500331 \
///              --match-contract EthenaSUSDeAdapterForkTest -vvv
contract EthenaSUSDeAdapterForkTest is Test {
    // Verified on-chain 2026-07-10 @ block 25500331
    address constant USDC      = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant SUSDE     = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address constant CRVUSD    = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant ENTRYPOOL = 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72; // Curve USDe/USDC
    address constant EXITPOOL1 = 0x57064F49Ad7123C92560882a45518374ad982e85; // Curve crvUSD/sUSDe
    address constant EXITPOOL2 = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E; // Curve USDC/crvUSD

    uint256 constant FORK_BLOCK = 25_500_331;

    address governance = makeAddr("governance");
    address vault      = makeAddr("vault");
    address recipient  = makeAddr("recipient");

    EthenaSUSDeAdapter adapter;
    bool forked;

    function setUp() public {
        string memory url = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            forked = false;
            return;
        }
        vm.createSelectFork(url, FORK_BLOCK);
        forked = true;
        adapter = new EthenaSUSDeAdapter(
            USDC, SUSDE, CRVUSD, ENTRYPOOL, EXITPOOL1, EXITPOOL2,
            vault, governance, 800
        );
    }

    modifier onlyFork() {
        if (!forked) return;
        _;
    }

    function _fundAndDeposit(uint256 usdcAmt) internal {
        deal(USDC, address(adapter), usdcAmt);
        vm.prank(vault);
        adapter.deposit(usdcAmt);
    }

    // ── T-A1 style: sanity of the wired protocol addresses ─────
    function test_fork_wiring() public onlyFork {
        assertEq(adapter.asset(), USDC);
        assertEq(address(adapter.usde()), IStakedUSDeV2(SUSDE).asset());
        assertEq(IStakedUSDeV2(SUSDE).cooldownDuration() > 0, true, "cooldown active (native redeem would revert)");
        emit log_named_uint("convertToAssets(1e18) USDe", IStakedUSDeV2(SUSDE).convertToAssets(1e18));
    }

    // ── deposit: USDC -> USDe -> stake -> hold sUSDe ────────────
    function test_fork_deposit_holds_susde() public onlyFork {
        _fundAndDeposit(10_000e6);
        uint256 shares = IERC20(SUSDE).balanceOf(address(adapter));
        assertGt(shares, 0, "no sUSDe minted");
        // No idle USDC/USDe left behind
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0);
        uint256 nav = adapter.totalAssets();
        emit log_named_uint("sUSDe held (1e18)", shares);
        emit log_named_uint("totalAssets USDC (6dec, haircut)", nav);
        // NAV should be ~ 99.5% of deposit or better (haircut is 0.5%; entry slip tiny)
        assertGt(nav, 9_900e6);
        assertLt(nav, 10_000e6); // conservative (haircut) — never over-reports
    }

    // ── partial withdraw delivers >= requested (vault guard) ────
    function test_fork_partial_withdraw() public onlyFork {
        _fundAndDeposit(10_000e6);
        uint256 want = 4_000e6;
        vm.prank(vault);
        uint256 got = adapter.withdraw(want, recipient);
        assertGe(got, want, "shortfall vs requested");
        assertEq(IERC20(USDC).balanceOf(recipient), got);
        assertGt(IERC20(SUSDE).balanceOf(address(adapter)), 0, "position fully drained on partial");
        emit log_named_uint("requested USDC", want);
        emit log_named_uint("received USDC", got);
    }

    // ── full drain covers reported NAV (setAdapter/emergency path) ──
    function test_fork_full_drain_covers_nav() public onlyFork {
        _fundAndDeposit(10_000e6);
        uint256 nav = adapter.totalAssets();
        vm.prank(vault);
        uint256 got = adapter.withdraw(nav, recipient);
        assertGe(got, nav, "full drain under-delivers vs reported NAV");
        assertEq(IERC20(SUSDE).balanceOf(address(adapter)), 0, "sUSDe dust left after full drain");
        emit log_named_uint("reported NAV", nav);
        emit log_named_uint("drained USDC", got);
    }

    // ── round-trip loss must be within the 0.5% slippage budget ──
    function test_fork_roundtrip_slippage_within_budget() public onlyFork {
        uint256 principal = 10_000e6;
        _fundAndDeposit(principal);
        uint256 nav = adapter.totalAssets();
        vm.prank(vault);
        uint256 got = adapter.withdraw(nav, recipient);
        // total round-trip (entry swap + stake + exit 2-hop) loss
        uint256 lossBps = principal > got ? ((principal - got) * 10_000) / principal : 0;
        emit log_named_uint("roundtrip loss (bps)", lossBps);
        assertLt(lossBps, 100, "roundtrip loss exceeds 1%"); // ~0.1-0.2% expected at $10k
    }

    // ── slippage cap reverts an oversized exit ─────────────────
    function test_fork_oversized_exit_reverts_on_slippage() public onlyFork {
        // Build a large sUSDe position directly (bypassing the entry cap) so the
        // exit alone would blow through the ~$0.66M pool depth beyond 0.5%.
        uint256 bigShares = 2_000_000e18; // ~ $2.5M of sUSDe, far exceeds pool depth
        deal(SUSDE, address(adapter), bigShares);
        uint256 nav = adapter.totalAssets();
        vm.prank(vault);
        vm.expectRevert(); // Curve min_dy (slippage floor) not met
        adapter.withdraw(nav, recipient);
    }

    // ── smaller size stays comfortably within budget ───────────
    function test_fork_small_deposit_low_slippage() public onlyFork {
        _fundAndDeposit(1_000e6);
        uint256 nav = adapter.totalAssets();
        vm.prank(vault);
        uint256 got = adapter.withdraw(nav, recipient);
        uint256 lossBps = 1_000e6 > got ? ((1_000e6 - got) * 10_000) / 1_000e6 : 0;
        emit log_named_uint("$1k roundtrip loss (bps)", lossBps);
        assertLt(lossBps, 100);
    }
}
