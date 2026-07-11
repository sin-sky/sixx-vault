#!/bin/bash
# 引数 IF（TASK-2026-06-12-002 / ADR-001 準拠）:
#   経路A（Claude Code hook spawn）= 第1引数が既知 EVENT キーワード（stop / danger）。
#     - settings.json Stop hook:        notify-shin.sh stop
#     - guard-dangerous.sh:             notify-shin.sh danger "オンチェーン操作を検出: ..."
#   経路B（agent / 人間が scripts/ ラッパー経由）= 第1引数がメッセージ本体。
#     - developer.md / architect.md:    notify-shin.sh "task-completed: ..." / "QUESTION: ..." 等
#   → 第1引数が既知 EVENT キーワードに一致するかで分岐し、両経路を両立させる。
#     既知キーワード以外は全てメッセージ本体とみなし、EVENT は接頭辞から導出する。
case "${1:-stop}" in
  stop|danger)
    # 経路A: 第1=EVENT 種別 / 第2=メッセージ（後方互換: 2引数形式を温存）
    EVENT="$1"
    MESSAGE="${2:-Claude Codeセッションが終了しました}"
    ;;
  *)
    # 経路B: 第1=メッセージ本体。EVENT は接頭辞から導出（該当なしは info）
    MESSAGE="$1"
    case "$MESSAGE" in
      QUESTION:*|ARCH-QUESTION:*)                   EVENT="question" ;;
      task-completed:*|parallel-task-completed:*)   EVENT="done" ;;
      REVIEW-REJECTED:*)                            EVENT="rejected" ;;
      AUDIT-COMPLETED:*|audit-*)                    EVENT="audit" ;;
      *)                                            EVENT="info" ;;
    esac
    ;;
esac

TIMESTAMP=$(date '+%Y-%m-%d %H:%M')
LOG_FILE="$(git rev-parse --show-toplevel)/.claude/hooks/notify.log"

# ログ追記（ファイル追記はインジェクション面が低いため $MESSAGE をそのまま記録）
echo "[$TIMESTAMP] [$EVENT] $MESSAGE" >> "$LOG_FILE"

# 表示テキスト（EVENT 込み）。$MESSAGE には guard 経路の $INPUT 由来の任意文字列
# （" \ 改行 等）が混入しうるため、以降の JSON / AppleScript は防御的にエスケープする。
SLACK_TEXT="🔔 *SIXX* [$EVENT] $MESSAGE"

# Slack Webhook（設定済みの場合）— JSON は安全生成
if [ -n "${SIXX_SLACK_WEBHOOK:-}" ]; then
  if command -v jq >/dev/null 2>&1; then
    # jq が値を安全にエスケープ
    PAYLOAD=$(jq -nc --arg t "$SLACK_TEXT" '{text:$t}')
  else
    # jq 不在環境（Mac/Codespaces 双方を想定）へのフォールバック: 手動エスケープ
    # 順序重要: バックスラッシュを最初に escape（後続の置換を二重 escape しない）
    esc=$SLACK_TEXT
    esc=${esc//\\/\\\\}
    esc=${esc//\"/\\\"}
    esc=${esc//$'\n'/\\n}
    esc=${esc//$'\r'/\\r}
    esc=${esc//$'\t'/\\t}
    PAYLOAD="{\"text\":\"$esc\"}"
  fi
  curl -s -X POST -H 'Content-type: application/json' \
    --data "$PAYLOAD" \
    "$SIXX_SLACK_WEBHOOK" > /dev/null 2>&1
fi

# macOS通知 — AppleScript インジェクション対策として env 経由で渡し
# AppleScript 側は `system attribute` で参照（文字列リテラル補間を避ける）
SIXX_NOTIFY_MSG="$MESSAGE" SIXX_NOTIFY_TITLE="SIXX [$EVENT]" osascript \
  -e 'display notification (system attribute "SIXX_NOTIFY_MSG") with title (system attribute "SIXX_NOTIFY_TITLE") sound name "Glass"' \
  2>/dev/null || true
echo "[$EVENT] 通知: $MESSAGE"
