// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IStrategyAdapter} from "../../src/interfaces/IStrategyAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockAdapter
/// @notice Simple in-memory adapter for unit tests. Holds assets locally (no external protocol).
contract MockAdapter is IStrategyAdapter {
    using SafeERC20 for IERC20;

    address public override asset;
    address public vault;
    bool private _paused;

    /// @dev Simulated yield: add this to balance on each totalAssets() call
    uint256 public simulatedYield;

    uint256 private _balance;

    constructor(address asset_, address vault_) {
        asset = asset_;
        vault = vault_;
    }

    modifier onlyVault() {
        require(msg.sender == vault, "MOCK: only vault");
        _;
    }

    function totalAssets() external view override returns (uint256) {
        return _balance + simulatedYield;
    }

    function deposit(uint256 assets) external override onlyVault returns (uint256) {
        // Assets already transferred to this contract by vault
        _balance += assets;
        emit Deposited(assets, assets);
        return assets;
    }

    function withdraw(uint256 assets, address recipient)
        external override onlyVault returns (uint256)
    {
        require(assets <= _balance + simulatedYield, "MOCK: insufficient balance");
        _balance = (_balance + simulatedYield) > assets
            ? (_balance + simulatedYield) - assets
            : 0;
        simulatedYield = 0;
        IERC20(asset).safeTransfer(recipient, assets);
        emit Withdrawn(assets, assets, recipient);
        return assets;
    }

    function harvest() external override returns (uint256) {
        uint256 yield = simulatedYield;
        simulatedYield = 0;
        _balance += yield;
        emit Harvested(yield);
        return yield;
    }

    /// @notice Test helper: inject yield into the adapter
    function addYield(uint256 yieldAmount) external {
        simulatedYield += yieldAmount;
        // Also transfer to self so the token balance matches
        IERC20(asset).safeTransferFrom(msg.sender, address(this), yieldAmount);
        _balance += yieldAmount;
        simulatedYield = 0;
    }

    function name()               external pure override returns (string memory) { return "Mock Adapter"; }
    function providerName()       external pure override returns (string memory) { return "Mock"; }
    function adapterType()        external pure override returns (string memory) { return "DeFi"; }
    function riskLevel()          external pure override returns (uint8)         { return 1; }
    function estimatedAPY()       external pure override returns (uint256)       { return 500; } // 5%
    function requiredLockPeriod() external pure override returns (uint256)       { return 0; }
    function isActive()           external view override returns (bool)          { return !_paused; }

    function pause() external override {
        _paused = true;
        emit Paused();
    }

    function unpause() external override {
        _paused = false;
        emit Unpaused();
    }
}
