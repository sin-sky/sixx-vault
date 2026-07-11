// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SIXXVault} from "../../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../../src/core/AdapterRegistry.sol";
import {FaultInjectingAdapter} from "../mocks/FaultInjectingAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract SteUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

/// @title StateTransitionEchidna — 別エンジン cross-check (state × fault)
/// @notice Echidna complement to StateTransitionFuzz. Echidna has no cheatcodes, so the
///         harness IS governance + the sole depositor; it fuzzes lifecycle transitions and
///         adapter fault toggles, and asserts the solvency-core fund-protection properties
///         under every reached (state × fault) combination. The multi-actor / pause-mint
///         properties live in the Foundry suite (which can prank distinct actors).
contract StateTransitionEchidna {
    SteUSDC         internal usdc;
    AdapterRegistry internal registry;
    SIXXVault       internal vault;
    FaultInjectingAdapter[3] internal pool;
    int256 internal activeIdx;

    address internal constant FEE_RCPT = address(0xFEE);
    address internal constant GUARDIAN = address(0x6042D);

    uint256 internal ghostDeposited;
    uint256 internal ghostWithdrawn;
    uint256 internal ghostYield;

    uint256 internal constant TOL = 1e4;
    uint256 internal constant MAX_DEPOSIT = 1_000_000e6;

    constructor() {
        usdc = new SteUSDC();
        registry = new AdapterRegistry(address(this));
        vault = new SIXXVault(
            IERC20(address(usdc)), "SIXX Stable Yield", "sxUSDC",
            address(this), address(registry), FEE_RCPT, GUARDIAN
        );
        for (uint256 i = 0; i < 3; i++) {
            pool[i] = new FaultInjectingAdapter(address(usdc), address(vault), address(this));
            registry.registerAdapter(address(pool[i]), "Test", "Fuzz");
        }
        vault.setAdapter(address(pool[0]));
        vault.setManagementFee(0);
        vault.setPerformanceFee(0);
        activeIdx = 0;
    }

    function _active() internal view returns (FaultInjectingAdapter) {
        if (activeIdx < 0) return FaultInjectingAdapter(address(0));
        return pool[uint256(activeIdx)];
    }

    // ── lifecycle actions ──
    function action_deposit(uint256 amt) public {
        amt = 1e6 + (amt % MAX_DEPOSIT);
        usdc.mint(address(this), amt);
        usdc.approve(address(vault), amt);
        try vault.deposit(amt, address(this)) { ghostDeposited += amt; } catch {}
    }

    function action_redeem(uint256 shares) public {
        uint256 bal = vault.balanceOf(address(this));
        if (bal == 0) return;
        shares = 1 + (shares % bal);
        uint256 before = usdc.balanceOf(address(this));
        try vault.redeem(shares, address(this), address(this)) {
            ghostWithdrawn += usdc.balanceOf(address(this)) - before;
        } catch {}
    }

    function action_addYield(uint256 amt) public {
        if (activeIdx < 0 || vault.totalAssets() == 0) return;
        amt = 1 + (amt % (MAX_DEPOSIT / 100));
        usdc.mint(address(this), amt);
        usdc.approve(address(_active()), amt);
        try _active().addYield(amt) { ghostYield += amt; } catch {}
    }

    function action_realizeLoss(uint256 amt) public {
        if (activeIdx < 0) return;
        amt = 1 + (amt % (MAX_DEPOSIT / 50));
        try _active().realizeLoss(amt, address(0xDEAD)) {} catch {}
    }

    function action_harvest() public { try vault.harvest() {} catch {} }
    function action_setFee(uint256 bps) public { try vault.setManagementFee(bps % 501) {} catch {} }

    function action_forceDetach() public {
        if (activeIdx < 0) return;
        try vault.setAdapter(address(0)) { activeIdx = -1; } catch {}
    }

    function action_attach(uint256 seed) public {
        uint256 j = seed % 3;
        if (activeIdx >= 0 && uint256(activeIdx) == j) return;
        try vault.setAdapter(address(pool[j])) { activeIdx = int256(j); } catch {}
    }

    function action_shutdownOn() public { try vault.setEmergencyShutdown(true) {} catch {} }
    function action_shutdownOff() public { try vault.setEmergencyShutdown(false) {} catch {} }
    function action_reopen() public { try vault.reopenDeposits() {} catch {} }

    // ── fault toggles ──
    function fault_revertTotalAssets(bool v) public { if (activeIdx >= 0) _active().setRevertOnTotalAssets(v); }
    function fault_revertWithdraw(bool v) public { if (activeIdx >= 0) _active().setRevertOnWithdraw(v); }
    function fault_deliverBps(uint256 bps) public { if (activeIdx >= 0) _active().setDeliverBps(5_000 + (bps % 5_001)); }

    // ── properties (must always hold under any state × fault) ──

    /// value non-creation: reported NAV never exceeds net value that entered.
    function echidna_value_non_creation() public view returns (bool) {
        uint256 netIn = ghostDeposited + ghostYield;
        uint256 ceiling = netIn > ghostWithdrawn ? netIn - ghostWithdrawn : 0;
        return vault.totalAssets() <= ceiling + TOL;
    }

    /// solvency / no over-claim: outstanding shares never claim more than the reported NAV.
    function echidna_shares_backed() public view returns (bool) {
        return vault.convertToAssets(vault.totalSupply()) <= vault.totalAssets() + TOL;
    }

    /// pause integrity: while impaired, no deposit capacity is advertised.
    function echidna_pause_blocks_deposit() public view returns (bool) {
        if (vault.depositsPaused() || vault.emergencyShutdown()) {
            return vault.maxDeposit(address(this)) == 0 && vault.maxMint(address(this)) == 0;
        }
        return true;
    }

    /// totalAssets() must never revert (H-02) — reads stay live under any fault.
    function echidna_totalAssets_never_reverts() public view returns (bool) {
        vault.totalAssets();
        return true;
    }

    /// MINV-1/5 (multi-adapter): NAV counts ONLY idle + the ACTIVE adapter — a detached /
    /// retired adapter (even faulty or holding stranded funds) never phantom-counts. Exercised
    /// as the harness migrates/detaches among the 3-adapter pool with per-adapter faults.
    function echidna_no_phantom_cross_adapter() public view returns (bool) {
        uint256 idle = usdc.balanceOf(address(vault));
        uint256 activeContribution = 0;
        if (activeIdx >= 0) {
            FaultInjectingAdapter a = pool[uint256(activeIdx)];
            activeContribution = a.revertOnTotalAssets() ? vault.totalDebt() : a.realBalance();
        }
        return vault.totalAssets() <= idle + activeContribution + TOL;
    }
}
