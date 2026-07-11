// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {PendlePTAdapter} from "../src/adapters/PendlePTAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title DeployPendleAdapter (DRY-RUN SIMULATION ONLY)
/// @notice Deploys the dedicated USDC "fixed-yield" vault + PendlePTAdapter and
///         registers the adapter. This is Part B's own new vault (1 vault = 1
///         adapter) — it does NOT touch the safe USDC vault or the Part A vault.
///
/// @dev 🛑 NEVER run with `--broadcast`. Broadcast/deploy/register/setAdapter and
///      any fund movement are human (SHIN) actions (`.claude/settings.json` deny).
///      Simulate on a mainnet fork only:
///        forge script script/DeployPendleAdapter.s.sol \
///          --fork-url $ETH_RPC_URL -vvvv
///
///      Env (all optional for the sim; required for a real deploy):
///        PENDLE_GOVERNANCE      governance EOA/Safe (default: msg.sender)
///        PENDLE_STABLE_SWAPPER  production IStableSwapper (see escalation #2).
///                               A placeholder is used if unset so the sim can run;
///                               it MUST be the real, audited swapper before broadcast.
contract DeployPendleAdapter is Script {
    // Mainnet, verified on-chain (T-B1). PT-sUSDe, expiry 2026-08-13.
    address constant USDC     = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant MARKET   = 0x177768caf9D0e036725A51D3f60d7E20F2D4D194;
    address constant ROUTER   = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address constant PTORACLE = 0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2;
    uint32  constant TWAP     = 900;

    function run() external {
        // L-01: DRY-RUN SIMULATION ONLY. Unlike the production Deploy.s.sol /
        //   DeployEthenaAdapter.s.sol, this script does NOT instantiate a TimelockController
        //   and wires governance/feeRecipient/guardian to a bare EOA (msg.sender/env). It must
        //   therefore never broadcast. Hard-revert under --broadcast / --resume so an executable
        //   copy in the handoff bundle can't deploy live governance to a non-Timelock address.
        //   To actually ship this vault, port the Timelock + Safe wiring from the core scripts.
        require(
            !vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) &&
            !vm.isContext(VmSafe.ForgeContext.ScriptResume),
            "DEPLOY: broadcast forbidden (dry-run sim only; port Timelock+Safe wiring first)"
        );

        address governance = vm.envOr("PENDLE_GOVERNANCE", msg.sender);
        address swapper    = vm.envOr("PENDLE_STABLE_SWAPPER", address(0xDEAD)); // placeholder for sim
        address feeRcpt    = governance;
        address guardian   = governance;

        console2.log("=== DeployPendleAdapter (SIMULATION) ===");
        console2.log("governance:", governance);
        console2.log("stableSwapper:", swapper);
        require(swapper != address(0), "set PENDLE_STABLE_SWAPPER");

        // 1) Registry (governance whitelist for adapters).
        AdapterRegistry registry = new AdapterRegistry(governance);

        // 2) Dedicated USDC fixed-yield vault (separate from safe/variable vaults).
        SIXXVault vault = new SIXXVault(
            IERC20(USDC),
            "SIXX Fixed Yield - PT-sUSDe",
            "sxFIX-PTsUSDe",
            governance,
            address(registry),
            feeRcpt,
            guardian
        );

        // 3) PendlePTAdapter bound to that vault.
        PendlePTAdapter adapter = new PendlePTAdapter(
            USDC, MARKET, ROUTER, PTORACLE, swapper, TWAP, address(vault), governance
        );

        console2.log("AdapterRegistry:", address(registry));
        console2.log("SIXXVault (USDC fixed):", address(vault));
        console2.log("PendlePTAdapter:", address(adapter));
        console2.log("PT expiry (unix):", adapter.expiry());
        console2.log("estimatedAPY (bps):", adapter.estimatedAPY());

        // Wiring assertions (pure sim; nothing broadcast).
        require(vault.asset() == USDC, "vault asset != USDC");
        require(adapter.market() == MARKET, "adapter market mismatch");
        require(adapter.asset() == USDC, "adapter asset != USDC");
        require(address(adapter.vault()) == address(vault), "adapter/vault link");

        // --- Human (SHIN) broadcast order, AFTER this sim is reviewed: -------
        //   (broadcast is DENIED to agents — SHIN executes these manually)
        //   a. registry.registerAdapter(address(adapter), "DeFi", "Pendle PT-sUSDe (fixed)")
        //   b. (fund staging) set vault.maxDeposit cap small; deposit test size
        //   c. vault.setAdapter(address(adapter))
        //      ^ ALSO gated by the global rule: setAdapter only once TVL >= $50M
        //        AND spread >= +0.8% (see sixx-protocol-engineer.md), and by
        //        PROGRESS_partB escalation #1 (vault recall guard vs AMM exit).
        console2.log("NOTE: registerAdapter / setAdapter are human (SHIN) broadcast steps.");
    }
}
