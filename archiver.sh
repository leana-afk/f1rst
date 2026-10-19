#!/usr/bin/env bash
#
# archiver.sh - fast, low-CPU, non-blocking archive creation/extraction
# Method: tar | zstd, run under nice + ionice (idle), optional background mode.
#
# Usage:
#   archiver.sh create  [-t THREADS] [-l LEVEL] [-b] OUTPUT.tar.zst DIR [DIR...]
#   archiver.sh extract [-t THREADS] [-b] ARCHIVE.tar.zst [DEST_DIR]
#
# Options:
#   -t N   zstd threads (default 2; 0 = all cores, 1 = gentlest)
#   -l N   zstd level 1-19 (default 3; create only)
#   -b     run in the background, logging to OUTPUT.log (shell returns immediately)
#   -h     show help

set -euo pipefail

THREADS=2
LEVEL=3
BACKGROUND=0
SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
ORIG_ARGS=("$@")

usage() { sed -n '2,16p' "$SCRIPT" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
die()   { echo "Error: $*" >&2; exit 1; }

# Low-priority wrappers (used only if available)
PRIO=()
command -v nice   >/dev/null 2>&1 && PRIO+=(nice -n 19)
command -v ionice >/dev/null 2>&1 && PRIO+=(ionice -c3)

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."; }

# Re-run this script detached from the terminal, then exit.
go_background() {
  local log="$1"
  ARCHIVER_BG_CHILD=1 nohup setsid bash "$SCRIPT" "${ORIG_ARGS[@]}" >"$log" 2>&1 &
  echo "Started in background (PID $!). Log: $log"
  exit 0
}

do_create() {
  (( $# >= 2 )) || usage 1
  local out="$1"; shift
  local tmp="${out}.part"

  for d in "$@"; do [[ -e "$d" ]] || die "Not found: $d"; done
  [[ -e "$out" ]] && die "Output already exists: $out"

  if (( BACKGROUND )) && [[ -z "${ARCHIVER_BG_CHILD:-}" ]]; then
    go_background "${out%.zst}.log"
  fi

  trap 'rm -f "$tmp"' ERR INT TERM

  echo "Creating $out (threads=$THREADS, level=$LEVEL)..."
  ${PRIO[@]+"${PRIO[@]}"} tar -cf - "$@" \
    | ${PRIO[@]+"${PRIO[@]}"} zstd -T"$THREADS" -"$LEVEL" -q -o "$tmp"

  # Verify integrity, then move into place atomically
  ${PRIO[@]+"${PRIO[@]}"} zstd -t -q "$tmp"
  mv "$tmp" "$out"
  trap - ERR INT TERM
  echo "Done: $out ($(du -h "$out" | cut -f1))"
}

do_extract() {
  (( $# >= 1 )) || usage 1
  local archive="$1" dest="${2:-.}"
  [[ -f "$archive" ]] || die "Archive not found: $archive"
  mkdir -p "$dest"

  if (( BACKGROUND )) && [[ -z "${ARCHIVER_BG_CHILD:-}" ]]; then
    go_background "${archive%.zst}.extract.log"
  fi

  echo "Extracting $archive -> $dest ..."
  ${PRIO[@]+"${PRIO[@]}"} zstd -d -c -T"$THREADS" -q "$archive" \
    | ${PRIO[@]+"${PRIO[@]}"} tar -xf - -C "$dest"
  echo "Done."
}

# ---- main ----
[[ $# -ge 1 ]] || usage 1
CMD="$1"; shift
[[ "$CMD" == "-h" || "$CMD" == "--help" ]] && usage 0

while getopts ":t:l:bh" opt; do
  case "$opt" in
    t) THREADS="$OPTARG" ;;
    l) LEVEL="$OPTARG" ;;
    b) BACKGROUND=1 ;;
    h) usage 0 ;;
    *) die "Invalid option: -$OPTARG" ;;
  esac
done
shift $((OPTIND - 1))

need tar
need zstd

case "$CMD" in
  create)  do_create  "$@" ;;
  extract) do_extract "$@" ;;
  *)       usage 1 ;;
esac
