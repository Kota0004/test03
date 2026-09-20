#!/usr/bin/env bash
# ノートの振り返り・検索・追記の小道具。
# 使い方は ./scripts/note.sh help
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTES="$ROOT/notes"
TZ_JST="Asia/Tokyo"

# 日本語のタグや本文が1文字ずつ正しく扱われるよう UTF-8 ロケールを選ぶ。
# 未設定のまま grep にかけるとバイト単位で区切られ、タグが途中で切れる。
pick_utf8_locale() {
  local l
  for l in "${LC_ALL:-}" "${LANG:-}"; do
    case "$l" in *[Uu][Tt][Ff]-8|*[Uu][Tt][Ff]8) echo "$l"; return ;; esac
  done
  for l in C.UTF-8 C.utf8 en_US.UTF-8; do
    if locale -a 2>/dev/null | grep -qxF "$l"; then echo "$l"; return; fi
  done
  locale -a 2>/dev/null | grep -im1 'utf-\?8' || echo C
}
export LC_ALL="$(pick_utf8_locale)"

# テンプレートは中身がプレースホルダなので集計・検索から外す
note_files() { find "$NOTES" -name '*.md' 2>/dev/null | sort; }
content_files() {
  find "$NOTES" "$ROOT/themes" "$ROOT/ideas" -name '*.md' ! -name '_template.md' 2>/dev/null | sort
}

jst() { TZ="$TZ_JST" date "$@"; }
month_file() { echo "$NOTES/$(jst '+%Y-%m').md"; }

# その日の次の連番 ID を返す
next_id() {
  local day file n
  day="$(jst '+%Y-%m-%d')"
  file="$(month_file)"
  n=0
  if [[ -f "$file" ]]; then
    n="$(grep -c "^## n-$day-" "$file" || true)"
  fi
  printf 'n-%s-%02d\n' "$day" "$((n + 1))"
}

cmd_add() {
  local body="${*:-}"
  if [[ -z "$body" ]]; then
    # 引数がなければ標準入力から読む（パイプ・ヒアドキュメント対応）
    body="$(cat)"
  fi
  [[ -n "${body//[[:space:]]/}" ]] || { echo "中身が空です" >&2; exit 1; }

  local file id
  file="$(month_file)"
  id="$(next_id)"
  mkdir -p "$NOTES"
  if [[ ! -f "$file" ]]; then
    printf '# %s の生ログ\n\n原文のまま、時系列、追記のみ。過去のエントリは編集しない。\n' \
      "$(jst '+%Y年%m月')" > "$file"
  fi
  {
    printf '\n---\n\n## %s — %s\n\n' "$id" "$(jst '+%Y-%m-%d %H:%M')"
    printf '%s\n' "$body" | sed 's/^/> /'
    printf '\n**読み取り:** （未整理 — 次のチャットで Claude が拾う）\n'
    printf '**タグ:** \n'
  } >> "$file"
  echo "$id を $(basename "$file") に追記しました"
}

cmd_recent() {
  local n="${1:-20}"
  local files
  mapfile -t files < <(note_files)
  [[ ${#files[@]} -gt 0 ]] || { echo "まだノートがありません"; return; }
  # 全エントリを連結し、後ろから n 件ぶんの見出し位置で切り出す
  local all start
  all="$(cat "${files[@]}")"
  start="$(echo "$all" | grep -n '^## n-' | tail -n "$n" | head -n 1 | cut -d: -f1)"
  [[ -n "$start" ]] || { echo "まだエントリがありません"; return; }
  echo "$all" | tail -n "+$start"
}

cmd_find() {
  local q="${1:-}"
  [[ -n "$q" ]] || { echo "検索語を指定してください" >&2; exit 1; }
  local files
  mapfile -t files < <(content_files)
  [[ ${#files[@]} -gt 0 ]] || { echo "まだノートがありません"; return; }
  grep -nH --color=auto -C 2 -- "$q" "${files[@]}" 2>/dev/null \
    || echo "「$q」は見つかりませんでした"
}

cmd_tags() {
  local files
  mapfile -t files < <(content_files)
  [[ ${#files[@]} -gt 0 ]] || { echo "まだタグがありません"; return; }
  grep -oh '#[^[:space:]#]*' "${files[@]}" 2>/dev/null \
    | sed 's/[　、。，．・「」（）()]*$//' \
    | grep -v '^#$' \
    | sort | uniq -c | sort -rn \
    || echo "まだタグがありません"
}

cmd_tag() {
  local t="${1:-}"
  [[ -n "$t" ]] || { echo "タグ名を指定してください" >&2; exit 1; }
  t="${t#\#}"
  local files out
  mapfile -t files < <(note_files)
  [[ ${#files[@]} -gt 0 ]] || { echo "まだノートがありません"; return; }
  out="$(awk -v tag="#$t" '
    function flush() { if (buf != "" && hit) printf "%s\n", buf; buf = ""; hit = 0 }
    /^## n-/ { flush(); inentry = 1 }
    inentry { buf = buf $0 "\n" }
    /^\*\*タグ:/ { if (index($0, tag) > 0) hit = 1 }
    END { flush() }
  ' "${files[@]}")"
  if [[ -n "${out//[[:space:]]/}" ]]; then echo "$out"; else echo "「#$t」のついたエントリはありません"; fi
}

cmd_stats() {
  local notes months themes ideas
  notes="$(note_files | xargs -r grep -h '^## n-' 2>/dev/null | wc -l | tr -d ' ')"
  months="$(note_files | wc -l | tr -d ' ')"
  themes="$(find "$ROOT/themes" -name '*.md' ! -name '_template.md' 2>/dev/null | wc -l | tr -d ' ')"
  ideas="$(find "$ROOT/ideas" -name '*.md' ! -name '_template.md' 2>/dev/null | wc -l | tr -d ' ')"
  echo "ノート:   ${notes:-0} 件（${months:-0} か月ぶん）"
  echo "テーマ:   ${themes:-0} 件"
  echo "アイデア: ${ideas:-0} 件"
  echo "最終更新: $(cd "$ROOT" && git log -1 --format='%ad' --date=format-local:'%Y-%m-%d %H:%M' 2>/dev/null || echo '-')"
}

cmd_help() {
  cat <<'HELP'
note.sh — ノートの小道具

  recent [件数]   直近のエントリを表示（既定 20 件）
  find <語>       ノート・テーマ・アイデアを全文検索
  tags            タグを使用回数順に一覧
  tag <タグ名>    そのタグのついたエントリを表示
  add <本文>      チャットを使わず直接追記（標準入力も可）
  stats           ノート数などの概況
  help            この画面

例:
  ./scripts/note.sh add "電車で思いついた: 〇〇"
  echo "長い文章" | ./scripts/note.sh add
  ./scripts/note.sh find 設計
HELP
}

case "${1:-help}" in
  add)    shift; cmd_add "$@" ;;
  recent) shift; cmd_recent "$@" ;;
  find)   shift; cmd_find "$@" ;;
  tags)   cmd_tags ;;
  tag)    shift; cmd_tag "$@" ;;
  stats)  cmd_stats ;;
  help|-h|--help) cmd_help ;;
  *) echo "不明なコマンド: $1" >&2; echo; cmd_help; exit 1 ;;
esac
