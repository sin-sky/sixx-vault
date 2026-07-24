// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IStrategyAdapter} from "../interfaces/IStrategyAdapter.sol";
import {IAdapterRegistry} from "../interfaces/IAdapterRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title BasketAllocator
/// @notice A *meta* SIXX strategy adapter: it implements `IStrategyAdapter` so the
///         SIXXVault sees it as an ordinary adapter, but internally it splits a
///         single underlying asset across N child adapters (each itself an
///         `IStrategyAdapter`) according to a governance-configured weight vector
///         (basis points, summing to 10_000). This is the on-chain "③運用(basket)"
///         container — the器 (vessel) — for the UI product `run-basket`.
///
/// @dev ── 設定注入方式（configuration-injection）──────────────────────────────
///      Per SHIN's directive the *composition* (which children, at what weights)
///      is intentionally NOT hardcoded. It is injected by governance via
///      `setComponents` / `setWeights`. This file ships only the vessel plus a
///      throwaway placeholder wiring in the deploy/test path.
///
///      TODO(SHIN): 構成銘柄・比率の確定 — decide the concrete child adapter set
///      (e.g. Aave USDC / Morpho curated / Venus …) and their weights, then inject
///      them through `setComponents`. Until then the basket has no components and
///      `deposit` reverts (funds stay idle & safe in the SIXXVault via its M-3
///      try/catch).
///
///      TODO(SHIN): 合成%の2段表示（法務） — the "blended %" that the UI shows for a
///      basket must be rendered as a two-line/2段 figure with the required legal
///      disclaimer. That is a *frontend* concern (see sixx-interface). This
///      contract only exposes `estimatedAPY()` as a weight-blended bps figure for
///      convenience; it is NOT a promise and must not be surfaced verbatim.
///
/// @dev ── 実装慣習（conventions, mirrors AaveV3USDCAdapter / ERC4626Adapter）────
///      * PUSH transfer model: the SIXXVault `safeTransfer`s the underlying to
///        THIS allocator BEFORE calling `deposit()`. In turn, this allocator
///        `safeTransfer`s each child's slice to the child BEFORE calling
///        `child.deposit()`. The existing SIXX adapters expect their funds to
///        already be present ("USDC is already in this contract") and do NO
///        `transferFrom`, so NO ERC20 approvals to children are needed.
///      * `onlyVault` / `whenNotPaused` gating; M-4 two-step rotation of both the
///        SIXX caller (`sixxVault`) and `governance`.
///      * Non-custodial: this contract only ever routes funds between the vault
///        and vetted on-chain adapters. It never holds user keys, never signs on a
///        user's behalf, and holds ~0 idle underlying between transactions.
///      * ReentrancyGuard (`nonReentrant`) on every fund-moving entry point —
///        children may re-enter through ERC-4626 / token hooks.
///
/// @dev ── 安全側の丸め（safe-side rounding）────────────────────────────────────
///      * `totalAssets()` sums ONLY the children's `totalAssets()` (each of which
///        rounds DOWN in the ERC-4626 case). Transient idle underlying dust in
///        this allocator is deliberately EXCLUDED, so the figure never overstates
///        what is redeemable — the SIXXVault share price is protected.
///      * On `deposit`, integer-division dust is handed to the first child, so
///        100% of the received amount is always deployed (no stranded idle).
///      * On `withdraw`, funds are pulled proportionally to each child's *current
///        holdings* (preserving weight ratios), with a second sweep pass to cover
///        rounding remainder, so the full request is delivered whenever aggregate
///        liquidity exists. If a sleeve is illiquid the request under-delivers and
///        the SIXXVault's own `received >= toWithdraw` check reverts safely.
contract BasketAllocator is IStrategyAdapter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================
    // Constants
    // =========================================

    /// @notice Weights are basis points; a full basket must sum to exactly this.
    uint16 public constant TOTAL_WEIGHT = 10_000;

    /// @notice Gas bound on the child set (withdraw/rebalance loop over children).
    uint256 public constant MAX_CHILDREN = 10;

    // =========================================
    // Immutables
    // =========================================

    /// @notice Underlying asset (e.g. USDC) — every child must share it.
    address public immutable override asset;

    /// @notice AdapterRegistry that whitelists which child adapters may be
    ///         injected. Enforces invariant H-1 *inside* the basket: `setComponents`
    ///         rejects any child that is not `isActive` in this registry, so the
    ///         same governance-vetted whitelist the SIXXVault requires for its own
    ///         active adapter also gates every sleeve. Mirrors
    ///         `SIXXVault.adapterRegistry` (immutable, injected at construction).
    /// @dev `address(0)` disables the check (permissionless — testing only), exactly
    ///      as `SIXXVault.setAdapter`'s H-1 branch treats a zero registry. Production
    ///      deployments MUST pass the real registry.
    IAdapterRegistry public immutable adapterRegistry;

    // =========================================
    // Mutable State
    // =========================================

    /// @notice The single SIXXVault allowed to call deposit/withdraw.
    /// @dev Named `sixxVault` to mirror ERC4626Adapter; `onlyVault` checks it.
    address public sixxVault;

    /// @notice M-4: Pending SIXX caller for the 2-step rotation.
    address public pendingSixxVault;

    /// @notice Governance address for admin / composition functions.
    address public governance;

    /// @notice M-4: Pending governance for the 2-step rotation.
    address public pendingGovernance;

    bool private _paused;

    /// @notice Child adapters, index-aligned with `weights`.
    address[] private _children;

    /// @notice Target weight (bps) per child, index-aligned with `_children`.
    uint16[] private _weights;

    /// @notice O(1) membership check for children.
    mapping(address => bool) public isChild;

    // =========================================
    // Events
    // =========================================

    event SixxVaultProposed(address indexed currentVault, address indexed pendingVault);
    event SixxVaultAccepted(address indexed newVault);
    event GovernanceProposed(address indexed currentGovernance, address indexed pendingGovernance);
    event GovernanceAccepted(address indexed newGovernance);

    /// @notice Emitted when the child set and/or weights are (re)configured.
    event ComponentsSet(address[] children, uint16[] weights);
    /// @notice Emitted when weights change (composition unchanged) and funds realign.
    event WeightsUpdated(uint16[] weights);
    /// @notice Emitted after a same-composition realignment to target weights.
    event Rebalanced(uint256 totalRedeployed);
    /// @notice Emitted when governance circuit-breaks a single sleeve.
    event ChildPaused(address indexed child);
    /// @notice Emitted when governance sweeps a stray (non-underlying) token.
    event Rescued(address indexed token, address indexed to, uint256 amount);

    // =========================================
    // Constructor
    // =========================================

    /// @param asset_            Underlying token address (chain-specific).
    /// @param sixxVault_        SIXXVault address (the only deposit/withdraw caller).
    /// @param governance_       Governance EOA or Safe.
    /// @param adapterRegistry_  AdapterRegistry that whitelists injectable children
    ///                          (H-1). `address(0)` disables the check — testing only;
    ///                          production MUST pass the real registry (mirrors
    ///                          `SIXXVault`'s `adapterRegistry_` constructor arg).
    /// @dev Composition is injected AFTER deployment via `setComponents` — the
    ///      basket starts empty on purpose (TODO(SHIN): 構成銘柄・比率の確定).
    constructor(address asset_, address sixxVault_, address governance_, address adapterRegistry_) {
        require(asset_ != address(0), "BASKET: zero asset");
        require(sixxVault_ != address(0), "BASKET: zero sixxVault");
        require(governance_ != address(0), "BASKET: zero governance");

        asset = asset_;
        sixxVault = sixxVault_;
        governance = governance_;
        adapterRegistry = IAdapterRegistry(adapterRegistry_);
    }

    // =========================================
    // Modifiers
    // =========================================

    modifier onlyVault() {
        require(msg.sender == sixxVault, "BASKET: only vault");
        _;
    }

    modifier onlyGovernance() {
        require(msg.sender == governance, "BASKET: only governance");
        _;
    }

    modifier whenNotPaused() {
        require(!_paused, "BASKET: paused");
        _;
    }

    // =========================================
    // Core: IStrategyAdapter
    // =========================================

    /// @notice Sum of all children's `totalAssets()`.
    /// @dev Excludes transient idle underlying held by this allocator (safe-side:
    ///      never overstates redeemable value). Each ERC-4626 child rounds DOWN.
    function totalAssets() public view override returns (uint256 total) {
        uint256 n = _children.length;
        for (uint256 i = 0; i < n; i++) {
            total += IStrategyAdapter(_children[i]).totalAssets();
        }
    }

    /// @notice SIXXVault sends the underlying here, then calls this to split it
    ///         across the children by weight.
    /// @dev PUSH model: the underlying is already held by this allocator. Integer
    ///      dust is handed to the first child so 100% is deployed.
    function deposit(uint256 assets)
        external override onlyVault whenNotPaused nonReentrant returns (uint256 deposited)
    {
        require(assets > 0, "BASKET: zero amount");
        require(_children.length > 0, "BASKET: no components");
        _distribute(assets);
        deposited = assets;
        emit Deposited(assets, deposited);
    }

    /// @notice Withdraw `assets` of underlying, pulling proportionally to each
    ///         child's current holdings and sending directly to `recipient`.
    /// @dev Two passes: (1) proportional-to-holdings pull, (2) sweep the rounding
    ///      remainder from any child still holding funds. Reports the amount the
    ///      children reported returning; the SIXXVault independently re-measures
    ///      its own balance delta and reverts on shortfall.
    function withdraw(uint256 assets, address recipient)
        external override onlyVault nonReentrant returns (uint256 withdrawn)
    {
        require(assets > 0, "BASKET: zero amount");
        require(recipient != address(0), "BASKET: zero recipient");

        uint256 total = totalAssets();
        if (total == 0) {
            emit Withdrawn(assets, 0, recipient);
            return 0;
        }

        uint256 n = _children.length;
        uint256 remaining = assets;

        // Pass 1: proportional to current holdings (preserves weight ratios).
        for (uint256 i = 0; i < n && remaining > 0; i++) {
            address child = _children[i];
            uint256 bal = IStrategyAdapter(child).totalAssets();
            if (bal == 0) continue;
            uint256 want = (assets * bal) / total; // rounds down
            uint256 amt = want < remaining ? want : remaining;
            if (amt > bal) amt = bal;
            if (amt == 0) continue;
            uint256 got = IStrategyAdapter(child).withdraw(amt, recipient);
            withdrawn += got;
            remaining = remaining > got ? remaining - got : 0;
        }

        // Pass 2: sweep the integer-division remainder from any liquid child.
        for (uint256 i = 0; i < n && remaining > 0; i++) {
            address child = _children[i];
            uint256 bal = IStrategyAdapter(child).totalAssets();
            if (bal == 0) continue;
            uint256 amt = remaining < bal ? remaining : bal;
            uint256 got = IStrategyAdapter(child).withdraw(amt, recipient);
            withdrawn += got;
            remaining = remaining > got ? remaining - got : 0;
        }

        emit Withdrawn(assets, withdrawn, recipient);
    }

    /// @notice Harvest every child and return the aggregate gain.
    /// @dev Permissionless (guarded only by `nonReentrant`), mirroring
    ///      ERC4626Adapter: harvesting merely compounds and cannot move funds out.
    ///      Each child's own `onlyVault` (== this allocator) is satisfied because
    ///      THIS allocator is the caller.
    function harvest() external override nonReentrant returns (uint256 harvested) {
        uint256 n = _children.length;
        for (uint256 i = 0; i < n; i++) {
            harvested += IStrategyAdapter(_children[i]).harvest();
        }
        emit Harvested(harvested);
    }

    // =========================================
    // Governance: composition (設定注入)
    // =========================================

    /// @notice Inject / replace the full child set and their weights.
    /// @dev Composition can only change while the basket is EMPTY
    ///      (`totalAssets() == 0`). This is the safe invariant that guarantees no
    ///      stranded funds: to migrate a funded basket, governance first recalls
    ///      all assets (e.g. `SIXXVault.setAdapter(0)` force-recalls this adapter),
    ///      then re-injects components, then redeploys. Use `setWeights` to change
    ///      only the ratios on a funded basket.
    /// @param children_ Child adapters (each an IStrategyAdapter over `asset`).
    /// @param weights_  Basis-point weights, index-aligned, summing to 10_000.
    function setComponents(address[] calldata children_, uint16[] calldata weights_)
        external
        onlyGovernance
    {
        require(totalAssets() == 0, "BASKET: drain before re-composing");
        uint256 n = children_.length;
        require(n > 0, "BASKET: empty set");
        require(n <= MAX_CHILDREN, "BASKET: too many children");
        require(n == weights_.length, "BASKET: length mismatch");

        // Clear the old membership mapping.
        uint256 old = _children.length;
        for (uint256 i = 0; i < old; i++) {
            isChild[_children[i]] = false;
        }
        delete _children;
        delete _weights;

        uint256 sum;
        for (uint256 i = 0; i < n; i++) {
            address child = children_[i];
            require(child != address(0), "BASKET: zero child");
            require(!isChild[child], "BASKET: duplicate child");
            require(weights_[i] > 0, "BASKET: zero weight");
            // Asset-mismatch guard: a child must route the SAME underlying.
            require(IStrategyAdapter(child).asset() == asset, "BASKET: asset mismatch");
            // H-1 (custody hardening): a child must be whitelisted & active in the
            // same AdapterRegistry the SIXXVault enforces. Prevents governance from
            // injecting an unvetted/malicious sleeve that could capture `_distribute`d
            // funds. `address(0)` registry disables the check (testing only).
            require(
                address(adapterRegistry) == address(0) || adapterRegistry.isActive(child),
                "BASKET: child not whitelisted"
            );

            isChild[child] = true;
            _children.push(child);
            _weights.push(weights_[i]);
            sum += weights_[i];
        }
        require(sum == TOTAL_WEIGHT, "BASKET: weights != 10000");

        emit ComponentsSet(children_, weights_);
    }

    /// @notice Change the weights of the CURRENT children and realign holdings.
    /// @dev Same composition, new ratios. Performs a full recall-to-self followed
    ///      by a weighted redeploy, so it requires every child to be liquid enough
    ///      to return its balance. TODO(SHIN): for large baskets consider a
    ///      delta-only rebalance to save gas.
    /// @param weights_ New basis-point weights, index-aligned with current children.
    function setWeights(uint16[] calldata weights_)
        external
        onlyGovernance
        nonReentrant
    {
        uint256 n = _children.length;
        require(n > 0, "BASKET: no components");
        require(weights_.length == n, "BASKET: length mismatch");
        uint256 sum;
        for (uint256 i = 0; i < n; i++) {
            require(weights_[i] > 0, "BASKET: zero weight");
            sum += weights_[i];
        }
        require(sum == TOTAL_WEIGHT, "BASKET: weights != 10000");

        _weights = weights_;
        emit WeightsUpdated(weights_);

        uint256 idle = _recallAllToSelf();
        if (idle > 0) _distribute(idle);
        emit Rebalanced(idle);
    }

    /// @notice Realign current holdings back to the current target weights.
    /// @dev Recalls everything to this allocator, then redeploys by weight. Fixes
    ///      drift accumulated from differing per-sleeve yields. Governance-only.
    function rebalance() external onlyGovernance nonReentrant {
        require(_children.length > 0, "BASKET: no components");
        uint256 idle = _recallAllToSelf();
        if (idle > 0) _distribute(idle);
        emit Rebalanced(idle);
    }

    // =========================================
    // Internal helpers
    // =========================================

    /// @dev Split `amount` of idle underlying across children by weight and PUSH
    ///      each slice. Integer dust is added to the first child so 100% deploys.
    function _distribute(uint256 amount) internal {
        uint256 n = _children.length;
        uint256[] memory slice = new uint256[](n);
        uint256 distributed;
        for (uint256 i = 0; i < n; i++) {
            slice[i] = (amount * _weights[i]) / TOTAL_WEIGHT; // rounds down
            distributed += slice[i];
        }
        // Hand rounding dust to the first child (weights[0] > 0 by construction).
        slice[0] += amount - distributed;

        for (uint256 i = 0; i < n; i++) {
            uint256 amt = slice[i];
            if (amt == 0) continue;
            address child = _children[i];
            IERC20(asset).safeTransfer(child, amt);
            IStrategyAdapter(child).deposit(amt);
        }
    }

    /// @dev Pull every child's entire balance back into this allocator and return
    ///      the resulting idle underlying balance. Uses the measured balance delta
    ///      so it is robust to children that under-report.
    function _recallAllToSelf() internal returns (uint256 idle) {
        uint256 n = _children.length;
        for (uint256 i = 0; i < n; i++) {
            address child = _children[i];
            uint256 bal = IStrategyAdapter(child).totalAssets();
            if (bal > 0) {
                IStrategyAdapter(child).withdraw(bal, address(this));
            }
        }
        idle = IERC20(asset).balanceOf(address(this));
    }

    // =========================================
    // Metadata
    // =========================================

    function name() external pure override returns (string memory) {
        return "SIXX Basket Allocator";
    }

    function providerName() external pure override returns (string memory) {
        return "SIXX";
    }

    function adapterType() external pure override returns (string memory) {
        return "DeFi";
    }

    /// @notice Conservative basket risk = the MAX riskLevel across sleeves.
    /// @dev A basket is at least as risky as its riskiest component. Returns 0 for
    ///      an empty basket. TODO(SHIN): governance may prefer a fixed label.
    function riskLevel() external view override returns (uint8 level) {
        uint256 n = _children.length;
        for (uint256 i = 0; i < n; i++) {
            uint8 r = IStrategyAdapter(_children[i]).riskLevel();
            if (r > level) level = r;
        }
    }

    /// @notice Weight-blended child APY in basis points.
    /// @dev Convenience only. The UI must render the "合成%" as a 2段 figure with
    ///      the legal disclaimer (TODO(SHIN)); do NOT surface this verbatim.
    function estimatedAPY() external view override returns (uint256 blended) {
        uint256 n = _children.length;
        for (uint256 i = 0; i < n; i++) {
            blended += _weights[i] * IStrategyAdapter(_children[i]).estimatedAPY();
        }
        blended = blended / TOTAL_WEIGHT;
    }

    /// @notice Conservative basket lock = the MAX requiredLockPeriod across sleeves.
    function requiredLockPeriod() external view override returns (uint256 lock) {
        uint256 n = _children.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 l = IStrategyAdapter(_children[i]).requiredLockPeriod();
            if (l > lock) lock = l;
        }
    }

    function isActive() external view override returns (bool) {
        return !_paused;
    }

    // =========================================
    // Views
    // =========================================

    /// @notice Current composition: index-aligned children and their weights (bps).
    function components() external view returns (address[] memory, uint16[] memory) {
        return (_children, _weights);
    }

    function childCount() external view returns (uint256) {
        return _children.length;
    }

    function childAt(uint256 index) external view returns (address child, uint16 weight) {
        require(index < _children.length, "BASKET: index oob");
        return (_children[index], _weights[index]);
    }

    /// @notice Underlying held by a single child sleeve.
    function childAssets(address child) external view returns (uint256) {
        require(isChild[child], "BASKET: not a child");
        return IStrategyAdapter(child).totalAssets();
    }

    // =========================================
    // Circuit Breaker
    // =========================================

    /// @notice Pause new basket deposits (governance or the vault).
    function pause() external override {
        require(msg.sender == governance || msg.sender == sixxVault, "BASKET: unauthorized");
        _paused = true;
        emit Paused();
    }

    /// @notice Resume basket deposits (governance only).
    function unpause() external override onlyGovernance {
        _paused = false;
        emit Unpaused();
    }

    /// @notice Circuit-break a single sleeve by pausing its child adapter.
    /// @dev Allowed because SIXX adapters let their own `vault` (== this allocator)
    ///      call `pause()`. NOTE: un-pausing a child requires the CHILD's own
    ///      governance (child.unpause is governance-only), so there is
    ///      deliberately no `unpauseChild` here.
    function pauseChild(address child) external onlyGovernance {
        require(isChild[child], "BASKET: not a child");
        IStrategyAdapter(child).pause();
        emit ChildPaused(child);
    }

    // =========================================
    // Admin (M-4: 2-step rotations)
    // =========================================

    function proposeSixxVault(address newVault) external onlyGovernance {
        require(newVault != address(0), "BASKET: zero vault");
        pendingSixxVault = newVault;
        emit SixxVaultProposed(sixxVault, newVault);
    }

    function acceptSixxVault() external {
        require(msg.sender == pendingSixxVault, "BASKET: not pending vault");
        emit SixxVaultAccepted(pendingSixxVault);
        sixxVault = pendingSixxVault;
        pendingSixxVault = address(0);
    }

    function proposeGovernance(address newGovernance) external onlyGovernance {
        require(newGovernance != address(0), "BASKET: zero address");
        pendingGovernance = newGovernance;
        emit GovernanceProposed(governance, newGovernance);
    }

    function acceptGovernance() external {
        require(msg.sender == pendingGovernance, "BASKET: not pending governance");
        emit GovernanceAccepted(pendingGovernance);
        governance = pendingGovernance;
        pendingGovernance = address(0);
    }

    // =========================================
    // Token Rescue
    // =========================================

    /// @notice Recover a stray token accidentally sent here. The underlying
    ///         `asset` is FORBIDDEN so no in-flight user funds can be swept; child
    ///         positions live inside the children, not here, so they are untouchable.
    function rescueToken(address token, address to) external onlyGovernance returns (uint256 amount) {
        require(to != address(0), "BASKET: zero recipient");
        require(token != asset, "BASKET: cannot rescue underlying");
        amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }
}
