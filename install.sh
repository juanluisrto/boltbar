#!/bin/sh
# Install Boltbar on macOS from a GitHub Release, or build from this checkout.
#   curl -fsSL https://raw.githubusercontent.com/juanluisrto/boltbar/main/install.sh | sh
#   BOLTBAR_REPO=juanluisrto/boltbar ./install.sh
set -eu

REPO="${BOLTBAR_REPO:-juanluisrto/boltbar}"
PREFIX="${BOLTBAR_PREFIX:-/Applications}"

if [ -z "$REPO" ]; then
  # Infer owner/name when this file is fetched from GitHub.
  case "${0:-}" in
    *githubusercontent.com/*)
      REPO=$(printf '%s\n' "$0" | sed -n 's#.*githubusercontent.com/\([^/]*\)/\([^/]*\)/.*#\1/\2#p')
      ;;
  esac
fi

if [ -z "$REPO" ] && [ -n "${INSTALL_SH_URL:-}" ]; then
  REPO=$(printf '%s\n' "$INSTALL_SH_URL" | sed -n 's#.*githubusercontent.com/\([^/]*\)/\([^/]*\)/.*#\1/\2#p')
fi

say() { printf 'boltbar: %s\n' "$*"; }
die() { printf 'boltbar: %s\n' "$*" >&2; exit 1; }

uname_s=$(uname -s)
[ "$uname_s" = Darwin ] || die "this installer is for macOS (found $uname_s)"

install_app() {
  src=$1
  dest="$PREFIX/Boltbar.app"
  say "installing to $dest"
  mkdir -p "$PREFIX"
  stage=$(mktemp -d "$PREFIX/.boltbar-install.XXXXXX")
  cp -R "$src" "$stage/Boltbar.app"
  if [ -e "$dest" ]; then
    backup="$PREFIX/Boltbar.backup.$(date +%Y%m%d-%H%M%S).app"
    [ ! -e "$backup" ] || die "backup already exists: $backup"
    mv "$dest" "$backup"
    say "previous installation preserved at $backup"
  fi
  mv "$stage/Boltbar.app" "$dest"
  rmdir "$stage"
  say "installed. Launch Boltbar from $dest, then press Opt+Space."
}

if [ -f ./Package.swift ] && [ -f ./scripts/build-native.sh ]; then
  say "building the native Swift checkout"
  sh scripts/build-native.sh
  install_app "build/Boltbar.app"
  exit 0
fi

if [ -n "$REPO" ]; then
  API="https://api.github.com/repos/${REPO}/releases/latest"
  say "looking up latest release of $REPO"
  if command -v curl >/dev/null 2>&1; then
    JSON=$(curl -fsSL "$API" || true)
  else
    JSON=$(wget -qO- "$API" || true)
  fi
  ASSET=$(printf '%s\n' "$JSON" | sed -n 's/.*"browser_download_url": "\([^"]*Boltbar-[^"]*universal\.zip\)".*/\1/p' | head -n 1)
  if [ -n "$ASSET" ]; then
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    say "downloading $ASSET"
    curl -fL "$ASSET" -o "$TMP/boltbar.zip"
    unzip -q "$TMP/boltbar.zip" -d "$TMP/out"
    APP=$(find "$TMP/out" -name 'Boltbar.app' -type d | head -n 1)
    [ -n "$APP" ] || die "the release zip did not contain Boltbar.app"
    install_app "$APP"
    exit 0
  fi
  say "no published universal zip yet; falling back to a source build if possible"
fi

die "No published app found. Clone the Swift branch and run sh scripts/build-native.sh."
