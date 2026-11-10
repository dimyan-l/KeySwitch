#!/bin/bash
# Build KeySwitchES.app with Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"
if [[ -x ../tools/check_shared_sources.sh ]]; then ../tools/check_shared_sources.sh; fi

IDENTITY="${KEYSWITCH_ES_CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="-"
  echo "⚠️ Sin certificado de firma estable: macOS puede volver a pedir los permisos."
fi
if [[ "${1:-}" == "--install" ]]; then
  if [[ "$IDENTITY" == "-" ]]; then
    echo "Instalación cancelada: firma KeySwitchES.app con un certificado estable antes de instalar." >&2
    exit 1
  fi
  for duplicate in /Applications/KeySwitchES\ [0-9]*.app; do
    if [[ -e "$duplicate" ]]; then
      echo "Instalación cancelada: existe otra copia $duplicate. Deja una sola KeySwitchES.app en Aplicaciones." >&2
      exit 1
    fi
  done
fi

echo "→ Компилирую (release)…"
swift build -c release

APP="build/KeySwitchES.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/KeySwitchES" "$APP/Contents/MacOS/KeySwitchES"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/Dictionaries "$APP/Contents/Resources/Dictionaries"
cp Resources/DefaultRules.json "$APP/Contents/Resources/DefaultRules.json"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp DICTIONARY_LICENSE.md "$APP/Contents/Resources/DICTIONARY_LICENSE.md"

# Una firma estable conserva los permisos entre versiones. El archivo de
# distribución puede llevar una firma ad-hoc hasta que su dueño lo firme.
codesign --force --deep --sign "$IDENTITY" "$APP"
echo "→ Подписано: $IDENTITY"

echo "→ Самопроверка словарей:"
"$APP/Contents/MacOS/KeySwitchES" --selftest | tail -4

if [[ "${1:-}" == "--install" ]]; then
  STAGING="$(mktemp -d /Applications/.KeySwitchES-install.XXXXXX)"
  trap 'rm -rf "$STAGING"' EXIT
  ditto "$APP" "$STAGING/KeySwitchES.app"
  codesign --verify --deep --strict "$STAGING/KeySwitchES.app"
  pkill -TERM -x KeySwitchES 2>/dev/null || true
  for _ in {1..50}; do
    if ! pgrep -x KeySwitchES >/dev/null 2>&1; then break; fi
    sleep 0.1
  done
  if pgrep -x KeySwitchES >/dev/null 2>&1; then
    echo "KeySwitch ES sigue abierto; la instalación se ha cancelado sin borrar la versión anterior." >&2
    exit 1
  fi
  if [[ -d /Applications/KeySwitchES.app ]]; then mv /Applications/KeySwitchES.app "$STAGING/previous.app"; fi
  if ! mv "$STAGING/KeySwitchES.app" /Applications/KeySwitchES.app; then
    if [[ -d "$STAGING/previous.app" ]]; then mv "$STAGING/previous.app" /Applications/KeySwitchES.app; fi
    exit 1
  fi
  echo "→ Instalado en /Applications. Ábrelo manualmente después de revisar los permisos."
else
  echo "Listo: $APP   (./build_app.sh --install — instalar en /Applications sin abrir)"
fi
