// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IListaStakeManager
/// @notice Minimal interface for Lista DAO's BNB liquid-staking StakeManager
///         (BNB Chain 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6), which mints
///         slisBNB against staked BNB.
/// @dev `deposit` is the native staking entry: it mints slisBNB to `msg.sender`
///      at the current exchange rate for the BNB sent as `msg.value` — no entry
///      slippage. slisBNB is NON-REBASING and value-accruing (like wstETH); its
///      BNB value is read via `convertSnBnbToBnb`, a protocol-internal rate that
///      is safe for accounting. The native exit (`requestWithdraw` +
///      `claimWithdraw`, 7-15 day unbonding) is deliberately NOT used; the adapter
///      exits instantly through PancakeSwap V3 instead.
interface IListaStakeManager {
    /// @notice Stake the BNB sent as `msg.value`, minting slisBNB to `msg.sender`.
    function deposit() external payable;

    /// @notice slisBNB minted for `_amount` BNB at the current exchange rate.
    function convertBnbToSnBnb(uint256 _amount) external view returns (uint256);

    /// @notice BNB value of `_amountInSlisBnb` slisBNB at the current exchange rate.
    ///         Protocol-internal rate (not a market/spot price) — safe for accounting.
    function convertSnBnbToBnb(uint256 _amountInSlisBnb) external view returns (uint256);
}
