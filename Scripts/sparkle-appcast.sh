#!/usr/bin/env bash
set -euo pipefail

# Build a Sparkle appcast from a folder of archives.
#
# Usage:
#   Scripts/sparkle-appcast.sh <updates-folder> <download-url-prefix>
#
# Put AgentNotch.zip (or .dmg) in <updates-folder>. Optional matching
# AgentNotch.md / AgentNotch.html becomes the release notes.
# The private EdDSA key is SPARKLE_ED_KEY_FILE, or .sparkle/ed-private-key.
#
# GitHub Releases host the zip. GitHub Pages hosts appcast.xml.
# Sparkle reads https://updates.lucabecker.dev/appcast.xml.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY="${SPARKLE_ED_KEY_FILE:-$ROOT/.sparkle/ed-private-key}"
SPARKLE_VERSION="2.9.6"
SPARKLE_TARBALL_SHA256="52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192"
TOOLS_DIR="$ROOT/.sparkle/Sparkle-$SPARKLE_VERSION"

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <updates-folder> <download-url-prefix>" >&2
  echo "example: $0 dist/updates https://github.com/itslucadev/AgentNotch/releases/download/v1.1/" >&2
  exit 1
fi

UPDATES="$1"
PREFIX="$2"

if [[ ! -f "$KEY" ]]; then
  echo "missing Sparkle private key: $KEY" >&2
  echo "Back this file up; losing it blocks signed updates until you rotate keys." >&2
  exit 1
fi

if [[ ! -d "$UPDATES" ]]; then
  echo "updates folder not found: $UPDATES" >&2
  exit 1
fi

generate_appcast=""
if [[ -x "$TOOLS_DIR/bin/generate_appcast" ]]; then
  generate_appcast="$TOOLS_DIR/bin/generate_appcast"
elif [[ -x "$TOOLS_DIR/generate_appcast" ]]; then
  generate_appcast="$TOOLS_DIR/generate_appcast"
fi

if [[ -z "$generate_appcast" ]]; then
  mkdir -p "$ROOT/.sparkle"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  tarball="$tmp/Sparkle-${SPARKLE_VERSION}.tar.xz"
  echo "Downloading Sparkle $SPARKLE_VERSION tools…"
  curl -fsSL \
    "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" \
    -o "$tarball"
  actual="$(shasum -a 256 "$tarball" | awk '{ print $1 }')"
  if [[ "$actual" != "$SPARKLE_TARBALL_SHA256" ]]; then
    echo "Sparkle tarball sha256 mismatch" >&2
    echo "expected $SPARKLE_TARBALL_SHA256" >&2
    echo "actual   $actual" >&2
    exit 1
  fi
  tar -xJ -f "$tarball" -C "$tmp"
  found="$(find "$tmp" -name generate_appcast -type f | head -n 1)"
  if [[ -z "$found" ]]; then
    echo "Sparkle archive did not contain generate_appcast" >&2
    exit 1
  fi
  mkdir -p "$TOOLS_DIR/bin"
  bindir="$(dirname "$found")"
  cp -R "$bindir"/. "$TOOLS_DIR/bin/"
  generate_appcast="$TOOLS_DIR/bin/generate_appcast"
  chmod +x "$generate_appcast"
fi

args=(
  --ed-key-file "$KEY"
  --download-url-prefix "$PREFIX"
  --link "https://lucabecker.dev/agent-notch"
)

"$generate_appcast" "${args[@]}" "$UPDATES"

echo
echo "Appcast written in $UPDATES"
echo "Upload AgentNotch.zip to the GitHub release."
echo "Commit appcast.xml on the appcast branch (Scripts/release.sh does this)."
echo "Sparkle reads https://updates.lucabecker.dev/appcast.xml"
