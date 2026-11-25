#!/usr/bin/env bash
# Składa REPORT.md i REPORT.html (do przeglądarki) z wyników jednego przebiegu.
# Użycie: build-report.sh <katalog_przebiegu> <host> <wersja_openclaw> <auth_mode> <kod_agenta>
set -euo pipefail
D="$1"; HOST="$2"; VER="$3"; AUTH="$4"; RC="$5"
R="$D/REPORT.md"

icon() { case "$1" in PASS) echo "✅";; FAIL) echo "❌";; WARN) echo "⚠️";; SKIP) echo "⏭️";; *) echo "ℹ️";; esac; }

{
  echo "# Raport audytu bezpieczeństwa hosta — $HOST"
  echo
  echo "| | |"
  echo "|---|---|"
  sed -n 's/^\(host\|date\|os\|kernel\|platform\): \(.*\)/| \1 | \2 |/p' "$D/evidence/context.txt"
  echo "| narzędzie | OpenClaw $VER, skill \`healthcheck\` (bundled), dostęp do modelu: \`$AUTH\` |"
  echo "| agent | $(cat "$D/agent_meta.txt" 2>/dev/null) |"
  echo "| kontrola po audycie | $(paste -sd';' "$D/post_check.txt" 2>/dev/null) |"
  echo
  echo "## Część A — kontrole deterministyczne (bez AI)"
  echo
  echo "Wynik: \`$(cat "$D/checks_summary.txt")\`"
  echo
  echo "| ID | Obszar | Status | Ważność | Kontrola | Dowód |"
  echo "|---|---|---|---|---|---|"
  tail -n +2 "$D/checks.tsv" | while IFS=$'\t' read -r id area st sev desc ev; do
    printf '| %s | %s | %s %s | %s | %s | `%s` |\n' "$id" "$area" "$(icon "$st")" "$st" "$sev" "$desc" "${ev//|/\\|}"
  done
  echo
  echo "## Część B — analiza skillem healthcheck (OpenClaw)"
  echo
  if [ "$RC" != 0 ] || [ ! -s "$D/healthcheck.md" ]; then
    echo "> ⚠️ Agent zakończył się kodem $RC — sprawdź \`openclaw_log.txt\`."
    echo
  fi
  # Przesuń nagłówki agenta o jeden poziom niżej
  sed 's/^#/##/' "$D/healthcheck.md" 2>/dev/null
  echo
  echo "## Pliki źródłowe"
  echo
  echo "- \`checks.tsv\` — wynik kontroli deterministycznych"
  echo "- \`evidence/\` — surowe dowody (sshd -T, ufw, iptables, nft, porty, settings.json z zamaskowanym env)"
  echo "- \`prompt.md\` — polecenie przekazane agentowi"
  echo "- \`healthcheck_raw.txt\`, \`openclaw_log.txt\` — pełne wyjście i log OpenClaw"
  echo "- \`preflight.txt\`, \`cleanup.txt\` — wymagania przed audytem i ślady po sprzątaniu"
  echo
  echo "## Część C — ślad narzędzia na maszynie"
  echo
  echo "Narzędzie instaluje się wyłącznie w \`~/.openclaw-audit\` (prywatny Node.js, OpenClaw, cache npm, stan OpenClaw)"
  echo "i nie korzysta z sudo do instalacji. Po audycie katalog jest usuwany, a zawartość katalogu domowego"
  echo "porównywana ze zdjęciem sprzed pierwszej instalacji."
  echo
  echo '```text'
  cat "$D/cleanup.txt" 2>/dev/null || echo "(brak danych o sprzątaniu)"
  echo '```'
  echo
  echo "<details><summary>Wymagania sprawdzone przed audytem</summary>"
  echo
  echo '```text'
  cat "$D/preflight.txt" 2>/dev/null || echo "(brak)"
  echo '```'
  echo
  echo "</details>"
} > "$R"

# ---------- REPORT.html: samodzielny raport do otwarcia w przeglądarce ----------
# Dane przebiegu są osadzane w base64 (żadne znaki z wyników nie trafiają wprost do HTML),
# a szablon renderuje je z pełnym escapowaniem — tekst agenta jest niezaufany.
TPL="$(cd "$(dirname "$0")" && pwd)/report-template.html"
H="$D/REPORT.html"
b64() { base64 < "$1" | tr -d '\n\r'; }
blk() { # id plik
  printf '<script type="text/plain" id="%s">' "$1"
  if [ -f "$2" ]; then b64 "$2"; fi
  printf '</script>\n'
}
if [ -f "$TPL" ]; then
  META=$(mktemp)
  {
    sed -n 's/^\(host\|date\|os\|kernel\|platform\): \(.*\)/\1\t\2/p' "$D/evidence/context.txt" 2>/dev/null
    printf 'tool\tOpenClaw %s, skill healthcheck, model: %s\n' "$VER" "$AUTH"
    printf 'agent\t%s\n' "$(cat "$D/agent_meta.txt" 2>/dev/null)"
    printf 'rc\t%s\n' "$RC"
  } > "$META"
  {
    sed '/<!--DANE-->/,$d' "$TPL"
    blk d-meta "$META"
    blk d-checks "$D/checks.tsv"
    blk d-agent "$D/healthcheck.md"
    blk d-post "$D/post_check.txt"
    blk d-cleanup "$D/cleanup.txt"
    blk d-preflight "$D/preflight.txt"
    sed '1,/<!--DANE-->/d' "$TPL"
  } > "$H"
  rm -f "$META"
fi
