#!/usr/bin/env bash
# Download and verify the user-supplied PenguTunnel 5.0.4 bundle.
set -Eeuo pipefail
REF="6401da473eb24247fc4e78606a37b750dc12c7f4"
REPO="https://raw.githubusercontent.com/V2grop/PenguTunnel/$REF"
CORE_SHA="eb6ddde796ab8e456946324578a88b775b3c37c65a0f2573f133bafd0d7f6058"
ARCHIVE_SHA="1b87d4cbfcf2865916b998593c2e3a2839031a06dc6eeefe2e4008f238918842"
INSTALLER_SHA="a49fc0b1b0c426ce9d6925dddca7d4b3ee8c4bb04952532d5e91232cf0e8a7a2"
VERIFY_ONLY=0
case "${1:-}" in
  --verify-only) VERIFY_ONLY=1 ;;
  '') ;;
  *) echo "Usage: bash install-online.sh [--verify-only]" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo "Too many arguments." >&2; exit 2; }
[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || {
  echo "Linux x86_64/amd64 is required; ARM64 is not supported." >&2; exit 1;
}
if (( ! VERIFY_ONLY && EUID != 0 )); then
  echo "Run as root: sudo bash install-online.sh" >&2; exit 1
fi
for dep in curl sha256sum gzip mktemp cat rm bash; do
  command -v "$dep" >/dev/null || { echo "Missing dependency: $dep" >&2; exit 1; }
done
umask 077
WORK_DIR="$(mktemp -d -t pengutunnel-5.0.4.XXXXXXXX)"
trap 'rm -rf -- "$WORK_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

download() {
  curl --fail --show-error --silent --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 15 --max-time 180 --retry 3 "$1" -o "$2"
}
verify() {
  local got
  got="$(sha256sum "$2")"
  [[ "${got%% *}" == "$1" ]] || {
    echo "ERROR: SHA256 mismatch for ${2##*/}; installation cancelled." >&2; return 1;
  }
}
echo 'Downloading and verifying installer (core 5.0.4 / menu 4.2.5)...'
download "$REPO/install.sh" "$WORK_DIR/install.sh"
verify "$INSTALLER_SHA" "$WORK_DIR/install.sh"
bash -n "$WORK_DIR/install.sh"
: > "$WORK_DIR/pengutunnel.gz"
for ((i=0; i<30; i++)); do
  printf -v part 'pengutunnel.gz.part-%03d' "$i"
  printf 'Downloading core part %d/30...\n' "$((i+1))"
  download "$REPO/releases/5.0.4/$part" "$WORK_DIR/part"
  cat "$WORK_DIR/part" >> "$WORK_DIR/pengutunnel.gz"
done
rm -f -- "$WORK_DIR/part"
verify "$ARCHIVE_SHA" "$WORK_DIR/pengutunnel.gz"
gzip -dc "$WORK_DIR/pengutunnel.gz" > "$WORK_DIR/pengutunnel"
verify "$CORE_SHA" "$WORK_DIR/pengutunnel"
echo 'Installer and core SHA256 verified.'
if (( VERIFY_ONLY )); then
  echo 'Verification complete; no installation or core execution performed.'
  exit 0
fi
# Keep this parent shell so the EXIT trap cleans temporary downloads after the menu exits.
cd "$WORK_DIR"
bash "$WORK_DIR/install.sh"
