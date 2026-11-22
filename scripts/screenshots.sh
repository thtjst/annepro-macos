#!/usr/bin/env bash
# Regenerates docs/screenshots: opens the real app windows with sample data (no keyboard
# needed) and saves them in light and dark mode at 2x.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product AnnePro
.build/debug/AnnePro --screenshots docs/screenshots
