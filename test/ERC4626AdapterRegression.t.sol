// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {ERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";
import {MockERC20, MockERC4626} from "./mocks/MockERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice ERC-4626 with a hard supply cap → deposit reverts past the cap
///         (simulates a Morpho MetaMorpho vault whose supply cap is exhausted).
contract CappedERC4626 is ERC4626 {
    uint256 public cap;
    constructor(IERC20 a, uint256 cap_) ERC20("Capped", "cap") ERC4626(a) { cap = cap_; }
    function maxDeposit(address) public view override returns (uint256) {
        uint256 ta = totalAssets();
        return ta >= cap ? 0 : cap - ta;
    }
    function maxMint(address r) public view override returns (uint256) {
        return convertToShares(maxDeposit(r));
    }
    function deposit(uint256 assets, address r) public override returns (uint256) {
        require(assets <= maxDeposit(r), "CAP: exceeded");
        return super.deposit(assets, r);
    }
}

/// @notice ERC-4626 with a configurable instant-liquidity ceiling on withdraw.
contract IlliquidERC4626 is ERC4626 {
    uint256 public liquidCap = type(uint256).max;
    constructor(IERC20 a) ERC20("Illiquid", "illq") ERC4626(a) {}
    function setLiquidCap(uint256 c) external { liquidCap = c; }
    function maxWithdraw(address o) public view override returns (uint256) {
        uint256 owned = super.maxWithdraw(o);
        return owned < liquidCap ? owned : liquidCap;
    }
    function withdraw(uint256 assets, address rcv, address o) public override returns (uint256) {
        require(assets <= maxWithdraw(o), "ILLQ: not enough liquidity");
        return super.withdraw(assets, rcv, o);
    }
}

/// @title ERC4626AdapterRegressionTest
/// @notice Locks in the security properties verified during the 2026-06-02 audit
///         (§4 attack scenarios) plus the audit-recommended additions
///         (L-1 rescue, M-G1 isFullyExited). Pure unit tests — no fork required:
///           forge test --match-contract ERC4626AdapterRegressionTest -vvv
contract ERC4626AdapterRegressionTest is Test {
    MockERC20 usdc;
    AdapterRegistry registry;
    SIXXVault vault;
    address gov = makeAddr("gov");
    address feeRecipient = makeAddr("fees");
    address alice = makeAddr("alice");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        registry = new AdapterRegistry(gov);
        vault = new SIXXVault(IERC20(address(usdc)), "SIXX USDC", "sxUSDC", gov, address(registry), feeRecipient);
    }

    function _seed(uint256 amt) internal {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(vault), amt);
        vault.deposit(amt, alice);
        vm.stopPrank();
    }

    function _wire(address erc4626Vault) internal returns (ERC4626Adapter ad) {
        ad = new ERC4626Adapter(address(usdc), erc4626Vault, address(vault), gov);
        vm.startPrank(gov);
        registry.registerAdapter(address(ad), "DeFi", "test");
        vault.setAdapter(address(ad));
        vm.stopPrank();
    }

    // ── §4-1: a fake sixxVault cannot drive deposit/withdraw ──────────────────
    function test_reg_fakeVault_rejected() public {
        MockERC4626 v = new MockERC4626(IERC20(address(usdc)));
        ERC4626Adapter ad = new ERC4626Adapter(address(usdc), address(v), address(vault), gov);
        usdc.mint(address(ad), 1_000e6);

        vm.prank(makeAddr("attacker"));
        vm.expectRevert(bytes("ADAPTER: only vault"));
        ad.deposit(1_000e6);

        vm.prank(makeAddr("attacker"));
        vm.expectRevert(bytes("ADAPTER: only vault"));
        ad.withdraw(1_000e6, makeAddr("attacker"));
    }

    // ── §4-3: donation to the Morpho vault must not distort SIXXVault accounting ─
    function test_reg_donation_doesNotDistortAccounting() public {
        MockERC4626 v = new MockERC4626(IERC20(address(usdc)));
        ERC4626Adapter ad = _wire(address(v));
        _seed(50_000e6);

        // Honest share price baseline.
        uint256 spBefore = vault.convertToAssets(1e15);

        // Attacker donates raw underlying into the ERC-4626 vault to inflate price.
        usdc.mint(address(this), 1_000_000e6);
        usdc.transfer(address(v), 1_000_000e6);

        // The adapter floors via convertToAssets and never reports more than redeemable.
        assertLe(ad.totalAssets(), v.maxWithdraw(address(ad)), "no overstatement");

        // Share price may rise (legit, donation is real yield to holders) but it
        // can never EXCEED true redeemable backing, so mint/burn stays fair.
        uint256 spAfter = vault.convertToAssets(1e15);
        assertGe(spAfter, spBefore, "price monotonic");
        // totalAssets() is fully backed by what the adapter can actually redeem.
        assertLe(vault.totalAssets(), usdc.balanceOf(address(vault)) + v.maxWithdraw(address(ad)) + 1);
    }

    // ── §4-4: withdraw maxWithdraw-clamp yields no accounting-drift profit ─────
    function test_reg_withdrawClamp_noDriftProfit() public {
        IlliquidERC4626 v = new IlliquidERC4626(IERC20(address(usdc)));
        ERC4626Adapter ad = _wire(address(v));
        _seed(50_000e6);
        uint256 spBefore = vault.convertToAssets(1e15);

        v.setLiquidCap(10_000e6); // partial illiquidity
        vm.warp(block.timestamp + vault.lockPeriod() + 1);

        // Over-large withdraw reverts (no silent under-delivery / vault shortfall).
        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(20_000e6, alice, alice);

        // In-band withdraw is exact and value-fair.
        vm.prank(alice);
        vault.withdraw(5_000e6, alice, alice);
        assertApproxEqAbs(usdc.balanceOf(alice), 5_000e6, 2, "exact amount delivered");

        uint256 spAfter = vault.convertToAssets(1e15);
        assertApproxEqAbs(spAfter, spBefore, 1e9, "no share-price drift exploit");
    }

    // ── §4-6 / L-3: migrate INTO a cap-exhausted vault → funds idle & safe (M-3) ─
    function test_reg_migrateIntoCappedVault_fundsSafeIdle() public {
        MockERC4626 vaultA = new MockERC4626(IERC20(address(usdc)));
        ERC4626Adapter adA = _wire(address(vaultA));
        _seed(50_000e6);
        assertApproxEqAbs(adA.totalAssets(), 50_000e6, 2, "A holds funds");
        uint256 taBefore = vault.totalAssets();

        // Target B: cap already exhausted by an unrelated depositor.
        CappedERC4626 vaultB = new CappedERC4626(IERC20(address(usdc)), 1_000_000e6);
        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(vaultB), 1_000_000e6);
        vaultB.deposit(1_000_000e6, address(this));
        assertEq(vaultB.maxDeposit(address(0)), 0, "B cap exhausted");

        ERC4626Adapter adB = new ERC4626Adapter(address(usdc), address(vaultB), address(vault), gov);
        vm.startPrank(gov);
        registry.registerAdapter(address(adB), "DeFi", "B");
        vault.setAdapter(address(adB)); // recall A, try-deposit B → M-3 catch
        vm.stopPrank();

        // No loss: pulled out of A, now idle in the vault; B got nothing.
        assertApproxEqAbs(usdc.balanceOf(address(vault)), 50_000e6, 2, "funds idle & safe");
        assertEq(adB.totalAssets(), 0, "nothing in capped B");
        assertApproxEqAbs(vault.totalAssets(), taBefore, 2, "totalAssets preserved");

        // Alice still exits in full.
        vm.warp(block.timestamp + vault.lockPeriod() + 1);
        uint256 maxA = vault.maxWithdraw(alice);
        vm.prank(alice);
        vault.withdraw(maxA, alice, alice);
        assertApproxEqAbs(usdc.balanceOf(alice), 50_000e6, 2, "alice exited fully");
    }

    // ── L-1: rescue protects core (asset/share), recovers only foreign tokens ──
    function test_reg_rescue_protectsCore_recoversForeign() public {
        MockERC4626 v = new MockERC4626(IERC20(address(usdc)));
        ERC4626Adapter ad = _wire(address(v));
        _seed(50_000e6); // adapter now holds vault shares (principal)

        // Core asset (USDC) is hard-excluded.
        vm.prank(gov);
        vm.expectRevert(bytes("ADAPTER: core protected"));
        ad.rescue(address(usdc), gov);

        // Vault share (deployed principal) is hard-excluded.
        vm.prank(gov);
        vm.expectRevert(bytes("ADAPTER: core protected"));
        ad.rescue(address(v), gov);

        // Non-governance cannot rescue.
        MockERC20 reward = new MockERC20("Morpho", "MORPHO", 18);
        reward.mint(address(ad), 500e18);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(bytes("ADAPTER: not governance"));
        ad.rescue(address(reward), gov);

        // zero recipient rejected.
        vm.prank(gov);
        vm.expectRevert(bytes("ADAPTER: zero to"));
        ad.rescue(address(reward), address(0));

        // Governance recovers the foreign reward token in full.
        vm.prank(gov);
        ad.rescue(address(reward), gov);
        assertEq(reward.balanceOf(gov), 500e18, "reward recovered");
        assertEq(reward.balanceOf(address(ad)), 0, "adapter swept");

        // Principal untouched: adapter still backs the full position.
        assertApproxEqAbs(ad.totalAssets(), 50_000e6, 2, "principal intact after rescue");
    }

    // ── M-G1: isFullyExited reflects redeemable balance (migrate-out guard) ────
    function test_reg_isFullyExited_tracksExit() public {
        MockERC4626 v = new MockERC4626(IERC20(address(usdc)));
        ERC4626Adapter ad = _wire(address(v));

        assertTrue(ad.isFullyExited(), "empty adapter is fully exited");

        _seed(50_000e6);
        assertFalse(ad.isFullyExited(), "holding funds -> not exited");

        // Drain everything back out via a full recall (emergency shutdown path).
        vm.prank(gov);
        vault.setEmergencyShutdown(true); // recalls all to vault
        assertTrue(ad.isFullyExited(), "after full recall -> fully exited");
    }
}
