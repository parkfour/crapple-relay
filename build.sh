#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

echo "=================================================="
echo " Building iMessage Relay Daemon for macOS 12.7"
echo "=================================================="

OUTPUT="imessage-relay"
ENTITLEMENTS="entitlements.plist"

# 1. Compile directly linking IMCore and IMFoundation frameworks
echo "[+] Compiling native daemon with clang (ARC enabled)..."
clang -fobjc-arc \
      -fno-modules \
      -O2 \
      -Wall \
      -Wno-deprecated-declarations \
      -F/System/Library/PrivateFrameworks \
      -framework Foundation \
      -framework IMCore \
      -framework IMFoundation \
      -framework IMSharedUtilities \
      -lsqlite3 \
      -I. \
      Sources/*.m \
      main.m \
      -o "$OUTPUT"

# 2. Ad-hoc code sign with required Monterey private entitlements
echo "[+] Signing binary with entitlements..."
codesign -s - --force --entitlements "$ENTITLEMENTS" "$OUTPUT"

echo "[+] Verifying code signature..."
codesign -v "$OUTPUT"

echo "=================================================="
echo " Build successful: $DIR/$OUTPUT"
echo " Run with: ./$OUTPUT --port 5569"
echo "=================================================="
