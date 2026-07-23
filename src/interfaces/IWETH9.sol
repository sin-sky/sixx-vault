// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IWETH9
/// @notice Minimal wrapped-native interface. Works for both canonical WETH
///         (Ethereum) and WBNB (BNB Chain) — both are the classic WETH9
///         `deposit()/withdraw()` design.
/// @dev Used by the staking adapters to convert the vault's ERC-20 wrapped-native
///      `asset` into the raw native coin required by the underlying staking entry
///      (Lido `submit{value:}` / Lista StakeManager `deposit{value:}`), and back.
interface IWETH9 is IERC20 {
    /// @notice Wrap native coin held as `msg.value` into the ERC-20 wrapper 1:1.
    function deposit() external payable;

    /// @notice Unwrap `wad` of the ERC-20 wrapper back to native coin 1:1,
    ///         sending the native coin to `msg.sender`.
    function withdraw(uint256 wad) external;
}
