#!/bin/bash
# End to end, the updater: an "old" copy of build/BlitzKVM.app and a "new"
# one (build 999999) under a test bundle id (the real app's settings stay
# untouched), the new one published in a local appcast signed with the
# update key from the login keychain (account "blitzkvm"; maintainers only).
# The old copy runs a self-test against the emulator with automatic updates
# on and must be replaced by the new one after it quits; again with the old
# copy's archive in the feed too, so it must update through the delta update
# made from it (as releases offer them). Then the negative control: an
# archive changed after signing must not be installed.
#
#   scripts/update-test.sh <emulator address> <signing identity>
set -uo pipefail
emulator=$1 identity=$2
macos=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bin="$macos/.build/artifacts/sparkle/Sparkle/bin"
src="$macos/build/BlitzKVM.app"
bid=xyz.scio.blitzkvm.updatetest
port=18777
work=$(mktemp -d "${TMPDIR:-/tmp}/blitzkvm-update-test.XXXXXX")
trap 'defaults delete $bid > /dev/null 2>&1; rm -rf "$work"' EXIT

copy() { # dir build version
	mkdir -p "$1"
	ditto "$src" "$1/BlitzKVM.app"
	local plist="$1/BlitzKVM.app/Contents/Info.plist"
	plutil -replace CFBundleIdentifier -string "$bid" "$plist"
	plutil -replace CFBundleVersion -string "$2" "$plist"
	plutil -replace CFBundleShortVersionString -string "$3" "$plist"
	codesign --force --options runtime --sign "$identity" --identifier "$bid" "$1/BlitzKVM.app" 2>&1 | grep -v "replacing existing" >&2
}
version() { plutil -extract CFBundleVersion raw "$1/BlitzKVM.app/Contents/Info.plist"; }

# run <case>: publishes the new copy (signed, tampered or delta), runs the
# old one, prints the old copy's build afterwards.
run() {
	local dir="$work/$1"
	copy "$dir/old" "$(version "$(dirname "$src")")" 0.0.1
	copy "$dir/new" 999999 9.9.9
	mkdir -p "$dir/feed"
	ditto -c -k --sequesterRsrc --keepParent "$dir/new/BlitzKVM.app" "$dir/feed/BlitzKVM.zip"
	if [ "$1" = delta ]; then
		ditto -c -k --sequesterRsrc --keepParent "$dir/old/BlitzKVM.app" "$dir/feed/BlitzKVM-old.zip"
	fi
	printf -- '- An update made by update-test.sh.\n' > "$dir/feed/BlitzKVM.md"
	"$bin/generate_appcast" --account blitzkvm --embed-release-notes --maximum-versions 1 --download-url-prefix "http://127.0.0.1:$port/" \
		-o "$dir/feed/appcast.xml" "$dir/feed" > /dev/null || exit 1
	if [ "$1" = tampered ]; then
		echo changed > "$dir/new/BlitzKVM.app/Contents/Resources/changed.txt"
		ditto -c -k --sequesterRsrc --keepParent "$dir/new/BlitzKVM.app" "$dir/feed/BlitzKVM.zip"
	fi
	python3 -m http.server "$port" --bind 127.0.0.1 --directory "$dir/feed" > "$dir/http.log" 2>&1 &
	server=$!
	trap 'kill $server 2> /dev/null' EXIT # run's subshell
	sleep 1
	defaults delete "$bid" > /dev/null 2>&1
	defaults write "$bid" SUAutomaticallyUpdate -bool true
	BLITZKVM_UPDATE_FEED="http://127.0.0.1:$port/appcast.xml" "$dir/old/BlitzKVM.app/Contents/MacOS/BlitzKVM" \
		--device "$emulator" --h264 --selftest 25 --view-only --window-size 480x270 > "$dir/selftest.json" 2>&1
	for _ in $(seq 1 30); do
		[ "$(version "$dir/old")" = 999999 ] && break
		sleep 1
	done
	if [ "$1" = delta ]; then
		grep -q "GET /BlitzKVM999999-.*\.delta" "$dir/http.log" || { echo "update-test ($1): the delta was never downloaded" >&2; exit 1; }
		! grep -q "GET /BlitzKVM.zip" "$dir/http.log" || { echo "update-test ($1): the whole archive was downloaded" >&2; exit 1; }
	else
		grep -q "GET /BlitzKVM.zip" "$dir/http.log" || { echo "update-test ($1): the update was never downloaded" >&2; exit 1; }
	fi
	version "$dir/old"
}

[ "$(run signed)" = 999999 ] || { echo "update-test: the signed update was not installed" >&2; exit 1; }
[ "$(run delta)" = 999999 ] || { echo "update-test: the delta update was not installed" >&2; exit 1; }
[ "$(run tampered)" != 999999 ] || { echo "update-test: an archive changed after signing was installed" >&2; exit 1; }
echo "update-test passed: a signed update was downloaded and installed on quit, also as a delta update, an archive changed after signing was refused"
