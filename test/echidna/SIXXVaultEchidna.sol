// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SIXXVault} from "../../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../../src/core/AdapterRegistry.sol";
import {MockAdapter} from "../mocks/MockAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Self-minting mock USDC for the Echidna harness.
contract EchUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

/// @title SIXXVault Echidna property harness
/// @notice Phase-1 defense-in-depth (ADR-006) property-based fuzzing layer.
///         Echidna deploys this contract and fuzzes the `action_*` functions; after every
///         call sequence each `echidna_*` predicate must hold. This is the deep-search,
///         coverage-guided complement to the Foundry invariant suite — the same four safety
///         properties explored by a different engine.
/// @dev Echidna has no cheatcodes, so this harness is deployed AS the vault/registry
///      governance and is the single depositor (its address is `msg.sender` into the vault).
///      Fees are pinned to 0 so the accounting identity `totalAssets == deposited + yield
///      - withdrawn` holds exactly up to share-rounding dust.
contract SIXXVaultEchidna {
    EchUSDC         internal usdc;
    AdapterRegistry internal registry;
    SIXXVault       internal vault;
    MockAdapter     internal adapter;

    address internal constant FEE_RCPT = address(0xFEE);
    address internal constant GUARDIAN = address(0x6042D);

    // Ghost accounting (underlying asset units)
    uint256 internal ghostDeposited;
    uint256 internal ghostWithdrawn;
    uint256 internal ghostYield;

    uint256 internal constant TOL = 3;
    uint256 internal constant MAX_DEPOSIT = 1_000_000e6; // 1M USDC
    uint256 internal constant MAX_YIELD   = 10_000e6;    // 10k USDC

    constructor() {
        usdc = new EchUSDC();

        // Deploy with governance = this harness so it can wire and configure without cheatcodes.
        registry = new AdapterRegistry(address(this));
        vault = new SIXXVault(
            IERC20(address(usdc)),
            "SIXX Stable Yield",
            "sxUSDC",
            address(this),
            address(registry),
            FEE_RCPT,
            GUARDIAN
        );
        adapter = new MockAdapter(address(usdc), address(vault));

        registry.registerAdapter(address(adapter), "DeFi", "Mock");
        vault.setAdapter(address(adapter));
        vault.setManagementFee(0);
        vault.setPerformanceFee(0);
    }

    // ─────────────────────────────────────────────────────────
    // Fuzzed actions (Echidna drives these)
    // ─────────────────────────────────────────────────────────

    /// @notice Deposit a bounded amount for this harness (caller == receiver).
    function action_deposit(uint256 amount) public {
        amount = 1e6 + (amount % MAX_DEPOSIT);
        usdc.mint(address(this), amount);
        usdc.approve(address(vault), amount);
        try vault.deposit(amount, address(this)) {
            ghostDeposited += amount;
        } catch {}
    }

    /// @notice Redeem a bounded fraction of held shares.
    function action_withdraw(uint256 shares) public {
        uint256 bal = vault.balanceOf(address(this));
        if (bal == 0) return;
        shares = 1 + (shares % bal);
        uint256 before = usdc.balanceOf(address(this));
        try vault.redeem(shares, address(this), address(this)) {
            ghostWithdrawn += usdc.balanceOf(address(this)) - before;
        } catch {}
    }

    /// @notice Inject real yield into the adapter (legitimate value increase).
    function action_addYield(uint256 amount) public {
        if (vault.totalAssets() == 0) return;
        amount = 1 + (amount % MAX_YIELD);
        usdc.mint(address(this), amount);
        usdc.approve(address(adapter), amount);
        try adapter.addYield(amount) {
            ghostYield += amount;
        } catch {}
    }

    /// @notice Exercise the harvest path (no-op for MockAdapter).
    function action_harvest() public {
        try adapter.harvest() {} catch {}
    }

    // ─────────────────────────────────────────────────────────
    // Properties (must always hold)
    // ─────────────────────────────────────────────────────────

    /// @notice P-1 value non-creation: reported assets never exceed net value that entered.
    function echidna_value_non_creation() public view returns (bool) {
        uint256 netIn = ghostDeposited + ghostYield;
        uint256 ceiling = netIn > ghostWithdrawn ? netIn - ghostWithdrawn : 0;
        return vault.totalAssets() <= ceiling + TOL;
    }

    /// @notice P-2 share↔asset consistency: outstanding shares never over-claim assets.
    function echidna_shares_backed() public view returns (bool) {
        return vault.convertToAssets(vault.totalSupply()) <= vault.totalAssets() + TOL;
    }

    /// @notice P-3 non-custody: the vault deploys everything and holds no idle balance.
    function echidna_non_custody_no_idle() public view returns (bool) {
        return usdc.balanceOf(address(vault)) <= TOL;
    }
}
