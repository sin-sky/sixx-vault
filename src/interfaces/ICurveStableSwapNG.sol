// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ICurveStableSwapNG
/// @notice Minimal interface for Curve StableSwap-NG two-coin pools used as the
///         on-chain DEX venues for the Ethena sUSDe adapter's entry/exit swaps.
/// @dev NG pools use `int128` coin indices. `get_dy` is a view quote helper (used
///      off-chain / in tests, never in accounting). `exchange` swaps `dx` of coin
///      `i` for coin `j`, reverting if the output is below `min_dy` — this is how
///      the adapter enforces its slippage cap on-chain. The adapter derives the
///      indices from `coins()` at construction so they cannot be misconfigured.
interface ICurveStableSwapNG {
    /// @notice Address of coin at index `i` (i in {0,1} for a 2-coin pool).
    function coins(uint256 i) external view returns (address);

    /// @notice Quote: output of coin `j` for `dx` of coin `i`. View-only.
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);

    /// @notice Swap `dx` of coin `i` for coin `j`, reverting if output < `min_dy`.
    ///         Output is sent to `msg.sender` (this adapter), then forwarded.
    /// @return The amount of coin `j` received.
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
}
