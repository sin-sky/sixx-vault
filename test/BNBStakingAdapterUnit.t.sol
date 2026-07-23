// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BNBStakingAdapter} from "../src/adapters/BNBStakingAdapter.sol";
import {IPancakeV3Router} from "../src/interfaces/IPancakeV3Router.sol";

// ─────────────────────────── Mocks ───────────────────────────

contract MockWBNB is ERC20 {
    constructor() ERC20("Wrapped BNB", "WBNB") {}
    function deposit() external payable { _mint(msg.sender, msg.value); }
    function withdraw(uint256 wad) external {
        _burn(msg.sender, wad);
        (bool ok, ) = msg.sender.call{value: wad}("");
        require(ok, "WBNB: send fail");
    }
    receive() external payable { _mint(msg.sender, msg.value); }
}

contract MockSlisBNB is ERC20 {
    address public minter;
    constructor() ERC20("Staked Lista BNB", "slisBNB") {}
    function setMinter(address m) external { minter = m; }
    function mint(address to, uint256 a) external { require(msg.sender == minter, "not minter"); _mint(to, a); }
}

/// @dev Mock Lista StakeManager. deposit{value} mints slisBNB at `rate` and
///      retains the BNB. rate = BNB per 1 slisBNB (18-dec).
contract MockStakeManager {
    MockSlisBNB public immutable slis;
    uint256 public rate = 1.036e18;
    constructor(address slis_) { slis = MockSlisBNB(slis_); }
    function setRate(uint256 r) external { rate = r; } // simulate reward accrual
    function convertBnbToSnBnb(uint256 a) public view returns (uint256) { return (a * 1e18) / rate; }
    function convertSnBnbToBnb(uint256 s) public view returns (uint256) { return (s * rate) / 1e18; }
    function deposit() external payable { slis.mint(msg.sender, convertBnbToSnBnb(msg.value)); }
}

/// @dev Mock PancakeSwap V3 router. Pays `outBps` of the slisBNB fair BNB value in WBNB.
contract MockV3Router {
    MockStakeManager public immutable stakeMgr;
    uint256 public outBps = 9985; // 0.15% pool slippage vs fair value
    constructor(address stakeMgr_) { stakeMgr = MockStakeManager(stakeMgr_); }
    function setOutBps(uint256 b) external { outBps = b; }
    function exactInputSingle(IPancakeV3Router.ExactInputSingleParams calldata p)
        external payable returns (uint256 amountOut)
    {
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        uint256 fair = stakeMgr.convertSnBnbToBnb(p.amountIn);
        amountOut = (fair * outBps) / 10_000;
        require(amountOut >= p.amountOutMinimum, "V3: slippage");
        IERC20(p.tokenOut).transfer(p.recipient, amountOut);
    }
}

contract Dummy is ERC20 {
    constructor() ERC20("Dummy", "DUM") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

// ─────────────────────────── Tests ───────────────────────────

contract BNBStakingAdapterUnitTest is Test {
    MockWBNB wbnb;
    MockSlisBNB slis;
    MockStakeManager stakeMgr;
    MockV3Router router;
    BNBStakingAdapter adapter;

    address governance = makeAddr("governance");
    address vault      = makeAddr("vault");
    address recipient  = makeAddr("recipient");
    address stranger   = makeAddr("stranger");

    uint24 constant FEE = 500;

    function setUp() public {
        wbnb     = new MockWBNB();
        slis     = new MockSlisBNB();
        stakeMgr = new MockStakeManager(address(slis));
        slis.setMinter(address(stakeMgr));
        router   = new MockV3Router(address(stakeMgr));
        adapter  = new BNBStakingAdapter(
            address(wbnb), address(slis), address(stakeMgr), address(router), FEE, vault, governance, 250
        );
        // Fund the router with WBNB so it can pay out on exits.
        vm.deal(address(this), 1_000 ether);
        wbnb.deposit{value: 1_000 ether}();
        wbnb.transfer(address(router), 1_000 ether);
    }

    function _fund(uint256 amt) internal {
        vm.deal(address(this), amt);
        wbnb.deposit{value: amt}();
        wbnb.transfer(address(adapter), amt);
    }

    // ── constructor validation ──────────────────────────────────
    function test_constructor_reverts_on_zero_fee() public {
        vm.expectRevert("ADAPTER: zero fee");
        new BNBStakingAdapter(
            address(wbnb), address(slis), address(stakeMgr), address(router), 0, vault, governance, 0
        );
    }

    function test_constructor_reverts_on_zero_asset() public {
        vm.expectRevert("ADAPTER: zero asset");
        new BNBStakingAdapter(
            address(0), address(slis), address(stakeMgr), address(router), FEE, vault, governance, 0
        );
    }

    // ── deposit / totalAssets math ──────────────────────────────
    function test_deposit_holds_slisbnb_and_nav_haircut() public {
        _fund(10 ether);
        vm.prank(vault);
        uint256 dep = adapter.deposit(10 ether);
        assertEq(dep, 10 ether);
        assertEq(slis.balanceOf(address(adapter)), stakeMgr.convertBnbToSnBnb(10 ether));
        // NAV = 10 BNB * (1 - 0.5%) = 9.95 BNB (allow sub-wei rounding, vault-favorable)
        assertApproxEqAbs(adapter.totalAssets(), (10 ether * 9950) / 10_000, 2);
        assertLe(adapter.totalAssets(), (10 ether * 9950) / 10_000);
        assertEq(address(adapter).balance, 0, "idle BNB");
        assertEq(wbnb.balanceOf(address(adapter)), 0, "idle WBNB");
    }

    function test_totalAssets_tracks_reward_accrual() public {
        _fund(10 ether);
        vm.prank(vault);
        adapter.deposit(10 ether);
        uint256 navBefore = adapter.totalAssets();
        stakeMgr.setRate(1.09e18); // slisBNB appreciates ~5%
        assertGt(adapter.totalAssets(), navBefore);
    }

    // ── withdraw: partial >= requested; full drain clears ───────
    function test_partial_withdraw_delivers_at_least_requested() public {
        _fund(20 ether);
        vm.prank(vault);
        adapter.deposit(20 ether);
        vm.prank(vault);
        uint256 got = adapter.withdraw(5 ether, recipient);
        assertGe(got, 5 ether);
        assertEq(wbnb.balanceOf(recipient), got);
        assertGt(slis.balanceOf(address(adapter)), 0);
    }

    function test_full_drain_covers_nav_and_zeroes_position() public {
        _fund(20 ether);
        vm.prank(vault);
        adapter.deposit(20 ether);
        uint256 nav = adapter.totalAssets();
        vm.prank(vault);
        uint256 got = adapter.withdraw(nav, recipient);
        assertGe(got, nav);
        assertEq(slis.balanceOf(address(adapter)), 0);
    }

    function test_withdraw_reverts_when_pool_below_floor() public {
        _fund(10 ether);
        vm.prank(vault);
        adapter.deposit(10 ether);
        router.setOutBps(9000); // 10% loss, below 0.5% floor
        vm.prank(vault);
        vm.expectRevert("V3: slippage");
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
        vm.prank(vault);
        vm.expectRevert("ADAPTER: only governance");
        adapter.unpause();
        vm.prank(governance);
        adapter.unpause();
        assertTrue(adapter.isActive());
    }

    // ── admin bounds ────────────────────────────────────────────
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
        adapter.setEstimatedAPY(300);
        assertEq(adapter.estimatedAPY(), 300);
    }

    // ── M-4 two-step rotations ──────────────────────────────────
    function test_vault_rotation_two_step() public {
        address newVault = makeAddr("newVault");
        vm.prank(governance);
        adapter.proposeVault(newVault);
        vm.prank(stranger);
        vm.expectRevert("ADAPTER: not pending vault");
        adapter.acceptVault();
        vm.prank(newVault);
        adapter.acceptVault();
        assertEq(adapter.vault(), newVault);
    }

    function test_governance_rotation_two_step() public {
        address newGov = makeAddr("newGov");
        vm.prank(governance);
        adapter.proposeGovernance(newGov);
        vm.prank(newGov);
        adapter.acceptGovernance();
        assertEq(adapter.governance(), newGov);
    }

    // ── rescue ──────────────────────────────────────────────────
    function test_rescue_cannot_touch_position() public {
        vm.prank(governance);
        vm.expectRevert("ADAPTER: cannot rescue position");
        adapter.rescueToken(address(slis), governance);
    }

    function test_rescue_moves_stray_token() public {
        Dummy d = new Dummy();
        d.mint(address(adapter), 777);
        vm.prank(governance);
        uint256 amt = adapter.rescueToken(address(d), recipient);
        assertEq(amt, 777);
        assertEq(d.balanceOf(recipient), 777);
    }

    function test_rescue_bnb() public {
        vm.deal(address(adapter), 4 ether);
        vm.prank(governance);
        uint256 amt = adapter.rescueBNB(recipient);
        assertEq(amt, 4 ether);
        assertEq(recipient.balance, 4 ether);
    }

    // ── metadata ────────────────────────────────────────────────
    function test_metadata() public view {
        assertEq(adapter.providerName(), "Lista DAO");
        assertEq(adapter.adapterType(), "DeFi");
        assertEq(adapter.riskLevel(), 2);
        assertEq(adapter.requiredLockPeriod(), 0);
    }
}
