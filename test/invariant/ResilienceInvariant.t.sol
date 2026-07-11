// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SIXXVault} from "../../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../../src/core/AdapterRegistry.sol";
import {FaultyAdapter} from "../mocks/FaultyAdapter.sol";
import {ResilienceHandler, IMintableERC20} from "./ResilienceHandler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Minimal mintable mock USDC.
contract ResUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

/// @title SIXXVault resilience invariants (P-03, 2nd review)
/// @notice Stateful invariants over the FAILURE-MODE surface: a lossy / unreadable adapter,
///         governance force-detach (pause), and reattach. Asserts the two anti-dilution
///         guarantees that H-01 / M-03 add on top of the base accounting safety:
///           R-1  no shares are ever minted while deposits are paused (no dilution against
///                an impaired/unreadable pool);
///           R-2  the pause is faithfully reflected in the ERC-4626 max* views (maxDeposit /
///                maxMint == 0 while paused) — integrators and previews cannot be misled;
///           R-3  outstanding shares never over-claim assets across any detach/reattach
///                sequence (no share-dilution exploit).
contract SIXXVaultResilienceInvariantTest is StdInvariant, Test {
    ResUSDC         usdc;
    AdapterRegistry registry;
    SIXXVault       vault;
    FaultyAdapter   adapter;
    ResilienceHandler handler;

    address governance   = address(0xBEEF);
    address feeRcpt      = address(0xFEE);
    address guardianAddr = address(0x6042D);

    uint256 constant TOL = 3;

    function setUp() public {
        usdc = new ResUSDC();

        vm.prank(governance);
        registry = new AdapterRegistry(governance);

        vm.prank(governance);
        vault = new SIXXVault(
            IERC20(address(usdc)),
            "SIXX Stable Yield",
            "sxUSDC",
            governance,
            address(registry),
            feeRcpt,
            guardianAddr
        );

        adapter = new FaultyAdapter(address(usdc), address(vault));

        vm.startPrank(governance);
        registry.registerAdapter(address(adapter), "Test", "Faulty");
        vault.setAdapter(address(adapter));
        vault.setManagementFee(0);
        vault.setPerformanceFee(0);
        vm.stopPrank();

        address[] memory actors = new address[](3);
        actors[0] = address(0xA11CE);
        actors[1] = address(0xB0B);
        actors[2] = address(0xCAFE);

        handler = new ResilienceHandler(
            vault, IMintableERC20(address(usdc)), registry, adapter, actors, governance
        );

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = ResilienceHandler.deposit.selector;
        selectors[1] = ResilienceHandler.withdraw.selector;
        selectors[2] = ResilienceHandler.setLossy.selector;
        selectors[3] = ResilienceHandler.forceDetach.selector;
        selectors[4] = ResilienceHandler.breakOracleThenForceDetach.selector;
        selectors[5] = ResilienceHandler.reattach.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice R-1: no deposit ever minted shares while `depositsPaused` was true.
    function invariant_noMintWhileDepositsPaused() public view {
        assertEq(handler.ghost_mintWhilePaused(), 0, "R-1: shares minted while deposits paused");
    }

    /// @notice R-2: a paused vault reports 0 deposit/mint capacity through the ERC-4626 views.
    function invariant_pausedImpliesZeroMaxDeposit() public view {
        if (vault.depositsPaused()) {
            assertEq(vault.maxDeposit(address(0xA11CE)), 0, "R-2: maxDeposit != 0 while paused");
            assertEq(vault.maxMint(address(0xA11CE)), 0, "R-2: maxMint != 0 while paused");
        }
    }

    /// @notice R-3: outstanding shares never over-claim assets, across every detach/reattach.
    function invariant_sharesNeverOverclaim() public view {
        uint256 claimable = vault.convertToAssets(vault.totalSupply());
        assertLe(claimable, vault.totalAssets() + TOL, "R-3: shares over-claim assets");
    }

    /// @notice Surfaces the failure-mode action mix (so a run that never paused is visible).
    function invariant_resilienceCallSummary() public view {
        // forge prints per-selector call counts automatically.
    }
}
