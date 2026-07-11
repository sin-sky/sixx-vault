// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployEthenaAdapter} from "../script/DeployEthenaAdapter.s.sol";

/// @title DeployBroadcastGuardTest
/// @notice L-01 (2nd independent review): the DeployEthenaAdapter script is DRY-RUN ONLY
///         in this workflow (SHIN broadcasts the real deploy via the Timelock/Safe). Like
///         DeployPendleAdapter, it must HARD-REVERT if executed with --broadcast / --resume
///         so an executable copy in the handoff bundle can never deploy live.
///
/// @dev `forge test` cannot enter a real ScriptBroadcast/ScriptResume context, so the script
///      exposes `_isBroadcastContext()` as an internal `virtual` seam. The production body
///      reads `vm.isContext(...)`; this harness overrides the seam with a settable flag to
///      drive the broadcast branch. The GUARD under test — the `require(...)` in `run()` —
///      is the real production code; only the context detection is substituted.
contract EthenaBroadcastHarness is DeployEthenaAdapter {
    bool public broadcastCtx;

    function setBroadcastCtx(bool v) external {
        broadcastCtx = v;
    }

    function _isBroadcastContext() internal view override returns (bool) {
        return broadcastCtx;
    }
}

contract DeployBroadcastGuardTest is Test {
    string constant BROADCAST_FORBIDDEN =
        "DEPLOY: broadcast forbidden (dry-run sim only; port Timelock+Safe wiring first)";

    /// RED-if-unfixed: with a broadcast/resume context, run() must hard-revert BEFORE any
    /// deployment. If the guard is removed, run() falls through to the mainnet-chainid check
    /// and reverts with a DIFFERENT string, failing this expectation.
    function test_L01_deployEthena_hardReverts_underBroadcast() public {
        EthenaBroadcastHarness h = new EthenaBroadcastHarness();
        h.setBroadcastCtx(true);
        vm.expectRevert(bytes(BROADCAST_FORBIDDEN));
        h.run();
    }

    /// Positive control: OUTSIDE a broadcast context the guard passes, so control reaches the
    /// next check (mainnet-only). Proves the guard does not spuriously block a dry-run sim.
    function test_L01_deployEthena_passesGuard_inSimContext() public {
        EthenaBroadcastHarness h = new EthenaBroadcastHarness();
        h.setBroadcastCtx(false);
        // Test chain is not mainnet → the guard passed and the mainnet check now fires.
        vm.expectRevert(bytes("DeployEthena: mainnet only"));
        h.run();
    }
}
