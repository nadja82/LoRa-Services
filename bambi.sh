#!/usr/bin/env bash
#
# send_random_meshtastic.sh
# Wählt zufällig eine Zeile aus "messages.txt" im Script-Ordner,
# fügt Begrüßung & Verabschiedung (Emojis) hinzu
# und sendet sie via Meshtastic an Channel/Gruppe Index 3 über /dev/ttyUSB0.
#
# Nutzung:
#   ./send_random_meshtastic.sh
#
# Voraussetzungen:
#   - meshtastic CLI installiert (pipx install meshtastic)
#   - messages.txt im gleichen Ordner wie dieses Script

set -euo pipefail

PORT="localhost"
CHANNEL_INDEX=3

# Verzeichnis ermitteln, in dem das Script liegt
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEXT_FILE="$SCRIPT_DIR/bambi.txt"

die() { echo "Error: $*" >&2; exit 1; }

check_deps() {
  command -v meshtastic >/dev/null 2>&1 || die "meshtastic CLI nicht gefunden. Installiere z.B.: pipx install meshtastic"
}

validate_file() {
  [[ -r "$TEXT_FILE" ]] || die "Datei '$TEXT_FILE' nicht lesbar oder existiert nicht."
  local count
  count=$(grep -v '^[[:space:]]*$' "$TEXT_FILE" | grep -v '^[[:space:]]*#' | wc -l | tr -d ' ')
  [[ "$count" -ge 1 ]] || die "In '$TEXT_FILE' keine sendbaren Zeilen (leer oder nur Kommentare)."
}

pick_random_line() {
  if command -v shuf >/dev/null 2>&1; then
    grep -v '^[[:space:]]*$' "$TEXT_FILE" | grep -v '^[[:space:]]*#' | sed 's/\r$//' | shuf -n 1
  else
    awk '
      /^[[:space:]]*$/ { next }
      /^[[:space:]]*#/ { next }
      { sub(/\r$/, ""); a[++n]=$0 }
      END { if (n) { srand(); print a[int(rand()*n)+1] } }
    ' "$TEXT_FILE"
  fi
}

random_greeting() {
  local GREETINGS=(
    "Hey, 👋 "
    "Hi 🙂 "
    "Hello 😃 "
    "😉GoodNews: "
    "hi Bambi😎, "
    "hi👋 "
    "🚀hey "
    "🌟BambiChannel: "
    "📡BambiChannel: "
  )
  echo "${GREETINGS[$RANDOM % ${#GREETINGS[@]}]}"
}

random_farewell() {
  local FAREWELLS=(
    "🙂"
    "😉"
    "😎"
    "🚀"
    "🌟"
    "📡"
  )
  echo "${FAREWELLS[$RANDOM % ${#FAREWELLS[@]}]}"
}

send_meshtastic() {
  local msg="$1"
  meshtastic --host "$PORT" --ch-index "$CHANNEL_INDEX" --sendtext "$msg"
}

# --- Main --------------------------------------------------------------------

check_deps
validate_file

MESSAGE="$(pick_random_line)"
[[ -n "$MESSAGE" ]] || die "Konnte keine zufällige Zeile ermitteln."

GREETING="$(random_greeting)"
FAREWELL="$(random_farewell)"
FULL_MESSAGE="$GREETING $MESSAGE $FAREWELL"

echo "Sende an Meshtastic (host: $PORT, Channel-Index: $CHANNEL_INDEX):"
echo "  » $FULL_MESSAGE"

if send_meshtastic "$FULL_MESSAGE"; then
  echo "✅ Nachricht erfolgreich gesendet."
else
  die "❌ Senden fehlgeschlagen. Ist das Gerät an $PORT erreichbar oder blockiert ein anderes Programm die serielle Schnittstelle?"
fi
