// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BNBStakingAdapter} from "../src/adapters/BNBStakingAdapter.sol";
import {IListaStakeManager} from "../src/interfaces/IListaStakeManager.sol";

/// @title BNBStakingAdapterForkTest
/// @notice BNB Chain fork integration for the Lista slisBNB adapter.
///         Exercises the real Lista stake and PancakeSwap V3 slisBNB->WBNB exit.
///         Run: set -a; source ../sixx-interface/.env.local; set +a; \
///              forge test --match-contract BNBStakingAdapterForkTest \
///              --fork-url $BNB_RPC_URL -vv
contract BNBStakingAdapterForkTest is Test {
    // Verified on-chain 2026-07-23
    address constant WBNB      = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant SLISBNB   = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
    address constant STAKEMGR  = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;
    address constant V3ROUTER  = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    uint24  constant POOL_FEE  = 500; // slisBNB/WBNB 0.05% pool (deepest venue)

    uint256 constant FORK_BLOCK = 111_700_363;

    address governance = makeAddr("governance");
    address vault      = makeAddr("vault");
    address recipient  = makeAddr("recipient");
    address stranger   = makeAddr("stranger");

    BNBStakingAdapter adapter;
    bool forked;

    function setUp() public {
        string memory url = vm.envOr("BNB_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            forked = false;
            return;
        }
        vm.createSelectFork(url, FORK_BLOCK);
        forked = true;
        adapter = new BNBStakingAdapter(
            WBNB, SLISBNB, STAKEMGR, V3ROUTER, POOL_FEE, vault, governance, 250
        );
        // Clear any fork-inherited native balance at the deterministic address.
        vm.deal(address(adapter), 0);
    }

    modifier onlyFork() {
        if (!forked) return;
        _;
    }

    function _fundAndDeposit(uint256 wbnbAmt) internal {
        deal(WBNB, address(adapter), wbnbAmt);
        vm.prank(vault);
        adapter.deposit(wbnbAmt);
    }

    // ── wiring sanity ───────────────────────────────────────────
    function test_fork_wiring() public onlyFork {
        assertEq(adapter.asset(), WBNB);
        assertEq(address(adapter.slisBNB()), SLISBNB);
        assertEq(adapter.poolFee(), POOL_FEE);
        assertEq(adapter.riskLevel(), 2);
        assertEq(adapter.requiredLockPeriod(), 0);
        assertEq(adapter.estimatedAPY(), 250);
        // sanity: exchange rate is > 1 BNB per slisBNB (value-accruing)
        assertGt(IListaStakeManager(STAKEMGR).convertSnBnbToBnb(1e18), 1e18);
    }

    // ── deposit: WBNB -> BNB -> slisBNB ─────────────────────────
    function test_fork_deposit_holds_slisbnb() public onlyFork {
        _fundAndDeposit(10 ether);
        uint256 shares = IERC20(SLISBNB).balanceOf(address(adapter));
        assertGt(shares, 0, "no slisBNB minted");
        assertEq(IERC20(WBNB).balanceOf(address(adapter)), 0, "idle WBNB");
        assertEq(address(adapter).balance, 0, "idle BNB");
        uint256 nav = adapter.totalAssets();
        emit log_named_uint("slisBNB held", shares);
        emit log_named_uint("totalAssets WBNB (haircut)", nav);
        assertGt(nav, 9.9 ether);
        assertLt(nav, 10 ether); // conservative — never over-reports
    }

    // ── partial withdraw delivers >= requested (vault guard) ────
    function test_fork_partial_withdraw() public onlyFork {
        _fundAndDeposit(20 ether);
        uint256 want = 5 ether;
        vm.prank(vault);
        uint256 got = adapter.withdraw(want, recipient);
        assertGe(got, want, "shortfall vs requested");
        assertEq(IERC20(WBNB).balanceOf(recipient), got);
        assertGt(IERC20(SLISBNB).balanceOf(address(adapter)), 0, "position fully drained on partial");
        emit log_named_uint("requested WBNB", want);
        emit log_named_uint("received WBNB", got);
    }

    // ── full drain covers reported NAV (setAdapter/emergency path) ──
    function test_fork_full_drain_covers_nav() public onlyFork {
        _fundAndDeposit(20 ether);
        uint256 nav = adapter.totalAssets();
        vm.prank(vault);
        uint256 got = adapter.withdraw(nav, recipient);
        assertGe(got, nav, "full drain under-delivers vs reported NAV");
        assertEq(IERC20(SLISBNB).balanceOf(address(adapter)), 0, "slisBNB dust left after full drain");
        emit log_named_uint("reported NAV", nav);
        emit log_named_uint("drained WBNB", got);
    }

    // ── round-trip loss within budget for a retail-sized position ──
    function test_fork_roundtrip_within_budget() public onlyFork {
        uint256 principal = 20 ether;
        _fundAndDeposit(principal);
        uint256 nav = adapter.totalAssets();
        vm.prank(vault);
        uint256 got = adapter.withdraw(nav, recipient);
        uint256 lossBps = principal > got ? ((principal - got) * 10_000) / principal : 0;
        emit log_named_uint("roundtrip loss (bps)", lossBps);
        assertLt(lossBps, 100, "roundtrip loss exceeds 1%");
    }

    // ── oversized exit reverts on the slippage floor (thin pool) ──
    function test_fork_oversized_exit_reverts_on_slippage() public onlyFork {
        // Seed a slisBNB position far exceeding the ~$2.5M pool depth so the
        // exit alone would blow through the 0.5% slippage floor.
        uint256 bigShares = 50_000 ether; // ~50k slisBNB, dwarfs pool depth
        deal(SLISBNB, address(adapter), bigShares);
        uint256 nav = adapter.totalAssets();
        vm.prank(vault);
        vm.expectRevert(); // PancakeSwap amountOutMinimum (slippage floor) not met
        adapter.withdraw(nav, recipient);
    }

    // ── access control ──────────────────────────────────────────
    function test_fork_onlyVault_deposit() public onlyFork {
        deal(WBNB, address(adapter), 1 ether);
        vm.prank(stranger);
        vm.expectRevert("ADAPTER: only vault");
        adapter.deposit(1 ether);
    }

    function test_fork_onlyVault_withdraw() public onlyFork {
        _fundAndDeposit(2 ether);
        vm.prank(stranger);
        vm.expectRevert("ADAPTER: only vault");
        adapter.withdraw(1 ether, recipient);
    }

    // ── pause blocks deposit; unpause restores; withdraw stays open ─
    function test_fork_pause_semantics() public onlyFork {
        vm.prank(governance);
        adapter.pause();
        assertEq(adapter.isActive(), false);
        deal(WBNB, address(adapter), 2 ether);
        vm.prank(vault);
        vm.expectRevert("ADAPTER: paused");
        adapter.deposit(2 ether);

        vm.prank(governance);
        adapter.unpause();
        vm.prank(vault);
        adapter.deposit(2 ether);
        assertGt(IERC20(SLISBNB).balanceOf(address(adapter)), 0);

        // withdraw works even while paused
        vm.prank(governance);
        adapter.pause();
        vm.prank(vault);
        uint256 got = adapter.withdraw(1 ether, recipient);
        assertGe(got, 1 ether);
    }
}
