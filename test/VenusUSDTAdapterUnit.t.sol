// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {VenusUSDTAdapter} from "../src/adapters/VenusUSDTAdapter.sol";
import {MockUSDT, MockVUSDT} from "./VenusUSDTAdapter.t.sol";

/// @title VenusUSDTAdapterUnitTest
/// @notice Non-fork unit tests for the 2 audit-hardening fixes:
///         harvest onlyVault gating and ADP-2 rescueToken. No RPC required.
///         Mirrors AaveV3USDCAdapterUnit.t.sol; reuses the mocks declared in
///         VenusUSDTAdapter.t.sol.
contract VenusUSDTAdapterUnitTest is Test {
    address governance = makeAddr("governance");
    address vault      = makeAddr("vault");
    address stranger   = makeAddr("stranger");
    address recipient  = makeAddr("recipient");

    MockUSDT usdt;
    MockVUSDT vusdt;
    VenusUSDTAdapter adapter;

    uint256 constant RATE = 2e17;

    function setUp() public {
        usdt  = new MockUSDT();
        vusdt = new MockVUSDT(address(usdt), RATE);
        adapter = new VenusUSDTAdapter(address(usdt), address(vusdt), vault, governance);
    }

    // ─────────────────────────────────────────────────────────
    // Fix 1 — harvest access control
    // ─────────────────────────────────────────────────────────

    function test_harvest_only_vault() public {
        vm.prank(stranger);
        vm.expectRevert("ADAPTER: only vault");
        adapter.harvest();
    }

    function test_harvest_succeeds_for_vault() public {
        vm.prank(vault);
        uint256 harvested = adapter.harvest();
        assertEq(harvested, 0);
    }

    // ─────────────────────────────────────────────────────────
    // Fix 2 — ADP-2: rescueToken
    // ─────────────────────────────────────────────────────────

    function test_rescue_sweeps_stray_token() public {
        MockUSDT stray = new MockUSDT();
        stray.mint(address(adapter), 1_000e18);

        vm.prank(governance);
        uint256 amount = adapter.rescueToken(address(stray), recipient);

        assertEq(amount, 1_000e18);
        assertEq(stray.balanceOf(recipient), 1_000e18);
        assertEq(stray.balanceOf(address(adapter)), 0);
    }

    function test_rescue_cannot_take_position_token() public {
        vm.prank(governance);
        vm.expectRevert("ADAPTER: cannot rescue position");
        adapter.rescueToken(address(vusdt), recipient);
    }

    /// L-02 (3rd review): the underlying (USDT principal) must be un-rescuable, like Pendle.
    function test_L02_rescue_cannot_take_underlying() public {
        vm.prank(governance);
        vm.expectRevert("ADAPTER: cannot rescue principal");
        adapter.rescueToken(address(usdt), recipient);
    }

    function test_rescue_only_governance() public {
        vm.prank(stranger);
        vm.expectRevert("ADAPTER: not governance");
        adapter.rescueToken(address(usdt), recipient);
    }
}
