// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EthenaSUSDeAdapter} from "../src/adapters/EthenaSUSDeAdapter.sol";
import {MockUSDC} from "./SIXXVault.t.sol";

// ─────────────────────────────────────────────────────────────
// Mocks
// ─────────────────────────────────────────────────────────────

/// @dev Generic 18-decimal ERC20 (USDe, crvUSD).
contract Mock18 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

/// @dev Minimal StakedUSDeV2: ERC-4626-ish over USDe with a fixed appreciation
///      rate (USDe per sUSDe, 1e18). deposit() stakes with no cooldown.
contract MockStakedUSDe is ERC20 {
    IERC20 public immutable usde;
    uint256 public rate; // USDe (1e18) per 1e18 sUSDe

    constructor(IERC20 usde_, uint256 rate_) ERC20("Staked USDe", "sUSDe") {
        usde = usde_;
        rate = rate_;
    }

    function asset() external view returns (address) { return address(usde); }
    function cooldownDuration() external pure returns (uint24) { return 7 days; }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return (shares * rate) / 1e18;
    }
    function convertToShares(uint256 assets) public view returns (uint256) {
        return (assets * 1e18) / rate;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        usde.transferFrom(msg.sender, address(this), assets);
        shares = convertToShares(assets);
        _mint(receiver, shares);
    }

    // let the yield accrue (used to simulate sUSDe appreciation)
    function setRate(uint256 r) external { rate = r; }
}

/// @dev Two-coin Curve-style pool priced in USD. Handles cross-decimals and a
///      per-token USD price so sUSDe (worth >1 USD) swaps correctly. Pre-fund it
///      with output tokens. `feeBps` simulates slippage; set high to force reverts.
contract MockCurvePool {
    address[2] public coinList;
    uint8[2]   public dec;
    uint256[2] public priceUsd; // 1e18-scaled USD per whole token
    uint256 public feeBps;
    bool public reenter;              // reentrancy test toggle
    address public reentrantTarget;   // adapter to re-enter

    constructor(
        address c0, uint8 d0, uint256 p0,
        address c1, uint8 d1, uint256 p1,
        uint256 feeBps_
    ) {
        coinList = [c0, c1];
        dec = [d0, d1];
        priceUsd = [p0, p1];
        feeBps = feeBps_;
    }

    function coins(uint256 i) external view returns (address) { return coinList[i]; }

    function setReentrancy(address target) external { reenter = true; reentrantTarget = target; }

    function get_dy(int128 i, int128 j, uint256 dx) public view returns (uint256) {
        uint256 usd18 = (dx * priceUsd[uint128(i)]) / (10 ** dec[uint128(i)]);
        uint256 dy = (usd18 * (10 ** dec[uint128(j)])) / priceUsd[uint128(j)];
        return (dy * (10_000 - feeBps)) / 10_000;
    }

    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256 dy) {
        if (reenter) {
            // Attempt to re-enter the adapter mid-swap; the guard must revert.
            EthenaSUSDeAdapter(reentrantTarget).deposit(1);
        }
        dy = get_dy(i, j, dx);
        require(dy >= min_dy, "MockCurve: slippage");
        IERC20(coinList[uint128(i)]).transferFrom(msg.sender, address(this), dx);
        IERC20(coinList[uint128(j)]).transfer(msg.sender, dy);
    }
}

// ─────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────

contract EthenaSUSDeAdapterUnitTest is Test {
    address governance = makeAddr("governance");
    address vault      = makeAddr("vault");
    address stranger   = makeAddr("stranger");
    address recipient  = makeAddr("recipient");

    uint256 constant RATE = 1.2e18;   // 1 sUSDe = 1.2 USDe
    uint256 constant PAR  = 1e18;     // $1 tokens
    uint256 constant SUSDE_PRICE = 1.2e18;

    MockUSDC     usdc;
    Mock18       usde;
    Mock18       crvusd;
    MockStakedUSDe susde;
    MockCurvePool entryPool; // USDC <-> USDe
    MockCurvePool exitPool1; // sUSDe <-> crvUSD
    MockCurvePool exitPool2; // crvUSD <-> USDC
    EthenaSUSDeAdapter adapter;

    function _deploy(uint256 fee1, uint256 fee2, uint256 feeEntry) internal {
        usdc   = new MockUSDC();
        usde   = new Mock18("USDe", "USDe");
        crvusd = new Mock18("crvUSD", "crvUSD");
        susde  = new MockStakedUSDe(IERC20(address(usde)), RATE);

        entryPool = new MockCurvePool(
            address(usdc), 6, PAR, address(usde), 18, PAR, feeEntry
        );
        exitPool1 = new MockCurvePool(
            address(susde), 18, SUSDE_PRICE, address(crvusd), 18, PAR, fee1
        );
        exitPool2 = new MockCurvePool(
            address(crvusd), 18, PAR, address(usdc), 6, PAR, fee2
        );

        // Pre-fund pools with deep liquidity of their output tokens.
        usde.mint(address(entryPool), 100_000_000e18);
        crvusd.mint(address(exitPool1), 100_000_000e18);
        usdc.mint(address(exitPool2), 100_000_000e6);

        adapter = new EthenaSUSDeAdapter(
            address(usdc), address(susde), address(crvusd),
            address(entryPool), address(exitPool1), address(exitPool2),
            vault, governance, 800
        );
    }

    function setUp() public {
        _deploy(10, 10, 10); // 0.1% fee per leg → within 0.5% cap
    }

    /// @dev Simulate the vault: mint USDC to adapter, then call deposit as vault.
    function _vaultDeposit(uint256 usdcAmt) internal {
        usdc.mint(address(adapter), usdcAmt);
        vm.prank(vault);
        adapter.deposit(usdcAmt);
    }

    // ── constructor / config ───────────────────────────────────

    function test_constructor_binds_asset_and_indices() public view {
        assertEq(adapter.asset(), address(usdc));
        assertEq(address(adapter.susde()), address(susde));
        // entry pool: coin0=USDC, coin1=USDe
        assertEq(adapter.entryUsdcIndex(), int128(0));
        assertEq(adapter.entryUsdeIndex(), int128(1));
        // exit1: coin0=sUSDe, coin1=crvUSD
        assertEq(adapter.exit1SusdeIndex(), int128(0));
        assertEq(adapter.exit1CrvusdIndex(), int128(1));
        // exit2: coin0=crvUSD, coin1=USDC
        assertEq(adapter.exit2CrvusdIndex(), int128(0));
        assertEq(adapter.exit2UsdcIndex(), int128(1));
    }

    function test_constructor_reverts_on_wrong_pool_tokens() public {
        // entryPool that does not contain USDC → index derivation reverts.
        MockCurvePool badPool = new MockCurvePool(
            address(usde), 18, PAR, address(crvusd), 18, PAR, 0
        );
        vm.expectRevert("ADAPTER: token not in pool");
        new EthenaSUSDeAdapter(
            address(usdc), address(susde), address(crvusd),
            address(badPool), address(exitPool1), address(exitPool2),
            vault, governance, 800
        );
    }

    function test_metadata() public view {
        assertEq(adapter.riskLevel(), 4);
        assertEq(adapter.estimatedAPY(), 800);
        assertEq(adapter.requiredLockPeriod(), 0);
        assertEq(adapter.name(), "SIXX High Yield - Ethena sUSDe");
        assertEq(adapter.providerName(), "Ethena");
        assertTrue(adapter.isActive());
        assertEq(
            adapter.description(),
            "principal in synthetic USD (Ethena sUSDe); yield variable, NOT principal-guaranteed; 7-day cooldown bypassed via instant market exit; depeg risk (Oct-2025 briefly $0.65)"
        );
    }

    // ── deposit ────────────────────────────────────────────────

    function test_deposit_stakes_into_susde() public {
        _vaultDeposit(10_000e6);
        // sUSDe held = ~ 10_000 USDe (minus 0.1% entry fee) / 1.2
        uint256 shares = susde.balanceOf(address(adapter));
        // 10000 USDC → ~9990 USDe → /1.2 ≈ 8325 sUSDe
        assertApproxEqRel(shares, uint256(9_990e18) * 1e18 / RATE, 0.002e18);
        // no leftover USDC/USDe in adapter
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(usde.balanceOf(address(adapter)), 0);
    }

    function test_deposit_onlyVault() public {
        usdc.mint(address(adapter), 1_000e6);
        vm.prank(stranger);
        vm.expectRevert("ADAPTER: only vault");
        adapter.deposit(1_000e6);
    }

    function test_deposit_zero_reverts() public {
        vm.prank(vault);
        vm.expectRevert("ADAPTER: zero amount");
        adapter.deposit(0);
    }

    // ── totalAssets (haircut) ──────────────────────────────────

    function test_totalAssets_is_haircut_of_convertToAssets() public {
        _vaultDeposit(10_000e6);
        uint256 shares = susde.balanceOf(address(adapter));
        uint256 fairUsdc = susde.convertToAssets(shares) / 1e12; // USDe→USDC 1:1
        uint256 expected = fairUsdc * (10_000 - 50) / 10_000;    // 0.5% haircut
        assertEq(adapter.totalAssets(), expected);
        // reported NAV strictly below fair value (conservative)
        assertLt(adapter.totalAssets(), fairUsdc);
    }

    function test_totalAssets_zero_when_empty() public view {
        assertEq(adapter.totalAssets(), 0);
    }

    // ── withdraw round trips ───────────────────────────────────

    function test_partial_withdraw_delivers_at_least_requested() public {
        _vaultDeposit(50_000e6);
        uint256 want = 10_000e6;
        vm.prank(vault);
        uint256 got = adapter.withdraw(want, recipient);
        assertGe(got, want);                          // vault shortfall guard holds
        assertEq(usdc.balanceOf(recipient), got);
        // position still holds the remainder
        assertGt(susde.balanceOf(address(adapter)), 0);
    }

    function test_full_drain_clears_vault_shortfall_guard() public {
        _vaultDeposit(20_000e6);
        uint256 reportedNav = adapter.totalAssets();
        vm.prank(vault);
        uint256 got = adapter.withdraw(reportedNav, recipient);
        // Full exit sells all sUSDe; realized USDC must cover the reported NAV
        // (this is exactly the vault's `received >= adapterBal` requirement).
        assertGe(got, reportedNav);
        assertEq(susde.balanceOf(address(adapter)), 0);
    }

    function test_withdraw_larger_than_nav_drains_all() public {
        _vaultDeposit(20_000e6);
        vm.prank(vault);
        uint256 got = adapter.withdraw(type(uint128).max, recipient);
        assertGt(got, 0);
        assertEq(susde.balanceOf(address(adapter)), 0);
    }

    function test_withdraw_onlyVault() public {
        _vaultDeposit(10_000e6);
        vm.prank(stranger);
        vm.expectRevert("ADAPTER: only vault");
        adapter.withdraw(1_000e6, recipient);
    }

    function test_withdraw_zero_recipient_reverts() public {
        _vaultDeposit(10_000e6);
        vm.prank(vault);
        vm.expectRevert("ADAPTER: zero recipient");
        adapter.withdraw(1_000e6, address(0));
    }

    // ── slippage cap enforcement ───────────────────────────────

    function test_withdraw_reverts_when_slippage_exceeds_cap() public {
        // exit pools charge 0.6% total (>0.5% cap) → min_dy on final leg fails.
        _deploy(40, 40, 10);
        _vaultDeposit(10_000e6);
        vm.prank(vault);
        vm.expectRevert(); // MockCurve slippage / below min_dy
        adapter.withdraw(5_000e6, recipient);
    }

    function test_deposit_reverts_when_entry_slippage_exceeds_cap() public {
        _deploy(10, 10, 60); // 0.6% entry fee > 0.5% cap
        usdc.mint(address(adapter), 10_000e6);
        vm.prank(vault);
        vm.expectRevert();
        adapter.deposit(10_000e6);
    }

    // ── reentrancy ─────────────────────────────────────────────

    function test_reentrancy_blocked_on_exit() public {
        _vaultDeposit(10_000e6);
        // Arm exitPool1 to re-enter adapter.deposit during the swap.
        exitPool1.setReentrancy(address(adapter));
        usdc.mint(address(adapter), 1e6); // give the reentrant deposit something to pull
        vm.prank(vault);
        vm.expectRevert(); // ReentrancyGuard: reentrant call
        adapter.withdraw(1_000e6, recipient);
    }

    // ── pause ──────────────────────────────────────────────────

    function test_pause_blocks_deposit() public {
        vm.prank(governance);
        adapter.pause();
        assertFalse(adapter.isActive());
        usdc.mint(address(adapter), 1_000e6);
        vm.prank(vault);
        vm.expectRevert("ADAPTER: paused");
        adapter.deposit(1_000e6);
    }

    function test_pause_does_not_block_withdraw() public {
        _vaultDeposit(10_000e6);
        vm.prank(governance);
        adapter.pause();
        vm.prank(vault);
        uint256 got = adapter.withdraw(1_000e6, recipient);
        assertGe(got, 1_000e6); // exits still work while paused (users can leave)
    }

    function test_pause_onlyAuthorized() public {
        vm.prank(stranger);
        vm.expectRevert("ADAPTER: unauthorized");
        adapter.pause();
    }

    function test_unpause_onlyGovernance() public {
        vm.prank(governance);
        adapter.pause();
        vm.prank(stranger);
        vm.expectRevert("ADAPTER: only governance");
        adapter.unpause();
    }

    // ── harvest ────────────────────────────────────────────────

    function test_harvest_is_noop_and_onlyVault() public {
        vm.prank(vault);
        assertEq(adapter.harvest(), 0);
        vm.prank(stranger);
        vm.expectRevert("ADAPTER: only vault");
        adapter.harvest();
    }

    // ── admin: APY / rotations ─────────────────────────────────

    function test_setEstimatedAPY_onlyGovernance() public {
        vm.prank(governance);
        adapter.setEstimatedAPY(1_500);
        assertEq(adapter.estimatedAPY(), 1_500);
        vm.prank(stranger);
        vm.expectRevert("ADAPTER: not governance");
        adapter.setEstimatedAPY(1);
    }

    function test_vault_rotation_two_step() public {
        address newVault = makeAddr("newVault");
        vm.prank(governance);
        adapter.proposeVault(newVault);
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

    // ── rescue ─────────────────────────────────────────────────

    function test_rescue_sweeps_stray_token() public {
        Mock18 stray = new Mock18("X", "X");
        stray.mint(address(adapter), 5e18);
        vm.prank(governance);
        uint256 amt = adapter.rescueToken(address(stray), recipient);
        assertEq(amt, 5e18);
        assertEq(stray.balanceOf(recipient), 5e18);
    }

    function test_rescue_cannot_take_position() public {
        _vaultDeposit(10_000e6);
        vm.prank(governance);
        vm.expectRevert("ADAPTER: cannot rescue position");
        adapter.rescueToken(address(susde), recipient);
    }

    function test_rescue_onlyGovernance() public {
        vm.prank(stranger);
        vm.expectRevert("ADAPTER: not governance");
        adapter.rescueToken(address(usdc), recipient);
    }

    // ── appreciation flows through totalAssets ─────────────────

    function test_yield_accrual_raises_totalAssets() public {
        _vaultDeposit(10_000e6);
        uint256 before = adapter.totalAssets();
        susde.setRate(1.3e18); // sUSDe appreciates
        assertGt(adapter.totalAssets(), before);
    }

    // ── ADR-007 #1: governance-settable slippage (depeg liveness lever) ─────────

    function test_setSlippageBps_default_and_governanceUpdate() public {
        assertEq(adapter.slippageBps(), 50, "default 0.5%");
        assertEq(adapter.MAX_SLIPPAGE_BPS(), 300, "cap 3%");
        vm.prank(governance);
        adapter.setSlippageBps(200);
        assertEq(adapter.slippageBps(), 200, "governance widened to 2%");
    }

    function test_setSlippageBps_onlyGovernance() public {
        vm.prank(stranger);
        vm.expectRevert("ADAPTER: not governance");
        adapter.setSlippageBps(100);
    }

    function test_setSlippageBps_capEnforced() public {
        vm.prank(governance);
        vm.expectRevert("ADAPTER: slippage too high");
        adapter.setSlippageBps(301); // over MAX_SLIPPAGE_BPS

        vm.prank(governance);
        adapter.setSlippageBps(300); // exactly the cap is allowed
        assertEq(adapter.slippageBps(), 300);
    }

    /// @notice Widening slippage lowers the reported NAV (bigger haircut) — the honest,
    ///         conservative mark that lets exits keep clearing during a depeg.
    function test_wideningSlippage_lowersNavMark() public {
        _vaultDeposit(10_000e6);
        uint256 navBefore = adapter.totalAssets();
        vm.prank(governance);
        adapter.setSlippageBps(200); // 0.5% -> 2%
        assertLt(adapter.totalAssets(), navBefore, "wider haircut => lower, honest NAV");
    }
}
