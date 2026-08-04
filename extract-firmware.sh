#!/usr/bin/env bash
#
# Extract TAS2783 firmware blobs from the ASUS SmartAMP driver installer.
#
# Dependencies: wrestool (icoutils), 7z (p7zip)
#
# Usage:
#   ./extract-firmware.sh SmartAMP_TI_DCH_TexasInstruments_Z_V6.3.1.15_47519.exe
#
# Per-system identifiers (installer & firmware filenames + SHA-256s) live in
# systems/<MODEL>.conf. Override the default with: SYSTEM_CONF=path ./extract-firmware.sh ...
#
# Download the installer from:
#   https://www.asus.com/laptops/for-creators/proart/proart-px13-hn7306/helpdesk_download?model2Name=HN7306EA
#   Look for TI Smart Amplifier Driver for Speakers under Driver & Tools → Windows 11 64-bit.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SYSTEM_CONF="${SYSTEM_CONF:-$SCRIPT_DIR/systems/HN7306EAC.conf}"

EXE="${1:?Usage: $0 <SmartAMP installer .exe>}"
OUTDIR="firmware"

# shellcheck source=/dev/null
source "$SYSTEM_CONF"

# Check dependencies
for cmd in wrestool 7z sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Error: $cmd not found. Install icoutils and p7zip." >&2; exit 1; }
done

# Verify installer hash
echo "Verifying installer checksum..."
actual_sha256=$(sha256sum "$EXE" | awk '{print $1}')
if [ "$actual_sha256" != "$INSTALLER_SHA256" ]; then
    echo "Warning: installer SHA-256 mismatch (expected $INSTALLER_SHA256, got $actual_sha256)" >&2
    echo "Proceeding anyway - firmware hashes will be checked after extraction." >&2
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Step 1: Extract the 7z archive embedded as a ZIP resource in the outer ASUS PE
echo "Extracting firmware archive from installer..."
wrestool -x --raw --type=ZIP --name=103 "$EXE" > "$TMPDIR/firmwares.7z" 2>/dev/null

# Step 2: Extract the firmware blobs from the 7z archive
7z x "$TMPDIR/firmwares.7z" -o"$TMPDIR/out" "Firmwares/$FIRMWARE_8_NAME" "Firmwares/$FIRMWARE_B_NAME" -y >/dev/null 2>&1

# Verify firmware hashes
echo "Verifying firmware checksums..."
actual_8=$(sha256sum "$TMPDIR/out/Firmwares/$FIRMWARE_8_NAME" | awk '{print $1}')
actual_B=$(sha256sum "$TMPDIR/out/Firmwares/$FIRMWARE_B_NAME" | awk '{print $1}')

fail=0
if [ "$actual_8" != "$FIRMWARE_8_SHA256" ]; then
    echo "FAIL: $FIRMWARE_8_NAME hash mismatch" >&2
    fail=1
fi
if [ "$actual_B" != "$FIRMWARE_B_SHA256" ]; then
    echo "FAIL: $FIRMWARE_B_NAME hash mismatch" >&2
    fail=1
fi
if [ "$fail" -eq 1 ]; then
    echo "Firmware verification failed." >&2
    exit 1
fi

# Copy to output
mkdir -p "$OUTDIR"
cp "$TMPDIR/out/Firmwares/$FIRMWARE_8_NAME" "$OUTDIR/"
cp "$TMPDIR/out/Firmwares/$FIRMWARE_B_NAME" "$OUTDIR/"

# Kernel-side names drop the "0x" prefix (1714-1-0x8.bin -> 1714-1-8.bin)
install_8="${FIRMWARE_8_NAME/0x/}"
install_B="${FIRMWARE_B_NAME/0x/}"

echo "OK - firmware extracted to $OUTDIR/"
echo "  $OUTDIR/$FIRMWARE_8_NAME  ($(wc -c < "$OUTDIR/$FIRMWARE_8_NAME") bytes)"
echo "  $OUTDIR/$FIRMWARE_B_NAME  ($(wc -c < "$OUTDIR/$FIRMWARE_B_NAME") bytes)"
echo ""
echo "Install with:"
echo "  sudo install -m 644 $OUTDIR/$FIRMWARE_8_NAME /lib/firmware/$install_8"
echo "  sudo install -m 644 $OUTDIR/$FIRMWARE_B_NAME /lib/firmware/$install_B"
echo "  sudo install -d -m 755 /lib/firmware/ti/audio/tas2783"
echo "  sudo install -m 644 $OUTDIR/$FIRMWARE_8_NAME /lib/firmware/ti/audio/tas2783/$install_8"
echo "  sudo install -m 644 $OUTDIR/$FIRMWARE_B_NAME /lib/firmware/ti/audio/tas2783/$install_B"
