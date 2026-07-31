#!/bin/bash
# =====================================================================
# 人生OS 整合性チェック（機械層）
# 整合性監査の機械層。オンデマンド実行。
# startup-check との役割分担: あちら＝毎回の健康診断（symlink等）、
# こちら＝ルール変更後の精密検査（パス参照・台帳突合）。
# 検出のみ行い、修正はしない（修正はオーナー承認後に秘書役が行う）。
# 歴史記録（日次/週次ログ・decisions・reviews・ideas・mindset-log）は
# 「当時の記述」のため対象外。
# BSD/GNU 両対応。パスはスクリプト位置から導出。
# =====================================================================

C="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

echo "🔍 整合性チェック（機械層） $(TZ=Asia/Tokyo date '+%Y-%m-%d %H:%M') JST"
echo "----------------------------------------"

# --- 対象mdの収集（歴史記録・使い捨てキャッシュを除外） ---
targets() {
  find "$C" -name '*.md' \
    -not -path '*/node_modules/*' \
    -not -path "$C/secretary/notes/2*" \
    -not -path "$C/secretary/notes/calendar-*" \
    -not -path "$C/secretary/notes/claude-updates-*" \
    -not -path "$C/secretary/notes/weekly/*" \
    -not -path "$C/secretary/notes/decisions.md" \
    -not -path "$C/secretary/notes/claude-app-import/*" \
    -not -path "$C/secretary/ideas/*" \
    -not -path "$C/strategy/reviews/*" \
    -not -path "$C/strategy/mindset-log.md" \
    2>/dev/null
  [ -f "$HOME/.claude/CLAUDE.md" ] && echo "$HOME/.claude/CLAUDE.md"
}

# --- 1. mdが参照するパスの実在チェック（ローカルMacのみ） ---
if [ "$(uname)" = "Darwin" ]; then
  while IFS= read -r f; do
    while IFS=: read -r ln path; do
      [ -n "$path" ] || continue
      # 対象外: プレースホルダ・日付テンプレ／ワイルドカード切れ（末尾-）／
      # スペース入りパス（iCloudのMobile Documents等・regexで拾えない）／
      # 実行時にDLされる使い捨てファイル（Downloads）
      case "$path" in
        *YYYY*|*'<'*|*…*|*-) continue ;;
        */Mobile|*/Downloads/*) continue ;;
      esac
      p="${path/#\~/$HOME}"
      p="${p%.}"
      [ -e "$p" ] || echo "⚠️ ${f#"$C"/}:${ln} 実在しないパス参照: $path" >> "$TMP"
    done < <(grep -noE '(/Users/[^/ ]+|~|\$HOME)/[A-Za-z0-9._/-]+' "$f" 2>/dev/null)
  done < <(targets)
else
  echo "💡 パス実在チェックはローカルMacのみ（クラウドでは対象外）"
fi

# --- 2. 台帳と実体の突合 ---
# skills実体 → SKILLS.md（自作）/ ARSENAL.md（武器）のどちらかに記載があるか
for d in "$C/.claude/skills"/*/; do
  [ -d "$d" ] || continue
  name=$(basename "$d")
  grep -q "$name" "$C/SKILLS.md" "$C/ARSENAL.md" 2>/dev/null \
    || echo "⚠️ .claude/skills/$name が SKILLS.md / ARSENAL.md のどちらにも記載なし" >> "$TMP"
done

# agents実体 → 組織ルールの部署一覧に記載があるか
for f in "$C/.claude/agents"/*.md; do
  [ -e "$f" ] || continue
  name=$(basename "$f" .md)
  grep -q "$name" "$C/CLAUDE.md" \
    || echo "⚠️ .claude/agents/$name が CLAUDE.md に記載なし" >> "$TMP"
done

# 部署一覧のsubagent → 実体があるか（表の行のみから抽出）
while IFS= read -r ag; do
  [ -f "$C/.claude/agents/$ag.md" ] \
    || echo "⚠️ 部署一覧の $ag に対応する .claude/agents/$ag.md が実体なし" >> "$TMP"
done < <(grep -E '^\|' "$C/CLAUDE.md" | grep -oE 'company-[a-z]+' | sort -u)

# --- 結果 ---
if [ -s "$TMP" ]; then
  sort -u "$TMP"
  echo "----------------------------------------"
  echo "検出 $(sort -u "$TMP" | wc -l | tr -d ' ') 件。歴史記録由来・意図的残置かは秘書役が判断し、修正はオーナー承認後。"
else
  echo "✅ 機械層チェック: 指摘なし"
fi
