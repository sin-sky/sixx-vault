// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IStrategyAdapter} from "../../src/interfaces/IStrategyAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title HarvestAdapter
/// @notice Test adapter that recognizes yield DISCRETELY at harvest() time — its
///         totalAssets() jumps only when harvest() is called. Models a reward-claiming
///         adapter (Morpho/Curve gauge etc.), the class that reintroduces JIT risk and
///         that ADR-007 #2 profit-streaming defends against.
contract HarvestAdapter is IStrategyAdapter {
    using SafeERC20 for IERC20;

    address public override asset;
    address public vault;
    uint256 private _balance;
    /// @dev Rewards already sitting in the contract but NOT yet counted in totalAssets()
    ///      until harvest() realizes them (the discrete jump).
    uint256 public pendingReward;

    /// @dev Fraction of a requested withdraw actually delivered (bps). < 10_000 lets a
    ///      force-detach realize a writeoff (received < marked) — used by the M-03 tests.
    uint256 public deliverBps = 10_000;

    constructor(address asset_, address vault_) {
        asset = asset_;
        vault = vault_;
    }

    function setDeliverBps(uint256 bps) external {
        deliverBps = bps;
    }

    /// @notice Test helper: model a realized loss on already-harvested principal — the
    ///         mark (totalAssets) drops and the tokens leave the adapter, so raw vault
    ///         assets can fall at/under a still-locked profit buffer (the M-03 hazard).
    function simulateLoss(uint256 amount, address sink) external {
        require(amount <= _balance, "HARVEST: loss > balance");
        _balance -= amount;
        IERC20(asset).safeTransfer(sink, amount);
    }

    modifier onlyVault() {
        require(msg.sender == vault, "HARVEST: only vault");
        _;
    }

    /// @notice Test helper: fund a pending reward (tokens pulled in now, realized on harvest).
    function addReward(uint256 amount) external {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        pendingReward += amount;
    }

    function totalAssets() external view override returns (uint256) {
        return _balance; // reward is excluded until harvested
    }

    function deposit(uint256 assets) external override onlyVault returns (uint256) {
        _balance += assets;
        emit Deposited(assets, assets);
        return assets;
    }

    function withdraw(uint256 assets, address recipient)
        external override onlyVault returns (uint256)
    {
        // Deliver the (optionally haircut) amount; under-delivery models realizable < mark
        //   so a force-detach best-effort recall writes off the shortfall (M-03).
        uint256 send = (assets * deliverBps) / 10_000;
        if (send > _balance) send = _balance;
        _balance -= send;
        IERC20(asset).safeTransfer(recipient, send);
        emit Withdrawn(assets, send, recipient);
        return send;
    }

    /// @notice Realize the pending reward — this is where totalAssets() jumps.
    function harvest() external override returns (uint256) {
        uint256 realized = pendingReward;
        _balance += realized;
        pendingReward = 0;
        emit Harvested(realized);
        return realized;
    }

    function name()               external pure override returns (string memory) { return "Harvest Adapter"; }
    function providerName()       external pure override returns (string memory) { return "Harvest"; }
    function adapterType()        external pure override returns (string memory) { return "DeFi"; }
    function riskLevel()          external pure override returns (uint8)         { return 2; }
    function estimatedAPY()       external pure override returns (uint256)       { return 800; }
    function requiredLockPeriod() external pure override returns (uint256)       { return 0; }
    function isActive()           external pure override returns (bool)          { return true; }
    function pause()  external override { emit Paused(); }
    function unpause() external override { emit Unpaused(); }
}
