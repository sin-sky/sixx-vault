// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";
import {MockERC20, MockERC4626} from "./mocks/MockERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title ERC4626AdapterUnitTest
/// @notice Pure unit tests for ERC4626Adapter against an OZ mock ERC-4626 vault.
///         No fork required:
///           forge test --match-contract ERC4626AdapterUnitTest -vvv
///
/// The test contract itself plays the role of the SIXXVault caller, so it
/// exercises the PUSH transfer model directly: mint underlying to the adapter,
/// THEN call `deposit` (exactly how SIXXVault deploys idle funds).
contract ERC4626AdapterUnitTest is Test {
    MockERC20      asset;
    MockERC4626    erc4626;
    ERC4626Adapter adapter;

    address governance = makeAddr("governance");
    address recipient   = makeAddr("recipient");

    uint256 constant AMT = 1_000e6; // 1,000 units of a 6-decimal asset

    function setUp() public {
        asset   = new MockERC20("USD Coin", "USDC", 6);
        erc4626 = new MockERC4626(IERC20(address(asset)));

        // This test contract is the SIXX caller (sixxVault_).
        adapter = new ERC4626Adapter(
            address(asset),
            address(erc4626),
            address(this),
            governance
        );
    }

    /// @dev Push model: fund the adapter, then deposit (as the SIXX caller).
    function _pushAndDeposit(uint256 amount) internal returns (uint256 deposited) {
        asset.mint(address(adapter), amount);
        deposited = adapter.deposit(amount);
    }

    // ─────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────

    function test_constructor_setsState() public view {
        assertEq(adapter.asset(), address(asset));
        assertEq(address(adapter.vault()), address(erc4626));
        assertEq(adapter.sixxVault(), address(this));
        assertEq(adapter.governance(), governance);
        assertTrue(adapter.isActive());
        // Infinite approval to the vault was set in the constructor.
        assertEq(asset.allowance(address(adapter), address(erc4626)), type(uint256).max);
    }

    function test_constructor_revertsOnAssetMismatch() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        MockERC4626 wrongVault = new MockERC4626(IERC20(address(other)));
        vm.expectRevert(bytes("ADAPTER: asset mismatch"));
        new ERC4626Adapter(address(asset), address(wrongVault), address(this), governance);
    }

    function test_constructor_revertsOnZeroAddrs() public {
        vm.expectRevert(bytes("ADAPTER: zero asset"));
        new ERC4626Adapter(address(0), address(erc4626), address(this), governance);

        vm.expectRevert(bytes("ADAPTER: zero vault"));
        new ERC4626Adapter(address(asset), address(0), address(this), governance);

        vm.expectRevert(bytes("ADAPTER: zero sixxVault"));
        new ERC4626Adapter(address(asset), address(erc4626), address(0), governance);

        vm.expectRevert(bytes("ADAPTER: zero governance"));
        new ERC4626Adapter(address(asset), address(erc4626), address(this), address(0));
    }

    // ─────────────────────────────────────────────────────────
    // deposit
    // ─────────────────────────────────────────────────────────

    function test_deposit_pushModel() public {
        uint256 deposited = _pushAndDeposit(AMT);
        assertEq(deposited, AMT);
        // Underlying moved out of the adapter into the vault.
        assertEq(asset.balanceOf(address(adapter)), 0, "adapter holds no idle underlying");
        assertGt(erc4626.balanceOf(address(adapter)), 0, "adapter holds shares");
        assertApproxEqAbs(adapter.totalAssets(), AMT, 1, "totalAssets ~= AMT");
    }

    function test_deposit_onlyVault() public {
        asset.mint(address(adapter), AMT);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(bytes("ADAPTER: only vault"));
        adapter.deposit(AMT);
    }

    function test_deposit_zeroAmountReverts() public {
        vm.expectRevert(bytes("ADAPTER: zero amount"));
        adapter.deposit(0);
    }

    function test_deposit_whenPausedReverts() public {
        asset.mint(address(adapter), AMT);
        vm.prank(governance);
        adapter.pause();
        vm.expectRevert(bytes("ADAPTER: paused"));
        adapter.deposit(AMT);
    }

    // ─────────────────────────────────────────────────────────
    // withdraw
    // ─────────────────────────────────────────────────────────

    function test_withdraw_roundTrip() public {
        _pushAndDeposit(AMT);
        uint256 withdrawn = adapter.withdraw(AMT, recipient);
        assertApproxEqAbs(withdrawn, AMT, 1, "withdrawn ~= AMT");
        assertApproxEqAbs(asset.balanceOf(recipient), AMT, 1, "recipient funded");
        assertApproxEqAbs(adapter.totalAssets(), 0, 1, "adapter drained");
    }

    function test_withdraw_capsAtMaxWithdraw() public {
        _pushAndDeposit(AMT);
        // Ask for far more than is held; should be capped at what we can redeem.
        uint256 withdrawn = adapter.withdraw(AMT * 100, recipient);
        assertApproxEqAbs(withdrawn, AMT, 1, "capped at maxWithdraw");
        assertApproxEqAbs(asset.balanceOf(recipient), AMT, 1);
    }

    function test_withdraw_onlyVault() public {
        _pushAndDeposit(AMT);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(bytes("ADAPTER: only vault"));
        adapter.withdraw(AMT, recipient);
    }

    function test_withdraw_zeroAmountReverts() public {
        vm.expectRevert(bytes("ADAPTER: zero amount"));
        adapter.withdraw(0, recipient);
    }

    function test_withdraw_zeroRecipientReverts() public {
        vm.expectRevert(bytes("ADAPTER: zero recipient"));
        adapter.withdraw(AMT, address(0));
    }

    function test_withdraw_isNotPausedGated() public {
        // Withdrawals must remain available even when deposits are paused.
        _pushAndDeposit(AMT);
        vm.prank(governance);
        adapter.pause();
        uint256 withdrawn = adapter.withdraw(AMT, recipient);
        assertApproxEqAbs(withdrawn, AMT, 1, "can withdraw while paused");
    }

    // ─────────────────────────────────────────────────────────
    // totalAssets / yield
    // ─────────────────────────────────────────────────────────

    function test_totalAssets_tracksYield() public {
        _pushAndDeposit(AMT);
        uint256 before = adapter.totalAssets();
        // Simulate yield: donate 10% extra underlying to the vault.
        asset.mint(address(erc4626), AMT / 10);
        uint256 afterYield = adapter.totalAssets();
        assertGt(afterYield, before, "totalAssets grows with share price");
        assertApproxEqRel(afterYield, AMT + AMT / 10, 0.001e18, "tracks ~110%");
    }

    function test_totalAssets_neverOverstatesWithdrawable() public {
        _pushAndDeposit(AMT);
        asset.mint(address(erc4626), 777e6); // arbitrary donation
        // convertToAssets rounds down → never exceeds redeemable amount.
        assertLe(adapter.totalAssets(), erc4626.maxWithdraw(address(adapter)));
    }

    // ─────────────────────────────────────────────────────────
    // harvest / metadata
    // ─────────────────────────────────────────────────────────

    function test_harvest_isNoOp() public {
        _pushAndDeposit(AMT);
        assertEq(adapter.harvest(), 0);
    }

    function test_metadata() public view {
        assertEq(adapter.adapterType(), "DeFi");
        assertEq(adapter.riskLevel(), 2);
        assertEq(adapter.estimatedAPY(), 0);
        assertEq(adapter.requiredLockPeriod(), 0);
        assertEq(adapter.providerName(), "ERC-4626 Vault");
    }

    // ─────────────────────────────────────────────────────────
    // Circuit breaker
    // ─────────────────────────────────────────────────────────

    function test_pause_auth() public {
        // sixxVault (this) and governance can pause; strangers cannot.
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(bytes("ADAPTER: unauthorized"));
        adapter.pause();

        adapter.pause(); // as sixxVault
        assertFalse(adapter.isActive());
    }

    function test_unpause_onlyGovernance() public {
        adapter.pause();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(bytes("ADAPTER: only governance"));
        adapter.unpause();

        vm.prank(governance);
        adapter.unpause();
        assertTrue(adapter.isActive());
    }

    // ─────────────────────────────────────────────────────────
    // M-4 two-step rotations
    // ─────────────────────────────────────────────────────────

    function test_twoStepGovernance() public {
        address newGov = makeAddr("newGov");

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(bytes("ADAPTER: not governance"));
        adapter.proposeGovernance(newGov);

        vm.prank(governance);
        adapter.proposeGovernance(newGov);
        assertEq(adapter.pendingGovernance(), newGov);

        // Only the pending address can accept.
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(bytes("ADAPTER: not pending governance"));
        adapter.acceptGovernance();

        vm.prank(newGov);
        adapter.acceptGovernance();
        assertEq(adapter.governance(), newGov);
        assertEq(adapter.pendingGovernance(), address(0));
    }

    function test_twoStepSixxVault() public {
        address newVault = makeAddr("newVault");

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(bytes("ADAPTER: not governance"));
        adapter.proposeSixxVault(newVault);

        vm.prank(governance);
        adapter.proposeSixxVault(newVault);
        assertEq(adapter.pendingSixxVault(), newVault);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(bytes("ADAPTER: not pending vault"));
        adapter.acceptSixxVault();

        vm.prank(newVault);
        adapter.acceptSixxVault();
        assertEq(adapter.sixxVault(), newVault);
        assertEq(adapter.pendingSixxVault(), address(0));

        // Old caller (this) can no longer deposit.
        asset.mint(address(adapter), AMT);
        vm.expectRevert(bytes("ADAPTER: only vault"));
        adapter.deposit(AMT);
    }
}

// =============================================================
// Invariant: totalAssets must never overstate redeemable assets
// =============================================================

/// @notice Drives the adapter through random deposit/withdraw/yield sequences
///         and asserts the rounding-direction invariant from the spec.
contract ERC4626AdapterHandler is Test {
    MockERC20      public asset;
    MockERC4626    public erc4626;
    ERC4626Adapter public adapter;

    constructor(MockERC20 a, MockERC4626 v, ERC4626Adapter ad) {
        asset = a;
        erc4626 = v;
        adapter = ad;
    }

    function deposit(uint256 amount) external {
        amount = bound(amount, 1, 1_000_000e6);
        asset.mint(address(adapter), amount);
        adapter.deposit(amount);
    }

    function withdraw(uint256 amount) external {
        uint256 max = erc4626.maxWithdraw(address(adapter));
        if (max == 0) return;
        amount = bound(amount, 1, max);
        adapter.withdraw(amount, address(this));
    }

    function accrueYield(uint256 amount) external {
        amount = bound(amount, 0, 100_000e6);
        if (amount > 0) asset.mint(address(erc4626), amount);
    }
}

contract ERC4626AdapterInvariantTest is StdInvariant, Test {
    MockERC20      asset;
    MockERC4626    erc4626;
    ERC4626Adapter adapter;
    ERC4626AdapterHandler handler;

    function setUp() public {
        asset   = new MockERC20("USD Coin", "USDC", 6);
        erc4626 = new MockERC4626(IERC20(address(asset)));
        // The handler must be the SIXX caller so it can drive deposit/withdraw.
        // Predict the adapter address is not needed: deploy adapter with handler
        // as sixxVault by constructing the handler first against a placeholder is
        // circular, so instead deploy adapter pointing at a to-be handler via a
        // two-step: deploy handler, then deploy adapter with handler as caller.
        handler = new ERC4626AdapterHandler(asset, erc4626, ERC4626Adapter(address(0)));
        adapter = new ERC4626Adapter(
            address(asset),
            address(erc4626),
            address(handler),
            address(this)
        );
        // Re-point the handler at the real adapter.
        handler = new ERC4626AdapterHandler(asset, erc4626, adapter);
        // The first handler was the registered sixxVault; rotate to the real one.
        adapter.proposeSixxVault(address(handler));
        vm.prank(address(handler));
        adapter.acceptSixxVault();

        targetContract(address(handler));
    }

    /// @notice Spec invariant: reported totalAssets never exceeds what the
    ///         adapter could actually redeem from the vault.
    function invariant_totalAssetsNotOverWithdrawable() public view {
        assertLe(adapter.totalAssets(), erc4626.maxWithdraw(address(adapter)));
    }
}

// =============================================================
// Fork tests — real Morpho MetaMorpho vaults
// =============================================================

/// @notice Round-trips the adapter against the live Gauntlet USDC Prime
///         MetaMorpho vault on Base.
///           forge test --fork-url $BASE_RPC_URL \
///             --match-contract ERC4626AdapterBaseForkTest -vvv
contract ERC4626AdapterBaseForkTest is Test {
    // Morpho — Gauntlet USDC Prime (Base)
    address constant VAULT = 0xeE8F4eC5672F09119b96Ab6fB59C27E1b7e44b61;

    address governance = makeAddr("governance");
    address recipient   = makeAddr("recipient");

    function test_fork_roundTrip() public {
        if (VAULT.code.length == 0) {
            // Not running against a Base fork — skip cleanly.
            vm.skip(true);
            return;
        }
        _roundTrip(VAULT);
    }

    function _roundTrip(address vaultAddr) internal {
        IERC4626 v = IERC4626(vaultAddr);
        address underlying = v.asset();
        uint256 amt = 10_000 * (10 ** uint256(IERC20Decimals(underlying).decimals()));

        ERC4626Adapter adapter = new ERC4626Adapter(
            underlying, vaultAddr, address(this), governance
        );

        // PUSH model: fund the adapter, then deposit as the SIXX caller.
        deal(underlying, address(adapter), amt);
        adapter.deposit(amt);

        uint256 ta = adapter.totalAssets();
        console2.log("totalAssets after deposit:", ta);
        assertApproxEqRel(ta, amt, 0.001e18, "deposited ~= totalAssets");

        // Let a little time pass; a live MetaMorpho vault should not lose value.
        vm.warp(block.timestamp + 7 days);
        assertGe(adapter.totalAssets(), ta - 1, "value does not decrease");

        // Withdraw everything back to recipient.
        uint256 redeemable = v.maxWithdraw(address(adapter));
        uint256 withdrawn = adapter.withdraw(redeemable, recipient);
        assertApproxEqAbs(IERC20(underlying).balanceOf(recipient), withdrawn, 2, "recipient funded");
        assertGt(withdrawn, 0, "withdrew funds");
    }
}

/// @notice Round-trips the adapter against the live Steakhouse USDT MetaMorpho
///         vault on Ethereum mainnet.
///           forge test --fork-url $ETH_RPC_URL \
///             --match-contract ERC4626AdapterEthForkTest -vvv
contract ERC4626AdapterEthForkTest is Test {
    // Morpho — Steakhouse USDT (Ethereum)
    address constant VAULT = 0xbEef047a543E45807105E51A8BBEFCc5950fcfBa;

    address governance = makeAddr("governance");
    address recipient   = makeAddr("recipient");

    function test_fork_roundTrip() public {
        if (VAULT.code.length == 0) {
            vm.skip(true);
            return;
        }
        IERC4626 v = IERC4626(VAULT);
        address underlying = v.asset();
        uint256 amt = 10_000 * (10 ** uint256(IERC20Decimals(underlying).decimals()));

        ERC4626Adapter adapter = new ERC4626Adapter(
            underlying, VAULT, address(this), governance
        );

        deal(underlying, address(adapter), amt);
        adapter.deposit(amt);

        uint256 ta = adapter.totalAssets();
        console2.log("totalAssets after deposit:", ta);
        assertApproxEqRel(ta, amt, 0.001e18, "deposited ~= totalAssets");

        vm.warp(block.timestamp + 7 days);
        assertGe(adapter.totalAssets(), ta - 1, "value does not decrease");

        uint256 redeemable = v.maxWithdraw(address(adapter));
        uint256 withdrawn = adapter.withdraw(redeemable, recipient);
        assertApproxEqAbs(IERC20(underlying).balanceOf(recipient), withdrawn, 2, "recipient funded");
        assertGt(withdrawn, 0, "withdrew funds");
    }
}

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}
