#!/bin/bash
# Notarizes a signed app with the Apple ID signed into Xcode (Settings →
# Accounts): no app-specific password or API key. The app is wrapped in a
# minimal Xcode archive, uploaded with `xcodebuild -exportArchive`
# (destination upload), and the notarized, stapled app is fetched with
# `xcodebuild -exportNotarizedApp` once Apple has processed it.
#
#   scripts/notarize.sh <signed.app> <team-id> <output-dir>
set -euo pipefail

app="$1" team="$2" out="$3"
name="$(basename "$app" .app)"
work="$(mktemp -d "${TMPDIR:-/tmp}/notarize.XXXXXX")"
trap 'rm -rf "$work"' EXIT
archive="$work/$name.xcarchive"
plist() { /usr/libexec/PlistBuddy -c "Print $1" "$app/Contents/Info.plist"; }
identity="$(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p')"
[ -n "$identity" ] || { echo "notarize: $app is not signed with a Developer ID Application identity" >&2; exit 2; }

mkdir -p "$archive/Products/Applications"
ditto "$app" "$archive/Products/Applications/$name.app"
cat > "$archive/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>ApplicationProperties</key><dict>
		<key>ApplicationPath</key><string>Applications/$name.app</string>
		<key>Architectures</key><array><string>arm64</string></array>
		<key>CFBundleIdentifier</key><string>$(plist CFBundleIdentifier)</string>
		<key>CFBundleShortVersionString</key><string>$(plist CFBundleShortVersionString)</string>
		<key>CFBundleVersion</key><string>$(plist CFBundleVersion)</string>
		<key>SigningIdentity</key><string>$identity</string>
		<key>Team</key><string>$team</string>
	</dict>
	<key>ArchiveVersion</key><integer>2</integer>
	<key>CreationDate</key><date>$(date -u +%Y-%m-%dT%H:%M:%SZ)</date>
	<key>Name</key><string>$name</string>
	<key>SchemeName</key><string>$name</string>
</dict></plist>
EOF
cat > "$work/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>method</key><string>developer-id</string>
	<key>destination</key><string>upload</string>
	<key>teamID</key><string>$team</string>
	<key>signingStyle</key><string>manual</string>
	<key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
EOF

echo "notarize: uploading $name with the Xcode account"
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$work/ExportOptions.plist" \
	-exportPath "$work/upload" -allowProvisioningUpdates 2>&1 | grep -vE "Progress [0-9]+ %" | tail -5

echo "notarize: waiting for Apple (usually a few minutes)"
for _ in $(seq 1 60); do
	if xcodebuild -exportNotarizedApp -archivePath "$archive" -exportPath "$work/notarized" >"$work/export.log" 2>&1; then
		rm -rf "$out/$name.app"
		mkdir -p "$out"
		ditto "$work/notarized/$name.app" "$out/$name.app"
		xcrun stapler validate "$out/$name.app"
		spctl --assess --type execute -vv "$out/$name.app"
		exit 0
	fi
	sleep 30
done
echo "notarize: not notarized after 30 minutes; last output:" >&2
cat "$work/export.log" >&2
exit 1
