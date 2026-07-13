// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {SIXXVault} from "../src/core/SIXXVault.sol";
import {IStrategyAdapter} from "../src/interfaces/IStrategyAdapter.sol";
import {MockUSDC} from "./SIXXVault.t.sol";
import {HarvestAdapter} from "./mocks/HarvestAdapter.sol";
import {FaultyAdapter} from "./mocks/FaultyAdapter.sol";
import {MockAdapter} from "./mocks/MockAdapter.sol";

/// @title FundProtectionUnderFailureTest
/// @notice Fund-protection resilience PoCs: five failure scenarios, each asserting the four
///         fund-protection conditions — (a) recoverable, (b) loss isolated/bounded,
///         (c) fair socialization (pre-failure early-exit reverts), (d) graceful degradation
///         (no wipeout; the emergency valve is never bricked). Adversarial-mock based, so the
///         whole suite runs under `forge test` with NO fork/RPC.
///
///         Companion analysis: audit/FUND_PROTECTION_UNDER_FAILURE.md.
///         Production `src/` is unchanged; this is tests/mocks only.
contract FundProtectionUnderFailureTest is Test {
    using SafeERC20 for IERC20;

    MockUSDC usdc;

    address gov      = makeAddr("gov");
    address guardian = makeAddr("guardian");
    address fee      = makeAddr("fee");
    address alice    = makeAddr("alice");
    address bob      = makeAddr("bob");
    address carol    = makeAddr("carol");
    address attacker = makeAddr("attacker");
    address sink     = makeAddr("sink");

    uint256 constant D = 1e6; // USDC unit

    function setUp() public {
        usdc = new MockUSDC();
    }

    // ─── helpers ─────────────────────────────────────────────────────────

    function _vaultWith(address gov_) internal returns (SIXXVault v) {
        // adapterRegistry = address(0): permissionless routing so the failure/liveness
        // behaviour is isolated from the H-1 whitelist (which is exercised elsewhere).
        v = new SIXXVault(
            IERC20(address(usdc)), "SIXX Stable Yield", "sxUSDC",
            gov_, address(0), fee, guardian
        );
    }

    function _attach(SIXXVault v, address gov_, address adapter) internal {
        vm.prank(gov_);
        v.setAdapter(adapter);
    }

    function _deposit(SIXXVault v, address who, uint256 amt) internal returns (uint256 shares) {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(v), amt);
        shares = v.deposit(amt, who);
        vm.stopPrank();
    }

    function _redeemAll(SIXXVault v, address who) internal returns (uint256 got) {
        uint256 sh = v.balanceOf(who);
        vm.prank(who);
        got = v.redeem(sh, who, who);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // A2 — external protocol insolvency is isolated + fairly socialized
    // ═══════════════════════════════════════════════════════════════════════

    function test_A2_externalInsolvency_isolatedAndSocialized() public {
        // Vault 1 holds real principal via a harvest-style adapter.
        SIXXVault v1 = _vaultWith(gov);
        HarvestAdapter a1 = new HarvestAdapter(address(usdc), address(v1));
        _attach(v1, gov, address(a1));
        _deposit(v1, alice, 10_000 * D);
        _deposit(v1, bob,   10_000 * D);
        assertEq(v1.totalAssets(), 20_000 * D, "pre-loss NAV");

        // Isolation control: an independent vault + adapter holding Carol's funds.
        SIXXVault v2 = _vaultWith(gov);
        HarvestAdapter a2 = new HarvestAdapter(address(usdc), address(v2));
        _attach(v2, gov, address(a2));
        _deposit(v2, carol, 10_000 * D);
        uint256 v2NavBefore = v2.totalAssets();

        // Inject bad-debt into vault1's adapter: 25% of principal becomes insolvent.
        a1.simulateLoss(5_000 * D, sink);

        // (c) the loss hit the live mark immediately — nobody can exit at the pre-loss value.
        assertEq(v1.totalAssets(), 15_000 * D, "post-loss NAV must equal the honest mark");
        assertLt(v1.maxWithdraw(alice), 10_000 * D, "pre-loss face should exceed the honest cap");
        vm.prank(alice);
        vm.expectRevert(); // ERC4626ExceededMaxWithdraw — cannot exit at the pre-loss face value
        v1.withdraw(10_000 * D, alice, alice);

        // (a) recoverable + (c) equal split: both redeem their honest pro-rata (~7.5k each).
        uint256 aliceGot = _redeemAll(v1, alice);
        uint256 bobGot   = _redeemAll(v1, bob);
        assertApproxEqRel(aliceGot, 7_500 * D, 1e14, "alice pro-rata");
        assertApproxEqRel(bobGot,   7_500 * D, 1e14, "bob pro-rata");
        assertApproxEqAbs(aliceGot, bobGot, 2, "loss not socialized equally");

        // (d) graceful: recovered > 0 (75% of principal), not a wipeout.
        assertGt(aliceGot, 0, "wipeout");

        // (b) isolation: vault2 is untouched; Carol is still whole.
        assertEq(v2.totalAssets(), v2NavBefore, "loss leaked into the other strategy");
        uint256 carolGot = _redeemAll(v2, carol);
        assertApproxEqRel(carolGot, 10_000 * D, 1e14, "carol should be unaffected");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // B1 — Ethena depeg: honest accounting, no pre-depeg front-run
    // ═══════════════════════════════════════════════════════════════════════

    function test_B1_ethenaDepeg_honestAccounting_noFrontRun() public {
        SIXXVault v = _vaultWith(gov);
        // HarvestAdapter stands in for the sUSDe-backed position; simulateLoss models a depeg.
        HarvestAdapter a = new HarvestAdapter(address(usdc), address(v));
        _attach(v, gov, address(a));
        _deposit(v, alice, 10_000 * D);
        _deposit(v, bob,   10_000 * D);

        // Depeg: sUSDe mark drops 20% (honest re-valuation, reflected atomically).
        a.simulateLoss(4_000 * D, sink);
        assertApproxEqRel(v.totalAssets(), 16_000 * D, 1e14, "depegged NAV must equal the honest mark");

        // (c) CENTERPIECE: an early-exiter cannot dump sUSDe exposure at the pre-depeg par onto
        //     the remaining holder — withdrawing the pre-depeg face value reverts.
        assertLt(v.maxWithdraw(alice), 10_000 * D, "pre-depeg face should exceed the honest cap");
        vm.prank(alice);
        vm.expectRevert(); // ERC4626ExceededMaxWithdraw — cannot exit at the pre-depeg par
        v.withdraw(10_000 * D, alice, alice);

        // (a)+(c) both holders realize the SAME honest 20% haircut (~8k each), order-independent.
        uint256 aliceGot = _redeemAll(v, alice);
        uint256 bobGot   = _redeemAll(v, bob);
        assertApproxEqRel(aliceGot, 8_000 * D, 1e14, "alice honest post-depeg value");
        assertApproxEqAbs(aliceGot, bobGot, 2, "depeg loss not shared equally");

        // (b) bounded to the depeg magnitude; (d) not a wipeout.
        assertGt(bobGot, 0, "wipeout");
        assertApproxEqRel(aliceGot + bobGot, 16_000 * D, 1e14, "total must equal the depegged NAV");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // D1 — governance compromise × Timelock exit window
    // ═══════════════════════════════════════════════════════════════════════

    bytes32 private constant DRAIN_SALT = bytes32(uint256(0xDEAD));

    function test_D1_govCompromise_timelockExitWindow() public {
        uint256 delay = 48 hours;
        TimelockController tl = _timelock(delay);

        SIXXVault v = _vaultWith(address(tl));
        MockAdapter good = new MockAdapter(address(usdc), address(v));
        _attachViaTimelock(tl, v, address(good), delay); // one-time legit wiring
        _deposit(v, alice, 20_000 * D);
        assertEq(v.totalAssets(), 20_000 * D, "setup NAV");

        // A malicious adapter that siphons every pushed deposit to the attacker.
        DrainAdapter drain = new DrainAdapter(address(usdc), address(v), attacker);

        // (c) neither an EOA direct call nor a same-block timelock execute can reroute.
        _assertNoInstantReroute(tl, v, good, drain, delay);

        // (a) during the 48h window the user exits fully — withdrawals are permissionless.
        uint256 got = _redeemAll(v, alice);
        assertApproxEqRel(got, 20_000 * D, 1e14, "user could not exit during the timelock window");

        // (b) when the attacker finally executes, the vault is already empty -> theft ~= 0.
        vm.warp(block.timestamp + delay + 1);
        vm.prank(attacker);
        tl.execute(address(v), 0, _drainData(drain), bytes32(0), DRAIN_SALT);
        assertEq(v.activeAdapter(), address(drain), "reroute should now be active");
        assertLe(usdc.balanceOf(attacker), 1, "attacker drained user funds despite the timelock");
    }

    function _timelock(uint256 delay) internal returns (TimelockController tl) {
        address[] memory ps = new address[](1); ps[0] = attacker; // compromised proposer
        address[] memory es = new address[](1); es[0] = attacker; // compromised executor
        tl = new TimelockController(delay, ps, es, address(0));
    }

    function _drainData(DrainAdapter drain) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(SIXXVault.setAdapter.selector, address(drain));
    }

    /// @dev Proves the two instant-reroute paths are both blocked, leaving `good` active.
    function _assertNoInstantReroute(
        TimelockController tl, SIXXVault v, MockAdapter good, DrainAdapter drain, uint256 delay
    ) internal {
        // Attacker's EOA cannot touch the vault directly — gov IS the timelock.
        vm.prank(attacker);
        vm.expectRevert(bytes("VAULT: not governance"));
        v.setAdapter(address(drain));

        // Even via the timelock, the malicious reroute is NOT executable before the delay.
        bytes memory data = _drainData(drain);
        bytes32 opId = tl.hashOperation(address(v), 0, data, bytes32(0), DRAIN_SALT);
        vm.prank(attacker);
        tl.schedule(address(v), 0, data, bytes32(0), DRAIN_SALT, delay);
        assertFalse(tl.isOperationReady(opId), "malicious op unexpectedly ready before delay");
        vm.prank(attacker);
        vm.expectRevert(); // TimelockUnexpectedOperationState (not ready)
        tl.execute(address(v), 0, data, bytes32(0), DRAIN_SALT);
        assertEq(v.activeAdapter(), address(good), "reroute leaked before the delay");
    }

    function _attachViaTimelock(TimelockController tl, SIXXVault v, address adapter, uint256 delay)
        internal
    {
        bytes memory data = abi.encodeWithSelector(SIXXVault.setAdapter.selector, adapter);
        bytes32 salt = bytes32(uint256(1));
        vm.prank(attacker);
        tl.schedule(address(v), 0, data, bytes32(0), salt, delay);
        vm.warp(block.timestamp + delay + 1);
        vm.prank(attacker);
        tl.execute(address(v), 0, data, bytes32(0), salt);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // E1 — bank run × illiquid (solvent): fair, no fire-sale, recoverable
    // ═══════════════════════════════════════════════════════════════════════

    function test_E1_bankRun_illiquidButSolvent_fairAndRecoverable() public {
        SIXXVault v = _vaultWith(gov);
        IlliquidAdapter a = new IlliquidAdapter(address(usdc), address(v));
        _attach(v, gov, address(a));
        _deposit(v, alice, 10_000 * D);
        _deposit(v, bob,   10_000 * D);
        _deposit(v, carol, 10_000 * D);
        assertEq(v.totalAssets(), 30_000 * D, "setup NAV");

        // Liquidity crunch: only 10k of 30k is withdrawable now (rest locked in-protocol).
        a.setAvailableLiquidity(10_000 * D);

        // (c) a first-mover cannot extract MORE than a pro-rata share (no draining others).
        assertApproxEqRel(v.maxWithdraw(alice), 10_000 * D, 1e14, "cap should be the honest 1/3 share");
        vm.prank(alice);
        vm.expectRevert(); // ERC4626ExceededMaxWithdraw — cannot grab beyond a pro-rata share
        v.withdraw(15_000 * D, alice, alice);

        // Alice takes exactly her honest share (10k), consuming the available liquidity.
        uint256 aliceGot = _redeemAll(v, alice);
        assertApproxEqRel(aliceGot, 10_000 * D, 1e14, "alice honest share");

        // (c) ADR-007 柱1: a late-mover gets an honest partial-fill of the remaining liquidity —
        //     which is 0 right now — with NO revert and NO fire-sale haircut. Bob is not stranded;
        //     nothing burns and he keeps his full claim as shares to recover when liquidity returns.
        uint256 bobShares = v.balanceOf(bob);
        vm.prank(bob);
        uint256 bobEarly = v.redeem(bobShares, bob, bob);
        assertEq(bobEarly, 0, "no liquidity now -> zero cash, no fire-sale");
        assertEq(v.balanceOf(bob), bobShares, "no shares burned; full pro-rata claim retained");

        // (b) illiquidity is NOT a loss: NAV intact for the two remaining holders (20k).
        assertApproxEqRel(v.totalAssets(), 20_000 * D, 1e14, "illiquidity must not be a loss");

        // (a)+(d) liquidity returns -> everyone recovers in full; no permanent stuck.
        a.setAvailableLiquidity(20_000 * D);
        uint256 bobGot   = _redeemAll(v, bob);
        uint256 carolGot = _redeemAll(v, carol);
        assertApproxEqRel(bobGot,   10_000 * D, 1e14, "bob full recovery after liquidity returns");
        assertApproxEqRel(carolGot, 10_000 * D, 1e14, "carol full recovery after liquidity returns");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // G1 — post-deploy adapter bug × force-detach: users still exit
    // ═══════════════════════════════════════════════════════════════════════

    function test_G1_postDeployBug_forceDetach_usersExit() public {
        SIXXVault v = _vaultWith(gov);
        FaultyAdapter a = new FaultyAdapter(address(usdc), address(v));
        _attach(v, gov, address(a));
        _deposit(v, alice, 10_000 * D);
        _deposit(v, bob,   10_000 * D);
        assertEq(v.totalAssets(), 20_000 * D, "setup NAV");

        // Post-deploy bug: the adapter can now only realize 50% of its mark on withdraw.
        a.setDeliverBps(5_000);

        // (c) nobody can grab MORE than their pro-rata mark share ahead of the writeoff: an
        //     over-cap withdraw still reverts on the ERC-4626 max guard. (A within-cap exit would
        //     merely partial-fill to the realizable 50% — no revert, no fire-sale — but we leave
        //     the pool intact here so the force-detach writeoff below splits equally.)
        vm.prank(alice);
        vm.expectRevert(); // ERC4626ExceededMaxWithdraw
        v.withdraw(15_000 * D, alice, alice);

        // (d) the emergency valve is never bricked by the adapter: even when totalAssets()
        //     reverts, shutdown still toggles (brick-proof).
        a.setRevertOnTotalAssets(true);
        vm.prank(guardian);
        v.setEmergencyShutdown(true);
        assertTrue(v.emergencyShutdown(), "shutdown bricked by a broken adapter");
        a.setRevertOnTotalAssets(false); // gov can now read the mark to book the writeoff

        // Force-detach isolates the bug: recover the realizable half, write off the rest,
        // pause deposits so nobody mints against the impaired pool.
        vm.prank(gov);
        v.setAdapter(address(0));
        assertEq(v.activeAdapter(), address(0), "force-detach failed");
        assertTrue(v.depositsPaused(), "impaired pool not deposit-paused");

        // (a) users exit with the recovered pro-rata; (b) loss bounded to the unrecovered half;
        // (c) the writeoff is split equally across both holders.
        uint256 aliceGot = _redeemAll(v, alice);
        uint256 bobGot   = _redeemAll(v, bob);
        assertGt(aliceGot, 0, "user could not exit after detach");
        assertApproxEqAbs(aliceGot, bobGot, 2, "writeoff not socialized equally");
        assertApproxEqRel(aliceGot + bobGot, 10_000 * D, 1e14, "recovered != realizable half");
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Scenario-specific adversarial mocks
// ═══════════════════════════════════════════════════════════════════════════

/// @notice E1: solvent-but-illiquid adapter. `totalAssets()` (the mark) is unaffected by the
///         liquidity crunch; `withdraw` only releases up to `availableLiquidity`, under-delivering
///         beyond it so the vault's `received >= toWithdraw` guard reverts (no forced fire-sale).
contract IlliquidAdapter is IStrategyAdapter {
    using SafeERC20 for IERC20;

    address public override asset;
    address public vault;
    uint256 private _mark;
    uint256 public availableLiquidity;

    constructor(address asset_, address vault_) {
        asset = asset_;
        vault = vault_;
    }

    modifier onlyVault() {
        require(msg.sender == vault, "ILLIQ: only vault");
        _;
    }

    function setAvailableLiquidity(uint256 x) external { availableLiquidity = x; }

    function totalAssets() external view override returns (uint256) { return _mark; }

    function deposit(uint256 assets) external override onlyVault returns (uint256) {
        _mark += assets; // tokens were transferred in by the vault before this call
        emit Deposited(assets, assets);
        return assets;
    }

    function withdraw(uint256 assets, address recipient) external override onlyVault returns (uint256) {
        uint256 send = assets <= availableLiquidity ? assets : availableLiquidity;
        _mark -= send;
        availableLiquidity -= send;
        IERC20(asset).safeTransfer(recipient, send);
        emit Withdrawn(assets, send, recipient);
        return send;
    }

    function harvest() external override returns (uint256) { emit Harvested(0); return 0; }
    function name() external pure override returns (string memory) { return "Illiquid Adapter"; }
    function providerName() external pure override returns (string memory) { return "Illiquid"; }
    function adapterType() external pure override returns (string memory) { return "Test"; }
    function riskLevel() external pure override returns (uint8) { return 1; }
    function estimatedAPY() external pure override returns (uint256) { return 0; }
    function requiredLockPeriod() external pure override returns (uint256) { return 0; }
    function isActive() external pure override returns (bool) { return true; }
    function pause() external override { emit Paused(); }
    function unpause() external override { emit Unpaused(); }
}

/// @notice D1: malicious adapter that siphons every pushed deposit straight to the attacker.
///         Models the drain a compromised governance would route to — the property under test
///         is that the 48h Timelock delays this long enough for users to exit first.
contract DrainAdapter is IStrategyAdapter {
    using SafeERC20 for IERC20;

    address public override asset;
    address public vault;
    address public attacker;

    constructor(address asset_, address vault_, address attacker_) {
        asset = asset_;
        vault = vault_;
        attacker = attacker_;
    }

    modifier onlyVault() {
        require(msg.sender == vault, "DRAIN: only vault");
        _;
    }

    function totalAssets() external view override returns (uint256) {
        // Whatever it holds is instantly gone; report 0 so it looks empty.
        return IERC20(asset).balanceOf(address(this));
    }

    function deposit(uint256 assets) external override onlyVault returns (uint256) {
        uint256 bal = IERC20(asset).balanceOf(address(this));
        if (bal > 0) IERC20(asset).safeTransfer(attacker, bal); // siphon
        emit Deposited(assets, assets);
        return assets;
    }

    function withdraw(uint256, address) external override onlyVault returns (uint256) {
        emit Withdrawn(0, 0, attacker);
        return 0; // nothing to give back — funds already stolen
    }

    function harvest() external override returns (uint256) { emit Harvested(0); return 0; }
    function name() external pure override returns (string memory) { return "Drain Adapter"; }
    function providerName() external pure override returns (string memory) { return "Drain"; }
    function adapterType() external pure override returns (string memory) { return "Test"; }
    function riskLevel() external pure override returns (uint8) { return 1; }
    function estimatedAPY() external pure override returns (uint256) { return 0; }
    function requiredLockPeriod() external pure override returns (uint256) { return 0; }
    function isActive() external pure override returns (bool) { return true; }
    function pause() external override { emit Paused(); }
    function unpause() external override { emit Unpaused(); }
}
