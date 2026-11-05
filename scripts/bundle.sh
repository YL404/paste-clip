#!/bin/zsh
# Builds PasteClip and assembles a signed build/PasteClip.app.
# Usage: scripts/bundle.sh [release|debug]
# Signing identity: $SIGN_IDENTITY, else the first "Apple Development" identity, else ad-hoc.
set -euo pipefail
cd "${0:A:h}/.."

config="${1:-release}"
swift build -c "$config"
bin_dir="$(swift build -c "$config" --show-bin-path)"

app="build/PasteClip.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/PasteClip" "$app/Contents/MacOS/"
cp Support/Info.plist "$app/Contents/"
# Compiles the Icon Composer file into Assets.car (Liquid Glass icon) and AppIcon.icns.
xcrun actool Support/AppIcon.icon --compile "$app/Contents/Resources" \
  --platform macosx --minimum-deployment-target 26.0 --app-icon AppIcon \
  --output-partial-info-plist /dev/null --errors --warnings >/dev/null

identity="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}"
if [[ -z "$identity" ]]; then
  # Ad-hoc signatures change on every build, so macOS forgets the Accessibility grant.
  echo "warning: no Apple Development identity found, signing ad-hoc" >&2
  identity="-"
fi
codesign --force --sign "$identity" "$app"
echo "$app"
