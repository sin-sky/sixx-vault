// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {MockUSDC} from "./SIXXVault.t.sol";

/// @dev Exposes Deploy's internal wiring helpers as external functions so
///      tests can exercise the SCRIPT's actual code paths (not a re-implementation).
contract DeployHarness is Deploy {
    function safe(address deployer) external view returns (address) {
        return _safe(deployer);
    }

    function deployCore(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address safe_,
        address feeRecipient_
    ) external returns (TimelockController, AdapterRegistry, SIXXVault) {
        return _deployCore(asset_, name_, symbol_, safe_, feeRecipient_);
    }
}

/// @notice C-1 review follow-up: script/Deploy.s.sol wires governance to the
///         Timelock and the guardian to the Safe -- the highest-blast-radius
///         part of the change. These tests exercise the SCRIPT's own wiring
///         helper (via a thin harness subclass), not a hand-rolled setUp that
///         merely mirrors it.
contract DeployWiringTest is Test {
    DeployHarness harness;
    MockUSDC usdc;

    address deployer     = address(0xD00D);
    address safeAddr     = address(0x5AFE);
    address feeRecipient = address(0xFEE);

    function setUp() public {
        harness = new DeployHarness();
        usdc = new MockUSDC();
    }

    function test_deployCore_routes_governance_to_timelock() public {
        (TimelockController timelock, AdapterRegistry registry, SIXXVault vault) =
            harness.deployCore(IERC20(address(usdc)), "n", "s", safeAddr, feeRecipient);

        assertEq(vault.governance(), address(timelock), "vault governance != timelock");
        assertEq(registry.governance(), address(timelock), "registry governance != timelock");
        assertEq(vault.guardian(), safeAddr, "vault guardian != safe");
        assertEq(vault.feeRecipient(), feeRecipient, "vault feeRecipient mismatch");
    }

    function test_safe_addresses_per_chain() public {
        vm.chainId(1);
        assertEq(harness.safe(deployer), 0x4d71aCE4612AB3B71423b454e21c0Bd03c4F8fE0);

        vm.chainId(42161);
        assertEq(harness.safe(deployer), 0xd388aC46E7a763d5eaFb73b735292c6A46B5BAC0);

        vm.chainId(56);
        assertEq(harness.safe(deployer), 0x81E85C9F3FdE1ceE38cD3DA9bbAa6212F01D196D);

        vm.chainId(421614); // testnet -> falls back to deployer
        assertEq(harness.safe(deployer), deployer);
    }

    function test_timelock_min_delay_is_48h() public {
        (TimelockController timelock,,) =
            harness.deployCore(IERC20(address(usdc)), "n", "s", safeAddr, feeRecipient);

        assertEq(timelock.getMinDelay(), 48 hours);
    }
}
