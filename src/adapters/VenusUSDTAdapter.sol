// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IStrategyAdapter} from "../interfaces/IStrategyAdapter.sol";
import {IVenusVToken} from "../interfaces/IVenusVToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title VenusUSDTAdapter
/// @notice Supplies USDT to Venus Protocol (BNB Chain) and holds vUSDT.
///         vUSDT balance is constant per address; underlying value grows via
///         `exchangeRateStored`, so harvest is a no-op.
///
/// @dev Deployment addresses:
///      BNB Testnet (chainId 97):
///        USDT       0xA11c8D9DC9b66E209Ef60F0C8D969D3CD988782c
///        vUSDT      0xb7526572FFE56AB9D7489838Bf2E18e3323b441A
///        Unitroller 0x94d1820b2D1c7c7452A163983Dc888CEC546b77D
contract VenusUSDTAdapter is IStrategyAdapter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================
    // Constants
    // =========================================

    /// @notice BSC block time is ~3s → ~10.5M blocks/year. Used for APY estimate.
    uint256 internal constant BLOCKS_PER_YEAR = 10_512_000;

    // =========================================
    // Immutables
    // =========================================

    /// @notice Underlying asset (USDT)
    address public immutable override asset;

    /// @notice Venus vToken (vUSDT) — balance is constant per address;
    ///         value grows through exchangeRate.
    IVenusVToken public immutable vToken;

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

    /// @param asset_      USDT token address (chain-specific)
    /// @param vToken_     vUSDT token address (chain-specific)
    /// @param vault_      SIXXVault address
    /// @param governance_ Governance EOA or Safe
    constructor(
        address asset_,
        address vToken_,
        address vault_,
        address governance_
    ) {
        require(asset_      != address(0), "ADAPTER: zero asset");
        require(vToken_     != address(0), "ADAPTER: zero vToken");
        require(vault_      != address(0), "ADAPTER: zero vault");
        require(governance_ != address(0), "ADAPTER: zero governance");
        require(IVenusVToken(vToken_).underlying() == asset_, "ADAPTER: vToken/asset mismatch");

        asset      = asset_;
        vToken     = IVenusVToken(vToken_);
        vault      = vault_;
        governance = governance_;

        // Infinite approval: vToken.mint() pulls USDT from this adapter
        IERC20(asset_).forceApprove(vToken_, type(uint256).max);
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

    /// @notice Underlying value of held vUSDT
    /// @dev exchangeRateStored mantissa is 1e18 — slightly stale between blocks
    ///      but acceptable for previews. Withdraw paths get fresh accrual since
    ///      `redeemUnderlying`/`redeem` accrue interest first.
    ///
    ///      Medium-B audit note: `exchangeRateCurrent()` cannot be used here —
    ///      it is a NON-view function (it calls `accrueInterest()` and mutates
    ///      state), whereas `totalAssets()` must stay `view` (ERC-4626 +
    ///      IStrategyAdapter interface + the vault's own `view` totalAssets).
    ///      The staleness is at most one block of USDT supply interest (~3s of
    ///      yield): it under-reports totalAssets — conservative for redemptions,
    ///      and on deposits it hands the incoming depositor a marginally favorable
    ///      share price, bounded by that same sub-block dust (not exploitable).
    ///      It never touches actual redemptions, which accrue fresh on-chain.
    function totalAssets() external view override returns (uint256) {
        return _underlyingValue();
    }

    /// @dev Underlying value of held vUSDT at the stored (slightly stale) rate.
    function _underlyingValue() internal view returns (uint256) {
        return (vToken.balanceOf(address(this)) * vToken.exchangeRateStored()) / 1e18;
    }

    /// @notice Vault sends USDT here, then calls this to supply to Venus
    function deposit(uint256 assets)
        external override onlyVault whenNotPaused nonReentrant returns (uint256 deposited)
    {
        require(assets > 0, "ADAPTER: zero amount");
        require(vToken.mint(assets) == 0, "ADAPTER: mint failed");
        deposited = assets;
        emit Deposited(assets, deposited);
    }

    /// @notice Withdraw USDT from Venus and forward to `recipient`
    /// @dev Venus' redeemUnderlying sends to msg.sender (this adapter), so we
    ///      then forward to `recipient`.
    function withdraw(uint256 assets, address recipient)
        external override onlyVault nonReentrant returns (uint256 withdrawn)
    {
        require(assets > 0, "ADAPTER: zero amount");
        require(recipient != address(0), "ADAPTER: zero recipient");

        if (assets >= _underlyingValue()) {
            // Drain-all path (recall on shutdown / adapter migration / last full
            // exit): redeem the ENTIRE vUSDT balance by vToken amount instead of
            // by underlying amount. `redeemUnderlying()` leaves sub-unit vUSDT
            // dust — the stored rate used to size the request is staler than the
            // rate Venus accrues to inside the call — and that residual dust later
            // bricks a 100% exit with Venus "redeemTokens zero". `redeem(balance)`
            // burns to exactly zero, so no dust survives the recall.
            uint256 vBal = vToken.balanceOf(address(this));
            uint256 before = IERC20(asset).balanceOf(address(this));
            if (vBal > 0) {
                require(vToken.redeem(vBal) == 0, "ADAPTER: redeem failed");
            }
            withdrawn = IERC20(asset).balanceOf(address(this)) - before;
        } else {
            require(vToken.redeemUnderlying(assets) == 0, "ADAPTER: redeem failed");
            withdrawn = assets;
        }

        IERC20(asset).safeTransfer(recipient, withdrawn);
        emit Withdrawn(assets, withdrawn, recipient);
    }

    /// @notice vUSDT auto-compounds via exchangeRate — harvest is a no-op
    function harvest() external override onlyVault returns (uint256) {
        emit Harvested(0);
        return 0;
    }

    // =========================================
    // Metadata
    // =========================================

    function name() external pure override returns (string memory) {
        return "SIXX Stable Yield - Venus USDT";
    }

    function providerName() external pure override returns (string memory) {
        return "Venus Protocol";
    }

    function adapterType() external pure override returns (string memory) {
        return "DeFi";
    }

    function riskLevel() external pure override returns (uint8) {
        return 3; // Compound-fork on BNB; slightly higher than Aave on ETH
    }

    /// @notice Live APY estimate from Venus' per-block supply rate
    /// @dev supplyRatePerBlock is 1e18-scaled. Annualized BPS:
    ///      rate * BLOCKS_PER_YEAR / 1e14 (simple, not compounded).
    function estimatedAPY() external view override returns (uint256) {
        try vToken.supplyRatePerBlock() returns (uint256 rate) {
            return (rate * BLOCKS_PER_YEAR) / 1e14;
        } catch {
            return 0;
        }
    }

    function requiredLockPeriod() external pure override returns (uint256) {
        return 0; // Venus supports instant withdrawal (subject to utilization)
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

    /// @notice Recover tokens accidentally sent to this adapter. Cannot touch the
    ///         yield-bearing position (vToken), so user principal is never at risk.
    function rescueToken(address token, address to) external returns (uint256 amount) {
        require(msg.sender == governance, "ADAPTER: not governance");
        require(to != address(0), "ADAPTER: zero recipient");
        require(token != address(vToken), "ADAPTER: cannot rescue position");
        require(token != asset, "ADAPTER: cannot rescue principal"); // L-02: underlying protected
        amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }
}
