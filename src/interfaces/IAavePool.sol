// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IAavePool
/// @notice Minimal interface for Aave V3 Pool — only the functions SIXX uses
interface IAavePool {
    struct ReserveConfigurationMap {
        uint256 data;
    }

    struct ReserveData {
        ReserveConfigurationMap configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate; // RAY (1e27) per-second rate
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        uint16 id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }

    /// @notice Supply `amount` of `asset` to Aave on behalf of `onBehalfOf`
    /// @param asset The ERC-20 token address
    /// @param amount Amount to supply
    /// @param onBehalfOf Address that receives the aTokens
    /// @param referralCode 0 unless registered referral
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;

    /// @notice Withdraw `amount` of `asset` from Aave and send to `to`
    /// @param asset The underlying ERC-20 token address
    /// @param amount Amount to withdraw (use type(uint256).max for full balance)
    /// @param to Recipient of the withdrawn tokens
    /// @return The actual amount withdrawn
    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256);

    /// @notice Get reserve data (used for APY estimation)
    function getReserveData(address asset) external view returns (ReserveData memory);
}
