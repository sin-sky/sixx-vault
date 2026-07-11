// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SIXXVault} from "../../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../../src/core/AdapterRegistry.sol";
import {FaultyAdapter} from "../mocks/FaultyAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMintableERC20 is IERC20 {
    function mint(address to, uint256 amount) external;
}

/// @title ResilienceHandler
/// @notice P-03 (2nd review): drives the vault through fuzzed FAILURE-MODE sequences the
///         happy-path invariant handler never reaches — a post-deploy bug that makes the
///         adapter under-deliver (realizable < mark) or makes its valuation read revert,
///         governance force-detach (pause to idle), and reattach of a fresh adapter.
/// @dev The broken-oracle case sets `revertOnTotalAssets` ONLY inside `breakOracleThenForceDetach`,
///      which detaches in the same action — so `activeAdapter` is address(0) before the next
///      invariant evaluation and `vault.totalAssets()` never reverts during an assertion.
contract ResilienceHandler is Test {
    SIXXVault       public immutable vault;
    IMintableERC20  public immutable usdc;
    AdapterRegistry public immutable registry;
    address         public immutable governance;

    FaultyAdapter public adapter; // current adapter (reattach swaps this)

    address[] public actors;
    address internal currentActor;

    /// @dev Ghost: a deposit that MINTED shares while `depositsPaused` was true — must stay 0.
    ///      With H-01/M-03, maxDeposit()==0 while paused so such a deposit always reverts.
    uint256 public ghost_mintWhilePaused;

    // Call counters (surfaced in the invariant summary).
    uint256 public callsDeposit;
    uint256 public callsWithdraw;
    uint256 public callsSetLossy;
    uint256 public callsForceDetach;
    uint256 public callsBreakOracle;
    uint256 public callsReattach;

    uint256 internal constant MAX_ACTION = 1_000_000 * 1e6;

    constructor(
        SIXXVault vault_,
        IMintableERC20 usdc_,
        AdapterRegistry registry_,
        FaultyAdapter adapter_,
        address[] memory actors_,
        address governance_
    ) {
        vault = vault_;
        usdc = usdc_;
        registry = registry_;
        adapter = adapter_;
        actors = actors_;
        governance = governance_;
    }

    modifier useActor(uint256 actorSeed) {
        currentActor = actors[bound(actorSeed, 0, actors.length - 1)];
        _;
    }

    // ─── Action: user deposits for themselves (H-3: caller == receiver) ───
    function deposit(uint256 actorSeed, uint256 amount) external useActor(actorSeed) {
        amount = bound(amount, 0, MAX_ACTION);
        if (amount == 0) return;
        usdc.mint(currentActor, amount);

        bool wasPaused = vault.depositsPaused();
        uint256 supplyBefore = vault.totalSupply();

        vm.startPrank(currentActor);
        usdc.approve(address(vault), amount);
        try vault.deposit(amount, currentActor) {
            // A mint while paused is the exact dilution H-01/M-03 forbid.
            if (wasPaused && vault.totalSupply() > supplyBefore) ghost_mintWhilePaused++;
            callsDeposit++;
        } catch {}
        vm.stopPrank();
    }

    // ─── Action: user redeems a fraction of their shares ───
    function withdraw(uint256 actorSeed, uint256 shares) external useActor(actorSeed) {
        uint256 bal = vault.balanceOf(currentActor);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        vm.startPrank(currentActor);
        try vault.redeem(shares, currentActor, currentActor) {
            callsWithdraw++;
        } catch {}
        vm.stopPrank();
    }

    // ─── Action: post-deploy bug — adapter under-delivers on withdraw (realizable < mark).
    //     Safe standalone: FaultyAdapter.totalAssets() stays readable (deliverBps only
    //     affects the withdraw leg), so invariant evaluation never reverts.
    function setLossy(uint256 bps) external {
        adapter.setDeliverBps(bound(bps, 5_000, 10_000));
        callsSetLossy++;
    }

    // ─── Action: governance force-detach (pause to idle). Best-effort recall; a shortfall
    //     writes off NAV and pauses deposits.
    function forceDetach() external {
        if (vault.activeAdapter() == address(0)) return;
        vm.prank(governance);
        try vault.setAdapter(address(0)) { callsForceDetach++; } catch {}
    }

    // ─── Action: broken valuation (H-01) — set totalAssets() to revert, then force-detach
    //     in the SAME action so the unreadable adapter is never left active for an assertion.
    function breakOracleThenForceDetach() external {
        if (vault.activeAdapter() == address(0)) return;
        adapter.setRevertOnTotalAssets(true);
        vm.prank(governance);
        try vault.setAdapter(address(0)) { callsBreakOracle++; } catch {}
    }

    // ─── Action: governance reattaches a fresh, healthy adapter (reopens deposits) ───
    function reattach() external {
        if (vault.activeAdapter() != address(0)) return;
        FaultyAdapter fresh = new FaultyAdapter(address(usdc), address(vault));
        vm.startPrank(governance);
        registry.registerAdapter(address(fresh), "Test", "Faulty");
        try vault.setAdapter(address(fresh)) {
            adapter = fresh;
            callsReattach++;
        } catch {}
        vm.stopPrank();
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }
}
