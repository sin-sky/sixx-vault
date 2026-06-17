// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";

/// @title ActivateERC4626Adapter
/// @notice STEP 3 (deferred from DeployERC4626Adapter): switch the live ETH USDC
///         SIXXVault's active strategy to the already-deployed, already-registered
///         ERC4626Adapter. This recalls 100% from Aave and redeploys to Morpho.
///
/// ⚠️ DO NOT RUN until the blue-chip bar is met — notably Gauntlet USDC Prime
///    TVL >= $50M (was ~$38.1M at rails-deploy time) and a final curator check.
///    Re-verify supply-cap headroom >= vault.totalAssets() so nothing is stranded.
///
/// Usage (broadcaster MUST be the governance EOA):
///   ADAPTER=0x<deployed adapter> \
///   forge script script/ActivateERC4626Adapter.s.sol \
///     --rpc-url $ETH_RPC_URL --broadcast
contract ActivateERC4626Adapter is Script {
    uint256 internal constant ETH_MAINNET = 1;

    address internal constant ETH_REGISTRY   = 0x0b487365d5E7FD5d324D7221340413a096492542;
    address internal constant ETH_SIXX_VAULT = 0x5292A8DCd18C6512137e8cA6C21dB0dc6b830b31;
    address internal constant ETH_GOVERNANCE = 0x58cda24e2530d34FCa304e79c37f97c347Edb150;

    function run() external {
        require(block.chainid == ETH_MAINNET, "Activate: ETH mainnet only");

        uint256 pk      = vm.envUint("PRIVATE_KEY");
        address sender  = vm.addr(pk);
        require(sender == ETH_GOVERNANCE, "Activate: broadcaster must be governance");

        address adapter = vm.envAddress("ADAPTER");
        require(adapter != address(0), "Activate: ADAPTER env not set");
        require(
            AdapterRegistry(ETH_REGISTRY).isActive(adapter),
            "Activate: adapter not registered/active"
        );

        console2.log("Adapter to activate:", adapter);
        console2.log("Active (before)    :", SIXXVault(ETH_SIXX_VAULT).activeAdapter());

        vm.startBroadcast(pk);
        SIXXVault(ETH_SIXX_VAULT).setAdapter(adapter); // recall-all from Aave -> redeploy to Morpho
        vm.stopBroadcast();

        console2.log("Active (after)     :", SIXXVault(ETH_SIXX_VAULT).activeAdapter());
        console2.log("Migration complete.");
    }
}
