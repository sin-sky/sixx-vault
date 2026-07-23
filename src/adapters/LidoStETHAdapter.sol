// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IStrategyAdapter} from "../interfaces/IStrategyAdapter.sol";
import {IWETH9} from "../interfaces/IWETH9.sol";
import {ILidoStETH} from "../interfaces/ILidoStETH.sol";
import {IWstETH} from "../interfaces/IWstETH.sol";
import {ICurveStETHPool} from "../interfaces/ICurveStETHPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title LidoStETHAdapter
/// @notice SIXX "ETH 運用" adapter. Stakes WETH principal into Lido and holds the
///         non-rebasing wstETH wrapper as its yield position. Yield is the Lido
///         validator reward, surfaced through wstETH's monotonically increasing
///         stETH-per-token rate.
///
/// @dev asset() == WETH, so this adapter plugs into a WETH-denominated SIXXVault.
///      The vault holds WETH (an ERC-20); this adapter converts to/from raw ETH
///      internally because both the Lido stake entry and the Curve exit venue
///      operate on native ETH.
///
///      ── Flow ──────────────────────────────────────────────────────────────
///      deposit:  WETH --withdraw--> ETH --Lido.submit{value}--> stETH (1:1, NO
///                slippage) --wstETH.wrap--> hold wstETH.
///      withdraw: wstETH --unwrap--> stETH --Curve stETH/ETH exchange--> ETH
///                --WETH.deposit{value}--> WETH --> recipient.
///                The native Lido withdrawal queue (unstETH NFT, ~1-5 days) is
///                NEVER used — exit is instant via the deepest on-chain stETH
///                venue (Curve classic stETH/ETH pool).
///      totalAssets: getStETHByWstETH(held wstETH) [== ETH value] minus the
///                max-slippage haircut, so reported NAV is the CONSERVATIVE
///                DEX-realizable value. This (a) keeps DEX spot price out of
///                accounting (uses only wstETH's protocol rate) — oracle-
///                manipulation resistant, and (b) makes a 100% recall clear the
///                vault's `received >= toWithdraw` shortfall guard (M13-16):
///                actual stETH->ETH slippage (~0.03% at depth) is far smaller
///                than the haircut, so a full drain delivers at least reported NAV.
///      harvest: no-op (wstETH auto-appreciates via getStETHByWstETH).
///
///      ── Non-custodial / instant-exit conclusion ──────────────────────────
///      Instant withdrawal (UI "即時") is honored via the Curve exit. It is the
///      ONLY way to satisfy the synchronous IStrategyAdapter.withdraw() interface
///      for a staking asset whose native exit is a multi-day queue. requiredLock
///      Period() therefore returns 0. No user funds are ever custodied by a SIXX-
///      side wallet: the adapter is a stateless router — the vault pushes WETH in,
///      the adapter stakes and holds only the wstETH position, and withdraw()
///      sends WETH straight to `recipient`. The alternative (native queue,
///      requiredLockPeriod = ~5 days) was rejected because it (i) cannot deliver
///      assets synchronously in withdraw() and (ii) contradicts the UI "即時".
///      See the deploy report for the SHIN decision on TVL vs. Curve depth.
///
///      ── DISCLOSURE ────────────────────────────────────────────────────────
///      Principal is held in staked ETH (Lido stETH via wstETH); yield is VARIABLE
///      (validator rewards) and NOT principal-guaranteed; stETH carries slashing
///      risk, withdrawal-queue congestion, and a stETH/ETH secondary-market
///      discount. Must never be presented as a capital-guaranteed deposit.
///
///      Ethereum mainnet reference addresses (verified on-chain 2026-07-23):
///        WETH       0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 (18 dec)
///        stETH      0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84 (18 dec, rebasing)
///        wstETH     0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0 (18 dec, non-rebasing)
///        curvePool  0xDC24316b9AE028F1497c275EB9192a3Ea0f67022 (ETH/stETH classic)
contract LidoStETHAdapter is IStrategyAdapter, ReentrancyGuard {
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

    /// @notice Underlying asset (WETH) — matches the connected WETH-denominated vault.
    address public immutable override asset;

    /// @notice Lido stETH (rebasing staked ETH), the staking entry token.
    ILidoStETH public immutable stETH;

    /// @notice wstETH (non-rebasing wrapper) — the held yield position.
    IWstETH public immutable wstETH;

    /// @notice Curve classic stETH/ETH pool — the instant exit venue.
    ICurveStETHPool public immutable curvePool;

    /// @notice Curve coin indices (0 = ETH sentinel, 1 = stETH), derived at deploy.
    int128 public immutable stEthIndex;
    int128 public immutable ethIndex;

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

    /// @notice Tolerated slippage on the Curve exit, in bps (default 0.5%). Doubles
    ///         as the NAV haircut in totalAssets(). Governance can WIDEN it (up to
    ///         MAX_SLIPPAGE_BPS) so exits keep clearing during a stETH depeg at an
    ///         honest, lower NAV mark, then tighten back once the peg recovers.
    uint256 public slippageBps = 50;

    /// @notice Representative APY in bps (Lido yield is variable; displayed estimate).
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
    event ETHRescued(address indexed to, uint256 amount);
    event EstimatedAPYUpdated(uint256 oldBps, uint256 newBps);
    event SlippageUpdated(uint256 oldBps, uint256 newBps);

    // =========================================
    // Constructor
    // =========================================

    /// @param asset_           WETH token address.
    /// @param stETH_           Lido stETH address.
    /// @param wstETH_          wstETH address; its stETH() must equal stETH_.
    /// @param curvePool_       Curve ETH/stETH classic pool.
    /// @param vault_           SIXXVault address.
    /// @param governance_      Governance EOA or Safe.
    /// @param estimatedApyBps_ Initial representative APY (bps).
    constructor(
        address asset_,
        address stETH_,
        address wstETH_,
        address curvePool_,
        address vault_,
        address governance_,
        uint256 estimatedApyBps_
    ) {
        require(asset_ != address(0), "ADAPTER: zero asset");
        require(stETH_ != address(0), "ADAPTER: zero stETH");
        require(wstETH_ != address(0), "ADAPTER: zero wstETH");
        require(curvePool_ != address(0), "ADAPTER: zero pool");
        require(vault_ != address(0), "ADAPTER: zero vault");
        require(governance_ != address(0), "ADAPTER: zero governance");
        // Wrapper/stETH linkage guard: wstETH must wrap exactly the configured stETH.
        require(IWstETH(wstETH_).stETH() == stETH_, "ADAPTER: wstETH/stETH mismatch");

        asset      = asset_;
        stETH      = ILidoStETH(stETH_);
        wstETH     = IWstETH(wstETH_);
        curvePool  = ICurveStETHPool(curvePool_);
        vault      = vault_;
        governance = governance_;
        _estimatedApyBps = estimatedApyBps_;

        // Derive & bind the Curve coin indices from the pool's coins() so a
        // misconfigured pool reverts at deploy time rather than mis-routing funds.
        stEthIndex = _coinIndex(curvePool_, stETH_);
        ethIndex   = stEthIndex == 0 ? int128(1) : int128(0); // the other coin is ETH

        // Infinite approvals for the internal legs.
        IERC20(stETH_).forceApprove(wstETH_, type(uint256).max);    // stETH -> wrap
        IERC20(stETH_).forceApprove(curvePool_, type(uint256).max); // stETH -> Curve exit
    }

    /// @dev Returns the int128 index (0 or 1) of `token` in the 2-coin pool,
    ///      reverting if the token is not one of the pool's two coins.
    function _coinIndex(address pool, address token) internal view returns (int128) {
        if (ICurveStETHPool(pool).coins(0) == token) return 0;
        if (ICurveStETHPool(pool).coins(1) == token) return 1;
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

    /// @notice Conservative DEX-realizable WETH value of the held wstETH.
    /// @dev NAV = getStETHByWstETH(wstETH) [ETH value, 18dec] minus the max-slippage
    ///      haircut. Uses ONLY wstETH's protocol-internal rate (no DEX spot) →
    ///      oracle-manipulation resistant. WETH and stETH are both 18-decimal, so
    ///      no scaling. Floors are vault-favorable (NAV is never over-reported).
    function totalAssets() public view override returns (uint256) {
        uint256 shares = wstETH.balanceOf(address(this));
        if (shares == 0) return 0;
        return (wstETH.getStETHByWstETH(shares) * (MAX_BPS - slippageBps)) / MAX_BPS;
    }

    /// @notice Vault sends WETH here, then calls this: unwrap to ETH, stake to
    ///         stETH (1:1), wrap to wstETH.
    function deposit(uint256 assets)
        external
        override
        onlyVault
        whenNotPaused
        nonReentrant
        returns (uint256 deposited)
    {
        require(assets > 0, "ADAPTER: zero amount");

        // WETH -> ETH. WETH.withdraw sends native ETH to this contract (receive()).
        IWETH9(asset).withdraw(assets);

        // ETH -> stETH via native Lido stake. 1:1, no slippage. Reverts if the
        // deposit would exceed Lido's daily stake limit (see ILidoStETH).
        stETH.submit{value: assets}(address(0));

        // stETH -> wstETH. Wrap the full realized stETH balance to sweep the
        // sub-wei stETH share-rounding dust into the non-rebasing position.
        uint256 stBal = IERC20(address(stETH)).balanceOf(address(this));
        wstETH.wrap(stBal);

        // Entry is principal-exact (native 1:1 stake); report the input amount.
        deposited = assets;
        emit Deposited(assets, deposited);
    }

    /// @notice Sell just enough wstETH on Curve to deliver >= `assets` WETH to
    ///         `recipient`. Never uses the native Lido withdrawal queue.
    /// @dev The Curve leg's `min_dy` enforces the slippage cap against the
    ///      getStETHByWstETH fair value of the wstETH sold; a breach reverts. On a
    ///      full drain (assets >= totalAssets) the entire wstETH balance is sold,
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

        uint256 shares = wstETH.balanceOf(address(this));
        require(shares > 0, "ADAPTER: no position");

        uint256 sharesToSell;
        if (assets >= totalAssets()) {
            // Full exit (recall-all / migration / emergency shutdown): sell all.
            sharesToSell = shares;
        } else {
            // Sell wstETH worth `assets` ETH grossed up by 1/(1-slippage) so that,
            // after slippage, the vault still receives at least `assets`.
            uint256 targetStEth = (assets * MAX_BPS) / (MAX_BPS - slippageBps);
            sharesToSell = wstETH.getWstETHByStETH(targetStEth);
            if (sharesToSell > shares || sharesToSell == 0) sharesToSell = shares;
        }

        // Slippage floor: >= (1 - slippage) of the sold wstETH's fair ETH value.
        // Mirrors totalAssets() so drain-all's floor equals the reported NAV.
        uint256 minEthOut =
            (wstETH.getStETHByWstETH(sharesToSell) * (MAX_BPS - slippageBps)) / MAX_BPS;

        // wstETH -> stETH.
        uint256 stETHOut = wstETH.unwrap(sharesToSell);

        // stETH -> ETH via Curve (raw ETH lands here through receive()).
        uint256 ethBefore = address(this).balance;
        curvePool.exchange(stEthIndex, ethIndex, stETHOut, minEthOut);
        uint256 ethReceived = address(this).balance - ethBefore;

        // ETH -> WETH, forward to recipient.
        IWETH9(asset).deposit{value: ethReceived}();
        withdrawn = ethReceived;
        IERC20(asset).safeTransfer(recipient, withdrawn);
        emit Withdrawn(assets, withdrawn, recipient);
    }

    /// @notice wstETH auto-appreciates via getStETHByWstETH — harvest is a no-op.
    function harvest() external override onlyVault returns (uint256) {
        emit Harvested(0);
        return 0;
    }

    /// @notice Accept native ETH from WETH unwrap and Curve exit only.
    receive() external payable {}

    // =========================================
    // Metadata
    // =========================================

    function name() external pure override returns (string memory) {
        return "SIXX ETH Yield - Lido stETH";
    }

    function providerName() external pure override returns (string memory) {
        return "Lido";
    }

    function adapterType() external pure override returns (string memory) {
        return "DeFi";
    }

    function riskLevel() external pure override returns (uint8) {
        return 2; // staked ETH: slashing + queue + secondary-market discount risk
    }

    /// @notice Representative variable APY in bps. See `description()` disclaimer.
    function estimatedAPY() external view override returns (uint256) {
        return _estimatedApyBps;
    }

    function requiredLockPeriod() external pure override returns (uint256) {
        return 0; // Instant Curve exit; native withdrawal queue intentionally bypassed.
    }

    function isActive() external view override returns (bool) {
        return !_paused;
    }

    /// @notice Mandatory risk disclosure surfaced to integrators/UI.
    function description() external pure returns (string memory) {
        return
            "principal in staked ETH (Lido stETH via wstETH); yield variable (validator rewards), NOT principal-guaranteed; native withdrawal queue bypassed via instant Curve exit; slashing + stETH/ETH discount risk";
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

    /// @notice Set the Curve slippage tolerance / NAV haircut (bps, <= MAX_SLIPPAGE_BPS).
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
    // Token / ETH Rescue
    // =========================================

    /// @notice Recover tokens accidentally sent here. Cannot touch the wstETH
    ///         position, so user principal is never at risk.
    function rescueToken(address token, address to) external returns (uint256 amount) {
        require(msg.sender == governance, "ADAPTER: not governance");
        require(to != address(0), "ADAPTER: zero recipient");
        require(token != address(wstETH), "ADAPTER: cannot rescue position");
        amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    /// @notice Recover raw ETH accidentally left on the adapter (never held at rest;
    ///         only transient during deposit/withdraw). Governance only.
    function rescueETH(address to) external returns (uint256 amount) {
        require(msg.sender == governance, "ADAPTER: not governance");
        require(to != address(0), "ADAPTER: zero recipient");
        amount = address(this).balance;
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "ADAPTER: ETH send failed");
        emit ETHRescued(to, amount);
    }
}
