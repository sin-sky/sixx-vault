// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IWstETH
/// @notice Minimal interface for Lido's wstETH (wrapped stETH).
/// @dev wstETH is the NON-REBASING wrapper of stETH: its balance is constant while
///      its stETH (== ETH) value grows via `getStETHByWstETH`. The adapter holds
///      wstETH as its internal position so that `totalAssets()` reads a stable
///      share balance × a monotonically increasing rate — no daily rebase to track
///      and no stETH 1-2 wei transfer quirks in the accounting path.
interface IWstETH is IERC20 {
    /// @notice Wrap `_stETHAmount` stETH (pulled from `msg.sender`, requires
    ///         approval) into wstETH minted to `msg.sender`.
    /// @return The amount of wstETH minted.
    function wrap(uint256 _stETHAmount) external returns (uint256);

    /// @notice Burn `_wstETHAmount` wstETH from `msg.sender`, returning the
    ///         equivalent stETH to `msg.sender`.
    /// @return The amount of stETH returned.
    function unwrap(uint256 _wstETHAmount) external returns (uint256);

    /// @notice stETH (== ETH) value of `_wstETHAmount` wstETH. Protocol-internal
    ///         rate (not a market/spot price) — safe for accounting.
    function getStETHByWstETH(uint256 _wstETHAmount) external view returns (uint256);

    /// @notice wstETH equivalent of `_stETHAmount` stETH.
    function getWstETHByStETH(uint256 _stETHAmount) external view returns (uint256);

    /// @notice The wrapped stETH token address (must match the configured stETH).
    function stETH() external view returns (address);
}
