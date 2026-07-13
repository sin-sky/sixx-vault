// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {MockAdapter} from "./mocks/MockAdapter.sol";
import {FaultyAdapter} from "./mocks/FaultyAdapter.sol";
import {MockUSDC} from "./SIXXVault.t.sol";
import {IStrategyAdapter} from "../src/interfaces/IStrategyAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title ThirdReviewRemediation
/// @notice 第3レビュー remediation の PoC / 回帰テスト。
///         H-02（totalAssets() revert 下でもユーザーは常に退出可能）・M-02（mainnet governance=Timelock 強制）・
///         M-03（setAdapter で adapter の vault/asset/governance binding 検証）・L-03（registry list 上限）。
///         L-02（各 adapter rescueToken が underlying を拒否）は各 adapter unit スイートに追加。
contract ThirdReviewRemediationTest is Test {
    address governance   = address(0xBEEF);
    address alice        = address(0xA11CE);
    address bob          = address(0xB0B);
    address feeRcpt      = address(0xFEE);
    address guardianAddr = address(0x6042D);

    MockUSDC        usdc;
    AdapterRegistry registry;
    SIXXVault       vault;
    MockAdapter     adapter;

    uint256 constant USDC_6 = 1e6;

    function setUp() public {
        usdc = new MockUSDC();
        vm.prank(governance);
        registry = new AdapterRegistry(governance);
        vm.prank(governance);
        vault = new SIXXVault(
            IERC20(address(usdc)), "SIXX Stable Yield", "sxUSDC",
            governance, address(registry), feeRcpt, guardianAddr
        );
        adapter = new MockAdapter(address(usdc), address(vault));
        vm.startPrank(governance);
        registry.registerAdapter(address(adapter), "DeFi", "Mock");
        vault.setAdapter(address(adapter));
        vm.stopPrank();

        usdc.mint(alice, 100_000 * USDC_6);
        usdc.mint(bob,   100_000 * USDC_6);
    }

    function _deposit(address who, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(who);
        usdc.approve(address(vault), amount);
        shares = vault.deposit(amount, who);
        vm.stopPrank();
    }

    function _swapToFaulty() internal returns (FaultyAdapter f) {
        f = new FaultyAdapter(address(usdc), address(vault));
        vm.startPrank(governance);
        registry.registerAdapter(address(f), "Test", "Faulty");
        vault.setAdapter(address(f));
        vm.stopPrank();
    }

    // =====================================================================
    // H-02 — totalAssets() revert 下でもユーザーは常に退出可能
    // =====================================================================

    /// After emergency shutdown recalls funds to idle, a subsequently-reverting adapter
    /// valuation must NOT block the exit: redeem must ACTUALLY succeed (assets received),
    /// not merely leave a flag set. Exercises both the `_collectFees` front-stage and the
    /// ERC-4626 share↔asset conversion, which both read totalAssets().
    function test_H02_redeem_succeeds_underShutdown_whenTotalAssetsReverts() public {
        vm.prank(governance);
        vault.setManagementFee(100); // 1% — exercise the fee front-stage too

        _deposit(alice, 1_000 * USDC_6);
        FaultyAdapter f = _swapToFaulty(); // funds migrate into the faulty adapter

        // Shutdown recalls everything to the vault (adapter withdraw still works here).
        vm.prank(guardianAddr);
        vault.setEmergencyShutdown(true);
        assertTrue(vault.emergencyShutdown(), "shutdown flag not set");

        // NOW the adapter valuation starts reverting (broken oracle post-shutdown).
        f.setRevertOnTotalAssets(true);
        skip(30 days); // a fee window so _collectFees does real work on the exit path

        uint256 shares   = vault.balanceOf(alice);
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 got = vault.redeem(shares, alice, alice); // MUST NOT revert

        assertGt(got, 0, "H-02: redeem produced no assets under totalAssets revert");
        assertEq(usdc.balanceOf(alice) - balBefore, got, "H-02: user did not receive redeemed assets");
        assertEq(vault.balanceOf(alice), 0, "H-02: shares not fully burned");
    }

    /// Even WITHOUT shutdown (funds still in the adapter, not idle): a reverting valuation
    /// must fall back to a best-effort recall so the user can still exit as long as the
    /// adapter's own withdraw can deliver.
    /// H-02 + C-1 guard (Round-8 v2): a reverting adapter valuation must never BRICK an exit, but
    /// the exit is now IDLE-ONLY (it does NOT recall against the stale loss-blind `_totalDebt` — the
    /// finding C-1/D-1/E-1 fix). With idle==0 the solo exit returns 0 (no revert, claim retained);
    /// the adapter funds are released FAIRLY by force-detach. This deliberately supersedes the old
    /// "permissionless recall on broken oracle" behavior (now governance-gated via force-detach).
    function test_H02_valuationRevert_idleOnly_noBrick_thenDetachRecovers() public {
        _deposit(alice, 1_000 * USDC_6);
        FaultyAdapter f = _swapToFaulty();      // funds held in the faulty adapter; idle == 0
        f.setRevertOnTotalAssets(true);         // valuation reverts

        uint256 shares   = vault.balanceOf(alice);
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 got = vault.redeem(shares, alice, alice); // MUST NOT revert (柱1)

        assertEq(got, 0, "guard: idle-only exit (idle==0), no recall against stale mark");
        assertEq(usdc.balanceOf(alice), balBefore, "nothing delivered while idle-only");
        assertGt(vault.balanceOf(alice), 0, "no brick; claim retained");

        // force-detach releases the adapter funds -> alice recovers in full.
        f.setRevertOnTotalAssets(false);
        vm.prank(governance);
        vault.setAdapter(address(0));
        uint256 rem = vault.balanceOf(alice); // hoist before prank (a call here would consume it)
        vm.prank(alice);
        uint256 got2 = vault.redeem(rem, alice, alice);
        assertApproxEqAbs(got + got2, 1_000 * USDC_6, 3, "force-detach recovers full principal");
    }

    /// totalAssets() itself must never revert — it degrades to the last booked debt so all
    /// read-dependent paths (previews, conversion, fee) stay live.
    function test_H02_totalAssets_neverReverts_onAdapterReadFailure() public {
        _deposit(alice, 1_000 * USDC_6);
        FaultyAdapter f = _swapToFaulty();
        f.setRevertOnTotalAssets(true);
        uint256 ta = vault.totalAssets(); // MUST NOT revert
        assertApproxEqAbs(ta, 1_000 * USDC_6, 2, "H-02: totalAssets fallback (last debt) wrong");
    }

    // =====================================================================
    // M-02 — mainnet governance must be a TimelockController(>=48h), never a hot EOA
    // =====================================================================

    function _newTimelock(uint256 delay) internal returns (TimelockController) {
        address[] memory p = new address[](1); p[0] = governance;
        address[] memory e = new address[](1); e[0] = governance;
        return new TimelockController(delay, p, e, address(0));
    }

    function test_M02_vault_proposeGovernance_mainnet_rejectsEOA() public {
        vm.chainId(1);
        vm.prank(governance);
        vm.expectRevert(bytes("VAULT: mainnet gov must be a Timelock"));
        vault.proposeGovernance(bob); // EOA — no getMinDelay()
    }

    function test_M02_vault_proposeGovernance_mainnet_rejectsShortTimelock() public {
        vm.chainId(1);
        TimelockController tl = _newTimelock(24 hours); // < 48h
        vm.prank(governance);
        vm.expectRevert(bytes("VAULT: mainnet gov timelock < 48h"));
        vault.proposeGovernance(address(tl));
    }

    function test_M02_vault_proposeGovernance_mainnet_acceptsTimelock48h() public {
        vm.chainId(1);
        TimelockController tl = _newTimelock(48 hours);
        vm.prank(governance);
        vault.proposeGovernance(address(tl));
        assertEq(vault.pendingGovernance(), address(tl), "M-02: 48h Timelock rejected on mainnet");
    }

    function test_M02_vault_proposeGovernance_nonMainnet_allowsEOA() public {
        // Default chain (31337) — testnet/local iteration keeps EOA governance.
        vm.prank(governance);
        vault.proposeGovernance(bob);
        assertEq(vault.pendingGovernance(), bob, "M-02: EOA blocked off-mainnet");
    }

    function test_M02_registry_proposeGovernance_mainnet_rejectsEOA() public {
        vm.chainId(1);
        vm.prank(governance);
        vm.expectRevert(bytes("REGISTRY: mainnet gov must be a Timelock"));
        registry.proposeGovernance(bob);
    }

    // =====================================================================
    // F-1 — the M-02 Timelock-governance guard must ALSO fire on the
    //        non-Ethereum production chains the deploy script wires as
    //        mainnet: Arbitrum One (42161) and BNB Chain (56). The guard
    //        previously keyed on chainid==1 only, leaving the vault's
    //        PRIMARY production chain (Arbitrum One) able to hand governance
    //        to a bare EOA — silently defeating the 48h detection window.
    // =====================================================================

    function test_F1_vault_proposeGovernance_arbitrumOne_rejectsEOA() public {
        vm.chainId(42161);
        vm.prank(governance);
        vm.expectRevert(bytes("VAULT: mainnet gov must be a Timelock"));
        vault.proposeGovernance(bob);
    }

    function test_F1_vault_proposeGovernance_bnb_rejectsEOA() public {
        vm.chainId(56);
        vm.prank(governance);
        vm.expectRevert(bytes("VAULT: mainnet gov must be a Timelock"));
        vault.proposeGovernance(bob);
    }

    function test_F1_vault_proposeGovernance_arbitrumOne_rejectsShortTimelock() public {
        vm.chainId(42161);
        TimelockController tl = _newTimelock(24 hours);
        vm.prank(governance);
        vm.expectRevert(bytes("VAULT: mainnet gov timelock < 48h"));
        vault.proposeGovernance(address(tl));
    }

    function test_F1_vault_proposeGovernance_arbitrumOne_acceptsTimelock48h() public {
        vm.chainId(42161);
        TimelockController tl = _newTimelock(48 hours);
        vm.prank(governance);
        vault.proposeGovernance(address(tl));
        assertEq(vault.pendingGovernance(), address(tl), "F-1: 48h Timelock rejected on Arbitrum One");
    }

    function test_F1_registry_proposeGovernance_arbitrumOne_rejectsEOA() public {
        vm.chainId(42161);
        vm.prank(governance);
        vm.expectRevert(bytes("REGISTRY: mainnet gov must be a Timelock"));
        registry.proposeGovernance(bob);
    }

    function test_F1_registry_proposeGovernance_bnb_rejectsEOA() public {
        vm.chainId(56);
        vm.prank(governance);
        vm.expectRevert(bytes("REGISTRY: mainnet gov must be a Timelock"));
        registry.proposeGovernance(bob);
    }

    // Testnets stay EOA-friendly for iteration: Arbitrum Sepolia (421614)
    // and BNB Testnet (97) must NOT require a Timelock.
    function test_F1_vault_proposeGovernance_arbSepolia_allowsEOA() public {
        vm.chainId(421614);
        vm.prank(governance);
        vault.proposeGovernance(bob);
        assertEq(vault.pendingGovernance(), bob, "F-1: EOA blocked on Arbitrum Sepolia testnet");
    }

    // RINV-5 negative test: the REGISTRY false-side of _isProductionChain() had no
    //   diff-local coverage (only the vault had a non-production allows-EOA test), so a
    //   mutant flipping `if (_isProductionChain())` to `if (true)` survived this suite and
    //   was only caught by RemediationPartB. This pins the registry testnet path here so
    //   the gate's false branch is killed diff-locally too. (chainid 421614 = Arb Sepolia.)
    function test_F1_registry_proposeGovernance_nonProduction_allowsEOA() public {
        vm.chainId(421614);
        vm.prank(governance);
        registry.proposeGovernance(bob);
        assertEq(registry.pendingGovernance(), bob, "F-1: registry EOA blocked off-production");
    }

    // Also pin the default-chain (31337) registry path — an `if (true)` mutant on the
    //   registry gate must revert an EOA proposal here, so this kills it directly.
    function test_F1_registry_proposeGovernance_defaultChain_allowsEOA() public {
        // no vm.chainId → default 31337 (local), a non-production chain.
        vm.prank(governance);
        registry.proposeGovernance(bob);
        assertEq(registry.pendingGovernance(), bob, "F-1: registry EOA blocked on local chain");
    }

    // =====================================================================
    // M-03 — setAdapter verifies the adapter's vault/asset/governance binding
    // =====================================================================

    function _register(address a) internal {
        vm.prank(governance);
        registry.registerAdapter(a, "Test", "Bind");
    }

    function test_M03_setAdapter_rejectsAssetMismatch() public {
        MockUSDC other = new MockUSDC();
        MockAdapter bad = new MockAdapter(address(other), address(vault)); // wrong asset
        _register(address(bad));
        vm.prank(governance);
        vm.expectRevert(bytes("VAULT: adapter asset mismatch"));
        vault.setAdapter(address(bad));
    }

    function test_M03_setAdapter_rejectsVaultMismatch() public {
        MockAdapter bad = new MockAdapter(address(usdc), address(0xDEAD)); // wrong vault
        _register(address(bad));
        vm.prank(governance);
        vm.expectRevert(bytes("VAULT: adapter vault mismatch"));
        vault.setAdapter(address(bad));
    }

    function test_M03_setAdapter_rejectsGovernanceMismatch() public {
        GovMockAdapter bad = new GovMockAdapter(address(usdc), address(vault), address(0xBAD));
        _register(address(bad));
        vm.prank(governance);
        vm.expectRevert(bytes("VAULT: adapter governance mismatch"));
        vault.setAdapter(address(bad));
    }

    function test_M03_setAdapter_acceptsCorrectlyBoundAdapter() public {
        GovMockAdapter ok = new GovMockAdapter(address(usdc), address(vault), governance);
        _register(address(ok));
        vm.prank(governance);
        vault.setAdapter(address(ok)); // all bindings match → succeeds
        assertEq(vault.activeAdapter(), address(ok), "M-03: correctly-bound adapter rejected");
    }

    // =====================================================================
    // L-03 — registry active-adapter list is bounded (no unbounded-gas DoS)
    // =====================================================================

    function test_L03_registerAdapter_enforcesMaxAdapters() public {
        uint256 cap = registry.MAX_ADAPTERS();
        // one adapter (the Mock) is already registered in setUp.
        for (uint256 i = registry.getActiveAdapters().length; i < cap; i++) {
            vm.prank(governance);
            registry.registerAdapter(address(uint160(0x1000 + i)), "T", "P");
        }
        // the next registration exceeds the cap and must revert.
        vm.prank(governance);
        vm.expectRevert(bytes("REGISTRY: max adapters"));
        registry.registerAdapter(address(uint160(0x9999)), "T", "P");
    }
}

/// @dev Mock adapter that additionally exposes governance() (like the real adapters), so the
///      M-03 governance-binding branch can be exercised. Reuses MockAdapter's vault()/asset().
contract GovMockAdapter is MockAdapter {
    address public governance;
    constructor(address asset_, address vault_, address gov_) MockAdapter(asset_, vault_) {
        governance = gov_;
    }
}
