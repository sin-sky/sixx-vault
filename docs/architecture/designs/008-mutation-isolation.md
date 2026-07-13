# ADR-008 — Mutation isolation & the concurrent-session / zombie-contamination rule

- Status: **Accepted** (2026-07-13)
- Context: Round 8 pre-freeze hardening
- Supersedes: nothing; complements ADR-006 (mutation as the free automation layer)

## Problem

A mutation harness works by copying a Gambit *mutant* into `src/core/SIXXVault.sol`, running the
suite to see if it dies, then restoring the original. Three times during Round 8 the working
tree's source was **re-contaminated from outside the running command**:

1. a `nohup … &` mutation job orphaned and swapped mutants in while Slither/Aderyn ran (results voided);
2. a background confirmation loop kept cycling mutants into `src` after its launching turn ended;
3. a **foreground** mutant-swap loop that hit the harness's command timeout **did not die** — the
   underlying `bash … for id in …; cp mutant→src; forge test; cp back` kept looping as an orphan,
   silently leaving `#438` / `#564` in `src` between later commands and breaking clean-tree guards.

Root causes: (a) mutation ran in the **primary (freeze-target) worktree**, so any leak dirtied the
body directly; (b) the restore `trap` does not fire on `SIGKILL` / timeout, and forge **children**
outlive the parent; (c) this tree is shared by **parallel sessions** running mutation concurrently.

Clean-tree guards *caught* the contamination each time, but "catch" is not "prevent".

## Decision

**Mutation must never run in the primary worktree, and a leaked mutant must never be commitable.**

1. **Isolation (prevention).** `scripts/mutation-guard.sh::mutation_require_isolated_worktree`
   aborts (exit 5) when `git rev-parse --git-dir == --git-common-dir` (the primary worktree).
   Both `scripts/mutation-test.sh` and `scripts/mutation-diffscope.sh` source it and call it before
   touching source. The **only** sanctioned entry point is
   `scripts/run-mutation-isolated.sh <script> [args]`, which:
   - creates a throwaway **linked** worktree (`…-mut-$$`) at the current `HEAD`,
   - symlinks `lib/` (submodules aren't checked out in a linked worktree),
   - runs the mutation script under `setsid` (its own process group),
   - on **any** exit/INT/TERM: `kill -- -$$` the whole group, then `git worktree remove --force` +
     `prune`. A leaked mutant can therefore only ever dirty a disposable tree.
   Emergency override (discouraged, logged): `MUTATION_ALLOW_PRIMARY=1`.

2. **No child outlives its step.** Each per-mutant `forge` runs via `mutation_run <secs> …` =
   `timeout --kill-after=15s`, so a hung/mutated forge is force-killed rather than lingering.

3. **Commit-time backstop.** `.githooks/pre-commit` (enabled by `scripts/install-hooks.sh` →
   `core.hooksPath=.githooks`) rejects any commit whose **staged** `src/**.sol` carries a Gambit
   mutation marker (`/// …Mutation(`). A leaked mutant can never be frozen into history.

4. **Regression-locked.** `scripts/test-mutation-hygiene.sh` asserts (1) the hook rejects a
   mutation-marked staged file, (2) it allows clean source, (3) the harness refuses the primary
   worktree. Run it in CI / before freeze.

## Concurrent-session rule (permanent)

This working tree is shared by parallel agent sessions. Therefore:

- **Never** run a mutation/mutant-swap job in the primary tree — use `run-mutation-isolated.sh`.
- Before trusting any measurement: `pgrep -af 'gambit_diffscope|BK=|for id in|final-confirm'` and
  kill strays; wrap every measurement in a pre/post `git diff --quiet -- src/core/SIXXVault.sol`
  guard; treat a non-clean guard as **void**, not a result.
- Stage **only** `test/**` and docs in pre-freeze commits — never `src` — so a transient
  working-tree mutant from a neighbour session cannot leak into a commit.
- Do not launch mutant-swap loops that can hit a command timeout; use fast, targeted,
  single-mutant validations that finish well under it.

## Consequences

- Mutation is slightly slower to start (worktree add + one compile) — acceptable; correctness of the
  freeze target is non-negotiable.
- The body `src` is now structurally unreachable from a mutation job; the three incident classes
  above cannot recur silently.
