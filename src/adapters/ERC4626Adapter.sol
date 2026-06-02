// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IStrategyAdapter} from "../interfaces/IStrategyAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ERC4626Adapter
/// @notice Generic SIXX strategy adapter that wraps a single external ERC-4626
///         vault. v1 connects to blue-chip Morpho MetaMorpho vaults, but because
///         the integration is the bare ERC-4626 standard the same adapter is
///         reusable for any compliant vault (Sky `sUSDS`, Ethena `sUSDe`, …) by
///         pointing `vault` at a different address — one codebase, many targets.
///
/// @dev Blue-chip gating is a *governance-at-registration* concern, not code: the
///      `vault` is immutable and the AdapterRegistry only whitelists adapters
///      whose curator/TVL/audit bar governance has cleared. See the deploy-time
///      checklist in DeployERC4626Adapter.s.sol.
///
/// @dev Implementation conventions mirror AaveV3USDCAdapter / VenusUSDTAdapter
///      *exactly*:
///        - PUSH transfer model: the SIXXVault `safeTransfer`s the underlying to
///          this adapter BEFORE calling `deposit()`; the downstream vault then
///          pulls from us via the constructor's infinite approval. There is NO
///          `transferFrom` here — identical direction to AaveV3USDCAdapter.deposit
///          ("USDC is already in this contract (transferred by vault)").
///        - `onlyVault` / `whenNotPaused` gating, M-4 two-step rotation of both
///          the SIXX caller and governance.
///      The audit's "M-3 self-call" requirement is satisfied here by OZ
///      `ReentrancyGuard` (`nonReentrant` on every state-changing entry point).
///      Note: the existing Aave/Venus adapters carry no literal self-call/guard
///      construct, so there was nothing to copy verbatim — the guard is added
///      because ERC-4626 deposit/withdraw can re-enter through token hooks.
///
/// @dev Morpho-specific: MORPHO incentive rewards are distributed off-chain via a
///      Universal Rewards Distributor (merkle claim) and are NOT reflected in the
///      vault's share price, so they never appear in `totalAssets()`. v1 leaves
///      them out of scope ("rewards excluded"); a future governance-only claim →
///      feeRecipient function can be bolted on without touching this core.
contract ERC4626Adapter is IStrategyAdapter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================
    // Immutables
    // =========================================

    /// @notice Underlying asset (e.g. USDC, USDT)
    address public immutable override asset;

    /// @notice Connected ERC-4626 vault (e.g. a Morpho MetaMorpho vault).
    ///         Immutable: one adapter == one vetted vault.
    IERC4626 public immutable vault;

    // =========================================
    // Mutable State
    // =========================================

    /// @notice The single SIXXVault allowed to call deposit/withdraw.
    /// @dev Named `sixxVault` (not `vault`) to avoid colliding with the ERC-4626
    ///      `vault` immutable above.
    address public sixxVault;

    /// @notice M-4: Pending SIXX caller for the 2-step rotation.
    address public pendingSixxVault;

    /// @notice Governance address for admin functions.
    address public governance;

    /// @notice M-4: Pending governance for the 2-step rotation.
    address public pendingGovernance;

    bool private _paused;

    // =========================================
    // Events (M-4 admin rotations)
    // =========================================

    event SixxVaultProposed(address indexed currentVault, address indexed pendingVault);
    event SixxVaultAccepted(address indexed newVault);
    event GovernanceProposed(address indexed currentGovernance, address indexed pendingGovernance);
    event GovernanceAccepted(address indexed newGovernance);

    // =========================================
    // Constructor
    // =========================================

    /// @param asset_      Underlying token address (chain-specific).
    /// @param vault_      ERC-4626 vault address (chain-specific).
    /// @param sixxVault_  SIXXVault address (the only deposit/withdraw caller).
    /// @param governance_ Governance EOA or Safe.
    constructor(
        address asset_,
        address vault_,
        address sixxVault_,
        address governance_
    ) {
        require(asset_     != address(0), "ADAPTER: zero asset");
        require(vault_     != address(0), "ADAPTER: zero vault");
        require(sixxVault_ != address(0), "ADAPTER: zero sixxVault");
        require(governance_ != address(0), "ADAPTER: zero governance");
        // Mistaken-vault guard: the ERC-4626 vault's underlying MUST equal `asset_`.
        require(IERC4626(vault_).asset() == asset_, "ADAPTER: asset mismatch");

        asset      = asset_;
        vault      = IERC4626(vault_);
        sixxVault  = sixxVault_;
        governance = governance_;

        // Infinite approval: vault.deposit() pulls the underlying from this adapter.
        IERC20(asset_).forceApprove(vault_, type(uint256).max);
    }

    // =========================================
    // Modifiers
    // =========================================

    modifier onlyVault() {
        require(msg.sender == sixxVault, "ADAPTER: only vault");
        _;
    }

    modifier whenNotPaused() {
        require(!_paused, "ADAPTER: paused");
        _;
    }

    // =========================================
    // Core: IStrategyAdapter
    // =========================================

    /// @notice Underlying value of the ERC-4626 shares held by this adapter.
    /// @dev `convertToAssets` rounds DOWN, so this never over-states what we can
    ///      actually redeem — important for the vault's totalAssets() accounting.
    function totalAssets() external view override returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(address(this)));
    }

    /// @notice SIXXVault sends the underlying here, then calls this to deposit
    ///         into the ERC-4626 vault.
    /// @dev PUSH model (matches AaveV3USDCAdapter / VenusUSDTAdapter): the
    ///      underlying is already held by this adapter when we are called. The
    ///      ERC-4626 vault pulls it from us via the constructor's infinite
    ///      approval — so there is intentionally NO `transferFrom` here.
    function deposit(uint256 assets)
        external override onlyVault whenNotPaused nonReentrant returns (uint256 deposited)
    {
        require(assets > 0, "ADAPTER: zero amount");
        // Return value is the shares minted; we intentionally report the asset
        // amount (`deposited`) per IStrategyAdapter, mirroring the existing adapters.
        // slither-disable-next-line unused-return
        vault.deposit(assets, address(this));
        deposited = assets;
        emit Deposited(assets, deposited);
    }

    /// @notice Withdraw the underlying from the ERC-4626 vault and send it
    ///         directly to `recipient`.
    /// @dev Caps the request at `maxWithdraw` so a partially-illiquid vault
    ///      returns just-enough instead of reverting. ERC-4626 `withdraw` sends
    ///      assets straight to `recipient` and burns this adapter's shares.
    function withdraw(uint256 assets, address recipient)
        external override onlyVault nonReentrant returns (uint256 withdrawn)
    {
        require(assets > 0, "ADAPTER: zero amount");
        require(recipient != address(0), "ADAPTER: zero recipient");

        uint256 maxW = vault.maxWithdraw(address(this));
        uint256 amt  = assets < maxW ? assets : maxW;
        if (amt == 0) {
            emit Withdrawn(assets, 0, recipient);
            return 0;
        }

        // Return value is the shares burned; we report the asset amount (`withdrawn`).
        // slither-disable-next-line unused-return
        vault.withdraw(amt, recipient, address(this));
        withdrawn = amt;
        emit Withdrawn(assets, withdrawn, recipient);
    }

    /// @notice ERC-4626 share price auto-compounds — harvest is a no-op.
    /// @dev MORPHO merkle rewards are out of scope (see contract-level notes).
    function harvest() external override nonReentrant returns (uint256) {
        emit Harvested(0);
        return 0;
    }

    // =========================================
    // Metadata
    // =========================================

    function name() external pure override returns (string memory) {
        return "SIXX ERC-4626 Strategy Adapter";
    }

    /// @notice Generic provider label. The vault-specific provider string
    ///         (e.g. "Morpho - Gauntlet USDC Prime (Base)") is recorded in the
    ///         AdapterRegistry at registration, not hard-coded here, because this
    ///         adapter is reused across multiple vetted vaults.
    function providerName() external pure override returns (string memory) {
        return "ERC-4626 Vault";
    }

    /// @notice Human-readable description. Not part of IStrategyAdapter, exposed
    ///         for front-ends. Explicitly flags the v1 rewards stance.
    function description() external pure returns (string memory) {
        return "Generic ERC-4626 vault adapter (v1: blue-chip Morpho MetaMorpho vaults). "
               "MORPHO rewards excluded - distributed off-chain via merkle URD and not "
               "reflected in share price.";
    }

    function adapterType() external pure override returns (string memory) {
        return "DeFi";
    }

    function riskLevel() external pure override returns (uint8) {
        return 2; // On par with Aave: only named, audited curators (Gauntlet/Steakhouse).
    }

    /// @notice Returns 0 on-chain by design.
    /// @dev A MetaMorpho vault's realized APY cannot be read precisely on-chain
    ///      (it depends on the allocation across underlying Morpho markets). Per
    ///      the existing Aave/Venus front-end convention, the UI sources a 7-day
    ///      average from vaults.fyi / DefiLlama rather than trusting a noisy
    ///      on-chain spot rate.
    function estimatedAPY() external pure override returns (uint256) {
        return 0;
    }

    /// @notice 0 — v1 target vaults support instant `maxWithdraw`-bounded redeem.
    /// @dev Request/claim (withdrawal-queue) vaults are NOT supported by this
    ///      flow; instant redemption MUST be verified before registration (see
    ///      deploy checklist). If a queued vault is ever adopted, this must be
    ///      raised and a separate request/claim flow implemented.
    function requiredLockPeriod() external pure override returns (uint256) {
        return 0;
    }

    function isActive() external view override returns (bool) {
        return !_paused;
    }

    // =========================================
    // Circuit Breaker
    // =========================================

    function pause() external override {
        require(msg.sender == governance || msg.sender == sixxVault, "ADAPTER: unauthorized");
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

    /// @notice M-4: Propose a new SIXX caller. Takes effect when the proposed
    ///         address calls `acceptSixxVault()`. Two-step prevents bricking the
    ///         adapter by handing off to an address that cannot act.
    function proposeSixxVault(address newVault) external {
        require(msg.sender == governance, "ADAPTER: not governance");
        require(newVault != address(0), "ADAPTER: zero vault");
        pendingSixxVault = newVault;
        emit SixxVaultProposed(sixxVault, newVault);
    }

    /// @notice M-4: Accept a pending SIXX-caller rotation. Callable only by the
    ///         proposed address.
    function acceptSixxVault() external {
        require(msg.sender == pendingSixxVault, "ADAPTER: not pending vault");
        emit SixxVaultAccepted(pendingSixxVault);
        sixxVault = pendingSixxVault;
        pendingSixxVault = address(0);
    }

    /// @notice M-4: Propose a new governance. Takes effect on
    ///         `acceptGovernance()` from the proposed address.
    function proposeGovernance(address newGovernance) external {
        require(msg.sender == governance, "ADAPTER: not governance");
        require(newGovernance != address(0), "ADAPTER: zero address");
        pendingGovernance = newGovernance;
        emit GovernanceProposed(governance, newGovernance);
    }

    /// @notice M-4: Accept a pending governance rotation. Callable only by the
    ///         proposed address.
    function acceptGovernance() external {
        require(msg.sender == pendingGovernance, "ADAPTER: not pending governance");
        emit GovernanceAccepted(pendingGovernance);
        governance = pendingGovernance;
        pendingGovernance = address(0);
    }
}
