// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IUniswapV3Router
/// @notice Minimal `exactInputSingle` surface of the Uniswap V3 `SwapRouter`
///         (and BNB-chain PancakeSwap V3 SmartRouter, same ABI) used by
///         `UniV3SpotSwapper` to buy the spot target with a single deep pool.
interface IUniswapV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps `amountIn` of `tokenIn` for as much `tokenOut` as possible,
    ///         reverting if the received amount is below `amountOutMinimum`.
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}
