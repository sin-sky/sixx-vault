// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IStableSwapper} from "../interfaces/IStableSwapper.sol";
import {ICurveStableSwapNG} from "../interfaces/ICurveStableSwapNG.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title CurveStableSwapper
/// @notice Production `IStableSwapper` for the USDC / USDe / sUSDe legs shared by
///         the Ethena-family adapters (PendlePTAdapter's stable legs, and any
///         future adapter that injects a swapper). It standardizes, at the
///         infrastructure layer, the Curve StableSwap-NG routing that was
///         previously hardcoded per-adapter (see EthenaSUSDeAdapter Part A).
///
/// @dev Supported pairs (exact-in, atomic):
///        USDC  -> USDe   : entryPool  (USDC/USDe)                    [1 hop]
///        USDe  -> USDC   : entryPool  (USDe/USDC)                    [1 hop]
///        sUSDe -> USDC   : exitPool1 (sUSDe/crvUSD) -> exitPool2 (crvUSD/USDC)  [2 hops]
///        USDC  -> sUSDe  : exitPool2 (USDC/crvUSD)  -> exitPool1 (crvUSD/sUSDe) [2 hops]
///      No direct deep sUSDe/USDC or sUSDe/USDe Curve pool exists, so the sUSDe
///      legs route through crvUSD (the deepest venue), mirroring Part A.
///
/// @dev Settlement (per `IStableSwapper`): pulls `amountIn` of `tokenIn` from
///      `msg.sender` (caller must approve), executes the route, and MUST deliver
///      at least `minOut` of `tokenOut` to `to`. `minOut` is enforced ON-CHAIN in
///      two independent ways — Curve's own `min_dy` on the final hop AND a
///      balance-delta re-check here — so a thin/faulty pool reverts rather than
///      realizing an unbounded loss. All slippage/oracle policy lives in the
///      CALLER (the adapter sizes `minOut`); this contract is pure execution.
///
/// @dev Statelessness: the contract holds NO balances between calls. Each swap
///      consumes its entire input (single-hop, or 2-hop where the crvUSD
///      intermediate is fully spent by the second hop) and forwards the full
///      measured output, so no dust accumulates and no rescue path is needed.
///      There is no owner and no admin — nothing to compromise.
///
/// @dev Routing is IMMUTABLE (pools + derived indices fixed at construction).
///      This is safe because the consumer replaces the swapper via governance:
///      PendlePTAdapter.setSwapper(newSwapper) re-points to a freshly deployed
///      swapper if Curve liquidity migrates — identical to Part A's "immutable
///      route, redeploy-to-migrate" model. Indices are DERIVED from each pool's
///      `coins()` at deploy time, so a misconfigured pool reverts at construction
///      rather than mis-routing user funds.
///
/// @dev Ethereum mainnet reference wiring (verified on-chain 2026-07-10):
///        USDC      0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 (6 dec)
///        USDe      0x4c9EDD5852cd905f086C759E8383e09bff1E68B3 (18 dec)
///        sUSDe     0x9D39A5DE30e57443BfF2A8307A4256c8797A3497 (StakedUSDeV2, 18 dec)
///        crvUSD    0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E (18 dec, intermediary)
///        entryPool 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72 (Curve USDe/USDC NG)
///        exitPool1 0x57064F49Ad7123C92560882a45518374ad982e85 (Curve crvUSD/sUSDe NG)
///        exitPool2 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E (Curve USDC/crvUSD NG)
contract CurveStableSwapper is IStableSwapper, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================
    // Immutables — tokens
    // =========================================

    address public immutable usdc;   // 6 dec
    address public immutable usde;    // 18 dec
    address public immutable susde;   // 18 dec (StakedUSDeV2)
    address public immutable crvusd;  // 18 dec (2-hop intermediary)

    // =========================================
    // Immutables — Curve StableSwap-NG venues
    // =========================================

    ICurveStableSwapNG public immutable entryPool; // USDC <-> USDe
    ICurveStableSwapNG public immutable exitPool1; // sUSDe <-> crvUSD
    ICurveStableSwapNG public immutable exitPool2; // USDC  <-> crvUSD

    // Coin indices derived from each pool's coins() at construction.
    int128 public immutable entryUsdcIndex;
    int128 public immutable entryUsdeIndex;
    int128 public immutable exit1SusdeIndex;
    int128 public immutable exit1CrvusdIndex;
    int128 public immutable exit2UsdcIndex;
    int128 public immutable exit2CrvusdIndex;

    // =========================================
    // Events
    // =========================================

    event Swapped(
        address indexed tokenIn,
        address indexed tokenOut,
        address indexed to,
        uint256 amountIn,
        uint256 amountOut
    );

    // =========================================
    // Constructor
    // =========================================

    /// @param usdc_      USDC token (6 dec)
    /// @param usde_      USDe token (18 dec)
    /// @param susde_     StakedUSDeV2 / sUSDe token (18 dec)
    /// @param crvusd_    crvUSD token (18 dec, 2-hop intermediary)
    /// @param entryPool_ Curve USDC/USDe NG pool
    /// @param exitPool1_ Curve sUSDe/crvUSD NG pool
    /// @param exitPool2_ Curve USDC/crvUSD NG pool
    constructor(
        address usdc_,
        address usde_,
        address susde_,
        address crvusd_,
        address entryPool_,
        address exitPool1_,
        address exitPool2_
    ) {
        require(usdc_      != address(0), "SWAPPER: zero usdc");
        require(usde_      != address(0), "SWAPPER: zero usde");
        require(susde_     != address(0), "SWAPPER: zero susde");
        require(crvusd_    != address(0), "SWAPPER: zero crvusd");
        require(entryPool_ != address(0), "SWAPPER: zero entryPool");
        require(exitPool1_ != address(0), "SWAPPER: zero exitPool1");
        require(exitPool2_ != address(0), "SWAPPER: zero exitPool2");

        usdc   = usdc_;
        usde   = usde_;
        susde  = susde_;
        crvusd = crvusd_;

        entryPool = ICurveStableSwapNG(entryPool_);
        exitPool1 = ICurveStableSwapNG(exitPool1_);
        exitPool2 = ICurveStableSwapNG(exitPool2_);

        // Derive & bind coin indices from each pool's coins() so a misconfigured
        // pool (wrong tokens) reverts at deploy time rather than mis-routing funds.
        entryUsdcIndex   = _coinIndex(entryPool_, usdc_);
        entryUsdeIndex   = _coinIndex(entryPool_, usde_);
        exit1SusdeIndex  = _coinIndex(exitPool1_, susde_);
        exit1CrvusdIndex = _coinIndex(exitPool1_, crvusd_);
        exit2UsdcIndex   = _coinIndex(exitPool2_, usdc_);
        exit2CrvusdIndex = _coinIndex(exitPool2_, crvusd_);

        // Standing approvals: each pool pulls exactly the tokens it can consume.
        //   entryPool: USDC (USDC->USDe), USDe (USDe->USDC)
        //   exitPool1: sUSDe (sUSDe->crvUSD), crvUSD (crvUSD->sUSDe)
        //   exitPool2: crvUSD (crvUSD->USDC), USDC (USDC->crvUSD)
        IERC20(usdc_).forceApprove(entryPool_, type(uint256).max);
        IERC20(usde_).forceApprove(entryPool_, type(uint256).max);
        IERC20(susde_).forceApprove(exitPool1_, type(uint256).max);
        IERC20(crvusd_).forceApprove(exitPool1_, type(uint256).max);
        IERC20(crvusd_).forceApprove(exitPool2_, type(uint256).max);
        IERC20(usdc_).forceApprove(exitPool2_, type(uint256).max);
    }

    /// @dev int128 index (0 or 1) of `token` in a 2-coin Curve pool; reverts if
    ///      the token is not one of the pool's two coins.
    function _coinIndex(address pool, address token) internal view returns (int128) {
        if (ICurveStableSwapNG(pool).coins(0) == token) return 0;
        if (ICurveStableSwapNG(pool).coins(1) == token) return 1;
        revert("SWAPPER: token not in pool");
    }

    // =========================================
    // IStableSwapper
    // =========================================

    /// @inheritdoc IStableSwapper
    /// @dev Pulls `amountIn` of `tokenIn` from `msg.sender`, routes via Curve, and
    ///      delivers `amountOut >= minOut` of `tokenOut` to `to` (reverting
    ///      otherwise). `amountOut` is measured by balance delta on `tokenOut` held
    ///      by this contract, so it is exact and immune to any pre-existing dust.
    ///      nonReentrant: Curve NG plain-ERC20 pools have no swap callback, but the
    ///      guard is kept as defense-in-depth against any exotic token hook.
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address to
    ) external override nonReentrant returns (uint256 amountOut) {
        require(amountIn > 0, "SWAPPER: zero amountIn");
        require(to != address(0), "SWAPPER: zero to");

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        if (tokenIn == usdc && tokenOut == usde) {
            // 1 hop: USDC -> USDe. Curve enforces min_dy == minOut.
            entryPool.exchange(entryUsdcIndex, entryUsdeIndex, amountIn, minOut);
        } else if (tokenIn == usde && tokenOut == usdc) {
            // 1 hop: USDe -> USDC.
            entryPool.exchange(entryUsdeIndex, entryUsdcIndex, amountIn, minOut);
        } else if (tokenIn == susde && tokenOut == usdc) {
            // 2 hops: sUSDe -> crvUSD -> USDC. End-to-end min enforced on hop 2.
            uint256 crvOut = _hopThroughCrvusd(exitPool1, exit1SusdeIndex, exit1CrvusdIndex, amountIn);
            exitPool2.exchange(exit2CrvusdIndex, exit2UsdcIndex, crvOut, minOut);
        } else if (tokenIn == usdc && tokenOut == susde) {
            // 2 hops: USDC -> crvUSD -> sUSDe. End-to-end min enforced on hop 2.
            uint256 crvOut = _hopThroughCrvusd(exitPool2, exit2UsdcIndex, exit2CrvusdIndex, amountIn);
            exitPool1.exchange(exit1CrvusdIndex, exit1SusdeIndex, crvOut, minOut);
        } else {
            revert("SWAPPER: unsupported pair");
        }

        // Independent on-chain floor: measured output must clear minOut. This is
        // belt-and-suspenders on top of Curve's own min_dy on the final hop.
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        require(amountOut >= minOut, "SWAPPER: min out");

        IERC20(tokenOut).safeTransfer(to, amountOut);
        emit Swapped(tokenIn, tokenOut, to, amountIn, amountOut);
    }

    /// @dev First hop into crvUSD. Returns the exact crvUSD received (balance
    ///      delta), which the caller feeds as the second hop's `dx` so no crvUSD
    ///      dust is left behind. `min_dy = 0` here; the end-to-end floor is
    ///      enforced on the second hop plus the balance-delta re-check in swap().
    function _hopThroughCrvusd(
        ICurveStableSwapNG pool,
        int128 iFrom,
        int128 iCrvusd,
        uint256 amountIn
    ) internal returns (uint256 crvOut) {
        uint256 crvBefore = IERC20(crvusd).balanceOf(address(this));
        pool.exchange(iFrom, iCrvusd, amountIn, 0);
        crvOut = IERC20(crvusd).balanceOf(address(this)) - crvBefore;
    }
}
