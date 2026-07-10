// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SIXXVault} from "../../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../../src/core/AdapterRegistry.sol";
import {MockAdapter} from "../mocks/MockAdapter.sol";
import {Handler, IMintableERC20} from "./Handler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Minimal mintable mock USDC (mirrors the one in SIXXVault.t.sol).
contract InvUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

/// @title SIXXVault stateful invariants
/// @notice Phase-1 defense-in-depth (ADR-006) automated invariant layer.
///         Drives the vault through fuzzed deposit/withdraw/yield/harvest/time sequences
///         via {Handler} and asserts four safety properties that must hold in every state:
///           1. value non-creation       — the vault never reports more assets than have net entered
///           2. share↔asset consistency  — outstanding shares never claim more assets than exist
///           3. non-custody              — the vault holds no idle balance during normal operation
///           4. totalAssets monotonicity — assets only decrease via an explicit withdrawal
/// @dev Fees are pinned to 0 so the accounting identity is exact up to share-rounding dust.
contract SIXXVaultInvariantTest is StdInvariant, Test {
    InvUSDC         usdc;
    AdapterRegistry registry;
    SIXXVault       vault;
    MockAdapter     adapter;
    Handler         handler;

    address governance   = address(0xBEEF);
    address feeRcpt      = address(0xFEE);
    address guardianAddr = address(0x6042D);

    uint256 constant TOL = 3; // wei of 6-decimal USDC — share-rounding dust only

    function setUp() public {
        usdc = new InvUSDC();

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

        adapter = new MockAdapter(address(usdc), address(vault));

        vm.startPrank(governance);
        registry.registerAdapter(address(adapter), "DeFi", "Mock");
        vault.setAdapter(address(adapter));
        // Pin fees to zero: keep the value-conservation identity clean.
        vault.setManagementFee(0);
        vault.setPerformanceFee(0);
        vm.stopPrank();

        // Actors
        address[] memory actors = new address[](3);
        actors[0] = address(0xA11CE);
        actors[1] = address(0xB0B);
        actors[2] = address(0xCAFE);

        handler = new Handler(vault, IMintableERC20(address(usdc)), adapter, actors);

        // Only fuzz the handler's action functions.
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = Handler.deposit.selector;
        selectors[1] = Handler.withdraw.selector;
        selectors[2] = Handler.addYield.selector;
        selectors[3] = Handler.harvest.selector;
        selectors[4] = Handler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice INV-1 value non-creation: reported assets never exceed net value that entered.
    function invariant_valueNonCreation() public view {
        uint256 netIn = handler.ghost_deposited() + handler.ghost_yield();
        uint256 out = handler.ghost_withdrawn();
        uint256 ceiling = netIn > out ? netIn - out : 0;
        assertLe(vault.totalAssets(), ceiling + TOL, "INV-1: vault created value");
    }

    /// @notice INV-2 share↔asset consistency: outstanding shares never claim more than exists.
    function invariant_sharesBacked() public view {
        uint256 claimable = vault.convertToAssets(vault.totalSupply());
        assertLe(claimable, vault.totalAssets() + TOL, "INV-2: shares over-claim assets");
    }

    /// @notice INV-3 non-custody: the vault deploys everything and holds no idle balance.
    function invariant_nonCustodyNoIdle() public view {
        assertLe(usdc.balanceOf(address(vault)), TOL, "INV-3: unexpected idle balance in vault");
    }

    /// @notice INV-4 monotonicity: totalAssets only drops on an explicit withdrawal.
    function invariant_totalAssetsMonotonic() public view {
        assertFalse(handler.ghost_nonWithdrawDecrease(), "INV-4: totalAssets decreased without a withdrawal");
    }

    /// @notice Surfaces the action mix so a run that never exercised paths is visible.
    function invariant_callSummary() public view {
        console2Log();
    }

    function console2Log() internal view {
        // forge prints per-selector call counts automatically; this hook keeps a
        // stable place to add richer summaries without touching the assertions above.
    }
}
