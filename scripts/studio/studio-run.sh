#!/bin/zsh
# Photo Bench: Mac mini（16GB）を圧迫する重い処理（release レンダー、実写ゲート、swift test）を
# 同じ LAN 上の Mac Studio（64GB、Lightroom CC のプロファイル資産あり）で実行するための入口。
#
#   scripts/studio/studio-run.sh sync                 # 作業ツリーのソースを Studio へ同期（.build / exports / .photobench / dist は除く）
#                                                     # 私物の写真（*.tif・P152*・DSC0*）は送りも消しもしない。Studio 側へ別に置く
#   scripts/studio/studio-run.sh sync-data <path...>  # exports/ や .photobench/ の個別ディレクトリを同期（相対パス）
#   scripts/studio/studio-run.sh run  <command...>    # Studio のリポジトリで実行（PATH に Homebrew と venv を通す）
#   scripts/studio/studio-run.sh fetch <path...>      # Studio 側の相対パスをこちらへ取り込む（結果 JSON など）
#
# 例:
#   scripts/studio/studio-run.sh sync && scripts/studio/studio-run.sh run swift build -c release --product photobench-render
#   scripts/studio/studio-run.sh run python3 scripts/lr_measure/run_gate.py --render-binary .build/release/photobench-render --out-dir .photobench/phase2/c3-gate-results-lens
#   scripts/studio/studio-run.sh fetch .photobench/phase2/c3-gate-results-lens/summary.md
#
# 前提（2026-09-23 に整備済み）: `ssh takuya-mac-studio` が BatchMode で通る（~/.claude/skills/ssh-personal-macs）、
# Studio に Xcode・Homebrew の libraw/pkgconf・`~/.venvs/photobench`（numpy / Pillow / opencv-python-headless）。
# キーチェーンも Docker も使わない処理だけをここから流す（それ以外は skill の tmux ハブ経由）。
set -euo pipefail

STUDIO_HOST="${PHOTO_BENCH_STUDIO_HOST:-takuya-mac-studio}"
STUDIO_DIR="${PHOTO_BENCH_STUDIO_DIR:-Documents/app/photo-edit-app}"
LOCAL_ROOT="${0:A:h:h:h}"
REMOTE_ENV='export PATH=$HOME/.venvs/photobench/bin:/opt/homebrew/bin:$PATH; export CI_SILENCE_GL_DEPRECATION=1'

usage() { sed -n '2,20p' "$0"; exit 1; }

case "${1:-}" in
  sync)
    /usr/bin/rsync -a --delete \
      --exclude .build --exclude dist --exclude exports --exclude .photobench \
      --exclude '*.tif' --exclude 'P152*' --exclude 'DSC0*' --exclude '.DS_Store' \
      "$LOCAL_ROOT/" "$STUDIO_HOST:$STUDIO_DIR/"
    echo "synced source -> $STUDIO_HOST:$STUDIO_DIR"
    ;;
  sync-data)
    shift; [ $# -ge 1 ] || usage
    for rel in "$@"; do
      parent="$(dirname "$rel")"
      ssh -o BatchMode=yes "$STUDIO_HOST" "mkdir -p '$STUDIO_DIR/$parent'"
      /usr/bin/rsync -a "$LOCAL_ROOT/$rel" "$STUDIO_HOST:$STUDIO_DIR/$parent/"
      echo "synced $rel"
    done
    ;;
  run)
    shift; [ $# -ge 1 ] || usage
    # 引数をそのまま remote の zsh へ渡す（printf %q でシェル安全に引用）
    cmd="$(printf '%q ' "$@")"
    ssh -o BatchMode=yes "$STUDIO_HOST" "$REMOTE_ENV; cd '$STUDIO_DIR' && $cmd"
    ;;
  fetch)
    shift; [ $# -ge 1 ] || usage
    for rel in "$@"; do
      mkdir -p "$LOCAL_ROOT/$(dirname "$rel")"
      /usr/bin/rsync -a "$STUDIO_HOST:$STUDIO_DIR/$rel" "$LOCAL_ROOT/$(dirname "$rel")/"
      echo "fetched $rel"
    done
    ;;
  *) usage ;;
esac
