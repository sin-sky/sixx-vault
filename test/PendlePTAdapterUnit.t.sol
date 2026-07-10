// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PendlePTAdapter} from "../src/adapters/PendlePTAdapter.sol";
import {IStableSwapper} from "../src/interfaces/IStableSwapper.sol";
import {
    IPendleRouter,
    TokenInput,
    TokenOutput,
    ApproxParams,
    LimitOrderData
} from "../src/interfaces/IPendleRouter.sol";
import {MockUSDC} from "./SIXXVault.t.sol";

/// @title PendlePTAdapterUnitTest
/// @notice Pure-mock (no fork) unit suite for PendlePTAdapter. The fork suite
///         (PendlePTAdapterFork) proves the economics against the REAL Pendle
///         router + PT TWAP oracle; this suite proves the branches fork cannot
///         reach deterministically: every constructor validation revert, the
///         full admin / M-4 rotation / rescue / pause surface, TWAP-cap
///         accounting, estimatedAPY math, and pre/post-maturity exit routing.
///
///         All Pendle infra (market / PT / SY / oracle / router) and the injected
///         stablecoin swapper are mocked. The test contract plays the vault.
///
/// Run:  forge test --match-contract PendlePTAdapterUnitTest -vvv   (no fork)
contract PendlePTAdapterUnitTest is Test {
    using SafeERC20 for IERC20;

    address governance = makeAddr("governance");
    address stranger   = makeAddr("stranger");
    address recipient  = makeAddr("recipient");

    uint32  constant TWAP    = 900;
    uint256 constant PT_RATE = 0.95e18;   // PT->USDe TWAP (discount), <1e18 pre-maturity
    uint256 constant PERSHARE = 1.1e18;   // USDe per 1 sUSDe (convertToAssets(1e18))

    MockUSDC          usdc;
    MockToken18       usde;
    MockSUSDe         susde;
    MockPT            pt;
    MockPendleSY      sy;
    MockPendleMarket  market;
    MockPtOracle      oracle;
    MockPendleRouter  router;
    MockPBSwapper     swapper;
    PendlePTAdapter   adapter;

    uint256 expiryTs; // block.timestamp + 30d at construction

    function setUp() public {
        _deployGraph();
        adapter = new PendlePTAdapter(
            address(usdc), address(market), address(router), address(oracle),
            address(swapper), TWAP, address(this), governance
        );
        // Approvals for the fully-wired mocks so the round trip can run.
        susde.mint(address(router), 5_000_000e18);   // router pays sUSDe on exit
        usde.mint(address(swapper), 5_000_000e18);
        usdc.mint(address(swapper), 5_000_000e6);
        susde.mint(address(swapper), 5_000_000e18);
    }

    /// @dev Build the mock Pendle graph (not the adapter). Reused by revert tests
    ///      that need to poison one input, so tokens/market are rebuildable.
    function _deployGraph() internal {
        usdc  = new MockUSDC();
        usde  = new MockToken18("USDe", "USDe");
        susde = new MockSUSDe(PERSHARE);
        pt    = new MockPT();
        sy    = new MockPendleSY(address(susde), address(usde));
        yt_   = makeAddr("YT");
        expiryTs = block.timestamp + 30 days;
        pt.init(address(sy), yt_, expiryTs);
        market = new MockPendleMarket(address(sy), address(pt), yt_, expiryTs);
        oracle = new MockPtOracle(PT_RATE);
        router = new MockPendleRouter(address(pt), address(usde), address(susde), address(oracle));
        swapper = new MockPBSwapper(address(usdc), address(usde), address(susde));
    }

    address yt_;

    /// @dev Emulate the vault push: mint USDC to the adapter, then deposit as vault.
    function _deposit(uint256 amt) internal {
        usdc.mint(address(adapter), amt);
        adapter.deposit(amt);
    }

    // ─────────────────────────────────────────────────────────────
    // Constructor: zero-address / zero-arg guards
    // ─────────────────────────────────────────────────────────────

    function _construct(
        address asset_, address market_, address router_, address oracle_,
        address swapper_, uint32 twap_, address vault_, address gov_
    ) internal returns (PendlePTAdapter) {
        return new PendlePTAdapter(asset_, market_, router_, oracle_, swapper_, twap_, vault_, gov_);
    }

    function test_ctor_zeroAsset_reverts() public {
        vm.expectRevert(bytes("ADAPTER: zero asset"));
        _construct(address(0), address(market), address(router), address(oracle), address(swapper), TWAP, address(this), governance);
    }

    function test_ctor_zeroMarket_reverts() public {
        vm.expectRevert(bytes("ADAPTER: zero market"));
        _construct(address(usdc), address(0), address(router), address(oracle), address(swapper), TWAP, address(this), governance);
    }

    function test_ctor_zeroRouter_reverts() public {
        vm.expectRevert(bytes("ADAPTER: zero router"));
        _construct(address(usdc), address(market), address(0), address(oracle), address(swapper), TWAP, address(this), governance);
    }

    function test_ctor_zeroOracle_reverts() public {
        vm.expectRevert(bytes("ADAPTER: zero oracle"));
        _construct(address(usdc), address(market), address(router), address(0), address(swapper), TWAP, address(this), governance);
    }

    function test_ctor_zeroSwapper_reverts() public {
        vm.expectRevert(bytes("ADAPTER: zero swapper"));
        _construct(address(usdc), address(market), address(router), address(oracle), address(0), TWAP, address(this), governance);
    }

    function test_ctor_zeroTwap_reverts() public {
        vm.expectRevert(bytes("ADAPTER: zero twap"));
        _construct(address(usdc), address(market), address(router), address(oracle), address(swapper), 0, address(this), governance);
    }

    function test_ctor_zeroVault_reverts() public {
        vm.expectRevert(bytes("ADAPTER: zero vault"));
        _construct(address(usdc), address(market), address(router), address(oracle), address(swapper), TWAP, address(0), governance);
    }

    function test_ctor_zeroGovernance_reverts() public {
        vm.expectRevert(bytes("ADAPTER: zero governance"));
        _construct(address(usdc), address(market), address(router), address(oracle), address(swapper), TWAP, address(this), address(0));
    }

    // ─────────────────────────────────────────────────────────────
    // Constructor: on-chain cross-validation (_resolveAndValidate)
    // ─────────────────────────────────────────────────────────────

    function test_ctor_badMarket_reverts() public {
        MockPendleMarket bad = new MockPendleMarket(address(0), address(pt), yt_, expiryTs);
        vm.expectRevert(bytes("ADAPTER: bad market"));
        _construct(address(usdc), address(bad), address(router), address(oracle), address(swapper), TWAP, address(this), governance);
    }

    function test_ctor_ptSyMismatch_reverts() public {
        MockPT badPt = new MockPT();
        badPt.init(makeAddr("otherSY"), yt_, expiryTs); // PT.SY() != market.sy
        MockPendleMarket m = new MockPendleMarket(address(sy), address(badPt), yt_, expiryTs);
        vm.expectRevert(bytes("ADAPTER: PT/SY mismatch"));
        _construct(address(usdc), address(m), address(router), address(oracle), address(swapper), TWAP, address(this), governance);
    }

    function test_ctor_ptYtMismatch_reverts() public {
        MockPT badPt = new MockPT();
        badPt.init(address(sy), makeAddr("otherYT"), expiryTs); // PT.YT() != market.yt
        MockPendleMarket m = new MockPendleMarket(address(sy), address(badPt), yt_, expiryTs);
        vm.expectRevert(bytes("ADAPTER: PT/YT mismatch"));
        _construct(address(usdc), address(m), address(router), address(oracle), address(swapper), TWAP, address(this), governance);
    }

    function test_ctor_expiryMismatch_reverts() public {
        MockPT badPt = new MockPT();
        badPt.init(address(sy), yt_, expiryTs + 1 days); // PT.expiry != market.expiry
        MockPendleMarket m = new MockPendleMarket(address(sy), address(badPt), yt_, expiryTs);
        vm.expectRevert(bytes("ADAPTER: expiry mismatch"));
        _construct(address(usdc), address(m), address(router), address(oracle), address(swapper), TWAP, address(this), governance);
    }

    function test_ctor_alreadyMatured_reverts() public {
        MockPT mPt = new MockPT();
        mPt.init(address(sy), yt_, block.timestamp); // expiry == now → not > now
        MockPendleMarket m = new MockPendleMarket(address(sy), address(mPt), yt_, block.timestamp);
        vm.expectRevert(bytes("ADAPTER: already matured"));
        _construct(address(usdc), address(m), address(router), address(oracle), address(swapper), TWAP, address(this), governance);
    }

    function test_ctor_badSY_reverts() public {
        MockPendleSY badSy = new MockPendleSY(address(0), address(usde)); // yieldToken == 0
        MockPT p = new MockPT();
        p.init(address(badSy), yt_, expiryTs);
        MockPendleMarket m = new MockPendleMarket(address(badSy), address(p), yt_, expiryTs);
        vm.expectRevert(bytes("ADAPTER: bad SY"));
        _construct(address(usdc), address(m), address(router), address(oracle), address(swapper), TWAP, address(this), governance);
    }

    function test_ctor_oracleNotReady_grow_reverts() public {
        oracle.setState(true, false); // increaseCardinalityRequired = true
        vm.expectRevert(bytes("ADAPTER: oracle not ready"));
        _construct(address(usdc), address(market), address(router), address(oracle), address(swapper), TWAP, address(this), governance);
    }

    function test_ctor_oracleNotReady_stale_reverts() public {
        oracle.setState(false, true); // oldestObservationSatisfied = false
        vm.expectRevert(bytes("ADAPTER: oracle not ready"));
        _construct(address(usdc), address(market), address(router), address(oracle), address(swapper), TWAP, address(this), governance);
    }

    function test_ctor_bindsState() public view {
        assertEq(adapter.asset(), address(usdc));
        assertEq(address(adapter.pt()), address(pt));
        assertEq(adapter.sy(), address(sy));
        assertEq(adapter.usde(), address(usde));
        assertEq(adapter.susde(), address(susde));
        assertEq(adapter.expiry(), expiryTs);
        assertEq(adapter.twapDuration(), TWAP);
        assertEq(adapter.slippageBps(), 50); // 0.5% default
        assertEq(address(adapter.swapper()), address(swapper));
    }

    // ─────────────────────────────────────────────────────────────
    // Metadata
    // ─────────────────────────────────────────────────────────────

    function test_metadata() public view {
        assertEq(adapter.riskLevel(), 4);
        assertEq(adapter.requiredLockPeriod(), 0);
        assertEq(adapter.name(), "SIXX Fixed Yield - Pendle PT-sUSDe");
        assertEq(adapter.providerName(), "Pendle (PT-sUSDe / Ethena)");
        assertEq(adapter.adapterType(), "DeFi");
        assertTrue(adapter.isActive());
        assertEq(
            adapter.description(),
            "principal held as sUSDe (Ethena synthetic USD); yield fixed ONLY if held to maturity, NOT principal-guaranteed; early exit at market price can be below deposit; depeg can reduce principal even at maturity"
        );
    }

    function test_estimatedAPY_matchesFormula() public view {
        // gainFrac = 1e18/rate*1e18 - 1e18 ; apy = gainFrac*yr*BPS/remaining/1e18
        uint256 gainFrac = (1e18 * 1e18) / PT_RATE - 1e18;
        uint256 remaining = expiryTs - block.timestamp;
        uint256 expected = (gainFrac * 365 days * 10_000) / remaining / 1e18;
        assertEq(adapter.estimatedAPY(), expected);
        assertGt(adapter.estimatedAPY(), 0);
    }

    function test_estimatedAPY_zero_atPar() public {
        oracle.setRate(1e18); // no discount → no gain to par
        assertEq(adapter.estimatedAPY(), 0);
    }

    function test_estimatedAPY_zero_afterMaturity() public {
        vm.warp(expiryTs + 1);
        assertEq(adapter.estimatedAPY(), 0);
    }

    function test_isActive_false_whenMatured() public {
        vm.warp(expiryTs);
        assertFalse(adapter.isActive());
    }

    // ─────────────────────────────────────────────────────────────
    // totalAssets accounting
    // ─────────────────────────────────────────────────────────────

    function test_totalAssets_zero_whenEmpty() public view {
        assertEq(adapter.totalAssets(), 0);
    }

    function test_totalAssets_idleOnly_whenNoPT() public {
        usdc.mint(address(adapter), 123e6); // idle dust, no PT
        assertEq(adapter.totalAssets(), 123e6);
    }

    function test_totalAssets_marksAtTWAP() public {
        _deposit(10_000e6);
        uint256 ptBal = pt.balanceOf(address(adapter));
        // TWAP-capped USDe mark, recall-haircut applied, then USDe(18)->USDC(6).
        uint256 usdeVal = (ptBal * PT_RATE) / 1e18;
        uint256 expected = (usdeVal * (10_000 - adapter.recallHaircutBps())) / 10_000 / 1e12;
        assertEq(adapter.totalAssets(), expected);
    }

    function test_totalAssets_cappedAtPar_whenTwapAbovePar() public {
        _deposit(10_000e6);
        uint256 ptBal = pt.balanceOf(address(adapter));
        oracle.setRate(1.2e18); // TWAP now above par → must clamp to 1e18
        uint256 usdeVal = (ptBal * 1e18) / 1e18;
        uint256 expectedPar = (usdeVal * (10_000 - adapter.recallHaircutBps())) / 10_000 / 1e12;
        assertEq(adapter.totalAssets(), expectedPar);
    }

    function test_totalAssets_addsIdleDust() public {
        _deposit(10_000e6);
        uint256 ptOnly = adapter.totalAssets();
        usdc.mint(address(adapter), 5e6);
        assertEq(adapter.totalAssets(), ptOnly + 5e6);
    }

    // ─────────────────────────────────────────────────────────────
    // deposit: guards + happy path
    // ─────────────────────────────────────────────────────────────

    function test_deposit_buysPT() public {
        _deposit(10_000e6);
        assertGt(pt.balanceOf(address(adapter)), 0);
        assertEq(usdc.balanceOf(address(adapter)), 0); // fully deployed
        assertEq(usde.balanceOf(address(adapter)), 0);
    }

    function test_deposit_onlyVault() public {
        usdc.mint(address(adapter), 1_000e6);
        vm.prank(stranger);
        vm.expectRevert(bytes("ADAPTER: only vault"));
        adapter.deposit(1_000e6);
    }

    function test_deposit_zero_reverts() public {
        vm.expectRevert(bytes("ADAPTER: zero amount"));
        adapter.deposit(0);
    }

    function test_deposit_afterMaturity_reverts() public {
        vm.warp(expiryTs);
        usdc.mint(address(adapter), 1_000e6);
        vm.expectRevert(bytes("ADAPTER: matured"));
        adapter.deposit(1_000e6);
    }

    function test_deposit_whenPaused_reverts() public {
        vm.prank(governance);
        adapter.pause();
        usdc.mint(address(adapter), 1_000e6);
        vm.expectRevert(bytes("ADAPTER: paused"));
        adapter.deposit(1_000e6);
    }

    // ─────────────────────────────────────────────────────────────
    // withdraw: idle-first, partial, full, post-maturity, guards
    // ─────────────────────────────────────────────────────────────

    function test_withdraw_zero_reverts() public {
        vm.expectRevert(bytes("ADAPTER: zero amount"));
        adapter.withdraw(0, recipient);
    }

    function test_withdraw_zeroRecipient_reverts() public {
        _deposit(10_000e6);
        vm.expectRevert(bytes("ADAPTER: zero recipient"));
        adapter.withdraw(1_000e6, address(0));
    }

    function test_withdraw_onlyVault() public {
        _deposit(10_000e6);
        vm.prank(stranger);
        vm.expectRevert(bytes("ADAPTER: only vault"));
        adapter.withdraw(1_000e6, recipient);
    }

    function test_withdraw_servesIdleFirst_noPTTouch() public {
        _deposit(10_000e6);
        uint256 ptBefore = pt.balanceOf(address(adapter));
        usdc.mint(address(adapter), 2_000e6); // idle covers the request
        uint256 got = adapter.withdraw(1_500e6, recipient);
        assertEq(got, 1_500e6);
        assertEq(usdc.balanceOf(recipient), 1_500e6);
        assertEq(pt.balanceOf(address(adapter)), ptBefore); // PT untouched
    }

    function test_withdraw_noPosition_reverts() public {
        // No PT, idle < request → "no position".
        usdc.mint(address(adapter), 100e6);
        vm.expectRevert(bytes("ADAPTER: no position"));
        adapter.withdraw(1_000e6, recipient);
    }

    function test_withdraw_partial_deliversAtLeastRequested() public {
        _deposit(50_000e6);
        uint256 want = 10_000e6;
        uint256 got = adapter.withdraw(want, recipient);
        assertGe(got, want);
        assertEq(usdc.balanceOf(recipient), got);
        assertGt(pt.balanceOf(address(adapter)), 0); // remainder stays invested
    }

    function test_withdraw_fullExit_drainsPT() public {
        _deposit(20_000e6);
        uint256 nav = adapter.totalAssets();
        uint256 got = adapter.withdraw(type(uint256).max, recipient);
        assertGe(got, nav); // realized ≥ reported (vault shortfall guard analogue)
        assertEq(pt.balanceOf(address(adapter)), 0);
    }

    function test_withdraw_postMaturity_redeemsAtPar() public {
        _deposit(20_000e6);
        uint256 ptBal = pt.balanceOf(address(adapter));
        vm.warp(expiryTs + 1);
        // Par mark == PT notional in USDC, recall-haircut applied (the sUSDe->USDC
        // exit leg still carries slippage post-maturity, so the haircut stays).
        uint256 expectedPar = (ptBal * (10_000 - adapter.recallHaircutBps())) / 10_000 / 1e12;
        assertEq(adapter.totalAssets(), expectedPar);
        uint256 got = adapter.withdraw(type(uint256).max, recipient);
        assertGt(got, (20_000e6 * 99) / 100); // ~principal at par (par swapper)
        assertEq(pt.balanceOf(address(adapter)), 0);
    }

    // ─────────────────────────────────────────────────────────────
    // harvest
    // ─────────────────────────────────────────────────────────────

    function test_harvest_noop_onlyVault() public {
        assertEq(adapter.harvest(), 0);
        vm.prank(stranger);
        vm.expectRevert(bytes("ADAPTER: only vault"));
        adapter.harvest();
    }

    // ─────────────────────────────────────────────────────────────
    // pause / unpause
    // ─────────────────────────────────────────────────────────────

    function test_pause_byGovernance_and_byVault() public {
        vm.prank(governance);
        adapter.pause();
        assertFalse(adapter.isActive());
        vm.prank(governance);
        adapter.unpause();
        assertTrue(adapter.isActive());
        // vault may also pause
        adapter.pause();
        assertFalse(adapter.isActive());
    }

    function test_pause_unauthorized_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("ADAPTER: unauthorized"));
        adapter.pause();
    }

    function test_unpause_onlyGovernance() public {
        vm.prank(governance);
        adapter.pause();
        vm.prank(stranger);
        vm.expectRevert(bytes("ADAPTER: only governance"));
        adapter.unpause();
    }

    function test_pause_doesNotBlockWithdraw() public {
        _deposit(10_000e6);
        vm.prank(governance);
        adapter.pause();
        uint256 got = adapter.withdraw(1_000e6, recipient); // exits still work
        assertGe(got, 1_000e6);
    }

    // ─────────────────────────────────────────────────────────────
    // setSlippageBps
    // ─────────────────────────────────────────────────────────────

    function test_setSlippage_updates() public {
        vm.prank(governance);
        adapter.setSlippageBps(120);
        assertEq(adapter.slippageBps(), 120);
    }

    function test_setSlippage_capEnforced() public {
        vm.prank(governance);
        vm.expectRevert(bytes("ADAPTER: slippage too high"));
        adapter.setSlippageBps(301); // > MAX_SLIPPAGE_BPS (300)
    }

    function test_setSlippage_onlyGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("ADAPTER: not governance"));
        adapter.setSlippageBps(10);
    }

    // ─────────────────────────────────────────────────────────────
    // setRecallHaircutBps + haircut/floor equality (escalate#1)
    // ─────────────────────────────────────────────────────────────

    function test_ctor_recallHaircutDefault() public view {
        assertEq(adapter.recallHaircutBps(), 50); // 0.5% default
    }

    function test_setRecallHaircut_updates() public {
        vm.prank(governance);
        adapter.setRecallHaircutBps(120);
        assertEq(adapter.recallHaircutBps(), 120);
    }

    function test_setRecallHaircut_capEnforced() public {
        vm.prank(governance);
        vm.expectRevert(bytes("ADAPTER: haircut too high"));
        adapter.setRecallHaircutBps(301); // > MAX_RECALL_HAIRCUT_BPS (300)
    }

    function test_setRecallHaircut_onlyGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("ADAPTER: not governance"));
        adapter.setRecallHaircutBps(10);
    }

    /// @dev A-parity core: a full exit realizes >= the reported NAV for a range of
    ///      haircuts, so the vault's `received >= toWithdraw` guard always holds.
    function test_withdraw_fullExit_realizesReportedNAV_acrossHaircuts() public {
        uint256[3] memory haircuts = [uint256(0), 50, 300];
        for (uint256 i = 0; i < haircuts.length; i++) {
            _deployGraph();
            adapter = new PendlePTAdapter(
                address(usdc), address(market), address(router), address(oracle),
                address(swapper), TWAP, address(this), governance
            );
            susde.mint(address(router), 5_000_000e18);
            usde.mint(address(swapper), 5_000_000e18);
            usdc.mint(address(swapper), 5_000_000e6);
            susde.mint(address(swapper), 5_000_000e18);
            vm.prank(governance);
            adapter.setRecallHaircutBps(haircuts[i]);

            _deposit(20_000e6);
            uint256 nav = adapter.totalAssets();
            uint256 got = adapter.withdraw(type(uint256).max, recipient);
            assertGe(got, nav, "full exit realized below reported NAV");
            assertEq(pt.balanceOf(address(adapter)), 0, "PT not drained");
        }
    }

    /// @dev Fail-close valve: if the exit route cannot realize the reported NAV
    ///      (haircut too tight for the actual slippage), the whole withdraw reverts
    ///      and no funds move — the vault guard is never silently shorted.
    function test_withdraw_fullExit_reverts_whenHaircutTooTight() public {
        _deposit(20_000e6);
        // 0 haircut => full-exit floor == un-haircut mark; a 1% swapper skim then
        // can't meet it.
        vm.prank(governance);
        adapter.setRecallHaircutBps(0);
        swapper.setHaircutBps(100); // 1%
        vm.expectRevert(bytes("MockPBSwapper: min out"));
        adapter.withdraw(type(uint256).max, recipient);
        // Position untouched (revert rolled back the burn).
        assertGt(pt.balanceOf(address(adapter)), 0, "position must survive a fail-close");
    }

    // ─────────────────────────────────────────────────────────────
    // setSwapper (approval flip)
    // ─────────────────────────────────────────────────────────────

    function test_setSwapper_flipsApprovals() public {
        MockPBSwapper newSwapper = new MockPBSwapper(address(usdc), address(usde), address(susde));
        vm.prank(governance);
        adapter.setSwapper(address(newSwapper));
        assertEq(address(adapter.swapper()), address(newSwapper));
        // old revoked, new granted
        assertEq(usdc.allowance(address(adapter), address(swapper)), 0);
        assertEq(susde.allowance(address(adapter), address(swapper)), 0);
        assertEq(usdc.allowance(address(adapter), address(newSwapper)), type(uint256).max);
        assertEq(susde.allowance(address(adapter), address(newSwapper)), type(uint256).max);
    }

    function test_setSwapper_zero_reverts() public {
        vm.prank(governance);
        vm.expectRevert(bytes("ADAPTER: zero swapper"));
        adapter.setSwapper(address(0));
    }

    function test_setSwapper_onlyGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("ADAPTER: not governance"));
        adapter.setSwapper(address(1));
    }

    // ─────────────────────────────────────────────────────────────
    // M-4 two-step rotations
    // ─────────────────────────────────────────────────────────────

    function test_vaultRotation_twoStep() public {
        address newVault = makeAddr("newVault");
        vm.prank(governance);
        adapter.proposeVault(newVault);
        assertEq(adapter.pendingVault(), newVault);
        vm.prank(newVault);
        adapter.acceptVault();
        assertEq(adapter.vault(), newVault);
        assertEq(adapter.pendingVault(), address(0));
    }

    function test_proposeVault_onlyGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("ADAPTER: not governance"));
        adapter.proposeVault(makeAddr("x"));
    }

    function test_acceptVault_onlyPending() public {
        vm.prank(governance);
        adapter.proposeVault(makeAddr("newVault"));
        vm.prank(stranger);
        vm.expectRevert(bytes("ADAPTER: not pending vault"));
        adapter.acceptVault();
    }

    function test_governanceRotation_twoStep() public {
        address newGov = makeAddr("newGov");
        vm.prank(governance);
        adapter.proposeGovernance(newGov);
        assertEq(adapter.pendingGovernance(), newGov);
        vm.prank(newGov);
        adapter.acceptGovernance();
        assertEq(adapter.governance(), newGov);
        assertEq(adapter.pendingGovernance(), address(0));
    }

    function test_proposeGovernance_onlyGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("ADAPTER: not governance"));
        adapter.proposeGovernance(makeAddr("x"));
    }

    function test_acceptGovernance_onlyPending() public {
        vm.prank(governance);
        adapter.proposeGovernance(makeAddr("newGov"));
        vm.prank(stranger);
        vm.expectRevert(bytes("ADAPTER: not pending governance"));
        adapter.acceptGovernance();
    }

    // ─────────────────────────────────────────────────────────────
    // rescueToken
    // ─────────────────────────────────────────────────────────────

    function test_rescue_sweepsStray() public {
        MockToken18 stray = new MockToken18("X", "X");
        stray.mint(address(adapter), 7e18);
        vm.prank(governance);
        uint256 amt = adapter.rescueToken(address(stray), recipient);
        assertEq(amt, 7e18);
        assertEq(stray.balanceOf(recipient), 7e18);
    }

    function test_rescue_cannotTakePosition() public {
        _deposit(10_000e6);
        vm.prank(governance);
        vm.expectRevert(bytes("ADAPTER: cannot rescue position"));
        adapter.rescueToken(address(pt), recipient);
    }

    function test_rescue_cannotTakePrincipal() public {
        vm.prank(governance);
        vm.expectRevert(bytes("ADAPTER: cannot rescue principal"));
        adapter.rescueToken(address(usdc), recipient);
    }

    function test_rescue_zeroRecipient_reverts() public {
        vm.prank(governance);
        vm.expectRevert(bytes("ADAPTER: zero recipient"));
        adapter.rescueToken(address(usde), address(0));
    }

    function test_rescue_onlyGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("ADAPTER: not governance"));
        adapter.rescueToken(address(usde), recipient);
    }
}

// ═════════════════════════════════════════════════════════════════
// Mocks
// ═════════════════════════════════════════════════════════════════

/// @dev Generic 18-decimal ERC20 (USDe, stray token).
contract MockToken18 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

/// @dev StakedUSDeV2-ish: an ERC20 exposing convertToAssets (USDe per sUSDe).
///      `perShare` = convertToAssets(1e18). Openly mintable for the router/swapper.
contract MockSUSDe is ERC20 {
    uint256 public perShare;
    constructor(uint256 perShare_) ERC20("Staked USDe", "sUSDe") { perShare = perShare_; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
    function convertToAssets(uint256 shares) external view returns (uint256) {
        return (shares * perShare) / 1e18;
    }
}

/// @dev Pendle Principal Token: ERC20 + SY/YT/expiry views. Openly mintable so the
///      mock router can create PT on buy.
contract MockPT is ERC20 {
    address private _sy;
    address private _yt;
    uint256 private _expiry;
    constructor() ERC20("PT-sUSDe", "PT") {}
    function init(address sy_, address yt_, uint256 expiry_) external { _sy = sy_; _yt = yt_; _expiry = expiry_; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
    function burn(address from, uint256 amt) external { _burn(from, amt); }
    function SY() external view returns (address) { return _sy; }
    function YT() external view returns (address) { return _yt; }
    function expiry() external view returns (uint256) { return _expiry; }
    function isExpired() external view returns (bool) { return block.timestamp >= _expiry; }
}

/// @dev Pendle SY: yieldToken() = sUSDe, assetInfo() = (TOKEN, USDe, 18).
contract MockPendleSY {
    address public immutable yt_token; // sUSDe
    address public immutable usdeAddr;
    constructor(address susde_, address usde_) { yt_token = susde_; usdeAddr = usde_; }
    function yieldToken() external view returns (address) { return yt_token; }
    function assetInfo() external view returns (uint8, address, uint8) { return (0, usdeAddr, 18); }
    function getTokensIn() external view returns (address[] memory a) {
        a = new address[](2); a[0] = usdeAddr; a[1] = yt_token;
    }
    function getTokensOut() external view returns (address[] memory a) {
        a = new address[](1); a[0] = yt_token;
    }
}

/// @dev Pendle market: readTokens() + expiry().
contract MockPendleMarket {
    address private _sy;
    address private _pt;
    address private _yt;
    uint256 private _expiry;
    constructor(address sy_, address pt_, address yt_, uint256 expiry_) { _sy = sy_; _pt = pt_; _yt = yt_; _expiry = expiry_; }
    function readTokens() external view returns (address, address, address) { return (_sy, _pt, _yt); }
    function expiry() external view returns (uint256) { return _expiry; }
    function isExpired() external view returns (bool) { return block.timestamp >= _expiry; }
}

/// @dev Pendle PT TWAP oracle. `rate` = PtToAssetRate (1e18 = par). Oracle-state
///      knobs let constructor "not ready" paths be exercised.
contract MockPtOracle {
    uint256 public rate;
    bool public grow;       // increaseCardinalityRequired
    bool public stale;      // !oldestObservationSatisfied
    constructor(uint256 rate_) { rate = rate_; }
    function setRate(uint256 r) external { rate = r; }
    function setState(bool grow_, bool stale_) external { grow = grow_; stale = stale_; }
    function getPtToAssetRate(address, uint32) external view returns (uint256) { return rate; }
    function getOracleState(address, uint32) external view returns (bool, uint16, bool) {
        return (grow, 83, !stale);
    }
}

/// @dev Pendle Router V4 mock. Uses the oracle rate (capped at par, mirroring the
///      adapter) for PT<->USDe and the sUSDe convertToAssets rate for USDe<->sUSDe,
///      so realized amounts line up with the adapter's min-out sizing.
contract MockPendleRouter is IPendleRouter {
    using SafeERC20 for IERC20;
    MockPT   public immutable pt;
    IERC20   public immutable usde;
    MockSUSDe public immutable susde;
    MockPtOracle public immutable oracle;

    constructor(address pt_, address usde_, address susde_, address oracle_) {
        pt = MockPT(pt_);
        usde = IERC20(usde_);
        susde = MockSUSDe(susde_);
        oracle = MockPtOracle(oracle_);
    }

    function _rateCapped() internal view returns (uint256 r) {
        r = oracle.rate();
        if (r > 1e18) r = 1e18;
    }

    function swapExactTokenForPt(
        address receiver,
        address,
        uint256 minPtOut,
        ApproxParams calldata,
        TokenInput calldata input,
        LimitOrderData calldata
    ) external payable returns (uint256 netPtOut, uint256, uint256) {
        usde.safeTransferFrom(msg.sender, address(this), input.netTokenIn);
        netPtOut = (input.netTokenIn * 1e18) / _rateCapped(); // USDe -> PT at (capped) rate
        require(netPtOut >= minPtOut, "MockRouter: min PT");
        pt.mint(receiver, netPtOut);
    }

    function swapExactPtForToken(
        address receiver,
        address,
        uint256 exactPtIn,
        TokenOutput calldata output,
        LimitOrderData calldata
    ) external returns (uint256 netTokenOut, uint256, uint256) {
        pt.burn(msg.sender, exactPtIn);
        uint256 usdeVal = (exactPtIn * _rateCapped()) / 1e18;      // PT -> USDe (market)
        netTokenOut = (usdeVal * 1e18) / susde.perShare();        // USDe -> sUSDe
        require(netTokenOut >= output.minTokenOut, "MockRouter: min out");
        IERC20(address(susde)).safeTransfer(receiver, netTokenOut);
    }

    function redeemPyToToken(
        address receiver,
        address,
        uint256 netPyIn,
        TokenOutput calldata output
    ) external returns (uint256 netTokenOut, uint256) {
        pt.burn(msg.sender, netPyIn);
        uint256 usdeVal = netPyIn;                                 // par redemption
        netTokenOut = (usdeVal * 1e18) / susde.perShare();
        require(netTokenOut >= output.minTokenOut, "MockRouter: min out");
        IERC20(address(susde)).safeTransfer(receiver, netTokenOut);
    }
}

/// @dev Par stablecoin swapper over the mock token set (USDC/USDe/sUSDe), paying
///      from pre-funded balances. Optional haircut simulates slippage.
contract MockPBSwapper is IStableSwapper {
    using SafeERC20 for IERC20;
    address public immutable usdc;
    address public immutable usde;
    address public immutable susde;
    uint256 public haircutBps;

    constructor(address usdc_, address usde_, address susde_) { usdc = usdc_; usde = usde_; susde = susde_; }
    function setHaircutBps(uint256 bps) external { haircutBps = bps; }

    function _rawOut(address tokenIn, address tokenOut, uint256 amountIn) internal view returns (uint256) {
        if (tokenIn == usdc && tokenOut == usde)  return amountIn * 1e12;   // 6 -> 18, par
        if (tokenIn == usde && tokenOut == usdc)  return amountIn / 1e12;   // 18 -> 6, par
        if (tokenIn == susde && tokenOut == usdc) {
            uint256 u = MockSUSDe(susde).convertToAssets(amountIn);         // sUSDe -> USDe
            return u / 1e12;                                                // -> USDC
        }
        revert("MockPBSwapper: pair");
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address to)
        external returns (uint256 amountOut)
    {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        amountOut = _rawOut(tokenIn, tokenOut, amountIn) * (10_000 - haircutBps) / 10_000;
        require(amountOut >= minOut, "MockPBSwapper: min out");
        IERC20(tokenOut).safeTransfer(to, amountOut);
    }
}
