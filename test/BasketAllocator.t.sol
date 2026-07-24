// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {BasketAllocator} from "../src/periphery/BasketAllocator.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {IStrategyAdapter} from "../src/interfaces/IStrategyAdapter.sol";
import {MockAdapter} from "./mocks/MockAdapter.sol";
import {HarvestAdapter} from "./mocks/HarvestAdapter.sol";
import {MockUSDC} from "./SIXXVault.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title BasketAllocatorTest
/// @notice Pure unit tests for the meta-allocator vessel. The test contract plays
///         the role of the SIXXVault (`sixxVault == address(this)`) so it can drive
///         deposit/withdraw directly, following the PUSH transfer model.
contract BasketAllocatorTest is Test {
    // Actors
    address governance = address(0xBEEF);
    address recipient  = address(0xCAFE);
    address stranger   = address(0x57A);

    // Contracts
    MockUSDC        usdc;
    AdapterRegistry registry;
    BasketAllocator basket;
    MockAdapter     c0; // weight 5000
    MockAdapter     c1; // weight 3000
    MockAdapter     c2; // weight 2000

    uint256 constant U = 1e6; // 1 USDC (6 decimals)

    function setUp() public {
        usdc = new MockUSDC();

        // H-1: the allocator enforces the same whitelist the SIXXVault does.
        vm.prank(governance);
        registry = new AdapterRegistry(governance);

        // sixxVault == address(this): the test drives deposit/withdraw.
        basket = new BasketAllocator(address(usdc), address(this), governance, address(registry));

        c0 = new MockAdapter(address(usdc), address(basket));
        c1 = new MockAdapter(address(usdc), address(basket));
        c2 = new MockAdapter(address(usdc), address(basket));

        // Whitelist all three sleeves so setComponents accepts them.
        vm.startPrank(governance);
        registry.registerAdapter(address(c0), "DeFi", "Mock");
        registry.registerAdapter(address(c1), "DeFi", "Mock");
        registry.registerAdapter(address(c2), "DeFi", "Mock");
        vm.stopPrank();

        address[] memory kids = new address[](3);
        kids[0] = address(c0);
        kids[1] = address(c1);
        kids[2] = address(c2);
        uint16[] memory w = new uint16[](3);
        w[0] = 5000;
        w[1] = 3000;
        w[2] = 2000;

        vm.prank(governance);
        basket.setComponents(kids, w);
    }

    // ── helpers ──────────────────────────────────────────────

    /// @dev Emulate the SIXXVault PUSH: mint underlying to the allocator, then call deposit.
    function _deposit(uint256 amount) internal {
        usdc.mint(address(basket), amount);
        basket.deposit(amount);
    }

    function _kidsWeights(uint16 a, uint16 b, uint16 cc)
        internal view returns (address[] memory kids, uint16[] memory w)
    {
        kids = new address[](3);
        kids[0] = address(c0);
        kids[1] = address(c1);
        kids[2] = address(c2);
        w = new uint16[](3);
        w[0] = a; w[1] = b; w[2] = cc;
    }

    // ── composition / config injection ───────────────────────

    function test_SetComponents_StoresCompositionAndMembership() public view {
        (address[] memory kids, uint16[] memory w) = basket.components();
        assertEq(kids.length, 3);
        assertEq(kids[0], address(c0));
        assertEq(w[0], 5000);
        assertEq(basket.childCount(), 3);
        assertTrue(basket.isChild(address(c0)));
        assertTrue(basket.isChild(address(c2)));
        assertFalse(basket.isChild(stranger));
    }

    function test_SetComponents_RevertsOnBadWeightSum() public {
        (address[] memory kids, uint16[] memory w) = _kidsWeights(5000, 3000, 1000); // 9000
        vm.prank(governance);
        vm.expectRevert("BASKET: weights != 10000");
        basket.setComponents(kids, w);
    }

    function test_SetComponents_RevertsOnZeroWeight() public {
        (address[] memory kids, uint16[] memory w) = _kidsWeights(7000, 3000, 0);
        vm.prank(governance);
        vm.expectRevert("BASKET: zero weight");
        basket.setComponents(kids, w);
    }

    function test_SetComponents_RevertsOnDuplicateChild() public {
        address[] memory kids = new address[](2);
        kids[0] = address(c0);
        kids[1] = address(c0);
        uint16[] memory w = new uint16[](2);
        w[0] = 5000; w[1] = 5000;
        vm.prank(governance);
        vm.expectRevert("BASKET: duplicate child");
        basket.setComponents(kids, w);
    }

    function test_SetComponents_RevertsOnAssetMismatch() public {
        MockUSDC other = new MockUSDC();
        MockAdapter wrong = new MockAdapter(address(other), address(basket));
        address[] memory kids = new address[](1);
        kids[0] = address(wrong);
        uint16[] memory w = new uint16[](1);
        w[0] = 10000;
        vm.prank(governance);
        vm.expectRevert("BASKET: asset mismatch");
        basket.setComponents(kids, w);
    }

    function test_SetComponents_RevertsOnUnwhitelistedChild() public {
        // Correct asset, but never registered in the AdapterRegistry (H-1).
        MockAdapter rogue = new MockAdapter(address(usdc), address(basket));
        address[] memory kids = new address[](2);
        kids[0] = address(c0);
        kids[1] = address(rogue);
        uint16[] memory w = new uint16[](2);
        w[0] = 5000; w[1] = 5000;
        vm.prank(governance);
        vm.expectRevert("BASKET: child not whitelisted");
        basket.setComponents(kids, w);
    }

    function test_SetComponents_RevertsOnDisabledChild() public {
        // Registered but then disabled → must be rejected (isActive == false).
        MockAdapter extra = new MockAdapter(address(usdc), address(basket));
        vm.startPrank(governance);
        registry.registerAdapter(address(extra), "DeFi", "Mock");
        registry.setAdapterStatus(address(extra), false);
        vm.stopPrank();

        address[] memory kids = new address[](2);
        kids[0] = address(c0);
        kids[1] = address(extra);
        uint16[] memory w = new uint16[](2);
        w[0] = 5000; w[1] = 5000;
        vm.prank(governance);
        vm.expectRevert("BASKET: child not whitelisted");
        basket.setComponents(kids, w);
    }

    function test_SetComponents_SucceedsWithWhitelistedChild() public {
        // Registering a fresh, correct-asset child lets it be injected.
        MockAdapter fresh = new MockAdapter(address(usdc), address(basket));
        vm.prank(governance);
        registry.registerAdapter(address(fresh), "DeFi", "Mock");

        address[] memory kids = new address[](2);
        kids[0] = address(c0);
        kids[1] = address(fresh);
        uint16[] memory w = new uint16[](2);
        w[0] = 4000; w[1] = 6000;
        vm.prank(governance);
        basket.setComponents(kids, w); // no revert
        assertTrue(basket.isChild(address(fresh)));
        assertEq(basket.childCount(), 2);
    }

    function test_SetComponents_RevertsWhenNotGovernance() public {
        (address[] memory kids, uint16[] memory w) = _kidsWeights(5000, 3000, 2000);
        vm.prank(stranger);
        vm.expectRevert("BASKET: only governance");
        basket.setComponents(kids, w);
    }

    function test_SetComponents_RevertsWhenFunded() public {
        _deposit(10_000 * U);
        (address[] memory kids, uint16[] memory w) = _kidsWeights(5000, 3000, 2000);
        vm.prank(governance);
        vm.expectRevert("BASKET: drain before re-composing");
        basket.setComponents(kids, w);
    }

    // ── deposit distribution ─────────────────────────────────

    function test_Deposit_DistributesByWeight() public {
        _deposit(10_000 * U);
        assertEq(c0.totalAssets(), 5_000 * U);
        assertEq(c1.totalAssets(), 3_000 * U);
        assertEq(c2.totalAssets(), 2_000 * U);
        assertEq(basket.totalAssets(), 10_000 * U);
    }

    function test_Deposit_DustGoesToFirstChild() public {
        // 10001 wei with 5000/3000/2000: floors = 5000/3000/2000 (sum 10000), dust 1 → c0.
        _deposit(10_001);
        assertEq(c0.totalAssets(), 5001);
        assertEq(c1.totalAssets(), 3000);
        assertEq(c2.totalAssets(), 2000);
        // 100% deployed, nothing stranded in the allocator.
        assertEq(basket.totalAssets(), 10_001);
        assertEq(usdc.balanceOf(address(basket)), 0);
    }

    function test_Deposit_RevertsWhenNotVault() public {
        usdc.mint(address(basket), 1_000 * U);
        vm.prank(stranger);
        vm.expectRevert("BASKET: only vault");
        basket.deposit(1_000 * U);
    }

    function test_Deposit_RevertsWhenNoComponents() public {
        BasketAllocator empty = new BasketAllocator(address(usdc), address(this), governance, address(registry));
        usdc.mint(address(empty), 1_000 * U);
        vm.expectRevert("BASKET: no components");
        empty.deposit(1_000 * U);
    }

    // ── withdraw proportional pull ───────────────────────────

    function test_Withdraw_ProportionalPreservesRatios() public {
        _deposit(10_000 * U);
        uint256 got = basket.withdraw(4_000 * U, recipient);
        assertEq(got, 4_000 * U);
        assertEq(usdc.balanceOf(recipient), 4_000 * U);
        // Remaining 6000 keeps the 5:3:2 ratio → 3000/1800/1200.
        assertEq(c0.totalAssets(), 3_000 * U);
        assertEq(c1.totalAssets(), 1_800 * U);
        assertEq(c2.totalAssets(), 1_200 * U);
        assertEq(basket.totalAssets(), 6_000 * U);
    }

    function test_Withdraw_FullExit() public {
        _deposit(10_000 * U);
        uint256 got = basket.withdraw(10_000 * U, recipient);
        assertEq(got, 10_000 * U);
        assertEq(usdc.balanceOf(recipient), 10_000 * U);
        assertEq(basket.totalAssets(), 0);
    }

    function test_Withdraw_RoundingRemainderSwept() public {
        _deposit(10_000 * U);
        // assets=1: pass-1 proportional shares all floor to 0 (1*bal/total < 1),
        // so the pass-2 sweep must deliver the full 1 wei.
        uint256 got = basket.withdraw(1, recipient);
        assertEq(got, 1);
        assertEq(usdc.balanceOf(recipient), 1);
        assertEq(basket.totalAssets(), 10_000 * U - 1);
    }

    function test_Withdraw_RevertsWhenNotVault() public {
        _deposit(10_000 * U);
        vm.prank(stranger);
        vm.expectRevert("BASKET: only vault");
        basket.withdraw(1_000 * U, recipient);
    }

    function test_Withdraw_ZeroTotalReturnsZero() public {
        // No deposit yet — totalAssets == 0.
        uint256 got = basket.withdraw(1_000 * U, recipient);
        assertEq(got, 0);
    }

    // ── pause / circuit breaker ──────────────────────────────

    function test_Pause_BlocksDeposit() public {
        vm.prank(governance);
        basket.pause();
        assertFalse(basket.isActive());
        usdc.mint(address(basket), 1_000 * U);
        vm.expectRevert("BASKET: paused");
        basket.deposit(1_000 * U);
    }

    function test_Pause_ByVault_ThenUnpauseByGovernance() public {
        // The vault (this contract) may pause.
        basket.pause();
        assertFalse(basket.isActive());
        // Only governance may unpause.
        vm.expectRevert("BASKET: only governance");
        basket.unpause();
        vm.prank(governance);
        basket.unpause();
        assertTrue(basket.isActive());
    }

    function test_Withdraw_StillWorksWhilePaused() public {
        _deposit(10_000 * U);
        vm.prank(governance);
        basket.pause();
        // Users must always be able to exit even when deposits are frozen.
        uint256 got = basket.withdraw(5_000 * U, recipient);
        assertEq(got, 5_000 * U);
    }

    function test_PauseChild_OnlyGovernance() public {
        vm.prank(stranger);
        vm.expectRevert("BASKET: only governance");
        basket.pauseChild(address(c0));

        vm.prank(governance);
        basket.pauseChild(address(c0));
        assertFalse(c0.isActive());
    }

    // ── rebalance / reweight ─────────────────────────────────

    function test_Rebalance_RealignsDrift() public {
        _deposit(10_000 * U);
        // Simulate c1 earning yield → drift away from target ratio.
        usdc.mint(address(this), 1_000 * U);
        usdc.approve(address(c1), 1_000 * U);
        c1.addYield(1_000 * U); // c1 now holds 4000, total 11000

        assertEq(basket.totalAssets(), 11_000 * U);

        vm.prank(governance);
        basket.rebalance();

        // 11000 re-split 5:3:2 → 5500/3300/2200.
        assertEq(c0.totalAssets(), 5_500 * U);
        assertEq(c1.totalAssets(), 3_300 * U);
        assertEq(c2.totalAssets(), 2_200 * U);
        assertEq(usdc.balanceOf(address(basket)), 0);
    }

    function test_SetWeights_ReweightsAndRealigns() public {
        _deposit(10_000 * U);
        uint16[] memory w = new uint16[](3);
        w[0] = 2000; w[1] = 2000; w[2] = 6000;
        vm.prank(governance);
        basket.setWeights(w);
        assertEq(c0.totalAssets(), 2_000 * U);
        assertEq(c1.totalAssets(), 2_000 * U);
        assertEq(c2.totalAssets(), 6_000 * U);
        (, uint16[] memory got) = basket.components();
        assertEq(got[2], 6000);
    }

    function test_SetWeights_RevertsOnBadSum() public {
        _deposit(10_000 * U);
        uint16[] memory w = new uint16[](3);
        w[0] = 2000; w[1] = 2000; w[2] = 5000; // 9000
        vm.prank(governance);
        vm.expectRevert("BASKET: weights != 10000");
        basket.setWeights(w);
    }

    function test_Rebalance_OnlyGovernance() public {
        _deposit(10_000 * U);
        vm.prank(stranger);
        vm.expectRevert("BASKET: only governance");
        basket.rebalance();
    }

    // ── harvest aggregation ──────────────────────────────────

    function test_Harvest_AggregatesChildren() public {
        // Rebuild the basket out of HarvestAdapters that realize reward on harvest.
        BasketAllocator hb = new BasketAllocator(address(usdc), address(this), governance, address(registry));
        HarvestAdapter h0 = new HarvestAdapter(address(usdc), address(hb));
        HarvestAdapter h1 = new HarvestAdapter(address(usdc), address(hb));

        address[] memory kids = new address[](2);
        kids[0] = address(h0);
        kids[1] = address(h1);
        uint16[] memory w = new uint16[](2);
        w[0] = 6000; w[1] = 4000;
        vm.startPrank(governance);
        registry.registerAdapter(address(h0), "DeFi", "Harvest");
        registry.registerAdapter(address(h1), "DeFi", "Harvest");
        hb.setComponents(kids, w);
        vm.stopPrank();

        usdc.mint(address(hb), 10_000 * U);
        hb.deposit(10_000 * U);

        // Seed pending rewards in both children.
        usdc.mint(address(this), 300 * U);
        usdc.approve(address(h0), 200 * U);
        usdc.approve(address(h1), 100 * U);
        h0.addReward(200 * U);
        h1.addReward(100 * U);

        uint256 harvested = hb.harvest();
        assertEq(harvested, 300 * U);
        assertEq(hb.totalAssets(), 10_300 * U);
    }

    // ── metadata aggregation ─────────────────────────────────

    function test_Metadata_RiskIsMaxAndApyIsBlended() public {
        // Swap c2 for a HarvestAdapter (risk 2, apy 800) to exercise max/blend.
        HarvestAdapter h = new HarvestAdapter(address(usdc), address(basket));
        address[] memory kids = new address[](2);
        kids[0] = address(c0); // MockAdapter: risk 1, apy 500
        kids[1] = address(h);  // Harvest:    risk 2, apy 800
        uint16[] memory w = new uint16[](2);
        w[0] = 5000; w[1] = 5000;
        vm.startPrank(governance);
        registry.registerAdapter(address(h), "DeFi", "Harvest");
        basket.setComponents(kids, w);
        vm.stopPrank();

        // riskLevel = max(1,2) = 2
        assertEq(basket.riskLevel(), 2);
        // blended APY = (5000*500 + 5000*800) / 10000 = 650 bps
        assertEq(basket.estimatedAPY(), 650);
    }

    // ── two-step rotations (M-4) ─────────────────────────────

    function test_TwoStepGovernanceRotation() public {
        vm.prank(governance);
        basket.proposeGovernance(stranger);
        // Not effective until accepted.
        assertEq(basket.governance(), governance);
        vm.prank(stranger);
        basket.acceptGovernance();
        assertEq(basket.governance(), stranger);
    }

    function test_TwoStepGovernance_WrongAcceptorReverts() public {
        vm.prank(governance);
        basket.proposeGovernance(stranger);
        vm.prank(address(0xDEAD));
        vm.expectRevert("BASKET: not pending governance");
        basket.acceptGovernance();
    }

    function test_TwoStepSixxVaultRotation() public {
        vm.prank(governance);
        basket.proposeSixxVault(stranger);
        assertEq(basket.sixxVault(), address(this));
        vm.prank(stranger);
        basket.acceptSixxVault();
        assertEq(basket.sixxVault(), stranger);
    }

    // ── rescue ───────────────────────────────────────────────

    function test_RescueToken_ForbidsUnderlying() public {
        vm.prank(governance);
        vm.expectRevert("BASKET: cannot rescue underlying");
        basket.rescueToken(address(usdc), governance);
    }

    function test_RescueToken_SweepsStrayToken() public {
        MockUSDC stray = new MockUSDC();
        stray.mint(address(basket), 777);
        vm.prank(governance);
        uint256 amt = basket.rescueToken(address(stray), governance);
        assertEq(amt, 777);
        assertEq(stray.balanceOf(governance), 777);
    }

    function test_RescueToken_OnlyGovernance() public {
        MockUSDC stray = new MockUSDC();
        stray.mint(address(basket), 1);
        vm.prank(stranger);
        vm.expectRevert("BASKET: only governance");
        basket.rescueToken(address(stray), stranger);
    }
}
