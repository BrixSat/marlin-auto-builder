#!/usr/bin/env bash
#
# Marlin firmware builder
# -----------------------
# Downloads Marlin from GitHub, drops in a printer's saved configuration,
# builds it, and copies the resulting firmware.hex into ./output/.
#
# Usage:
#   ./build.sh [PRINTER] [options]
#
#   PRINTER              Name of a folder under printers/. If omitted, you get a
#                        menu. Use "all" (or --all) to build every printer.
#
# Options:
#   -a, --all            Build every printer under printers/.
#   -v, --version VER    Marlin tag to build (e.g. 2.1.2.8) or "latest".
#                        Overrides MARLIN_VERSION from the printer's printer.conf.
#   -l, --list           List available printers and exit.
#   -k, --keep           Keep the temporary build tree (default: delete it).
#   -h, --help           Show this help.
#
# Add a new printer:  create printers/<name>/ containing
#   Configuration.h, Configuration_adv.h, and printer.conf
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRINTERS_DIR="$SCRIPT_DIR/printers"
CACHE_DIR="$SCRIPT_DIR/.cache"      # downloaded Marlin tarballs (reused across builds)
BUILD_DIR="$SCRIPT_DIR/.build"      # transient extracted source
OUTPUT_DIR="$SCRIPT_DIR/output"     # firmware .hex output

REPO="MarlinFirmware/Marlin"

# ---- pretty output -------------------------------------------------------
if [ -t 1 ]; then BOLD=$'\e[1m'; RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; RST=$'\e[0m'
else BOLD=""; RED=""; GRN=""; YEL=""; RST=""; fi
info()  { echo "${BOLD}==>${RST} $*"; }
warn()  { echo "${YEL}warning:${RST} $*" >&2; }
die()   { echo "${RED}error:${RST} $*" >&2; exit 1; }

usage() {
  sed -n '3,25p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'
}

# ---- args ----------------------------------------------------------------
PRINTER=""
VERSION_OVERRIDE=""
KEEP=0
ALL=0
LIST_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    -l|--list)    LIST_ONLY=1; shift ;;
    -a|--all)     ALL=1; shift ;;
    -k|--keep)    KEEP=1; shift ;;
    -v|--version) VERSION_OVERRIDE="${2:-}"; [ -n "$VERSION_OVERRIDE" ] || die "--version needs a value"; shift 2 ;;
    all)          ALL=1; shift ;;
    -*)           die "unknown option: $1  (try --help)" ;;
    *)            [ -z "$PRINTER" ] || die "unexpected extra argument: $1"; PRINTER="$1"; shift ;;
  esac
done

# ---- discover printers ---------------------------------------------------
list_printers() {
  [ -d "$PRINTERS_DIR" ] || return 0
  for d in "$PRINTERS_DIR"/*/; do
    [ -f "${d}printer.conf" ] && basename "$d"
  done
}

mapfile -t PRINTERS < <(list_printers)
[ "${#PRINTERS[@]}" -gt 0 ] || die "no printers found under $PRINTERS_DIR"

if [ "$LIST_ONLY" = "1" ]; then
  info "Available printers:"
  for p in "${PRINTERS[@]}"; do
    desc="$(. "$PRINTERS_DIR/$p/printer.conf" 2>/dev/null; echo "${DESCRIPTION:-}")"
    printf "  %-14s %s\n" "$p" "$desc"
  done
  exit 0
fi

# ---- tools ---------------------------------------------------------------
find_pio() {
  if command -v platformio >/dev/null 2>&1; then command -v platformio
  elif command -v pio >/dev/null 2>&1; then command -v pio
  elif [ -x "$HOME/.platformio/penv/bin/platformio" ]; then echo "$HOME/.platformio/penv/bin/platformio"
  else return 1; fi
}
PIO="$(find_pio)" || die "PlatformIO not found (install it, or fix your PATH)"

# ---- version resolution (memoized) ---------------------------------------
_LATEST=""
resolve_latest() {
  if [ -z "$_LATEST" ]; then
    info "Looking up latest Marlin release..." >&2
    _LATEST="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
      | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name" *: *"([^"]+)".*/\1/')"
    [ -n "$_LATEST" ] || die "could not determine latest release tag"
  fi
  echo "$_LATEST"
}

# ---- download + extract a Marlin version (cached) ------------------------
# echoes the extracted source dir on stdout; all logs go to stderr.
ensure_source() {
  local version="$1"
  local tarball="$CACHE_DIR/Marlin-$version.tar.gz"
  mkdir -p "$CACHE_DIR"
  if [ -s "$tarball" ]; then
    info "Using cached source: $(basename "$tarball")" >&2
  else
    info "Downloading Marlin $version ..." >&2
    curl -fL --retry 3 -o "$tarball" \
      "https://github.com/$REPO/archive/refs/tags/$version.tar.gz" >&2 \
      || { rm -f "$tarball"; return 1; }
  fi
  rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
  tar -xzf "$tarball" -C "$BUILD_DIR" >&2 || return 1
  local src
  src="$(find "$BUILD_DIR" -maxdepth 1 -type d -name 'Marlin-*' | head -1)"
  [ -n "$src" ] && [ -d "$src/Marlin" ] || return 1
  echo "$src"
}

# ---- build one printer; returns 0 on success, 1 on failure ---------------
LAST_OUT=""
build_one() {
  local printer="$1"
  local dir="$PRINTERS_DIR/$printer"
  LAST_OUT=""

  echo
  info "${BOLD}==== $printer ====${RST}"
  [ -d "$dir" ]                     || { warn "unknown printer '$printer'"; return 1; }
  [ -f "$dir/printer.conf" ]        || { warn "$printer: missing printer.conf"; return 1; }
  [ -f "$dir/Configuration.h" ]     || { warn "$printer: missing Configuration.h"; return 1; }
  [ -f "$dir/Configuration_adv.h" ] || { warn "$printer: missing Configuration_adv.h"; return 1; }

  # load config (subshell-safe: reset first)
  local DESCRIPTION="" PIO_ENV="" MARLIN_VERSION=""
  # shellcheck disable=SC1090
  . "$dir/printer.conf"
  [ -n "$PIO_ENV" ] || { warn "$printer: PIO_ENV not set in printer.conf"; return 1; }

  local version="${VERSION_OVERRIDE:-${MARLIN_VERSION:-latest}}"
  if [ "$version" = "latest" ]; then version="$(resolve_latest)"; fi

  local src
  src="$(ensure_source "$version")" || { warn "$printer: could not fetch Marlin $version"; return 1; }

  info "Applying $printer config ($DESCRIPTION)"
  cp "$dir/Configuration.h"     "$src/Marlin/Configuration.h"
  cp "$dir/Configuration_adv.h" "$src/Marlin/Configuration_adv.h"

  info "Building $printer ($PIO_ENV, Marlin $version) ..."
  if ! ( cd "$src" && rm -rf .pio && "$PIO" run -e "$PIO_ENV" ); then
    warn "$printer: BUILD FAILED"
    return 1
  fi

  local hex="$src/.pio/build/$PIO_ENV/firmware.hex"
  [ -f "$hex" ] || { warn "$printer: build finished but firmware.hex not found"; return 1; }

  mkdir -p "$OUTPUT_DIR"
  local stamp out
  stamp="$(date +%Y%m%d-%H%M%S)"
  out="$OUTPUT_DIR/${printer}-${version}-${stamp}.hex"
  cp "$hex" "$out"
  cp "$hex" "$OUTPUT_DIR/${printer}-latest.hex"
  LAST_OUT="$out"
  info "${GRN}$printer OK${RST} -> $out"
  return 0
}

# ---- choose targets ------------------------------------------------------
declare -a TARGETS
if [ "$ALL" = "1" ]; then
  [ -z "$PRINTER" ] || die "give either a printer name or --all, not both"
  TARGETS=("${PRINTERS[@]}")
else
  if [ -z "$PRINTER" ]; then
    info "Select a printer to build (or Ctrl-C to cancel):"
    select choice in "${PRINTERS[@]}" "all"; do
      [ -n "${choice:-}" ] || { echo "Invalid selection."; continue; }
      [ "$choice" = "all" ] && { TARGETS=("${PRINTERS[@]}"); } || TARGETS=("$choice")
      break
    done
  else
    TARGETS=("$PRINTER")
  fi
fi

# ---- run -----------------------------------------------------------------
declare -a OK=() FAIL=()
for p in "${TARGETS[@]}"; do
  if build_one "$p"; then OK+=("$p"); else FAIL+=("$p"); fi
done

# ---- cleanup -------------------------------------------------------------
if [ "$KEEP" = "1" ]; then
  info "Kept last build tree under: $BUILD_DIR"
else
  rm -rf "$BUILD_DIR"
fi

# ---- summary -------------------------------------------------------------
echo
if [ "${#TARGETS[@]}" -gt 1 ]; then
  info "Summary:"
  for p in "${OK[@]}";   do echo "  ${GRN}ok  ${RST} $p  ($OUTPUT_DIR/${p}-latest.hex)"; done
  for p in "${FAIL[@]}"; do echo "  ${RED}FAIL${RST} $p"; done
  echo "  ${#OK[@]} succeeded, ${#FAIL[@]} failed."
elif [ "${#OK[@]}" = "1" ]; then
  info "${GRN}Done.${RST} Output: $LAST_OUT"
fi

[ "${#FAIL[@]}" -eq 0 ] || exit 1
