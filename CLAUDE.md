# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository

Foundry project (Solidity 0.8.28). The working tree in this codespace lives at `/workspaces/sixx-vault`; ignore `~/sixx-vault` paths in `SETUP.md` — that doc was written for a local machine.

Submodules under `lib/` (`openzeppelin-contracts`, `forge-std`) must exist before `forge build`. After a fresh clone:

```bash
forge install OpenZeppelin/openzeppelin-contracts --no-commit
forge install foundry-rs/forge-std --no-commit
```

## Commands

```bash
forge build                                                            # compile
forge test -vvv                                                        # all non-fork tests
forge test --match-contract SIXXVaultTest -vvv                         # unit tests only
forge test --match-test test_Foo -vvv                                  # single test by name
forge test --fork-url $ARB_RPC_URL --match-contract AaveV3AdapterForkTest -vvv
forge test --fork-url $ARB_RPC_URL --fork-block-number 300000000 \
  --match-contract AaveV3AdapterForkTest -vvv                          # pinned-block fork run
forge script script/Deploy.s.sol --rpc-url $ARB_SEPOLIA_RPC_URL --broadcast
```

Fork tests require `ARB_RPC_URL` (and/or `ETH_RPC_URL`) in `.env`; deploys also need `PRIVATE_KEY`. Verify uses `ARBISCAN_API_KEY` / `ETHERSCAN_API_KEY`. Foundry profile: optimizer on (200 runs), `via_ir = false`, fuzz `runs = 1000`, invariant `runs = 256` / `depth = 15`.

## Architecture

Three-contract system: a single ERC-4626 **Vault** routes funds through one **Adapter** at a time, gated by a governance-controlled **AdapterRegistry**. One vault is deployed per underlying asset (e.g. one for USDC).

- **`SIXXVault`** (`src/core/SIXXVault.sol`) — ERC-4626 wrapper. Holds no idle balance during normal operation: `_deposit` pushes everything to the active adapter via `_deployToAdapter`, and `_withdraw` pulls just-enough back via `_recallFromAdapter`. `totalAssets()` = `IERC20(asset).balanceOf(vault) + IStrategyAdapter(activeAdapter).totalAssets()`. The adapter is the source of truth for deployed funds; `_totalDebt` is a bookkeeping aid, not a balance.
- **`AdapterRegistry`** (`src/core/AdapterRegistry.sol`) — Governance whitelist. `setAdapter` on the vault enforces `registry.isActive(newAdapter)` when `adapterRegistry != address(0)`; passing `address(0)` as the new adapter is the explicit "pause strategy" path and bypasses the check.
- **`IStrategyAdapter`** (`src/interfaces/IStrategyAdapter.sol`) — Adapter contract. Implementations live under `src/adapters/`. The vault transfers underlying tokens to the adapter *before* calling `deposit(amount)`, and `withdraw(amount, recipient)` sends directly to `recipient` (usually the vault). Auto-compounding adapters (e.g. `AaveV3USDCAdapter` holding aUSDC) make `harvest()` a no-op. Adapters are `onlyVault` for state-changing entry points.

### Invariants enforced after the recent audit

These have explicit `H-*` / `M-*` markers in code comments and commit history — preserve them when editing:

- **H-1**: `setAdapter` enforces the registry whitelist unless `newAdapter == address(0)`.
- **H-2**: Share transfers (`_update`) revert while the sender's lock is active. Mints/burns are exempt; burns are gated by `_withdraw`.
- **H-3**: A deposit only extends `_lockedUntil[receiver]` when `caller == receiver`. Depositing on behalf of someone else does not re-lock them.
- **H-4**: `maxWithdraw` / `maxRedeem` return 0 while the owner is locked, so integrators and previews see the lock.
- **M-1**: `collectFees` uses the dilution formula `feeShares = feeAssets * supply / (assets - feeAssets)` because `feeAssets` is already counted in `totalAssets()`; do not switch back to `previewDeposit`.

Other constraints:

- Hard fee caps: `MAX_PERFORMANCE_FEE = 3000` (30%), `MAX_MANAGEMENT_FEE = 500` (5%).
- 2-step governance transfer on both `SIXXVault` and `AdapterRegistry` (`proposeGovernance` → `acceptGovernance`).
- Emergency shutdown blocks new deposits via `maxDeposit`/`maxMint` returning 0 and via the `_deposit` revert check; toggling it on force-recalls all assets from the adapter.
- `_decimalsOffset() = 9` (OZ v5 virtual-shares offset) protects against first-deposit inflation attacks; for USDC this gives 15-decimal shares.
- The `performanceFee` field exists and is settable, but is not yet referenced in any accrual path — only management fee is currently collected by `collectFees`.

### Tests

- `test/SIXXVault.t.sol` — pure unit tests using `MockUSDC` (declared in the same file) and `test/mocks/MockAdapter.sol`. No fork required.
- `test/AaveV3Adapter.t.sol` — integration tests against live Arbitrum One state; needs `--fork-url $ARB_RPC_URL`. Hardcodes Arbitrum USDC / Aave Pool / aUSDC addresses.

When adding a new adapter, mirror the `AaveV3USDCAdapter` pattern: store `vault` and `governance` as state, gate writes with `onlyVault`, expose live APY via the underlying protocol's rate oracle, and add both a unit suite (against a mock pool) and a fork suite.
