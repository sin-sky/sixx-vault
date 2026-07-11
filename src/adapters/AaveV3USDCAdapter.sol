// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IStrategyAdapter} from "../interfaces/IStrategyAdapter.sol";
import {IAavePool} from "../interfaces/IAavePool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AaveV3USDCAdapter
/// @notice Supplies USDC to Aave V3 and holds aUSDC.
///         aUSDC balance auto-increases over time — no explicit harvest needed.
///
/// @dev Deployment addresses:
///      Arbitrum One:
///        USDC      0xaf88d065e77c8cC2239327C5EDb3A432268e5831
///        Aave Pool 0x794a61358D6845594F94dc1DB02A252b5b4814aD
///        aUSDC     0x625E7708f30cA75bfd92586e17077590C60eb4cD
///      Ethereum mainnet:
///        USDC      0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
///        Aave Pool 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2
///        aUSDC     0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c
contract AaveV3USDCAdapter is IStrategyAdapter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================
    // Immutables
    // =========================================

    /// @notice Underlying asset (USDC)
    address public immutable override asset;

    /// @notice Aave V3 Pool contract
    IAavePool public immutable aavePool;

    /// @notice aToken (aUSDC) — balance increases automatically as interest accrues
    IERC20 public immutable aToken;

    /// @notice Aave referral code (0 = none)
    uint16 public immutable referralCode;

    // =========================================
    // Mutable State
    // =========================================

    /// @notice The single vault allowed to call deposit/withdraw
    address public vault;

    /// @notice M-4: Pending vault for the 2-step rotation.
    address public pendingVault;

    /// @notice Governance address for admin functions
    address public governance;

    /// @notice M-4: Pending governance for the 2-step rotation.
    address public pendingGovernance;

    bool private _paused;

    // =========================================
    // Events (M-4 admin rotations)
    // =========================================

    event VaultProposed(address indexed currentVault, address indexed pendingVault);
    event VaultAccepted(address indexed newVault);
    event GovernanceProposed(address indexed currentGovernance, address indexed pendingGovernance);
    event GovernanceAccepted(address indexed newGovernance);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    // =========================================
    // Constructor
    // =========================================

    /// @param asset_        USDC token address (chain-specific)
    /// @param aavePool_     Aave V3 Pool address (chain-specific)
    /// @param aToken_       aUSDC token address (chain-specific)
    /// @param vault_        SIXXVault address
    /// @param governance_   Governance EOA or Safe
    /// @param referralCode_ 0 unless Aave referral is registered
    constructor(
        address asset_,
        address aavePool_,
        address aToken_,
        address vault_,
        address governance_,
        uint16  referralCode_
    ) {
        require(asset_      != address(0), "ADAPTER: zero asset");
        require(aavePool_   != address(0), "ADAPTER: zero pool");
        require(aToken_     != address(0), "ADAPTER: zero aToken");
        require(vault_      != address(0), "ADAPTER: zero vault");
        require(governance_ != address(0), "ADAPTER: zero governance");
        require(
            IAavePool(aavePool_).getReserveData(asset_).aTokenAddress == aToken_,
            "ADAPTER: aToken/pool mismatch"
        );

        asset        = asset_;
        aavePool     = IAavePool(aavePool_);
        aToken       = IERC20(aToken_);
        vault        = vault_;
        governance   = governance_;
        referralCode = referralCode_;

        // Infinite approval: Aave Pool pulls USDC from this adapter on supply()
        IERC20(asset_).forceApprove(aavePool_, type(uint256).max);
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

    /// @notice aUSDC balance = USDC value including accrued interest
    function totalAssets() external view override returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    /// @notice Vault sends USDC here, then calls this to supply to Aave
    /// @dev Vault does `safeTransfer(adapter, idle)` before calling `deposit(idle)`
    function deposit(uint256 assets)
        external override onlyVault whenNotPaused nonReentrant returns (uint256 deposited)
    {
        require(assets > 0, "ADAPTER: zero amount");
        // USDC is already in this contract (transferred by vault)
        aavePool.supply(asset, assets, address(this), referralCode);
        deposited = assets;
        emit Deposited(assets, deposited);
    }

    /// @notice Withdraw USDC from Aave and send directly to `recipient`
    /// @dev C: On a full exit (recall-all during shutdown / adapter migration) use
    ///      `type(uint256).max` so Aave sweeps the ENTIRE aUSDC balance, including the
    ///      interest that accrues inside the withdraw call. A fixed `assets` amount
    ///      would leave sub-unit aUSDC dust stranded once the vault stops pointing here.
    function withdraw(uint256 assets, address recipient)
        external override onlyVault nonReentrant returns (uint256 withdrawn)
    {
        require(assets > 0, "ADAPTER: zero amount");
        require(recipient != address(0), "ADAPTER: zero recipient");
        uint256 amount = assets >= aToken.balanceOf(address(this)) ? type(uint256).max : assets;
        // Aave withdraws `amount` (or the full balance for max); returns actual withdrawn.
        withdrawn = aavePool.withdraw(asset, amount, recipient);
        emit Withdrawn(assets, withdrawn, recipient);
    }

    /// @notice aUSDC auto-compounds — harvest is a no-op
    function harvest() external override onlyVault returns (uint256) {
        emit Harvested(0);
        return 0;
    }

    // =========================================
    // Metadata
    // =========================================

    function name() external pure override returns (string memory) {
        return "SIXX Stable Yield - Aave V3 USDC";
    }

    function providerName() external pure override returns (string memory) {
        return "Aave V3";
    }

    function adapterType() external pure override returns (string memory) {
        return "DeFi";
    }

    function riskLevel() external pure override returns (uint8) {
        return 2; // 1=lowest … 5=highest
    }

    /// @notice Live APY estimate from Aave's on-chain rate
    /// @dev currentLiquidityRate is in RAY (1e27, per-second).
    ///      Annualized %: rate / 1e27 * ~31.5M seconds ≈ rate / 1e27 * SECS_PER_YEAR
    ///      Basis points: multiply by 10_000, divide by 1e27 → divide by 1e23
    function estimatedAPY() external view override returns (uint256) {
        try aavePool.getReserveData(asset) returns (IAavePool.ReserveData memory data) {
            return uint256(data.currentLiquidityRate) / 1e23;
        } catch {
            return 0;
        }
    }

    function requiredLockPeriod() external pure override returns (uint256) {
        return 0; // Aave supports instant withdrawal
    }

    function isActive() external view override returns (bool) {
        return !_paused;
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
    // Admin (M-4: 2-step rotations)
    // =========================================

    /// @notice M-4: Propose a new vault. Takes effect when the proposed
    ///         address calls `acceptVault()`. Two-step prevents bricking the
    ///         adapter by handing off to an address that cannot act.
    function proposeVault(address newVault) external {
        require(msg.sender == governance, "ADAPTER: not governance");
        require(newVault != address(0), "ADAPTER: zero vault");
        pendingVault = newVault;
        emit VaultProposed(vault, newVault);
    }

    /// @notice M-4: Accept a pending vault rotation. Callable only by the
    ///         proposed address.
    function acceptVault() external {
        require(msg.sender == pendingVault, "ADAPTER: not pending vault");
        emit VaultAccepted(pendingVault);
        vault = pendingVault;
        pendingVault = address(0);
    }

    /// @notice M-4: Propose a new governance. Takes effect on
    ///         `acceptGovernance()` from the proposed address.
    function proposeGovernance(address newGovernance) external {
        require(msg.sender == governance, "ADAPTER: not governance");
        require(newGovernance != address(0), "ADAPTER: zero address");
        pendingGovernance = newGovernance;
        emit GovernanceProposed(governance, newGovernance);
    }

    /// @notice M-4: Accept a pending governance rotation. Callable only by
    ///         the proposed address.
    function acceptGovernance() external {
        require(msg.sender == pendingGovernance, "ADAPTER: not pending governance");
        emit GovernanceAccepted(pendingGovernance);
        governance = pendingGovernance;
        pendingGovernance = address(0);
    }

    // =========================================
    // ADP-2: Token Rescue
    // =========================================

    /// @notice Recover tokens accidentally sent to this adapter. Cannot touch the
    ///         yield-bearing position (aToken), so user principal is never at risk.
    function rescueToken(address token, address to) external returns (uint256 amount) {
        require(msg.sender == governance, "ADAPTER: not governance");
        require(to != address(0), "ADAPTER: zero recipient");
        require(token != address(aToken), "ADAPTER: cannot rescue position");
        require(token != asset, "ADAPTER: cannot rescue principal"); // L-02: underlying protected
        amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }
}
