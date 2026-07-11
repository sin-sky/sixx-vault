// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IStrategyAdapter} from "../../src/interfaces/IStrategyAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title FaultInjectingAdapter
/// @notice Adapter mock for the state-transition × fault-injection fuzz. Holds the underlying
///         locally (like MockAdapter) and exposes runtime-toggleable FAULT KNOBS so the fuzzer
///         can drive any adapter failure mode in the middle of any state transition:
///           - revertOnTotalAssets : valuation read reverts (broken oracle / not-ready TWAP —
///                                   the H-01/H-02 root cause).
///           - revertOnWithdraw    : withdraw reverts (fully frozen / underlying paused).
///           - deliverBps < 10_000 : withdraw delivers less than requested (realizable < mark;
///                                   models a stale mark / thin liquidity).
///           - realizeLoss(amount) : permanently burns held value (depeg / protocol loss).
///         Exposes vault()/governance()/asset() so SIXXVault.setAdapter's M-03 binding check
///         accepts it (bound to the fuzz vault + governance).
/// @dev Standard-token semantics only. Rebasing / fee-on-transfer underlyings are documented
///      OUT OF SCOPE (SCOPE.md §2 / AUDIT_PACKAGE §5 — the vault targets standard USDC/USDT).
contract FaultInjectingAdapter is IStrategyAdapter {
    using SafeERC20 for IERC20;

    address public override asset;
    address public vault;
    address public governance;
    uint256 private _balance;
    bool private _paused;

    // ── Fault knobs (fuzzer-toggled between actions) ──
    bool public revertOnTotalAssets;
    bool public revertOnWithdraw;
    uint256 public deliverBps = 10_000; // fraction of a requested withdraw actually delivered

    constructor(address asset_, address vault_, address governance_) {
        asset = asset_;
        vault = vault_;
        governance = governance_;
    }

    modifier onlyVault() {
        require(msg.sender == vault, "FIA: only vault");
        _;
    }

    // ── Fault controls (unauthenticated — test harness only) ──
    function setRevertOnTotalAssets(bool v) external { revertOnTotalAssets = v; }
    function setRevertOnWithdraw(bool v) external { revertOnWithdraw = v; }
    function setDeliverBps(uint256 bps) external { deliverBps = bps; }

    /// @notice Permanently burn `amount` of held value (depeg / realized protocol loss). The
    ///         tokens leave the adapter, so the vault's real backing drops — the honest,
    ///         unambiguous loss model (no oracle recovery games).
    function realizeLoss(uint256 amount, address sink) external {
        if (amount > _balance) amount = _balance;
        _balance -= amount;
        IERC20(asset).safeTransfer(sink, amount);
    }

    /// @notice Inject real yield (profit): pulls `amount` in and counts it. Continuous-accrual
    ///         style (reflected immediately in totalAssets), so vault.harvest() is a no-op here.
    function addYield(uint256 amount) external {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        _balance += amount;
    }

    /// @notice The adapter's TRUE holdings, always readable (ignores the revert knob). The
    ///         fuzz handler uses it to tell a genuine liveness breach (funds exist but the
    ///         exit failed) from the documented case where a realized loss has drained the
    ///         adapter below its booked debt (claim unrecoverable → force-detach recovery).
    function realBalance() external view returns (uint256) {
        return _balance;
    }

    // ── IStrategyAdapter ──
    function totalAssets() external view override returns (uint256) {
        require(!revertOnTotalAssets, "FIA: totalAssets reverts");
        return _balance;
    }

    function deposit(uint256 assets) external override onlyVault returns (uint256) {
        _balance += assets; // assets already transferred in by the vault
        emit Deposited(assets, assets);
        return assets;
    }

    function withdraw(uint256 assets, address recipient) external override onlyVault returns (uint256) {
        require(!revertOnWithdraw, "FIA: withdraw reverts");
        uint256 send = (assets * deliverBps) / 10_000;
        if (send > _balance) send = _balance;
        _balance -= send;
        IERC20(asset).safeTransfer(recipient, send);
        emit Withdrawn(assets, send, recipient);
        return send;
    }

    function harvest() external override returns (uint256) {
        emit Harvested(0);
        return 0;
    }

    function name() external pure override returns (string memory) { return "Fault Injecting Adapter"; }
    function providerName() external pure override returns (string memory) { return "Fuzz"; }
    function adapterType() external pure override returns (string memory) { return "Test"; }
    function riskLevel() external pure override returns (uint8) { return 1; }
    function estimatedAPY() external pure override returns (uint256) { return 0; }
    function requiredLockPeriod() external pure override returns (uint256) { return 0; }
    function isActive() external view override returns (bool) { return !_paused; }
    function pause() external override { _paused = true; emit Paused(); }
    function unpause() external override { _paused = false; emit Unpaused(); }
}
