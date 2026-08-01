#!/bin/bash
# =====================================================================
# 人生OS 自走メンテスクリプト（auto-maintain）
# launchd からログイン時＋4時間おきに起動される。「Macを開いたら追いつく」方式。
# 毎回「何が溜まっているか」を自己判定し、溜まっていなければ数秒で終了（冪等）。
#
# やること（判断不要な定型作業のみ）:
#   1. カレンダーキャッシュ（今日分がなければ claude headless で取得）
#   2. 週次圧縮（前週以前の日次ログがあれば claude headless で weekly 作成 → 検証後に日次削除）
#   3. 使い捨てファイルの掃除（当日分以外の calendar-*。自フォルダの中だけ）
#   4. git 自動コミット（差分あり・かつ直近30分ファイル変更なし＝セッション中でないとき）
#   5. iCloudバックアップ（git bundle を週1で作成・2世代保持。全損リスク対策の暫定保険）
#      復元: git clone <bundleファイル> .company
#
# やらないこと: 月次レビュー・mindset精錬・アイデア棚卸し（判断が要る作業）・GitHubへのpush
#   機微ファイルのiCloudミラー（sensitive-mirror）: launchd無人実行ではkTCCServiceFileProviderDomain
#   権限が付与できず常時失敗するため対象外。週次圧縮の対話セッション内で手動実行する（secretary/CLAUDE.md）
# 実行ログ: ~/Library/Logs/company-auto-maintain.log（リポジトリ外。コミットループ防止）
# =====================================================================

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
C="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$HOME/Library/Logs/company-auto-maintain.log"
# ★/tmp は誰でも書ける共有領域。固定名だと、先回りしてシンボリックリンクを
#   置かれた場合に touch がそれを追い、任意ファイルのmtimeを書き換えられる。
#   macOSの TMPDIR はユーザーごとに分離されているのでそちらを使う。
TMPD="${TMPDIR:-/tmp}"
LOCK="$TMPD/company-auto-maintain.lock"
TODAY=$(date +%Y-%m-%d)
THIS_WEEK=$(date +%G-W%V)
START_MARK="$TMPD/company-auto-maintain.start"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# --- 多重起動ロック（PID入り。プロセス死亡済みなら奪取） ---
if mkdir "$LOCK" 2>/dev/null; then
  echo $$ > "$LOCK/pid"
else
  oldpid=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
    exit 0  # 実行中インスタンスがいる。静かに退出（ログも残さない）
  fi
  rm -rf "$LOCK"; mkdir "$LOCK" || exit 0; echo $$ > "$LOCK/pid"
fi
trap 'rm -rf "$LOCK" "$START_MARK"; rm -f "${MCPCFG_FILE:-}"' EXIT
touch "$START_MARK"

# claude CLI はLLMを使う①②にだけ要る。無くても③掃除・④gitコミット・⑤バックアップは走らせる
if command -v claude >/dev/null; then
  HAS_CLAUDE=1
else
  HAS_CLAUDE=0
  log "WARN: claude CLI が見つからない（LLMを使う①カレンダー・②週次圧縮のみスキップ）"
fi

actions=""
did_compress=0

# --- 1. カレンダーキャッシュ ---
if [ "$HAS_CLAUDE" = 1 ] && [ ! -f "$C/secretary/notes/calendar-${TODAY}.md" ]; then
  # mcp-googleは ~/claude-plugins プロジェクトスコープ登録のため、人生OS からの headless では見えない。
  # ~/.claude.json から設定（env込み）を抽出して明示的に渡す（認証情報はこのスクリプトに置かない）
  # ★設定はファイル経由で渡す。--mcp-config に中身を直接渡すと env（認証情報）が
  #   プロセス引数に載り、同じユーザーで動く任意のプロセスから ps で読める。
  #   TMPDIR はmacOSではユーザーごとに分離されているので /tmp より安全。
  MCPCFG_FILE="${TMPDIR:-/tmp}/company-mcp-$$.json"
  ( umask 077; python3 -c "import json,os; d=json.load(open(os.path.expanduser('~/.claude.json'))); print(json.dumps({'mcpServers':{'mcp-google':d['projects']['<YOUR_WORKSPACE_PATH>']['mcpServers']['mcp-google']}}))" > "$MCPCFG_FILE" ) 2>/dev/null
  if [ ! -s "$MCPCFG_FILE" ]; then
    rm -f "$MCPCFG_FILE"
    actions="$actions calendar:SKIP(外部連携が未設定)"
  else
    cd "$C" && claude -p \
      --model sonnet \
      --mcp-config "$MCPCFG_FILE" \
      --strict-mcp-config \
      --allowedTools "mcp__mcp-google__list_events,Write" \
      --max-turns 10 \
      "mcp__mcp-google__list_events で2つのカレンダーの予定を今日（${TODAY}）から7日後まで取得して、\
${C}/secretary/notes/calendar-${TODAY}.md に保存して。\
①calendar_id=primary（見出し: <account>（オーナー個人））②calendar_id=you@example.com（見出し: <account>（夫婦共有））。\
ファイル形式: 1行目「# カレンダー取得ログ <開始日>〜<終了日>」、以降アカウント別の ## 見出し配下に「- YYYY-MM-DD [HH:MM] タイトル」の箇条書き。\
取得に失敗したらファイルを作らず終了して。" >/dev/null 2>&1
    rm -f "$MCPCFG_FILE"
    if [ -f "$C/secretary/notes/calendar-${TODAY}.md" ]; then
      actions="$actions calendar:OK"
    else
      actions="$actions calendar:FAIL"
    fi
  fi
fi

# --- 2. 週次圧縮（前週以前の日次ログ） ---
stale=""
for f in "$C"/secretary/notes/????-??-??.md; do
  [ -e "$f" ] || continue
  d=$(basename "$f" .md)
  w=$(date -j -f "%Y-%m-%d" "$d" +%G-W%V 2>/dev/null)
  [ -n "$w" ] && [ "$w" != "$THIS_WEEK" ] && stale="$stale $d"
done

if [ -n "$stale" ] && [ "$HAS_CLAUDE" != 1 ]; then
  actions="$actions compress:SKIP(claude CLI なし)"
  stale=""
fi

if [ -n "$stale" ]; then
  cd "$C" && claude -p \
    --model sonnet \
    --permission-mode acceptEdits \
    --max-turns 40 \
    "あなたは 人生OS の秘書役として週次圧縮を行う。secretary/CLAUDE.md の「週次圧縮」ルールに従うこと。\
対象の日次ログ:${stale}（secretary/notes/YYYY-MM-DD.md）。\
手順: ①対象ログを読む ②ISO週（%G-W%V）ごとにグループ化し secretary/notes/weekly/YYYY-WNN.md を作成/追記（既存weeklyファイルの形式に合わせる。冒頭に「> 日次ログ: <元ファイル名>」を必ず含める） \
③日次ログ内の思想・判断軸が strategy/mindset-log.md に記録済みか確認し、漏れがあれば mindset-log.md に追記 \
④secretary/notes/current-setup.md の最終更新日を今日（${TODAY}）にする。\
【重要】日次ログの削除と git commit はやらないこと（呼び出し元スクリプトが検証後に行う）。" >/dev/null 2>&1

  # 検証してから削除。★「ファイル名が書いてある」だけでは中身が要約された保証がない。
  #   要約に失敗して見出しと1行だけ書かれた場合も条件を満たし、元ログが消える。
  #   そこで最低限の記述量を足す。弾きたいのは空振り（数行のスタブ）だけなので
  #   絶対値の下限にする。要約率で測ってはいけない——実在の週次は9〜40行で、
  #   日次の本数に比例させると通常の週が永久に圧縮されなくなる（実測で確認）。
  WEEKLY_MIN_LINES=6
  removed=""; kept=""
  for d in $stale; do
    w=$(date -j -f "%Y-%m-%d" "$d" +%G-W%V 2>/dev/null)
    wf="$C/secretary/notes/weekly/${w}.md"
    if [ ! -f "$wf" ] || [ ! "$wf" -nt "$START_MARK" ] || ! grep -q "${d}.md" "$wf"; then
      kept="$kept ${d}"
      continue
    fi
    wf_lines=$(grep -c '[^[:space:]]' "$wf" 2>/dev/null || echo 0)
    if [ "$wf_lines" -lt "$WEEKLY_MIN_LINES" ]; then
      kept="$kept ${d}"
      log "WARN: ${w}.md が ${wf_lines}行しかない。要約が失敗した可能性があるので ${d}.md を温存する"
      continue
    fi
    rm "$C/secretary/notes/${d}.md"
    removed="$removed ${d}"
    did_compress=1
  done
  [ -n "$removed" ] && actions="$actions compress:OK(${removed# })"
  [ -n "$kept" ] && actions="$actions compress:FAIL(${kept# }は検証NGで温存)"
fi

# --- 3. 使い捨てファイルの掃除 ---
# calendar-*.md は当日限りのキャッシュ（状態の正は外部にある: 予定は
# カレンダー側）。当日分以外を削除する。
cleaned=0
for f in "$C"/secretary/notes/calendar-*.md; do
  [ -e "$f" ] || continue
  case "$(basename "$f")" in
    *"${TODAY}"*) ;;
    *) rm "$f" && cleaned=$((cleaned+1)) ;;
  esac
done
# ★このスクリプトが消してよいのは自分のフォルダの中だけ。以前ここで
#   親ディレクトリにある別ツールの作業フォルダを rm -rf していたが、自分の管理外を
#   確認なく消す処理だった（別ツールが同じ場所を使っていると巻き込む）。
#   使い捨てスクショの掃除は、それを作ったツール側の責任として切り離した。
[ "$cleaned" -gt 0 ] && actions="$actions cleanup:OK(${cleaned}件)"

# --- 4. git 自動コミット ---
changes=$(git -C "$C" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
if [ "${changes:-0}" -gt 0 ]; then
  # 直近30分にファイル変更があれば「セッション作業中」とみなして見送る（圧縮を実行した回は除く）
  # 注: macOSのfindは -newermt '-30 minutes' を誤解釈する（エラーにならず常に不一致）ため基準ファイル方式を使う
  REF="$TMPD/company-auto-maintain.ref"
  touch -t "$(date -v-30M +%Y%m%d%H%M.%S)" "$REF"
  recent=$(find "$C" -not -path '*/.git/*' -type f -newer "$REF" ! -newer "$START_MARK" 2>/dev/null | head -1)
  rm -f "$REF"
  if [ "$did_compress" -eq 1 ] || [ -z "$recent" ]; then
    git -C "$C" add -A && git -C "$C" commit -q -m "auto: maintenance ${TODAY}" && actions="$actions commit:OK(${changes}件)"
  else
    actions="$actions commit:skip(直近30分に変更あり)"
  fi
fi

# --- 5. iCloudバックアップ（git bundle・週1・2世代保持） ---
# GitHub化済み（2026-07-19・新履歴リポは機微除外）。bundleはGitHub障害時の保険として継続。
# 機微ファイル（git管理外＝GitHubにもbundleにも入らない）のミラーは、launchdの裸バイナリでは
# kTCCServiceFileProviderDomain権限が付与できずiCloud領域のopendirが常にEPERMになるため、
# ここでは行わない（週次圧縮の対話セッション内で手動実行。secretary/CLAUDE.md参照）。
# 注意: throttle判定はiCloud上のファイル列挙に依存すると同じ理由で機能しないため、
# 非iCloudのローカル状態ファイルで管理する。
# 世代ローテーションのglobは日付形式限定（company-legacy-*.bundle を消さないため）
BK="$HOME/Library/Mobile Documents/com~apple~CloudDocs/company-backup"
STATE="$HOME/Library/Application Support/company-auto-maintain/last-backup-date"
mkdir -p "$(dirname "$STATE")"
need_bk=1
if [ -f "$STATE" ]; then
  bd_epoch=$(date -j -f "%Y-%m-%d" "$(cat "$STATE")" +%s 2>/dev/null)
  now_epoch=$(date +%s)
  if [ -n "$bd_epoch" ] && [ $(( (now_epoch - bd_epoch) / 86400 )) -lt 7 ]; then
    need_bk=0
  fi
fi
if [ "$need_bk" -eq 1 ]; then
  mkdir -p "$BK"
  if git -C "$C" bundle create "$BK/company-${TODAY}.bundle" --all >/dev/null 2>&1 \
     && git -C "$C" bundle verify "$BK/company-${TODAY}.bundle" >/dev/null 2>&1; then
    actions="$actions backup:OK"
    echo "$TODAY" > "$STATE"
    ls -t "$BK"/company-????-??-??.bundle 2>/dev/null | tail -n +3 | while IFS= read -r f; do rm -f "$f"; done
  else
    rm -f "$BK/company-${TODAY}.bundle"
    actions="$actions backup:FAIL"
  fi
fi

[ -z "$actions" ] && actions=" nothing-to-do"
log "run:${actions}"

# --- ログローテーション（500行超で400行に切り詰め） ---
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG" | tr -d ' ')" -gt 500 ]; then
  tail -400 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
