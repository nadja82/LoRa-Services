#!/bin/bash
# Liest Temperatur & Luftfeuchte vom ESP8266 und sendet über Meshtastic

ESP_URL="http://envnode.local/api/now"   # URL deines ESPs
CH_INDEX=2                               # Meshtastic Channel Index
HOST="localhost"                         # Meshtastic Daemon Host

# Werte vom ESP holen
DATA=$(curl -s "$ESP_URL")

# Prüfen ob Daten da sind
if [ -z "$DATA" ]; then
    echo "Fehler: Keine Daten vom ESP erreichbar."
    exit 1
fi

# Mit jq Temperatur und Feuchte extrahieren
TEMP=$(echo "$DATA" | jq -r '.t')
HUM=$(echo "$DATA" | jq -r '.h')

# Prüfen ob gültige Zahlen
if [ "$TEMP" = "null" ] || [ "$HUM" = "null" ]; then
    echo "Fehler: Ungültige Sensordaten."
    exit 1
fi

# Nachricht formatieren
MSG="WomoTemp: ${TEMP}°C ${HUM}%"

# An Meshtastic senden
meshtastic --host "$HOST" --ch-index "$CH_INDEX" --sendtext "$MSG"

# Ausgabe für Log
echo "$(date '+%F %T') -> Gesendet: $MSG"
