// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ICurveStETHPool
/// @notice Minimal interface for the classic Curve stETH/ETH StableSwap pool
///         (mainnet 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022), the deepest
///         on-chain venue for an instant stETH exit.
/// @dev This is a RAW-ETH pool: coin 0 is the ETH sentinel
///      (0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE) and coin 1 is stETH. When
///      swapping stETH -> ETH the pool pulls stETH via `transferFrom` (requires
///      approval) and sends raw ETH to `msg.sender`, which is why the adapter has
///      a `receive()`. `exchange` is `payable` on-chain; the adapter calls it with
///      zero value on the stETH->ETH leg. `get_dy` is a view quote used only in
///      tests, never in accounting (accounting uses wstETH's protocol rate).
interface ICurveStETHPool {
    /// @notice Address of coin at index `i` (0 = ETH sentinel, 1 = stETH).
    function coins(uint256 i) external view returns (address);

    /// @notice Quote: output of coin `j` for `dx` of coin `i`. View-only.
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);

    /// @notice Swap `dx` of coin `i` for coin `j`, reverting if output < `min_dy`.
    /// @return The amount of coin `j` received.
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy)
        external
        payable
        returns (uint256);
}
