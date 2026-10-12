#!/bin/sh
# Prepares the JetKVM Desktop firmware the app's setup sheet installs:
# checks the fork's build against the SHA-256 in Support/Firmware.json and
# gzips it into build/firmware (next to a copy of the manifest).
#
#   scripts/bundle-firmware.sh <jetkvm_app> <Firmware.json> <out dir>
#
# Without the binary the app is built without firmware (the sheet says so).
set -eu
binary=$1 manifest=$2 out=$3
want=$(sed -n 's/.*"sha256": *"\([0-9a-f]*\)".*/\1/p' "$manifest")
if [ -f "$out/jetkvm_app.gz" ] && [ "$(cat "$out/sha256" 2>/dev/null)" = "$want" ]; then
	exit 0
fi
rm -rf "$out"
if [ ! -f "$binary" ]; then
	echo "warning: $binary not found: building without firmware (FORK_BINARY=... to set it)" >&2
	exit 0
fi
have=$(shasum -a 256 "$binary" | cut -d ' ' -f 1)
if [ "$have" != "$want" ]; then
	echo "error: $binary is $have, Support/Firmware.json pins $want" >&2
	exit 1
fi
mkdir -p "$out"
gzip -9 -n -c "$binary" > "$out/jetkvm_app.gz"
cp "$manifest" "$out/Firmware.json"
echo "$want" > "$out/sha256"
echo "bundled firmware $(sed -n 's/.*"tag": *"\([^"]*\)".*/\1/p' "$manifest") ($(du -h "$out/jetkvm_app.gz" | cut -f 1) gzipped)"
