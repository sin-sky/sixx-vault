// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAdapterRegistry} from "../interfaces/IAdapterRegistry.sol";
import {ITimelockMinDelay} from "../interfaces/ITimelockMinDelay.sol";

/// @title AdapterRegistry
/// @notice Whitelist of approved SIXX strategy adapters.
///         Governance registers/disables adapters; Vault checks isActive() before switching.
contract AdapterRegistry is IAdapterRegistry {
    // =========================================
    // State
    // =========================================

    address public governance;
    address public pendingGovernance;

    /// @notice L-03 (3rd review): hard cap on the number of registered adapters so
    ///         `getActiveAdapters()` (and any list scan) stays bounded — no unbounded-gas
    ///         growth. Far above any realistic adapter count (one active adapter per vault).
    uint256 public constant MAX_ADAPTERS = 100;

    mapping(address => AdapterInfo) private _adapters;
    address[] private _adapterList;

    // =========================================
    // Constructor
    // =========================================

    constructor(address governance_) {
        require(governance_ != address(0), "REGISTRY: zero governance");
        governance = governance_;
    }

    // =========================================
    // Modifiers
    // =========================================

    modifier onlyGovernance() {
        require(msg.sender == governance, "REGISTRY: not governance");
        _;
    }

    // =========================================
    // Registration
    // =========================================

    function registerAdapter(
        address adapter,
        string calldata adapterType_,
        string calldata providerName_
    ) external override onlyGovernance {
        require(adapter != address(0), "REGISTRY: zero address");
        require(
            _adapters[adapter].status == Status.NotRegistered,
            "REGISTRY: already registered"
        );
        // L-03: bound the list so getActiveAdapters() can never grow unbounded.
        require(_adapterList.length < MAX_ADAPTERS, "REGISTRY: max adapters");
        _adapters[adapter] = AdapterInfo({
            adapter: adapter,
            status: Status.Active,
            adapterType: adapterType_,
            providerName: providerName_,
            registeredAt: block.timestamp
        });
        _adapterList.push(adapter);
        emit AdapterRegistered(adapter, adapterType_, providerName_);
    }

    /// @notice M-5: Set an adapter to Active or Disabled. Adapters must
    ///         be registered first (cannot resurrect a never-registered
    ///         address). No-op if already in the target state.
    function setAdapterStatus(address adapter, bool active)
        external override onlyGovernance
    {
        AdapterInfo storage info = _adapters[adapter];
        require(info.status != Status.NotRegistered, "REGISTRY: not registered");

        Status newStatus = active ? Status.Active : Status.Disabled;
        if (info.status == newStatus) return;

        info.status = newStatus;
        emit AdapterStatusUpdated(adapter, active);
    }

    // =========================================
    // View
    // =========================================

    function isActive(address adapter) external view override returns (bool) {
        return _adapters[adapter].status == Status.Active;
    }

    function getAdapterInfo(address adapter)
        external view override returns (AdapterInfo memory)
    {
        return _adapters[adapter];
    }

    function getActiveAdapters() external view override returns (address[] memory) {
        uint256 count;
        for (uint256 i = 0; i < _adapterList.length; i++) {
            if (_adapters[_adapterList[i]].status == Status.Active) count++;
        }
        address[] memory result = new address[](count);
        uint256 idx;
        for (uint256 i = 0; i < _adapterList.length; i++) {
            if (_adapters[_adapterList[i]].status == Status.Active) {
                result[idx++] = _adapterList[i];
            }
        }
        return result;
    }

    // =========================================
    // Governance Transfer
    // =========================================

    function proposeGovernance(address newGovernance) external onlyGovernance {
        require(newGovernance != address(0), "REGISTRY: zero address");
        // M-02 (3rd review): on mainnet, registry governance MUST also be a
        //   TimelockController(>=48h) so registerAdapter/setAdapterStatus inherit the 48h
        //   detection window (mainnet-gate G1). Off-mainnet keeps EOA for iteration.
        if (block.chainid == 1) {
            require(newGovernance.code.length > 0, "REGISTRY: mainnet gov must be a Timelock");
            try ITimelockMinDelay(newGovernance).getMinDelay() returns (uint256 d) {
                require(d >= 48 hours, "REGISTRY: mainnet gov timelock < 48h");
            } catch {
                revert("REGISTRY: mainnet gov must be a Timelock");
            }
        }
        emit GovernanceProposed(governance, newGovernance); // Part B P2: observability
        pendingGovernance = newGovernance;
    }

    function acceptGovernance() external {
        require(msg.sender == pendingGovernance, "REGISTRY: not pending");
        emit GovernanceAccepted(pendingGovernance); // Part B P2: observability
        governance = pendingGovernance;
        pendingGovernance = address(0);
    }
}
