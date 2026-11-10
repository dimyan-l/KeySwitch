#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
from PIL import Image

for source, output in (
    ("Resources/AppIcon-source.png", "Resources/AppIcon.icns"),
    ("KeySwitchES/Resources/AppIcon-source.png", "KeySwitchES/Resources/AppIcon.icns"),
):
    icon = Image.open(source).convert("RGBA")
    icon = icon.resize((1024, 1024), Image.Resampling.LANCZOS)
    icon.save(output, format="ICNS")
PY
