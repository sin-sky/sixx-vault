// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {VenusUSDTAdapter} from "../src/adapters/VenusUSDTAdapter.sol";
import {IVenusVToken} from "../src/interfaces/IVenusVToken.sol";
import {IStrategyAdapter} from "../src/interfaces/IStrategyAdapter.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ════════════════════════════════════════════════════════════════════════
// Mocks (BSC-flavoured: USDT on BNB Chain is 18 decimals, not 6)
// ════════════════════════════════════════════════════════════════════════

/// @dev Minimal 18-decimal mock for BSC USDT (no fork needed).
contract MockUSDT is ERC20 {
    constructor() ERC20("Tether USD", "USDT") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 18; }
}

/// @title MockVUSDT
/// @notice Faithful in-memory model of a Venus / Compound-v2 vToken.
/// @dev Compound semantics modelled here:
///      - mint() pulls `underlying` via transferFrom and credits vTokens =
///        mintAmount * 1e18 / exchangeRate.
///      - redeemUnderlying() burns the matching vTokens (rounded up) and sends
///        `redeemAmount` underlying back to msg.sender.
///      - every state-changing call returns a Compound error code: 0 = success.
///      - underlying value of a held balance grows by raising `exchangeRate`.
contract MockVUSDT is IVenusVToken {
    address private immutable _underlying;
    uint256 public exchangeRate;   // mantissa 1e18 (underlying = vBal * rate / 1e18)
    uint256 public supplyRate;     // per-block, scaled 1e18

    mapping(address => uint256) private _vBal;

    // Failure-injection switches for the error-path tests
    bool public mintShouldFail;
    bool public redeemShouldFail;
    bool public supplyRateReverts;
    /// @dev B-2: fraction of a redeemUnderlying request actually DELIVERED while still
    ///      returning success (0). Models a forked/upgraded vToken whose return code lies
    ///      about the delivered amount. Default 100% = honest.
    uint256 public deliverBps = 10_000;

    constructor(address underlying_, uint256 initialRate) {
        _underlying = underlying_;
        exchangeRate = initialRate;
    }

    function underlying() external view returns (address) { return _underlying; }
    function exchangeRateStored() external view returns (uint256) { return exchangeRate; }
    function balanceOf(address account) external view returns (uint256) { return _vBal[account]; }

    function supplyRatePerBlock() external view returns (uint256) {
        require(!supplyRateReverts, "MOCK: rate unavailable");
        return supplyRate;
    }

    function mint(uint256 mintAmount) external returns (uint256) {
        if (mintShouldFail) return 1; // non-zero Compound error code
        IERC20(_underlying).transferFrom(msg.sender, address(this), mintAmount);
        _vBal[msg.sender] += (mintAmount * 1e18) / exchangeRate;
        return 0;
    }

    function redeemUnderlying(uint256 redeemAmount) external returns (uint256) {
        if (redeemShouldFail) return 1;
        uint256 vBurn = (redeemAmount * 1e18 + exchangeRate - 1) / exchangeRate; // round up
        if (vBurn > _vBal[msg.sender]) return 9; // COMPTROLLER_REJECTION-ish
        _vBal[msg.sender] -= vBurn;
        IERC20(_underlying).transfer(msg.sender, (redeemAmount * deliverBps) / 10_000);
        return 0;
    }

    function redeem(uint256 redeemTokens) external returns (uint256) {
        if (redeemShouldFail) return 1;
        if (redeemTokens > _vBal[msg.sender]) return 9;
        _vBal[msg.sender] -= redeemTokens;
        IERC20(_underlying).transfer(msg.sender, (redeemTokens * exchangeRate) / 1e18);
        return 0;
    }

    // ── test helpers ──────────────────────────────────────────
    function setDeliverBps(uint256 b) external { deliverBps = b; }
    function setExchangeRate(uint256 r) external { exchangeRate = r; }
    function setSupplyRate(uint256 r) external { supplyRate = r; }
    function setMintShouldFail(bool f) external { mintShouldFail = f; }
    function setRedeemShouldFail(bool f) external { redeemShouldFail = f; }
    function setSupplyRateReverts(bool f) external { supplyRateReverts = f; }
}

/// @dev A vToken whose underlying() reports a different asset — for the
///      constructor mismatch guard.
contract MockVUSDTWrongUnderlying is MockVUSDT {
    address private immutable _wrong;
    constructor(address wrong_) MockVUSDT(wrong_, 2e17) { _wrong = wrong_; }
}

// ════════════════════════════════════════════════════════════════════════
// Unit suite — adapter logic against the mock vToken (no fork / no RPC)
// ════════════════════════════════════════════════════════════════════════

contract VenusUSDTAdapterTest is Test {
    MockUSDT  usdt;
    MockVUSDT vusdt;
    VenusUSDTAdapter adapter;

    address governance = makeAddr("governance");
    address vault      = makeAddr("vault");
    address alice      = makeAddr("alice");

    // 0.2 exchange rate (Compound-style sub-1e18 mantissa) exercises the
    // vToken<->underlying conversion rather than a trivial 1:1.
    uint256 constant RATE = 2e17;
    uint256 constant DEPOSIT = 1_000e18; // 1,000 USDT (18 decimals on BSC)

    event Deposited(uint256 assets, uint256 deposited);
    event Withdrawn(uint256 assets, uint256 withdrawn, address indexed recipient);
    event Harvested(uint256 harvested);
    event Paused();
    event Unpaused();

    function setUp() public {
        usdt  = new MockUSDT();
        vusdt = new MockVUSDT(address(usdt), RATE);
        adapter = new VenusUSDTAdapter(address(usdt), address(vusdt), vault, governance);
    }

    /// @dev Emulate the vault's flow: tokens land on the adapter, then the
    ///      vault calls deposit().
    function _fundAndDeposit(uint256 amount) internal {
        usdt.mint(address(adapter), amount);
        vm.prank(vault);
        adapter.deposit(amount);
    }

    // ── constructor ───────────────────────────────────────────

    function test_constructor_setsState() public view {
        assertEq(adapter.asset(), address(usdt));
        assertEq(address(adapter.vault()), vault);
        assertEq(adapter.governance(), governance);
        assertEq(address(adapter.vToken()), address(vusdt));
        // infinite approval granted to the vToken so mint() can pull USDT
        assertEq(usdt.allowance(address(adapter), address(vusdt)), type(uint256).max);
    }

    function test_constructor_revertsZeroAsset() public {
        vm.expectRevert("ADAPTER: zero asset");
        new VenusUSDTAdapter(address(0), address(vusdt), vault, governance);
    }

    function test_constructor_revertsZeroVToken() public {
        vm.expectRevert("ADAPTER: zero vToken");
        new VenusUSDTAdapter(address(usdt), address(0), vault, governance);
    }

    function test_constructor_revertsZeroVault() public {
        vm.expectRevert("ADAPTER: zero vault");
        new VenusUSDTAdapter(address(usdt), address(vusdt), address(0), governance);
    }

    function test_constructor_revertsZeroGovernance() public {
        vm.expectRevert("ADAPTER: zero governance");
        new VenusUSDTAdapter(address(usdt), address(vusdt), vault, address(0));
    }

    function test_constructor_revertsUnderlyingMismatch() public {
        MockUSDT other = new MockUSDT();
        MockVUSDTWrongUnderlying wrong = new MockVUSDTWrongUnderlying(address(other));
        vm.expectRevert("ADAPTER: vToken/asset mismatch");
        new VenusUSDTAdapter(address(usdt), address(wrong), vault, governance);
    }

    // ── deposit ───────────────────────────────────────────────

    function test_deposit_mintsVTokensAndReportsAssets() public {
        usdt.mint(address(adapter), DEPOSIT);

        vm.expectEmit(false, false, false, true, address(adapter));
        emit Deposited(DEPOSIT, DEPOSIT);

        vm.prank(vault);
        uint256 deposited = adapter.deposit(DEPOSIT);

        assertEq(deposited, DEPOSIT, "returns deposited amount");
        // vTokens minted = DEPOSIT * 1e18 / RATE
        assertEq(vusdt.balanceOf(address(adapter)), (DEPOSIT * 1e18) / RATE, "vToken minted");
        // underlying value round-trips back to the deposit
        assertEq(adapter.totalAssets(), DEPOSIT, "totalAssets == deposit");
        // adapter forwarded all USDT to the vToken
        assertEq(usdt.balanceOf(address(adapter)), 0, "adapter holds no idle USDT");
    }

    function test_deposit_onlyVault() public {
        usdt.mint(address(adapter), DEPOSIT);
        vm.prank(alice);
        vm.expectRevert("ADAPTER: only vault");
        adapter.deposit(DEPOSIT);
    }

    function test_deposit_revertsZeroAmount() public {
        vm.prank(vault);
        vm.expectRevert("ADAPTER: zero amount");
        adapter.deposit(0);
    }

    function test_deposit_revertsWhenPaused() public {
        vm.prank(governance);
        adapter.pause();
        usdt.mint(address(adapter), DEPOSIT);
        vm.prank(vault);
        vm.expectRevert("ADAPTER: paused");
        adapter.deposit(DEPOSIT);
    }

    function test_deposit_revertsOnMintFailure() public {
        vusdt.setMintShouldFail(true);
        usdt.mint(address(adapter), DEPOSIT);
        vm.prank(vault);
        vm.expectRevert("ADAPTER: mint failed");
        adapter.deposit(DEPOSIT);
    }

    // ── withdraw ──────────────────────────────────────────────

    function test_withdraw_redeemsAndForwardsToRecipient() public {
        _fundAndDeposit(DEPOSIT);

        vm.expectEmit(true, false, false, true, address(adapter));
        emit Withdrawn(DEPOSIT, DEPOSIT, alice);

        vm.prank(vault);
        uint256 withdrawn = adapter.withdraw(DEPOSIT, alice);

        assertEq(withdrawn, DEPOSIT, "returns withdrawn amount");
        assertEq(usdt.balanceOf(alice), DEPOSIT, "recipient received underlying");
        assertApproxEqAbs(adapter.totalAssets(), 0, 1, "adapter drained");
    }

    function test_withdraw_onlyVault() public {
        _fundAndDeposit(DEPOSIT);
        vm.prank(alice);
        vm.expectRevert("ADAPTER: only vault");
        adapter.withdraw(DEPOSIT, alice);
    }

    function test_withdraw_revertsZeroAmount() public {
        vm.prank(vault);
        vm.expectRevert("ADAPTER: zero amount");
        adapter.withdraw(0, alice);
    }

    function test_withdraw_revertsZeroRecipient() public {
        _fundAndDeposit(DEPOSIT);
        vm.prank(vault);
        vm.expectRevert("ADAPTER: zero recipient");
        adapter.withdraw(DEPOSIT, address(0));
    }

    function test_withdraw_revertsOnRedeemFailure() public {
        _fundAndDeposit(DEPOSIT);
        vusdt.setRedeemShouldFail(true);
        vm.prank(vault);
        vm.expectRevert("ADAPTER: redeem failed");
        adapter.withdraw(DEPOSIT, alice);
    }

    /// @dev Partial withdraw (< totalAssets) uses redeemUnderlying and leaves the
    ///      remaining position invested.
    function test_withdraw_partial_keepsRemainderInvested() public {
        _fundAndDeposit(DEPOSIT);
        uint256 part = DEPOSIT / 4;

        vm.prank(vault);
        uint256 withdrawn = adapter.withdraw(part, alice);

        assertEq(withdrawn, part, "exact partial amount");
        assertEq(usdt.balanceOf(alice), part, "recipient got the partial amount");
        assertApproxEqAbs(adapter.totalAssets(), DEPOSIT - part, 1, "remainder stays invested");
        assertGt(vusdt.balanceOf(address(adapter)), 0, "still holds vUSDT");
    }

    /// @dev B-2 (Round 8): the partial withdraw path reports the REAL USDT balance delta,
    ///      not the assumed input. If a (forked/upgraded) vToken returns success while
    ///      delivering less than requested, `withdrawn = assets` would have safeTransfer'd
    ///      USDT the adapter does not hold and reverted (DoS). Measuring the delta lets the
    ///      call report exactly what was received and forward it — symmetric with drain-all.
    function test_B2_partialWithdraw_reportsRealDelta_notAssumedInput() public {
        _fundAndDeposit(DEPOSIT);
        vusdt.setDeliverBps(9_000); // vToken delivers only 90% of the request, returns 0

        uint256 part = DEPOSIT / 4;
        uint256 expected = (part * 9_000) / 10_000;

        vm.prank(vault);
        uint256 withdrawn = adapter.withdraw(part, alice);

        assertEq(withdrawn, expected, "must report the actual delivered delta, not the input");
        assertEq(usdt.balanceOf(alice), expected, "recipient receives exactly the delivered delta");
    }

    /// @dev Drain-all withdraw (>= totalAssets) redeems the entire vToken balance,
    ///      leaving zero vUSDT — the fix that prevents dust accumulation.
    function test_withdraw_drainAll_leavesNoVTokenDust() public {
        _fundAndDeposit(DEPOSIT);
        assertGt(vusdt.balanceOf(address(adapter)), 0, "holds vUSDT before");

        vm.prank(vault);
        adapter.withdraw(DEPOSIT, alice);

        assertEq(vusdt.balanceOf(address(adapter)), 0, "drained to zero vUSDT");
        assertEq(adapter.totalAssets(), 0, "no residual assets");
    }

    /// @dev Withdrawals must keep working while the adapter is paused
    ///      (pause only blocks *new* deposits — exits are never trapped).
    function test_withdraw_allowedWhilePaused() public {
        _fundAndDeposit(DEPOSIT);
        vm.prank(governance);
        adapter.pause();
        vm.prank(vault);
        uint256 withdrawn = adapter.withdraw(DEPOSIT, alice);
        assertEq(withdrawn, DEPOSIT);
        assertEq(usdt.balanceOf(alice), DEPOSIT);
    }

    // ── totalAssets / yield ───────────────────────────────────

    function test_totalAssets_growsWithExchangeRate() public {
        _fundAndDeposit(DEPOSIT);
        assertEq(adapter.totalAssets(), DEPOSIT);

        // +5% exchange rate = +5% underlying value of the held vTokens.
        vusdt.setExchangeRate((RATE * 105) / 100);
        // fund the mock so the gain is actually redeemable
        usdt.mint(address(vusdt), DEPOSIT / 20);

        assertEq(adapter.totalAssets(), (DEPOSIT * 105) / 100, "value tracks exchangeRate");
    }

    function test_totalAssets_zeroBeforeDeposit() public view {
        assertEq(adapter.totalAssets(), 0);
    }

    // ── harvest (no-op for auto-compounding vToken) ───────────

    function test_harvest_isNoOp() public {
        _fundAndDeposit(DEPOSIT);
        vm.expectEmit(false, false, false, true, address(adapter));
        emit Harvested(0);
        vm.prank(vault);
        uint256 harvested = adapter.harvest();
        assertEq(harvested, 0, "harvest returns 0");
        assertEq(adapter.totalAssets(), DEPOSIT, "harvest does not change assets");
    }

    // ── estimatedAPY ──────────────────────────────────────────

    function test_estimatedAPY_fromSupplyRate() public {
        // APY_bps = rate * BLOCKS_PER_YEAR / 1e14
        // rate 1e10 → 1e10 * 10_512_000 / 1e14 = 1051 bps (10.51%)
        vusdt.setSupplyRate(1e10);
        assertEq(adapter.estimatedAPY(), 1051);
    }

    function test_estimatedAPY_zeroWhenRateZero() public {
        vusdt.setSupplyRate(0);
        assertEq(adapter.estimatedAPY(), 0);
    }

    function test_estimatedAPY_catchesRevertReturningZero() public {
        vusdt.setSupplyRateReverts(true);
        assertEq(adapter.estimatedAPY(), 0, "try/catch returns 0 on rate failure");
    }

    // ── metadata ──────────────────────────────────────────────

    function test_metadata() public view {
        assertEq(adapter.name(), "SIXX Stable Yield - Venus USDT");
        assertEq(adapter.providerName(), "Venus Protocol");
        assertEq(adapter.adapterType(), "DeFi");
        assertEq(adapter.riskLevel(), 3);
        assertEq(adapter.requiredLockPeriod(), 0);
        assertTrue(adapter.isActive());
    }

    // ── circuit breaker ───────────────────────────────────────

    function test_pause_byGovernance() public {
        vm.prank(governance);
        adapter.pause();
        assertFalse(adapter.isActive());
    }

    function test_pause_byVault() public {
        vm.prank(vault);
        adapter.pause();
        assertFalse(adapter.isActive());
    }

    function test_pause_unauthorizedReverts() public {
        vm.prank(alice);
        vm.expectRevert("ADAPTER: unauthorized");
        adapter.pause();
    }

    function test_unpause_onlyGovernance() public {
        vm.prank(governance);
        adapter.pause();

        // vault may pause but may NOT unpause
        vm.prank(vault);
        vm.expectRevert("ADAPTER: only governance");
        adapter.unpause();

        vm.prank(governance);
        adapter.unpause();
        assertTrue(adapter.isActive());
    }

    // ── 2-step vault rotation (M-4) ───────────────────────────

    function test_vaultRotation_twoStep() public {
        address newVault = makeAddr("newVault");

        vm.prank(governance);
        adapter.proposeVault(newVault);
        assertEq(adapter.pendingVault(), newVault);
        assertEq(address(adapter.vault()), vault, "vault unchanged until accept");

        vm.prank(newVault);
        adapter.acceptVault();
        assertEq(address(adapter.vault()), newVault);
        assertEq(adapter.pendingVault(), address(0));
    }

    function test_proposeVault_onlyGovernance() public {
        vm.prank(alice);
        vm.expectRevert("ADAPTER: not governance");
        adapter.proposeVault(makeAddr("x"));
    }

    function test_proposeVault_rejectsZero() public {
        vm.prank(governance);
        vm.expectRevert("ADAPTER: zero vault");
        adapter.proposeVault(address(0));
    }

    function test_acceptVault_onlyPending() public {
        vm.prank(governance);
        adapter.proposeVault(makeAddr("newVault"));
        vm.prank(alice);
        vm.expectRevert("ADAPTER: not pending vault");
        adapter.acceptVault();
    }

    // ── 2-step governance rotation (M-4) ──────────────────────

    function test_governanceRotation_twoStep() public {
        address newGov = makeAddr("newGov");

        vm.prank(governance);
        adapter.proposeGovernance(newGov);
        assertEq(adapter.pendingGovernance(), newGov);
        assertEq(adapter.governance(), governance, "unchanged until accept");

        vm.prank(newGov);
        adapter.acceptGovernance();
        assertEq(adapter.governance(), newGov);
        assertEq(adapter.pendingGovernance(), address(0));
    }

    function test_proposeGovernance_onlyGovernance() public {
        vm.prank(alice);
        vm.expectRevert("ADAPTER: not governance");
        adapter.proposeGovernance(makeAddr("x"));
    }

    function test_proposeGovernance_rejectsZero() public {
        vm.prank(governance);
        vm.expectRevert("ADAPTER: zero address");
        adapter.proposeGovernance(address(0));
    }

    function test_acceptGovernance_onlyPending() public {
        vm.prank(governance);
        adapter.proposeGovernance(makeAddr("newGov"));
        vm.prank(alice);
        vm.expectRevert("ADAPTER: not pending governance");
        adapter.acceptGovernance();
    }
}

// ════════════════════════════════════════════════════════════════════════
// Fork suite — live Venus on BNB Chain (mainnet)
//
// Run:
//   forge test --fork-url $BNB_RPC_URL --match-contract VenusUSDTAdapterForkTest -vvv
// Pin a block for reproducibility:
//   forge test --fork-url $BNB_RPC_URL --fork-block-number <n> \
//     --match-contract VenusUSDTAdapterForkTest -vvv
//
// NOTE: BSC USDT is 18 decimals. Addresses are BNB mainnet Venus core-pool.
//       Verify against https://docs.venus.io before trusting a green run.
// ════════════════════════════════════════════════════════════════════════

interface IVTokenAccrue {
    function accrueInterest() external returns (uint256);
}

contract VenusUSDTAdapterForkTest is Test {
    // ─── BNB Chain (mainnet) addresses ────────────────────────
    address constant USDT  = 0x55d398326f99059fF775485246999027B3197955; // 18 decimals
    address constant VUSDT = 0xfD5840Cd36d94D7229439859C0112a4185BC0255; // Venus vUSDT (core pool)

    // ─── Actors ───────────────────────────────────────────────
    address governance = makeAddr("governance");
    address alice      = makeAddr("alice");
    address feeRcpt    = makeAddr("feeRecipient");
    address guardian   = makeAddr("guardian");

    // ─── Contracts ────────────────────────────────────────────
    AdapterRegistry  registry;
    SIXXVault        vault;
    VenusUSDTAdapter adapter;

    uint256 constant DEPOSIT = 1_000e18; // 1,000 USDT

    function setUp() public {
        vm.prank(governance);
        registry = new AdapterRegistry(governance);

        vm.prank(governance);
        vault = new SIXXVault(
            IERC20(USDT),
            "SIXX Stable Yield",
            "sxUSDT",
            governance,
            address(registry),
            feeRcpt,
            guardian
        );

        adapter = new VenusUSDTAdapter(USDT, VUSDT, address(vault), governance);

        vm.startPrank(governance);
        registry.registerAdapter(address(adapter), "DeFi", "Venus Protocol");
        vault.setAdapter(address(adapter));
        vm.stopPrank();

        deal(USDT, alice, DEPOSIT * 10);
    }

    function test_fork_smoke_deposit() public {
        vm.startPrank(alice);
        IERC20(USDT).approve(address(vault), DEPOSIT);
        uint256 shares = vault.deposit(DEPOSIT, alice);
        vm.stopPrank();

        console2.log("--- Venus Smoke Deposit ---");
        console2.log("Shares received   :", shares);
        console2.log("Vault totalAssets :", vault.totalAssets());
        console2.log("Adapter vUSDT bal :", IERC20(VUSDT).balanceOf(address(adapter)));

        assertGt(shares, 0, "Shares must be > 0");
        assertEq(IERC20(USDT).balanceOf(address(vault)), 0, "Vault fully deployed");
        // Venus rounds on mint/redeem — allow small dust.
        assertApproxEqAbs(adapter.totalAssets(), DEPOSIT, 1e15, "Adapter holds ~DEPOSIT");
    }

    function test_fork_deposit_then_withdraw() public {
        vm.startPrank(alice);
        IERC20(USDT).approve(address(vault), DEPOSIT);
        uint256 shares = vault.deposit(DEPOSIT, alice);

        uint256 balBefore = IERC20(USDT).balanceOf(alice);
        uint256 withdrawn = vault.redeem(shares, alice, alice);
        uint256 balAfter = IERC20(USDT).balanceOf(alice);
        vm.stopPrank();

        console2.log("--- Venus Round-trip ---");
        console2.log("Withdrawn :", withdrawn);
        console2.log("Net change:", balAfter - balBefore);

        // Allow ~0.1% for Venus redeem rounding.
        assertApproxEqRel(balAfter - balBefore, DEPOSIT, 0.001e18, "Full round-trip");
    }

    function test_fork_yield_accrual() public {
        vm.startPrank(alice);
        IERC20(USDT).approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, alice);
        vm.stopPrank();

        uint256 before = vault.totalAssets();

        // Venus accrues per block (Compound). Advance blocks + time, then force
        // accrual so exchangeRateStored reflects the new interest.
        vm.roll(block.number + 2_000_000);
        vm.warp(block.timestamp + 30 days);
        IVTokenAccrue(VUSDT).accrueInterest();

        uint256 afterAssets = vault.totalAssets();
        console2.log("--- Venus Yield ---");
        console2.log("before:", before);
        console2.log("after :", afterAssets);

        assertGe(afterAssets, before, "Assets must not decrease over time");
    }

    function test_fork_emergency_shutdown_full_flow() public {
        vm.startPrank(alice);
        IERC20(USDT).approve(address(vault), DEPOSIT);
        uint256 shares = vault.deposit(DEPOSIT, alice);
        vm.stopPrank();

        vm.prank(governance);
        vault.setEmergencyShutdown(true);

        // Funds recalled from Venus back to the vault (allow redeem dust).
        assertApproxEqRel(
            IERC20(USDT).balanceOf(address(vault)), DEPOSIT, 0.001e18,
            "Assets recalled to vault"
        );

        // New deposits are blocked. OZ v5: maxDeposit() returns 0 on shutdown →
        // ERC4626ExceededMaxDeposit fires before the vault's own
        // "VAULT: emergency shutdown" check.
        vm.startPrank(alice);
        IERC20(USDT).approve(address(vault), DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(
            bytes4(keccak256("ERC4626ExceededMaxDeposit(address,uint256,uint256)")),
            alice, DEPOSIT, uint256(0)
        ));
        vault.deposit(DEPOSIT, alice);

        // Holder fully exits during shutdown — the drain-all fix means the 100%
        // redeem no longer trips the Venus dust trap (see the dedicated
        // regression test_fork_full_exit_after_shutdown_does_not_trap).
        uint256 withdrawn = vault.redeem(shares, alice, alice);
        vm.stopPrank();
        assertApproxEqRel(withdrawn, DEPOSIT, 0.001e18, "Can fully withdraw in emergency");
    }

    /// @dev REGRESSION (Venus dust trap): the LAST holder must be able to redeem
    ///      100% of their position after an emergency shutdown. Before the fix the
    ///      emergency recall left sub-unit vUSDT dust counted in totalAssets(), and
    ///      a full redeem then tried redeemUnderlying(dust) → Venus "redeemTokens
    ///      zero" revert. The fix makes the adapter's drain-all path redeem the
    ///      entire vToken balance so no dust survives the recall.
    function test_fork_full_exit_after_shutdown_does_not_trap() public {
        vm.startPrank(alice);
        IERC20(USDT).approve(address(vault), DEPOSIT);
        uint256 shares = vault.deposit(DEPOSIT, alice);
        vm.stopPrank();

        vm.prank(governance);
        vault.setEmergencyShutdown(true);

        // The sole holder redeems 100% of shares — must not revert.
        vm.prank(alice);
        uint256 withdrawn = vault.redeem(shares, alice, alice);

        assertApproxEqRel(withdrawn, DEPOSIT, 0.001e18, "Full exit returns ~deposit");
        // Adapter fully drained (no orphaned dust counted as live assets).
        assertEq(IERC20(VUSDT).balanceOf(address(adapter)), 0, "No vUSDT dust left");
    }

    function test_fork_estimated_apy() public view {
        uint256 apyBps = adapter.estimatedAPY();
        console2.log("--- Venus USDT APY (bps) ---", apyBps);
        // Sane band for a stablecoin supply rate.
        assertLe(apyBps, 5_000, "APY <= 50%");
    }

    function test_fork_two_depositors_proportional_shares() public {
        address bob = makeAddr("bob");
        deal(USDT, bob, DEPOSIT * 10);

        vm.startPrank(alice);
        IERC20(USDT).approve(address(vault), DEPOSIT);
        uint256 sharesAlice = vault.deposit(DEPOSIT, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC20(USDT).approve(address(vault), DEPOSIT * 2);
        uint256 sharesBob = vault.deposit(DEPOSIT * 2, bob);
        vm.stopPrank();

        assertApproxEqRel(sharesBob, sharesAlice * 2, 0.001e18, "Bob has ~2x shares");
        assertApproxEqRel(vault.totalAssets(), DEPOSIT * 3, 0.001e18, "Total ~3000 USDT");
    }
}
