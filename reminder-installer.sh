cat <<'SH' > reminder-installer.sh
#!/bin/bash
set -e

APP_DIR="/opt/meshtastic-reminder"
USER_NAME="${SUDO_USER:-$USER}"

echo "==> Systempakete"
sudo apt-get update
sudo apt-get install -y python3-venv python3-pip

echo "==> App-Verzeichnis"
sudo mkdir -p "$APP_DIR"
sudo chown -R "$USER_NAME":"$USER_NAME" "$APP_DIR"

echo "==> Python venv + Pakete"
python3 -m venv "$APP_DIR/.venv"
"$APP_DIR/.venv/bin/pip" install --upgrade pip
"$APP_DIR/.venv/bin/pip" install flask gunicorn meshtastic

echo "==> settings.json"
cat > "$APP_DIR/settings.json" <<'JSON'
{
  "port": "/dev/ttyUSB0",
  "channel_index": 2,
  "destination": "",
  "timezone": "Europe/Berlin",
  "admin_token": ""
}
JSON

echo "==> reminders.json"
cat > "$APP_DIR/reminders.json" <<'JSON'
{
  "reminders": []
}
JSON

echo "==> web.py"
cat > "$APP_DIR/web.py" <<'PY'
#!/usr/bin/env python3
import json, uuid, os
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo
from flask import Flask, request, jsonify

APP_DIR = os.path.dirname(os.path.abspath(__file__))
REM_FILE = os.path.join(APP_DIR, "reminders.json")
SET_FILE = os.path.join(APP_DIR, "settings.json")
app = Flask(__name__)

def load_settings():
    with open(SET_FILE, "r", encoding="utf-8") as f: return json.load(f)
def save_settings(s):
    with open(SET_FILE, "w", encoding="utf-8") as f: json.dump(s, f, indent=2, ensure_ascii=False)
def load_reminders():
    with open(REM_FILE, "r", encoding="utf-8") as f: return json.load(f)
def save_reminders(d):
    with open(REM_FILE, "w", encoding="utf-8") as f: json.dump(d, f, indent=2, ensure_ascii=False)

def require_token_if_configured():
    token = (load_settings().get("admin_token") or "")
    if token and request.headers.get("X-Admin-Token","") != token: return False
    return True

@app.route("/")
def index():
    return f"""<!doctype html>
<html lang="de" data-theme="dark"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Meshtastic Erinnerungen (7 Tage)</title>
<style>
:root{{--bg:#0b0d10;--card:#12161b;--muted:#1b222b;--line:#24303d;--text:#e2e8f0;--sub:#94a3b8;--accent:#0ea5e9;--accent2:#22d3ee;--danger:#ef4444;--mono:ui-monospace,Menlo,Consolas,monospace}}
*{{box-sizing:border-box}} body{{background:var(--bg);color:var(--text);font-family:system-ui,-apple-system,Segoe UI,Roboto,Ubuntu;max-width:980px;margin:20px auto;padding:0 12px}}
header{{display:flex;gap:12px;align-items:center;justify-content:space-between}} h1{{font-size:1.4rem;margin:6px 0}}
.card{{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:12px;margin:12px 0;box-shadow:0 8px 30px rgba(0,0,0,.25)}}
.row{{display:flex;gap:12px;flex-wrap:wrap}} .row>*{{flex:1 1 220px}}
label{{font-size:.9rem;font-weight:600;display:block;margin-bottom:4px;color:var(--sub)}}
input,textarea{{background:var(--bg);color:var(--text);width:100%;padding:10px;border:1px solid var(--line);border-radius:10px;outline:none}}
button{{padding:10px 14px;border:0;border-radius:12px;cursor:pointer;font-weight:600}} .primary{{background:var(--accent);color:#00111a}} .ghost{{background:var(--muted)}} .danger{{background:var(--danger);color:#fff}}
table{{width:100%;border-collapse:collapse;margin-top:10px}} th,td{{border-bottom:1px solid var(--line);padding:10px;text-align:left}} th{{color:var(--sub)}}
small.mono{{font-family:var(--mono);color:var(--sub)}}
.grid-30{{display:grid;grid-template-columns:repeat(auto-fill,minmax(90px,1fr));gap:8px;margin-top:10px}}
.slot{{background:var(--muted);border:1px solid var(--line);border-radius:10px;padding:10px;text-align:center;cursor:pointer}} .slot:hover{{outline:2px solid var(--accent2)}}
.modal-backdrop{{position:fixed;inset:0;background:rgba(0,0,0,.6);display:none;align-items:center;justify-content:center;z-index:1000}}
.modal{{width:min(720px,92vw);background:var(--card);border:1px solid var(--line);border-radius:16px;padding:14px}}
.right{{text-align:right}}
</style></head><body>
<header>
  <h1>Meshtastic Reminder – nächste 7 Tage</h1>
  <div>
    <button id="openWindow" class="ghost">30-Minuten-Fenster</button>
    <button id="refresh" class="primary">Aktualisieren</button>
  </div>
</header>

<div class="card">
  <h3>Standardeinstellungen</h3>
  <div class="row">
    <div><label>Serieller Port (Heltec V3)</label><input id="port" placeholder="/dev/ttyUSB0"></div>
    <div><label>Channel Index</label><input id="ch" type="number" min="0" max="7" value="2"></div>
    <div><label>Destination (optional, z.B. !XXXXXXXX)</label><input id="dest" placeholder=""></div>
    <div><label>Timezone</label><input id="tz" placeholder="Europe/Berlin"></div>
  </div>
  <div class="row">
    <div><label>Admin Token (optional)</label><input id="token" type="password" placeholder=""></div>
  </div>
  <button class="primary" id="saveSettings">Einstellungen speichern</button>
  <small class="mono">Dispatcher prüft alle 30&nbsp;Minuten.</small>
</div>

<div class="card">
  <h3>Erinnerung anlegen (innerhalb 7 Tage)</h3>
  <div class="row"><div><label>Nachricht</label><textarea id="text" rows="3" maxlength="250" placeholder="Was soll gesendet werden?"></textarea></div></div>
  <div class="row">
    <div><label>Datum</label><input id="date" type="date"></div>
    <div><label>Uhrzeit</label><input id="time" type="time" step="1800"></div>
    <div><label>Channel Index (optional)</label><input id="choverride" type="number" min="0" max="7" placeholder=""></div>
    <div><label>Destination (optional)</label><input id="destoverride" placeholder=""></div>
  </div>
  <div class="row">
    <button class="ghost" id="pickWindow">Zeit im 30-Min-Fenster wählen</button><span></span><span></span>
    <button class="primary" id="add">Erinnerung speichern</button>
  </div>
</div>

<div class="card">
  <h3>Geplante Erinnerungen</h3>
  <table><thead><tr><th>Wann</th><th>Text</th><th>Ch/Dest</th><th>Status</th><th>Aktion</th></tr></thead>
  <tbody id="rows"></tbody></table>
</div>

<div class="modal-backdrop" id="mb">
  <div class="modal">
    <header><h3 style="margin:0">Zeit auswählen (30-Minuten-Raster)</h3></header>
    <div class="row">
      <div><label>Datum</label><input id="wdate" type="date"></div>
      <div class="right" style="flex:1 1 auto"><label>&nbsp;</label><button class="ghost" id="closeWin">Schließen</button></div>
    </div>
    <div class="grid-30" id="slots"></div>
  </div>
</div>

<script>
const $=s=>document.querySelector(s); const pad=n=>String(n).padStart(2,"0");
function setDateBounds(input){const now=new Date(), max=new Date(); max.setDate(max.getDate()+7);
  input.min=`${now.getFullYear()}-${pad(now.getMonth()+1)}-${pad(now.getDate())}`;
  input.max=`${max.getFullYear()}-${pad(max.getMonth()+1)}-${pad(max.getDate())}`;}
function fillSlots(dateStr){const g=$("#slots"); g.innerHTML="";
  for(let h=0;h<24;h++){for(let m=0;m<60;m+=30){const t=`${pad(h)}:${pad(m)}`, d=document.createElement("div");
    d.className="slot"; d.textContent=t; d.onclick=()=>{$("#date").value=dateStr; $("#time").value=t; $("#mb").style.display="none";}; g.appendChild(d);}}}
async function loadAll(){
  const r=await fetch("/api/all"), data=await r.json(), s=data.settings;
  $("#port").value=s.port||""; $("#ch").value=s.channel_index??2; $("#dest").value=s.destination||""; $("#tz").value=s.timezone||"Europe/Berlin"; $("#token").value=s.admin_token||"";
  const tbody=$("#rows"); tbody.innerHTML="";
  for(const rem of data.reminders.reminders){
    const tr=document.createElement("tr");
    tr.innerHTML=`<td><small class="mono">${rem.when}</small></td><td>${rem.text.replace(/</g,"&lt;")}</td>
    <td><small class="mono">ch=${rem.channel_index??"(std)"}<br>${rem.destination||"(broadcast)"}</small></td>
    <td>${rem.status}</td><td><button class="danger" data-id="${rem.id}">Löschen</button></td>`;
    tbody.appendChild(tr);
  }
  tbody.querySelectorAll("button.danger").forEach(b=>b.onclick=async()=>{
    const headers={}, token=$("#token").value.trim(); if(token) headers["X-Admin-Token"]=token;
    await fetch("/api/reminder/"+b.dataset.id,{method:"DELETE",headers}); loadAll();
  });
  setDateBounds($("#date")); setDateBounds($("#wdate"));
  const now=new Date(), d=`${now.getFullYear()}-${pad(now.getMonth()+1)}-${pad(now.getDate())}`;
  if(!$("#date").value) $("#date").value=d; if(!$("#wdate").value) $("#wdate").value=d; fillSlots($("#wdate").value);
}
$("#refresh").onclick=loadAll;
$("#saveSettings").onclick=async()=>{
  const payload={port:$("#port").value.trim(), channel_index:Number($("#ch").value), destination:$("#dest").value.trim(),
    timezone:$("#tz").value.trim()||"Europe/Berlin", admin_token:$("#token").value.trim()};
  const headers={"Content-Type":"application/json"}; if(payload.admin_token) headers["X-Admin-Token"]=payload.admin_token;
  await fetch("/api/settings",{method:"PUT",headers,body:JSON.stringify(payload)}); loadAll();
};
$("#add").onclick=async()=>{
  const text=$("#text").value.trim(), date=$("#date").value, time=$("#time").value;
  if(!text||!date||!time){alert("Bitte Text, Datum und Uhrzeit angeben."); return;}
  const chOverride=$("#choverride").value.trim(), destOverride=$("#destoverride").value.trim();
  const payload={text, when_local:`${date}T${time}:00`, channel_index: chOverride===""?null:Number(chOverride), destination: destOverride||null};
  const headers={"Content-Type":"application/json"}, token=$("#token").value.trim(); if(token) headers["X-Admin-Token"]=token;
  const resp=await fetch("/api/reminder",{method:"POST",headers,body:JSON.stringify(payload)});
  if(!resp.ok){alert("Fehler: "+await resp.text()); return;}
  $("#text").value=""; $("#time").value=""; $("#choverride").value=""; $("#destoverride").value=""; loadAll();
};
$("#openWindow").onclick=()=>{$("#mb").style.display="flex"}; $("#pickWindow").onclick=()=>{$("#mb").style.display="flex"};
$("#closeWin").onclick=()=>{$("#mb").style.display="none"}; $("#wdate").onchange=e=>fillSlots(e.target.value);
loadAll();
</script></body></html>"""
@app.route("/api/all")
def api_all(): return jsonify({"settings": load_settings(), "reminders": load_reminders()})
@app.route("/api/settings", methods=["PUT"])
def api_settings():
    if not require_token_if_configured(): return "Forbidden", 403
    new = request.get_json(force=True)
    if not new.get("port"): return "Port erforderlich", 400
    if new.get("channel_index") is None: return "channel_index erforderlich", 400
    save_settings({"port":new["port"],"channel_index":int(new["channel_index"]),
                   "destination":new.get("destination") or "","timezone":new.get("timezone") or "Europe/Berlin",
                   "admin_token":new.get("admin_token") or ""})
    return "OK", 200
@app.route("/api/reminder", methods=["POST"])
def api_add_reminder():
    if not require_token_if_configured(): return "Forbidden", 403
    s = load_settings(); tz = ZoneInfo(s.get("timezone") or "Europe/Berlin")
    p = request.get_json(force=True)
    text = (p.get("text") or "").strip(); when_local = p.get("when_local")
    if not text or not when_local: return "text und when_local sind erforderlich", 400
    try:
        dt_local = datetime.fromisoformat(when_local); now = datetime.now(tz).replace(microsecond=0)
        dt_local = (dt_local if dt_local.tzinfo else dt_local.replace(tzinfo=tz)).astimezone(tz)
    except Exception: return "Ungültiges Datum/Uhrzeit", 400
    if dt_local < now: return "Zeitpunkt liegt in der Vergangenheit", 400
    if dt_local > (now + timedelta(days=7)): return "Nur Termine innerhalb der nächsten 7 Tage erlaubt", 400
    data = load_reminders(); rid = str(uuid.uuid4())
    data["reminders"].append({"id":rid,"text":text,"when":dt_local.replace(microsecond=0).isoformat(),
                              "channel_index":p.get("channel_index"),"destination":p.get("destination"),
                              "status":"pending","last_error":""})
    save_reminders(data); return jsonify({"id": rid}), 201
@app.route("/api/reminder/<rid>", methods=["DELETE"])
def api_delete_reminder(rid):
    if not require_token_if_configured(): return "Forbidden", 403
    data = load_reminders(); before = len(data["reminders"])
    data["reminders"] = [r for r in data["reminders"] if r["id"] != rid]
    if len(data["reminders"]) == before: return "not found", 404
    save_reminders(data); return "OK", 200
if __name__ == "__main__": app.run(host="0.0.0.0", port=8080)
PY
chmod +x "$APP_DIR/web.py"

echo "==> dispatch.py"
cat > "$APP_DIR/dispatch.py" <<'PY'
#!/usr/bin/env python3
import json, os, subprocess
from datetime import datetime
from zoneinfo import ZoneInfo

APP_DIR = os.path.dirname(os.path.abspath(__file__))
REM_FILE = os.path.join(APP_DIR, "reminders.json")
SET_FILE = os.path.join(APP_DIR, "settings.json")

def load_json(p): 
    with open(p, "r", encoding="utf-8") as f: return json.load(f)
def save_json(p, obj):
    tmp=p+".tmp"
    with open(tmp,"w",encoding="utf-8") as f: json.dump(obj,f,indent=2,ensure_ascii=False)
    os.replace(tmp,p)

def send_meshtastic(text, port, ch_index, destination):
    cmd = ["meshtastic","--port",port]
    if ch_index is not None: cmd += ["--ch-index", str(ch_index)]
    if destination: cmd += ["--dest", destination]
    cmd += ["--sendtext", text]
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    return res.returncode==0, (res.stdout or "")+(res.stderr or "")

def main():
    settings = load_json(SET_FILE)
    tz = ZoneInfo(settings.get("timezone") or "Europe/Berlin")
    port = settings.get("port") or "/dev/ttyUSB0"
    default_ch = settings.get("channel_index", 2)
    default_dest = settings.get("destination", "")

    store = load_json(REM_FILE)
    changed = False
    now = datetime.now(tz).replace(microsecond=0)

    for r in store.get("reminders", []):
        if r.get("status") != "pending": continue
        try:
            dt = datetime.fromisoformat(r["when"])
            dt = (dt if dt.tzinfo else dt.replace(tzinfo=tz)).astimezone(tz)
        except Exception:
            r["status"]="error"; r["last_error"]="Ungültiges Datum im Eintrag"; changed=True; continue
        if dt <= now:
            ch = r.get("channel_index"); ch = default_ch if ch is None else ch
            dest = r.get("destination") or default_dest or ""
            ok, out = send_meshtastic(r["text"], port, ch, dest)
            if ok: r["status"]="sent"; r["last_error"]=""
            else:  r["status"]="error"; r["last_error"]=out
            changed = True
    if changed: save_json(REM_FILE, store)

if __name__ == "__main__": main()
PY
chmod +x "$APP_DIR/dispatch.py"

echo "==> dialout-Gruppe"
sudo usermod -aG dialout "$USER_NAME" || true

echo "==> systemd: Web (8080) + Timer (30 Min)"
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

echo "==> Dienste starten"
sudo systemctl daemon-reload
sudo systemctl enable --now mesh-reminders-web.service
sudo systemctl enable --now mesh-reminders-dispatch.timer

IP=$(hostname -I | awk '{print $1}')
echo
echo "=========================================================="
echo " Web-UI:  http://display.local:8080  (oder: http://$IP:8080)"
echo " Logs:    sudo journalctl -u mesh-reminders-web -f"
echo "          sudo journalctl -u mesh-reminders-dispatch -f"
echo "=========================================================="
SH
