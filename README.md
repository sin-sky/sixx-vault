# SIXX Vault

Foundry (Solidity 0.8.28) implementation of the SIXX yield system: a single
ERC-4626 **Vault** routes funds through one **Adapter** at a time, gated by a
governance-controlled **AdapterRegistry**. One vault is deployed per underlying
asset.

See [`CLAUDE.md`](./CLAUDE.md) for architecture and the post-audit invariants
(`H-1`–`H-4`, `M-1`–`M-5`).

## Build & test

```bash
forge install OpenZeppelin/openzeppelin-contracts --no-commit   # first clone only
forge install foundry-rs/forge-std --no-commit                  # first clone only

forge build
forge test -vvv                                                 # all non-fork tests
```

Fork suites require an RPC and run only when pointed at a fork (they auto-skip
otherwise):

```bash
forge test --fork-url $BASE_RPC_URL --match-contract ERC4626AdapterBaseForkTest -vvv
forge test --fork-url $ETH_RPC_URL  --match-contract ERC4626AdapterEthForkTest  -vvv
```

## Adapters

| Adapter | Protocol | Asset | Chains |
|---|---|---|---|
| `AaveV3USDCAdapter` | Aave V3 | USDC | Ethereum, Arbitrum |
| `VenusUSDTAdapter` | Venus | USDT | BNB Chain |
| `ERC4626Adapter` | Any ERC-4626 (v1: Morpho MetaMorpho) | USDC | Ethereum |

`ERC4626Adapter` is a generic wrapper around a single external ERC-4626 vault.
Blue-chip safety is a **governance-at-registration** property: the `vault` is
immutable, and the AdapterRegistry only whitelists adapters whose target has
cleared the bar below. The same adapter is reusable for other compliant vaults
(Sky `sUSDS`, Ethena `sUSDe`) by deploying against a different address.

### Initial Morpho target (ETH USDC migration)

The first deployment migrates the **existing** ETH USDC SIXXVault from Aave V3 to
Morpho by switching its active adapter (no new vault is created):

| Role | Address |
|---|---|
| Target vault — Morpho · Gauntlet USDC Prime (Ethereum) | `0xdd0f28e19C1780eb6396170735D45153D261490d` |
| Existing SIXXVault (ETH USDC) | `0x5292A8DCd18C6512137e8cA6C21dB0dc6b830b31` |
| AdapterRegistry | `0x0b487365d5E7FD5d324D7221340413a096492542` |
| Current adapter (Aave V3, to be replaced) | `0x8857b9Fb5B0E87aDa7a104B7F8D7FaCAA892487C` |

## ERC4626Adapter — pre-deploy checklist

Governance **MUST** confirm every item below before registering an
`ERC4626Adapter` (`registerAdapter` → `setAdapter`). The contract enforces none
of these except the `asset()` match — they are the blue-chip bar.

- [ ] **ERC-4626 compliant** — `asset()`, `convertToAssets()`, `deposit()`,
      `withdraw()`, `maxWithdraw()` all respond as expected.
- [ ] **Curator is Gauntlet or Steakhouse** — verify the MetaMorpho
      `curator()` / `owner()` **on-chain**; do not trust the label alone.
- [ ] **Instant redemption** — the vault is a same-block redeem type, **not** a
      request/claim withdrawal-queue vault (`maxWithdraw(holder) > 0`
      immediately after deposit). The adapter's `requiredLockPeriod()` returns
      `0` on this assumption; a queued vault needs a separate flow.
- [ ] **TVL ≥ $50M** and **vaults.fyi score ≥ 8**.
- [ ] **`vault.asset()` == the intended underlying** for the chain (also
      asserted in the adapter constructor and the deploy script).
- [ ] **Audit & incident history** reviewed.
- [ ] **Supply-cap headroom ≥ the vault's current `totalAssets`** — otherwise
      `setAdapter`'s redeploy partially fails and migrated funds sit idle in the
      vault (the M-3 try/catch leaves them recoverable, but the migration is
      incomplete). The ETH fork sim asserts idle == 0 post-migration.

> **Rewards:** MORPHO incentive rewards are distributed off-chain via a merkle
> URD and are **not** reflected in the vault's share price, so they never appear
> in `totalAssets()`. v1 leaves them out of scope ("rewards excluded"); a future
> governance-only claim → feeRecipient function can be added without touching
> the core.

### Deploy / migrate (after the checklist passes)

`script/DeployERC4626Adapter.s.sol` connects to the **existing** ETH USDC
SIXXVault and performs the Aave → Morpho migration in one run: deploy adapter →
`registerAdapter` → `setAdapter`.

```bash
forge script script/DeployERC4626Adapter.s.sol --rpc-url $ETH_RPC_URL --broadcast --verify
```

The broadcaster (`PRIVATE_KEY`) **must be the governance EOA** — `register` and
`setAdapter` are governance-gated and the script `require`s it. Verification uses
`ETHERSCAN_API_KEY`. Never commit `.env`.

Validate the whole flow against a mainnet fork first (no broadcast):

```bash
forge test --fork-url $ETH_RPC_URL --match-contract ERC4626AdapterEthMigrationForkTest -vvv
```
