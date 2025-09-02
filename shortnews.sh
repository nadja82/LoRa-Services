#Install:
#sudo apt-get update
#sudo apt-get install -y xmlstarlet
#!/usr/bin/env bash
set -euo pipefail

# === Konfiguration ===
PORT="${PORT:-/dev/ttyUSB0}"      # z.B. /dev/serial0 oder /dev/ttyUSB0
CH_INDEX="${CH_INDEX:-3}"         # Meshtastic Channel-Index
MAXLEN="${MAXLEN:-160}"           # maximale Zeichenlänge pro Eilmeldung
LOG="${HOME}/shortnews_meshtastic.log"

# RSS-Quellen (beliebig erweiterbar)
FEEDS=(
  "https://www.tagesschau.de/xml/rss2"     # tagesschau.de (ARD)
  "https://newsfeed.zeit.de/news/index"    # ZEIT ONLINE - News
)

# === Abhängigkeiten prüfen ===
need() { command -v "$1" >/dev/null 2>&1 || { echo "Fehlt: $1"; exit 1; }; }
need curl
need xmlstarlet
need meshtastic

# === Hilfsfunktionen ===
trim_space() { sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'; }
truncate() {
  local s="$1" max="$2"
  # simple truncation; für Multi-Byte ok genug bei Headlines
  (( ${#s} > max )) && echo "${s:0:max}…" || echo "$s"
}

get_host() { awk -F/ '{print $3}' <<<"$1"; }

# === Neueste Kurzmeldung finden (erste funktionierende Quelle gewinnt) ===
TITLE=""; SRC=""; FEED_URL=""
for url in "${FEEDS[@]}"; do
  if XML="$(curl -fsSL --max-time 5 "$url")"; then
    # hole den ersten <item><title>
    t="$(xmlstarlet sel -t -v '(//item/title)[1]' -n 2>/dev/null <<<"$XML" | head -n1 | tr -d '\r')"
    # fallback für Atom
    if [[ -z "$t" ]]; then
      t="$(xmlstarlet sel -t -v '(//entry/title)[1]' -n 2>/dev/null <<<"$XML" | head -n1 | tr -d '\r')"
    fi
    if [[ -n "$t" ]]; then
      TITLE="$(echo "$t" | trim_space)"
      # Quelle: channel/title oder Hostname
      ctitle="$(xmlstarlet sel -t -v '(//channel/title)[1]' -n 2>/dev/null <<<"$XML" | head -n1)"
      [[ -n "$ctitle" ]] && SRC="$(echo "$ctitle" | trim_space)" || SRC="$(get_host "$url")"
      FEED_URL="$url"
      break
    fi
  fi
done

if [[ -z "$TITLE" ]]; then
  echo "❌ Konnte keinen Titel aus den Feeds lesen."
  exit 2
fi

# === ultrakurze Eilmeldung bauen ===
# Format: "EIL: <Quelle>: <Titel>"
MSG_RAW="EIL: ${SRC}: ${TITLE}"
MSG="$(truncate "$MSG_RAW" "$MAXLEN")"

echo "[i] Quelle: $FEED_URL"
echo "[i] Sende: $MSG"

# === Senden + Status prüfen ===
if OUT="$(meshtastic --port "$PORT" --ch-index "$CH_INDEX" --sendtext "$MSG" 2>&1)"; then
  echo "✅ Eilmeldung gesendet."
  STATUS="OK"
else
  echo "❌ Fehler beim Senden:"
  echo "$OUT"
  STATUS="FAIL"
fi

# === Loggen ===
echo "$(date +"%F %T") | [$STATUS] $MSG" >> "$LOG"
