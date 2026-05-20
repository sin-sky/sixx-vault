// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title ISIXXVault
/// @notice Extended ERC-4626 interface with adapter, lock period, fees, and governance
interface ISIXXVault is IERC4626 {
    // =========================================
    // Adapter
    // =========================================

    /// @notice Currently active strategy adapter address
    function activeAdapter() external view returns (address);

    /// @notice Adapter registry address
    function adapterRegistry() external view returns (address);

    /// @notice Switch the active strategy adapter (governance only)
    /// @dev Recalls all assets from the old adapter before switching
    function setAdapter(address newAdapter) external;

    // =========================================
    // Lock Period
    // =========================================

    /// @notice Default lock duration in seconds (0 = no lock)
    function lockPeriod() external view returns (uint256);

    /// @notice Unix timestamp after which `user` can withdraw
    function lockedUntil(address user) external view returns (uint256);

    /// @notice Update the lock period (governance only)
    function setLockPeriod(uint256 newPeriod) external;

    // =========================================
    // Fees
    // =========================================

    /// @notice Performance fee in basis points (e.g. 1000 = 10%)
    function performanceFee() external view returns (uint256);

    /// @notice Annual management fee in basis points
    function managementFee() external view returns (uint256);

    /// @notice Address that receives collected fees
    function feeRecipient() external view returns (address);

    /// @notice Collect accrued management fees (anyone can call)
    function collectFees() external returns (uint256 feeShares);

    // =========================================
    // Emergency
    // =========================================

    /// @notice Whether emergency shutdown is active
    function emergencyShutdown() external view returns (bool);

    /// @notice Activate or deactivate emergency shutdown (governance only)
    /// @dev When active: new deposits blocked, all assets recalled from adapter
    function setEmergencyShutdown(bool active) external;

    // =========================================
    // Governance (2-step transfer)
    // =========================================

    /// @notice Current governance address
    function governance() external view returns (address);

    /// @notice Pending governance (awaiting acceptance)
    function pendingGovernance() external view returns (address);

    /// @notice Propose a governance transfer (current governance only)
    function proposeGovernance(address newGovernance) external;

    /// @notice Accept governance transfer (pendingGovernance only)
    function acceptGovernance() external;

    // =========================================
    // Events
    // =========================================

    event AdapterUpdated(address indexed oldAdapter, address indexed newAdapter);
    event LockPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event EmergencyShutdown(bool active);
    event FeeCollected(address indexed recipient, uint256 feeShares, uint256 feeAssets);
    event GovernanceProposed(address indexed currentGovernance, address indexed pendingGovernance);
    event GovernanceAccepted(address indexed newGovernance);
}
