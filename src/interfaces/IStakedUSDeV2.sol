// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IStakedUSDeV2
/// @notice Minimal interface for Ethena's StakedUSDeV2 (sUSDe) — an ERC-4626
///         vault whose underlying asset is USDe. sUSDe is non-rebasing and
///         appreciates against USDe via `convertToAssets`.
/// @dev Only the members the EthenaSUSDeAdapter needs are declared. `deposit`
///      (native staking, no cooldown) and the `convertTo*` valuation views are
///      used; the native `withdraw`/`redeem`/`unstake` cooldown path is
///      deliberately NOT used (exit is via DEX to avoid the 7-day cooldown).
interface IStakedUSDeV2 is IERC20 {
    /// @notice Underlying asset (must be USDe)
    function asset() external view returns (address);

    /// @notice Stake `assets` USDe and mint sUSDe to `receiver`. No cooldown on entry.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice USDe value of `shares` sUSDe (protocol-internal, not a spot price).
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    /// @notice sUSDe shares equivalent to `assets` USDe.
    function convertToShares(uint256 assets) external view returns (uint256 shares);

    /// @notice Current unstake cooldown in seconds (>0 means native redeem reverts).
    function cooldownDuration() external view returns (uint24);
}
