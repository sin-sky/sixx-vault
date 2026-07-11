// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ITimelockMinDelay
/// @notice Minimal view surface of OpenZeppelin's TimelockController used by M-02 to
///         verify, on mainnet, that a proposed governance address is a TimelockController
///         with an adequate delay (never a hot EOA). Kept as a tiny interface so the core
///         contracts do not import the full TimelockController implementation.
interface ITimelockMinDelay {
    function getMinDelay() external view returns (uint256);
}
