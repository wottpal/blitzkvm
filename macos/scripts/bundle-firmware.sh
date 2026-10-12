#!/bin/sh
# Prepares the firmware builds JetKVM Setup installs (Support/Firmware.json):
# each is checked against its SHA-256 and gzipped into the output directory
# as <tag with / as ->.gz, next to a copy of the manifest. A build with a
# "url" is downloaded once (cached under build/firmware-cache); the JetKVM
# Desktop build comes from the fork's own build output.
#
#   scripts/bundle-firmware.sh <fork jetkvm_app> <Firmware.json> <out dir>
#
# A build whose binary is missing is left out (JetKVM Setup offers the rest).
set -eu
fork=$1 manifest=$2 out=$3
cache=$(dirname "$out")/firmware-cache
mkdir -p "$out" "$cache"
cp "$manifest" "$out/Firmware.json"
count=$(plutil -extract builds raw "$manifest")
i=0
while [ "$i" -lt "$count" ]; do
	tag=$(plutil -extract "builds.$i.tag" raw "$manifest")
	want=$(plutil -extract "builds.$i.sha256" raw "$manifest")
	url=$(plutil -extract "builds.$i.url" raw "$manifest" 2>/dev/null || true)
	i=$((i + 1))
	file="$out/$(echo "$tag" | tr / -).gz"
	if [ -f "$file" ] && [ "$(cat "$file.sha256" 2>/dev/null)" = "$want" ]; then
		continue
	fi
	rm -f "$file" "$file.sha256"
	if [ -n "$url" ]; then
		binary="$cache/$want"
		if [ ! -f "$binary" ]; then
			curl -fsSL "$url" -o "$binary.part" && mv "$binary.part" "$binary" || {
				rm -f "$binary.part"
				echo "warning: could not download $tag from $url: left out" >&2
				continue
			}
		fi
	else
		binary=$fork
	fi
	if [ ! -f "$binary" ]; then
		echo "warning: $binary not found: $tag left out (FORK_BINARY=... to set it)" >&2
		continue
	fi
	have=$(shasum -a 256 "$binary" | cut -d ' ' -f 1)
	if [ "$have" != "$want" ]; then
		echo "error: $binary is $have, Support/Firmware.json pins $want for $tag" >&2
		exit 1
	fi
	gzip -9 -n -c "$binary" > "$file"
	echo "$want" > "$file.sha256"
	echo "bundled $tag ($(du -h "$file" | cut -f 1 | tr -d ' ') gzipped)"
done
