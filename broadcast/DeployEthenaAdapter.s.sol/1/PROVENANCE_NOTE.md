# ⚠️ PROVENANCE NOTE — DeployEthenaAdapter (chain 1 / Ethereum mainnet)

> 2026-07-16・D-C 確定(SHIN)。本ディレクトリの broadcast 記録は **すべて廃棄予定の pre-hardening 版**。
> 監査対象・production は別(下記)。deploy-gate / 外部監査人は `run-latest.json` を**そのまま信用しないこと**。

## この dir にある2つの deploy run(両方 source commit `6bfe816` = round-8 v2 ハードニング前)

| run file | Timelock | AdapterRegistry | SIXXVault | EthenaSUSDeAdapter | 状態 |
|---|---|---|---|---|---|
| `run-1783670478779.json`(#1) | `0x8cd71c5a…9895` | `0xf49ca40f…3473` | `0xb7bd3e44…d8df` | `0xbf555b98…54ec` | **live activate 済**(Safe→Timelock nonce13, 2026-07-16 19:03 JST)だが **pre-hardening = 廃棄予定** |
| `run-1783671828541.json`(#2)=**`run-latest.json`** | `0x2ae6b837…` | `0x0f44fc95…` | `0x933537d1…` | `0x896becfd…` | **orphan(未 activate)= 廃棄予定** |

## 是正事項(D-C)
1. **`run-latest.json` は #2(orphan・非 live)を指す** — live は #1。ただし **#1/#2 とも `6bfe816`(ハードニング前)= 廃棄**。どちらも production ではない。
2. **旧 live #1(`0xb7bd3e44…`/`0xbf555b98…`)は launch しない**(ユーザー未開放を維持)。P3 TWAP≥15min 復元・round-8 v2 ハードニング・escalate#1 recall-haircut を**含まない**旧版のため。
3. **監査/production は最新ハードニング版に一本化**:draft 集約ブランチ `audit/scope-core-ethena-pendle`(core4+Ethena+Pendle、P3 復元込み)を **SHIN が再凍結タグ付与 → 外部監査 → その版を mainnet 再デプロイ + Timelock 結線** して production レールとする。
4. production デプロイ実施時に、その **新 broadcast 記録**をここへ追加し、**`run-latest` が production を指す**状態へ更新すること(`docs/operations/mainnet-gate.md`「デプロイ対象=再凍結タグ=監査提出版が一致」)。

参照: `memory/decisions.md` D-A / D-C。
