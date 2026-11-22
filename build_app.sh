#!/bin/bash
# Сборка KeySwitch.app. Нужны только Command Line Tools: xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"
./tools/check_shared_sources.sh

# Check the installation constraints before replacing the last successful build.
IDENTITY="${KEYSWITCH_CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  for candidate in "KeySwitch RU Local Signing 2026" "KeySwitch Dev"; do
    if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$candidate\""; then
      IDENTITY="$candidate"
      break
    fi
  done
fi
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="-"
  echo "⚠️ Нет постоянного сертификата подписи: новая сборка может снова запросить доступ macOS."
fi
if [[ "${1:-}" == "--install" ]]; then
  if [[ "$IDENTITY" == "-" ]]; then
    echo "Установка остановлена: без постоянного сертификата macOS может сбросить Универсальный доступ и Мониторинг ввода." >&2
    exit 1
  fi
  for duplicate in /Applications/KeySwitch\ [0-9]*.app; do
    if [[ -e "$duplicate" ]]; then
      echo "Установка остановлена: найдена другая копия $duplicate. Оставьте одну копию KeySwitch.app в «Программах»." >&2
      exit 1
    fi
  done
fi

echo "→ Компилирую (release)…"
swift build -c release

APP="build/KeySwitch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/KeySwitch" "$APP/Contents/MacOS/KeySwitch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/Dictionaries "$APP/Contents/Resources/Dictionaries"
cp Resources/DefaultRules.json "$APP/Contents/Resources/DefaultRules.json"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Стабильная подпись сохраняет идентичность приложения между обновлениями.
# Для сборки без установки допускается временная ad-hoc подпись.
codesign --force --deep --sign "$IDENTITY" "$APP"
echo "→ Подписано: $IDENTITY"

echo "→ Самопроверка словарей:"
"$APP/Contents/MacOS/KeySwitch" --selftest | tail -4

if [[ "${1:-}" == "--install" ]]; then
  STAGING="$(mktemp -d /Applications/.KeySwitch-install.XXXXXX)"
  cleanup_install() {
    if [[ -d "$STAGING/previous.app" && ! -e /Applications/KeySwitch.app ]]; then
      if ! mv "$STAGING/previous.app" /Applications/KeySwitch.app; then
        echo "Предыдущая версия сохранена в $STAGING/previous.app" >&2
        return
      fi
    fi
    rm -rf "$STAGING"
  }
  trap cleanup_install EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  ditto "$APP" "$STAGING/KeySwitch.app"
  codesign --verify --deep --strict "$STAGING/KeySwitch.app"
  pkill -TERM -x KeySwitch 2>/dev/null || true
  for _ in {1..50}; do
    if ! pgrep -x KeySwitch >/dev/null 2>&1; then break; fi
    sleep 0.1
  done
  if pgrep -x KeySwitch >/dev/null 2>&1; then
    echo "KeySwitch ещё работает; установка остановлена, предыдущая версия сохранена." >&2
    exit 1
  fi
  if [[ -d /Applications/KeySwitch.app ]]; then mv /Applications/KeySwitch.app "$STAGING/previous.app"; fi
  if ! mv "$STAGING/KeySwitch.app" /Applications/KeySwitch.app; then
    if [[ -d "$STAGING/previous.app" ]]; then mv "$STAGING/previous.app" /Applications/KeySwitch.app; fi
    exit 1
  fi
  echo "→ Установлено в /Applications. Запустите вручную после проверки разрешений."
else
  echo "Готово: $APP   (./build_app.sh --install — поставить в /Applications без запуска)"
fi
