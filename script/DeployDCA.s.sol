// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {DCAScheduler} from "../src/periphery/DCAScheduler.sol";

/// @title DeployDCA
/// @notice Deploys the non-custodial DCA (積立 / つみたて) scheduler on the target chain
///         (ETH → ARB → BNB rollout order). The scheduler is periphery: it holds NO user
///         funds between transactions, mints vault shares directly to each plan owner, and
///         cannot redirect funds (see DCAScheduler §non-custodial guarantees).
///
/// @dev ⚠️ DRY-RUN ONLY in this workflow. Run WITHOUT --broadcast to simulate:
///        forge script script/DeployDCA.s.sol --rpc-url $ETH_RPC_URL -vvvv
///      keeper registration / any activation is performed by SHIN post-deploy.
///      This script NEVER registers a keeper, sets a fee, or moves funds.
///
///      Post-deploy ordering (human):
///        1. scheduler.setKeeper(cronEOA, true)     [governance] — enable the cron trigger
///        2. (optional) scheduler.setPlatformFee(x) [governance] — value = SHIN decision (default 0)
///        Users then approve() a bounded USDC allowance and createPlan() themselves.
contract DeployDCA is Script {
    /// @dev Ethereum 2-of-3 Safe. Mirrors the other deploy scripts. Override via env
    ///      for ARB/BNB or a Timelock-governed setup.
    address internal constant DEFAULT_GOV_SAFE = 0x4d71aCE4612AB3B71423b454e21c0Bd03c4F8fE0;

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer   = vm.addr(deployerPk);

        // governance / guardian / feeRecipient default to the Safe; override per chain.
        address governance   = vm.envOr("DCA_GOVERNANCE",   DEFAULT_GOV_SAFE);
        address guardian     = vm.envOr("DCA_GUARDIAN",     DEFAULT_GOV_SAFE);
        address feeRecipient = vm.envOr("DCA_FEE_RECIPIENT", DEFAULT_GOV_SAFE);

        console2.log("Chain ID    :", block.chainid);
        console2.log("Deployer    :", deployer);
        console2.log("Governance  :", governance);
        console2.log("Guardian    :", guardian);
        console2.log("FeeRecipient:", feeRecipient);

        vm.startBroadcast(deployerPk);
        DCAScheduler scheduler = new DCAScheduler(governance, guardian, feeRecipient);
        vm.stopBroadcast();

        console2.log("DCAScheduler:", address(scheduler));
        console2.log("platformFee :", scheduler.platformFeeBps()); // expect 0
        console2.log("MAX fee bps :", scheduler.MAX_PLATFORM_FEE_BPS());
        console2.log("MIN interval:", scheduler.MIN_INTERVAL());
        console2.log("");
        console2.log("PENDING (human, NOT broadcast here):");
        console2.log("  1. scheduler.setKeeper(cronEOA, true)   [governance]");
        console2.log("  2. (optional) scheduler.setPlatformFee(x) [governance, default 0]");
        console2.log("Dry-run complete (no --broadcast).");
    }
}
