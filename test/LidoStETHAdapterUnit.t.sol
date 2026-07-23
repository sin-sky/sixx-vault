// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LidoStETHAdapter} from "../src/adapters/LidoStETHAdapter.sol";

// ─────────────────────────── Mocks ───────────────────────────

/// @dev Mock wrapped-native (WETH). deposit()/withdraw() move real test-ETH.
contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}
    function deposit() external payable { _mint(msg.sender, msg.value); }
    function withdraw(uint256 wad) external {
        _burn(msg.sender, wad);
        (bool ok, ) = msg.sender.call{value: wad}("");
        require(ok, "WETH: send fail");
    }
    receive() external payable { _mint(msg.sender, msg.value); }
}

/// @dev Mock Lido stETH. submit{value} mints stETH 1:1 and retains the ETH.
contract MockStETH is ERC20 {
    constructor() ERC20("Liquid staked Ether", "stETH") {}
    function submit(address) external payable returns (uint256) {
        _mint(msg.sender, msg.value);
        return msg.value;
    }
    function getCurrentStakeLimit() external pure returns (uint256) { return type(uint256).max; }
}

/// @dev Mock wstETH. Non-rebasing wrapper at a settable stETH-per-wstETH rate.
contract MockWstETH is ERC20 {
    IERC20 public immutable steth;
    uint256 public rate = 1.2e18; // stETH per 1 wstETH (18-dec)
    constructor(address steth_) ERC20("Wrapped stETH", "wstETH") { steth = IERC20(steth_); }
    function stETH() external view returns (address) { return address(steth); }
    function setRate(uint256 r) external { rate = r; } // simulate stETH rebase
    function getStETHByWstETH(uint256 w) public view returns (uint256) { return (w * rate) / 1e18; }
    function getWstETHByStETH(uint256 s) public view returns (uint256) { return (s * 1e18) / rate; }
    function wrap(uint256 stAmt) external returns (uint256 w) {
        steth.transferFrom(msg.sender, address(this), stAmt);
        w = getWstETHByStETH(stAmt);
        _mint(msg.sender, w);
    }
    function unwrap(uint256 wAmt) external returns (uint256 s) {
        _burn(msg.sender, wAmt);
        s = getStETHByWstETH(wAmt);
        steth.transfer(msg.sender, s);
    }
}

/// @dev Mock Curve ETH/stETH pool. coin0 = ETH sentinel, coin1 = stETH.
///      exchange(stETH->ETH) pulls stETH, returns ETH at `outBps` of par.
contract MockCurvePool {
    address constant ETH_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    IERC20 public immutable steth;
    uint256 public outBps = 9990; // 0.1% pool slippage vs par
    constructor(address steth_) { steth = IERC20(steth_); }
    function coins(uint256 i) external view returns (address) {
        return i == 0 ? ETH_SENTINEL : address(steth);
    }
    function setOutBps(uint256 b) external { outBps = b; }
    function exchange(int128, int128, uint256 dx, uint256 min_dy) external payable returns (uint256 dy) {
        steth.transferFrom(msg.sender, address(this), dx);
        dy = (dx * outBps) / 10_000;
        require(dy >= min_dy, "Curve: slippage");
        (bool ok, ) = msg.sender.call{value: dy}("");
        require(ok, "Curve: eth send");
    }
    receive() external payable {}
}

contract Dummy is ERC20 {
    constructor() ERC20("Dummy", "DUM") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

// ─────────────────────────── Tests ───────────────────────────

contract LidoStETHAdapterUnitTest is Test {
    MockWETH weth;
    MockStETH steth;
    MockWstETH wsteth;
    MockCurvePool pool;
    LidoStETHAdapter adapter;

    address governance = makeAddr("governance");
    address vault      = makeAddr("vault");
    address recipient  = makeAddr("recipient");
    address stranger   = makeAddr("stranger");

    function setUp() public {
        weth   = new MockWETH();
        steth  = new MockStETH();
        wsteth = new MockWstETH(address(steth));
        pool   = new MockCurvePool(address(steth));
        adapter = new LidoStETHAdapter(
            address(weth), address(steth), address(wsteth), address(pool), vault, governance, 350
        );
        // Fund the pool with ETH so it can pay out on stETH->ETH exchanges.
        vm.deal(address(pool), 1_000 ether);
    }

    function _fund(uint256 amt) internal {
        vm.deal(address(this), amt);
        weth.deposit{value: amt}();
        weth.transfer(address(adapter), amt);
    }

    // ── constructor validation ──────────────────────────────────
    function test_constructor_reverts_on_wsteth_mismatch() public {
        MockStETH other = new MockStETH();
        vm.expectRevert("ADAPTER: wstETH/stETH mismatch");
        new LidoStETHAdapter(
            address(weth), address(other), address(wsteth), address(pool), vault, governance, 0
        );
    }

    function test_constructor_reverts_on_zero() public {
        vm.expectRevert("ADAPTER: zero asset");
        new LidoStETHAdapter(address(0), address(steth), address(wsteth), address(pool), vault, governance, 0);
    }

    function test_constructor_derives_indices() public view {
        assertEq(adapter.stEthIndex(), 1);
        assertEq(adapter.ethIndex(), 0);
    }

    // ── deposit / totalAssets math ──────────────────────────────
    function test_deposit_holds_wsteth_and_nav_haircut() public {
        _fund(10 ether);
        vm.prank(vault);
        uint256 dep = adapter.deposit(10 ether);
        assertEq(dep, 10 ether, "deposited != principal");
        // wstETH held = 10 stETH / rate(1.2) = 8.333.. wstETH
        uint256 w = wsteth.balanceOf(address(adapter));
        assertEq(w, wsteth.getWstETHByStETH(10 ether));
        // NAV = 10 ETH * (1 - 0.5%) = 9.95 ETH (allow sub-wei wstETH round-trip
        // rounding, always vault-favorable / under-reported).
        assertApproxEqAbs(adapter.totalAssets(), (10 ether * 9950) / 10_000, 2);
        assertLe(adapter.totalAssets(), (10 ether * 9950) / 10_000); // never over-reports
        assertEq(address(adapter).balance, 0, "idle ETH");
        assertEq(weth.balanceOf(address(adapter)), 0, "idle WETH");
    }

    function test_totalAssets_tracks_rebase() public {
        _fund(10 ether);
        vm.prank(vault);
        adapter.deposit(10 ether);
        uint256 navBefore = adapter.totalAssets();
        // simulate a Lido rebase: stETH per wstETH rises 5%
        wsteth.setRate(1.26e18);
        uint256 navAfter = adapter.totalAssets();
        assertGt(navAfter, navBefore, "NAV did not follow rebase");
        assertApproxEqRel(navAfter, (navBefore * 105) / 100, 1e15); // ~+5%
    }

    // ── withdraw: partial delivers >= requested, full drain clears ──
    function test_partial_withdraw_delivers_at_least_requested() public {
        _fund(10 ether);
        vm.prank(vault);
        adapter.deposit(10 ether);
        vm.prank(vault);
        uint256 got = adapter.withdraw(4 ether, recipient);
        assertGe(got, 4 ether);
        assertEq(weth.balanceOf(recipient), got);
        assertGt(wsteth.balanceOf(address(adapter)), 0);
    }

    function test_full_drain_covers_nav_and_zeroes_position() public {
        _fund(10 ether);
        vm.prank(vault);
        adapter.deposit(10 ether);
        uint256 nav = adapter.totalAssets();
        vm.prank(vault);
        uint256 got = adapter.withdraw(nav, recipient);
        assertGe(got, nav, "drain under-delivers vs NAV");
        assertEq(wsteth.balanceOf(address(adapter)), 0, "position not zeroed");
    }

    function test_withdraw_reverts_when_pool_below_floor() public {
        _fund(10 ether);
        vm.prank(vault);
        adapter.deposit(10 ether);
        // pool now pays only 90% — below the 0.5% floor → revert
        pool.setOutBps(9000);
        vm.prank(vault);
        vm.expectRevert("Curve: slippage");
        adapter.withdraw(1 ether, recipient);
    }

    // ── access control ──────────────────────────────────────────
    function test_onlyVault_deposit() public {
        _fund(1 ether);
        vm.prank(stranger);
        vm.expectRevert("ADAPTER: only vault");
        adapter.deposit(1 ether);
    }

    function test_onlyVault_withdraw() public {
        _fund(1 ether);
        vm.prank(vault);
        adapter.deposit(1 ether);
        vm.prank(stranger);
        vm.expectRevert("ADAPTER: only vault");
        adapter.withdraw(1 ether, recipient);
    }

    function test_harvest_is_noop_and_onlyVault() public {
        vm.prank(vault);
        assertEq(adapter.harvest(), 0);
        vm.prank(stranger);
        vm.expectRevert("ADAPTER: only vault");
        adapter.harvest();
    }

    // ── pause / unpause ─────────────────────────────────────────
    function test_pause_auth_and_effect() public {
        vm.prank(stranger);
        vm.expectRevert("ADAPTER: unauthorized");
        adapter.pause();
        vm.prank(governance);
        adapter.pause();
        _fund(1 ether);
        vm.prank(vault);
        vm.expectRevert("ADAPTER: paused");
        adapter.deposit(1 ether);
        // only governance unpauses
        vm.prank(vault);
        vm.expectRevert("ADAPTER: only governance");
        adapter.unpause();
        vm.prank(governance);
        adapter.unpause();
        assertTrue(adapter.isActive());
    }

    // ── admin: slippage bounds & APY ────────────────────────────
    function test_setSlippage_bounds() public {
        vm.prank(governance);
        adapter.setSlippageBps(300);
        assertEq(adapter.slippageBps(), 300);
        vm.prank(governance);
        vm.expectRevert("ADAPTER: slippage too high");
        adapter.setSlippageBps(301);
        vm.prank(stranger);
        vm.expectRevert("ADAPTER: not governance");
        adapter.setSlippageBps(10);
    }

    function test_setEstimatedAPY() public {
        vm.prank(governance);
        adapter.setEstimatedAPY(420);
        assertEq(adapter.estimatedAPY(), 420);
        vm.prank(stranger);
        vm.expectRevert("ADAPTER: not governance");
        adapter.setEstimatedAPY(1);
    }

    // ── M-4 two-step rotations ──────────────────────────────────
    function test_vault_rotation_two_step() public {
        address newVault = makeAddr("newVault");
        vm.prank(stranger);
        vm.expectRevert("ADAPTER: not governance");
        adapter.proposeVault(newVault);
        vm.prank(governance);
        adapter.proposeVault(newVault);
        assertEq(adapter.pendingVault(), newVault);
        vm.prank(stranger);
        vm.expectRevert("ADAPTER: not pending vault");
        adapter.acceptVault();
        vm.prank(newVault);
        adapter.acceptVault();
        assertEq(adapter.vault(), newVault);
        assertEq(adapter.pendingVault(), address(0));
    }

    function test_governance_rotation_two_step() public {
        address newGov = makeAddr("newGov");
        vm.prank(governance);
        adapter.proposeGovernance(newGov);
        assertEq(adapter.pendingGovernance(), newGov);
        vm.prank(stranger);
        vm.expectRevert("ADAPTER: not pending governance");
        adapter.acceptGovernance();
        vm.prank(newGov);
        adapter.acceptGovernance();
        assertEq(adapter.governance(), newGov);
    }

    // ── rescue: cannot touch position; moves stray tokens & ETH ─
    function test_rescue_cannot_touch_position() public {
        vm.prank(governance);
        vm.expectRevert("ADAPTER: cannot rescue position");
        adapter.rescueToken(address(wsteth), governance);
    }

    function test_rescue_moves_stray_token() public {
        Dummy d = new Dummy();
        d.mint(address(adapter), 500);
        vm.prank(governance);
        uint256 amt = adapter.rescueToken(address(d), recipient);
        assertEq(amt, 500);
        assertEq(d.balanceOf(recipient), 500);
        vm.prank(stranger);
        vm.expectRevert("ADAPTER: not governance");
        adapter.rescueToken(address(d), recipient);
    }

    function test_rescue_eth() public {
        vm.deal(address(adapter), 3 ether);
        vm.prank(governance);
        uint256 amt = adapter.rescueETH(recipient);
        assertEq(amt, 3 ether);
        assertEq(recipient.balance, 3 ether);
    }

    // ── metadata ────────────────────────────────────────────────
    function test_metadata() public view {
        assertEq(adapter.providerName(), "Lido");
        assertEq(adapter.adapterType(), "DeFi");
        assertEq(adapter.riskLevel(), 2);
        assertEq(adapter.requiredLockPeriod(), 0);
    }
}
