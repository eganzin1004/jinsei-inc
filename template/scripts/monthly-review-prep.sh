#!/bin/bash
# =====================================================================
# 月次レビュー準備スクリプト
# 月次レビュー（strategy/CLAUDE.md）の冒頭で1回実行し、棚卸し候補を列挙する。
# 判断はしない——列挙するだけ。判定ロジック（対象・閾値）の正はこのファイル。
# strategy/CLAUDE.md 側は「このスクリプトを実行する」とだけ書く。
# BSD date（macOS）/ GNU date（クラウドVM）両対応。パスはスクリプト位置から導出。
# 出力の見方: ✅=候補なし / ⚠️=60日以上更新なし（生存確認） / → は補足行
# =====================================================================

C="$(cd "$(dirname "$0")/.." && pwd)"
TODAY=$(date +%Y-%m-%d)
NOW_EPOCH=$(date +%s)

if date -v+0d >/dev/null 2>&1; then IS_BSD=1; else IS_BSD=0; fi

day_epoch() {  # 引数: YYYY-MM-DD → epoch秒（不正なら空）
  if [ "$IS_BSD" -eq 1 ]; then
    date -j -f "%Y-%m-%d" "$1" +%s 2>/dev/null
  else
    date -d "$1" +%s 2>/dev/null
  fi
}

days_since() {  # 引数: YYYY-MM-DD → 経過日数を echo（未来なら負数、不正なら空）
  local d_epoch
  d_epoch=$(day_epoch "$1") || return
  [ -n "$d_epoch" ] || return
  echo $(( (NOW_EPOCH - d_epoch) / 86400 ))
}

file_mtime_date() {  # 引数: ファイルパス → 最終更新日 YYYY-MM-DD（mtime基準）
  if [ "$IS_BSD" -eq 1 ]; then
    stat -f "%Sm" -t "%Y-%m-%d" "$1" 2>/dev/null
  else
    stat -c "%y" "$1" 2>/dev/null | cut -c1-10
  fi
}

echo "📋 月次レビュー準備 — 棚卸し候補（${TODAY}時点）"
echo "判断はしない。以下は材料の列挙のみ。"
echo "========================================================================"

# --- 1. mindset-log の未振り分け分 ---
echo ""
echo "■ 1. mindset-log の未振り分け分"
ML="$C/strategy/mindset-log.md"
MS="$C/strategy/mindset.md"
if [ ! -f "$ML" ] || [ ! -f "$MS" ]; then
  echo "✅ なし（ファイル不在・クラウド想定）"
else
  prev_refine=$(tail -1 "$MS" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
  if [ -z "$prev_refine" ]; then
    echo "✅ なし（mindset.md 末尾に精錬日が見つからない）"
  else
    entries=$(awk -v prev="$prev_refine" '
      /^## [0-9]{4}-[0-9]{2}-[0-9]{2}/ {
        d = substr($0, 4, 10)
        if (d > prev) print substr($0, 4)
      }
    ' "$ML")
    if [ -z "$entries" ]; then
      echo "✅ なし（前回精錬日 ${prev_refine} 以降の未振り分けなし）"
    else
      cnt=$(echo "$entries" | wc -l | tr -d ' ')
      echo "$entries" | head -20 | sed 's/^/- /'
      if [ "$cnt" -gt 20 ]; then
        echo "- …他 $((cnt - 20)) 件（全件は mindset-log.md を直接読む）"
      fi
      echo "→ 計${cnt}件（前回精錬日: ${prev_refine} 以降）"
    fi
  fi
fi

# --- 2. decisions.md の棚卸し候補 ---
echo ""
echo "■ 2. decisions.md の棚卸し候補（90日以上前・ステータス有効）"
DEC="$C/secretary/notes/decisions.md"
if [ ! -f "$DEC" ]; then
  echo "✅ なし（ファイル不在・クラウド想定）"
else
  if [ "$IS_BSD" -eq 1 ]; then
    cutoff=$(date -v-90d +%Y-%m-%d)
  else
    cutoff=$(date -d "-90 day" +%Y-%m-%d)
  fi
  matches=$(awk -v cutoff="$cutoff" '
    /^## [0-9]{4}-[0-9]{2}-[0-9]{2}/ { sect = substr($0, 4, 10) }
    /^### / { heading = substr($0, 5) }
    /^→ ステータス: \*\*有効\*\*/ {
      if (heading != "" && sect <= cutoff) print sect "\t" heading
      heading = ""
    }
  ' "$DEC")
  if [ -z "$matches" ]; then
    echo "✅ なし"
  else
    total=$(echo "$matches" | wc -l | tr -d ' ')
    echo "$matches" | head -20 | awk -F'\t' '{print "- [" $1 "] " $2}'
    if [ "$total" -gt 20 ]; then
      echo "→ 他$((total - 20))件（計${total}件・カットオフ: ${cutoff}以前）"
    else
      echo "→ 計${total}件（カットオフ: ${cutoff}以前）"
    fi
  fi
fi

# --- 3. ideas/ の未処理分 ---
echo ""
echo "■ 3. ideas/ の未処理分"
IDEAS_DIR="$C/secretary/ideas"
if [ ! -d "$IDEAS_DIR" ] || [ -z "$(ls -A "$IDEAS_DIR" 2>/dev/null)" ]; then
  echo "✅ なし"
else
  for f in "$IDEAS_DIR"/*.md; do
    [ -f "$f" ] || continue
    n=$(grep -c '^## [0-9][0-9]:[0-9][0-9]' "$f")
    echo "- $(basename "$f"): ${n}件"
  done
fi

# --- 4. 台帳・ログ系ファイルの鮮度（生存確認用） ---
echo ""
echo "■ 4. 台帳・ログ系ファイルの鮮度（60日以上更新なしは⚠️）"
found_any=0
for dept_dir in "$C"/*/; do
  dept=$(basename "$dept_dir")
  cmd="$dept_dir/CLAUDE.md"
  [ -f "$cmd" ] || continue
  tokens=$(awk '/^## フォルダ構成/{flag=1; next} /^## /{flag=0} flag' "$cmd" | grep -oE '`[^`]+\.md`' | tr -d '`' | sort -u)
  [ -n "$tokens" ] || continue
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    path=""
    if [ -f "${dept_dir}${token}" ]; then
      path="${dept_dir}${token}"
    else
      path=$(find "$dept_dir" -maxdepth 4 -name "$token" -type f 2>/dev/null | head -1)
    fi
    [ -n "$path" ] && [ -f "$path" ] || continue
    mdate=$(file_mtime_date "$path")
    [ -n "$mdate" ] || continue
    d=$(days_since "$mdate")
    rel="${path#$C/}"
    if [ -n "$d" ] && [ "$d" -ge 60 ]; then
      echo "⚠️ ${rel}: ${d}日前（${mdate}）"
    else
      echo "- ${rel}: ${d}日前（${mdate}）"
    fi
    found_any=1
  done <<< "$tokens"
done
[ "$found_any" -eq 0 ] && echo "✅ なし"

# --- 4b. 未登録の.md（どの部署CLAUDE.mdのフォルダ構成にも載っていない＝孤児検出） ---
# 4の検査対象はフォルダ構成節に書かれたファイルだけなので、書き忘れた台帳は永久に検査されない。
# ここでその漏れ自体を拾う。ファイル名に日付を含むもの（月次レポート・スナップショット・
# レビュー等の一度きりの成果物）は継続更新される台帳ではないため除外する。
echo ""
echo "■ 4b. 未登録の.md（台帳なら部署CLAUDE.mdのフォルダ構成へ／成果物なら対象外でよい）"
declared=$({
  for dept_dir in "$C"/*/; do
    cmd="${dept_dir}CLAUDE.md"
    [ -f "$cmd" ] || continue
    awk '/^## フォルダ構成/{flag=1; next} /^## /{flag=0} flag' "$cmd" | grep -oE '`[^`]+\.md`' | tr -d '`'
  done
  # ルート直下のファイル（SKILLS.md・ARSENAL.md・MANUAL.md・notion.md 等）は
  # 構造上どの部署のフォルダ構成節にも載らない。組織CLAUDE.mdの
  # 「ルートのファイル」表を第2の台帳として併用する（除外パス一覧は持たせない）。
  if [ -f "$C/CLAUDE.md" ]; then
    awk '/^### ルートのファイル/{flag=1; next} /^#/{flag=0} flag' "$C/CLAUDE.md" \
      | grep -oE '`[^`]+\.md`' | tr -d '`'
  fi
} | sort -u)

# projects/ の台帳「関連ファイル欄」を第3の登録先として併用する。
# プロジェクトの成果物は部署のフォルダ構成節には載らない（部署は永続機能、
# プロジェクトは時限的な取り組みで、成果物は台帳側に登録するのが正）。
# ここを見ないと「作った成果物が台帳に載っているか」を誰も検査しないままになる。
# パス・ファイル名・ディレクトリ接頭辞のいずれでも登録済みと認める
# （台帳に `build/examples/` とあれば、その配下は登録済みとみなす）。
proj_declared=$(
  for led in "$C"/projects/*.md; do
    [ -f "$led" ] || continue
    lb=$(basename "$led")
    [ "$lb" = "CLAUDE.md" ] && continue
    # 先頭が _ のもの（_template.md 等）は台帳ではない
    # ※ case は使わない。macOSのbash 3.2 は $( ) の中の case パターンの ) を
    #   コマンド置換の閉じ括弧と誤解して構文エラーになる
    [ "${lb#_}" != "$lb" ] && continue
    awk '/^## 関連ファイル/{flag=1; next} /^## /{flag=0} flag' "$led" \
      | grep -oE '`[^`]+`' | tr -d '`'
  done | sort -u
)

unreg=$(find "$C" -name "*.md" -type f \
  -not -path "*/.git/*" \
  -not -path "$C/.claude/*" \
  -not -path "$C/secretary/notes/weekly/*" \
  -not -path "$C/secretary/ideas/*" \
  -not -path "$C/strategy/reviews/*" \
  -not -path "$C/engineering/debug-log/*" \
  -not -path "$C/research/projects/*" \
  -not -name "CLAUDE.md" \
  -not -name "_*.md" \
  2>/dev/null | while IFS= read -r f; do
    base=$(basename "$f")
    rel="${f#$C/}"
    # 日付を名前に含む＝一度きりの成果物（YYYY-MM / YYYY-MM-DD）
    echo "$base" | grep -qE '[0-9]{4}-[0-9]{2}' && continue
    # 登録先1・2: 部署CLAUDE.mdのフォルダ構成／組織CLAUDE.mdのルートファイル表
    echo "$declared" | grep -qxF "$base" && continue
    # 登録先3: projects台帳の関連ファイル欄（パス一致・名前一致・接頭辞一致）
    reg=0
    while IFS= read -r d; do
      [ -z "$d" ] && continue
      if [ "${d%/}" != "$d" ]; then
        # 末尾が / ＝ディレクトリ接頭辞での登録（配下は登録済みとみなす）
        [ "${rel#$d}" != "$rel" ] && { reg=1; break; }
      else
        { [ "$d" = "$rel" ] || [ "$d" = "$base" ]; } && { reg=1; break; }
      fi
    done <<EOF
$proj_declared
EOF
    [ "$reg" = 1 ] && continue
    echo "$rel"
  done | sort)

if [ -z "$unreg" ]; then
  echo "✅ なし"
else
  n=$(echo "$unreg" | wc -l | tr -d ' ')
  echo "$unreg" | head -15 | while IFS= read -r rel; do
    mdate=$(file_mtime_date "$C/$rel")
    d=$(days_since "$mdate")
    echo "- ${rel}: ${d}日前（${mdate}）"
  done
  [ "$n" -gt 15 ] && echo "  …他 $((n - 15)) 件"
fi

# --- 5. 撤退基準つき機構の判定期日 ---
echo ""
echo "■ 5. 撤退基準つき機構の判定期日"
SEC_CLAUDE="$C/secretary/CLAUDE.md"
if [ ! -f "$SEC_CLAUDE" ]; then
  echo "✅ なし（ファイル不在）"
else
  lines=$(grep "撤退基準" "$SEC_CLAUDE")
  if [ -z "$lines" ]; then
    echo "✅ なし"
  else
    echo "$lines"
  fi
fi

# --- 6. 今月の問い ---
echo ""
echo "■ 6. 今月の問い"
Q="$C/strategy/question.md"
if [ ! -f "$Q" ]; then
  echo "✅ なし（ファイル不在）"
else
  q_line=$(grep -m1 '^問い:' "$Q")
  if [ -z "$q_line" ]; then
    echo "✅ なし（question.md に「問い:」行がない）"
  else
    q_date=$(echo "$q_line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
    d=""
    [ -n "$q_date" ] && d=$(days_since "$q_date")
    echo "$q_line"
    [ -n "$d" ] && echo "→ 設定から${d}日経過"
  fi
fi

echo ""
echo "========================================================================"
