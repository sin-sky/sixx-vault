// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IStableSwapper
/// @notice Thin on-chain stablecoin swap abstraction used by `PendlePTAdapter`
///         for the non-Pendle legs of the round trip:
///           - deposit:  USDC -> USDe   (feed the Pendle Router, which is SY-native)
///           - withdraw: sUSDe -> USDC  (SY only redeems to sUSDe)
/// @dev This is deliberately an injected dependency, not baked into the adapter,
///      because the exact Curve routing for USDC/USDe/sUSDe is shared with the
///      Part A (Ethena sUSDe) strategy and must be standardized once at the
///      infrastructure layer (see PROGRESS_partB escalation #2). The production
///      implementation is a deploy-time parameter; the caller enforces `minOut`
///      so a faulty/thin swapper reverts rather than realizing an unbounded loss.
///
///      Settlement convention: the swapper pulls `amountIn` of `tokenIn` from
///      `msg.sender` via `transferFrom` (caller must approve), executes the swap,
///      and sends at least `minOut` of `tokenOut` to `to`, reverting otherwise.
interface IStableSwapper {
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address to
    ) external returns (uint256 amountOut);
}
