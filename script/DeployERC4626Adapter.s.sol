// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {ERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title DeployERC4626Adapter
/// @notice Deploys a SIXXVault + AdapterRegistry + ERC4626Adapter wired to a
///         blue-chip Morpho MetaMorpho vault, selecting the target by chainid.
///
/// Initial registered vaults (see SIXX_Morpho_Adapter spec):
///   - Base     (8453) — Morpho · Gauntlet USDC Prime  / USDC
///   - Ethereum (1)    — Morpho · Steakhouse USDT       / USDT
///
/// Usage:
///   forge script script/DeployERC4626Adapter.s.sol \
///     --rpc-url $BASE_RPC_URL --broadcast --verify
///   forge script script/DeployERC4626Adapter.s.sol \
///     --rpc-url $ETH_RPC_URL  --broadcast --verify
///
/// ─────────────────────────────────────────────────────────────────────────
/// PRE-DEPLOY CHECKLIST (governance MUST confirm before broadcasting — these
/// are the blue-chip bar; the contract itself enforces none of them):
///   [ ] vault is ERC-4626 compliant: asset() / convertToAssets() / deposit()
///       / withdraw() / maxWithdraw() all respond.
///   [ ] curator is Gauntlet or Steakhouse (verify MetaMorpho curator()/owner()
///       on-chain — do NOT trust the label alone).
///   [ ] TVL >= $50M and vaults.fyi score >= 8.
///   [ ] vault.asset() == the intended underlying for this chain (the script
///       reads it from the vault and asserts equality below).
///   [ ] instant redemption: vault is NOT a request/claim withdrawal-queue type
///       (maxWithdraw(holder) > 0 immediately after deposit). The adapter's
///       requiredLockPeriod() == 0 assumes this.
///   [ ] final review of audit history / past incidents.
/// ─────────────────────────────────────────────────────────────────────────
contract DeployERC4626Adapter is Script {
    // ─── Chain IDs ───────────────────────────────────────────
    uint256 internal constant ETH_MAINNET = 1;
    uint256 internal constant BASE        = 8453;

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer   = vm.addr(deployerPk);

        console2.log("Chain ID    :", block.chainid);
        console2.log("Deployer    :", deployer);

        if (block.chainid == BASE) {
            // Morpho · Gauntlet USDC Prime (Base)
            _deploy(
                deployerPk,
                deployer,
                "Base",
                0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913, // USDC (Base native)
                0xeE8F4eC5672F09119b96Ab6fB59C27E1b7e44b61, // Gauntlet USDC Prime vault
                "SIXX Stable Yield USDC",
                "sxUSDC",
                "Morpho - Gauntlet USDC Prime (Base)"
            );
        } else if (block.chainid == ETH_MAINNET) {
            // Morpho · Steakhouse USDT (Ethereum)
            _deploy(
                deployerPk,
                deployer,
                "Ethereum",
                0xdAC17F958D2ee523a2206206994597C13D831ec7, // USDT
                0xbEef047a543E45807105E51A8BBEFCc5950fcfBa, // Steakhouse USDT vault
                "SIXX Stable Yield USDT",
                "sxUSDT",
                "Morpho - Steakhouse USDT (ETH)"
            );
        } else {
            revert("DeployERC4626Adapter: unsupported chainid");
        }
    }

    function _deploy(
        uint256 deployerPk,
        address deployer,
        string memory label,
        address underlying,
        address vaultAddr,
        string memory vaultName,
        string memory vaultSymbol,
        string memory providerName
    ) internal {
        console2.log("Network     :", label);
        console2.log("Underlying  :", underlying);
        console2.log("ERC4626     :", vaultAddr);
        console2.log("Provider    :", providerName);

        // Sanity gate (also enforced in the adapter constructor): the vault's
        // underlying MUST match what we intend to deploy. Fails fast on a paste
        // error before any broadcast.
        require(IERC4626(vaultAddr).asset() == underlying, "Deploy: vault/underlying mismatch");

        vm.startBroadcast(deployerPk);

        AdapterRegistry registry = new AdapterRegistry(deployer);
        console2.log("Registry    :", address(registry));

        SIXXVault vault = new SIXXVault(
            IERC20(underlying),
            vaultName,
            vaultSymbol,
            deployer,
            address(registry),
            deployer
        );
        console2.log("SIXXVault   :", address(vault));

        ERC4626Adapter adapter = new ERC4626Adapter(
            underlying,
            vaultAddr,
            address(vault),
            deployer
        );
        console2.log("Adapter     :", address(adapter));

        // Only the bar-cleared adapter is registered; provider string is the
        // vault-specific label (the adapter's own providerName() is generic).
        registry.registerAdapter(address(adapter), "DeFi", providerName);
        vault.setAdapter(address(adapter));

        vm.stopBroadcast();
        console2.log("Deploy complete!");
    }
}
