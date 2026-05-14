#!/usr/bin/env bash
#
# Extract TAS2783 firmware blobs from the ASUS SmartAMP driver installer.
#
# Dependencies: wrestool (icoutils), 7z (p7zip)
#
# Usage:
#   ./extract-firmware.sh SmartAMP_TI_DCH_TexasInstruments_Z_V6.3.1.15_47519.exe
#
# Download the installer from:
#   https://www.asus.com/laptops/for-creators/proart/proart-px13-hn7306/helpdesk_download?model2Name=HN7306EA
#   Look for SmartAMP under Utilities → Windows 11 64-bit.

set -euo pipefail

EXE="${1:?Usage: $0 <SmartAMP installer .exe>}"
OUTDIR="firmware"

EXPECTED_EXE_SHA256="8728835795be467d39c721b6245e6e038d44fcbf0d0e49718ef45cb44eb8a3ce"
EXPECTED_0x8_SHA256="9a105de50978fc3250062d66bea6b77f3aaabaf85280739be28ff1ed3ae535ca"
EXPECTED_0xB_SHA256="a975dc7e2340cb5c97259d5e8c3d7e447b5a0af1a91528c058c9fda0adeb74c1"

# Check dependencies
for cmd in wrestool 7z sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Error: $cmd not found. Install icoutils and p7zip." >&2; exit 1; }
done

# Verify installer hash
echo "Verifying installer checksum..."
actual_sha256=$(sha256sum "$EXE" | awk '{print $1}')
if [ "$actual_sha256" != "$EXPECTED_EXE_SHA256" ]; then
    echo "Warning: installer SHA-256 mismatch (expected $EXPECTED_EXE_SHA256, got $actual_sha256)" >&2
    echo "Proceeding anyway — firmware hashes will be checked after extraction." >&2
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Step 1: Extract the 7z archive embedded as a ZIP resource in the outer ASUS PE
echo "Extracting firmware archive from installer..."
wrestool -x --raw --type=ZIP --name=103 "$EXE" > "$TMPDIR/firmwares.7z" 2>/dev/null

# Step 2: Extract the firmware blobs from the 7z archive
7z x "$TMPDIR/firmwares.7z" -o"$TMPDIR/out" "Firmwares/1714-1-0x8.bin" "Firmwares/1714-1-0xB.bin" -y >/dev/null 2>&1

# Verify firmware hashes
echo "Verifying firmware checksums..."
actual_0x8=$(sha256sum "$TMPDIR/out/Firmwares/1714-1-0x8.bin" | awk '{print $1}')
actual_0xB=$(sha256sum "$TMPDIR/out/Firmwares/1714-1-0xB.bin" | awk '{print $1}')

fail=0
if [ "$actual_0x8" != "$EXPECTED_0x8_SHA256" ]; then
    echo "FAIL: 1714-1-0x8.bin hash mismatch" >&2
    fail=1
fi
if [ "$actual_0xB" != "$EXPECTED_0xB_SHA256" ]; then
    echo "FAIL: 1714-1-0xB.bin hash mismatch" >&2
    fail=1
fi
if [ "$fail" -eq 1 ]; then
    echo "Firmware verification failed." >&2
    exit 1
fi

# Copy to output
mkdir -p "$OUTDIR"
cp "$TMPDIR/out/Firmwares/1714-1-0x8.bin" "$OUTDIR/"
cp "$TMPDIR/out/Firmwares/1714-1-0xB.bin" "$OUTDIR/"

echo "OK — firmware extracted to $OUTDIR/"
echo "  $OUTDIR/1714-1-0x8.bin  ($(wc -c < "$OUTDIR/1714-1-0x8.bin") bytes)"
echo "  $OUTDIR/1714-1-0xB.bin  ($(wc -c < "$OUTDIR/1714-1-0xB.bin") bytes)"
echo ""
echo "Install with:"
echo "  sudo install -m 644 $OUTDIR/1714-1-0x8.bin /lib/firmware/1714-1-8.bin"
echo "  sudo install -m 644 $OUTDIR/1714-1-0xB.bin /lib/firmware/1714-1-B.bin"
echo "  sudo install -d -m 755 /lib/firmware/ti/audio/tas2783"
echo "  sudo install -m 644 $OUTDIR/1714-1-0x8.bin /lib/firmware/ti/audio/tas2783/1714-1-8.bin"
echo "  sudo install -m 644 $OUTDIR/1714-1-0xB.bin /lib/firmware/ti/audio/tas2783/1714-1-B.bin"
