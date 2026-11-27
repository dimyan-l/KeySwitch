#!/bin/bash
# Собрать, установить и выложить релиз KeySwitch с этого Mac.
# Нужны: постоянный сертификат подписи (см. build_app.sh) и gh (brew install gh && gh auth login).
# Использование: tools/release.sh [тег-старого-релиза-для-удаления]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
TAG="v$VERSION"
NOTES="Design/release-notes/$TAG.md"
OLD_TAG="${1:-}"
[[ -f "$NOTES" ]] || { echo "Нет описания релиза: $NOTES" >&2; exit 1; }
command -v gh >/dev/null || { echo "Нужен gh: brew install gh && gh auth login" >&2; exit 1; }
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "Релиз $TAG уже существует." >&2
  exit 1
fi

./build_app.sh --install
open /Applications/KeySwitch.app

mkdir -p dist
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto build/KeySwitch.app "$STAGE/KeySwitch.app"
ln -s /Applications "$STAGE/Applications"
rm -f dist/KeySwitch.dmg
hdiutil create -volname "KeySwitch $VERSION" -srcfolder "$STAGE" -format UDZO dist/KeySwitch.dmg >/dev/null
SHA="$(shasum -a 256 dist/KeySwitch.dmg | cut -d' ' -f1)"
{ cat "$NOTES"; printf '\nСборка: `KeySwitch.dmg`, SHA-256 `%s`.\n' "$SHA"; } > "$STAGE/notes.md"

gh release create "$TAG" dist/KeySwitch.dmg --title "KeySwitch $VERSION" --notes-file "$STAGE/notes.md" --target main
echo "→ Опубликовано: $TAG"

if [[ -n "$OLD_TAG" ]]; then
  gh release delete "$OLD_TAG" --yes
  echo "→ Удалён старый релиз $OLD_TAG (git-тег оставлен)"
fi
