// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IStrategyAdapter} from "../../src/interfaces/IStrategyAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title PhantomMarkAdapter
/// @notice Adversarial adapter that reports a MARK (totalAssets) which can EXCEED its real
///         token backing — the "realizable < mark" regime (stale oracle / illiquid AMM / bad
///         debt) that E1 identified as the case where 柱3 (liquidity fairness) is at risk.
///         Unlike FaultInjectingAdapter (whose _balance==mark stays honest and only throttles
///         per-call), here the reported mark is DECOUPLED from the deliverable tokens:
///           - deposit(a)              : mark += a, real tokens += a (backed).
///           - withdraw(a)             : delivers min(a, realTokens); mark -= delivered.
///           - makePhantom(amt, sink)  : moves `amt` of real tokens OUT (unrealizable) WITHOUT
///                                       lowering the mark → mark now overstates realizable by amt.
/// @dev Test harness only. Bound to the test vault+governance so setAdapter's M-03 check accepts.
contract PhantomMarkAdapter is IStrategyAdapter {
    using SafeERC20 for IERC20;

    address public override asset;
    address public vault;
    address public governance;
    uint256 private _mark; // reported totalAssets; may exceed real token balance

    constructor(address asset_, address vault_, address governance_) {
        asset = asset_;
        vault = vault_;
        governance = governance_;
    }

    modifier onlyVault() {
        require(msg.sender == vault, "PMA: only vault");
        _;
    }

    function totalAssets() external view override returns (uint256) {
        return _mark;
    }

    function deposit(uint256 assets) external override onlyVault returns (uint256) {
        _mark += assets; // tokens already transferred in by the vault
        emit Deposited(assets, assets);
        return assets;
    }

    function withdraw(uint256 assets, address recipient) external override onlyVault returns (uint256) {
        uint256 bal = IERC20(asset).balanceOf(address(this));
        uint256 send = assets <= bal ? assets : bal;
        _mark = _mark > send ? _mark - send : 0;
        IERC20(asset).safeTransfer(recipient, send);
        emit Withdrawn(assets, send, recipient);
        return send;
    }

    /// @notice Make `amount` of the marked value UNREALIZABLE: remove the tokens but keep the
    ///         mark, so totalAssets() now overstates what withdraw() can ever deliver.
    function makePhantom(uint256 amount, address sink) external {
        IERC20(asset).safeTransfer(sink, amount);
    }

    /// @notice True deliverable tokens right now (for assertions).
    function realBalance() external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function harvest() external override returns (uint256) {
        emit Harvested(0);
        return 0;
    }

    function name() external pure override returns (string memory) { return "Phantom Mark Adapter"; }
    function providerName() external pure override returns (string memory) { return "Adversarial"; }
    function adapterType() external pure override returns (string memory) { return "Test"; }
    function riskLevel() external pure override returns (uint8) { return 5; }
    function estimatedAPY() external pure override returns (uint256) { return 0; }
    function requiredLockPeriod() external pure override returns (uint256) { return 0; }
    function isActive() external pure override returns (bool) { return true; }
    function pause() external override { emit Paused(); }
    function unpause() external override { emit Unpaused(); }
}
