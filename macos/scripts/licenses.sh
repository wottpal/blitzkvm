#!/bin/sh
# Assembles the licenses the app shows (BlitzKVM › Licenses…): BlitzKVM's
# own, the code compiled into the app (FSR, Sparkle) and its helper, and the
# firmware builds JetKVM Setup installs (GPL-2.0, with where their source
# is). Go modules are taken from what the helper links, with their license
# files from the module cache, so the list follows go.mod. Lines starting
# with "# " and "## " are headings.
#
#   scripts/licenses.sh <Firmware.json> <output file>
set -eu
manifest=$1 out=$2
macos=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
root=$(dirname "$macos")
mkdir -p "$(dirname "$out")"
tmp="$out.tmp"

section() { printf '\n## %s\n\n' "$1"; }

{
	printf '# BlitzKVM\n\n'
	cat "$root/LICENSE"

	printf '\n# Open-source software in BlitzKVM\n'
	section "AMD FidelityFX Super Resolution 1 (upscaling, ported to Metal in FSR.swift)"
	cat "$macos/Support/Licenses/FidelityFX-FSR1.txt"

	sparkle="$macos/.build/artifacts/sparkle/Sparkle"
	section "Sparkle $(plutil -extract CFBundleShortVersionString raw "$sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/Versions/B/Resources/Info.plist") (updates)"
	cat "$sparkle/LICENSE"

	goroot=$(cd "$root" && go env GOROOT)
	section "Go standard library and runtime $(cd "$root" && go env GOVERSION) (in the helper)"
	# Homebrew's Go keeps LICENSE next to GOROOT (libexec), not in it.
	if [ -f "$goroot/LICENSE" ]; then cat "$goroot/LICENSE"; else cat "$goroot/../LICENSE"; fi
	printf '\n'
	cat "$goroot/PATENTS"

	(cd "$root" && go list -deps -f '{{with .Module}}{{if not .Main}}{{.Path}} {{.Version}} {{.Dir}}{{end}}{{end}}' ./cmd/blitzkvm-engine) |
		sort -u | while read -r path version dir; do
			files=$(find "$dir" -maxdepth 1 -type f \( -iname 'LICENSE*' -o -iname 'LICENCE*' -o -iname 'COPYING*' -o -iname 'NOTICE*' -o -iname 'PATENTS*' \) | sort)
			if [ -z "$files" ]; then
				echo "licenses: no license file in $path $version ($dir)" >&2
				exit 1
			fi
			section "$path $version (Go module in the helper)"
			for f in $files; do
				cat "$f"
				printf '\n'
			done
		done

	printf '\n# JetKVM firmware bundled for installation\n\n'
	printf 'JetKVM Setup installs these builds of the JetKVM firmware on a device. They are licensed under the GNU General Public License, version 2 (below), and their complete source code is published:\n\n'
	count=$(plutil -extract builds raw "$manifest")
	i=0
	while [ "$i" -lt "$count" ]; do
		kind=$(plutil -extract "builds.$i.kind" raw "$manifest")
		tag=$(plutil -extract "builds.$i.tag" raw "$manifest")
		case $kind in
		blitzkvm) printf -- '- BlitzKVM firmware %s: https://github.com/wottpal/kvm/tree/%s\n' "$tag" "$tag" ;;
		*) printf -- '- JetKVM firmware %s: https://github.com/jetkvm/kvm/tree/%s\n' "$tag" "$tag" ;;
		esac
		i=$((i + 1))
	done
	printf '\nBoth include LVGL (MIT), the BlitzKVM build also libopus (BSD); the licenses of the Go modules they contain are in their source trees.\n'
	section "GNU General Public License, version 2"
	cat "$macos/Support/Licenses/GPL-2.0.txt"
	section "libopus"
	cat "$macos/Support/Licenses/libopus.txt"
	section "LVGL"
	cat "$macos/Support/Licenses/LVGL.txt"
} > "$tmp"
mv "$tmp" "$out"
echo "licenses: $(grep -c '^## ' "$out") sections in $out"
