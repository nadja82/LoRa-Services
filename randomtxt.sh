#!/usr/bin/env bash
#
# send_random_meshtastic.sh
# Wählt zufällig eine Zeile aus einer Textdatei, fügt Begrüßung & Verabschiedung hinzu
# und sendet sie via Meshtastic an Channel/Gruppe Index 3.
#
# Nutzung:
#   ./send_random_meshtastic.sh /pfad/zu/messages.txt
#

set -euo pipefail

PORT="/dev/ttyUSB0"
CHANNEL_INDEX=3
TEXT_FILE="${1:-messages.txt}"

# --- Hilfsfunktionen ---------------------------------------------------------

die() { echo "Error: $*" >&2; exit 1; }

check_deps() {
  command -v meshtastic >/dev/null 2>&1 || die "meshtastic CLI nicht gefunden. Installiere z.B.: pipx install meshtastic"
}

validate_file() {
  [[ -r "$TEXT_FILE" ]] || die "Datei '$TEXT_FILE' nicht lesbar oder existiert nicht."
  local count
  count=$(grep -v '^\s*$' "$TEXT_FILE" | grep -v '^\s*#' | wc -l | tr -d ' ')
  [[ "$count" -ge 1 ]] || die "In '$TEXT_FILE' keine sendbaren Zeilen gefunden."
}

pick_random_line() {
  if command -v shuf >/dev/null 2>&1; then
    grep -v '^\s*$' "$TEXT_FILE" | grep -v '^\s*#' | sed 's/\r$//' | shuf -n 1
  else
    awk '
      /^[[:space:]]*$/ { next }
      /^[[:space:]]*#/ { next }
      { gsub(/\r$/,""); a[++n]=$0 }
      END { if (n) { srand(); i=int(rand()*n)+1; print a[i] } }
    ' "$TEXT_FILE"
  fi
}

random_greeting() {
  local GREETINGS=(
    "Hey"
    "Hallo"
    "Hi"
    "Servus"
    "Moin"
    "Grüß dich"
    "Yo"
    "Hallöchen"
    "Na"
    "Ahoi"
  )
  echo "${GREETINGS[$RANDOM % ${#GREETINGS[@]}]}"
}

random_farewell() {
  local FAREWELLS=(
    "Bis bald!"
    "Ciao!"
    "Mach's gut!"
    "LG"
    "Bye!"
    "Bis später!"
    "Gruß"
    "Adieu!"
    "Alles Gute!"
    "👋"
  )
  echo "${FAREWELLS[$RANDOM % ${#FAREWELLS[@]}]}"
}

send_meshtastic() {
  local msg="$1"
  meshtastic --port "$PORT" --ch-index "$CHANNEL_INDEX" --sendtext "$msg"
}

# --- Main --------------------------------------------------------------------

check_deps
validate_file

MESSAGE="$(pick_random_line)"
GREETING="$(random_greeting)"
FAREWELL="$(random_farewell)"

FULL_MESSAGE="$GREETING $MESSAGE $FAREWELL"

echo "Sende an Meshtastic (Port: $PORT, Channel-Index: $CHANNEL_INDEX):"
echo "  » $FULL_MESSAGE"

if send_meshtastic "$FULL_MESSAGE"; then
  echo "✅ Nachricht erfolgreich gesendet."
else
  die "❌ Senden fehlgeschlagen. Ist das Gerät an $PORT frei?"
fi

