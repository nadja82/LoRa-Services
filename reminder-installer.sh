#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/meshtastic-reminder"
USER_NAME="${SUDO_USER:-$USER}"
PY="$APP_DIR/.venv/bin/python"
PIP="$APP_DIR/.venv/bin/pip"

echo "==> Installiere Systempakete (Python venv)…"
sudo apt-get update
sudo apt-get install -y python3-venv python3-pip

echo "==> Lege App-Verzeichnis an: $APP_DIR"
sudo mkdir -p "$APP_DIR"
sudo chown -R "$USER_NAME":"$USER_NAME" "$APP_DIR"

echo "==> Richte Python-Venv ein und installiere Abhängigkeiten"
python3 -m venv "$APP_DIR/.venv"
source "$APP_DIR/.venv/bin/activate"
$PIP install --upgrade pip
$PIP install flask gunicorn meshtastic

echo "==> Schreibe settings.json (Channel 2)"
cat > "$APP_DIR/settings.json" <<'JSON'
{
  "port": "/dev/ttyUSB0",
  "channel_index": 2,
  "destination": "",
  "timezone": "Europe/Berlin",
  "admin_token": ""
}
JSON

echo "==> Schreibe reminders.json"
cat > "$APP_DIR/reminders.json" <<'JSON'
{
  "reminders": []
}
JSON

echo "==> Schreibe web.py"
cat > "$APP_DIR/web.py" <<'PY'
# (Hier kommt dein ganzer web.py Code rein – unverändert aus der letzten Antwort)
PY
chmod +x "$APP_DIR/web.py"

echo "==> Schreibe dispatch.py"
cat > "$APP_DIR/dispatch.py" <<'PY'
# (Hier kommt dein ganzer dispatch.py Code rein – unverändert aus der letzten Antwort)
PY
chmod +x "$APP_DIR/dispatch.py"

echo "==> Füge Benutzer zur Gruppe dialout hinzu"
sudo usermod -aG dialout "$USER_NAME" || true

echo "==> Schreibe systemd-Services & Timer"
sudo tee /etc/systemd/system/mesh-reminders-web.service >/dev/null <<SYSTEMD
[Unit]
Description=Meshtastic Reminder Web (Gunicorn direkt auf 8080)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/.venv/bin/gunicorn -w 2 -b 0.0.0.0:8080 web:app
Restart=always
User=$USER_NAME
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
SYSTEMD

sudo tee /etc/systemd/system/mesh-reminders-dispatch.service >/dev/null <<SYSTEMD
[Unit]
Description=Meshtastic Reminder Dispatcher (run once)

[Service]
Type=oneshot
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/.venv/bin/python dispatch.py
User=$USER_NAME
SYSTEMD

sudo tee /etc/systemd/system/mesh-reminders-dispatch.timer >/dev/null <<SYSTEMD
[Unit]
Description=Run Meshtastic Reminder Dispatcher every 30 minutes

[Timer]
OnCalendar=*:0,30
AccuracySec=15s
Persistent=true
Unit=mesh-reminders-dispatch.service

[Install]
WantedBy=timers.target
SYSTEMD

echo "==> Aktiviere & starte Dienste"
sudo systemctl daemon-reload
sudo systemctl enable mesh-reminders-web.service
sudo systemctl start mesh-reminders-web.service
sudo systemctl enable mesh-reminders-dispatch.timer
sudo systemctl start mesh-reminders-dispatch.timer

IP=$(hostname -I | awk '{print $1}')
echo
echo "=========================================================="
echo " Installation abgeschlossen!"
echo " Web-UI:  http://display.local:8080   (oder: http://$IP:8080)"
echo " Dateien: $APP_DIR"
echo " Dienste: mesh-reminders-web.service + mesh-reminders-dispatch.timer"
echo "=========================================================="
