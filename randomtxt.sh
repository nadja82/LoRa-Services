#!/usr/bin/env bash
#
# send_random_meshtastic.sh
# Wählt zufällig eine Zeile aus einer Textdatei und sendet sie via Meshtastic
# an Channel/Gruppe Index 3 über Port /dev/ttyUSB0.
#
# Nutzung:
#   ./send_random_meshtastic.sh /pfad/zu/messages.txt
#
# Voraussetzungen:
#   - meshtastic CLI installiert (pipx/pip: meshtastic)
#   - Datei mit einer Zeile pro Nachricht
#   - shuf (coreutils) empfohlen; fallback via awk vorhanden

set -euo pipefail

# Feste Einstellungen laut Anforderung
PORT="/dev/ttyUSB0"
CHANNEL_INDEX=1

# Eingabedatei (Argument 1) oder Standard
TEXT_FILE="${1:-messages.txt}"

# --- Hilfsfunktionen ---------------------------------------------------------

die() { echo "Error: $*" >&2; exit 1; }

check_deps() {
  command -v meshtastic >/dev/null 2>&1 || die "meshtastic CLI nicht gefunden. Installiere z.B.: pipx install meshtastic"
}

validate_file() {
  [[ -r "$TEXT_FILE" ]] || die "Datei '$TEXT_FILE' nicht lesbar oder existiert nicht."
  # Prüfe, ob nach Filter mindestens eine gültige Zeile existiert
  local count
  count=$(grep -v '^\s*$' "$TEXT_FILE" | grep -v '^\s*#' | wc -l | tr -d ' ')
  [[ "$count" -ge 1 ]] || die "In '$TEXT_FILE' keine sendbaren Zeilen (leer oder nur Kommentare)."
}

pick_random_line() {
  # Filter: entferne Leerzeilen & Kommentarzeilen, trimme CRLF
  if command -v shuf >/dev/null 2>&1; then
    # Mit shuf, robust gegen große Dateien
    grep -v '^\s*$' "$TEXT_FILE" | grep -v '^\s*#' | sed 's/\r$//' | shuf -n 1
  else
    # Fallback ohne shuf
    awk '
      /^[[:space:]]*$/ { next }     # leere Zeilen überspringen
      /^[[:space:]]*#/ { next }     # Kommentarzeilen überspringen
      { gsub(/\r$/,""); a[++n]=$0 } # CR entfernen (Windows-Zeilenenden)
      END { if (n) { srand(); i=int(rand()*n)+1; print a[i] } }
    ' "$TEXT_FILE"
  fi
}

send_meshtastic() {
  local msg="$1"
  # Hinweis: --ch-index wählt den Channel-Index (0-basierend) für die Nachricht.
  meshtastic --port "$PORT" --ch-index "$CHANNEL_INDEX" --sendtext "$msg"
}

# --- Main --------------------------------------------------------------------

check_deps
validate_file

MESSAGE="$(pick_random_line)"
[[ -n "$MESSAGE" ]] || die "Konnte keine zufällige Zeile ermitteln."

echo "Sende an Meshtastic (Port: $PORT, Channel-Index: $CHANNEL_INDEX):"
echo "  » $MESSAGE"

# Senden
if send_meshtastic "$MESSAGE"; then
  echo "✅ Nachricht erfolgreich gesendet."
else
  die "Senden fehlgeschlagen. Ist das Gerät an $PORT erreichbar? Nutzt nichts anderes gerade die serielle Schnittstelle?"
fi
