#!/usr/bin/env bash
set -Eeuo pipefail

REPO="https://raw.githubusercontent.com/V2grop/PenguTunnel/main"
EXPECTED_SHA="793e594170065186df4979e6fffa360b6b9796f7cb4595493c8f48c2ed4cc9fd"

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo bash install-online.sh"
  exit 1
fi

command -v sha256sum >/dev/null || {
  echo "sha256sum is required."
  exit 1
}

if command -v curl >/dev/null; then
  download() { curl -fLsS --retry 2 "$1" -o "$2"; }
elif command -v wget >/dev/null; then
  download() { wget -q "$1" -O "$2"; }
else
  echo "Install curl or wget first."
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading installer..."
download "$REPO/install.sh" "$TMP/install.sh"

echo "Downloading PenguTunnel core..."
download "$REPO/PenguTunnel-4.2.1-pengutunnel" \
  "$TMP/pengutunnel"

ACTUAL_SHA="$(sha256sum "$TMP/pengutunnel" | awk '{print $1}')"

if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
  echo "ERROR: SHA256 mismatch. Installation cancelled."
  exit 1
fi

chmod +x "$TMP/pengutunnel"
echo "SHA256 verified."
cd "$TMP"
exec bash "$TMP/install.sh"
