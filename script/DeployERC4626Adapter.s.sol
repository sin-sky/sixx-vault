// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {ERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title DeployERC4626Adapter
/// @notice ETH-mainnet "rails only" (Plan A): deploy an ERC4626Adapter wired to
///         the existing ETH USDC SIXXVault and whitelist it in the registry —
///         WITHOUT switching the active strategy. Aave V3 stays active.
///
/// This does NOT deploy a new vault or registry — it connects to the live ones
/// from the prior Ethereum deployment (broadcast/Deploy.s.sol/1/run-latest.json)
/// and performs only TWO steps:
///   1. deploy ERC4626Adapter(existing vault as sixxVault, Gauntlet Prime as vault)
///   2. registerAdapter() on the existing registry
///
/// The third step — setAdapter() (recall 100% from Aave, redeploy to Morpho) — is
/// intentionally NOT called here. Run it later, once the blue-chip bar is met
/// (notably TVL >= $50M), via script/ActivateERC4626Adapter.s.sol.
///
/// Usage (broadcaster MUST be the governance EOA):
///   forge script script/DeployERC4626Adapter.s.sol \
///     --rpc-url $ETH_RPC_URL --broadcast --verify
///
/// ─────────────────────────────────────────────────────────────────────────
/// PRE-DEPLOY CHECKLIST (governance MUST confirm before broadcasting — the
/// contract enforces only the asset() match; the rest is the blue-chip bar):
///   [ ] Gauntlet USDC Prime is ERC-4626 compliant (asset/convertToAssets/
///       deposit/withdraw/maxWithdraw all respond).
///   [ ] curator() / owner() == Gauntlet, verified ON-CHAIN.
///   [ ] instant redemption (not a request/claim withdrawal queue).
///   [ ] TVL >= $50M and vaults.fyi score >= 8.
///   [ ] vault.asset() == ETH USDC (also asserted below).
///   [ ] audit / incident history reviewed.
///   [ ] supply cap headroom >= the vault's current totalAssets (else the
///       redeploy partially fails and funds sit idle — see fork sim).
/// ─────────────────────────────────────────────────────────────────────────
contract DeployERC4626Adapter is Script {
    uint256 internal constant ETH_MAINNET = 1;

    // ─── Existing ETH mainnet deployment (chain 1 broadcast) ─────────────────
    address internal constant ETH_USDC       = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // native USDC
    address internal constant ETH_REGISTRY   = 0x0b487365d5E7FD5d324D7221340413a096492542; // AdapterRegistry
    address internal constant ETH_SIXX_VAULT = 0x5292A8DCd18C6512137e8cA6C21dB0dc6b830b31; // SIXXVault (USDC)
    address internal constant ETH_GOVERNANCE = 0x58cda24e2530d34FCa304e79c37f97c347Edb150; // governance EOA

    // ─── Migration target: Morpho · Gauntlet USDC Prime (Ethereum) ───────────
    address internal constant GAUNTLET_USDC_PRIME = 0xdd0f28e19C1780eb6396170735D45153D261490d;

    string internal constant PROVIDER = "Morpho - Gauntlet USDC Prime (ETH)";

    function run() external {
        require(block.chainid == ETH_MAINNET, "Deploy: ETH mainnet only");

        uint256 pk     = vm.envUint("PRIVATE_KEY");
        address sender = vm.addr(pk);
        // register/setAdapter are governance-gated — the broadcaster must be it.
        require(sender == ETH_GOVERNANCE, "Deploy: broadcaster must be governance");
        // Mistaken-vault guard (also enforced in the adapter constructor).
        require(IERC4626(GAUNTLET_USDC_PRIME).asset() == ETH_USDC, "Deploy: vault/underlying mismatch");

        console2.log("Network     : Ethereum");
        console2.log("SIXXVault   :", ETH_SIXX_VAULT);
        console2.log("Registry    :", ETH_REGISTRY);
        console2.log("Active (keep):", SIXXVault(ETH_SIXX_VAULT).activeAdapter());
        console2.log("Target vault:", GAUNTLET_USDC_PRIME);

        vm.startBroadcast(pk);

        // 1. Deploy the adapter bound to the EXISTING vault.
        ERC4626Adapter adapter = new ERC4626Adapter(
            ETH_USDC,
            GAUNTLET_USDC_PRIME,
            ETH_SIXX_VAULT,
            ETH_GOVERNANCE
        );
        console2.log("New adapter :", address(adapter));

        // 2. Whitelist it in the existing registry. (Does NOT change active adapter.)
        AdapterRegistry(ETH_REGISTRY).registerAdapter(address(adapter), "DeFi", PROVIDER);

        // 3. setAdapter() is intentionally NOT called — Aave stays active (Plan A).
        //    Activate later via script/ActivateERC4626Adapter.s.sol once the bar is met.

        vm.stopBroadcast();

        console2.log("Active (still):", SIXXVault(ETH_SIXX_VAULT).activeAdapter());
        console2.log("Rails deployed + registered. Aave remains active.");
    }
}
