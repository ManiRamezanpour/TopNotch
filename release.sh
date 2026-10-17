#!/bin/zsh
# Build, package a .dmg and publish a GitHub release. Usage: ./release.sh 1.1.0 "what changed"
set -e
cd "${0:a:h}"
V=${1:?usage: ./release.sh <version> [notes]}
[[ -z $(git status --porcelain) ]] || { echo "commit your changes first"; exit 1; }
VERSION=$V ./build.sh
./dmg.sh
git tag "v$V" && git push origin "v$V"
gh release create "v$V" TopNotch.dmg --title "TopNotch $V" --notes "${2:-}

## Install
1. Download **TopNotch.dmg**, open it, drag **TopNotch** onto **Applications**.
2. Open it. macOS will refuse (it's not notarized) — click **Done**.
3. **System Settings → Privacy & Security** → scroll down → **Open Anyway**.

Or in Terminal: \`xattr -dr com.apple.quarantine /Applications/TopNotch.app\`

Requires macOS 14+ on Apple Silicon."
