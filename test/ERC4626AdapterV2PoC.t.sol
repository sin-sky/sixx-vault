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

/// @notice ERC-20 whose `transfer` re-enters the adapter's `rescue()` to probe
///         the ReentrancyGuard. Used to prove an untrusted token swept by
///         `rescue` cannot re-enter to drain core funds.
contract ReentrantToken is ERC20 {
    ERC4626Adapter public target;
    address public attacker;
    bool public didReenter;

    constructor() ERC20("Evil", "EVIL") {}

    function arm(ERC4626Adapter t, address a) external { target = t; attacker = a; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }

    function _update(address from, address to, uint256 value) internal override {
        // On the rescue sweep (adapter -> recipient), try to re-enter rescue().
        if (address(target) != address(0) && from == address(target)) {
            didReenter = true;
            // Re-enter: must be blocked by nonReentrant (first modifier on rescue).
            target.rescue(address(this), attacker);
        }
        super._update(from, to, value);
    }
}

/// @notice ERC-4626 with a configurable instant-liquidity ceiling on withdraw,
///         to simulate a partially-illiquid Morpho vault.
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

/// @title ERC4626AdapterV2PoC
/// @notice v2 post-deploy audit PoCs for the 141-line diff (rescue / isFullyExited).
///         forge test --match-contract ERC4626AdapterV2PoC -vvv
contract ERC4626AdapterV2PoC is Test {
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
        registry.registerAdapter(address(ad), "DeFi", "t");
        vault.setAdapter(address(ad));
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════════════════
    // (a) rescue() core-asset protection — 4 mandatory revert PoCs
    // ══════════════════════════════════════════════════════════════════════

    // PoC-1: rescue(asset) — underlying USDC is hard-excluded.
    function test_poc_rescue_asset_reverts() public {
        MockERC4626 v = new MockERC4626(IERC20(address(usdc)));
        ERC4626Adapter ad = _wire(address(v));
        // Even if USDC somehow sits on the adapter, rescue refuses it.
        usdc.mint(address(ad), 1_000e6);
        vm.prank(gov);
        vm.expectRevert(bytes("ADAPTER: core protected"));
        ad.rescue(address(usdc), gov);
    }

    // PoC-2: rescue(vault share) — the ERC-4626 shares (= deployed principal) are excluded.
    function test_poc_rescue_vaultShare_reverts() public {
        MockERC4626 v = new MockERC4626(IERC20(address(usdc)));
        ERC4626Adapter ad = _wire(address(v));
        _seed(50_000e6); // adapter now holds real principal as `v` shares
        assertGt(v.balanceOf(address(ad)), 0, "adapter holds shares");
        vm.prank(gov);
        vm.expectRevert(bytes("ADAPTER: core protected"));
        ad.rescue(address(v), gov);
        // Principal untouched.
        assertApproxEqAbs(ad.totalAssets(), 50_000e6, 2, "principal intact");
    }

    // PoC-3: malicious reentrant token cannot drain via rescue's external call.
    function test_poc_rescue_reentrancy_blocked() public {
        MockERC4626 v = new MockERC4626(IERC20(address(usdc)));
        ERC4626Adapter ad = _wire(address(v));
        _seed(50_000e6);
        uint256 principalBefore = ad.totalAssets();

        ReentrantToken evil = new ReentrantToken();
        evil.arm(ad, makeAddr("attacker"));
        evil.mint(address(ad), 100e18);

        // The sweep triggers evil._update -> re-enters rescue() -> nonReentrant
        // (the FIRST modifier on rescue) fires and reverts with OZ's
        // ReentrancyGuardReentrantCall, which bubbles through SafeERC20.transfer
        // and reverts the outer rescue. Asserting the exact selector proves it
        // was the reentrancy guard (not some other revert) that stopped it.
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        ad.rescue(address(evil), gov);

        // The whole call reverted, so nothing moved: core principal intact and
        // the evil token is still (harmlessly) stuck on the adapter.
        assertApproxEqAbs(ad.totalAssets(), principalBefore, 2, "principal intact after reentry attempt");
        assertGt(v.balanceOf(address(ad)), 0, "shares still held");
        assertEq(evil.balanceOf(address(ad)), 100e18, "evil token not swept (failed safe)");
    }

    // PoC-4: non-governance caller cannot rescue.
    function test_poc_rescue_nonGovernance_reverts() public {
        MockERC4626 v = new MockERC4626(IERC20(address(usdc)));
        ERC4626Adapter ad = _wire(address(v));
        MockERC20 foreign = new MockERC20("F", "F", 18);
        foreign.mint(address(ad), 10e18);

        vm.prank(makeAddr("attacker"));
        vm.expectRevert(bytes("ADAPTER: not governance"));
        ad.rescue(address(foreign), makeAddr("attacker"));

        // Even sixxVault (the deposit/withdraw caller) is NOT governance here.
        vm.prank(address(vault));
        vm.expectRevert(bytes("ADAPTER: not governance"));
        ad.rescue(address(foreign), gov);
    }

    // Positive control: a benign foreign token IS recoverable by governance,
    // and zero-recipient / empty-balance are rejected.
    function test_poc_rescue_happyPath_and_guards() public {
        MockERC4626 v = new MockERC4626(IERC20(address(usdc)));
        ERC4626Adapter ad = _wire(address(v));
        MockERC20 reward = new MockERC20("MORPHO", "MORPHO", 18);

        vm.prank(gov);
        vm.expectRevert(bytes("ADAPTER: nothing to rescue"));
        ad.rescue(address(reward), gov); // balance 0

        reward.mint(address(ad), 500e18);
        vm.prank(gov);
        vm.expectRevert(bytes("ADAPTER: zero to"));
        ad.rescue(address(reward), address(0));

        vm.prank(gov);
        ad.rescue(address(reward), gov);
        assertEq(reward.balanceOf(gov), 500e18, "foreign token recovered");
    }

    // ══════════════════════════════════════════════════════════════════════
    // (b) isFullyExited() effectiveness — is M-G1 actually enforced?
    // ══════════════════════════════════════════════════════════════════════

    // The view tracks redeemable balance correctly...
    function test_poc_isFullyExited_viewIsCorrect() public {
        MockERC4626 v = new MockERC4626(IERC20(address(usdc)));
        ERC4626Adapter ad = _wire(address(v));
        assertTrue(ad.isFullyExited(), "empty -> exited");
        _seed(50_000e6);
        assertFalse(ad.isFullyExited(), "funded -> not exited");
    }

    // ...BUT the live SIXXVault.setAdapter does NOT consult it. This PoC proves
    // M-G1 is NOT closed on-chain: governance can detach a NON-exited, illiquid
    // adapter and strand funds, while isFullyExited() still reads false.
    function test_poc_MG1_notEnforced_setAdapter_strands_illiquid() public {
        IlliquidERC4626 vI = new IlliquidERC4626(IERC20(address(usdc)));
        ERC4626Adapter adOld = _wire(address(vI));
        _seed(50_000e6);

        // Make the Morpho-like vault fully illiquid (e.g. utilization spike).
        vI.setLiquidCap(0);
        assertFalse(adOld.isFullyExited(), "old adapter still holds redeemable value");

        // Switch to a fresh healthy adapter. setAdapter tries to recall-all from
        // adOld, but the adapter clamps to maxWithdraw(=0) and returns nothing;
        // setAdapter does NOT require(isFullyExited()), so it proceeds anyway.
        MockERC4626 vNew = new MockERC4626(IERC20(address(usdc)));
        ERC4626Adapter adNew = new ERC4626Adapter(address(usdc), address(vNew), address(vault), gov);
        vm.startPrank(gov);
        registry.registerAdapter(address(adNew), "DeFi", "new");
        vault.setAdapter(address(adNew)); // succeeds despite old not being exited
        vm.stopPrank();

        // Consequence: funds are STRANDED in the now-detached old adapter, and
        // are no longer counted by the vault's totalAssets().
        assertEq(vault.activeAdapter(), address(adNew), "switched away");
        assertGt(adOld.totalAssets(), 0, "STRANDED value remains in detached old adapter");
        assertFalse(adOld.isFullyExited(), "old adapter was NOT fully exited at detach");
        // The vault now under-counts by the stranded amount (share price drop).
        assertLt(vault.totalAssets(), 50_000e6, "totalAssets dropped: M-G1 gap realised");

        // NOTE: recoverable (gov can setAdapter back to adOld once liquid), but
        // the on-chain guard did not prevent the stranding. M-G1 remains OPEN at
        // the contract level for this immutable vault — mitigation is procedural
        // (script-level require(adapter.isFullyExited()) before any migrate-out).
    }
}
