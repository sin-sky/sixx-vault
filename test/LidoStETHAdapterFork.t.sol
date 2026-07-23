// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LidoStETHAdapter} from "../src/adapters/LidoStETHAdapter.sol";
import {IWstETH} from "../src/interfaces/IWstETH.sol";

/// @title LidoStETHAdapterForkTest
/// @notice Ethereum mainnet fork integration for the Lido stETH adapter.
///         Exercises the real Lido stake, wstETH wrap, and Curve stETH/ETH exit.
///         Run: set -a; source ../sixx-interface/.env.local; set +a; \
///              forge test --match-contract LidoStETHAdapterForkTest \
///              --fork-url $ETH_RPC_URL -vv
contract LidoStETHAdapterForkTest is Test {
    // Verified on-chain 2026-07-23
    address constant WETH      = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant STETH     = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant WSTETH    = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant CURVEPOOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022; // ETH/stETH classic

    uint256 constant FORK_BLOCK = 25_596_677;

    address governance = makeAddr("governance");
    address vault      = makeAddr("vault");
    address recipient  = makeAddr("recipient");
    address stranger   = makeAddr("stranger");

    LidoStETHAdapter adapter;
    bool forked;

    function setUp() public {
        string memory url = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            forked = false;
            return;
        }
        vm.createSelectFork(url, FORK_BLOCK);
        forked = true;
        adapter = new LidoStETHAdapter(WETH, STETH, WSTETH, CURVEPOOL, vault, governance, 350);
        // The deterministic CREATE address can collide with a funded mainnet
        // account (fork inherits its native balance). Zero it so the "no idle
        // ETH" invariant is asserted against a clean slate — this is a test-
        // harness artifact, not adapter state.
        vm.deal(address(adapter), 0);
    }

    modifier onlyFork() {
        if (!forked) return;
        _;
    }

    function _fundAndDeposit(uint256 wethAmt) internal {
        deal(WETH, address(adapter), wethAmt);
        vm.prank(vault);
        adapter.deposit(wethAmt);
    }

    // ── wiring sanity ───────────────────────────────────────────
    function test_fork_wiring() public onlyFork {
        assertEq(adapter.asset(), WETH);
        assertEq(address(adapter.stETH()), STETH);
        assertEq(IWstETH(WSTETH).stETH(), STETH);
        assertEq(adapter.riskLevel(), 2);
        assertEq(adapter.requiredLockPeriod(), 0);
        assertEq(adapter.estimatedAPY(), 350);
    }

    // ── deposit: WETH -> ETH -> stETH -> wstETH ─────────────────
    function test_fork_deposit_holds_wsteth() public onlyFork {
        _fundAndDeposit(10 ether);
        uint256 shares = IERC20(WSTETH).balanceOf(address(adapter));
        assertGt(shares, 0, "no wstETH minted");
        // No idle WETH / stETH / ETH left behind (allow 1 wei stETH rounding dust)
        assertEq(IERC20(WETH).balanceOf(address(adapter)), 0, "idle WETH");
        assertLe(IERC20(STETH).balanceOf(address(adapter)), 2, "idle stETH > dust");
        assertEq(address(adapter).balance, 0, "idle ETH");
        uint256 nav = adapter.totalAssets();
        emit log_named_uint("wstETH held", shares);
        emit log_named_uint("totalAssets WETH (haircut)", nav);
        // NAV is haircut 0.5% of ~10 ETH principal: between 9.9 and 10 ETH.
        assertGt(nav, 9.9 ether);
        assertLt(nav, 10 ether); // conservative — never over-reports
    }

    // ── partial withdraw delivers >= requested (vault guard) ────
    function test_fork_partial_withdraw() public onlyFork {
        _fundAndDeposit(10 ether);
        uint256 want = 4 ether;
        vm.prank(vault);
        uint256 got = adapter.withdraw(want, recipient);
        assertGe(got, want, "shortfall vs requested");
        assertEq(IERC20(WETH).balanceOf(recipient), got);
        assertGt(IERC20(WSTETH).balanceOf(address(adapter)), 0, "position fully drained on partial");
        emit log_named_uint("requested WETH", want);
        emit log_named_uint("received WETH", got);
    }

    // ── full drain covers reported NAV (setAdapter/emergency path) ──
    function test_fork_full_drain_covers_nav() public onlyFork {
        _fundAndDeposit(10 ether);
        uint256 nav = adapter.totalAssets();
        vm.prank(vault);
        uint256 got = adapter.withdraw(nav, recipient);
        assertGe(got, nav, "full drain under-delivers vs reported NAV");
        assertEq(IERC20(WSTETH).balanceOf(address(adapter)), 0, "wstETH dust left after full drain");
        emit log_named_uint("reported NAV", nav);
        emit log_named_uint("drained WETH", got);
    }

    // ── round-trip loss must be within the slippage budget ──────
    function test_fork_roundtrip_within_budget() public onlyFork {
        uint256 principal = 50 ether;
        _fundAndDeposit(principal);
        uint256 nav = adapter.totalAssets();
        vm.prank(vault);
        uint256 got = adapter.withdraw(nav, recipient);
        uint256 lossBps = principal > got ? ((principal - got) * 10_000) / principal : 0;
        emit log_named_uint("roundtrip loss (bps)", lossBps);
        assertLt(lossBps, 100, "roundtrip loss exceeds 1%");
    }

    // ── access control ──────────────────────────────────────────
    function test_fork_onlyVault_deposit() public onlyFork {
        deal(WETH, address(adapter), 1 ether);
        vm.prank(stranger);
        vm.expectRevert("ADAPTER: only vault");
        adapter.deposit(1 ether);
    }

    function test_fork_onlyVault_withdraw() public onlyFork {
        _fundAndDeposit(1 ether);
        vm.prank(stranger);
        vm.expectRevert("ADAPTER: only vault");
        adapter.withdraw(0.5 ether, recipient);
    }

    // ── pause blocks deposit, unpause restores ──────────────────
    function test_fork_pause_blocks_deposit() public onlyFork {
        vm.prank(governance);
        adapter.pause();
        assertEq(adapter.isActive(), false);
        deal(WETH, address(adapter), 1 ether);
        vm.prank(vault);
        vm.expectRevert("ADAPTER: paused");
        adapter.deposit(1 ether);
        vm.prank(governance);
        adapter.unpause();
        assertEq(adapter.isActive(), true);
        vm.prank(vault);
        adapter.deposit(1 ether);
        assertGt(IERC20(WSTETH).balanceOf(address(adapter)), 0);
    }

    // ── withdraw is NOT blocked by pause (exit must always work) ─
    function test_fork_withdraw_works_while_paused() public onlyFork {
        _fundAndDeposit(2 ether);
        vm.prank(governance);
        adapter.pause();
        vm.prank(vault);
        uint256 got = adapter.withdraw(1 ether, recipient);
        assertGe(got, 1 ether);
    }
}
