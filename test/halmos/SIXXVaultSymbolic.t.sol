// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {SIXXVault} from "../../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../../src/core/AdapterRegistry.sol";
import {MockAdapter} from "../mocks/MockAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract SymUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

/// @title SIXXVault Halmos symbolic pilot (ADR-006 L3)
/// @notice Formal-verification pilot for the accounting core. Proves — for ALL deposit
///         amounts in a bounded range, not just sampled ones — that a single deposit can
///         never leave outstanding shares able to claim more assets than the vault holds
///         (INV-2, the share↔asset consistency property).
/// @dev Run: `halmos --function check_ --contract SIXXVaultSymbolic`.
///      Kept intentionally small (single deposit, one actor) so the solver stays tractable;
///      the fuzz/invariant/Echidna layers cover multi-step sequences.
contract SIXXVaultSymbolic is SymTest, Test {
    SymUSDC         usdc;
    AdapterRegistry registry;
    SIXXVault       vault;
    MockAdapter     adapter;

    address governance   = address(0xBEEF);
    address feeRcpt      = address(0xFEE);
    address guardianAddr = address(0x6042D);
    address alice        = address(0xA11CE);

    function setUp() public {
        usdc = new SymUSDC();
        vm.prank(governance);
        registry = new AdapterRegistry(governance);
        vm.prank(governance);
        vault = new SIXXVault(
            IERC20(address(usdc)), "SIXX Stable Yield", "sxUSDC",
            governance, address(registry), feeRcpt, guardianAddr
        );
        adapter = new MockAdapter(address(usdc), address(vault));
        vm.startPrank(governance);
        registry.registerAdapter(address(adapter), "DeFi", "Mock");
        vault.setAdapter(address(adapter));
        vault.setManagementFee(0);
        vault.setPerformanceFee(0);
        vm.stopPrank();
    }

    /// @notice INV-1 (symbolic): a single deposit creates no value.
    ///         For ALL amounts in range, reported totalAssets equals exactly what was
    ///         deposited — the vault never mints assets out of thin air. This property is
    ///         linear (no share mulDiv), so the solver discharges it quickly; the nonlinear
    ///         share-rounding property (INV-2) is left to the fuzz/invariant/Echidna layers.
    function check_depositCreatesNoValue(uint256 amount) public {
        vm.assume(amount > 0);
        vm.assume(amount <= 1_000_000e6);

        usdc.mint(alice, amount);
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();

        // PUSH model: everything is deployed to the adapter, idle is 0, and the mock adapter
        // holds exactly `amount` ⇒ totalAssets == amount (value conservation, no creation).
        assertEq(vault.totalAssets(), amount);
    }

    /// @notice DINV-2 / DINV-4 (symbolic): a solo depositor can NEVER redeem more than they
    ///         deposited — the share↔asset round-trip is always vault-favorable, proven for
    ///         ALL amounts in range (not sampled). Exercises the nonlinear share mulDiv with
    ///         the virtual-shares offset (9); the solver stays tractable on a single deposit.
    function check_redeemNeverExceedsDeposit(uint256 amount) public {
        vm.assume(amount > 0);
        vm.assume(amount <= 1_000_000e6);

        usdc.mint(alice, amount);
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);
        uint256 got = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        assertLe(got, amount);
    }
}
