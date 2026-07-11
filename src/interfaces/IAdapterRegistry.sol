// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IAdapterRegistry
/// @notice Registry for approved SIXX strategy adapters
interface IAdapterRegistry {
    enum Status {
        NotRegistered,
        Active,
        Disabled
    }

    struct AdapterInfo {
        address adapter;
        Status status;
        string adapterType;   // "DeFi" | "SelfManaged" | "CEX"
        string providerName;  // "Aave V3" | "Lido" | ...
        uint256 registeredAt;
    }

    /// @notice Register a new adapter (governance only)
    function registerAdapter(
        address adapter,
        string calldata adapterType,
        string calldata providerName
    ) external;

    /// @notice M-5: Enable or disable a previously-registered adapter.
    ///         Replaces the one-way `disableAdapter` so a disabled adapter
    ///         can be re-activated without re-registering.
    function setAdapterStatus(address adapter, bool active) external;

    /// @notice Returns true if adapter is registered and active
    function isActive(address adapter) external view returns (bool);

    /// @notice Returns full info about an adapter
    function getAdapterInfo(address adapter) external view returns (AdapterInfo memory);

    /// @notice Returns list of all currently active adapter addresses
    function getActiveAdapters() external view returns (address[] memory);

    event AdapterRegistered(address indexed adapter, string adapterType, string providerName);
    /// @dev M-5: emitted on both disable and re-enable; `active` carries
    ///      the new state.
    event AdapterStatusUpdated(address indexed adapter, bool active);
    /// @dev Part B P2: governance-transfer observability (2-step).
    event GovernanceProposed(address indexed current, address indexed pending);
    event GovernanceAccepted(address indexed newGovernance);
}
