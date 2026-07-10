// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IStrategyAdapter} from "../interfaces/IStrategyAdapter.sol";
import {IStakedUSDeV2} from "../interfaces/IStakedUSDeV2.sol";
import {ICurveStableSwapNG} from "../interfaces/ICurveStableSwapNG.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EthenaSUSDeAdapter
/// @notice High-yield (SATELLITE, variable) SIXX adapter that parks USDC principal
///         in Ethena's staked synthetic dollar (sUSDe / StakedUSDeV2).
///
///         DISCLOSURE: principal is held in synthetic USD (Ethena sUSDe); yield is
///         variable and NOT principal-guaranteed; the native 7-day unstake cooldown
///         is bypassed via a DEX exit; the underlying carries depeg risk (Oct-2025
///         USDe briefly traded ~$0.65 on one CEX order book). This is a
///         "variable-yield, NOT capital-guaranteed" product and must never be
///         presented as a capital-guaranteed deposit.
///
/// @dev Flow (asset() == USDC, so the adapter plugs into a USDC-denominated SIXXVault):
///      - deposit:  vault sends USDC → Curve (USDC→USDe) → StakedUSDeV2.deposit(USDe) → hold sUSDe.
///      - withdraw: sUSDe → Curve (sUSDe→crvUSD) → Curve (crvUSD→USDC) → recipient.
///                  Native unstake/redeem (7-day cooldown) is NEVER used.
///      - totalAssets: StakedUSDeV2.convertToAssets(sUSDe) valued 1:1 in USDC, then
///                     discounted by the max-slippage haircut so the reported NAV is
///                     the CONSERVATIVE DEX-realizable value. This (a) keeps DEX spot
///                     price out of accounting — oracle-manipulation resistant, and
///                     (b) is required for the vault's `received >= toWithdraw`
///                     shortfall guard (M13-16) to hold on a full drain / migration:
///                     actual exit slippage (<0.5%) is smaller than the haircut, so a
///                     100% recall delivers at least the reported amount.
///      - harvest: no-op (sUSDe auto-appreciates via convertToAssets).
///
///      Route venues are immutable and validated against `coins()` at construction.
///      Migrating the DEX route (if Ethena liquidity moves) = deploy a fresh adapter
///      and rotate the vault to it (M-4). Coin indices are DERIVED, not passed, so
///      they cannot be misconfigured.
///
///      Ethereum mainnet reference addresses (verified on-chain 2026-07-10):
///        USDC        0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 (6 dec)
///        USDe        0x4c9EDD5852cd905f086C759E8383e09bff1E68B3 (18 dec)
///        sUSDe       0x9D39A5DE30e57443BfF2A8307A4256c8797A3497 (StakedUSDeV2, asset()==USDe)
///        crvUSD      0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E (18 dec, exit intermediary)
///        entryPool   0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72 (Curve USDe/USDC NG)
///        exitPool1   0x57064F49Ad7123C92560882a45518374ad982e85 (Curve crvUSD/sUSDe NG)
///        exitPool2   0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E (Curve USDC/crvUSD NG)
contract EthenaSUSDeAdapter is IStrategyAdapter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================
    // Constants
    // =========================================

    uint256 private constant MAX_BPS = 10_000;

    /// @notice Max tolerated slippage on any DEX leg, in bps (0.5%). Swaps whose
    ///         realized output falls below the convertToAssets-derived floor revert.
    uint256 public constant MAX_SLIPPAGE_BPS = 50;

    /// @notice USDe/sUSDe/crvUSD are 18-decimal; USDC is 6-decimal. Scale = 1e12.
    uint256 private constant USDE_TO_USDC_SCALE = 1e12;

    // =========================================
    // Immutables — tokens
    // =========================================

    /// @notice Underlying asset (USDC) — matches the connected USDC-denominated vault.
    address public immutable override asset;

    /// @notice USDe (Ethena synthetic dollar), the staking asset of sUSDe.
    IERC20 public immutable usde;

    /// @notice StakedUSDeV2 (sUSDe) — ERC-4626 over USDe. The held yield position.
    IStakedUSDeV2 public immutable susde;

    /// @notice crvUSD — intermediary hop token for the sUSDe→USDC exit route.
    IERC20 public immutable crvusd;

    // =========================================
    // Immutables — DEX route (Curve StableSwap-NG pools + derived indices)
    // =========================================

    ICurveStableSwapNG public immutable entryPool; // USDC <-> USDe
    ICurveStableSwapNG public immutable exitPool1; // sUSDe <-> crvUSD
    ICurveStableSwapNG public immutable exitPool2; // crvUSD <-> USDC

    int128 public immutable entryUsdcIndex;
    int128 public immutable entryUsdeIndex;
    int128 public immutable exit1SusdeIndex;
    int128 public immutable exit1CrvusdIndex;
    int128 public immutable exit2CrvusdIndex;
    int128 public immutable exit2UsdcIndex;

    // =========================================
    // Mutable State
    // =========================================

    /// @notice The single vault allowed to call deposit/withdraw.
    address public vault;

    /// @notice M-4: Pending vault for the 2-step rotation.
    address public pendingVault;

    /// @notice Governance address for admin functions.
    address public governance;

    /// @notice M-4: Pending governance for the 2-step rotation.
    address public pendingGovernance;

    /// @notice Representative APY in bps (sUSDe yield is variable; this is a
    ///         displayed estimate with a disclaimer, set by governance).
    uint256 private _estimatedApyBps;

    bool private _paused;

    // =========================================
    // Events
    // =========================================

    event VaultProposed(address indexed currentVault, address indexed pendingVault);
    event VaultAccepted(address indexed newVault);
    event GovernanceProposed(address indexed currentGovernance, address indexed pendingGovernance);
    event GovernanceAccepted(address indexed newGovernance);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event EstimatedAPYUpdated(uint256 oldBps, uint256 newBps);

    // =========================================
    // Constructor
    // =========================================

    /// @param asset_        USDC token address.
    /// @param susde_        StakedUSDeV2 (sUSDe) address; its asset() must be USDe.
    /// @param crvusd_       crvUSD token address (exit intermediary).
    /// @param entryPool_    Curve USDC/USDe pool.
    /// @param exitPool1_    Curve sUSDe/crvUSD pool.
    /// @param exitPool2_    Curve crvUSD/USDC pool.
    /// @param vault_        SIXXVault address.
    /// @param governance_   Governance EOA or Safe.
    /// @param estimatedApyBps_ Initial representative APY (bps).
    constructor(
        address asset_,
        address susde_,
        address crvusd_,
        address entryPool_,
        address exitPool1_,
        address exitPool2_,
        address vault_,
        address governance_,
        uint256 estimatedApyBps_
    ) {
        require(asset_ != address(0), "ADAPTER: zero asset");
        require(susde_ != address(0), "ADAPTER: zero susde");
        require(crvusd_ != address(0), "ADAPTER: zero crvusd");
        require(entryPool_ != address(0), "ADAPTER: zero entryPool");
        require(exitPool1_ != address(0), "ADAPTER: zero exitPool1");
        require(exitPool2_ != address(0), "ADAPTER: zero exitPool2");
        require(vault_ != address(0), "ADAPTER: zero vault");
        require(governance_ != address(0), "ADAPTER: zero governance");

        address usde_ = IStakedUSDeV2(susde_).asset();
        require(usde_ != address(0), "ADAPTER: zero usde");

        asset  = asset_;
        usde   = IERC20(usde_);
        susde  = IStakedUSDeV2(susde_);
        crvusd = IERC20(crvusd_);
        vault  = vault_;
        governance = governance_;
        _estimatedApyBps = estimatedApyBps_;

        entryPool = ICurveStableSwapNG(entryPool_);
        exitPool1 = ICurveStableSwapNG(exitPool1_);
        exitPool2 = ICurveStableSwapNG(exitPool2_);

        // Derive & bind coin indices from each pool's coins() so a misconfigured
        // pool (wrong tokens) reverts at deploy time rather than mis-routing funds.
        entryUsdcIndex   = _coinIndex(entryPool_, asset_);
        entryUsdeIndex   = _coinIndex(entryPool_, usde_);
        exit1SusdeIndex  = _coinIndex(exitPool1_, susde_);
        exit1CrvusdIndex = _coinIndex(exitPool1_, crvusd_);
        exit2CrvusdIndex = _coinIndex(exitPool2_, crvusd_);
        exit2UsdcIndex   = _coinIndex(exitPool2_, asset_);

        // Infinite approvals for the swap/stake legs.
        IERC20(asset_).forceApprove(entryPool_, type(uint256).max);      // USDC -> entryPool
        IERC20(usde_).forceApprove(susde_, type(uint256).max);           // USDe -> stake
        IERC20(susde_).forceApprove(exitPool1_, type(uint256).max);      // sUSDe -> exitPool1
        IERC20(crvusd_).forceApprove(exitPool2_, type(uint256).max);     // crvUSD -> exitPool2
    }

    /// @dev Returns the int128 index (0 or 1) of `token` in a 2-coin Curve pool,
    ///      reverting if the token is not one of the pool's two coins.
    function _coinIndex(address pool, address token) internal view returns (int128) {
        if (ICurveStableSwapNG(pool).coins(0) == token) return 0;
        if (ICurveStableSwapNG(pool).coins(1) == token) return 1;
        revert("ADAPTER: token not in pool");
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

    /// @notice Conservative DEX-realizable USDC value of the held sUSDe.
    /// @dev NAV = convertToAssets(sUSDe) [USDe, 18dec] valued 1:1 as USDC [6dec],
    ///      minus the max-slippage haircut. Uses ONLY the protocol-internal
    ///      convertToAssets (no DEX spot) → oracle-manipulation resistant. The
    ///      haircut makes this the amount actually recoverable via the DEX exit,
    ///      so the vault's shortfall guard holds on a 100% recall. Floors are
    ///      vault-favorable (NAV is never over-reported).
    function totalAssets() public view override returns (uint256) {
        uint256 shares = susde.balanceOf(address(this));
        if (shares == 0) return 0;
        // multiply-before-divide (more precise); final floor is vault-favorable.
        return (susde.convertToAssets(shares) * (MAX_BPS - MAX_SLIPPAGE_BPS))
            / MAX_BPS
            / USDE_TO_USDC_SCALE;
    }

    /// @notice Vault sends USDC here, then calls this: swap USDC→USDe, stake to sUSDe.
    function deposit(uint256 assets)
        external
        override
        onlyVault
        whenNotPaused
        nonReentrant
        returns (uint256 deposited)
    {
        require(assets > 0, "ADAPTER: zero amount");

        // Entry slippage floor: at least (1 - 0.5%) of par (1 USDC ~= 1 USDe).
        uint256 minUsde = (assets * USDE_TO_USDC_SCALE * (MAX_BPS - MAX_SLIPPAGE_BPS)) / MAX_BPS;

        uint256 usdeBefore = usde.balanceOf(address(this));
        entryPool.exchange(entryUsdcIndex, entryUsdeIndex, assets, minUsde);
        uint256 usdeOut = usde.balanceOf(address(this)) - usdeBefore;

        // Native stake (no cooldown on entry) → sUSDe held by this adapter.
        susde.deposit(usdeOut, address(this));

        deposited = assets;
        emit Deposited(assets, deposited);
    }

    /// @notice Sell just enough sUSDe on the DEX to deliver >= `assets` USDC to
    ///         `recipient`. Never uses the native 7-day unstake cooldown.
    /// @dev The final leg's `min_dy` enforces the end-to-end 0.5% slippage cap
    ///      against the convertToAssets fair value of the sUSDe sold; a breach
    ///      reverts. On a full drain (assets >= totalAssets) the entire sUSDe
    ///      balance is sold, which — because reported NAV is already haircut —
    ///      still clears the vault's `received >= toWithdraw` guard.
    function withdraw(uint256 assets, address recipient)
        external
        override
        onlyVault
        nonReentrant
        returns (uint256 withdrawn)
    {
        require(assets > 0, "ADAPTER: zero amount");
        require(recipient != address(0), "ADAPTER: zero recipient");

        uint256 shares = susde.balanceOf(address(this));
        require(shares > 0, "ADAPTER: no position");

        uint256 sharesToSell;
        if (assets >= totalAssets()) {
            // Full exit (recall-all / migration / emergency shutdown): sell everything.
            sharesToSell = shares;
        } else {
            // Sell sUSDe worth `assets` USDC grossed up by 1/(1-slippage) so that,
            // after slippage, the vault still receives at least `assets`.
            uint256 targetUsde =
                (assets * USDE_TO_USDC_SCALE * MAX_BPS) / (MAX_BPS - MAX_SLIPPAGE_BPS);
            sharesToSell = susde.convertToShares(targetUsde);
            if (sharesToSell > shares || sharesToSell == 0) sharesToSell = shares;
        }

        // Slippage floor for the whole route: >= (1 - 0.5%) of the sold sUSDe's
        // convertToAssets (fair) value, expressed in USDC. Multiply-before-divide
        // mirrors totalAssets() so drain-all's floor equals the reported NAV.
        uint256 minUsdcOut = (susde.convertToAssets(sharesToSell) * (MAX_BPS - MAX_SLIPPAGE_BPS))
            / MAX_BPS
            / USDE_TO_USDC_SCALE;

        // Hop 1: sUSDe -> crvUSD (intermediate min = 0; end-to-end min enforced on hop 2).
        uint256 crvBefore = crvusd.balanceOf(address(this));
        exitPool1.exchange(exit1SusdeIndex, exit1CrvusdIndex, sharesToSell, 0);
        uint256 crvOut = crvusd.balanceOf(address(this)) - crvBefore;

        // Hop 2: crvUSD -> USDC, reverting if total realized < minUsdcOut (slippage cap).
        uint256 usdcBefore = IERC20(asset).balanceOf(address(this));
        exitPool2.exchange(exit2CrvusdIndex, exit2UsdcIndex, crvOut, minUsdcOut);
        withdrawn = IERC20(asset).balanceOf(address(this)) - usdcBefore;

        IERC20(asset).safeTransfer(recipient, withdrawn);
        emit Withdrawn(assets, withdrawn, recipient);
    }

    /// @notice sUSDe auto-appreciates via convertToAssets — harvest is a no-op.
    function harvest() external override onlyVault returns (uint256) {
        emit Harvested(0);
        return 0;
    }

    // =========================================
    // Metadata
    // =========================================

    function name() external pure override returns (string memory) {
        return "SIXX High Yield - Ethena sUSDe";
    }

    function providerName() external pure override returns (string memory) {
        return "Ethena";
    }

    function adapterType() external pure override returns (string memory) {
        return "DeFi";
    }

    function riskLevel() external pure override returns (uint8) {
        return 4; // Layer-2 high-risk band (synthetic USD, variable yield, depeg risk)
    }

    /// @notice Representative variable APY in bps. See `description()` disclaimer.
    function estimatedAPY() external view override returns (uint256) {
        return _estimatedApyBps;
    }

    function requiredLockPeriod() external pure override returns (uint256) {
        return 0; // Instant DEX exit; native 7-day cooldown intentionally bypassed.
    }

    function isActive() external view override returns (bool) {
        return !_paused;
    }

    /// @notice Mandatory risk disclosure surfaced to integrators/UI.
    /// @dev Not part of IStrategyAdapter; deliberately added for this satellite product.
    function description() external pure returns (string memory) {
        return
            "principal in synthetic USD (Ethena sUSDe); yield variable, NOT principal-guaranteed; 7-day cooldown bypassed via instant market exit; depeg risk (Oct-2025 briefly $0.65)";
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

    /// @notice Update the displayed representative APY (variable product).
    function setEstimatedAPY(uint256 newBps) external {
        require(msg.sender == governance, "ADAPTER: not governance");
        emit EstimatedAPYUpdated(_estimatedApyBps, newBps);
        _estimatedApyBps = newBps;
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

    /// @notice Recover tokens accidentally sent here. Cannot touch the sUSDe
    ///         position, so user principal is never at risk.
    function rescueToken(address token, address to) external returns (uint256 amount) {
        require(msg.sender == governance, "ADAPTER: not governance");
        require(to != address(0), "ADAPTER: zero recipient");
        require(token != address(susde), "ADAPTER: cannot rescue position");
        amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }
}
