#!/usr/bin/env bash
#
# archiver.sh - fast, low-CPU, non-blocking archive creation/extraction
# Method: tar | zstd, run under nice + ionice (idle), optional background mode.
# Safe to run on live data: files that change while being read only produce a
# warning (tar exit 1); sockets are skipped silently.
#
# Usage:
#   archiver.sh create  [-t THREADS] [-l LEVEL] [-x PATTERN]... [-b] OUTPUT.tar.zst DIR [DIR...]
#   archiver.sh extract [-t THREADS] [-b] ARCHIVE.tar.zst [DEST_DIR]
#
# Options:
#   -t N        zstd threads (default 2; 0 = all cores, 1 = gentlest)
#   -l N        zstd level 1-19 (default 3; create only)
#   -x PATTERN  exclude files matching PATTERN (repeatable, tar --exclude syntax)
#   -b          run in the background, logging next to the archive
#   -h          show help

set -euo pipefail

THREADS=2
LEVEL=3
BACKGROUND=0
EXCLUDES=()
SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
ORIG_ARGS=("$@")

usage() { sed -n '2,18p' "$SCRIPT" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
die()   { echo "Error: $*" >&2; exit 1; }
need()  { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."; }

PRIO=()
command -v nice   >/dev/null 2>&1 && PRIO+=(nice -n 19)
command -v ionice >/dev/null 2>&1 && PRIO+=(ionice -c3)

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
    go_background "${out}.log"
  fi

  # Remove stale partial file from a previous interrupted run, and clean up on exit
  rm -f "$tmp"
  trap "rm -f -- '$tmp'" EXIT
  trap 'exit 130' INT TERM

  local tar_args=(-cf - --warning=no-file-ignored)
  for x in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do tar_args+=(--exclude="$x"); done

  echo "Creating $out (threads=$THREADS, level=$LEVEL)..."

  # tar exit codes: 0 = ok, 1 = some files changed while read (non-fatal), 2 = fatal
  set +e
  ${PRIO[@]+"${PRIO[@]}"} tar "${tar_args[@]}" "$@" \
    | ${PRIO[@]+"${PRIO[@]}"} zstd -f -q -T"$THREADS" -"$LEVEL" -o "$tmp"
  local rc=("${PIPESTATUS[@]}")
  set -e
  local tar_rc=${rc[0]} zstd_rc=${rc[1]}

  (( zstd_rc == 0 )) || die "zstd failed (exit $zstd_rc)"
  (( tar_rc <= 1 ))  || die "tar failed (exit $tar_rc)"

  ${PRIO[@]+"${PRIO[@]}"} zstd -t -q "$tmp" || die "Integrity check failed"
  mv "$tmp" "$out"

  echo "Done: $out ($(du -h "$out" | cut -f1))"
  if (( tar_rc == 1 )); then
    echo "Warning: some files changed while being read. The archive is valid, but those"
    echo "         files (e.g. databases, logs) may be inconsistent. See messages above."
  fi
}

do_extract() {
  (( $# >= 1 )) || usage 1
  local archive="$1" dest="${2:-.}"
  [[ -f "$archive" ]] || die "Archive not found: $archive"
  mkdir -p "$dest"

  if (( BACKGROUND )) && [[ -z "${ARCHIVER_BG_CHILD:-}" ]]; then
    go_background "${archive}.extract.log"
  fi

  echo "Extracting $archive -> $dest ..."
  ${PRIO[@]+"${PRIO[@]}"} zstd -d -c -T"$THREADS" -q "$archive" \
    | ${PRIO[@]+"${PRIO[@]}"} tar -xf - -C "$dest"
  echo "Done."
}

[[ $# -ge 1 ]] || usage 1
CMD="$1"; shift
[[ "$CMD" == "-h" || "$CMD" == "--help" ]] && usage 0

while getopts ":t:l:x:bh" opt; do
  case "$opt" in
    t) THREADS="$OPTARG" ;;
    l) LEVEL="$OPTARG" ;;
    x) EXCLUDES+=("$OPTARG") ;;
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
