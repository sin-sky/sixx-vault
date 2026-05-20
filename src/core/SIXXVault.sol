// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISIXXVault} from "../interfaces/ISIXXVault.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
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
        public override(ERC4626, IERC4626) nonReentrant returns (uint256)
    {
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public override(ERC4626, IERC4626) nonReentrant returns (uint256)
    {
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public override(ERC4626, IERC4626) nonReentrant returns (uint256)
    {
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public override(ERC4626, IERC4626) nonReentrant returns (uint256)
    {
        return super.redeem(shares, receiver, owner);
    }

    // =========================================
    // ERC-4626: totalAssets
    // =========================================

    /// @notice Vault balance + assets deployed to adapter
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        uint256 adapterAssets = activeAdapter != address(0)
            ? IStrategyAdapter(activeAdapter).totalAssets()
            : 0;
        return IERC20(asset()).balanceOf(address(this)) + adapterAssets;
    }

    // =========================================
    // ERC-4626: maxDeposit / maxMint
    // =========================================

    function maxDeposit(address) public view override(ERC4626, IERC4626) returns (uint256) {
        if (emergencyShutdown) return 0;
        return type(uint256).max;
    }

    function maxMint(address) public view override(ERC4626, IERC4626) returns (uint256) {
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
