// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IPendleRouter
/// @notice Minimal, ABI-exact subset of the Pendle Router V4
///         (`0x888888888889758F76e7103c6CbF23ABbF58F946` on Ethereum mainnet)
///         used by `PendlePTAdapter`: buy PT with a token, sell PT for a token
///         (pre-maturity), and redeem PT to a token (post-maturity).
/// @dev Struct/enum layouts are copied verbatim from
///      `pendle-core-v2-public` (`IPAllActionTypeV3.sol`,
///      `swap-aggregator/IPSwapAggregator.sol`, `limit/IPLimitRouter.sol`)
///      so ABI encoding matches the live router exactly. The adapter only ever
///      passes SY-native token paths (SwapType.NONE, no aggregator) and empty
///      limit-order data, but the full types are declared so encoding is correct.

// ------------------------------------------------------------------
// Swap aggregator types (swap-aggregator/IPSwapAggregator.sol)
// ------------------------------------------------------------------

enum SwapType {
    NONE,
    KYBERSWAP,
    ODOS,
    ETH_WETH,
    OKX,
    ONE_INCH,
    PARASWAP,
    RESERVE_2,
    RESERVE_3,
    RESERVE_4,
    RESERVE_5
}

struct SwapData {
    SwapType swapType;
    address extRouter;
    bytes extCalldata;
    bool needScale;
}

// ------------------------------------------------------------------
// Router action types (IPAllActionTypeV3.sol)
// ------------------------------------------------------------------

struct TokenInput {
    address tokenIn;
    uint256 netTokenIn;
    address tokenMintSy;
    address pendleSwap;
    SwapData swapData;
}

struct TokenOutput {
    address tokenOut;
    uint256 minTokenOut;
    address tokenRedeemSy;
    address pendleSwap;
    SwapData swapData;
}

struct ApproxParams {
    uint256 guessMin;
    uint256 guessMax;
    uint256 guessOffchain;
    uint256 maxIteration;
    uint256 eps;
}

// ------------------------------------------------------------------
// Limit-order types (limit/IPLimitRouter.sol) — only ever passed empty
// ------------------------------------------------------------------

enum OrderType {
    SY_FOR_PT,
    PT_FOR_SY,
    SY_FOR_YT,
    YT_FOR_SY
}

struct Order {
    uint256 salt;
    uint256 expiry;
    uint256 nonce;
    OrderType orderType;
    address token;
    address YT;
    address maker;
    address receiver;
    uint256 makingAmount;
    uint256 lnImpliedRate;
    uint256 failSafeRate;
    bytes permit;
}

struct FillOrderParams {
    Order order;
    bytes signature;
    uint256 makingAmount;
}

struct LimitOrderData {
    address limitRouter;
    uint256 epsSkipMarket;
    FillOrderParams[] normalFills;
    FillOrderParams[] flashFills;
    bytes optData;
}

interface IPendleRouter {
    /// @notice Buy PT with `input.netTokenIn` of `input.tokenIn`.
    /// @dev With a SY-native `tokenIn` (SwapType.NONE) the router mints SY from
    ///      the token then swaps SY->PT on the market AMM.
    function swapExactTokenForPt(
        address receiver,
        address market,
        uint256 minPtOut,
        ApproxParams calldata guessPtOut,
        TokenInput calldata input,
        LimitOrderData calldata limit
    ) external payable returns (uint256 netPtOut, uint256 netSyFee, uint256 netSyInterm);

    /// @notice Sell `exactPtIn` PT for `output.tokenOut` (pre-maturity, market price).
    function swapExactPtForToken(
        address receiver,
        address market,
        uint256 exactPtIn,
        TokenOutput calldata output,
        LimitOrderData calldata limit
    ) external returns (uint256 netTokenOut, uint256 netSyFee, uint256 netSyInterm);

    /// @notice Redeem `netPyIn` PT (post-maturity, par) to `output.tokenOut`.
    /// @dev After expiry only PT is required (no YT); router redeems PT->SY 1:1
    ///      then SY->tokenOut.
    function redeemPyToToken(
        address receiver,
        address YT,
        uint256 netPyIn,
        TokenOutput calldata output
    ) external returns (uint256 netTokenOut, uint256 netSyInterm);
}
