// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IStrategyAdapter} from "../../src/interfaces/IStrategyAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title FaultyAdapter
/// @notice Test adapter that can be forced to revert or under-deliver on withdraw,
///         to exercise the vault's emergency-recall try/catch (A) and the recall
///         shortfall guard (M13-16). Holds assets locally like MockAdapter.
contract FaultyAdapter is IStrategyAdapter {
    using SafeERC20 for IERC20;

    address public override asset;
    address public vault;
    uint256 private _balance;

    /// @notice When true, `withdraw` reverts (simulates a frozen/broken protocol).
    bool public revertOnWithdraw;
    /// @notice When true, `totalAssets` reverts (simulates a broken oracle / not-ready TWAP).
    bool public revertOnTotalAssets;
    /// @notice Fraction of the requested amount actually delivered on withdraw (bps).
    ///         < 10_000 models "realizable < mark" (stress slippage / depeg beyond the NAV mark).
    uint256 public deliverBps = 10_000; // 100% by default

    constructor(address asset_, address vault_) {
        asset = asset_;
        vault = vault_;
    }

    modifier onlyVault() {
        require(msg.sender == vault, "FAULTY: only vault");
        _;
    }

    function setRevertOnWithdraw(bool v) external {
        revertOnWithdraw = v;
    }

    function setRevertOnTotalAssets(bool v) external {
        revertOnTotalAssets = v;
    }

    function setDeliverBps(uint256 bps) external {
        deliverBps = bps;
    }

    function totalAssets() external view override returns (uint256) {
        require(!revertOnTotalAssets, "FAULTY: totalAssets reverts");
        return _balance;
    }

    function deposit(uint256 assets) external override onlyVault returns (uint256) {
        _balance += assets;
        emit Deposited(assets, assets);
        return assets;
    }

    function withdraw(uint256 assets, address recipient) external override onlyVault returns (uint256) {
        require(!revertOnWithdraw, "FAULTY: withdraw reverts");
        uint256 send = (assets * deliverBps) / 10_000;
        _balance = _balance > send ? _balance - send : 0;
        IERC20(asset).safeTransfer(recipient, send);
        emit Withdrawn(assets, send, recipient);
        return send;
    }

    function harvest() external override returns (uint256) {
        emit Harvested(0);
        return 0;
    }

    function name() external pure override returns (string memory) { return "Faulty Adapter"; }
    function providerName() external pure override returns (string memory) { return "Faulty"; }
    function adapterType() external pure override returns (string memory) { return "Test"; }
    function riskLevel() external pure override returns (uint8) { return 1; }
    function estimatedAPY() external pure override returns (uint256) { return 0; }
    function requiredLockPeriod() external pure override returns (uint256) { return 0; }
    function isActive() external pure override returns (bool) { return true; }
    function pause() external override { emit Paused(); }
    function unpause() external override { emit Unpaused(); }
}
