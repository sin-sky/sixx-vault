// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {ERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ERC4626AdapterEthMigrationForkTest
/// @notice Full-flow simulation on an Ethereum mainnet fork: deploy the new
///         ERC4626Adapter against the LIVE ETH USDC SIXXVault, register it, and
///         switch the active strategy Aave V3 -> Morpho · Gauntlet USDC Prime,
///         proving funds migrate and a deposit/withdraw round-trip works.
///
///   forge test --fork-url $ETH_RPC_URL \
///     --match-contract ERC4626AdapterEthMigrationForkTest -vvv
///
/// Uses the real addresses from broadcast/Deploy.s.sol/1/run-latest.json.
contract ERC4626AdapterEthMigrationForkTest is Test {
    // ─── Live ETH mainnet deployment ─────────────────────────
    address constant USDC         = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant REGISTRY     = 0x0b487365d5E7FD5d324D7221340413a096492542;
    address constant SIXX_VAULT   = 0x5292A8DCd18C6512137e8cA6C21dB0dc6b830b31;
    address constant GOVERNANCE   = 0x58cda24e2530d34FCa304e79c37f97c347Edb150;
    address constant AAVE_ADAPTER = 0x8857b9Fb5B0E87aDa7a104B7F8D7FaCAA892487C;
    address constant A_USDC       = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c; // aEthUSDC

    // ─── Migration target ────────────────────────────────────
    address constant GAUNTLET_USDC_PRIME = 0xdd0f28e19C1780eb6396170735D45153D261490d;

    SIXXVault vault = SIXXVault(SIXX_VAULT);

    function test_fork_migrate_aave_to_morpho() public {
        if (SIXX_VAULT.code.length == 0) {
            vm.skip(true); // not an ETH fork
            return;
        }

        // ── 0. Seed deposit so the live Aave adapter actually holds funds ──
        address alice = makeAddr("alice");
        uint256 seed  = 50_000e6;
        deal(USDC, alice, seed);
        vm.startPrank(alice);
        IERC20(USDC).approve(SIXX_VAULT, seed);
        vault.deposit(seed, alice);
        vm.stopPrank();

        uint256 taPre    = vault.totalAssets();
        uint256 aUsdcPre = IERC20(A_USDC).balanceOf(AAVE_ADAPTER);
        console2.log("Active adapter (pre):", vault.activeAdapter());
        console2.log("totalAssets   (pre):", taPre);
        console2.log("Aave aUSDC    (pre):", aUsdcPre);
        assertEq(vault.activeAdapter(), AAVE_ADAPTER, "starts on Aave");
        assertGt(aUsdcPre, 0, "Aave holds funds pre-migration");

        // ── 1. Deploy the new adapter bound to the LIVE vault ──
        ERC4626Adapter morpho = new ERC4626Adapter(
            USDC, GAUNTLET_USDC_PRIME, SIXX_VAULT, GOVERNANCE
        );
        assertEq(morpho.asset(), USDC, "adapter asset == USDC");
        assertEq(address(morpho.vault()), GAUNTLET_USDC_PRIME, "wired to Gauntlet Prime");

        // ── 2 & 3. Register + switch active strategy (governance) ──
        vm.startPrank(GOVERNANCE);
        AdapterRegistry(REGISTRY).registerAdapter(
            address(morpho), "DeFi", "Morpho - Gauntlet USDC Prime (ETH)"
        );
        vault.setAdapter(address(morpho)); // recalls 100% from Aave, redeploys to Morpho
        vm.stopPrank();

        uint256 idle      = IERC20(USDC).balanceOf(SIXX_VAULT);
        uint256 aUsdcPost = IERC20(A_USDC).balanceOf(AAVE_ADAPTER);
        uint256 morphoTA  = morpho.totalAssets();
        console2.log("Active adapter (post):", vault.activeAdapter());
        console2.log("Aave aUSDC    (post):", aUsdcPost);
        console2.log("Morpho TA     (post):", morphoTA);
        console2.log("Vault idle    (post):", idle);
        console2.log("totalAssets   (post):", vault.totalAssets());

        // Active adapter switched and Aave fully drained.
        assertEq(vault.activeAdapter(), address(morpho), "now on Morpho");
        assertApproxEqAbs(aUsdcPost, 0, 5, "Aave adapter drained");
        // Funds landed in Morpho (would be 0 + idle>0 if the vault's supply cap blocked).
        assertApproxEqRel(morphoTA, taPre, 0.0005e18, "Morpho holds ~all migrated assets");
        assertApproxEqAbs(idle, 0, 5, "no funds stranded idle");
        // Total assets preserved across the migration (value-neutral).
        assertApproxEqRel(vault.totalAssets(), taPre, 0.0005e18, "totalAssets preserved");

        // ── 4. Small deposit/withdraw round-trip on the new strategy ──
        address bob   = makeAddr("bob");
        uint256 amt   = 1_000e6;
        deal(USDC, bob, amt);
        vm.startPrank(bob);
        IERC20(USDC).approve(SIXX_VAULT, amt);
        uint256 shares = vault.deposit(amt, bob);
        vm.stopPrank();
        assertGt(shares, 0, "bob got shares");
        assertApproxEqRel(morpho.totalAssets(), taPre + amt, 0.0005e18, "deposit routed to Morpho");

        // Warp past the deposit lock so bob can withdraw.
        vm.warp(block.timestamp + vault.lockPeriod() + 1);

        uint256 bobBefore = IERC20(USDC).balanceOf(bob);
        vm.prank(bob);
        uint256 got = vault.redeem(shares, bob, bob);
        uint256 received = IERC20(USDC).balanceOf(bob) - bobBefore;
        console2.log("Round-trip deposit :", amt);
        console2.log("Round-trip received:", received);
        assertEq(received, got, "redeem return matches transfer");
        assertApproxEqRel(received, amt, 0.001e18, "bob recovered ~deposit (round-trip)");
    }
}
