// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {FaultyAdapter} from "./mocks/FaultyAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract StressUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

/// @title Stress-exit freeze — PoC for Threat Council finding #1 (liveness, HIGH)
/// @notice Documents (does NOT fix) the "cannot de-risk under stress" failure mode found by
///         the 2026-07-11 threat council. When an adapter's realizable value drops below its
///         reported NAV mark (`received < mark` — depeg / slippage beyond the haircut), the
///         `require(received >= mark)` guard (M13-16) makes BOTH user withdrawal AND
///         governance detach revert. The emergency-shutdown valve is resilient to a reverting
///         `withdraw` (try/catch) but is BRITTLE to a reverting `totalAssets()` (read outside
///         the try/catch). These tests pin the current behaviour so a future core fix
///         (force-detach + totalAssets try/catch — see workspace ADR-007, requires SHIN
///         sign-off + re-audit) has an explicit target; they will be flipped when it lands.
/// @dev Mark > realizable is modelled with FaultyAdapter.setDeliverBps(< 10000).
contract StressExitFreezeTest is Test {
    StressUSDC      usdc;
    AdapterRegistry registry;
    SIXXVault       vault;
    FaultyAdapter   faulty;

    address governance   = address(0xBEEF);
    address alice        = address(0xA11CE);
    address feeRcpt      = address(0xFEE);
    address guardianAddr = address(0x6042D);

    uint256 constant USDC_6 = 1e6;
    uint256 constant AMOUNT = 10_000 * USDC_6;

    function setUp() public {
        usdc = new StressUSDC();
        vm.prank(governance);
        registry = new AdapterRegistry(governance);
        vm.prank(governance);
        vault = new SIXXVault(
            IERC20(address(usdc)), "SIXX Stable Yield", "sxUSDC",
            governance, address(registry), feeRcpt, guardianAddr
        );
        faulty = new FaultyAdapter(address(usdc), address(vault));
        vm.startPrank(governance);
        registry.registerAdapter(address(faulty), "Test", "Faulty");
        vault.setAdapter(address(faulty));
        vm.stopPrank();

        usdc.mint(alice, AMOUNT);
        vm.startPrank(alice);
        usdc.approve(address(vault), AMOUNT);
        vault.deposit(AMOUNT, alice);
        vm.stopPrank();
    }

    /// #1 — Under a 1% realizable shortfall, a normal user cannot exit at all.
    function test_stress_userExit_bricks_whenRealizableBelowMark() public {
        faulty.setDeliverBps(9_900); // realizable = 99% of NAV mark

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(bytes("VAULT: adapter shortfall"));
        vault.redeem(shares, alice, alice); // <-- FROZEN: user's own funds are stuck
    }

    /// #2 — Governance cannot detach/pause the strategy (setAdapter(0)) under the same shortfall.
    ///      Exactly when you most want to de-risk, migration is impossible.
    function test_stress_governanceDetach_bricks_whenRealizableBelowMark() public {
        faulty.setDeliverBps(9_900);

        vm.prank(governance);
        vm.expectRevert(bytes("VAULT: adapter shortfall"));
        vault.setAdapter(address(0)); // <-- FROZEN: cannot even pause to idle
    }

    /// #3 — The emergency-shutdown valve IS resilient to a fully-frozen `withdraw` (try/catch):
    ///      the flag still takes effect even though the recall reverts. This is the working path.
    function test_stress_emergencyShutdown_survives_frozenWithdraw() public {
        faulty.setRevertOnWithdraw(true); // adapter fully frozen on withdraw

        vm.prank(governance);
        vault.setEmergencyShutdown(true); // must NOT revert

        // Shutdown took effect (deposits blocked) despite the failed recall.
        assertEq(vault.maxDeposit(address(0)), 0, "shutdown active after frozen withdraw");
    }

    /// #4 — RESIDUAL HOLE: the same valve is bricked when the adapter's `totalAssets()` reverts,
    ///      because it is read OUTSIDE the try/catch. Emergency shutdown then reverts wholesale.
    function test_stress_emergencyShutdown_bricks_whenTotalAssetsReverts() public {
        faulty.setRevertOnTotalAssets(true); // e.g. Pendle TWAP oracle not ready

        vm.prank(governance);
        vm.expectRevert(bytes("FAULTY: totalAssets reverts"));
        vault.setEmergencyShutdown(true); // <-- FROZEN: even the emergency valve is blocked
    }
}
