// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";
import {MockUSDC} from "./SIXXVault.t.sol";

/// @dev Minimal external ERC-4626 vault (stands in for a Morpho USDC Prime MetaMorpho
///      vault). fee-less, 1:1-ish, so unit tests can exercise the adapter boundary
///      without a mainnet fork.
contract MockMorphoVault is ERC4626 {
    constructor(IERC20 a) ERC20("Mock Morpho USDC Prime", "mgtUSDC") ERC4626(a) {}
}

/// @dev A second ERC-20 to prove rescue() can sweep non-core dust.
contract OtherToken is ERC20 {
    constructor() ERC20("Other", "OTH") { _mint(msg.sender, 1_000e18); }
}

/// @notice Non-fork boundary regression for ERC4626Adapter (custody audit L-3:
///         the fork suite's boundary checks are skipped without RPC — this keeps
///         onlyVault / asset-mismatch / rescue-core-protected / accounting /
///         M-4 rotation / pause under CI at all times, with a mock ERC-4626 vault.
contract ERC4626AdapterUnitTest is Test {
    address governance = makeAddr("governance");
    address sixxVault  = makeAddr("sixxVault"); // stands in for the SIXXVault caller
    address user       = makeAddr("user");
    address stranger   = makeAddr("stranger");

    MockUSDC        usdc;
    MockMorphoVault mvault;
    ERC4626Adapter  adapter;

    uint256 constant USDC_1 = 1e6;
    uint256 constant AMT = 1_000 * USDC_1;

    function setUp() public {
        usdc = new MockUSDC();
        mvault = new MockMorphoVault(IERC20(address(usdc)));
        adapter = new ERC4626Adapter(address(usdc), address(mvault), sixxVault, governance);
    }

    /// PUSH model: SIXXVault sends USDC to the adapter, then calls deposit().
    function _fundAndDeposit(uint256 amt) internal {
        usdc.mint(address(adapter), amt);
        vm.prank(sixxVault);
        adapter.deposit(amt);
    }

    // ── constructor guard ─────────────────────────────────────

    function test_constructor_rejectsAssetMismatch() public {
        OtherToken wrong = new OtherToken(); // != mvault.asset()==usdc
        vm.expectRevert("ADAPTER: asset mismatch");
        new ERC4626Adapter(address(wrong), address(mvault), sixxVault, governance);
    }

    function test_constructor_setsImmutableAsset() public view {
        assertEq(adapter.asset(), address(usdc));
        assertEq(address(adapter.vault()), address(mvault));
    }

    // ── onlyVault gate ────────────────────────────────────────

    function test_deposit_onlyVault() public {
        usdc.mint(address(adapter), AMT);
        vm.prank(stranger);
        vm.expectRevert("ADAPTER: only vault");
        adapter.deposit(AMT);
    }

    function test_withdraw_onlyVault() public {
        _fundAndDeposit(AMT);
        vm.prank(stranger);
        vm.expectRevert("ADAPTER: only vault");
        adapter.withdraw(AMT, user);
    }

    // ── deposit / withdraw accounting ─────────────────────────

    function test_deposit_mintsSharesToAdapter_totalAssetsReflects() public {
        _fundAndDeposit(AMT);
        assertGt(mvault.balanceOf(address(adapter)), 0, "adapter holds vault shares");
        assertEq(usdc.balanceOf(address(adapter)), 0, "no idle USDC left on adapter");
        assertApproxEqAbs(adapter.totalAssets(), AMT, 1, "totalAssets ~= deposited");
    }

    function test_withdraw_sendsAssetsToRecipient_burnsShares() public {
        _fundAndDeposit(AMT);
        uint256 recBefore = usdc.balanceOf(user);

        vm.prank(sixxVault);
        uint256 out = adapter.withdraw(AMT, user);

        assertApproxEqAbs(out, AMT, 1, "reported withdrawn ~= requested");
        assertApproxEqAbs(usdc.balanceOf(user) - recBefore, AMT, 1, "recipient received assets");
        assertApproxEqAbs(adapter.totalAssets(), 0, 1, "adapter drained");
        assertTrue(adapter.isFullyExited(), "fully exited after full withdraw");
    }

    function test_withdraw_capsAtMaxWithdraw() public {
        _fundAndDeposit(AMT);
        // Request more than deposited — adapter caps at maxWithdraw (just-enough).
        vm.prank(sixxVault);
        uint256 out = adapter.withdraw(AMT * 10, user);
        assertApproxEqAbs(out, AMT, 1, "capped at available");
    }

    // ── rescue: core protected ────────────────────────────────

    function test_rescue_revertsOnCoreAsset() public {
        vm.prank(governance);
        vm.expectRevert("ADAPTER: core protected");
        adapter.rescue(address(usdc), governance);
    }

    function test_rescue_revertsOnVaultShares() public {
        vm.prank(governance);
        vm.expectRevert("ADAPTER: core protected");
        adapter.rescue(address(mvault), governance);
    }

    function test_rescue_sweepsNonCoreDust() public {
        OtherToken oth = new OtherToken();
        oth.transfer(address(adapter), 100e18);
        vm.prank(governance);
        adapter.rescue(address(oth), governance);
        assertEq(oth.balanceOf(governance), 100e18);
        assertEq(oth.balanceOf(address(adapter)), 0);
    }

    function test_rescue_onlyGovernance() public {
        OtherToken oth = new OtherToken();
        oth.transfer(address(adapter), 100e18);
        vm.prank(stranger);
        vm.expectRevert("ADAPTER: not governance");
        adapter.rescue(address(oth), stranger);
    }

    // ── M-4 2-step sixxVault rotation ─────────────────────────

    function test_rotateSixxVault_twoStep() public {
        address newVault = makeAddr("newVault");

        vm.prank(governance);
        adapter.proposeSixxVault(newVault);

        // Old vault still authoritative until acceptance.
        _fundAndDeposit(AMT); // works via old sixxVault

        vm.prank(newVault);
        adapter.acceptSixxVault();

        // Old vault now rejected, new vault accepted.
        usdc.mint(address(adapter), AMT);
        vm.prank(sixxVault);
        vm.expectRevert("ADAPTER: only vault");
        adapter.deposit(AMT);

        vm.prank(newVault);
        adapter.deposit(AMT); // ok
    }

    // ── pause blocks deposit, still allows withdraw ───────────

    function test_pause_blocksDeposit_allowsWithdraw() public {
        _fundAndDeposit(AMT);

        vm.prank(governance);
        adapter.pause();

        usdc.mint(address(adapter), AMT);
        vm.prank(sixxVault);
        vm.expectRevert("ADAPTER: paused");
        adapter.deposit(AMT);

        // Withdraw must remain available while paused (safe exit).
        vm.prank(sixxVault);
        uint256 out = adapter.withdraw(AMT, user);
        assertGt(out, 0, "withdraw allowed while paused");
    }

    // ── harvest is a safe no-op ───────────────────────────────

    function test_harvest_isNoOp() public {
        _fundAndDeposit(AMT);
        uint256 taBefore = adapter.totalAssets();
        adapter.harvest(); // permissionless no-op
        assertEq(adapter.totalAssets(), taBefore, "harvest does not move funds");
    }
}
