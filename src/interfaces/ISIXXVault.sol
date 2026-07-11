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
    // Profit streaming (ADR-007 #2 — structural JIT defense)
    // =========================================

    /// @notice Realize adapter profit and lock it, releasing linearly over the unlock window
    ///         (anyone can call). Discrete harvest gains are buffered so a just-in-time
    ///         depositor cannot skim yield they did not earn over time.
    /// @return profit Newly realized profit locked by this call
    function harvest() external returns (uint256 profit);

    /// @notice Amount of profit still locked (not yet counted in totalAssets), degrading to 0.
    function lockedProfit() external view returns (uint256);

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

    /// @notice The guardian address, allowed to trigger emergency shutdown immediately.
    function guardian() external view returns (address);

    /// @notice Update the guardian. Governance-only (behind the Timelock).
    function setGuardian(address newGuardian) external;

    // =========================================
    // Events
    // =========================================

    event AdapterUpdated(address indexed oldAdapter, address indexed newAdapter);
    event LockPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event EmergencyShutdown(bool active);
    event FeeCollected(address indexed recipient, uint256 feeShares, uint256 feeAssets);
    /// @dev Part B P2: emitted when governance changes the management-fee rate.
    event ManagementFeeUpdated(uint256 oldFee, uint256 newFee);
    event GovernanceProposed(address indexed currentGovernance, address indexed pendingGovernance);
    event GovernanceAccepted(address indexed newGovernance);
    event GuardianChanged(address indexed oldGuardian, address indexed newGuardian);
    /// @dev M-3: Emitted when an adapter reverts during deposit; the vault
    ///      rolls the transfer back so funds stay idle in the vault.
    event AdapterDepositFailed(address indexed adapter, uint256 amount);
    /// @dev A: Emitted when the recall of assets fails during emergency shutdown;
    ///      the shutdown still takes effect (activeAdapter unchanged, funds remain
    ///      counted and recoverable once the adapter unfreezes).
    event AdapterRecallFailed(address indexed adapter, uint256 amount);
    /// @dev ADR-007 #1: Emitted when governance force-detaches (pauses to idle) an
    ///      adapter via setAdapter(address(0)) using a best-effort recall. `marked` is the
    ///      adapter's reported NAV at detach; `received` is what was actually recalled to
    ///      idle. Any (marked - received) shortfall is written off from NAV — a deliberate,
    ///      timelocked governance action that keeps the pause valve always available.
    event AdapterForceDetached(address indexed adapter, uint256 marked, uint256 received);
    /// @dev ADR-007 #2: Emitted on harvest when realized profit is locked for linear release.
    ///      `newProfit` is realized this call; `totalLocked` is the resulting locked balance.
    event ProfitLocked(uint256 newProfit, uint256 totalLocked);
}
