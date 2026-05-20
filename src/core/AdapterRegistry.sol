// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAdapterRegistry} from "../interfaces/IAdapterRegistry.sol";

/// @title AdapterRegistry
/// @notice Whitelist of approved SIXX strategy adapters.
///         Governance registers/disables adapters; Vault checks isActive() before switching.
contract AdapterRegistry is IAdapterRegistry {
    // =========================================
    // State
    // =========================================

    address public governance;
    address public pendingGovernance;

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

    function disableAdapter(address adapter) external override onlyGovernance {
        require(_adapters[adapter].status == Status.Active, "REGISTRY: not active");
        _adapters[adapter].status = Status.Disabled;
        emit AdapterDisabled(adapter);
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
        pendingGovernance = newGovernance;
    }

    function acceptGovernance() external {
        require(msg.sender == pendingGovernance, "REGISTRY: not pending");
        governance = pendingGovernance;
        pendingGovernance = address(0);
    }
}
