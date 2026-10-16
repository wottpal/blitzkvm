#!/bin/sh
# Publishes the notarized app as a GitHub release that BlitzKVM's updater
# finds (SUFeedURL: the latest release's appcast.xml): the archive, its
# appcast signed with the update key from the login keychain (account
# "blitzkvm"), the release notes embedded in it, delta updates from the last
# releases (a few hundred KB instead of the whole app; Sparkle falls back to
# the archive) and SHA256SUMS.txt. The version is the app's
# CFBundleShortVersionString; the tag is v<version>.
# Run through `make release NOTES=<notes.md>`, which notarizes HEAD first.
#
#   scripts/release.sh <release notes.md>
set -eu
notes=$1
macos=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
root=$(dirname "$macos")
repo=wottpal/blitzkvm
bin="$macos/.build/artifacts/sparkle/Sparkle/bin"
app="$macos/build/BlitzKVM.app"
zip="$macos/build/BlitzKVM.zip"
fail() { echo "release: $*" >&2; exit 2; }

[ -f "$notes" ] || fail "no release notes at '$notes' (NOTES=…)"
version=$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")
build=$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")
tag="v$version"

# Only a notarized build of the pushed main, signed for this app's key.
git -C "$root" diff --quiet HEAD || fail "the tree has uncommitted changes"
git -C "$root" fetch -q origin main
[ "$(git -C "$root" rev-parse HEAD)" = "$(git -C "$root" rev-parse origin/main)" ] || fail "HEAD is not origin/main"
[ "$build" = "$(git -C "$root" rev-list --count HEAD)" ] || fail "the app is build $build, not of HEAD (make notarize)"
xcrun stapler validate "$app" > /dev/null || fail "$app is not notarized (make notarize)"
key=$("$bin/generate_keys" --account blitzkvm -p 2> /dev/null) || fail "no update signing key in the keychain (account blitzkvm)"
[ "$key" = "$(plutil -extract SUPublicEDKey raw "$app/Contents/Info.plist")" ] || fail "the keychain's update key doesn't match SUPublicEDKey"
if gh release view "$tag" -R "$repo" > /dev/null 2>&1; then fail "$tag already exists"; fi

out="$macos/build/release/$tag"
rm -rf "$out"
mkdir -p "$out"
cp "$zip" "$out/BlitzKVM.zip"
cp "$notes" "$out/BlitzKVM.md" # generate_appcast embeds it as the update's notes
# The last releases' archives (cached in build/archives), for generate_appcast
# to make deltas from; the appcast lists only the new release.
archives="$macos/build/archives"
mkdir -p "$archives"
for old in $(gh release list -R "$repo" --exclude-drafts --exclude-pre-releases --limit 5 --json tagName -q '.[].tagName'); do
	file="$archives/BlitzKVM-${old#v}.zip"
	if [ ! -f "$file" ]; then
		gh release download "$old" -R "$repo" -p BlitzKVM.zip -O "$file.part" && mv "$file.part" "$file" || {
			rm -f "$file.part"
			echo "release: $old has no archive, so no delta from it" >&2
			continue
		}
	fi
	ln -f "$file" "$out/"
done
"$bin/generate_appcast" --account blitzkvm --embed-release-notes --link "https://github.com/$repo" --maximum-versions 1 \
	--download-url-prefix "https://github.com/$repo/releases/download/$tag/" -o "$out/appcast.xml" "$out"
grep -q "sparkle:edSignature" "$out/appcast.xml" || fail "the appcast's archive is unsigned"
(cd "$out" && shasum -a 256 BlitzKVM.zip > SHA256SUMS.txt)
set -- "$out"/*.delta
[ -e "$1" ] || set --
echo "release: $# delta updates"

gh release create "$tag" -R "$repo" --target "$(git -C "$root" rev-parse HEAD)" --title "BlitzKVM $version" \
	--notes-file "$notes" --latest "$out/BlitzKVM.zip" "$out/appcast.xml" "$out/SHA256SUMS.txt" "$@"
echo "released $tag (build $build): https://github.com/$repo/releases/tag/$tag"
