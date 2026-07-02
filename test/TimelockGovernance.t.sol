// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {MockUSDC} from "./SIXXVault.t.sol";
import {MockAdapter} from "./mocks/MockAdapter.sol";

contract TimelockGovernanceTest is Test {
    address safe = address(0x5AFE);

    MockUSDC usdc;
    TimelockController timelock;
    AdapterRegistry registry;
    SIXXVault vault;
    MockAdapter adapter;

    uint256 constant DELAY = 48 hours;

    function setUp() public {
        usdc = new MockUSDC();
        address[] memory ps = new address[](1);
        address[] memory es = new address[](1);
        ps[0] = safe; es[0] = safe;
        timelock = new TimelockController(DELAY, ps, es, address(0));

        registry = new AdapterRegistry(address(timelock));
        vault = new SIXXVault(
            IERC20(address(usdc)), "SIXX Stable Yield", "sxUSDC",
            address(timelock), address(registry), address(0xFEE), safe
        );
        adapter = new MockAdapter(address(usdc), address(vault));
    }

    function test_setAdapter_direct_safe_call_reverts() public {
        vm.prank(safe);
        vm.expectRevert(bytes("VAULT: not governance"));
        vault.setAdapter(address(adapter));
    }

    function test_setAdapter_via_timelock_after_delay() public {
        // register adapter through the timelock first
        bytes memory regData = abi.encodeWithSelector(
            registry.registerAdapter.selector, address(adapter), "DeFi", "Mock"
        );
        _scheduleAndExecute(address(registry), regData);

        // now set the adapter through the timelock
        bytes memory setData = abi.encodeWithSelector(vault.setAdapter.selector, address(adapter));
        _scheduleAndExecute(address(vault), setData);

        assertEq(vault.activeAdapter(), address(adapter));
    }

    function test_setAdapter_execute_before_delay_reverts() public {
        // register adapter through the timelock first (same pattern as the passing test)
        bytes memory regData = abi.encodeWithSelector(
            registry.registerAdapter.selector, address(adapter), "DeFi", "Mock"
        );
        _scheduleAndExecute(address(registry), regData);

        // schedule setAdapter but do NOT warp past the delay
        bytes memory setData = abi.encodeWithSelector(vault.setAdapter.selector, address(adapter));
        bytes32 salt = bytes32(uint256(1));
        bytes32 opId = timelock.hashOperation(address(vault), 0, setData, bytes32(0), salt);

        vm.prank(safe);
        timelock.schedule(address(vault), 0, setData, bytes32(0), salt, DELAY);

        // explicit proof the operation is not yet executable
        assertFalse(timelock.isOperationReady(opId));

        vm.prank(safe);
        vm.expectRevert();
        timelock.execute(address(vault), 0, setData, bytes32(0), salt);

        // still not set, since execution reverted
        assertEq(vault.activeAdapter(), address(0));

        // bracket the property: after the delay elapses, the same op becomes ready
        vm.warp(block.timestamp + DELAY + 1);
        assertTrue(timelock.isOperationReady(opId));
    }

    function test_emergency_shutdown_bypasses_timelock_via_guardian() public {
        // guardian(safe) calls directly, no schedule/delay
        vm.prank(safe);
        vault.setEmergencyShutdown(true);
        assertTrue(vault.emergencyShutdown());
    }

    function _scheduleAndExecute(address target, bytes memory data) internal {
        bytes32 salt = bytes32(0);
        vm.prank(safe);
        timelock.schedule(target, 0, data, bytes32(0), salt, DELAY);
        vm.warp(block.timestamp + DELAY + 1);
        vm.prank(safe);
        timelock.execute(target, 0, data, bytes32(0), salt);
    }
}
