#!/usr/bin/env bash
# Instaluje narzędzie jako skill Claude Code: /audyt-hosta
# Użycie: ./install-skill.sh [--project <katalog_projektu>]
#   domyślnie: skill osobisty (~/.claude/skills/audyt-hosta) — dostępny w każdym projekcie
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude/skills/audyt-hosta"
[ "${1:-}" = "--project" ] && DEST="${2:?podaj katalog projektu}/.claude/skills/audyt-hosta"

mkdir -p "$DEST"
rm -rf "$DEST/remote" "$DEST/lib"
cp -r "$SRC/SKILL.md" "$SRC/run-audit.sh" "$SRC/config.example.env" "$SRC/README.md" "$SRC/remote" "$SRC/lib" "$DEST/"
chmod +x "$DEST/run-audit.sh" "$DEST"/remote/*.sh "$DEST"/lib/*.sh
# Celowo NIE kopiujemy: config.env, reports/, kluczy.
echo "Zainstalowano skill w: $DEST"
echo "Wywołanie w Claude Code: /audyt-hosta [ścieżka do pliku z danymi]"
