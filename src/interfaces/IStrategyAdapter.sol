// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IStrategyAdapter
/// @notice Standard interface for all SIXX yield strategy adapters
/// @dev Each adapter wraps a single external protocol (Aave, Lido, etc.)
interface IStrategyAdapter {
    // =========================================
    // Core
    // =========================================

    /// @notice Underlying asset address (e.g. USDC, WETH)
    function asset() external view returns (address);

    /// @notice Total assets under management by this adapter
    /// @dev For interest-bearing tokens (aUSDC, stETH), this grows automatically over time
    function totalAssets() external view returns (uint256);

    /// @notice Receive `assets` from vault and deploy into the protocol
    /// @dev Vault transfers tokens to this contract BEFORE calling this function
    /// @param assets Amount of underlying asset to deploy
    /// @return deposited Actual amount deposited
    function deposit(uint256 assets) external returns (uint256 deposited);

    /// @notice Withdraw `assets` from the protocol and send to `recipient`
    /// @param assets Amount of underlying asset to withdraw
    /// @param recipient Address to receive the withdrawn assets
    /// @return withdrawn Actual amount withdrawn
    function withdraw(uint256 assets, address recipient) external returns (uint256 withdrawn);

    /// @notice Claim/compound any pending rewards
    /// @dev For auto-compounding protocols (Aave), this is a no-op
    /// @return harvested Amount of additional assets gained
    function harvest() external returns (uint256 harvested);

    // =========================================
    // Metadata
    // =========================================

    /// @notice Human-readable adapter name
    function name() external view returns (string memory);

    /// @notice Protocol name (e.g. "Aave V3", "Lido")
    function providerName() external view returns (string memory);

    /// @notice Adapter category: "DeFi" | "SelfManaged" | "CEX"
    function adapterType() external view returns (string memory);

    /// @notice Risk level 1 (lowest) to 5 (highest)
    function riskLevel() external view returns (uint8);

    /// @notice Estimated APY in basis points (e.g. 500 = 5%)
    function estimatedAPY() external view returns (uint256);

    /// @notice Minimum lock period in seconds (0 = instant withdrawal)
    function requiredLockPeriod() external view returns (uint256);

    /// @notice Whether the adapter is currently active (not paused)
    function isActive() external view returns (bool);

    // =========================================
    // Circuit Breaker
    // =========================================

    /// @notice Pause new deposits (governance or vault)
    function pause() external;

    /// @notice Resume deposits (governance only)
    function unpause() external;

    // =========================================
    // Events
    // =========================================

    event Deposited(uint256 assets, uint256 deposited);
    event Withdrawn(uint256 assets, uint256 withdrawn, address indexed recipient);
    event Harvested(uint256 harvested);
    event Paused();
    event Unpaused();
}
