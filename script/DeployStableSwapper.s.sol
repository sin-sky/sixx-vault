// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {CurveStableSwapper} from "../src/periphery/CurveStableSwapper.sol";
import {IStableSwapper} from "../src/interfaces/IStableSwapper.sol";
import {ICurveStableSwapNG} from "../src/interfaces/ICurveStableSwapNG.sol";

/// @title DeployStableSwapper (DRY-RUN SIMULATION ONLY)
/// @notice Deploys the production `CurveStableSwapper` (USDC / USDe / sUSDe legs)
///         used by PendlePTAdapter and any future Ethena-family adapter via
///         `setSwapper`. The swapper is ownerless and immutable — deploying it
///         wires nothing and moves no funds.
///
/// @dev 🛑 NEVER run with `--broadcast`. Broadcast/deploy and any adapter
///      re-pointing (`setSwapper`) are human (SHIN) actions
///      (`.claude/settings.json` deny). Simulate on a mainnet fork only:
///        forge script script/DeployStableSwapper.s.sol \
///          --fork-url $ETH_RPC_URL -vvvv
///
///      After a real deploy, SHIN points a consumer adapter at it via governance:
///        PendlePTAdapter.setSwapper(<deployed CurveStableSwapper>)   [governance]
///      NOTE: Part A (EthenaSUSDeAdapter, already deployed) hardcodes the SAME
///      Curve routing as immutable state and does NOT take a swapper — this
///      contract is NOT applied to Part A. It is for Part B (Pendle) and future
///      swapper-injecting adapters only.
contract DeployStableSwapper is Script {
    uint256 internal constant ETH_MAINNET = 1;

    // Ethereum mainnet, verified on-chain 2026-07-10 (mirrors DeployEthenaAdapter).
    address internal constant USDC      = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDE      = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address internal constant SUSDE     = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address internal constant CRVUSD    = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address internal constant ENTRYPOOL = 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72; // USDC/USDe
    address internal constant EXITPOOL1 = 0x57064F49Ad7123C92560882a45518374ad982e85; // sUSDe/crvUSD
    address internal constant EXITPOOL2 = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E; // USDC/crvUSD

    function run() external {
        console2.log("=== DeployStableSwapper (SIMULATION) ===");
        console2.log("Chain ID:", block.chainid);

        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk != 0) {
            vm.startBroadcast(pk);
        } else {
            // Sim without a key: prank a deployer so constructor code runs.
            vm.startPrank(address(0xB0B));
        }

        CurveStableSwapper swapper =
            new CurveStableSwapper(USDC, USDE, SUSDE, CRVUSD, ENTRYPOOL, EXITPOOL1, EXITPOOL2);

        if (pk != 0) {
            vm.stopBroadcast();
        } else {
            vm.stopPrank();
        }

        console2.log("CurveStableSwapper:", address(swapper));
        console2.log("entryPool:", address(swapper.entryPool()));
        console2.log("exitPool1:", address(swapper.exitPool1()));
        console2.log("exitPool2:", address(swapper.exitPool2()));

        // Sanity: derived indices resolve on a mainnet fork (only meaningful when
        // forked against live Curve state).
        console2.log("entryUsdcIndex:", vm.toString(int256(swapper.entryUsdcIndex())));
        console2.log("entryUsdeIndex:", vm.toString(int256(swapper.entryUsdeIndex())));
        console2.log("exit1SusdeIndex:", vm.toString(int256(swapper.exit1SusdeIndex())));
        console2.log("exit1CrvusdIndex:", vm.toString(int256(swapper.exit1CrvusdIndex())));
        console2.log("exit2UsdcIndex:", vm.toString(int256(swapper.exit2UsdcIndex())));
        console2.log("exit2CrvusdIndex:", vm.toString(int256(swapper.exit2CrvusdIndex())));

        console2.log("NOTE: NOT applied to Part A (EthenaSUSDeAdapter hardcodes routing).");
        console2.log("NOTE: broadcast/setSwapper are SHIN-only. No wiring performed.");
    }
}
