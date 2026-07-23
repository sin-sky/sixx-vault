// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IStrategyAdapter} from "../interfaces/IStrategyAdapter.sol";
import {IWETH9} from "../interfaces/IWETH9.sol";
import {IListaStakeManager} from "../interfaces/IListaStakeManager.sol";
import {IPancakeV3Router} from "../interfaces/IPancakeV3Router.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title BNBStakingAdapter
/// @notice SIXX "BNB 運用" adapter. Stakes WBNB principal into Lista DAO liquid
///         staking and holds the non-rebasing slisBNB token as its yield position.
///         Yield is the BNB validator reward, surfaced through slisBNB's
///         monotonically increasing BNB-per-token exchange rate.
///
/// @dev asset() == WBNB, so this adapter plugs into a WBNB-denominated SIXXVault.
///
///      ── Protocol selection: Lista DAO slisBNB ─────────────────────────────
///      Chosen against the SIXX adoption bar (third-party audit / >1yr live /
///      TVL > $50M / clear provenance):
///        • TVL: StakeManager.getTotalPooledBnb() ~= 945,000 BNB (~$550M+) on
///          2026-07-23 — an order of magnitude above the $50M bar and the largest
///          BNB LST.
///        • Audits: multiple third-party reviews (PeckShield, SlowMist, Salus)
///          across the Synclub/Lista StakeManager lineage.
///        • Live: continuous operation since the Synclub launch (2023), >1yr.
///        • Provenance: Lista DAO (Binance Labs-backed), widely integrated as
///          collateral (e.g. Venus). slisBNB is non-rebasing and value-accruing —
///          the same clean accounting shape as wstETH.
///      Alternatives considered: Ankr ankrBNB (smaller TVL / thinner exit
///      liquidity), Stader BNBx (smaller TVL). Lista wins on depth and integration.
///
///      ── Flow ──────────────────────────────────────────────────────────────
///      deposit:  WBNB --withdraw--> BNB --StakeManager.deposit{value}--> slisBNB
///                (minted at exchange rate, NO slippage) --> hold slisBNB.
///      withdraw: slisBNB --PancakeSwap V3 exactInputSingle--> WBNB --> recipient.
///                The native Lista unbonding exit (requestWithdraw + claimWithdraw,
///                7-15 days) is NEVER used — exit is instant via the deepest
///                on-chain slisBNB venue (PancakeSwap V3 0.05% pool).
///      totalAssets: convertSnBnbToBnb(held slisBNB) [== BNB value] minus the
///                max-slippage haircut, so reported NAV is the CONSERVATIVE
///                DEX-realizable value. Uses only the protocol convert rate (no
///                DEX spot) — oracle-manipulation resistant — and makes a 100%
///                recall clear the vault's `received >= toWithdraw` guard (M13-16).
///      harvest: no-op (slisBNB auto-appreciates via convertSnBnbToBnb).
///
///      ── Non-custodial / instant-exit conclusion ──────────────────────────
///      Instant withdrawal (UI "即時") is honored via the PancakeSwap V3 exit — the
///      only way to satisfy the synchronous IStrategyAdapter.withdraw() for a
///      staking asset whose native exit is a multi-day unbonding queue.
///      requiredLockPeriod() returns 0. No user funds are custodied by a SIXX-side
///      wallet: the vault pushes WBNB in, the adapter holds only the slisBNB
///      position, and withdraw() sends WBNB straight to `recipient`. The
///      alternative (native unbonding, requiredLockPeriod = ~7-15 days) was
///      rejected: it cannot deliver assets synchronously and contradicts "即時".
///      CAVEAT (SHIN decision): slisBNB DEX depth (~$2.5M in the 0.05% pool on
///      2026-07-23) is far thinner than stETH/ETH; oversized exits revert on the
///      slippage floor. Cap the TVL routed here and/or add venues before scaling.
///
///      ── DISCLOSURE ────────────────────────────────────────────────────────
///      Principal is held in staked BNB (Lista slisBNB); yield is VARIABLE and NOT
///      principal-guaranteed; native unbonding bypassed via instant market exit;
///      carries slashing risk and slisBNB/BNB secondary-market discount risk. Must
///      never be presented as a capital-guaranteed deposit.
///
///      BNB Chain reference addresses (verified on-chain 2026-07-23):
///        WBNB         0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c (18 dec)
///        slisBNB      0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B (18 dec, non-rebasing)
///        StakeManager 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6
///        V3 SwapRouter 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4
///        exit pool    0x9474e972F49605315763c296B122CBB998b615Cf (slisBNB/WBNB, fee 500)
contract BNBStakingAdapter is IStrategyAdapter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================
    // Constants
    // =========================================

    uint256 private constant MAX_BPS = 10_000;

    /// @notice Hard ceiling on the slippage tolerance governance can set (3%).
    uint256 public constant MAX_SLIPPAGE_BPS = 300;

    // =========================================
    // Immutables — tokens & venue
    // =========================================

    /// @notice Underlying asset (WBNB) — matches the connected WBNB-denominated vault.
    address public immutable override asset;

    /// @notice Lista slisBNB (non-rebasing, value-accruing) — the held yield position.
    IERC20 public immutable slisBNB;

    /// @notice Lista StakeManager — the native staking entry.
    IListaStakeManager public immutable stakeManager;

    /// @notice PancakeSwap V3 SwapRouter — the instant exit venue.
    IPancakeV3Router public immutable swapRouter;

    /// @notice PancakeSwap V3 fee tier of the slisBNB/WBNB exit pool (e.g. 500 = 0.05%).
    uint24 public immutable poolFee;

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

    /// @notice Tolerated slippage on the PancakeSwap exit, in bps (default 0.5%).
    ///         Doubles as the NAV haircut in totalAssets(). Governance can WIDEN it
    ///         (up to MAX_SLIPPAGE_BPS) so exits keep clearing during a slisBNB
    ///         depeg at an honest, lower NAV mark, then tighten back on recovery.
    uint256 public slippageBps = 50;

    /// @notice Representative APY in bps (Lista yield is variable; displayed estimate).
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
    event BNBRescued(address indexed to, uint256 amount);
    event EstimatedAPYUpdated(uint256 oldBps, uint256 newBps);
    event SlippageUpdated(uint256 oldBps, uint256 newBps);

    // =========================================
    // Constructor
    // =========================================

    /// @param asset_           WBNB token address.
    /// @param slisBNB_         Lista slisBNB address.
    /// @param stakeManager_    Lista StakeManager address.
    /// @param swapRouter_      PancakeSwap V3 SwapRouter address.
    /// @param poolFee_         V3 fee tier of the slisBNB/WBNB exit pool.
    /// @param vault_           SIXXVault address.
    /// @param governance_      Governance EOA or Safe.
    /// @param estimatedApyBps_ Initial representative APY (bps).
    constructor(
        address asset_,
        address slisBNB_,
        address stakeManager_,
        address swapRouter_,
        uint24  poolFee_,
        address vault_,
        address governance_,
        uint256 estimatedApyBps_
    ) {
        require(asset_ != address(0), "ADAPTER: zero asset");
        require(slisBNB_ != address(0), "ADAPTER: zero slisBNB");
        require(stakeManager_ != address(0), "ADAPTER: zero stakeManager");
        require(swapRouter_ != address(0), "ADAPTER: zero router");
        require(poolFee_ != 0, "ADAPTER: zero fee");
        require(vault_ != address(0), "ADAPTER: zero vault");
        require(governance_ != address(0), "ADAPTER: zero governance");

        asset        = asset_;
        slisBNB      = IERC20(slisBNB_);
        stakeManager = IListaStakeManager(stakeManager_);
        swapRouter   = IPancakeV3Router(swapRouter_);
        poolFee      = poolFee_;
        vault        = vault_;
        governance   = governance_;
        _estimatedApyBps = estimatedApyBps_;

        // Infinite approval: the V3 router pulls slisBNB from this adapter on exit.
        IERC20(slisBNB_).forceApprove(swapRouter_, type(uint256).max);
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

    /// @notice Conservative DEX-realizable WBNB value of the held slisBNB.
    /// @dev NAV = convertSnBnbToBnb(slisBNB) [BNB value, 18dec] minus the max-
    ///      slippage haircut. Uses ONLY the protocol-internal convert rate (no DEX
    ///      spot) → oracle-manipulation resistant. WBNB and BNB are both 18-decimal.
    ///      Floors are vault-favorable (NAV is never over-reported).
    function totalAssets() public view override returns (uint256) {
        uint256 shares = slisBNB.balanceOf(address(this));
        if (shares == 0) return 0;
        return (stakeManager.convertSnBnbToBnb(shares) * (MAX_BPS - slippageBps)) / MAX_BPS;
    }

    /// @notice Vault sends WBNB here, then calls this: unwrap to BNB, stake to slisBNB.
    function deposit(uint256 assets)
        external
        override
        onlyVault
        whenNotPaused
        nonReentrant
        returns (uint256 deposited)
    {
        require(assets > 0, "ADAPTER: zero amount");

        // WBNB -> BNB. WBNB.withdraw sends native BNB to this contract (receive()).
        IWETH9(asset).withdraw(assets);

        // BNB -> slisBNB via native Lista stake. Minted at exchange rate, no slippage.
        stakeManager.deposit{value: assets}();

        // Entry is principal-exact (native stake at rate); report the input amount.
        deposited = assets;
        emit Deposited(assets, deposited);
    }

    /// @notice Sell just enough slisBNB on PancakeSwap V3 to deliver >= `assets`
    ///         WBNB to `recipient`. Never uses the native Lista unbonding queue.
    /// @dev The V3 leg's `amountOutMinimum` enforces the slippage cap against the
    ///      convertSnBnbToBnb fair value of the slisBNB sold; a breach reverts. On a
    ///      full drain (assets >= totalAssets) the entire slisBNB balance is sold,
    ///      which — because reported NAV is already haircut — still clears the
    ///      vault's `received >= toWithdraw` guard.
    function withdraw(uint256 assets, address recipient)
        external
        override
        onlyVault
        nonReentrant
        returns (uint256 withdrawn)
    {
        require(assets > 0, "ADAPTER: zero amount");
        require(recipient != address(0), "ADAPTER: zero recipient");

        uint256 shares = slisBNB.balanceOf(address(this));
        require(shares > 0, "ADAPTER: no position");

        uint256 sharesToSell;
        if (assets >= totalAssets()) {
            // Full exit (recall-all / migration / emergency shutdown): sell all.
            sharesToSell = shares;
        } else {
            // Sell slisBNB worth `assets` BNB grossed up by 1/(1-slippage) so that,
            // after slippage, the vault still receives at least `assets`.
            uint256 targetBnb = (assets * MAX_BPS) / (MAX_BPS - slippageBps);
            sharesToSell = stakeManager.convertBnbToSnBnb(targetBnb);
            if (sharesToSell > shares || sharesToSell == 0) sharesToSell = shares;
        }

        // Slippage floor: >= (1 - slippage) of the sold slisBNB's fair BNB value.
        // Mirrors totalAssets() so drain-all's floor equals the reported NAV.
        uint256 minWbnbOut =
            (stakeManager.convertSnBnbToBnb(sharesToSell) * (MAX_BPS - slippageBps)) / MAX_BPS;

        uint256 wbnbBefore = IERC20(asset).balanceOf(address(this));
        swapRouter.exactInputSingle(
            IPancakeV3Router.ExactInputSingleParams({
                tokenIn: address(slisBNB),
                tokenOut: asset,
                fee: poolFee,
                recipient: address(this),
                amountIn: sharesToSell,
                amountOutMinimum: minWbnbOut,
                sqrtPriceLimitX96: 0
            })
        );
        withdrawn = IERC20(asset).balanceOf(address(this)) - wbnbBefore;

        IERC20(asset).safeTransfer(recipient, withdrawn);
        emit Withdrawn(assets, withdrawn, recipient);
    }

    /// @notice slisBNB auto-appreciates via convertSnBnbToBnb — harvest is a no-op.
    function harvest() external override onlyVault returns (uint256) {
        emit Harvested(0);
        return 0;
    }

    /// @notice Accept native BNB from WBNB unwrap only.
    receive() external payable {}

    // =========================================
    // Metadata
    // =========================================

    function name() external pure override returns (string memory) {
        return "SIXX BNB Yield - Lista slisBNB";
    }

    function providerName() external pure override returns (string memory) {
        return "Lista DAO";
    }

    function adapterType() external pure override returns (string memory) {
        return "DeFi";
    }

    function riskLevel() external pure override returns (uint8) {
        return 2; // staked BNB: slashing + unbonding + slisBNB/BNB discount risk
    }

    /// @notice Representative variable APY in bps. See `description()` disclaimer.
    function estimatedAPY() external view override returns (uint256) {
        return _estimatedApyBps;
    }

    function requiredLockPeriod() external pure override returns (uint256) {
        return 0; // Instant PancakeSwap exit; native unbonding intentionally bypassed.
    }

    function isActive() external view override returns (bool) {
        return !_paused;
    }

    /// @notice Mandatory risk disclosure surfaced to integrators/UI.
    function description() external pure returns (string memory) {
        return
            "principal in staked BNB (Lista slisBNB); yield variable, NOT principal-guaranteed; native unbonding bypassed via instant market exit; slashing + slisBNB/BNB discount + thinner-DEX-depth risk";
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

    /// @notice Set the exit slippage tolerance / NAV haircut (bps, <= MAX_SLIPPAGE_BPS).
    function setSlippageBps(uint256 newBps) external {
        require(msg.sender == governance, "ADAPTER: not governance");
        require(newBps <= MAX_SLIPPAGE_BPS, "ADAPTER: slippage too high");
        emit SlippageUpdated(slippageBps, newBps);
        slippageBps = newBps;
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
    // Token / BNB Rescue
    // =========================================

    /// @notice Recover tokens accidentally sent here. Cannot touch the slisBNB
    ///         position, so user principal is never at risk.
    function rescueToken(address token, address to) external returns (uint256 amount) {
        require(msg.sender == governance, "ADAPTER: not governance");
        require(to != address(0), "ADAPTER: zero recipient");
        require(token != address(slisBNB), "ADAPTER: cannot rescue position");
        amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    /// @notice Recover raw BNB accidentally left on the adapter (never held at rest;
    ///         only transient during deposit). Governance only.
    function rescueBNB(address to) external returns (uint256 amount) {
        require(msg.sender == governance, "ADAPTER: not governance");
        require(to != address(0), "ADAPTER: zero recipient");
        amount = address(this).balance;
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "ADAPTER: BNB send failed");
        emit BNBRescued(to, amount);
    }
}
