// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {BasketAllocator} from "../src/periphery/BasketAllocator.sol";
import {MockAdapter} from "./mocks/MockAdapter.sol";
import {MockUSDC} from "./SIXXVault.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title BasketAllocatorIntegrationTest
/// @notice Proves the BasketAllocator behaves as an ORDINARY adapter when plugged
///         into the real SIXXVault: a user deposit routes vault → allocator →
///         children by weight, and a user withdraw pulls back through the same
///         path. This is the key "the vault sees it as one adapter" claim.
contract BasketAllocatorIntegrationTest is Test {
    address governance   = address(0xBEEF);
    address alice        = address(0xA11CE);
    address feeRcpt      = address(0xFEE);
    address guardianAddr = address(0x6042D);

    MockUSDC        usdc;
    AdapterRegistry registry;
    SIXXVault       vault;
    BasketAllocator basket;
    MockAdapter     c0;
    MockAdapter     c1;

    uint256 constant U = 1e6;

    function setUp() public {
        usdc = new MockUSDC();

        vm.prank(governance);
        registry = new AdapterRegistry(governance);

        vm.prank(governance);
        vault = new SIXXVault(
            IERC20(address(usdc)),
            "SIXX Basket",
            "sxBASK",
            governance,
            address(registry),
            feeRcpt,
            guardianAddr
        );

        // The allocator is the vault's single adapter; the allocator's own
        // children are keyed to the allocator as THEIR vault. The allocator shares
        // the vault's registry so H-1 gates the sleeves too.
        basket = new BasketAllocator(address(usdc), address(vault), governance, address(registry));
        c0 = new MockAdapter(address(usdc), address(basket));
        c1 = new MockAdapter(address(usdc), address(basket));

        address[] memory kids = new address[](2);
        kids[0] = address(c0);
        kids[1] = address(c1);
        uint16[] memory w = new uint16[](2);
        w[0] = 7000;
        w[1] = 3000;

        vm.startPrank(governance);
        // Whitelist the sleeves (H-1 inside the basket) and the basket itself.
        registry.registerAdapter(address(c0), "DeFi", "Mock");
        registry.registerAdapter(address(c1), "DeFi", "Mock");
        basket.setComponents(kids, w);
        registry.registerAdapter(address(basket), "DeFi", "SIXX Basket");
        vault.setAdapter(address(basket));
        vm.stopPrank();

        usdc.mint(alice, 100_000 * U);
    }

    function test_VaultDeposit_RoutesToBasketByWeight() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 10_000 * U);
        vault.deposit(10_000 * U, alice);
        vm.stopPrank();

        // Funds fanned out 70/30 across the sleeves, nothing idle anywhere.
        assertEq(c0.totalAssets(), 7_000 * U);
        assertEq(c1.totalAssets(), 3_000 * U);
        assertEq(basket.totalAssets(), 10_000 * U);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(vault.totalAssets(), 10_000 * U);
    }

    function test_VaultWithdraw_PullsBackThroughBasket() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 10_000 * U);
        vault.deposit(10_000 * U, alice);

        uint256 before = usdc.balanceOf(alice);
        vault.withdraw(4_000 * U, alice, alice);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice) - before, 4_000 * U);
        // Remaining 6000 keeps the 7:3 sleeve ratio.
        assertEq(c0.totalAssets(), 4_200 * U);
        assertEq(c1.totalAssets(), 1_800 * U);
        assertEq(basket.totalAssets(), 6_000 * U);
    }

    function test_VaultFullRedeem_DrainsBasket() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 10_000 * U);
        uint256 shares = vault.deposit(10_000 * U, alice);
        uint256 out = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        assertApproxEqAbs(out, 10_000 * U, 2);
        assertEq(basket.totalAssets(), 0);
        assertEq(c0.totalAssets(), 0);
        assertEq(c1.totalAssets(), 0);
    }

    function test_SetAdapterZero_ForceRecallsBasket() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 10_000 * U);
        vault.deposit(10_000 * U, alice);
        vm.stopPrank();

        // Governance detaches the basket → vault force-recalls 100% back to itself.
        vm.prank(governance);
        vault.setAdapter(address(0));

        assertEq(basket.totalAssets(), 0);
        assertEq(usdc.balanceOf(address(vault)), 10_000 * U);
        assertEq(vault.totalAssets(), 10_000 * U);
    }
}
