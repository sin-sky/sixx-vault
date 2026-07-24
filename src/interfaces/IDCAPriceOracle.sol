// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IDCAPriceOracle
/// @notice Trust anchor for the DCA *spot buy* slippage floor. Given a stable
///         `tokenIn` amount, returns the fair `tokenOut` amount the swap SHOULD
///         yield at the current oracle mid price (before slippage). The
///         `DCASpotAccumulator` derives its on-chain `minOut` floor from this
///         value so the keeper has ZERO discretion to accept a bad price — it
///         cannot route through a manipulated pool and cannot loosen the floor.
///
/// @dev Injected dependency (governance-replaceable), mirroring how the Ethena
///      adapters inject `IStableSwapper`: the exact price source (Chainlink feed
///      set, TWAP, etc.) is an infrastructure concern standardized once and
///      swapped out by redeploy-and-repoint if a feed migrates.
///
///      Implementations MUST revert (not return 0 or a stale value) when a price
///      is unavailable/stale/non-positive, so a broken oracle fails the DCA run
///      safely instead of manufacturing a zero floor that a keeper could exploit.
interface IDCAPriceOracle {
    /// @param tokenIn   stable input token (e.g. USDC)
    /// @param tokenOut  spot target token (e.g. WETH / WBTC / WBNB)
    /// @param amountIn  amount of `tokenIn` (in tokenIn's smallest units)
    /// @return expectedOut fair amount of `tokenOut` (in tokenOut's smallest
    ///         units) at the oracle mid price, BEFORE slippage is applied.
    function expectedOut(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        returns (uint256 expectedOut);
}
