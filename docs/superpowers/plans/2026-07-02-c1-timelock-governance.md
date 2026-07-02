# C-1 TimelockController ガバナンス＋緊急停止 guardian Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Vault の governance を OZ TimelockController(48h) に移し、`setEmergencyShutdown` のみ新規 `guardian`(Safe) が即時バイパスできるようにして、監査 CRITICAL C-1（単一鍵で TVL 100% 即時ドレイン可）を塞ぐ。

**Architecture:** `SIXXVault` に `guardian` state を追加。`setEmergencyShutdown` を「ON = guardian または governance が即時／OFF = governance のみ」に非対称化。`setGuardian` は onlyGovernance。`AdapterRegistry` はコード無変更で governance に Timelock を渡すだけ。`Deploy.s.sol` が TimelockController をデプロイし vault/registry の governance に配線、guardian には各チェーンの 2-of-3 Safe を設定。

**Tech Stack:** Foundry / Solidity 0.8.28 / OpenZeppelin v5（`TimelockController` は `lib/openzeppelin-contracts/contracts/governance/TimelockController.sol` に存在）。

## Global Constraints

- Solidity `^0.8.28`。既存パターン（`onlyGovernance` modifier・2段 governance 移行・`H-*`/`M-*` 不変条件）を保持。
- **全 forge コマンドに `FOUNDRY_EVM_VERSION=cancun` を付ける**（この Codespace は既定 osaka で panic — [[sixx-vault-forge-on-old-glibc]]）。
- 既存の非fork スイート（現 61 テスト）に回帰を出さない。`out/`・`cache/` はコミットしない。
- イベントは interface（`ISIXXVault.sol`）に宣言する既存慣習に従う。
- コミットメッセージ末尾に `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`。
- **本修正は非 upgradeable ゆえ次の再デプロイに乗る。mainnet デプロイ・資金移行は SHIN のオンチェーン操作（スコープ外）。**
- 確定 Safe アドレス（LATEST・2-of-3）：Eth `0x4d71aCE4612AB3B71423b454e21c0Bd03c4F8fE0`／Arb `0xd388aC46E7a763d5eaFb73b735292c6A46B5BAC0`／BNB `0x81E85C9F3FdE1ceE38cD3DA9bbAa6212F01D196D`。

---

## File Structure

- `src/interfaces/ISIXXVault.sol` — MODIFY: `guardian()`/`setGuardian()` view+外部関数、`GuardianChanged` event 追加。
- `src/core/SIXXVault.sol` — MODIFY: `guardian` state、constructor に `guardian_` 引数＋zero-check、`setGuardian`、`setEmergencyShutdown` の access 分岐。
- `script/Deploy.s.sol` — MODIFY: TimelockController デプロイ＋governance=timelock／guardian=safe 配線、Safe/minDelay 定数。
- `test/SIXXVault.t.sol` — MODIFY: `guardian` actor 追加、constructor 呼び出し更新、guardian/emergency の unit テスト追加。
- `test/TimelockGovernance.t.sol` — CREATE: in-process TimelockController 統合テスト。

---

## Task 1: guardian state・constructor・setGuardian・interface

**Files:**
- Modify: `src/interfaces/ISIXXVault.sol`
- Modify: `src/core/SIXXVault.sol:65-79`（constructor）、`:81-88`（modifiers 付近に setGuardian）
- Modify: `script/Deploy.s.sol`（constructor 呼び出し2箇所・build を green に保つための最小更新）
- Test: `test/SIXXVault.t.sol:19-66`（actor＋setUp）と新規テスト

**Interfaces:**
- Produces: `SIXXVault.guardian() -> address`（public state getter）、`SIXXVault.setGuardian(address newGuardian)`（onlyGovernance）、`event GuardianChanged(address indexed oldGuardian, address indexed newGuardian)`、constructor 第7引数 `address guardian_`。

- [ ] **Step 1: interface に guardian API＋event を追加**

`src/interfaces/ISIXXVault.sol` の governance view 群（`governance()` 付近 68行目以降）に追加:
```solidity
    /// @notice The guardian address, allowed to trigger emergency shutdown immediately.
    function guardian() external view returns (address);

    /// @notice Update the guardian. Governance-only (behind the Timelock).
    function setGuardian(address newGuardian) external;
```
event 群（`event GovernanceAccepted(...)` の後）に追加:
```solidity
    event GuardianChanged(address indexed oldGuardian, address indexed newGuardian);
```

- [ ] **Step 2: 失敗するテストを書く（constructor zero-guardian revert＋setGuardian 一式）**

`test/SIXXVault.t.sol` の actor に `address guardianAddr = address(0x6042D);` を追加（21-24行目付近）。既存 `setUp` の constructor 呼び出し（45-52行目）を、第7引数 `guardianAddr` 付きに更新:
```solidity
        vault = new SIXXVault(
            IERC20(address(usdc)),
            "SIXX Stable Yield",
            "sxUSDC",
            governance,
            address(registry),
            feeRcpt,
            guardianAddr
        );
```
ファイル末尾付近に新規テストを追加:
```solidity
    function test_constructor_reverts_on_zero_guardian() public {
        vm.expectRevert(bytes("VAULT: zero guardian"));
        new SIXXVault(
            IERC20(address(usdc)), "n", "s", governance, address(registry), feeRcpt, address(0)
        );
    }

    function test_guardian_initialized() public view {
        assertEq(vault.guardian(), guardianAddr);
    }

    function test_setGuardian_only_governance() public {
        vm.prank(alice);
        vm.expectRevert(bytes("VAULT: not governance"));
        vault.setGuardian(bob);
    }

    function test_setGuardian_rejects_zero() public {
        vm.prank(governance);
        vm.expectRevert(bytes("VAULT: zero guardian"));
        vault.setGuardian(address(0));
    }

    function test_setGuardian_updates_and_emits() public {
        vm.expectEmit(true, true, false, false);
        emit ISIXXVault.GuardianChanged(guardianAddr, bob);
        vm.prank(governance);
        vault.setGuardian(bob);
        assertEq(vault.guardian(), bob);
    }
```
（`ISIXXVault` は SIXXVault.t.sol に未 import＝確認済。`import {ISIXXVault} from "../src/interfaces/ISIXXVault.sol";` を import 群〔4-10行目〕に追加すること。）

- [ ] **Step 3: テストが（コンパイルエラーで）失敗するのを確認**

Run: `FOUNDRY_EVM_VERSION=cancun forge build`
Expected: FAIL — `SIXXVault` constructor に第7引数が無い／`guardian()` `setGuardian` 未定義でコンパイルエラー。

- [ ] **Step 4: SIXXVault に guardian を実装**

`src/core/SIXXVault.sol` state 宣言（`address public override governance;` 付近36-37行目）に追加:
```solidity
    address public override guardian;
```
constructor（65-79行目）に第7引数と検証・代入を追加:
```solidity
    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address governance_,
        address adapterRegistry_,
        address feeRecipient_,
        address guardian_
    ) ERC4626(asset_) ERC20(name_, symbol_) {
        require(governance_ != address(0), "VAULT: zero governance");
        require(feeRecipient_ != address(0), "VAULT: zero fee recipient");
        require(guardian_ != address(0), "VAULT: zero guardian");
        governance = governance_;
        adapterRegistry = adapterRegistry_;
        feeRecipient = feeRecipient_;
        guardian = guardian_;
        _lastHarvestTimestamp = block.timestamp;
    }
```
governance 2段移行の近く（`proposeGovernance` 付近391行目以降）に setGuardian を追加:
```solidity
    function setGuardian(address newGuardian) external override onlyGovernance {
        require(newGuardian != address(0), "VAULT: zero guardian");
        emit GuardianChanged(guardian, newGuardian);
        guardian = newGuardian;
    }
```

- [ ] **Step 5: Deploy.s.sol の constructor 呼び出しを build green に保つ最小更新**

`script/Deploy.s.sol` の `new SIXXVault(...)` 2箇所（`_deployAaveV3USDC` と `_deployVenusUSDT`）に第7引数 `deployer` を暫定で追加（Task 3 で Safe に差し替える）:
```solidity
        SIXXVault vault = new SIXXVault(
            IERC20(usdc),
            "SIXX Stable Yield",
            "sxUSDC",
            deployer,
            address(registry),
            deployer,
            deployer
        );
```
（Venus 側も同様に `sxUSDT` ブロックへ第7引数 `deployer` を追加。）

- [ ] **Step 6: テストが通るのを確認**

Run: `FOUNDRY_EVM_VERSION=cancun forge test --match-contract SIXXVaultTest -vvv`
Expected: PASS — 新規5テスト green＋既存回帰なし。

- [ ] **Step 7: Commit**

```bash
git add src/interfaces/ISIXXVault.sol src/core/SIXXVault.sol script/Deploy.s.sol test/SIXXVault.t.sol
git commit -m "feat(vault): guardian ロール＋setGuardian＋constructor 引数を追加（C-1）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: setEmergencyShutdown の非対称アクセス（ON=guardian|gov / OFF=gov）

**Files:**
- Modify: `src/core/SIXXVault.sol:366`（setEmergencyShutdown）
- Test: `test/SIXXVault.t.sol`（新規テスト）

**Interfaces:**
- Consumes: Task 1 の `guardian` state、既存 `governance`。
- Produces: 挙動変更のみ（シグネチャ不変）。ON は `msg.sender == guardian || msg.sender == governance`、OFF は `msg.sender == governance`。

- [ ] **Step 1: 失敗するテストを書く**

`test/SIXXVault.t.sol` に追加:
```solidity
    function test_guardian_can_shutdown_on() public {
        vm.prank(guardianAddr);
        vault.setEmergencyShutdown(true);
        assertTrue(vault.emergencyShutdown());
    }

    function test_guardian_cannot_shutdown_off() public {
        vm.prank(governance);
        vault.setEmergencyShutdown(true);
        vm.prank(guardianAddr);
        vm.expectRevert(bytes("VAULT: not governance"));
        vault.setEmergencyShutdown(false);
    }

    function test_governance_can_toggle_both() public {
        vm.prank(governance);
        vault.setEmergencyShutdown(true);
        assertTrue(vault.emergencyShutdown());
        vm.prank(governance);
        vault.setEmergencyShutdown(false);
        assertFalse(vault.emergencyShutdown());
    }

    function test_third_party_cannot_shutdown() public {
        vm.prank(alice);
        vm.expectRevert(bytes("VAULT: not guardian/gov"));
        vault.setEmergencyShutdown(true);
        vm.prank(alice);
        vm.expectRevert(bytes("VAULT: not governance"));
        vault.setEmergencyShutdown(false);
    }

    function test_guardian_shutdown_still_recalls_and_exempts_lock() public {
        // alice deposits -> funds pushed to adapter, alice locked
        uint256 amt = 1_000 * USDC_6;
        vm.startPrank(alice);
        usdc.approve(address(vault), amt);
        vault.deposit(amt, alice);
        vm.stopPrank();
        // guardian triggers shutdown: recall from adapter + lock exemption
        vm.prank(guardianAddr);
        vault.setEmergencyShutdown(true);
        // alice can withdraw immediately despite lock (B), funds were recalled (A)
        uint256 maxW = vault.maxWithdraw(alice);
        assertGt(maxW, 0, "lock exempt under shutdown");
        vm.prank(alice);
        vault.withdraw(maxW, alice, alice);
    }
```

- [ ] **Step 2: テストが失敗するのを確認**

Run: `FOUNDRY_EVM_VERSION=cancun forge test --match-test test_guardian_can_shutdown_on -vvv`
Expected: FAIL — 現状 `setEmergencyShutdown` は `onlyGovernance` なので guardian 呼び出しが `"VAULT: not governance"` で revert。

- [ ] **Step 3: setEmergencyShutdown の access を分岐化**

`src/core/SIXXVault.sol:366` の関数シグネチャから `onlyGovernance` を除き、冒頭に分岐を追加（既存の `emergencyShutdown = active;` 以降の A/try-catch ロジックは不変）:
```solidity
    function setEmergencyShutdown(bool active) external override nonReentrant {
        if (active) {
            require(msg.sender == guardian || msg.sender == governance, "VAULT: not guardian/gov");
        } else {
            require(msg.sender == governance, "VAULT: not governance");
        }
        emergencyShutdown = active;
        // ... 既存 A/try-catch recall ロジックはそのまま ...
```

- [ ] **Step 4: テストが通るのを確認**

Run: `FOUNDRY_EVM_VERSION=cancun forge test --match-contract SIXXVaultTest -vvv`
Expected: PASS — 新規5テスト green＋既存回帰なし。

- [ ] **Step 5: Commit**

```bash
git add src/core/SIXXVault.sol test/SIXXVault.t.sol
git commit -m "feat(vault): setEmergencyShutdown を ON=guardian即時/OFF=Timelock に非対称化（C-1）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Deploy.s.sol の TimelockController 配線

**Files:**
- Modify: `script/Deploy.s.sol`

**Interfaces:**
- Consumes: Task 1 の constructor 第7引数、既存 `AdapterRegistry(address governance_)`。
- Produces: デプロイ順 Timelock → Registry(gov=timelock) → Vault(gov=timelock, guardian=safe)。

- [ ] **Step 1: import と定数を追加**

`script/Deploy.s.sol` の import に追加:
```solidity
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
```
`Deploy` contract の chain-id 定数群の後に追加:
```solidity
    uint256 internal constant TIMELOCK_MIN_DELAY = 48 hours;

    /// @dev Chain 2-of-3 Safe = Timelock proposer/executor + Vault guardian.
    ///      Testnets have no Safe → fall back to the deployer.
    function _safe(address deployer) internal view returns (address) {
        if (block.chainid == ETH_MAINNET) return 0x4d71aCE4612AB3B71423b454e21c0Bd03c4F8fE0;
        if (block.chainid == ARB_ONE)     return 0xd388aC46E7a763d5eaFb73b735292c6A46B5BAC0;
        if (block.chainid == BNB_MAINNET) return 0x81E85C9F3FdE1ceE38cD3DA9bbAa6212F01D196D;
        return deployer; // testnets
    }

    /// @dev Deploy a TimelockController with the Safe as sole proposer+executor,
    ///      self-administered (admin = address(0)).
    function _deployTimelock(address safe) internal returns (TimelockController) {
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = safe;
        executors[0] = safe;
        return new TimelockController(TIMELOCK_MIN_DELAY, proposers, executors, address(0));
    }
```

- [ ] **Step 2: `_deployAaveV3USDC` を Timelock 配線に更新**

`vm.startBroadcast(deployerPk);` の直後を次に置換（registry/vault の governance を timelock に、guardian を safe に）:
```solidity
        vm.startBroadcast(deployerPk);

        address safe = _safe(deployer);
        TimelockController timelock = _deployTimelock(safe);
        console2.log("Timelock    :", address(timelock));

        AdapterRegistry registry = new AdapterRegistry(address(timelock));
        console2.log("Registry    :", address(registry));

        SIXXVault vault = new SIXXVault(
            IERC20(usdc),
            "SIXX Stable Yield",
            "sxUSDC",
            address(timelock),
            address(registry),
            deployer,      // feeRecipient
            safe           // guardian
        );
        console2.log("SIXXVault   :", address(vault));

        AaveV3USDCAdapter adapter = new AaveV3USDCAdapter(
            usdc, aavePool, aUsdc, address(vault), deployer, 0
        );
        console2.log("Adapter     :", address(adapter));
```
**注意**：`registry.registerAdapter(...)` と `vault.setAdapter(...)` は governance=timelock になったため deployer 直呼びでは revert する。初期 adapter 配線は「Timelock 経由（schedule→48h→execute）」が必要。この初期登録は `SAFE_MIGRATION_RUNBOOK` 系の別オペとし、Deploy スクリプトからは**削除**して次のコメントに置換:
```solidity
        // NOTE: registry.registerAdapter / vault.setAdapter are now governance-gated
        // (governance = Timelock). Do the initial adapter wiring via the Timelock
        // (schedule -> 48h -> execute) from the Safe. See SAFE_MIGRATION_RUNBOOK.
        console2.log("Adapter (register+setAdapter) pending via Timelock:", address(adapter));

        vm.stopBroadcast();
        console2.log("Deploy complete!");
```

- [ ] **Step 3: `_deployVenusUSDT` を同様に更新**

`_deployVenusUSDT` の broadcast ブロックを Step 2 と同型に更新（Timelock デプロイ→Registry(gov=timelock)→Vault(gov=timelock, guardian=safe)→Adapter、registerAdapter/setAdapter は Timelock 経由コメント化）。vault 名は `"SIXX Stable Yield USDT"`/`"sxUSDT"`。

- [ ] **Step 4: build が通るのを確認**

Run: `FOUNDRY_EVM_VERSION=cancun forge build`
Expected: PASS — コンパイル成功。

- [ ] **Step 5: Commit**

```bash
git add script/Deploy.s.sol
git commit -m "feat(deploy): TimelockController(48h) を配線し registry/vault governance を Timelock・guardian を Safe に（C-1）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Timelock 統合テスト（48h 遅延＋緊急バイパス実証）

**Files:**
- Create: `test/TimelockGovernance.t.sol`

**Interfaces:**
- Consumes: `SIXXVault`（Task 1/2）、OZ `TimelockController`、`AdapterRegistry`、`MockAdapter`。

- [ ] **Step 1: 統合テストを書く**

`test/TimelockGovernance.t.sol` を新規作成:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SIXXVault} from "../src/core/SIXXVault.sol";
import {AdapterRegistry} from "../src/core/AdapterRegistry.sol";
import {MockUSDC} from "./SIXXVault.t.sol";
import {MockAdapter} from "./mocks/MockAdapter.sol";

contract TimelockGovernanceTest is Test {
    address safe = address(0x5AFE);
    address alice = address(0xA11CE);

    MockUSDC usdc;
    TimelockController timelock;
    AdapterRegistry registry;
    SIXXVault vault;
    MockAdapter adapter;

    uint256 constant DELAY = 48 hours;

    function setUp() public {
        usdc = new MockUSDC();
        address[] memory ps = new address[](1);
        address[] memory es = new address[](1);
        ps[0] = safe; es[0] = safe;
        timelock = new TimelockController(DELAY, ps, es, address(0));

        registry = new AdapterRegistry(address(timelock));
        vault = new SIXXVault(
            IERC20(address(usdc)), "SIXX Stable Yield", "sxUSDC",
            address(timelock), address(registry), address(0xFEE), safe
        );
        adapter = new MockAdapter(address(usdc), address(vault));
    }

    function test_setAdapter_direct_safe_call_reverts() public {
        vm.prank(safe);
        vm.expectRevert(bytes("VAULT: not governance"));
        vault.setAdapter(address(adapter));
    }

    function test_setAdapter_via_timelock_after_delay() public {
        // register adapter through the timelock first
        bytes memory regData = abi.encodeWithSelector(
            registry.registerAdapter.selector, address(adapter), "DeFi", "Mock"
        );
        _scheduleAndExecute(address(registry), regData);

        // now set the adapter through the timelock
        bytes memory setData = abi.encodeWithSelector(vault.setAdapter.selector, address(adapter));
        _scheduleAndExecute(address(vault), setData);

        assertEq(vault.activeAdapter(), address(adapter));
    }

    function test_emergency_shutdown_bypasses_timelock_via_guardian() public {
        // guardian(safe) calls directly, no schedule/delay
        vm.prank(safe);
        vault.setEmergencyShutdown(true);
        assertTrue(vault.emergencyShutdown());
    }

    function _scheduleAndExecute(address target, bytes memory data) internal {
        bytes32 salt = bytes32(0);
        vm.prank(safe);
        timelock.schedule(target, 0, data, bytes32(0), salt, DELAY);
        vm.warp(block.timestamp + DELAY + 1);
        vm.prank(safe);
        timelock.execute(target, 0, data, bytes32(0), salt);
    }
}
```

- [ ] **Step 2: テストが通るのを確認**

Run: `FOUNDRY_EVM_VERSION=cancun forge test --match-contract TimelockGovernanceTest -vvv`
Expected: PASS — 直呼び revert／schedule→warp→execute で setAdapter 成功／guardian 即時 emergency。
（`MockUSDC` は `SIXXVault.t.sol` 内宣言＝確認済。`import {MockUSDC} from "./SIXXVault.t.sol";` が正。`MockAdapter` は `./mocks/MockAdapter.sol`。）

- [ ] **Step 3: 全スイート回帰確認**

Run: `FOUNDRY_EVM_VERSION=cancun forge test -vvv`
Expected: PASS — 既存61＋本計画の新規テスト全 green（fork テストは RPC 無しでスキップ/別途）。

- [ ] **Step 4: Commit**

```bash
git add test/TimelockGovernance.t.sol
git commit -m "test(vault): Timelock 48h 遅延＋guardian 緊急バイパスの統合テスト（C-1）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**1. Spec coverage:**
- §3.1 SIXXVault guardian state/constructor/setEmergencyShutdown/setGuardian/event → Task 1・2 ✅
- §3.2 ISIXXVault 更新 → Task 1 Step 1 ✅
- §3.3 AdapterRegistry コード無変更（governance に Timelock を渡すだけ）→ Task 3 ✅
- §3.4 TimelockController は OZ を使用（自作しない）→ Task 3 import ✅
- §3.5 Deploy.s.sol 配線順（Timelock→Registry→Vault→Adapter）→ Task 3 ✅
- §5 テスト unit(1-6)/integration(7-8)/deploy → Task 1・2（unit）・Task 4（integration）✅。deploy 配線は Task 4 の in-process 統合テストが governance=timelock/guardian=safe を実証（別途 deploy dry-run は本環境で forge script 実行に鍵不要の想定だが省略）。
- §2.2 方向非対称（ON=guardian|gov / OFF=gov）→ Task 2 ✅

**2. Placeholder scan:** TODO/TBD 無し。各コードステップに実コードあり。✅

**3. Type consistency:** `guardian()`/`setGuardian(address)`/`GuardianChanged(address,address)`/constructor 第7引数 `address guardian_` は Task 1〜4 で一貫。revert 文字列 `"VAULT: zero guardian"`/`"VAULT: not guardian/gov"`/`"VAULT: not governance"` は Task 1・2・4 で一致。✅

**留意（実装者へ）**：
- Task 3 で初期 adapter 登録が Deploy から外れる（governance=Timelock 化のため）。これは意図通り（初期配線は Safe→Timelock の schedule→execute オペ）。mainnet 手順は SAFE_MIGRATION_RUNBOOK 側に追記が必要（別タスク・本計画スコープ外）。
- import 元は確認済：`MockUSDC`=`./SIXXVault.t.sol`（同ファイル内宣言）／`MockAdapter`=`./mocks/MockAdapter.sol`／`ISIXXVault`=`../src/interfaces/ISIXXVault.sol`（Task 1 で test に追加）。
