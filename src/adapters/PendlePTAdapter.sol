// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IStrategyAdapter} from "../interfaces/IStrategyAdapter.sol";
import {
    IPendleRouter,
    TokenInput,
    TokenOutput,
    ApproxParams,
    LimitOrderData,
    SwapData,
    SwapType
} from "../interfaces/IPendleRouter.sol";
import {IPendleMarket, IPendlePrincipalToken, IPendleSY, IPPtOracle, ISUSDeConvert} from "../interfaces/IPendleCore.sol";
import {IStableSwapper} from "../interfaces/IStableSwapper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PendlePTAdapter
/// @notice SIXX fixed-yield adapter for a Pendle Principal Token (PT-sUSDe).
///         The yield is fixed ONLY if held to maturity; principal is NOT
///         guaranteed. Principal is held as sUSDe (Ethena); an early exit is at
///         market price and can be below your deposit, and an Ethena/sUSDe depeg
///         can reduce principal even at maturity.
///
/// @dev Vault asset is USDC. PT is NOT ERC-4626 (maturity-bearing zero-coupon), so
///      this is a bespoke adapter rather than the shared ERC4626Adapter.
///
///      Money path (SY-native; USDC is not accepted by the SY directly —
///      SY.getTokensIn() = [USDe, sUSDe], SY.getTokensOut() = [sUSDe]):
///        deposit : USDC --(swapper)--> USDe --(Pendle Router)--> PT           (< maturity only)
///        exit    : PT --(Pendle Router)--> sUSDe --(swapper)--> USDC --> recipient
///                    pre-maturity  = swapExactPtForToken (market price, slippage bound)
///                    post-maturity = redeemPyToToken     (par redemption)
///
///      Accounting (totalAssets, USDC 6-dec):
///        pre-maturity  = min(Pendle TWAP PtToAssetRate, 1e18) * ptBal, USDe≈USDC par
///        post-maturity = par (rate = 1e18)
///      The TWAP oracle (not spot) is the only external price in the accounting
///      core, capped at par so it can never over-mark. Market spot never enters
///      accounting (ADR-004 §4). Truncation is always vault-favorable.
///
/// @dev Ethereum mainnet reference deployment (PT-sUSDe, expiry 2026-08-13):
///        USDC        0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 (6 dec)
///        USDe        0x4c9EDD5852cd905f086C759E8383e09bff1E68B3 (18 dec)
///        sUSDe       0x9D39A5DE30e57443BfF2A8307A4256c8797A3497 (StakedUSDeV2)
///        Market      0x177768caf9d0e036725a51d3f60d7e20f2d4d194
///        PT          0x5A19fa369F2895dCD8d2cEE62E4Ceae58eF92BBb
///        SY          0xBF98480425A29197e5d99D003017f63a1e595D02
///        YT          0x45A699A11A4a17fe0931EF3ceA4BFc3235e659F2
///        Router V4   0x888888888889758F76e7103c6CbF23ABbF58F946
///        PT Oracle   0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2
contract PendlePTAdapter is IStrategyAdapter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================
    // Constants
    // =========================================

    uint256 internal constant BPS = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    /// @notice Hard ceiling on the per-leg slippage tolerance governance can set.
    uint256 internal constant MAX_SLIPPAGE_BPS = 300; // 3%
    /// @notice Padding above the analytical PT upper bound for the router's
    ///         binary-search guessMax (covers TWAP-vs-spot divergence).
    uint256 internal constant GUESS_MAX_PAD_BPS = 200; // +2%

    /// @dev Pendle token set resolved on-chain at construction (single memory
    ///      slot keeps the constructor out of "stack too deep").
    struct ResolvedTokens {
        address sy;
        address pt;
        address yt;
        address usde;
        address susde;
        uint256 expiry;
    }

    // =========================================
    // Immutables
    // =========================================

    /// @notice Underlying vault asset (USDC, 6 dec)
    address public immutable override asset;

    /// @notice SY-native input token fed to the router (USDe, 18 dec)
    address public immutable usde;

    /// @notice SY yield token received on exit (sUSDe, 18 dec)
    address public immutable susde;

    IPendleRouter public immutable pendleRouter;
    IPPtOracle    public immutable ptOracle;
    address       public immutable market;
    IERC20        public immutable pt;
    address       public immutable yt;
    address       public immutable sy;

    /// @notice PT maturity (unix seconds). At/after this, PT redeems 1:1 to asset.
    uint256 public immutable expiry;

    /// @notice TWAP window (seconds) used for PtToAssetRate; validated ready at deploy.
    uint32 public immutable twapDuration;

    // =========================================
    // Mutable State
    // =========================================

    /// @notice Injected stablecoin swapper (USDC<->USDe, sUSDe->USDC)
    IStableSwapper public swapper;

    /// @notice Per-leg slippage tolerance in bps (default 0.5%)
    uint256 public slippageBps;

    address public vault;
    address public pendingVault;
    address public governance;
    address public pendingGovernance;

    bool private _paused;

    // =========================================
    // Events
    // =========================================

    event VaultProposed(address indexed currentVault, address indexed pendingVault);
    event VaultAccepted(address indexed newVault);
    event GovernanceProposed(address indexed currentGovernance, address indexed pendingGovernance);
    event GovernanceAccepted(address indexed newGovernance);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event SlippageUpdated(uint256 oldBps, uint256 newBps);
    event SwapperUpdated(address indexed oldSwapper, address indexed newSwapper);

    // =========================================
    // Constructor
    // =========================================

    /// @param asset_        USDC token address
    /// @param market_       Pendle PT-sUSDe market
    /// @param pendleRouter_ Pendle Router V4
    /// @param ptOracle_     Pendle PT TWAP oracle (PendlePYLpOracle)
    /// @param swapper_      Stablecoin swapper (USDC<->USDe, sUSDe->USDC)
    /// @param twapDuration_ TWAP window in seconds (e.g. 900)
    /// @param vault_        SIXXVault (USDC) address
    /// @param governance_   Governance EOA or Safe
    constructor(
        address asset_,
        address market_,
        address pendleRouter_,
        address ptOracle_,
        address swapper_,
        uint32  twapDuration_,
        address vault_,
        address governance_
    ) {
        require(asset_        != address(0), "ADAPTER: zero asset");
        require(market_       != address(0), "ADAPTER: zero market");
        require(pendleRouter_ != address(0), "ADAPTER: zero router");
        require(ptOracle_     != address(0), "ADAPTER: zero oracle");
        require(swapper_      != address(0), "ADAPTER: zero swapper");
        require(twapDuration_ >= 900,        "ADAPTER: twap < 15min"); // Part B P3 (OR2): min 15-min TWAP
        require(vault_        != address(0), "ADAPTER: zero vault");
        require(governance_   != address(0), "ADAPTER: zero governance");

        // Resolve and cross-check the Pendle token set on-chain (single memory
        // slot keeps the constructor out of "stack too deep").
        ResolvedTokens memory r = _resolveAndValidate(market_, ptOracle_, twapDuration_);

        asset        = asset_;
        market       = market_;
        pendleRouter = IPendleRouter(pendleRouter_);
        ptOracle     = IPPtOracle(ptOracle_);
        swapper      = IStableSwapper(swapper_);
        twapDuration = twapDuration_;
        vault        = vault_;
        governance   = governance_;

        sy     = r.sy;
        pt     = IERC20(r.pt);
        yt     = r.yt;
        usde   = r.usde;
        susde  = r.susde;
        expiry = r.expiry;

        slippageBps = 50; // 0.5% default (matches Part A)

        _initApprovals(asset_, r.susde, r.usde, r.pt, swapper_, pendleRouter_);
    }

    /// @dev Grant the standing approvals in a separate frame (constructor stack).
    ///      swapper pulls USDC (deposit) + sUSDe (withdraw); router pulls USDe
    ///      (buy PT) + PT (sell / redeem PT).
    function _initApprovals(
        address asset_,
        address susde_,
        address usde_,
        address pt_,
        address swapper_,
        address router_
    ) private {
        IERC20(asset_).forceApprove(swapper_, type(uint256).max);
        IERC20(susde_).forceApprove(swapper_, type(uint256).max);
        IERC20(usde_).forceApprove(router_, type(uint256).max);
        IERC20(pt_).forceApprove(router_, type(uint256).max);
    }

    /// @dev Reads Pendle's token set from the market, cross-checks PT<->SY<->YT and
    ///      expiry consistency, resolves the SY input (USDe) / output (sUSDe) tokens,
    ///      and requires the TWAP oracle to already be warmed for `twapDuration_`.
    ///      Kept as a separate call frame to avoid constructor stack-too-deep.
    function _resolveAndValidate(address market_, address ptOracle_, uint32 twapDuration_)
        private
        view
        returns (ResolvedTokens memory r)
    {
        (r.sy, r.pt, r.yt) = IPendleMarket(market_).readTokens();
        require(r.sy != address(0) && r.pt != address(0) && r.yt != address(0), "ADAPTER: bad market");
        require(IPendlePrincipalToken(r.pt).SY() == r.sy, "ADAPTER: PT/SY mismatch");
        require(IPendlePrincipalToken(r.pt).YT() == r.yt, "ADAPTER: PT/YT mismatch");

        r.expiry = IPendleMarket(market_).expiry();
        require(r.expiry == IPendlePrincipalToken(r.pt).expiry(), "ADAPTER: expiry mismatch");
        require(r.expiry > block.timestamp, "ADAPTER: already matured");

        r.susde = IPendleSY(r.sy).yieldToken();
        (, r.usde,) = IPendleSY(r.sy).assetInfo();
        require(r.susde != address(0) && r.usde != address(0), "ADAPTER: bad SY");

        (bool grow,, bool oldestOk) = IPPtOracle(ptOracle_).getOracleState(market_, twapDuration_);
        require(!grow && oldestOk, "ADAPTER: oracle not ready");
    }

    // =========================================
    // Modifiers
    // =========================================

    modifier onlyVault() {
        require(msg.sender == vault, "ADAPTER: only vault");
        _;
    }

    modifier whenNotPaused() {
        require(!_paused, "ADAPTER: paused");
        _;
    }

    // =========================================
    // Core: IStrategyAdapter
    // =========================================

    /// @notice USDC value of the held PT plus any idle USDC dust.
    /// @dev Pre-maturity: PT marked at the manipulation-resistant Pendle TWAP,
    ///      capped at par. Post-maturity: par (PT redeems 1:1). USDe≈USDC 1:1
    ///      (depeg is a disclosed risk, not priced by a spot). All divisions
    ///      truncate → conservative (under-reports), i.e. vault-favorable.
    function totalAssets() external view override returns (uint256) {
        uint256 idle = IERC20(asset).balanceOf(address(this));
        uint256 ptBal = pt.balanceOf(address(this));
        if (ptBal == 0) return idle;
        return _usdeToUsdc(_ptValueInUsde(ptBal)) + idle;
    }

    /// @notice Vault sends USDC here, then calls this. USDC -> USDe -> PT.
    /// @dev New deposits are only meaningful before maturity (the market AMM is
    ///      dead after expiry). Two slippage bounds guard the two legs.
    function deposit(uint256 assets)
        external override onlyVault whenNotPaused nonReentrant returns (uint256 deposited)
    {
        require(assets > 0, "ADAPTER: zero amount");
        require(block.timestamp < expiry, "ADAPTER: matured");

        // Leg 1: USDC -> USDe (par-referenced min-out).
        uint256 usdeMin = _applySlip(_usdcToUsde(assets));
        uint256 usdeIn = swapper.swap(asset, usde, assets, usdeMin, address(this));
        require(usdeIn > 0, "ADAPTER: no usde");

        // Leg 2: USDe -> PT via the market AMM.
        uint256 rate = _ptToAssetRate();                 // PT->USDe, <1e18 pre-maturity
        uint256 expPt = (usdeIn * 1e18) / rate;          // analytical upper bound on PT out
        uint256 minPtOut = _applySlip(expPt);

        ApproxParams memory guess = ApproxParams({
            guessMin: 0,
            guessMax: (expPt * (BPS + GUESS_MAX_PAD_BPS)) / BPS,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e14 // 0.01%
        });
        TokenInput memory input = TokenInput({
            tokenIn: usde,
            netTokenIn: usdeIn,
            tokenMintSy: usde,
            pendleSwap: address(0),
            swapData: SwapData({swapType: SwapType.NONE, extRouter: address(0), extCalldata: "", needScale: false})
        });

        pendleRouter.swapExactTokenForPt(address(this), market, minPtOut, guess, input, _emptyLimit());

        deposited = assets;
        emit Deposited(assets, deposited);
    }

    /// @notice Liquidate PT to deliver USDC to `recipient`.
    /// @dev Full exit (assets >= totalAssets) liquidates the entire PT balance and
    ///      forwards everything realized. Partial exit liquidates a slippage-buffered
    ///      proportional slice. Pre-maturity uses the AMM (market price); post-maturity
    ///      redeems at par. The vault's own `received >= toWithdraw` guard reverts a
    ///      request the AMM cannot satisfy (early-exit-below-mark is a disclosed risk).
    function withdraw(uint256 assets, address recipient)
        external override onlyVault nonReentrant returns (uint256 withdrawn)
    {
        require(assets > 0, "ADAPTER: zero amount");
        require(recipient != address(0), "ADAPTER: zero recipient");

        // Serve from idle USDC first.
        uint256 idle0 = IERC20(asset).balanceOf(address(this));
        if (idle0 >= assets) {
            IERC20(asset).safeTransfer(recipient, assets);
            emit Withdrawn(assets, assets, recipient);
            return assets;
        }

        uint256 ptBal = pt.balanceOf(address(this));
        require(ptBal > 0, "ADAPTER: no position");

        uint256 ta = _usdeToUsdc(_ptValueInUsde(ptBal)) + idle0; // == totalAssets()
        bool fullExit = assets >= ta;

        uint256 ptToLiq;
        if (fullExit) {
            ptToLiq = ptBal;
        } else {
            uint256 ptMarkUsdc = ta - idle0;                       // USDC value backed by PT
            uint256 targetFromPt = assets - idle0;
            // Buffer the target up so realized (net of two swap legs) can reach it.
            uint256 buffered = (targetFromPt * BPS) / (BPS - slippageBps);
            ptToLiq = (ptBal * buffered) / ptMarkUsdc;
            if (ptToLiq > ptBal) ptToLiq = ptBal;
            require(ptToLiq > 0, "ADAPTER: dust");
        }

        // Leg 1: PT -> sUSDe (min-out from the marked USDe value of the slice).
        uint256 susdeMin = _applySlip(_usdeToSusde(_ptValueInUsde(ptToLiq)));
        TokenOutput memory out = TokenOutput({
            tokenOut: susde,
            minTokenOut: susdeMin,
            tokenRedeemSy: susde,
            pendleSwap: address(0),
            swapData: SwapData({swapType: SwapType.NONE, extRouter: address(0), extCalldata: "", needScale: false})
        });

        uint256 susdeOut;
        if (block.timestamp >= expiry) {
            (susdeOut,) = pendleRouter.redeemPyToToken(address(this), yt, ptToLiq, out);
        } else {
            (susdeOut,,) = pendleRouter.swapExactPtForToken(address(this), market, ptToLiq, out, _emptyLimit());
        }

        // Leg 2: sUSDe -> USDC.
        uint256 usdcMin = _applySlip(_usdeToUsdc(_susdeToUsde(susdeOut)));
        swapper.swap(susde, asset, susdeOut, usdcMin, address(this));

        // Deliver: full exit forwards everything realized; partial caps at `assets`
        // and leaves any surplus idle for the next call.
        uint256 bal = IERC20(asset).balanceOf(address(this));
        uint256 toSend = fullExit ? bal : (bal < assets ? bal : assets);
        IERC20(asset).safeTransfer(recipient, toSend);
        withdrawn = toSend;
        emit Withdrawn(assets, withdrawn, recipient);
    }

    /// @notice Fixed yield accrues as PT converges to par — captured by
    ///         totalAssets(), so harvest is a no-op.
    function harvest() external override onlyVault returns (uint256) {
        emit Harvested(0);
        return 0;
    }

    // =========================================
    // Internal math (all truncation is vault-favorable)
    // =========================================

    /// @dev PT->USDe rate (1e18 = par). Post-maturity = par; pre-maturity = TWAP
    ///      capped at par so the mark can never exceed redemption value.
    function _ptToAssetRate() internal view returns (uint256) {
        if (block.timestamp >= expiry) return 1e18;
        uint256 twap = ptOracle.getPtToAssetRate(market, twapDuration);
        return twap > 1e18 ? 1e18 : twap;
    }

    /// @dev USDe (18 dec) value of `ptAmount` (18 dec) at the marked rate.
    function _ptValueInUsde(uint256 ptAmount) internal view returns (uint256) {
        return (ptAmount * _ptToAssetRate()) / 1e18;
    }

    /// @dev USDe (18 dec) -> USDC (6 dec), par 1:1, truncated.
    function _usdeToUsdc(uint256 usdeAmount) internal pure returns (uint256) {
        return usdeAmount / 1e12;
    }

    /// @dev USDC (6 dec) -> USDe (18 dec), par 1:1.
    function _usdcToUsde(uint256 usdcAmount) internal pure returns (uint256) {
        return usdcAmount * 1e12;
    }

    /// @dev USDe value (18 dec) -> sUSDe amount (18 dec) via the protocol-internal
    ///      ERC-4626 rate (not a spot). Used only to size a conservative min-out.
    function _usdeToSusde(uint256 usdeAmount) internal view returns (uint256) {
        uint256 usdePerSusde = ISUSDeConvert(susde).convertToAssets(1e18);
        return (usdeAmount * 1e18) / usdePerSusde;
    }

    /// @dev sUSDe amount (18 dec) -> USDe value (18 dec) via the internal rate.
    function _susdeToUsde(uint256 susdeAmount) internal view returns (uint256) {
        return ISUSDeConvert(susde).convertToAssets(susdeAmount);
    }

    function _applySlip(uint256 x) internal view returns (uint256) {
        return (x * (BPS - slippageBps)) / BPS;
    }

    function _emptyLimit() internal pure returns (LimitOrderData memory limit) {
        // zero-initialized: limitRouter = address(0) (unused), empty fill arrays.
    }

    // =========================================
    // Metadata
    // =========================================

    function name() external pure override returns (string memory) {
        return "SIXX Fixed Yield - Pendle PT-sUSDe";
    }

    function providerName() external pure override returns (string memory) {
        return "Pendle (PT-sUSDe / Ethena)";
    }

    function adapterType() external pure override returns (string memory) {
        return "DeFi";
    }

    /// @notice Mandatory risk disclosure surfaced to integrators/UI. Not part of
    ///         IStrategyAdapter; deliberately added for this satellite product.
    function description() external pure returns (string memory) {
        return
            "principal held as sUSDe (Ethena synthetic USD); yield fixed ONLY if held to maturity, NOT principal-guaranteed; early exit at market price can be below deposit; depeg can reduce principal even at maturity";
    }

    /// @notice Layer-2 high-risk band: Ethena synthetic-dollar underlying + maturity
    ///         structure. Fixed only if held to maturity; early exit at market
    ///         price (can be below deposit).
    function riskLevel() external pure override returns (uint8) {
        return 4;
    }

    /// @notice Live implied fixed APY (bps) to maturity, derived from the PT TWAP.
    /// @dev gainToPar = 1/rate - 1 (annualized over the remaining term). Returns 0
    ///      at/after maturity or if the oracle is unavailable.
    function estimatedAPY() external view override returns (uint256) {
        if (block.timestamp >= expiry) return 0;
        try ptOracle.getPtToAssetRate(market, twapDuration) returns (uint256 rate) {
            if (rate == 0 || rate >= 1e18) return 0;
            uint256 gainFrac = (1e18 * 1e18) / rate - 1e18; // fractional gain to par, 1e18-scaled
            uint256 remaining = expiry - block.timestamp;
            return (gainFrac * SECONDS_PER_YEAR * BPS) / remaining / 1e18;
        } catch {
            return 0;
        }
    }

    /// @notice 0 = no hard time-lock (early exit is available anytime at market
    ///         price). The maturity horizon and early-exit-below-deposit economics
    ///         are disclosed at the product layer, not encoded as a hard lock here.
    function requiredLockPeriod() external pure override returns (uint256) {
        return 0;
    }

    /// @notice Active only while not paused and before maturity (deposits stop at
    ///         maturity; the position becomes withdraw-only pending re-investment).
    function isActive() external view override returns (bool) {
        return !_paused && block.timestamp < expiry;
    }

    // =========================================
    // Circuit Breaker
    // =========================================

    function pause() external override {
        require(msg.sender == governance || msg.sender == vault, "ADAPTER: unauthorized");
        _paused = true;
        emit Paused();
    }

    function unpause() external override {
        require(msg.sender == governance, "ADAPTER: only governance");
        _paused = false;
        emit Unpaused();
    }

    // =========================================
    // Admin
    // =========================================

    /// @notice Update per-leg slippage tolerance (bps), capped at MAX_SLIPPAGE_BPS.
    function setSlippageBps(uint256 newBps) external {
        require(msg.sender == governance, "ADAPTER: not governance");
        require(newBps <= MAX_SLIPPAGE_BPS, "ADAPTER: slippage too high");
        emit SlippageUpdated(slippageBps, newBps);
        slippageBps = newBps;
    }

    /// @notice Swap out the injected stablecoin swapper (e.g. re-route Curve pools).
    function setSwapper(address newSwapper) external {
        require(msg.sender == governance, "ADAPTER: not governance");
        require(newSwapper != address(0), "ADAPTER: zero swapper");
        address old = address(swapper);
        // Revoke the old approvals, grant to the new swapper.
        IERC20(asset).forceApprove(old, 0);
        IERC20(susde).forceApprove(old, 0);
        swapper = IStableSwapper(newSwapper);
        IERC20(asset).forceApprove(newSwapper, type(uint256).max);
        IERC20(susde).forceApprove(newSwapper, type(uint256).max);
        emit SwapperUpdated(old, newSwapper);
    }

    // M-4: 2-step vault rotation
    function proposeVault(address newVault) external {
        require(msg.sender == governance, "ADAPTER: not governance");
        require(newVault != address(0), "ADAPTER: zero vault");
        pendingVault = newVault;
        emit VaultProposed(vault, newVault);
    }

    function acceptVault() external {
        require(msg.sender == pendingVault, "ADAPTER: not pending vault");
        emit VaultAccepted(pendingVault);
        vault = pendingVault;
        pendingVault = address(0);
    }

    // M-4: 2-step governance rotation
    function proposeGovernance(address newGovernance) external {
        require(msg.sender == governance, "ADAPTER: not governance");
        require(newGovernance != address(0), "ADAPTER: zero address");
        pendingGovernance = newGovernance;
        emit GovernanceProposed(governance, newGovernance);
    }

    function acceptGovernance() external {
        require(msg.sender == pendingGovernance, "ADAPTER: not pending governance");
        emit GovernanceAccepted(pendingGovernance);
        governance = pendingGovernance;
        pendingGovernance = address(0);
    }

    // =========================================
    // ADP-2: Token Rescue
    // =========================================

    /// @notice Recover tokens accidentally sent here. Cannot touch the PT position
    ///         or idle USDC (user principal), so principal is never at risk.
    function rescueToken(address token, address to) external returns (uint256 amount) {
        require(msg.sender == governance, "ADAPTER: not governance");
        require(to != address(0), "ADAPTER: zero recipient");
        require(token != address(pt), "ADAPTER: cannot rescue position");
        require(token != asset, "ADAPTER: cannot rescue principal");
        amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }
}
