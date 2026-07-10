// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IPendleCore
/// @notice Read-only views on the Pendle market / PT / SY contracts and the
///         Pendle PT TWAP oracle, used by `PendlePTAdapter` for construction-time
///         validation and mark-to-oracle accounting.

/// @notice Pendle market (PT-sUSDe market at
///         `0x177768caf9d0e036725a51d3f60d7e20f2d4d194`).
interface IPendleMarket {
    /// @return _SY standardized-yield token
    /// @return _PT principal token
    /// @return _YT yield token
    function readTokens() external view returns (address _SY, address _PT, address _YT);

    function expiry() external view returns (uint256);

    function isExpired() external view returns (bool);
}

/// @notice Pendle principal token (PT).
interface IPendlePrincipalToken {
    function expiry() external view returns (uint256);
    function isExpired() external view returns (bool);
    function SY() external view returns (address);
    function YT() external view returns (address);
}

/// @notice Pendle standardized-yield wrapper (SY-sUSDe).
interface IPendleSY {
    /// @notice Tokens accepted to mint SY (for SY-sUSDe: [USDe, sUSDe]).
    function getTokensIn() external view returns (address[] memory);

    /// @notice Tokens SY can be redeemed to (for SY-sUSDe: [sUSDe]).
    function getTokensOut() external view returns (address[] memory);

    /// @notice The interest-bearing token wrapped by the SY (sUSDe).
    function yieldToken() external view returns (address);

    /// @return assetType 0 = TOKEN, 1 = LIQUIDITY
    /// @return assetAddress underlying asset (USDe for SY-sUSDe)
    /// @return assetDecimals decimals of the asset
    function assetInfo() external view returns (uint8 assetType, address assetAddress, uint8 assetDecimals);
}

/// @notice Pendle PT TWAP oracle (`PendlePYLpOracle`,
///         `0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2`).
interface IPPtOracle {
    /// @notice TWAP rate of PT priced in the SY's asset (USDe here); 1e18 = par.
    /// @param market Pendle market address
    /// @param duration TWAP window in seconds
    function getPtToAssetRate(address market, uint32 duration) external view returns (uint256);

    /// @notice Whether the market's oracle observation buffer supports `duration`.
    /// @return increaseCardinalityRequired true if the buffer must be grown first
    /// @return cardinalityRequired minimum cardinality for `duration`
    /// @return oldestObservationSatisfied true if the oldest observation is old enough
    function getOracleState(address market, uint32 duration)
        external
        view
        returns (bool increaseCardinalityRequired, uint16 cardinalityRequired, bool oldestObservationSatisfied);
}

/// @notice Minimal ERC-4626 view on StakedUSDeV2 (sUSDe) — used only for
///         min-out sizing (protocol-internal rate, not a manipulable spot price).
interface ISUSDeConvert {
    /// @return assets USDe returned for `shares` sUSDe
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
}
