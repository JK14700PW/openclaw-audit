#!/usr/bin/env bash
# Skan repozytorium pod kątem sekretów i danych prywatnych przed commitem/publikacją.
# Użycie: scripts/check-secrets.sh [pliki...]
#   domyślnie: pliki śledzone przez git + nowe, nieignorowane (bez repo: wszystkie pliki poza .git)
#
# 1) Wzorce ogólne: klucze prywatne, tokeny GitHub/Anthropic/OpenAI/AWS/Slack, publiczne adresy IPv4
#    (dozwolone: adresy dokumentacyjne RFC 5737, prywatne, loopback, Azure 168.63.129.16).
# 2) Wzorce własne z pliku .private-patterns (w .gitignore): prawdziwe IP, login, e-mail itp.,
#    jedna wartość na linię, porównanie dosłowne bez rozróżniania wielkości liter.
set -uo pipefail
export LC_ALL=C
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ $# -gt 0 ]; then FILES=("$@")
elif git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  mapfile -t FILES < <(git ls-files --cached --others --exclude-standard)
else
  mapfile -t FILES < <(find . -type f -not -path './.git/*' | sed 's|^\./||')
fi

FOUND="$(mktemp)"; trap 'rm -f "$FOUND"' EXIT
hit() { echo "❌ $1: $2" | tee -a "$FOUND" >&2; }

GENERIC='-----BEGIN [A-Z ]*PRIVATE KEY-----|sk-ant-[A-Za-z0-9_-]{10,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{32,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}'
PRIVATE=()
if [ -f .private-patterns ]; then
  while IFS= read -r p || [ -n "$p" ]; do
    p="${p%$'\r'}"; [ -z "$p" ] || [ "${p:0:1}" = "#" ] || PRIVATE+=("$p")
  done < .private-patterns
fi

n=0
for f in "${FILES[@]}"; do
  f="${f#./}"
  [ -f "$f" ] || continue
  case "$f" in .private-patterns|.git/*) continue ;; esac
  n=$((n+1))

  # Pliki, które nigdy nie powinny trafić do repozytorium
  case "$f" in
    config.example.env) ;;
    *.pem|*.key|*id_rsa*|*id_ed25519*|*.env|.secrets/*) hit "$f" "plik z danymi lub kluczem"; continue ;;
  esac

  # Ten skaner i testy zawierają wzorce/atrapy z definicji
  case "$f" in scripts/check-secrets.sh|tests/*) ;; *)
    while IFS= read -r l; do hit "$f" "wygląda na sekret: ${l:0:60}…"; done \
      < <(grep -IEno -e "$GENERIC" "$f" 2>/dev/null)
  esac

  while IFS=: read -r ln ip; do
    case "$ip" in
      192.0.2.*|198.51.100.*|203.0.113.*|127.*|0.0.0.0|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|168.63.129.16|255.*) ;;
      *) hit "$f:$ln" "publiczny adres IP $ip" ;;
    esac
  done < <(grep -IEno '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' "$f" 2>/dev/null)

  if [ ${#PRIVATE[@]} -gt 0 ] && grep -Iq . "$f" 2>/dev/null; then
    content=$(tr "A-Z" "a-z" < "$f")
    for p in "${PRIVATE[@]}"; do
      pl=$(printf "%s" "$p" | tr "A-Z" "a-z")
      [[ "$content" == *"$pl"* ]] && hit "$f" "zawiera wartość z .private-patterns"
    done
  fi
done

if [ -s "$FOUND" ]; then
  echo "Znaleziono $(wc -l < "$FOUND") problem(ów) w $n plikach." >&2; exit 1
fi
echo "✅ Brak sekretów i danych prywatnych ($n plików, ${#PRIVATE[@]} wzorców własnych)." >&2
