#!/usr/bin/env bash
# Testy parsera pliku konfiguracji (bez połączenia z maszyną): run-audit.sh --check
# --validate: kod 2 dla złych plików, 0 dla dobrych.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
touch "$T/key.pem"
pass=0; failn=0
expect() { # nazwa oczekiwany_kod oczekiwany_tekst zawartość
  printf '%b' "$4" > "$T/c.env"
  out=$(timeout 20 bash "$ROOT/run-audit.sh" --validate -c "$T/c.env" 2>&1); rc=$?
  if [ "$rc" = "$2" ] && grep -qF -- "$3" <<<"$out"; then pass=$((pass+1)); echo "ok   $1"
  else failn=$((failn+1)); echo "FAIL $1 (rc=$rc)"; echo "$out" | sed 's/^/     /'; fi
}
GOOD="AUDIT_HOST=192.0.2.1\nAUDIT_PORT=1\nAUDIT_USER=tester\nAUDIT_SSH_KEY=key.pem\n"

expect "przykładowy plik ma poprawne klucze"  2 "Brak klucza SSH" "$(sed 's/\\/\\\\/g' "$ROOT/config.example.env")"
expect "nieznany klucz"                         2 "Nieznany klucz"   "${GOOD}FOO=1\n"
expect "wstrzyknięcie polecenia w host"         2 "Niepoprawny AUDIT_HOST" "AUDIT_HOST=192.0.2.9;touch /tmp/x\nAUDIT_USER=t\nAUDIT_SSH_KEY=key.pem\n"
expect "\$(...) nie jest wykonywane"            2 "Niepoprawny AUDIT_HOST" "AUDIT_HOST=\$(id)\nAUDIT_USER=t\nAUDIT_SSH_KEY=key.pem\n"
expect "port nie-liczbowy"                      2 "AUDIT_PORT musi"  "${GOOD}AUDIT_PORT=abc\n"
expect "brak użytkownika"                       2 "Brak AUDIT_USER"  "AUDIT_HOST=192.0.2.1\nAUDIT_SSH_KEY=key.pem\n"
expect "zły AUTH_MODE"                          2 "AUTH_MODE musi"   "${GOOD}AUTH_MODE=xyz\n"
expect "api-key bez klucza"                     2 "podaj ANTHROPIC_API_KEY_FILE" "${GOOD}AUTH_MODE=anthropic-api-key\n"
expect "klucz API wczytany (CRLF obcięty)"      0 "klucz API wczytany, 17 znaków" "${GOOD}AUTH_MODE=anthropic-api-key\nANTHROPIC_API_KEY=sk-test-123456789\r\n"
if grep -q 123456789 <<<"$out"; then failn=$((failn+1)); echo "FAIL klucz API pojawił się w wyjściu"
else pass=$((pass+1)); echo "ok   klucz API nie jest wypisywany"; fi
printf 'k-test-from-file\r\n' > "$T/api.key"
expect "klucz API z pliku"                      0 "klucz API wczytany, 16 znaków" "${GOOD}AUTH_MODE=anthropic-api-key\nANTHROPIC_API_KEY_FILE=api.key\n"
expect "zły CLEANUP"                            2 "CLEANUP musi"     "${GOOD}CLEANUP=maybe\n"
expect "CLEANUP=no akceptowane"                 0 "sprzątanie po audycie: no" "${GOOD}CLEANUP=no\n"
expect "domyślny prywatny Node"                 0 "Node 24.22.3 (prywatny)" "${GOOD}NODE_VERSION=\n"
expect "zły SHA Node"                           2 "NODE_SHA256"      "${GOOD}NODE_SHA256_X64=xyz\n"
expect "wstrzyknięcie w wersję Node"            2 "NODE_VERSION"     "${GOOD}NODE_VERSION=24.0.0;id\n"
expect "zły SHA skilla"                      2 "HEALTHCHECK_SHA256" "${GOOD}HEALTHCHECK_SHA256=abc\n"
expect "CRLF, cudzysłowy, komentarze"           0 "tester@192.0.2.1:1" "# komentarz\r\nAUDIT_HOST=\"192.0.2.1\"\r\nAUDIT_PORT=1 # port\r\nAUDIT_USER='tester'\r\nAUDIT_SSH_KEY=key.pem\r\n"

# Diagnoza błędów połączenia (--check, bez internetu): kod 4 i czytelna przyczyna
conn() { # nazwa host port oczekiwany_tekst
  printf 'AUDIT_HOST=%s\nAUDIT_PORT=%s\nAUDIT_USER=tester\nAUDIT_SSH_KEY=key.pem\n' "$2" "$3" > "$T/c.env"
  out=$(timeout 40 bash "$ROOT/run-audit.sh" --check -c "$T/c.env" 2>&1); rc=$?
  if [ "$rc" = 4 ] && grep -qF -- "$4" <<<"$out" && grep -qF "niczego nie wysłano" <<<"$out"; then pass=$((pass+1)); echo "ok   $1"
  else failn=$((failn+1)); echo "FAIL $1 (rc=$rc)"; echo "$out" | tail -6 | sed 's/^/     /'; fi
}
if command -v ssh >/dev/null; then
  conn "połączenie odrzucone (zły port)" 127.0.0.1 1 "nie działa SSH"
  conn "nieznany adres hosta"            nie-ma-takiego-hosta.invalid 22 "Nie można odnaleźć adresu"
fi

echo "wynik: $pass ok, $failn błędów"
[ $failn = 0 ]
