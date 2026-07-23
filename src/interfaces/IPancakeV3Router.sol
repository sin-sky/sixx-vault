// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IPancakeV3Router
/// @notice Minimal interface for the PancakeSwap V3 SwapRouter
///         (BNB Chain 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4), used as the
///         instant slisBNB -> WBNB exit venue for the BNB staking adapter.
/// @dev PancakeSwap's V3 `ExactInputSingleParams` has NO `deadline` field (unlike
///      the original Uniswap V3 router) — verified against the deployed selector
///      0x04e45aaf. `amountOutMinimum` is the on-chain slippage floor: the swap
///      reverts if realized output is below it. The adapter derives that floor
///      from the underlying protocol's convert rate (not the pool's spot price),
///      so pool manipulation cannot loosen the guard.
interface IPancakeV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swap `amountIn` of `tokenIn` for `tokenOut` through a single V3 pool
    ///         of tier `fee`, reverting if output < `amountOutMinimum`.
    /// @return amountOut The amount of `tokenOut` received.
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}
