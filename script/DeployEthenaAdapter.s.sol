// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {EthenaSUSDeAdapter} from "../src/adapters/EthenaSUSDeAdapter.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title DeployEthenaAdapter
/// @notice Deploys the HIGH-YIELD (satellite, variable) Ethena sUSDe line on
///         Ethereum mainnet: a DEDICATED USDC-denominated SIXXVault + its own
///         AdapterRegistry + Timelock, plus the EthenaSUSDeAdapter. This vault is
///         SEPARATE from the safe USDC term vault — the safe line is never touched
///         (SHIN guardrail 2026-07-10).
///
/// @dev ⚠️ DRY-RUN ONLY in this workflow. Run WITHOUT --broadcast to simulate:
///        forge script script/DeployEthenaAdapter.s.sol \
///          --rpc-url $ETH_RPC_URL -vvvv
///      registerAdapter / setAdapter / broadcast are performed by SHIN via the
///      Timelock (schedule → 48h → execute from the 2-of-3 Safe). This script
///      NEVER wires the adapter into the vault.
///
///      Post-deploy ordering (human, via Timelock):
///        1. registry.registerAdapter(adapter)   [governance = Timelock]
///        2. vault.setAdapter(adapter)            [governance = Timelock]
///        3. (optional) vault.setLockPeriod / adapter.setEstimatedAPY
///        Fund the vault gradually (staged rollout) — per-tx swap sizes should stay
///        well within the ~$0.66M Curve pool depth to hold the 0.5% slippage cap
///        (see PROGRESS.md escalation note).
contract DeployEthenaAdapter is Script {
    uint256 internal constant ETH_MAINNET = 1;
    uint256 internal constant TIMELOCK_MIN_DELAY = 48 hours;

    // ─── Ethereum mainnet addresses (verified on-chain 2026-07-10 @ block 25500331) ───
    address internal constant USDC      = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant SUSDE     = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497; // StakedUSDeV2
    address internal constant CRVUSD    = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address internal constant ENTRYPOOL = 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72; // Curve USDe/USDC
    address internal constant EXITPOOL1 = 0x57064F49Ad7123C92560882a45518374ad982e85; // Curve crvUSD/sUSDe
    address internal constant EXITPOOL2 = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E; // Curve USDC/crvUSD

    /// @dev Ethereum 2-of-3 Safe (guardian + feeRecipient). Mirrors Deploy.s.sol.
    address internal constant ETH_SAFE = 0x4d71aCE4612AB3B71423b454e21c0Bd03c4F8fE0;

    function run() external {
        // L-01 (2nd review): DRY-RUN SIMULATION ONLY in this workflow. The real deploy is
        //   broadcast by SHIN via the Timelock/Safe, not by this script. Hard-revert under
        //   --broadcast / --resume so an executable copy in the handoff bundle can never
        //   deploy live (parity with DeployPendleAdapter.s.sol). To actually ship, run the
        //   dedicated production path with the Timelock+Safe wiring reviewed.
        require(
            !_isBroadcastContext(),
            "DEPLOY: broadcast forbidden (dry-run sim only; port Timelock+Safe wiring first)"
        );
        require(block.chainid == ETH_MAINNET, "DeployEthena: mainnet only");

        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer   = vm.addr(deployerPk);
        // Representative variable APY (bps); SHIN can update via setEstimatedAPY.
        uint256 apyBps = vm.envOr("ETHENA_APY_BPS", uint256(800));

        console2.log("Chain ID    :", block.chainid);
        console2.log("Deployer    :", deployer);
        console2.log("Safe        :", ETH_SAFE);
        console2.log("APY bps     :", apyBps);

        vm.startBroadcast(deployerPk);

        // Governance = Timelock (proposer/executor = Safe), self-administered.
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = ETH_SAFE;
        executors[0] = ETH_SAFE;
        TimelockController timelock =
            new TimelockController(TIMELOCK_MIN_DELAY, proposers, executors, address(0));

        AdapterRegistry registry = new AdapterRegistry(address(timelock));

        // Dedicated high-yield USDC vault (separate from the safe USDC term vault).
        SIXXVault vault = new SIXXVault(
            IERC20(USDC),
            "SIXX High Yield USDC (Ethena sUSDe)",
            "sxheUSDC",
            address(timelock), // governance
            address(registry),
            ETH_SAFE,          // feeRecipient = Safe
            ETH_SAFE           // guardian = Safe
        );

        // Adapter governance = Timelock (never the hot deployer key).
        EthenaSUSDeAdapter adapter = new EthenaSUSDeAdapter(
            USDC, SUSDE, CRVUSD, ENTRYPOOL, EXITPOOL1, EXITPOOL2,
            address(vault), address(timelock), apyBps
        );

        vm.stopBroadcast();

        console2.log("Timelock    :", address(timelock));
        console2.log("Registry    :", address(registry));
        console2.log("SIXXVault   :", address(vault));
        console2.log("Adapter     :", address(adapter));
        console2.log("riskLevel   :", adapter.riskLevel());
        console2.log("asset==USDC :", adapter.asset() == USDC);
        console2.log("");
        console2.log("PENDING (human via Timelock, NOT broadcast here):");
        console2.log("  1. registry.registerAdapter(adapter)");
        console2.log("  2. vault.setAdapter(adapter)");
        console2.log("Dry-run complete (no --broadcast).");
    }

    /// @dev L-01 (2nd review): true iff the script is executing under `forge script
    ///      --broadcast` or `--resume`. `virtual` so a test can drive the broadcast branch
    ///      (forge test cannot enter a real ScriptBroadcast/ScriptResume context); the
    ///      production body reads the actual forge execution context.
    function _isBroadcastContext() internal view virtual returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
            || vm.isContext(VmSafe.ForgeContext.ScriptResume);
    }
}
