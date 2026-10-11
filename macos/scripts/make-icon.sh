#!/bin/sh
set -eu

macos_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_dir="$macos_dir/build/icon"
mkdir -p "$output_dir"

# Apple's compiler supplies the native appearance variants and the macOS 14 fallback.
xcrun actool "$macos_dir/Support/AppIcon.icon" \
    --compile "$output_dir" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --standalone-icon-behavior all \
    --output-partial-info-plist "$output_dir/partial-info.plist" \
    --output-format human-readable-text \
    --warnings --errors

# Retain the standalone icon at the repository's established location.
cp "$output_dir/AppIcon.icns" "$macos_dir/Support/AppIcon.icns"
