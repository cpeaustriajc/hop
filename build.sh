#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
total=7
log="$PWD/build/swift-build.log"

mkdir -p build

echo "[1/$total] swift build -c release (usually 1-3 min); log: $log"
swift build -c release 2>&1 | tee "$log"

echo "[2/$total] locating binary"
bin_dir="$(swift build -c release --show-bin-path)"
echo "      $bin_dir/Hop"

echo "[3/$total] assembling build/Hop.app"
rm -rf build/Hop.app
mkdir -p build/Hop.app/Contents/MacOS build/Hop.app/Contents/Resources
cp "$bin_dir/Hop" build/Hop.app/Contents/MacOS/Hop
cp Resources/Info.plist build/Hop.app/Contents/Info.plist
cp Resources/AppIcon.icns build/Hop.app/Contents/Resources/AppIcon.icns

echo "[4/$total] ad-hoc codesign"
codesign -s - --force build/Hop.app

echo "[5/$total] installing to ~/Applications/Hop.app (replacing any old copy)"
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Hop.app"
cp -R build/Hop.app "$HOME/Applications/Hop.app"
echo "      $HOME/Applications/Hop.app"

echo "[6/$total] registering with LaunchServices (does not change the claude handler)"
lsregister=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
"$lsregister" -f "$HOME/Applications/Hop.app"
mdimport "$HOME/Applications/Hop.app"

echo "[7/$total] done"
echo "$PWD/build/Hop.app"
echo "installed: $HOME/Applications/Hop.app"
