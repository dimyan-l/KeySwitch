#!/bin/bash
# Сборка KeySwitch.app. Нужны только Command Line Tools: xcode-select --install
#   ./build_app.sh            собрать и проверить → build/KeySwitch.app
#   ./build_app.sh --install  поставить в /Applications и запустить
#   ./build_app.sh --dmg      образ для установки → build/KeySwitch.dmg
set -euo pipefail
cd "$(dirname "$0")"

echo "→ Компилирую (release)…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/KeySwitch"

# Собираем и подписываем во временной папке, а не в build/: проект лежит в ~/Documents под iCloud,
# и iCloud навешивает на свежие файлы свои атрибуты. codesign их не принимает и через раз падал
# с «resource fork, Finder information, or similar detritus not allowed».
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/KeySwitch.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/KeySwitch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/Dictionaries "$APP/Contents/Resources/Dictionaries"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # пересобрать: swift tools/make_icon.swift icns swap Resources/AppIcon.icns
xattr -cr "$APP"   # на случай атрибутов, приехавших вместе с файлами проекта

# Подпись. Если в Связке ключей есть сертификат "KeySwitch Dev" (см. README), подписываем им —
# тогда macOS не сбрасывает разрешения после каждой пересборки. Иначе — ad-hoc подпись.
IDENTITY="-"
# Без -v: самоподписанный сертификат без настроенного доверия в «valid» не попадает, но для подписи годится.
if security find-identity -p codesigning 2>/dev/null | grep -q "KeySwitch Dev"; then
  IDENTITY="KeySwitch Dev"
fi
codesign --force --deep --sign "$IDENTITY" "$APP"
echo "→ Подписано: $IDENTITY"

# Самопроверка: любой ✗ или неполный «Итог» останавливает сборку, ничего не ставится и не пакуется.
echo "→ Самопроверка:"
REPORT="$("$APP/Contents/MacOS/KeySwitch" --selftest)"
grep '^✗' <<<"$REPORT" || true
tail -4 <<<"$REPORT"
TOTAL="$(grep '^Итог:' <<<"$REPORT" || true)"
if grep -q '^✗' <<<"$REPORT" || ! [[ "$TOTAL" =~ ^Итог:\ ([0-9]+)/([0-9]+)$ && "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" ]]; then
  echo "✗ Самопроверка не прошла — не устанавливаю и не пакую" >&2
  exit 1
fi

# Копия в build/ для удобства; ставим и пакуем подписанный экземпляр из временной папки.
mkdir -p build
rm -rf build/KeySwitch.app
ditto "$APP" build/KeySwitch.app

if [[ "${1:-}" == "--dmg" ]]; then
  # Образ для установки: внутри KeySwitch.app и ярлык «Программы», чтобы перетащить одно в другое.
  DMGSRC="$STAGE/dmg"
  mkdir -p "$DMGSRC"
  ditto "$APP" "$DMGSRC/KeySwitch.app"
  ln -s /Applications "$DMGSRC/Applications"
  rm -f build/KeySwitch.dmg
  hdiutil create -volname "KeySwitch" -srcfolder "$DMGSRC" -ov -format UDZO "$STAGE/KeySwitch.dmg" >/dev/null
  codesign --force --sign "$IDENTITY" "$STAGE/KeySwitch.dmg"
  cp "$STAGE/KeySwitch.dmg" build/KeySwitch.dmg
  echo "→ Образ: build/KeySwitch.dmg"
elif [[ "${1:-}" == "--install" ]]; then
  pkill -x KeySwitch 2>/dev/null || true
  rm -rf /Applications/KeySwitch.app
  ditto "$APP" /Applications/KeySwitch.app
  open /Applications/KeySwitch.app
  echo "→ Установлено в /Applications и запущено"
else
  echo "Готово: build/KeySwitch.app   (./build_app.sh --install — поставить в /Applications и запустить)"
fi
