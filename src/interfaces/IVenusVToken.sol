// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IVenusVToken
/// @notice Minimal interface for a Venus Protocol vToken (Compound v2 fork).
/// @dev Venus uses Compound-style error codes: every state-changing call returns
///      `uint256` where `0` means success and any non-zero value is a numeric
///      error code defined in Venus' ErrorReporter.
interface IVenusVToken {
    /// @notice Supply `mintAmount` of the underlying asset and receive vTokens.
    /// @dev Pulls `mintAmount` of `underlying()` from `msg.sender` via transferFrom.
    /// @param mintAmount Amount of underlying to supply
    /// @return 0 on success, non-zero error code on failure
    function mint(uint256 mintAmount) external returns (uint256);

    /// @notice Redeem vTokens for a specified amount of the underlying asset.
    /// @dev Burns the caller's vTokens equivalent to `redeemAmount` of underlying
    ///      and transfers `redeemAmount` of underlying to `msg.sender`.
    /// @param redeemAmount Amount of underlying to receive
    /// @return 0 on success, non-zero error code on failure
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);

    /// @notice Redeem a specific amount of vTokens for the underlying.
    /// @dev Burns `redeemTokens` vTokens and transfers the equivalent underlying
    ///      (`redeemTokens * exchangeRate / 1e18`) to `msg.sender`. Unlike
    ///      `redeemUnderlying`, this lets a position be drained to exactly zero
    ///      vTokens, leaving no sub-unit dust behind.
    /// @param redeemTokens Amount of vTokens to burn
    /// @return 0 on success, non-zero error code on failure
    function redeem(uint256 redeemTokens) external returns (uint256);

    /// @notice vToken balance of `account` (NOT underlying-denominated)
    function balanceOf(address account) external view returns (uint256);

    /// @notice Stored exchange rate from vToken to underlying (mantissa 1e18,
    ///         adjusted for underlying/vToken decimal difference).
    /// @dev underlying = vBalance * exchangeRateStored / 1e18.
    ///      Slightly stale between blocks; use exchangeRateCurrent() to accrue.
    function exchangeRateStored() external view returns (uint256);

    /// @notice Supply interest rate per block, scaled by 1e18.
    /// @dev Used for APY estimation: APY_bps ≈ rate * blocksPerYear / 1e14.
    function supplyRatePerBlock() external view returns (uint256);

    /// @notice Underlying ERC-20 asset wrapped by this vToken
    function underlying() external view returns (address);
}
