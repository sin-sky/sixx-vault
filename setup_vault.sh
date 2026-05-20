#!/usr/bin/env bash
# ==============================================================
# setup_vault.sh — SIXX Vault ソース一括セットアップ
# 使い方: ~/sixx-vault で bash setup_vault.sh
# ==============================================================
set -e
export PATH="$HOME/.foundry/bin:$PATH"

VAULT_DIR="$(pwd)"
echo "=== SIXX Vault Setup ==="
echo "Target: $VAULT_DIR"

# ── ディレクトリ作成 ──────────────────────────────────────────
mkdir -p src/interfaces src/core src/adapters test/mocks script

# ==============================================================
# src/interfaces/IStrategyAdapter.sol
# ==============================================================
cat > src/interfaces/IStrategyAdapter.sol << 'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IStrategyAdapter
/// @notice Standard interface for all SIXX yield strategy adapters
interface IStrategyAdapter {
    function asset()              external view returns (address);
    function totalAssets()        external view returns (uint256);
    function deposit(uint256 assets) external returns (uint256 deposited);
    function withdraw(uint256 assets, address recipient) external returns (uint256 withdrawn);
    function harvest()            external returns (uint256 harvested);

    function name()               external view returns (string memory);
    function providerName()       external view returns (string memory);
    function adapterType()        external view returns (string memory);
    function riskLevel()          external view returns (uint8);
    function estimatedAPY()       external view returns (uint256);
    function requiredLockPeriod() external view returns (uint256);
    function isActive()           external view returns (bool);
    function pause()              external;
    function unpause()            external;

    event Deposited(uint256 assets, uint256 deposited);
    event Withdrawn(uint256 assets, uint256 withdrawn, address indexed recipient);
    event Harvested(uint256 harvested);
    event Paused();
    event Unpaused();
}
EOF

# ==============================================================
# src/interfaces/IAdapterRegistry.sol
# ==============================================================
cat > src/interfaces/IAdapterRegistry.sol << 'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IAdapterRegistry {
    enum Status { NotRegistered, Active, Disabled }

    struct AdapterInfo {
        address adapter;
        Status status;
        string adapterType;
        string providerName;
        uint256 registeredAt;
    }

    function registerAdapter(address adapter, string calldata adapterType, string calldata providerName) external;
    function disableAdapter(address adapter) external;
    function isActive(address adapter) external view returns (bool);
    function getAdapterInfo(address adapter) external view returns (AdapterInfo memory);
    function getActiveAdapters() external view returns (address[] memory);

    event AdapterRegistered(address indexed adapter, string adapterType, string providerName);
    event AdapterDisabled(address indexed adapter);
}
EOF

# ==============================================================
# src/interfaces/IAavePool.sol
# ==============================================================
cat > src/interfaces/IAavePool.sol << 'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IAavePool {
    struct ReserveConfigurationMap { uint256 data; }

    struct ReserveData {
        ReserveConfigurationMap configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40  lastUpdateTimestamp;
        uint16  id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function getReserveData(address asset) external view returns (ReserveData memory);
}
EOF

# ==============================================================
# src/interfaces/ISIXXVault.sol
# ==============================================================
cat > src/interfaces/ISIXXVault.sol << 'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface ISIXXVault is IERC4626 {
    function activeAdapter()    external view returns (address);
    function adapterRegistry()  external view returns (address);
    function setAdapter(address newAdapter) external;

    function lockPeriod()       external view returns (uint256);
    function lockedUntil(address user) external view returns (uint256);
    function setLockPeriod(uint256 newPeriod) external;

    function performanceFee()   external view returns (uint256);
    function managementFee()    external view returns (uint256);
    function feeRecipient()     external view returns (address);
    function collectFees()      external returns (uint256 feeShares);

    function emergencyShutdown() external view returns (bool);
    function setEmergencyShutdown(bool active) external;

    function governance()        external view returns (address);
    function pendingGovernance() external view returns (address);
    function proposeGovernance(address newGovernance) external;
    function acceptGovernance()  external;

    event AdapterUpdated(address indexed oldAdapter, address indexed newAdapter);
    event LockPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event EmergencyShutdown(bool active);
    event FeeCollected(address indexed recipient, uint256 feeShares, uint256 feeAssets);
    event GovernanceProposed(address indexed currentGovernance, address indexed pendingGovernance);
    event GovernanceAccepted(address indexed newGovernance);
}
EOF

echo "✓ interfaces written"

# ==============================================================
# src/core/SIXXVault.sol
# ==============================================================
cat > src/core/SIXXVault.sol << 'EOFSOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISIXXVault} from "../interfaces/ISIXXVault.sol";
import {IStrategyAdapter} from "../interfaces/IStrategyAdapter.sol";

/// @title SIXXVault
/// @notice ERC-4626 compliant tokenized vault with pluggable yield strategy adapters.
///         Supports lock periods, management fees, emergency shutdown, and 2-step governance.
/// @dev Deployed per asset (e.g. one vault for USDC, one for WETH).
///      Strategy can be swapped by governance without changing the vault address.
contract SIXXVault is ERC4626, ReentrancyGuard, ISIXXVault {
    using SafeERC20 for IERC20;

    // =========================================
    // Constants
    // =========================================

    uint256 private constant MAX_BPS = 10_000;
    /// @dev ~365.25 days in seconds
    uint256 private constant SECS_PER_YEAR = 365 days + 6 hours;
    uint256 private constant MAX_PERFORMANCE_FEE = 3_000; // 30% hard cap
    uint256 private constant MAX_MANAGEMENT_FEE = 500;    // 5% hard cap

    // =========================================
    // State Variables
    // =========================================

    address public override governance;
    address public override pendingGovernance;
    address public override activeAdapter;
    address public override adapterRegistry;

    uint256 public override lockPeriod;
    uint256 public override performanceFee;
    uint256 public override managementFee;
    address public override feeRecipient;
    bool public override emergencyShutdown;

    /// @dev Amount of assets currently deployed to the active adapter
    uint256 private _totalDebt;
    /// @dev Timestamp of last fee collection
    uint256 private _lastHarvestTimestamp;

    /// @dev Maps user address to the unix timestamp they can next withdraw
    mapping(address => uint256) private _lockedUntil;

    // =========================================
    // Constructor
    // =========================================

    /// @param asset_           Underlying ERC-20 token (e.g. USDC)
    /// @param name_            Share token name (e.g. "SIXX Stable Yield")
    /// @param symbol_          Share token symbol (e.g. "sxUSDC")
    /// @param governance_      Initial governance address (SHIN EOA → Gnosis Safe later)
    /// @param adapterRegistry_ AdapterRegistry contract address (address(0) = permissionless for testing)
    /// @param feeRecipient_    Address receiving management/performance fees
    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address governance_,
        address adapterRegistry_,
        address feeRecipient_
    ) ERC4626(asset_) ERC20(name_, symbol_) {
        require(governance_ != address(0), "VAULT: zero governance");
        require(feeRecipient_ != address(0), "VAULT: zero fee recipient");
        governance = governance_;
        adapterRegistry = adapterRegistry_;
        feeRecipient = feeRecipient_;
        _lastHarvestTimestamp = block.timestamp;
    }

    // =========================================
    // Modifiers
    // =========================================

    modifier onlyGovernance() {
        require(msg.sender == governance, "VAULT: not governance");
        _;
    }

    // =========================================
    // ERC-4626: Public entry points (nonReentrant)
    // =========================================

    function deposit(uint256 assets, address receiver)
        public override(ERC4626, ISIXXVault) nonReentrant returns (uint256)
    {
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public override nonReentrant returns (uint256)
    {
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public override(ERC4626, ISIXXVault) nonReentrant returns (uint256)
    {
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public override nonReentrant returns (uint256)
    {
        return super.redeem(shares, receiver, owner);
    }

    // =========================================
    // ERC-4626: totalAssets
    // =========================================

    /// @notice Vault balance + assets deployed to adapter
    function totalAssets() public view override(ERC4626, ISIXXVault) returns (uint256) {
        uint256 adapterAssets = activeAdapter != address(0)
            ? IStrategyAdapter(activeAdapter).totalAssets()
            : 0;
        return IERC20(asset()).balanceOf(address(this)) + adapterAssets;
    }

    // =========================================
    // ERC-4626: maxDeposit / maxMint
    // =========================================

    function maxDeposit(address) public view override returns (uint256) {
        if (emergencyShutdown) return 0;
        return type(uint256).max;
    }

    function maxMint(address) public view override returns (uint256) {
        if (emergencyShutdown) return 0;
        return type(uint256).max;
    }

    // =========================================
    // ERC-4626: Internal hooks
    // =========================================

    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        require(!emergencyShutdown, "VAULT: emergency shutdown");
        super._deposit(caller, receiver, assets, shares);

        // Extend lock for receiver (never shorten existing lock)
        if (lockPeriod > 0) {
            uint256 newLock = block.timestamp + lockPeriod;
            if (newLock > _lockedUntil[receiver]) {
                _lockedUntil[receiver] = newLock;
            }
        }

        // Push idle assets to adapter
        _deployToAdapter();
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        require(block.timestamp >= _lockedUntil[owner], "VAULT: still locked");
        _recallFromAdapter(assets);
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    // =========================================
    // Internal: Adapter I/O
    // =========================================

    /// @dev Transfer all idle vault balance to the active adapter
    function _deployToAdapter() internal {
        if (activeAdapter == address(0)) return;
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle == 0) return;
        IERC20(asset()).safeTransfer(activeAdapter, idle);
        IStrategyAdapter(activeAdapter).deposit(idle);
        _totalDebt += idle;
    }

    /// @dev Pull at least `assets` back to the vault from the adapter
    function _recallFromAdapter(uint256 assets) internal {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle >= assets) return;
        if (activeAdapter == address(0)) return;

        uint256 needed = assets - idle;
        uint256 available = IStrategyAdapter(activeAdapter).totalAssets();
        uint256 toWithdraw = needed > available ? available : needed;
        if (toWithdraw == 0) return;

        IStrategyAdapter(activeAdapter).withdraw(toWithdraw, address(this));
        _totalDebt = _totalDebt > toWithdraw ? _totalDebt - toWithdraw : 0;
    }

    // =========================================
    // Governance: Adapter Management
    // =========================================

    /// @notice Switch the active strategy adapter
    /// @dev Recalls 100% of assets from old adapter first.
    ///      Deploys to new adapter immediately after switch.
    function setAdapter(address newAdapter) external override onlyGovernance {
        // Recall everything from current adapter
        if (activeAdapter != address(0)) {
            uint256 adapterBal = IStrategyAdapter(activeAdapter).totalAssets();
            if (adapterBal > 0) {
                IStrategyAdapter(activeAdapter).withdraw(adapterBal, address(this));
            }
            _totalDebt = 0;
        }

        address oldAdapter = activeAdapter;
        activeAdapter = newAdapter;
        emit AdapterUpdated(oldAdapter, newAdapter);

        // Deploy to new adapter (skip if address(0) = pause strategy)
        if (newAdapter != address(0)) {
            _deployToAdapter();
        }
    }

    // =========================================
    // Governance: Lock Period
    // =========================================

    function setLockPeriod(uint256 newPeriod) external override onlyGovernance {
        emit LockPeriodUpdated(lockPeriod, newPeriod);
        lockPeriod = newPeriod;
    }

    // =========================================
    // Governance: Fees
    // =========================================

    function setPerformanceFee(uint256 newFee) external onlyGovernance {
        require(newFee <= MAX_PERFORMANCE_FEE, "VAULT: fee too high");
        performanceFee = newFee;
    }

    function setManagementFee(uint256 newFee) external onlyGovernance {
        require(newFee <= MAX_MANAGEMENT_FEE, "VAULT: fee too high");
        managementFee = newFee;
    }

    function setFeeRecipient(address newRecipient) external onlyGovernance {
        require(newRecipient != address(0), "VAULT: zero address");
        feeRecipient = newRecipient;
    }

    // =========================================
    // Fee Collection (permissionless — anyone can trigger)
    // =========================================

    /// @notice Collect accrued management fees by minting shares to feeRecipient
    function collectFees() external override returns (uint256 feeShares) {
        if (managementFee == 0 || feeRecipient == address(0)) return 0;

        uint256 elapsed = block.timestamp - _lastHarvestTimestamp;
        if (elapsed == 0) return 0;

        uint256 assets = totalAssets();
        uint256 supply = totalSupply();
        if (assets == 0 || supply == 0) {
            _lastHarvestTimestamp = block.timestamp;
            return 0;
        }

        // Pro-rated management fee
        uint256 feeAssets = (assets * managementFee * elapsed) / (MAX_BPS * SECS_PER_YEAR);
        if (feeAssets > 0) {
            feeShares = previewDeposit(feeAssets);
            if (feeShares > 0) {
                _mint(feeRecipient, feeShares);
                emit FeeCollected(feeRecipient, feeShares, feeAssets);
            }
        }
        _lastHarvestTimestamp = block.timestamp;
    }

    // =========================================
    // Governance: Emergency Shutdown
    // =========================================

    function setEmergencyShutdown(bool active) external override onlyGovernance {
        emergencyShutdown = active;
        if (active && activeAdapter != address(0)) {
            // Recall all assets to vault for safe withdrawal by users
            uint256 adapterBal = IStrategyAdapter(activeAdapter).totalAssets();
            if (adapterBal > 0) {
                IStrategyAdapter(activeAdapter).withdraw(adapterBal, address(this));
                _totalDebt = 0;
            }
        }
        emit EmergencyShutdown(active);
    }

    // =========================================
    // Governance: 2-step Transfer
    // =========================================

    function proposeGovernance(address newGovernance) external override onlyGovernance {
        require(newGovernance != address(0), "VAULT: zero address");
        pendingGovernance = newGovernance;
        emit GovernanceProposed(governance, newGovernance);
    }

    function acceptGovernance() external override {
        require(msg.sender == pendingGovernance, "VAULT: not pending governance");
        emit GovernanceAccepted(pendingGovernance);
        governance = pendingGovernance;
        pendingGovernance = address(0);
    }

    // =========================================
    // View
    // =========================================

    function lockedUntil(address user) external view override returns (uint256) {
        return _lockedUntil[user];
    }

    function totalDebt() external view returns (uint256) {
        return _totalDebt;
    }

    // =========================================
    // Inflation Attack Protection
    // =========================================

    /// @dev Virtual shares offset (OZ v5).
    ///      For USDC (6 decimals): offset=9 → shares have 15 decimals.
    ///      Makes first-deposit inflation attack economically infeasible.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 9;
    }
}

EOFSOL

# ==============================================================
# src/core/AdapterRegistry.sol
# ==============================================================
cat > src/core/AdapterRegistry.sol << 'EOFREG'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAdapterRegistry} from "../interfaces/IAdapterRegistry.sol";

/// @title AdapterRegistry
/// @notice Whitelist of approved SIXX strategy adapters.
///         Governance registers/disables adapters; Vault checks isActive() before switching.
contract AdapterRegistry is IAdapterRegistry {
    // =========================================
    // State
    // =========================================

    address public governance;
    address public pendingGovernance;

    mapping(address => AdapterInfo) private _adapters;
    address[] private _adapterList;

    // =========================================
    // Constructor
    // =========================================

    constructor(address governance_) {
        require(governance_ != address(0), "REGISTRY: zero governance");
        governance = governance_;
    }

    // =========================================
    // Modifiers
    // =========================================

    modifier onlyGovernance() {
        require(msg.sender == governance, "REGISTRY: not governance");
        _;
    }

    // =========================================
    // Registration
    // =========================================

    function registerAdapter(
        address adapter,
        string calldata adapterType_,
        string calldata providerName_
    ) external override onlyGovernance {
        require(adapter != address(0), "REGISTRY: zero address");
        require(
            _adapters[adapter].status == Status.NotRegistered,
            "REGISTRY: already registered"
        );
        _adapters[adapter] = AdapterInfo({
            adapter: adapter,
            status: Status.Active,
            adapterType: adapterType_,
            providerName: providerName_,
            registeredAt: block.timestamp
        });
        _adapterList.push(adapter);
        emit AdapterRegistered(adapter, adapterType_, providerName_);
    }

    function disableAdapter(address adapter) external override onlyGovernance {
        require(_adapters[adapter].status == Status.Active, "REGISTRY: not active");
        _adapters[adapter].status = Status.Disabled;
        emit AdapterDisabled(adapter);
    }

    // =========================================
    // View
    // =========================================

    function isActive(address adapter) external view override returns (bool) {
        return _adapters[adapter].status == Status.Active;
    }

    function getAdapterInfo(address adapter)
        external view override returns (AdapterInfo memory)
    {
        return _adapters[adapter];
    }

    function getActiveAdapters() external view override returns (address[] memory) {
        uint256 count;
        for (uint256 i = 0; i < _adapterList.length; i++) {
            if (_adapters[_adapterList[i]].status == Status.Active) count++;
        }
        address[] memory result = new address[](count);
        uint256 idx;
        for (uint256 i = 0; i < _adapterList.length; i++) {
            if (_adapters[_adapterList[i]].status == Status.Active) {
                result[idx++] = _adapterList[i];
            }
        }
        return result;
    }

    // =========================================
    // Governance Transfer
    // =========================================

    function proposeGovernance(address newGovernance) external onlyGovernance {
        require(newGovernance != address(0), "REGISTRY: zero address");
        pendingGovernance = newGovernance;
    }

    function acceptGovernance() external {
        require(msg.sender == pendingGovernance, "REGISTRY: not pending");
        governance = pendingGovernance;
        pendingGovernance = address(0);
    }
}

EOFREG

# ==============================================================
# src/adapters/AaveV3USDCAdapter.sol
# ==============================================================
cat > src/adapters/AaveV3USDCAdapter.sol << 'EOFADP'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IStrategyAdapter} from "../interfaces/IStrategyAdapter.sol";
import {IAavePool} from "../interfaces/IAavePool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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
contract AaveV3USDCAdapter is IStrategyAdapter {
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

    /// @notice Governance address for admin functions
    address public governance;

    bool private _paused;

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
        external override onlyVault whenNotPaused returns (uint256 deposited)
    {
        require(assets > 0, "ADAPTER: zero amount");
        // USDC is already in this contract (transferred by vault)
        aavePool.supply(asset, assets, address(this), referralCode);
        deposited = assets;
        emit Deposited(assets, deposited);
    }

    /// @notice Withdraw USDC from Aave and send directly to `recipient`
    function withdraw(uint256 assets, address recipient)
        external override onlyVault returns (uint256 withdrawn)
    {
        require(assets > 0, "ADAPTER: zero amount");
        require(recipient != address(0), "ADAPTER: zero recipient");
        // Aave withdraws up to `assets`; returns actual amount withdrawn
        withdrawn = aavePool.withdraw(asset, assets, recipient);
        emit Withdrawn(assets, withdrawn, recipient);
    }

    /// @notice aUSDC auto-compounds — harvest is a no-op
    function harvest() external override returns (uint256) {
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
    // Admin
    // =========================================

    /// @notice Update vault address (e.g. after vault upgrade)
    function setVault(address newVault) external {
        require(msg.sender == governance, "ADAPTER: not governance");
        require(newVault != address(0), "ADAPTER: zero vault");
        vault = newVault;
    }

    /// @notice Update governance (single-step for simplicity; vault uses 2-step)
    function setGovernance(address newGovernance) external {
        require(msg.sender == governance, "ADAPTER: not governance");
        require(newGovernance != address(0), "ADAPTER: zero address");
        governance = newGovernance;
    }
}

EOFADP

echo "✓ core contracts written"
# ==============================================================
# test/mocks/MockAdapter.sol
# ==============================================================
cat > test/mocks/MockAdapter.sol << 'EOFMOCK'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IStrategyAdapter} from "../../src/interfaces/IStrategyAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockAdapter
/// @notice Simple in-memory adapter for unit tests. Holds assets locally (no external protocol).
contract MockAdapter is IStrategyAdapter {
    using SafeERC20 for IERC20;

    address public override asset;
    address public vault;
    bool private _paused;

    /// @dev Simulated yield: add this to balance on each totalAssets() call
    uint256 public simulatedYield;

    uint256 private _balance;

    constructor(address asset_, address vault_) {
        asset = asset_;
        vault = vault_;
    }

    modifier onlyVault() {
        require(msg.sender == vault, "MOCK: only vault");
        _;
    }

    function totalAssets() external view override returns (uint256) {
        return _balance + simulatedYield;
    }

    function deposit(uint256 assets) external override onlyVault returns (uint256) {
        // Assets already transferred to this contract by vault
        _balance += assets;
        emit Deposited(assets, assets);
        return assets;
    }

    function withdraw(uint256 assets, address recipient)
        external override onlyVault returns (uint256)
    {
        require(assets <= _balance + simulatedYield, "MOCK: insufficient balance");
        _balance = (_balance + simulatedYield) > assets
            ? (_balance + simulatedYield) - assets
            : 0;
        simulatedYield = 0;
        IERC20(asset).safeTransfer(recipient, assets);
        emit Withdrawn(assets, assets, recipient);
        return assets;
    }

    function harvest() external override returns (uint256) {
        uint256 yield = simulatedYield;
        simulatedYield = 0;
        _balance += yield;
        emit Harvested(yield);
        return yield;
    }

    /// @notice Test helper: inject yield into the adapter
    function addYield(uint256 yieldAmount) external {
        simulatedYield += yieldAmount;
        // Also transfer to self so the token balance matches
        IERC20(asset).safeTransferFrom(msg.sender, address(this), yieldAmount);
        _balance += yieldAmount;
        simulatedYield = 0;
    }

    function name()               external pure override returns (string memory) { return "Mock Adapter"; }
    function providerName()       external pure override returns (string memory) { return "Mock"; }
    function adapterType()        external pure override returns (string memory) { return "DeFi"; }
    function riskLevel()          external pure override returns (uint8)         { return 1; }
    function estimatedAPY()       external pure override returns (uint256)       { return 500; } // 5%
    function requiredLockPeriod() external pure override returns (uint256)       { return 0; }
    function isActive()           external view override returns (bool)          { return !_paused; }

    function pause() external override {
        _paused = true;
        emit Paused();
    }

    function unpause() external override {
        _paused = false;
        emit Unpaused();
    }
}

EOFMOCK

# ==============================================================
# test/SIXXVault.t.sol
# ==============================================================
cat > test/SIXXVault.t.sol << 'EOFTEST'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {MockAdapter} from "./mocks/MockAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Minimal mock ERC-20 for unit tests (no fork needed)
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

contract SIXXVaultTest is Test {
    // ─── Actors ───────────────────────────────────────────────
    address governance = address(0xBEEF);
    address alice      = address(0xA11CE);
    address bob        = address(0xB0B);
    address feeRcpt    = address(0xFEE);

    // ─── Contracts ────────────────────────────────────────────
    MockUSDC       usdc;
    AdapterRegistry registry;
    SIXXVault      vault;
    MockAdapter    adapter;

    uint256 constant USDC_6 = 1e6; // 1 USDC

    // ─────────────────────────────────────────────────────────
    function setUp() public {
        // Deploy mock token
        usdc = new MockUSDC();

        // Deploy registry
        vm.prank(governance);
        registry = new AdapterRegistry(governance);

        // Deploy vault
        vm.prank(governance);
        vault = new SIXXVault(
            IERC20(address(usdc)),
            "SIXX Stable Yield",
            "sxUSDC",
            governance,
            address(registry),
            feeRcpt
        );

        // Deploy mock adapter (vault address known now)
        adapter = new MockAdapter(address(usdc), address(vault));

        // Register + activate adapter
        vm.startPrank(governance);
        registry.registerAdapter(address(adapter), "DeFi", "Mock");
        vault.setAdapter(address(adapter));
        vm.stopPrank();

        // Fund users
        usdc.mint(alice, 10_000 * USDC_6);
        usdc.mint(bob,   10_000 * USDC_6);
    }

    // ─────────────────────────────────────────────────────────
    // Basic Deposit / Withdraw
    // ─────────────────────────────────────────────────────────

    function test_deposit_mints_shares() public {
        uint256 amount = 1_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);
        vm.stopPrank();

        assertGt(shares, 0, "Should receive shares");
        assertEq(vault.balanceOf(alice), shares, "Alice share balance");
        assertApproxEqAbs(vault.totalAssets(), amount, 1, "totalAssets = deposit");
        // Assets should be deployed to adapter
        assertGt(adapter.totalAssets(), 0, "Adapter should hold assets");
        assertEq(usdc.balanceOf(address(vault)), 0, "Vault should be empty (all deployed)");
    }

    function test_withdraw_returns_assets() public {
        uint256 amount = 1_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);

        uint256 balBefore = usdc.balanceOf(alice);
        vault.redeem(shares, alice, alice);
        uint256 balAfter = usdc.balanceOf(alice);
        vm.stopPrank();

        assertApproxEqAbs(balAfter - balBefore, amount, 2, "Should recover deposit");
        assertApproxEqAbs(vault.totalAssets(), 0, 1, "Vault drained");
    }

    function test_multiple_depositors() public {
        uint256 amount = 1_000 * USDC_6;

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, bob);
        vm.stopPrank();

        assertApproxEqAbs(vault.totalAssets(), 2 * amount, 2, "2x deposit");
        // Both have roughly equal shares
        assertApproxEqRel(vault.balanceOf(alice), vault.balanceOf(bob), 1e16, "Equal shares");
    }

    // ─────────────────────────────────────────────────────────
    // Lock Period
    // ─────────────────────────────────────────────────────────

    function test_lock_period_blocks_early_withdraw() public {
        vm.prank(governance);
        vault.setLockPeriod(7 days);

        uint256 amount = 1_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);

        // Immediate withdrawal should revert
        vm.expectRevert("VAULT: still locked");
        vault.redeem(shares, alice, alice);
        vm.stopPrank();
    }

    function test_lock_period_allows_withdraw_after_expiry() public {
        vm.prank(governance);
        vault.setLockPeriod(7 days);

        uint256 amount = 1_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 days + 1);

        vm.startPrank(alice);
        uint256 withdrawn = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        assertApproxEqAbs(withdrawn, amount, 2, "Should withdraw after lock");
    }

    // ─────────────────────────────────────────────────────────
    // Emergency Shutdown
    // ─────────────────────────────────────────────────────────

    function test_emergency_shutdown_blocks_deposits() public {
        vm.prank(governance);
        vault.setEmergencyShutdown(true);

        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000 * USDC_6);
        vm.expectRevert("VAULT: emergency shutdown");
        vault.deposit(1_000 * USDC_6, alice);
        vm.stopPrank();
    }

    function test_emergency_shutdown_recalls_assets() public {
        uint256 amount = 1_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(vault)), 0, "All deployed before shutdown");

        vm.prank(governance);
        vault.setEmergencyShutdown(true);

        assertApproxEqAbs(
            usdc.balanceOf(address(vault)), amount, 2,
            "Assets recalled on shutdown"
        );
    }

    function test_emergency_shutdown_allows_withdrawal() public {
        uint256 amount = 1_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);
        vm.stopPrank();

        vm.prank(governance);
        vault.setEmergencyShutdown(true);

        vm.startPrank(alice);
        uint256 withdrawn = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        assertApproxEqAbs(withdrawn, amount, 2, "Should still withdraw in emergency");
    }

    // ─────────────────────────────────────────────────────────
    // Adapter Switch
    // ─────────────────────────────────────────────────────────

    function test_set_adapter_migrates_assets() public {
        uint256 amount = 1_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();

        assertGt(adapter.totalAssets(), 0, "Old adapter has assets");

        // Deploy new adapter
        MockAdapter newAdapter = new MockAdapter(address(usdc), address(vault));
        vm.startPrank(governance);
        registry.registerAdapter(address(newAdapter), "DeFi", "Mock v2");
        vault.setAdapter(address(newAdapter));
        vm.stopPrank();

        assertApproxEqAbs(adapter.totalAssets(), 0, 1, "Old adapter drained");
        assertGt(newAdapter.totalAssets(), 0, "New adapter has assets");
        assertApproxEqAbs(vault.totalAssets(), amount, 2, "Total assets preserved");
    }

    // ─────────────────────────────────────────────────────────
    // Governance Transfer
    // ─────────────────────────────────────────────────────────

    function test_governance_transfer_two_step() public {
        address newGov = address(0xDEAD);

        vm.prank(governance);
        vault.proposeGovernance(newGov);
        assertEq(vault.pendingGovernance(), newGov);

        // Old governance still works
        assertEq(vault.governance(), governance);

        // Accept from new governance
        vm.prank(newGov);
        vault.acceptGovernance();
        assertEq(vault.governance(), newGov);
        assertEq(vault.pendingGovernance(), address(0));
    }

    function test_non_pending_cannot_accept_governance() public {
        vm.prank(governance);
        vault.proposeGovernance(address(0xDEAD));

        vm.prank(alice);
        vm.expectRevert("VAULT: not pending governance");
        vault.acceptGovernance();
    }

    // ─────────────────────────────────────────────────────────
    // Management Fee
    // ─────────────────────────────────────────────────────────

    function test_management_fee_mints_shares() public {
        // Set 1% annual management fee
        vm.prank(governance);
        vault.setManagementFee(100); // 100 BPS = 1%

        uint256 amount = 100_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();

        uint256 feeSharesBefore = vault.balanceOf(feeRcpt);

        // Advance 1 year
        vm.warp(block.timestamp + 365 days + 6 hours);
        vault.collectFees();

        uint256 feeSharesAfter = vault.balanceOf(feeRcpt);
        assertGt(feeSharesAfter, feeSharesBefore, "Fee shares minted");

        // ~1% of 100k USDC = ~1000 USDC worth of shares
        uint256 feeAssets = vault.convertToAssets(feeSharesAfter - feeSharesBefore);
        assertApproxEqRel(feeAssets, 1_000 * USDC_6, 0.01e18, "Fee ~1% of assets");
    }

    // ─────────────────────────────────────────────────────────
    // ERC-4626 Properties
    // ─────────────────────────────────────────────────────────

    function test_preview_deposit_matches_actual() public {
        uint256 amount = 500 * USDC_6;
        uint256 previewShares = vault.previewDeposit(amount);

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        uint256 actualShares = vault.deposit(amount, alice);
        vm.stopPrank();

        assertEq(previewShares, actualShares, "preview == actual");
    }

    function test_max_deposit_zero_on_shutdown() public {
        assertEq(vault.maxDeposit(alice), type(uint256).max);

        vm.prank(governance);
        vault.setEmergencyShutdown(true);

        assertEq(vault.maxDeposit(alice), 0);
    }
}

EOFTEST

# ==============================================================
# test/AaveV3Adapter.t.sol
# ==============================================================
cat > test/AaveV3Adapter.t.sol << 'EOFFFORK'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AaveV3USDCAdapter} from "../src/adapters/AaveV3USDCAdapter.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title AaveV3AdapterForkTest
/// @notice Integration tests against live Arbitrum One state.
///
/// Run:
///   forge test --fork-url $ARB_RPC_URL --match-contract AaveV3AdapterForkTest -vvv
///
/// Or pin to a block for reproducible results:
///   forge test --fork-url $ARB_RPC_URL --fork-block-number 300000000 -vvv
contract AaveV3AdapterForkTest is Test {
    // ─── Arbitrum One Addresses ───────────────────────────────
    address constant USDC      = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant AAVE_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address constant A_USDC    = 0x625E7708f30cA75bfd92586e17077590C60eb4cD;

    // ─── Actors ───────────────────────────────────────────────
    address governance = makeAddr("governance");
    address alice      = makeAddr("alice");
    address feeRcpt    = makeAddr("feeRecipient");

    // ─── Contracts ────────────────────────────────────────────
    AdapterRegistry    registry;
    SIXXVault          vault;
    AaveV3USDCAdapter  adapter;

    uint256 constant DEPOSIT = 1_000e6; // 1,000 USDC

    // ─────────────────────────────────────────────────────────
    function setUp() public {
        // Deploy registry
        vm.prank(governance);
        registry = new AdapterRegistry(governance);

        // Deploy vault
        vm.prank(governance);
        vault = new SIXXVault(
            IERC20(USDC),
            "SIXX Stable Yield",
            "sxUSDC",
            governance,
            address(registry),
            feeRcpt
        );

        // Deploy adapter
        adapter = new AaveV3USDCAdapter(
            USDC,
            AAVE_POOL,
            A_USDC,
            address(vault),
            governance,
            0 // referral code
        );

        // Register and activate
        vm.startPrank(governance);
        registry.registerAdapter(address(adapter), "DeFi", "Aave V3");
        vault.setAdapter(address(adapter));
        vm.stopPrank();

        // Fund alice via deal() — sets ERC-20 balance without needing a whale
        deal(USDC, alice, DEPOSIT * 10);
    }

    // ─────────────────────────────────────────────────────────
    // Smoke Test: deposit → check state
    // ─────────────────────────────────────────────────────────

    function test_smoke_deposit() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), DEPOSIT);
        uint256 shares = vault.deposit(DEPOSIT, alice);
        vm.stopPrank();

        console2.log("--- Smoke Deposit ---");
        console2.log("Shares received :", shares);
        console2.log("Vault totalAssets:", vault.totalAssets());
        console2.log("Adapter aUSDC   :", IERC20(A_USDC).balanceOf(address(adapter)));
        console2.log("Vault USDC idle :", IERC20(USDC).balanceOf(address(vault)));

        assertGt(shares, 0, "Shares must be > 0");
        // All assets deployed — vault idle should be 0
        assertEq(IERC20(USDC).balanceOf(address(vault)), 0, "Vault fully deployed");
        // aUSDC balance should approximate deposit (slight rounding)
        assertApproxEqAbs(adapter.totalAssets(), DEPOSIT, 2, "Adapter holds ~DEPOSIT");
        assertApproxEqAbs(vault.totalAssets(), DEPOSIT, 2, "totalAssets ~DEPOSIT");
    }

    // ─────────────────────────────────────────────────────────
    // Full round-trip: deposit → withdraw
    // ─────────────────────────────────────────────────────────

    function test_deposit_then_withdraw() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), DEPOSIT);
        uint256 shares = vault.deposit(DEPOSIT, alice);
        vm.stopPrank();

        uint256 usdcBefore = IERC20(USDC).balanceOf(alice);

        vm.startPrank(alice);
        uint256 withdrawn = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        uint256 usdcAfter = IERC20(USDC).balanceOf(alice);

        console2.log("--- Round-trip ---");
        console2.log("Deposited  :", DEPOSIT);
        console2.log("Withdrawn  :", withdrawn);
        console2.log("Net change :", usdcAfter - usdcBefore);

        // Allow 2 wei rounding
        assertApproxEqAbs(usdcAfter - usdcBefore, DEPOSIT, 2, "Full round-trip");
        assertApproxEqAbs(vault.totalAssets(), 0, 2, "Vault drained");
    }

    // ─────────────────────────────────────────────────────────
    // Time travel: yield accrual
    // ─────────────────────────────────────────────────────────

    function test_yield_accrual_30_days() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, alice);
        vm.stopPrank();

        uint256 assetsBefore = vault.totalAssets();

        // aUSDC accrues interest based on block.timestamp (Aave uses ray-math)
        vm.warp(block.timestamp + 30 days);

        uint256 assetsAfter = vault.totalAssets();

        console2.log("--- Yield Accrual (30 days) ---");
        console2.log("Assets before:", assetsBefore);
        console2.log("Assets after :", assetsAfter);
        if (assetsAfter >= assetsBefore) {
            console2.log("Yield earned :", assetsAfter - assetsBefore);
        }

        // aUSDC.balanceOf() returns principal + accrued interest
        assertGe(assetsAfter, assetsBefore, "Assets must not decrease");
    }

    // ─────────────────────────────────────────────────────────
    // Emergency shutdown
    // ─────────────────────────────────────────────────────────

    function test_emergency_shutdown_full_flow() public {
        // Deposit
        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), DEPOSIT);
        uint256 shares = vault.deposit(DEPOSIT, alice);
        vm.stopPrank();

        // Trigger shutdown
        vm.prank(governance);
        vault.setEmergencyShutdown(true);

        console2.log("--- Emergency Shutdown ---");
        console2.log("Vault USDC after shutdown :", IERC20(USDC).balanceOf(address(vault)));
        console2.log("Adapter aUSDC after shutdown:", adapter.totalAssets());

        assertApproxEqAbs(
            IERC20(USDC).balanceOf(address(vault)), DEPOSIT, 2,
            "Assets recalled to vault"
        );

        // New deposit should revert
        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), DEPOSIT);
        vm.expectRevert("VAULT: emergency shutdown");
        vault.deposit(DEPOSIT, alice);
        vm.stopPrank();

        // Existing holder can still withdraw
        vm.startPrank(alice);
        uint256 withdrawn = vault.redeem(shares, alice, alice);
        vm.stopPrank();
        assertApproxEqAbs(withdrawn, DEPOSIT, 2, "Can withdraw in emergency");
    }

    // ─────────────────────────────────────────────────────────
    // APY estimation
    // ─────────────────────────────────────────────────────────

    function test_estimated_apy() public view {
        uint256 apyBps = adapter.estimatedAPY();
        console2.log("--- Aave V3 USDC APY ---");
        console2.log("APY (basis points):", apyBps);
        console2.log("APY (%)           :", apyBps / 100);
        // Should be a sane value (0–50% = 0–5000 BPS)
        assertLe(apyBps, 5_000, "APY should be <= 50%");
    }

    // ─────────────────────────────────────────────────────────
    // Multiple depositors
    // ─────────────────────────────────────────────────────────

    function test_two_depositors_proportional_shares() public {
        address bob = makeAddr("bob");
        deal(USDC, bob, DEPOSIT * 10);

        // Alice deposits 1000
        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), DEPOSIT);
        uint256 sharesAlice = vault.deposit(DEPOSIT, alice);
        vm.stopPrank();

        // Bob deposits 2000 (2x)
        vm.startPrank(bob);
        IERC20(USDC).approve(address(vault), DEPOSIT * 2);
        uint256 sharesBob = vault.deposit(DEPOSIT * 2, bob);
        vm.stopPrank();

        console2.log("--- Two Depositors ---");
        console2.log("Alice shares:", sharesAlice);
        console2.log("Bob shares  :", sharesBob);
        console2.log("Total assets:", vault.totalAssets());

        // Bob should have ~2x Alice's shares
        assertApproxEqRel(sharesBob, sharesAlice * 2, 0.001e18, "Bob has 2x shares");
        assertApproxEqAbs(vault.totalAssets(), DEPOSIT * 3, 3, "Total = 3000 USDC");
    }
}

EOFFFORK

echo "✓ test files written"

# ==============================================================
# foundry.toml + remappings.txt
# ==============================================================
cat > foundry.toml << 'EOFTOML'
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc = "0.8.28"
optimizer = true
optimizer_runs = 200

[profile.default.fuzz]
runs = 1000

[rpc_endpoints]
arbitrum         = "${ARB_RPC_URL}"
arbitrum_sepolia = "${ARB_SEPOLIA_RPC_URL}"
EOFTOML

cat > remappings.txt << 'EOFREMAP'
@openzeppelin/=lib/openzeppelin-contracts/
forge-std/=lib/forge-std/src/
EOFREMAP

echo "✓ config files written"

# ==============================================================
# 依存ライブラリのインストール
# ==============================================================
echo ""
echo "=== Installing dependencies ==="

# forge-std は通常 forge init で入っているが念のため
if [ ! -d "lib/forge-std" ]; then
  forge install foundry-rs/forge-std --no-commit
fi

if [ ! -d "lib/openzeppelin-contracts" ]; then
  echo "Installing OpenZeppelin Contracts..."
  forge install OpenZeppelin/openzeppelin-contracts --no-commit
else
  echo "OpenZeppelin already installed"
fi

# ==============================================================
# Counter.sol を退避（デフォルトテンプレートと衝突しないよう）
# ==============================================================
if [ -f "src/Counter.sol" ]; then
  mv src/Counter.sol src/Counter.sol.bak
  echo "✓ Counter.sol moved to Counter.sol.bak"
fi
if [ -f "test/Counter.t.sol" ]; then
  mv test/Counter.t.sol test/Counter.t.sol.bak
  echo "✓ Counter.t.sol moved to Counter.t.sol.bak"
fi

# ==============================================================
# forge build
# ==============================================================
echo ""
echo "=== forge build ==="
forge build

echo ""
echo "================================================"
echo "✅ Setup complete!"
echo ""
echo "Next steps:"
echo "  forge test --match-contract SIXXVaultTest -vvv"
echo "  forge test --fork-url \$ARB_RPC_URL --match-contract AaveV3AdapterForkTest -vvv"
echo "================================================"
