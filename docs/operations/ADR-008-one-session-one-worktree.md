# ADR-008 — One session = one worktree; measurement runs only on a frozen, isolated tree

- **Status:** Accepted (2026-07-13)
- **Supersedes/relates:** ADR-006 (local audit harness as source of truth)
- **Enforced by:** `scripts/clean-tree-guard.sh`, `scripts/guarded-analysis.sh`,
  `scripts/contract-audit.sh` (Stage 0a + Stage Z), `scripts/mutation-test.sh`,
  regression suite `scripts/measurement-guard.test.sh` (fixtures G–K).

## Context — the incident

On 2026-07-13 two Claude Code sessions were found operating on the **same** working tree
(`/workspaces/sixx-vault`) at the same time:

- session `f0fb3c76` / later `9b7933f9` (pid 1574) had checked out `audit/round8-hardening`
  and was **editing `src/`** (Round 8 hardening: `R8-1`, `R8-2`/`M-04`);
- a second session was asked to **measure** (mutation, Slither/Aderyn, invariants).

Because both shared one `.git` and one checkout, the measuring session was reading a tree that
the editing session was rewriting underneath it. This is the **root cause** of the two
"the measuring instrument lied" bugs seen earlier in the audit:

1. **mutation false-kill** — per-mutant verdicts computed while another process changed `src/`;
2. **Aderyn mutant-phantom** — a static analyser read a tree that still had a mutant swapped in.

These were originally treated as one-off accidents. They are not: sharing a working tree makes
contaminated measurements the *default* outcome whenever two sessions overlap. We treat it as a
**structural defect** and remove the possibility mechanically.

> Forensic note: the marquee mutation stat (94.6% / 1090, killed 1031 / survived 59, committed
> `71afda4`) was checked against this defect. Session-transcript timestamps show it ran entirely
> inside a **single-session** window (`f0fb3c76`, 2026-07-12 16:31–23:27 UTC) with no concurrent
> session; the shared-tree overlap first occurred ~8 h later on 07-13. The stat is therefore
> **valid** and was not contaminated — but the guard below now makes that a machine-checked
> property of every future run instead of a forensic argument after the fact.

## Decision

1. **One session = one worktree.** A Claude session that will build/test/measure MUST work in
   its **own** `git worktree`. Sharing a single working tree across concurrent sessions is
   prohibited.
2. **Measurement runs only on a dedicated, isolated, verified-frozen tree.** Analysis
   (Slither/Aderyn/Halmos), mutation, coverage and invariants may run **only** in a dedicated
   *linked* worktree, and only while `git status` is clean and the source hash is frozen for the
   whole run.
3. **A moved source hash voids the run.** If any source input changes between the start and end
   of a measurement, the results are discarded and the run FAILs. No `|| true`; `exit != 0` is
   always FAIL.

## Mechanism (how it's enforced)

| Guard | What it proves | Failure |
|---|---|---|
| `clean-tree-guard.sh --require-isolated` | we are in a **linked** worktree (git-dir ≠ common git-dir), tree is clean (minus tracked `out/`+`cache/` build artifacts), no `gambit_out/`·`mutants/`·`*.mutant` | exit 1 |
| `clean-tree-guard.sh --print-hash` | deterministic sha256 of every source input (`src/`,`test/`,`script/` `*.sol` + `foundry.toml`/`remappings.txt`/`echidna.yaml`) | — (snapshot primitive) |
| `guarded-analysis.sh <label> [--allow-target f] -- <cmd>` | tree clean+isolated at start **and** source hash unchanged across the whole command | exit 6 (start), exit 5 (changed mid-run) |
| `contract-audit.sh` Stage 0a | clean+isolated before any stage runs | `clean-tree` FAIL |
| `contract-audit.sh` Stage Z | source hash identical from Stage 0a → after the last stage | `src-frozen` FAIL |
| `mutation-test.sh` | every **non-target** source file unchanged across the mutant loop (target is legitimately mutated + restored) | exit 5 |

`ALLOW_SHARED_TREE=1` downgrades *only* the isolation requirement to a loud WARN (for a genuine
single-session/CI run where no other session touches the tree); the clean-tree and whole-run
source-freeze checks still apply.

## How to run measurement correctly

```bash
# from the main checkout, create a dedicated worktree pinned to the frozen tip
git worktree add -b audit/<task> /workspaces/sixx-vault-<task> main
cd /workspaces/sixx-vault-<task>
git submodule update --init --recursive        # populate lib/ from existing objects (offline)

# run the full local audit — refuses to run unless this is an isolated, clean worktree
./scripts/contract-audit.sh                    # add --mutation for the slow mutation gate

# when done
git worktree remove /workspaces/sixx-vault-<task>
```

## Consequences

- Concurrent sessions can no longer silently contaminate each other's measurements; an overlap
  now produces a hard FAIL (`clean-tree`, `src-frozen`, or exit 5/6), never a fake green.
- A small operational cost: measurement needs a worktree + one offline `submodule update`.
- The regression suite (`measurement-guard.test.sh` G–K) pins these behaviours so the class of
  bug cannot silently return a third time.
