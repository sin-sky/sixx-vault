// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ILidoStETH
/// @notice Minimal interface for Lido's stETH (Liquid staked Ether 2.0).
/// @dev `submit` is the native staking entry: it mints stETH 1:1 for the ETH sent
///      as `msg.value` (subject to the daily protocol stake limit) — there is NO
///      entry slippage, unlike a DEX buy. stETH is a REBASING token (balance grows
///      daily), which is exactly why the adapter immediately wraps to wstETH.
///      The native exit (Lido withdrawal queue via unstETH NFTs, ~1-5 days) is
///      deliberately NOT used; the adapter exits instantly through Curve instead.
interface ILidoStETH is IERC20 {
    /// @notice Stake the ETH sent as `msg.value`, minting stETH 1:1 to `msg.sender`.
    /// @param _referral Referral address (address(0) for none).
    /// @return The amount of stETH shares minted.
    function submit(address _referral) external payable returns (uint256);

    /// @notice Current remaining daily staking capacity, in wei of ETH. `submit`
    ///         reverts once a deposit would exceed this. Used only for diagnostics.
    function getCurrentStakeLimit() external view returns (uint256);
}
