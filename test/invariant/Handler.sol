// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SIXXVault} from "../../src/core/SIXXVault.sol";
import {MockAdapter} from "../mocks/MockAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMintableERC20 is IERC20 {
    function mint(address to, uint256 amount) external;
}

/// @title Invariant Handler for SIXXVault
/// @notice Bounded, stateful action driver used by the Foundry invariant runner.
///         Each public function is a fuzzed "user action". Ghost variables track the
///         value that has legitimately entered (deposits + injected yield) and left
///         (withdrawals) the system so the invariant contract can assert that the vault
///         never creates value out of thin air and never silently loses value.
/// @dev All actions keep management/performance fees at 0 (set in the test setUp) so the
///      accounting identity `totalAssets == deposited + yield - withdrawn` holds exactly
///      up to share-rounding dust.
contract Handler is Test {
    SIXXVault public immutable vault;
    IMintableERC20 public immutable usdc;
    MockAdapter public immutable adapter;
    /// @dev Governance address, so fuzzed governance actions (fee toggling) can be pranked.
    address public immutable governance;
    uint256 internal constant MAX_MANAGEMENT_FEE = 500; // 5% hard cap (mirrors the vault)

    // ─── Actors ───────────────────────────────────────────────
    address[] public actors;
    address internal currentActor;

    // ─── Ghost accounting (in underlying asset units) ─────────
    uint256 public ghost_deposited; // cumulative assets deposited by users
    uint256 public ghost_withdrawn; // cumulative assets sent back to users
    uint256 public ghost_yield;     // cumulative yield injected into the adapter

    // ─── Monotonicity tracking ────────────────────────────────
    // totalAssets() must never decrease outside of an explicit withdrawal.
    // Any decrease observed during deposit/yield/harvest/warp flips this flag.
    bool public ghost_nonWithdrawDecrease;

    // ─── Call counters (surfaced in invariant summary) ────────
    uint256 public callsDeposit;
    uint256 public callsWithdraw;
    uint256 public callsYield;
    uint256 public callsHarvest;
    uint256 public callsWarp;
    uint256 public callsSetFee;
    uint256 public callsHarvestVault;

    uint256 internal constant MAX_ACTION = 1_000_000 * 1e6; // 1M USDC per action cap

    constructor(
        SIXXVault vault_,
        IMintableERC20 usdc_,
        MockAdapter adapter_,
        address[] memory actors_,
        address governance_
    ) {
        vault = vault_;
        usdc = usdc_;
        adapter = adapter_;
        actors = actors_;
        governance = governance_;
    }

    modifier useActor(uint256 actorSeed) {
        currentActor = actors[bound(actorSeed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────
    // Action: user deposits `amount` for themselves (caller == receiver, H-3)
    // ─────────────────────────────────────────────────────────
    function deposit(uint256 actorSeed, uint256 amount) external useActor(actorSeed) {
        amount = bound(amount, 0, MAX_ACTION);
        if (amount == 0) return;

        // fund the actor on demand
        vm.stopPrank();
        usdc.mint(currentActor, amount);
        vm.startPrank(currentActor);

        uint256 before = vault.totalAssets();
        usdc.approve(address(vault), amount);
        try vault.deposit(amount, currentActor) {
            ghost_deposited += amount;
            _checkNoDecrease(before);
            callsDeposit++;
        } catch {
            // reverts are acceptable (e.g. shutdown) — no state change to record
        }
    }

    // ─────────────────────────────────────────────────────────
    // Action: user redeems a fraction of their shares
    // ─────────────────────────────────────────────────────────
    function withdraw(uint256 actorSeed, uint256 shares) external useActor(actorSeed) {
        uint256 bal = vault.balanceOf(currentActor);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);

        uint256 assetsBefore = usdc.balanceOf(currentActor);
        try vault.redeem(shares, currentActor, currentActor) {
            uint256 assetsOut = usdc.balanceOf(currentActor) - assetsBefore;
            ghost_withdrawn += assetsOut;
            callsWithdraw++;
        } catch {
            // locked / shutdown paths may revert — acceptable
        }
    }

    // ─────────────────────────────────────────────────────────
    // Action: inject real yield into the adapter (legitimate value increase)
    // ─────────────────────────────────────────────────────────
    function addYield(uint256 amount) external {
        amount = bound(amount, 0, MAX_ACTION / 100);
        if (amount == 0) return;
        // Only meaningful once there is capital deployed
        if (vault.totalAssets() == 0) return;

        uint256 before = vault.totalAssets();
        usdc.mint(address(this), amount);
        usdc.approve(address(adapter), amount);
        try adapter.addYield(amount) {
            ghost_yield += amount;
            _checkNoDecrease(before);
            callsYield++;
        } catch {}
    }

    // ─────────────────────────────────────────────────────────
    // Action: harvest (no-op for MockAdapter, but exercises the path)
    // ─────────────────────────────────────────────────────────
    function harvest() external {
        uint256 before = vault.totalAssets();
        try adapter.harvest() {
            _checkNoDecrease(before);
            callsHarvest++;
        } catch {}
    }

    // ─────────────────────────────────────────────────────────
    // Action: advance time (management-fee accrual window, lock expiry)
    // ─────────────────────────────────────────────────────────
    function warp(uint256 dt) external {
        dt = bound(dt, 0, 365 days);
        uint256 before = vault.totalAssets();
        vm.warp(block.timestamp + dt);
        _checkNoDecrease(before);
        callsWarp++;
    }

    // ─────────────────────────────────────────────────────────
    // Action: governance toggles the management fee between 0 and a bounded rate
    //   (P-03: exercises the M-01 anchor-advance path — a 0->nonzero change must only
    //   ever apply going forward, never retroactively diluting existing LPs. Fees mint
    //   shares, never assets, so the value-conservation invariants must still hold.)
    // ─────────────────────────────────────────────────────────
    function setManagementFee(uint256 bps) external {
        bps = bound(bps, 0, MAX_MANAGEMENT_FEE);
        uint256 before = vault.totalAssets();
        vm.prank(governance);
        try vault.setManagementFee(bps) {
            _checkNoDecrease(before);
            callsSetFee++;
        } catch {}
    }

    // ─────────────────────────────────────────────────────────
    // Action: permissionless vault.harvest() (P-03: zero-profit harvest must be a
    //   no-op on the unlock schedule — M-02 — so repeated calls never suppress
    //   totalAssets to grief exiting holders).
    // ─────────────────────────────────────────────────────────
    function harvestVault() external {
        uint256 before = vault.totalAssets();
        try vault.harvest() {
            _checkNoDecrease(before);
            callsHarvestVault++;
        } catch {}
    }

    // ─────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────
    function _checkNoDecrease(uint256 before) internal {
        // Allow tiny share-rounding dust; a real decrease outside withdraw is a bug.
        if (vault.totalAssets() + 2 < before) {
            ghost_nonWithdrawDecrease = true;
        }
    }

    function netValueIn() external view returns (uint256) {
        return ghost_deposited + ghost_yield;
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }
}
