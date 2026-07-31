#!/bin/bash
# =====================================================================
# 人生OS 起動チェックスクリプト
# /company 起動時に 秘書役 が最初に実行する。チェックの判定ロジックの正はこのファイル。
# 出力の見方: ✅=OK / 💡=軽い案内 / ⚠️=要対応 / 🔥=期限超過 / 🎯=マイルストーン / ❓=今月の問い
# 💬 REMARK は 秘書役 への内部シグナル（ダッシュボードには転記しない）。
# BSD date（macOS）/ GNU date（クラウドVM）両対応。パスはスクリプト位置から導出。
# =====================================================================

C="$(cd "$(dirname "$0")/.." && pwd)"
TODAY=$(date +%Y-%m-%d)
NOW_EPOCH=$(date +%s)
NOW_JST=$(TZ=Asia/Tokyo date '+%H:%M')
THIS_WEEK=$(date +%G-W%V)

if date -v+0d >/dev/null 2>&1; then IS_BSD=1; else IS_BSD=0; fi
if [ "$IS_BSD" -eq 1 ]; then
  PREV_MONTH=$(date -v-1m +%Y-%m)
else
  PREV_MONTH=$(date -d "-1 month" +%Y-%m)
fi

day_epoch() {  # 引数: YYYY-MM-DD → epoch秒（不正なら空）
  if [ "$IS_BSD" -eq 1 ]; then
    date -j -f "%Y-%m-%d" "$1" +%s 2>/dev/null
  else
    date -d "$1" +%s 2>/dev/null
  fi
}

week_of() {  # 引数: YYYY-MM-DD → ISO週（YYYY-WNN）
  if [ "$IS_BSD" -eq 1 ]; then
    date -j -f "%Y-%m-%d" "$1" +%G-W%V 2>/dev/null
  else
    date -d "$1" +%G-W%V 2>/dev/null
  fi
}

days_since() {  # 引数: YYYY-MM-DD → 経過日数を echo（未来なら負数、不正なら空）
  local d_epoch
  d_epoch=$(day_epoch "$1") || return
  [ -n "$d_epoch" ] || return
  echo $(( (NOW_EPOCH - d_epoch) / 86400 ))
}

echo "📅 今日: ${TODAY}（$(date +%a)）現在 ${NOW_JST} JST"
echo "----------------------------------------"

# --- 0. 今月の問い（strategy/question.md・常に1つ） ---
q_file="$C/strategy/question.md"
if [ ! -f "$q_file" ]; then
  echo "💡 今月の問い: 未設定（strategy/question.md がない）→ 月次レビューで設定"
else
  q_line=$(grep -m1 '^問い:' "$q_file" | sed 's/^問い: *//')
  if [ -z "$q_line" ]; then
    echo "⚠️ 今月の問い: question.md に「問い:」行がない → フォーマットを直す"
  else
    echo "❓ 今月の問い: ${q_line}"
    q_set=$(echo "$q_line" | grep -oE '設定: [0-9]{4}-[0-9]{2}-[0-9]{2}' | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
    q_d=""
    [ -n "$q_set" ] && q_d=$(days_since "$q_set")
    [ -n "$q_d" ] && [ "$q_d" -gt 40 ] && echo "⚠️ 今月の問い: 設定から${q_d}日経過 → 月次レビューで交代 or 継続を判断"
  fi
fi
echo "----------------------------------------"

# --- 1. プロジェクト 次のマイルストーン（active台帳のみ） ---
echo "■ プロジェクト"
for f in "$C"/projects/*.md; do
  base=$(basename "$f" .md)
  case "$base" in CLAUDE|_template) continue ;; esac
  grep -m1 -q 'ステータス.*: *active' "$f" || continue
  line=$(grep -m1 '次のマイルストーン' "$f" | sed -E 's/^.*次のマイルストーン\*{0,2}: *//')
  if [ -z "$line" ]; then
    echo "⚠️ [$base] 次のマイルストーン欄がない（台帳に追記する）"
    continue
  fi
  case "$line" in
    未設定*) echo "⚠️ [$base] マイルストーン未設定 → オーナーと決める" ;;
    なし*) : ;;
    *)
      due=$(echo "$line" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}')
      d=""
      [ -n "$due" ] && d=$(days_since "$due")
      if [ -n "$d" ] && [ "$d" -gt 0 ]; then
        echo "🔥 [$base] 期限超過: $line"
      elif [ -n "$d" ] && [ "$d" -ge -30 ]; then
        echo "🎯 [$base] (30日以内) $line"
      else
        echo "🎯 [$base] $line"
      fi
      ;;
  esac
done
echo "----------------------------------------"
echo "■ リマインド"

# セットアップ中は「まだ達成しようがないもの」を出さない。
# SETUP.md は導入が終わったら削除する設計なので、その有無が「導入中か」の判定になる
# （新しい状態ファイルは作らない）。入れた初日に、先月の月次レビューが無いことや
# 使っていない部署の未作成を並べても、直せる人がいない。
SETTING_UP=0
[ -f "$C/SETUP.md" ] && SETTING_UP=1

# --- 2. カレンダーキャッシュ ---
if [ -f "$C/secretary/notes/calendar-${TODAY}.md" ]; then
  echo "✅ カレンダー: 本日キャッシュ済み → notes/calendar-${TODAY}.md を読む"
elif [ "$SETTING_UP" -eq 0 ]; then
  echo "⚠️ カレンダー: 未取得 → 繋いでいる場合は今日〜7日後を取得しキャッシュ保存"
fi

# --- 3. 週次圧縮（今週以外の日次ログが残っていないか） ---
stale=""
for f in "$C"/secretary/notes/????-??-??.md; do
  [ -e "$f" ] || continue
  d=$(basename "$f" .md)
  w=$(week_of "$d")
  [ -n "$w" ] && [ "$w" != "$THIS_WEEK" ] && stale="$stale $(basename "$f")"
done
if [ -n "$stale" ]; then
  echo "⚠️ 週次圧縮: 前週以前の日次ログが残っている →${stale} （「週次圧縮して」・圧縮後に git commit）"
else
  echo "✅ 週次圧縮: 残なし"
fi

# --- 4. 月次レビュー（先月分。実施されるまで毎回通知） ---
if [ -f "$C/strategy/reviews/${PREV_MONTH}.md" ]; then
  echo "✅ 月次レビュー: ${PREV_MONTH} 実施済み"
elif [ "$SETTING_UP" -eq 0 ]; then
  echo "⚠️ 月次レビュー: ${PREV_MONTH} 分が未実施（mindset精錬含む）→「月次レビューして」"
fi

# --- 5. mindset 精錬の鮮度（35日超で通知） ---
# まだ作っていない段階でも生のエラーを出さない（雛形のままなら日付が入っていないので静かに通る）
last_refine=$(grep -oE '最終精錬: [0-9]{4}-[0-9]{2}-[0-9]{2}' "$C/strategy/mindset.md" 2>/dev/null | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
if [ -n "$last_refine" ]; then
  d=$(days_since "$last_refine")
  if [ -n "$d" ] && [ "$d" -gt 35 ]; then
    echo "⚠️ mindset精錬: 最終 ${last_refine}（${d}日前）→ mindset-log が溜まっている（月次レビューとセット）"
  else
    echo "✅ mindset精錬: 最終 ${last_refine}"
  fi
fi

# --- 6. 家計月次（先月分） ---
if [ ! -d "$C/finance" ]; then
  echo "💡 家計月次: スキップ（finance/ はローカルのみ・ここはクラウド環境）"
elif [ -f "$C/finance/monthly/${PREV_MONTH}.md" ]; then
  echo "✅ 家計月次: ${PREV_MONTH} 作成済み"
elif [ "$SETTING_UP" -eq 0 ]; then
  echo "⚠️ 家計月次: ${PREV_MONTH} 分が未作成 → 家計簿のCSVを用意して集計する"
fi

# --- 7. 自動メンテ（auto-maintain）稼働状況 ---
if [ "$(uname)" != "Darwin" ]; then
  echo "💡 自動メンテ: ローカルMac側で稼働（クラウドでは対象外）"
else
AM_LOG="$HOME/Library/Logs/company-auto-maintain.log"
if [ ! -f "$AM_LOG" ]; then
  echo "⚠️ 自動メンテ: 実行記録なし → launchd登録を確認（scripts/auto-maintain.sh）"
else
  am_last=$(tail -1 "$AM_LOG")
  am_date=$(echo "$am_last" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}')
  am_d=""
  [ -n "$am_date" ] && am_d=$(days_since "$am_date")
  if [ -n "$am_d" ] && [ "$am_d" -gt 7 ]; then
    echo "⚠️ 自動メンテ: 最終実行 ${am_date}（${am_d}日前）→ launchd登録を確認"
  else
    echo "✅ 自動メンテ: ${am_last#* }（最終 ${am_date}）"
  fi
  if echo "$am_last" | grep -q "FAIL"; then
    echo "⚠️ 自動メンテ: 直近実行にFAILあり → ~/Library/Logs/company-auto-maintain.log を確認"
  fi
fi
fi

# --- 8. 機微ミラー（sensitive-mirror）鮮度（対話セッション内の手動実行のみ。7日超で通知） ---
if [ "$(uname)" != "Darwin" ]; then
  echo "💡 機微ミラー: ローカルMac側で運用（クラウドでは対象外）"
else
MIRROR_STATE="$HOME/Library/Application Support/company-auto-maintain/last-mirror-date"
if [ ! -f "$MIRROR_STATE" ]; then
  echo "⚠️ 機微ミラー: 実行記録なし → 週次圧縮時に秘書役との対話セッション中で手動実行（secretary/CLAUDE.md「週次圧縮」参照）"
else
  mirror_date=$(head -1 "$MIRROR_STATE" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
  mirror_d=""
  [ -n "$mirror_date" ] && mirror_d=$(days_since "$mirror_date")
  if [ -n "$mirror_d" ] && [ "$mirror_d" -gt 7 ]; then
    echo "⚠️ 機微ミラー: 最終実行 ${mirror_date}（${mirror_d}日前）→ 週次圧縮時に手動実行（secretary/CLAUDE.md）"
  else
    echo "✅ 機微ミラー: 最終実行 ${mirror_date}"
  fi
fi
fi

# --- 9. symlink整合（スキル・agentの実体は人生OS、~/.claudeは取り付け口） ---
if [ "$(uname)" != "Darwin" ]; then
  echo "💡 symlink: クラウドでは対象外（repo直下の .claude/ が直接効く）"
else
  sl_ng=""
  for kind in skills agents; do
    for src in "$C/.claude/$kind"/*; do
      [ -e "$src" ] || continue
      name=$(basename "$src")
      link="$HOME/.claude/$kind/$name"
      if [ ! -L "$link" ] || [ "$(readlink "$link")" != "$src" ]; then
        sl_ng="$sl_ng $kind/$name"
      fi
    done
    # 孤児symlink（実体が消えたリンク）
    for link in "$HOME/.claude/$kind"/*; do
      [ -L "$link" ] && [ ! -e "$link" ] && sl_ng="$sl_ng 孤児:$kind/$(basename "$link")"
    done
  done
  if [ -n "$sl_ng" ]; then
    echo "⚠️ symlink: 不整合 →${sl_ng} （実体は ${C}/.claude/、~/.claude に ln -s で張り直す）"
  else
    n_sk=$(ls "$C/.claude/skills" | wc -l | tr -d ' ')
    n_ag=$(ls "$C/.claude/agents" | wc -l | tr -d ' ')
    echo "✅ symlink: skills ${n_sk}・agents ${n_ag} 整合"
  fi
fi

# --- 10. git 未コミット ---
changes=$(git -C "$C" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
last_commit=$(git -C "$C" log -1 --format=%cs 2>/dev/null)
if [ "${changes:-0}" -gt 0 ]; then
  d=""
  [ -n "$last_commit" ] && d=$(days_since "$last_commit")
  echo "💡 git: 未コミット ${changes} 件（最終コミット ${last_commit:-なし}・${d:-?}日前）→ 週次圧縮時にまとめて commit"
fi

# --- 11. 💬 REMARK（秘書役への内部シグナル・1日1件・クールダウン3日） ---
# 「言うことがある日」の検出だけを機械層で行う。発火した日だけ 秘書役 が素材を読んで地の文で書く。
# 出力行はダッシュボードに転記しない（行末に明示）。イベント優先: E3 > E2 > E4 > E1。
if [ "$(uname)" = "Darwin" ]; then
  STATE_DIR="$HOME/Library/Application Support/company-auto-maintain"
  REMARK_STATE="$STATE_DIR/last-remark-date"
  STARTUP_STATE="$STATE_DIR/last-startup-date"

  # 前回起動からの経過（E2判定用。状態ファイルの更新はこの節の最後）
  startup_gap=""
  if [ -f "$STARTUP_STATE" ]; then
    last_startup=$(head -1 "$STARTUP_STATE" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
    [ -n "$last_startup" ] && startup_gap=$(days_since "$last_startup")
  fi

  # 共通ゲート: 前回の発火から3日未満なら全イベント不発（定型化を防ぐ主装置）
  remark_ok=1
  if [ -f "$REMARK_STATE" ]; then
    last_remark=$(head -1 "$REMARK_STATE" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
    if [ -n "$last_remark" ]; then
      rk_d=$(days_since "$last_remark")
      [ -n "$rk_d" ] && [ "$rk_d" -lt 3 ] && remark_ok=0
    fi
  fi

  remark_line=""

  # 優先1: E3 過去の同日（1ヶ月前→3ヶ月前 / growth-log→ideas→mindset-log・週次フォールバックなし）
  if [ "$remark_ok" -eq 1 ]; then
    for back in 1 3; do
      [ -n "$remark_line" ] && break
      if [ "$IS_BSD" -eq 1 ]; then
        pd=$(date -v-"${back}"m +%Y-%m-%d)
      else
        pd=$(date -d "-${back} month" +%Y-%m-%d)
      fi
      [ -n "$pd" ] || continue
      span="${back}ヶ月前"
      gl="$C/life/mental/growth-log.md"
      hit=""
      [ -f "$gl" ] && hit=$(grep -m1 "^### ${pd}" "$gl" | sed 's/^### //')
      if [ -n "$hit" ]; then
        remark_line="E3 | 素材: life/mental/growth-log.md（${span} ${hit}）"
        continue
      fi
      idf="$C/secretary/ideas/${pd}.md"
      if [ -f "$idf" ]; then
        hit=$(grep -m1 '^## ' "$idf" | sed 's/^## //')
        remark_line="E3 | 素材: secretary/ideas/${pd}.md（${span} ${hit:-アイデアメモ}）"
        continue
      fi
      hit=$(grep -m1 "^## ${pd}" "$C/strategy/mindset-log.md" 2>/dev/null | sed 's/^## //')
      [ -n "$hit" ] && remark_line="E3 | 素材: strategy/mindset-log.md（${span} ${hit}）"
    done
  fi

  # 優先2: E2 間が空いた（前回の起動から7日以上）
  if [ "$remark_ok" -eq 1 ] && [ -z "$remark_line" ] && [ -n "$startup_gap" ] && [ "$startup_gap" -ge 7 ]; then
    lw=$(ls "$C/secretary/notes/weekly"/*.md 2>/dev/null | tail -1)
    [ -n "$lw" ] && remark_line="E2 | 素材: secretary/notes/weekly/$(basename "$lw")（前回起動から${startup_gap}日）"
  fi

  # 優先3: E4 決定が溜まった（直近7日の decisions.md 新規###が3件以上）
  if [ "$remark_ok" -eq 1 ] && [ -z "$remark_line" ] && [ -f "$C/secretary/notes/decisions.md" ]; then
    recent_days=""
    i=0
    while [ "$i" -lt 7 ]; do
      if [ "$IS_BSD" -eq 1 ]; then rday=$(date -v-"${i}"d +%Y-%m-%d); else rday=$(date -d "-${i} day" +%Y-%m-%d); fi
      recent_days="$recent_days $rday"
      i=$((i + 1))
    done
    dec_n=$(awk -v days=" ${recent_days} " '
      /^## / { if ($2 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) sec = $2; next }
      /^### / { if (sec != "" && index(days, " " sec " ") > 0) n++ }
      END { print n + 0 }' "$C/secretary/notes/decisions.md")
    if [ -n "$dec_n" ] && [ "$dec_n" -ge 3 ]; then
      remark_line="E4 | 素材: secretary/notes/decisions.md（直近7日の新規###が${dec_n}件）"
    fi
  fi

  # 優先4: E1 思考が動いた（mindset-log の mtime が2日以内）
  if [ "$remark_ok" -eq 1 ] && [ -z "$remark_line" ] && [ -f "$C/strategy/mindset-log.md" ]; then
    if [ "$IS_BSD" -eq 1 ]; then
      ml_epoch=$(stat -f %m "$C/strategy/mindset-log.md" 2>/dev/null)
    else
      ml_epoch=$(stat -c %Y "$C/strategy/mindset-log.md" 2>/dev/null)
    fi
    if [ -n "$ml_epoch" ] && [ $(( (NOW_EPOCH - ml_epoch) / 86400 )) -le 2 ]; then
      remark_line="E1 | 素材: strategy/mindset-log.md（末尾3エントリ）"
    fi
  fi

  mkdir -p "$STATE_DIR"
  if [ -n "$remark_line" ]; then
    echo "💬 REMARK: ${remark_line} ※秘書役への内部指示・ダッシュボードに転記しない"
    echo "$TODAY" > "$REMARK_STATE"
  fi
  echo "$TODAY" > "$STARTUP_STATE"
fi

echo "----------------------------------------"
echo "（このあと 秘書役: 外部タスク管理から未処理タスクを取得（繋いでいる場合。TODOの正は外部側） → 未取得ならカレンダー取得 → ダッシュボード表示）"
