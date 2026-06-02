// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {ERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title RedeployERC4626Adapter
/// @notice ETH-mainnet clean re-deploy (Plan A, v2): ship the audit-hardened
///         ERC4626Adapter (L-1 `rescue`, M-G1 `isFullyExited`) wired to the
///         existing ETH USDC SIXXVault, whitelist it, and DISABLE the prior
///         rails adapter — WITHOUT switching the active strategy. Aave stays
///         active.
///
/// Performs exactly THREE governance actions:
///   1. deploy new ERC4626Adapter(existing vault, Gauntlet Prime)  [same params]
///   2. registerAdapter(new, "DeFi", "...v2") on the existing registry
///   3. setAdapterStatus(OLD, false) to retire the prior rails adapter
///
/// It DOES NOT call setAdapter() — activeAdapter remains Aave V3. Activation is a
/// separate, gated step (script/ActivateERC4626Adapter.s.sol) run only once the
/// blue-chip bar is met. See the 2026-06-02 audit: condition (1) re-run the ETH
/// migration fork test green, (2) verify Morpho cap headroom >= vault.totalAssets()
/// immediately before activating, (3) confirm Etherscan-verified source == this commit.
///
/// Usage (broadcaster MUST be the governance EOA; top up to ~0.02 ETH first):
///   forge script script/RedeployERC4626Adapter.s.sol \
///     --rpc-url $ETH_RPC_URL --broadcast --verify
contract RedeployERC4626Adapter is Script {
    uint256 internal constant ETH_MAINNET = 1;

    // ─── Existing ETH mainnet deployment (chain 1) ───────────────────────────
    address internal constant ETH_USDC       = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // native USDC
    address internal constant ETH_REGISTRY   = 0x0b487365d5E7FD5d324D7221340413a096492542; // AdapterRegistry
    address internal constant ETH_SIXX_VAULT = 0x5292A8DCd18C6512137e8cA6C21dB0dc6b830b31; // SIXXVault (USDC)
    address internal constant ETH_GOVERNANCE = 0x58cda24e2530d34FCa304e79c37f97c347Edb150; // governance EOA

    // ─── Migration target: Morpho · Gauntlet USDC Prime (Ethereum) ───────────
    address internal constant GAUNTLET_USDC_PRIME = 0xdd0f28e19C1780eb6396170735D45153D261490d;

    // ─── Prior rails adapter to retire (audit v1, registered + unactivated) ──
    address internal constant OLD_ADAPTER = 0x4f6D6C9E815D37870307E524FCe4dcc822cd9ad2;

    string internal constant PROVIDER = "Morpho - Gauntlet USDC Prime (ETH) v2";

    function run() external {
        require(block.chainid == ETH_MAINNET, "Redeploy: ETH mainnet only");

        uint256 pk     = vm.envUint("PRIVATE_KEY");
        address sender = vm.addr(pk);
        require(sender == ETH_GOVERNANCE, "Redeploy: broadcaster must be governance");

        // Mistaken-vault guard (also enforced in the adapter constructor).
        require(IERC4626(GAUNTLET_USDC_PRIME).asset() == ETH_USDC, "Redeploy: vault/underlying mismatch");

        SIXXVault sixx = SIXXVault(ETH_SIXX_VAULT);
        AdapterRegistry registry = AdapterRegistry(ETH_REGISTRY);

        address activeBefore = sixx.activeAdapter();
        console2.log("Network        : Ethereum");
        console2.log("SIXXVault      :", ETH_SIXX_VAULT);
        console2.log("Registry       :", ETH_REGISTRY);
        console2.log("Active (keep)  :", activeBefore);
        console2.log("Old adapter    :", OLD_ADAPTER);
        console2.log("Old is active? :", registry.isActive(OLD_ADAPTER));

        // Never retire an adapter that is currently the live strategy.
        require(activeBefore != OLD_ADAPTER, "Redeploy: old adapter is ACTIVE strategy - abort");

        vm.startBroadcast(pk);

        // 1. Deploy the hardened adapter bound to the EXISTING vault (same params).
        ERC4626Adapter adapter = new ERC4626Adapter(
            ETH_USDC,
            GAUNTLET_USDC_PRIME,
            ETH_SIXX_VAULT,
            ETH_GOVERNANCE
        );
        console2.log("New adapter    :", address(adapter));

        // 2. Whitelist the new adapter. (Does NOT change the active adapter.)
        registry.registerAdapter(address(adapter), "DeFi", PROVIDER);

        // 3. Retire the prior rails adapter so it can never be activated by mistake.
        if (registry.isActive(OLD_ADAPTER)) {
            registry.setAdapterStatus(OLD_ADAPTER, false);
        }

        vm.stopBroadcast();

        console2.log("Active (still) :", sixx.activeAdapter());
        console2.log("Old is active? :", registry.isActive(OLD_ADAPTER));
        console2.log("New is active? :", registry.isActive(address(adapter)));
        console2.log("Rails v2 deployed + registered; old retired. Aave remains active.");
        console2.log("NEXT: meet blue-chip bar, then run ActivateERC4626Adapter with ADAPTER=", address(adapter));
    }
}
