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
  rm -rf "$dest"
  cp -R "$src" "$dest"
  xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true
  say "installed. Launch Boltbar from $dest, then press Opt+Space."
}

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

if [ -f "./src-tauri/tauri.conf.json" ] && [ -f "./package.json" ]; then
  command -v cargo >/dev/null 2>&1 || die "Rust/cargo is required to build from source"
  command -v npm >/dev/null 2>&1 || die "npm is required to build from source"
  say "building Boltbar from this checkout (universal if both Apple targets are installed)"
  npm install
  if rustup target list --installed 2>/dev/null | grep -q 'aarch64-apple-darwin' \
    && rustup target list --installed 2>/dev/null | grep -q 'x86_64-apple-darwin'; then
    npm run tauri -- build --target universal-apple-darwin
  else
    npm run tauri -- build
  fi
  APP=$(find target src-tauri/target -path '*/bundle/macos/Boltbar.app' -type d 2>/dev/null | head -n 1)
  [ -n "$APP" ] || die "the build finished without Boltbar.app"
  install_app "$APP"
  exit 0
fi

die "set BOLTBAR_REPO=owner/name after publishing a GitHub repo, or run this script from a Boltbar checkout"
