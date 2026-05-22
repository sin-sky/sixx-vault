// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AaveV3USDCAdapter} from "../src/adapters/AaveV3USDCAdapter.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Deploy is Script {
    address constant USDC      = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;
    address constant AAVE_POOL = 0xBfC91D59fdAA134A4ED45f7B584cAf96D7792Eff;
    address constant A_USDC    = 0x460b97BD498E1157530AEb3086301d5225b91216;

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer   = vm.addr(deployerPk);

        console2.log("Deployer    :", deployer);
        console2.log("Chain ID    :", block.chainid);

        vm.startBroadcast(deployerPk);

        AdapterRegistry registry = new AdapterRegistry(deployer);
        console2.log("Registry    :", address(registry));

        SIXXVault vault = new SIXXVault(
            IERC20(USDC),
            "SIXX Stable Yield",
            "sxUSDC",
            deployer,
            address(registry),
            deployer
        );
        console2.log("SIXXVault   :", address(vault));

        AaveV3USDCAdapter adapter = new AaveV3USDCAdapter(
            USDC, AAVE_POOL, A_USDC, address(vault), deployer, 0
        );
        console2.log("Adapter     :", address(adapter));

        registry.registerAdapter(address(adapter), "DeFi", "Aave V3");
        vault.setAdapter(address(adapter));

        vm.stopBroadcast();
        console2.log("Deploy complete!");
    }
}
