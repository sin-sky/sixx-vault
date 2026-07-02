// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {AaveV3USDCAdapter} from "../src/adapters/AaveV3USDCAdapter.sol";
import {VenusUSDTAdapter} from "../src/adapters/VenusUSDTAdapter.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {MockUSDC} from "./SIXXVault.t.sol";

/// @dev Minimal Venus vToken stub: the adapter constructor only needs
///      underlying() to match the asset (and an ERC20 to forceApprove).
contract MockVToken {
    address public immutable underlyingAsset;

    constructor(address underlying_) {
        underlyingAsset = underlying_;
    }

    function underlying() external view returns (address) {
        return underlyingAsset;
    }
}

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
        address safe_
    ) external returns (TimelockController, AdapterRegistry, SIXXVault) {
        return _deployCore(asset_, name_, symbol_, safe_);
    }

    function newAaveAdapter(
        address usdc,
        address aavePool,
        address aUsdc,
        address vault_,
        address governance_
    ) external returns (AaveV3USDCAdapter) {
        return _newAaveAdapter(usdc, aavePool, aUsdc, vault_, governance_);
    }

    function newVenusAdapter(
        address usdt,
        address vUsdt,
        address vault_,
        address governance_
    ) external returns (VenusUSDTAdapter) {
        return _newVenusAdapter(usdt, vUsdt, vault_, governance_);
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

    address deployer = address(0xD00D);
    address safeAddr = address(0x5AFE);

    function setUp() public {
        harness = new DeployHarness();
        usdc = new MockUSDC();
    }

    function test_deployCore_routes_governance_to_timelock() public {
        (TimelockController timelock, AdapterRegistry registry, SIXXVault vault) =
            harness.deployCore(IERC20(address(usdc)), "n", "s", safeAddr);

        assertEq(vault.governance(), address(timelock), "vault governance != timelock");
        assertEq(registry.governance(), address(timelock), "registry governance != timelock");
        assertEq(vault.guardian(), safeAddr, "vault guardian != safe");
        // SHIN decision 2026-07-02: fees accrue to the chain's Safe, not a hot deployer key.
        assertEq(vault.feeRecipient(), safeAddr, "vault feeRecipient must be the Safe");
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
            harness.deployCore(IERC20(address(usdc)), "n", "s", safeAddr);

        assertEq(timelock.getMinDelay(), 48 hours);
    }

    /// @notice C-1 audit follow-up (Critical): both chain adapters must be
    ///         governed by the Timelock, never the hot deployer key. Exercises
    ///         the script's own adapter-construction helpers.
    function test_adapters_governed_by_timelock_not_deployer() public {
        (TimelockController timelock,, SIXXVault vault) =
            harness.deployCore(IERC20(address(usdc)), "n", "s", safeAddr);

        // Aave adapter: pool/aToken only need to be non-zero (constructor
        // forceApproves the pool on the asset; it makes no call into them).
        AaveV3USDCAdapter aave = harness.newAaveAdapter(
            address(usdc), address(0xA00E), address(0xA70C), address(vault), address(timelock)
        );
        assertEq(aave.governance(), address(timelock), "aave adapter governance != timelock");
        assertTrue(aave.governance() != deployer, "aave adapter must not be deployer-governed");

        // Venus adapter: needs a vToken whose underlying() == asset.
        MockVToken vusdt = new MockVToken(address(usdc));
        VenusUSDTAdapter venus = harness.newVenusAdapter(
            address(usdc), address(vusdt), address(vault), address(timelock)
        );
        assertEq(venus.governance(), address(timelock), "venus adapter governance != timelock");
        assertTrue(venus.governance() != deployer, "venus adapter must not be deployer-governed");
    }
}
