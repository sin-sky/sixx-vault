// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AaveV3USDCAdapter} from "../src/adapters/AaveV3USDCAdapter.sol";
import {VenusUSDTAdapter} from "../src/adapters/VenusUSDTAdapter.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title Deploy
/// @notice Deploys SIXXVault + AdapterRegistry + a chain-appropriate adapter,
///         selecting protocol and addresses via block.chainid.
///
/// Supported chains:
///   - Ethereum         (1)        — Aave V3 Ethereum         / USDC (native)
///   - Arbitrum One     (42161)    — Aave V3 Arbitrum         / USDC (native)
///   - BNB Chain        (56)       — Venus Protocol BSC        / USDT
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
    uint256 internal constant ETH_MAINNET = 1;
    uint256 internal constant ARB_ONE     = 42161;
    uint256 internal constant BNB_MAINNET = 56;
    uint256 internal constant ETH_SEPOLIA = 11155111;
    uint256 internal constant ARB_SEPOLIA = 421614;
    uint256 internal constant BNB_TESTNET = 97;

    uint256 internal constant TIMELOCK_MIN_DELAY = 48 hours;

    /// @dev Chain 2-of-3 Safe = Timelock proposer/executor + Vault guardian.
    ///      Testnets have no Safe → fall back to the deployer.
    function _safe(address deployer) internal view returns (address) {
        if (block.chainid == ETH_MAINNET) return 0x4d71aCE4612AB3B71423b454e21c0Bd03c4F8fE0;
        if (block.chainid == ARB_ONE)     return 0xd388aC46E7a763d5eaFb73b735292c6A46B5BAC0;
        if (block.chainid == BNB_MAINNET) return 0x81E85C9F3FdE1ceE38cD3DA9bbAa6212F01D196D;
        return deployer; // testnets
    }

    /// @dev Deploy a TimelockController with the Safe as sole proposer+executor,
    ///      self-administered (admin = address(0)).
    function _deployTimelock(address safe) internal returns (TimelockController) {
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = safe;
        executors[0] = safe;
        return new TimelockController(TIMELOCK_MIN_DELAY, proposers, executors, address(0));
    }

    /// @dev Core wiring shared by every chain-specific deploy path: Timelock
    ///      (governance for both registry + vault) and the Safe as guardian.
    function _deployCore(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address safe_,
        address feeRecipient_
    ) internal returns (TimelockController timelock, AdapterRegistry registry, SIXXVault vault) {
        timelock = _deployTimelock(safe_);
        registry = new AdapterRegistry(address(timelock));
        vault = new SIXXVault(
            asset_,
            name_,
            symbol_,
            address(timelock),
            address(registry),
            feeRecipient_, // feeRecipient
            safe_          // guardian
        );
    }

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer   = vm.addr(deployerPk);

        console2.log("Chain ID    :", block.chainid);
        console2.log("Deployer    :", deployer);

        if (block.chainid == ETH_MAINNET) {
            // Source: bgd-labs/aave-address-book → AaveV3Ethereum (native USDC)
            _deployAaveV3USDC(
                deployerPk,
                deployer,
                "Ethereum",
                0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, // USDC (native)
                0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2, // Aave V3 Pool
                0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c  // aEthUSDC
            );
        } else if (block.chainid == ARB_ONE) {
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
        } else if (block.chainid == BNB_MAINNET) {
            // Source: VenusProtocol/venus-protocol → deployments/bscmainnet (Core Pool)
            // Verified on-chain: vUSDT.underlying() == USDT, vUSDT.symbol() == "vUSDT"
            _deployVenusUSDT(
                deployerPk,
                deployer,
                "BNB Chain",
                0x55d398326f99059fF775485246999027B3197955, // USDT (BSC-USD, 18 decimals)
                0xfD5840Cd36d94D7229439859C0112a4185BC0255  // vUSDT
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

        address safe = _safe(deployer);
        (TimelockController timelock, AdapterRegistry registry, SIXXVault vault) =
            _deployCore(IERC20(usdc), "SIXX Stable Yield", "sxUSDC", safe, deployer);
        console2.log("Timelock    :", address(timelock));
        console2.log("Registry    :", address(registry));
        console2.log("SIXXVault   :", address(vault));

        AaveV3USDCAdapter adapter = new AaveV3USDCAdapter(
            usdc, aavePool, aUsdc, address(vault), deployer, 0
        );
        console2.log("Adapter     :", address(adapter));

        // NOTE: registry.registerAdapter / vault.setAdapter are now governance-gated
        // (governance = Timelock). Do the initial adapter wiring via the Timelock
        // (schedule -> 48h -> execute) from the Safe. See SAFE_MIGRATION_RUNBOOK.
        console2.log("Adapter (register+setAdapter) pending via Timelock:", address(adapter));

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

        address safe = _safe(deployer);
        (TimelockController timelock, AdapterRegistry registry, SIXXVault vault) =
            _deployCore(IERC20(usdt), "SIXX Stable Yield USDT", "sxUSDT", safe, deployer);
        console2.log("Timelock    :", address(timelock));
        console2.log("Registry    :", address(registry));
        console2.log("SIXXVault   :", address(vault));

        VenusUSDTAdapter adapter = new VenusUSDTAdapter(
            usdt, vUsdt, address(vault), deployer
        );
        console2.log("Adapter     :", address(adapter));

        // NOTE: registry.registerAdapter / vault.setAdapter are now governance-gated
        // (governance = Timelock). Do the initial adapter wiring via the Timelock
        // (schedule -> 48h -> execute) from the Safe. See SAFE_MIGRATION_RUNBOOK.
        console2.log("Adapter (register+setAdapter) pending via Timelock:", address(adapter));

        vm.stopBroadcast();
        console2.log("Deploy complete!");
    }
}
