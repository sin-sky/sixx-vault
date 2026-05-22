// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AaveV3USDCAdapter} from "../src/adapters/AaveV3USDCAdapter.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Deploy
/// @notice Deploys SIXXVault + AdapterRegistry + AaveV3USDCAdapter on the
///         active testnet, selecting addresses via block.chainid.
///
/// Supported chains:
///   - ETH Sepolia     (11155111) — Aave V3 Sepolia
///   - Arbitrum Sepolia (421614)  — Aave V3 Arbitrum Sepolia
///
/// Usage:
///   forge script script/Deploy.s.sol \
///     --rpc-url $ETH_SEPOLIA_RPC_URL --broadcast --verify
///   forge script script/Deploy.s.sol \
///     --rpc-url $ARB_SEPOLIA_RPC_URL --broadcast --verify
contract Deploy is Script {
    // ─── Chain IDs ───────────────────────────────────────────
    uint256 internal constant ETH_SEPOLIA = 11155111;
    uint256 internal constant ARB_SEPOLIA = 421614;

    struct Addresses {
        address usdc;
        address aavePool;
        address aUsdc;
        string  label;
    }

    function _addresses() internal view returns (Addresses memory a) {
        if (block.chainid == ETH_SEPOLIA) {
            // Source: bgd-labs/aave-address-book → AaveV3Sepolia
            a.usdc     = 0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8;
            a.aavePool = 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951;
            a.aUsdc    = 0x16dA4541aD1807f4443d92D26044C1147406EB80;
            a.label    = "ETH Sepolia";
        } else if (block.chainid == ARB_SEPOLIA) {
            a.usdc     = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;
            a.aavePool = 0xBfC91D59fdAA134A4ED45f7B584cAf96D7792Eff;
            a.aUsdc    = 0x460b97BD498E1157530AEb3086301d5225b91216;
            a.label    = "Arbitrum Sepolia";
        } else {
            revert("Deploy: unsupported chainid");
        }
    }

    function run() external {
        Addresses memory a = _addresses();

        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer   = vm.addr(deployerPk);

        console2.log("Network     :", a.label);
        console2.log("Chain ID    :", block.chainid);
        console2.log("Deployer    :", deployer);
        console2.log("USDC        :", a.usdc);
        console2.log("Aave Pool   :", a.aavePool);
        console2.log("aUSDC       :", a.aUsdc);

        vm.startBroadcast(deployerPk);

        AdapterRegistry registry = new AdapterRegistry(deployer);
        console2.log("Registry    :", address(registry));

        SIXXVault vault = new SIXXVault(
            IERC20(a.usdc),
            "SIXX Stable Yield",
            "sxUSDC",
            deployer,
            address(registry),
            deployer
        );
        console2.log("SIXXVault   :", address(vault));

        AaveV3USDCAdapter adapter = new AaveV3USDCAdapter(
            a.usdc, a.aavePool, a.aUsdc, address(vault), deployer, 0
        );
        console2.log("Adapter     :", address(adapter));

        registry.registerAdapter(address(adapter), "DeFi", "Aave V3");
        vault.setAdapter(address(adapter));

        vm.stopBroadcast();
        console2.log("Deploy complete!");
    }
}
