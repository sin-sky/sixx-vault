// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";

/// @title MorphoAdapterForkTest
/// @notice Ethereum mainnet fork integration for the generic ERC4626Adapter
///         pointed at a LIVE blue-chip MetaMorpho vault (Gauntlet USDC Prime).
///         Confirms the adapter "connects" (wiring), a USDC->shares deposit,
///         totalAssets accounting, and a withdraw round-trip against real state.
///
///         This test does NOT activate, register, deploy or broadcast anything.
///         It only verifies the connection in a fork (Go A/Go B gate untouched).
///
///         Run (scoped so it never drags in the other fork suites):
///           forge test --fork-url $ETH_RPC_URL \
///             --fork-block-number 25501600 \
///             --match-contract MorphoAdapterForkTest -vvv
contract MorphoAdapterForkTest is Test {
    // ── Verified on-chain 2026-07-10 (chainid 1) via read-only cast call ──
    // Underlying
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // 6 decimals

    // Primary target: Gauntlet USDC Prime (MetaMorpho, gtUSDC, 18-dec shares).
    //   asset()==USDC ✅ | curator 0x9E33..0585 | owner 0xC684..fAec
    //   TVL ~$31.36M @ this block (BELOW the $50M Go B activation gate).
    address constant GAUNTLET_USDC_PRIME = 0xdd0f28e19C1780eb6396170735D45153D261490d;

    // Secondary target (also verified ERC-4626 / asset==USDC; TVL ~$95.5M,
    //   already clears the $50M gate). Kept as a second connection assertion.
    address constant STEAKHOUSE_USDC = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;

    uint256 constant FORK_BLOCK = 25_501_600;

    address governance = makeAddr("governance");
    address sixxVault  = makeAddr("sixxVault"); // the test acts as the SIXXVault
    address recipient  = makeAddr("recipient");

    ERC4626Adapter adapter;
    bool forked;

    function setUp() public {
        string memory url = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            forked = false;
            return;
        }
        vm.createSelectFork(url, FORK_BLOCK);
        forked = true;
        // Deploy the (already-audited) generic adapter against the LIVE vault.
        adapter = new ERC4626Adapter(USDC, GAUNTLET_USDC_PRIME, sixxVault, governance);
    }

    modifier onlyFork() {
        if (!forked) return;
        _;
    }

    function _fundAndDeposit(uint256 usdcAmt) internal {
        deal(USDC, address(adapter), usdcAmt);
        vm.prank(sixxVault);
        adapter.deposit(usdcAmt);
    }

    // ── wiring: adapter connects to a real, compliant ERC-4626 ──────────
    function test_fork_wiring() public onlyFork {
        // Adapter side
        assertEq(adapter.asset(), USDC, "adapter asset != USDC");
        assertEq(address(adapter.vault()), GAUNTLET_USDC_PRIME, "vault not wired");
        assertEq(adapter.sixxVault(), sixxVault, "sixxVault not set");
        assertEq(adapter.governance(), governance, "governance not set");
        assertTrue(adapter.isActive(), "adapter should be active on deploy");
        assertEq(adapter.riskLevel(), 2, "riskLevel");
        assertEq(adapter.requiredLockPeriod(), 0, "lock period should be instant");

        // Live vault side: prove full ERC-4626 surface responds on real state.
        IERC4626 v = IERC4626(GAUNTLET_USDC_PRIME);
        assertEq(v.asset(), USDC, "vault.asset != USDC");
        assertEq(IERC20Metadata(GAUNTLET_USDC_PRIME).decimals(), 18, "share decimals");
        assertEq(IERC20Metadata(USDC).decimals(), 6, "USDC decimals");

        uint256 tvl = v.totalAssets();
        assertGt(tvl, 0, "vault has no assets");
        uint256 shPer1e18 = v.convertToAssets(1e18);
        uint256 shFor1e6  = v.convertToShares(1e6);
        assertGt(shPer1e18, 0, "convertToAssets zero");
        assertGt(shFor1e6, 0, "convertToShares zero");
        // previewDeposit / previewRedeem must be live too.
        assertGt(v.previewDeposit(1e6), 0, "previewDeposit zero");
        assertGt(v.previewRedeem(1e18), 0, "previewRedeem zero");

        emit log_named_string("vault name", IERC20Metadata(GAUNTLET_USDC_PRIME).name());
        emit log_named_string("vault symbol", IERC20Metadata(GAUNTLET_USDC_PRIME).symbol());
        emit log_named_uint("vault TVL (USDC 6dp)", tvl);
        emit log_named_uint("convertToAssets(1e18 shares) USDC", shPer1e18);

        // Secondary vault connection sanity (asset match only — not the deploy target).
        assertEq(IERC4626(STEAKHOUSE_USDC).asset(), USDC, "steakhouse asset != USDC");
    }

    // ── constructor mistaken-vault guard: asset mismatch must revert ────
    function test_fork_constructor_rejects_asset_mismatch() public onlyFork {
        // WETH != USDC underlying of the vault → asset mismatch guard fires.
        address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        vm.expectRevert(bytes("ADAPTER: asset mismatch"));
        new ERC4626Adapter(WETH, GAUNTLET_USDC_PRIME, sixxVault, governance);
    }

    // ── deposit: USDC -> gtUSDC shares held by adapter ──────────────────
    function test_fork_deposit_mints_shares() public onlyFork {
        uint256 principal = 50_000e6;
        _fundAndDeposit(principal);

        uint256 shares = IERC20(GAUNTLET_USDC_PRIME).balanceOf(address(adapter));
        assertGt(shares, 0, "no gtUSDC shares minted");
        // PUSH model: no idle underlying left on the adapter after deposit.
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0, "idle USDC left behind");

        uint256 nav = adapter.totalAssets();
        emit log_named_uint("gtUSDC shares (1e18)", shares);
        emit log_named_uint("totalAssets USDC (6dp)", nav);

        // totalAssets = convertToAssets(shares) floors, so it is <= principal but
        // within a couple of accounting units (share price rounding only).
        assertLe(nav, principal, "totalAssets over-reports principal");
        assertGe(nav + 5, principal, "totalAssets undershoots principal beyond rounding dust");
    }

    // ── totalAssets tracks the live share price (no idle-cash mispricing) ──
    function test_fork_totalAssets_matches_convertToAssets() public onlyFork {
        _fundAndDeposit(50_000e6);
        uint256 shares = IERC20(GAUNTLET_USDC_PRIME).balanceOf(address(adapter));
        uint256 expected = IERC4626(GAUNTLET_USDC_PRIME).convertToAssets(shares);
        assertEq(adapter.totalAssets(), expected, "totalAssets != convertToAssets(shares)");
    }

    // ── withdraw round-trip: recipient gets USDC back, ~lossless ────────
    function test_fork_withdraw_roundtrip() public onlyFork {
        uint256 principal = 50_000e6;
        _fundAndDeposit(principal);

        uint256 nav = adapter.totalAssets();
        vm.prank(sixxVault);
        uint256 got = adapter.withdraw(nav, recipient);

        assertEq(IERC20(USDC).balanceOf(recipient), got, "recipient balance != returned");
        // ERC-4626 withdraw delivers exactly the (maxWithdraw-clamped) request.
        assertEq(got, nav, "withdraw did not deliver requested NAV");

        // Round-trip loss is pure share-price flooring dust (no swap/slippage).
        uint256 lossBps = principal > got ? ((principal - got) * 10_000) / principal : 0;
        emit log_named_uint("roundtrip loss (bps)", lossBps);
        assertEq(lossBps, 0, "unexpected round-trip loss on a bare ERC-4626");

        // Position essentially cleared; convertToAssets floors dust to 0.
        assertTrue(adapter.isFullyExited(), "adapter not fully exited after full drain");
    }

    // ── partial withdraw leaves the remainder deployed ──────────────────
    function test_fork_partial_withdraw() public onlyFork {
        _fundAndDeposit(50_000e6);
        uint256 want = 20_000e6;
        vm.prank(sixxVault);
        uint256 got = adapter.withdraw(want, recipient);

        assertEq(got, want, "partial withdraw shortfall");
        assertEq(IERC20(USDC).balanceOf(recipient), want, "recipient underfunded");
        assertGt(adapter.totalAssets(), 0, "position fully drained on partial");
        emit log_named_uint("remaining NAV after partial (USDC 6dp)", adapter.totalAssets());
    }

    // ── APY is 0 on-chain BY DESIGN (front-end sources 7d avg off-chain) ──
    function test_fork_estimatedAPY_is_zero_by_design() public onlyFork {
        // MetaMorpho realized APY depends on the allocation across underlying
        // Morpho Blue markets and is not reliably readable on-chain — the
        // adapter intentionally returns 0 and the UI uses vaults.fyi/DefiLlama.
        assertEq(adapter.estimatedAPY(), 0, "estimatedAPY should be 0 by design");
    }

    // ── access control: only the wired SIXXVault can move funds ─────────
    function test_fork_onlyVault_gates_deposit() public onlyFork {
        deal(USDC, address(adapter), 1_000e6);
        vm.expectRevert(bytes("ADAPTER: only vault"));
        adapter.deposit(1_000e6); // called by test (not sixxVault)
    }
}
