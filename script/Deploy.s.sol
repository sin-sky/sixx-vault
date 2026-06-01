// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AaveV3USDCAdapter} from "../src/adapters/AaveV3USDCAdapter.sol";
import {VenusUSDTAdapter} from "../src/adapters/VenusUSDTAdapter.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Deploy
/// @notice Deploys SIXXVault + AdapterRegistry + a chain-appropriate adapter,
///         selecting protocol and addresses via block.chainid.
///
/// Supported chains:
///   - Arbitrum One     (42161)    — Aave V3 Arbitrum         / USDC (native)
///   - ETH Sepolia      (11155111) — Aave V3 Sepolia          / USDC
///   - Arbitrum Sepolia (421614)   — Aave V3 Arbitrum Sepolia / USDC
///   - BNB Testnet      (97)       — Venus Protocol BSC Testnet / USDT
///
/// Usage:
///   forge script script/Deploy.s.sol \
///     --rpc-url $ETH_SEPOLIA_RPC_URL --broadcast --verify
///   forge script script/Deploy.s.sol \
///     --rpc-url $ARB_SEPOLIA_RPC_URL --broadcast --verify
///   forge script script/Deploy.s.sol \
///     --rpc-url $BNB_TESTNET_RPC_URL --broadcast --verify
contract Deploy is Script {
    // ─── Chain IDs ───────────────────────────────────────────
    uint256 internal constant ARB_ONE     = 42161;
    uint256 internal constant ETH_SEPOLIA = 11155111;
    uint256 internal constant ARB_SEPOLIA = 421614;
    uint256 internal constant BNB_TESTNET = 97;

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer   = vm.addr(deployerPk);

        console2.log("Chain ID    :", block.chainid);
        console2.log("Deployer    :", deployer);

        if (block.chainid == ARB_ONE) {
            // Source: bgd-labs/aave-address-book → AaveV3Arbitrum (USDCn / native USDC)
            _deployAaveV3USDC(
                deployerPk,
                deployer,
                "Arbitrum One",
                0xaf88d065e77c8cC2239327C5EDb3A432268e5831, // USDC (native)
                0x794a61358D6845594F94dc1DB02A252b5b4814aD, // Aave V3 Pool
                0x724dc807b04555b71ed48a6896b6F41593b8C637  // aArbUSDCn
            );
        } else if (block.chainid == ETH_SEPOLIA) {
            // Source: bgd-labs/aave-address-book → AaveV3Sepolia
            _deployAaveV3USDC(
                deployerPk,
                deployer,
                "ETH Sepolia",
                0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8, // USDC
                0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951, // Aave Pool
                0x16dA4541aD1807f4443d92D26044C1147406EB80  // aUSDC
            );
        } else if (block.chainid == ARB_SEPOLIA) {
            _deployAaveV3USDC(
                deployerPk,
                deployer,
                "Arbitrum Sepolia",
                0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d, // USDC
                0xBfC91D59fdAA134A4ED45f7B584cAf96D7792Eff, // Aave Pool
                0x460b97BD498E1157530AEb3086301d5225b91216  // aUSDC
            );
        } else if (block.chainid == BNB_TESTNET) {
            // Source: VenusProtocol/venus-protocol → deployments/bsctestnet
            _deployVenusUSDT(
                deployerPk,
                deployer,
                "BNB Testnet",
                0xA11c8D9DC9b66E209Ef60F0C8D969D3CD988782c, // USDT
                0xb7526572FFE56AB9D7489838Bf2E18e3323b441A  // vUSDT
            );
        } else {
            revert("Deploy: unsupported chainid");
        }
    }

    // =========================================
    // Aave V3 (USDC vaults)
    // =========================================

    function _deployAaveV3USDC(
        uint256 deployerPk,
        address deployer,
        string memory label,
        address usdc,
        address aavePool,
        address aUsdc
    ) internal {
        console2.log("Network     :", label);
        console2.log("USDC        :", usdc);
        console2.log("Aave Pool   :", aavePool);
        console2.log("aUSDC       :", aUsdc);

        vm.startBroadcast(deployerPk);

        AdapterRegistry registry = new AdapterRegistry(deployer);
        console2.log("Registry    :", address(registry));

        SIXXVault vault = new SIXXVault(
            IERC20(usdc),
            "SIXX Stable Yield",
            "sxUSDC",
            deployer,
            address(registry),
            deployer
        );
        console2.log("SIXXVault   :", address(vault));

        AaveV3USDCAdapter adapter = new AaveV3USDCAdapter(
            usdc, aavePool, aUsdc, address(vault), deployer, 0
        );
        console2.log("Adapter     :", address(adapter));

        registry.registerAdapter(address(adapter), "DeFi", "Aave V3");
        vault.setAdapter(address(adapter));

        vm.stopBroadcast();
        console2.log("Deploy complete!");
    }

    // =========================================
    // Venus Protocol (USDT vaults)
    // =========================================

    function _deployVenusUSDT(
        uint256 deployerPk,
        address deployer,
        string memory label,
        address usdt,
        address vUsdt
    ) internal {
        console2.log("Network     :", label);
        console2.log("USDT        :", usdt);
        console2.log("vUSDT       :", vUsdt);

        vm.startBroadcast(deployerPk);

        AdapterRegistry registry = new AdapterRegistry(deployer);
        console2.log("Registry    :", address(registry));

        SIXXVault vault = new SIXXVault(
            IERC20(usdt),
            "SIXX Stable Yield USDT",
            "sxUSDT",
            deployer,
            address(registry),
            deployer
        );
        console2.log("SIXXVault   :", address(vault));

        VenusUSDTAdapter adapter = new VenusUSDTAdapter(
            usdt, vUsdt, address(vault), deployer
        );
        console2.log("Adapter     :", address(adapter));

        registry.registerAdapter(address(adapter), "DeFi", "Venus Protocol");
        vault.setAdapter(address(adapter));

        vm.stopBroadcast();
        console2.log("Deploy complete!");
    }
}
