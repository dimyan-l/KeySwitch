#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for name in Typer.swift FocusToken.swift InputPolicy.swift Rules.swift SpellCorrector.swift SelectionSuggestions.swift SettingsWindow.swift MotionBadge.swift; do
  if ! cmp -s "$ROOT/Sources/KeySwitch/$name" "$ROOT/KeySwitchES/Sources/KeySwitchES/$name"; then
    echo "Общий файл $name различается в RU/EN и EN/ES" >&2
    exit 1
  fi
done
