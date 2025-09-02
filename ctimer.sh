#!/usr/bin/env bash
# timer-wizard.sh — Dialog-UI für systemd User-Timer/Services
# Features:
#  - Bestehende Timer auflisten, Status ansehen, starten/stoppen, enable/disable, jetzt ausführen
#  - Neue Timer anlegen: Daily, Wochentage, Intervall (OnUnitActiveSec), Fenster (RandomizedDelaySec),
#    freie OnCalendar-Eingabe, optional zusätzliches Jitter
#  - Einfache Editierfunktionen für Service/Timer-Dateien
#  - Läuft nutzerweit in ~/.config/systemd/user (kein sudo nötig)
#
# Getestet auf Ubuntu/KDE (Plasma). Benötigt: dialog, systemd --user
# -----------------------------------------------------------------------------

set -euo pipefail

APP_TITLE="Systemd Timer Wizard"
SYSUSER_DIR="$HOME/.config/systemd/user"

# ----- Helpers ---------------------------------------------------------------

need_dialog() {
  if ! command -v dialog >/dev/null 2>&1; then
    echo "dialog ist nicht installiert. Installiere es z. B. mit:"
    echo "  sudo apt update && sudo apt install -y dialog"
    exit 1
  fi
}

ensure_dirs() {
  mkdir -p "$SYSUSER_DIR"
}

reload_user_daemon() {
  systemctl --user daemon-reload
}

msg() {
  dialog --title "$APP_TITLE" --msgbox "$1" 10 70
}

yesno() {
  dialog --title "$APP_TITLE" --yesno "$1" 10 70
}

inputbox() {
  # $1 prompt, $2 default
  dialog --title "$APP_TITLE" --inputbox "$1" 10 70 "$2" 3>&1 1>&2 2>&3
}

menu() {
  # $1 title, then pairs (tag desc) via stdin
  dialog --title "$APP_TITLE" --menu "$1" 15 80 10 "$@" 3>&1 1>&2 2>&3
}

checklist() {
  # $1 title, items triplets: tag desc on/off
  dialog --title "$APP_TITLE" --checklist "$1" 18 80 10 "$@" 3>&1 1>&2 2>&3
}

fselect() {
  # $1 path
  dialog --title "$APP_TITLE" --fselect "$1" 20 80 3>&1 1>&2 2>&3
}

edit_in_editor() {
  local file="$1"
  ${EDITOR:-nano} "$file"
}

sanitize_unit_name() {
  local s="$1"
  s="${s// /-}"
  s="${s//[^A-Za-z0-9_.@-]/-}"
  echo "$s"
}

list_user_timers() {
  # Liste nur Timer, die in unserem User-dir existieren
  find "$SYSUSER_DIR" -maxdepth 1 -type f -name "*.timer" -printf "%f\n" | sort
}

timer_to_service() {
  echo "${1%.timer}.service"
}

# ----- Create Timer ----------------------------------------------------------

create_timer_flow() {
  # Name
  local rawname
  rawname="$(inputbox "Name des Timers (wird als Unit-Name verwendet, z. B. dnk-msg-bot)" "my-job")" || return
  local unit_base
  unit_base="$(sanitize_unit_name "$rawname")"
  if [[ -z "$unit_base" ]]; then msg "Ungültiger Name."; return; fi

  # Skript
  local script_path
  script_path="$(fselect "$HOME/")" || return
  if [[ -z "$script_path" || ! -f "$script_path" ]]; then msg "Skript-Datei existiert nicht."; return; fi

  # WorkingDirectory
  local workdir_default
  workdir_default="$(dirname "$script_path")"
  local workdir
  workdir="$(inputbox "WorkingDirectory (wo das Skript läuft)" "$workdir_default")" || return
  [[ -d "$workdir" ]] || { msg "WorkingDirectory existiert nicht."; return; }

  # Beschreibung
  local descr
  descr="$(inputbox "Beschreibung (Service Description)" "$unit_base")" || return

  # Planungstyp
  local choice
  choice=$(dialog --title "$APP_TITLE" --menu "Planungstyp wählen" 18 80 10 \
    daily "Täglich um bestimmte Uhrzeit" \
    weekly "Wochentage um bestimmte Uhrzeit" \
    interval "Intervall (alle N Minuten/Stunden/Tage)" \
    window "Zeitfenster (einmal täglich zufällig innerhalb eines Fensters)" \
    raw "Freies OnCalendar (systemd-Format)" \
    3>&1 1>&2 2>&3) || return

  local oncalendar="" randomized="" persistent="true" onunitactiveseq=""

  case "$choice" in
    daily)
      local t
      t="$(inputbox "Uhrzeit (HH:MM), z. B. 09:30" "09:00")" || return
      oncalendar="*-*-* $t:00"
      ;;
    weekly)
      local t
      t="$(inputbox "Uhrzeit (HH:MM), z. B. 09:30" "09:00")" || return
      # Checkliste Wochentage
      local days
      days=$(checklist "Wähle Wochentage" \
        Mon "Montag" on \
        Tue "Dienstag" on \
        Wed "Mittwoch" on \
        Thu "Donnerstag" on \
        Fri "Freitag" on \
        Sat "Samstag" off \
        Sun "Sonntag" off) || return
      # days ist z. B. "Mon" "Tue"
      days="${days//\"/}"
      if [[ -z "$days" ]]; then msg "Keine Tage gewählt."; return; fi
      # systemd erlaubt: Mon,Fri *-*-* 09:00:00
      local csv_days
      csv_days=$(echo "$days" | sed 's/ /,/g')
      oncalendar="$csv_days *-*-* ${t}:00"
      ;;
    interval)
      # Intervall via OnUnitActiveSec
      local n unit
      n="$(inputbox "Intervall-Zahl (z. B. 15)" "15")" || return
      unit=$(dialog --title "$APP_TITLE" --menu "Einheit" 12 60 5 \
        s "Sekunden" m "Minuten" h "Stunden" d "Tage" 3>&1 1>&2 2>&3) || return
      case "$unit" in
        s) onunitactiveseq="${n}s" ;;
        m) onunitactiveseq="${n}min" ;;
        h) onunitactiveseq="${n}h" ;;
        d) onunitactiveseq="${n}d" ;;
      esac
      # OnBootSec optional?
      local bootsec
      bootsec="$(inputbox "Start nach Boot (OnBootSec), leer lassen für 0" "")" || true
      # Random Jitter?
      randomized="$(inputbox "Optionales zusätzliches Jitter (RandomizedDelaySec), z. B. 60s oder leer" "")" || true
      # Speichere Parameter in globals für Write
      WRITE_INTERVAL_BOOTSEC="$bootsec"
      ;;
    window)
      # Fenster = Starte täglich ab Startzeit, zufällig innerhalb Dauer
      local start tdur
      start="$(inputbox "Fenster-Start (HH:MM), z. B. 08:00" "08:00")" || return
      tdur="$(inputbox "Fenster-Dauer in Minuten (z. B. 120 für 2h)" "120")" || return
      oncalendar="*-*-* ${start}:00"
      randomized="$((tdur*60))s"
      ;;
    raw)
      oncalendar="$(inputbox "OnCalendar Ausdruck (z. B. Mon..Fri 09:00)" "*-*-* 09:00:00")" || return
      randomized="$(inputbox "Optionales RandomizedDelaySec (z. B. 300s), leer für kein Jitter" "")" || true
      ;;
  esac

  # Persistenz
  if yesno "Persistent=true setzen? (Nachhol-Trigger bei ausgeschaltetem System)"; then
    persistent="true"
  else
    persistent="false"
  fi

  # Zus. Jitter abfragen, falls daily/weekly
  if [[ "$choice" == "daily" || "$choice" == "weekly" ]]; then
    randomized="$(inputbox "Optionales RandomizedDelaySec (z. B. 300s), leer für kein Jitter" "${randomized:-}")" || true
  fi

  # Dateien schreiben
  local svc="$SYSUSER_DIR/${unit_base}.service"
  local tmr="$SYSUSER_DIR/${unit_base}.timer"

  cat > "$svc" <<EOF
[Unit]
Description=$descr

[Service]
Type=simple
WorkingDirectory=$workdir
ExecStart=$script_path
# Optional: Env VARS hier setzen, Logausgabe landet in journalctl --user -u ${unit_base}.service
EOF

  # Timer-Datei
  {
    echo "[Unit]"
    echo "Description=Timer for ${unit_base}.service"
    echo
    echo "[Timer]"
    if [[ -n "${oncalendar:-}" ]]; then
      echo "OnCalendar=$oncalendar"
    fi
    if [[ -n "${onunitactiveseq:-}" ]]; then
      echo "OnUnitActiveSec=$onunitactiveseq"
      # Boot-Verzögerung optional
      if [[ -n "${WRITE_INTERVAL_BOOTSEC:-}" ]]; then
        echo "OnBootSec=${WRITE_INTERVAL_BOOTSEC}"
      fi
    fi
    if [[ -n "${randomized:-}" ]]; then
      echo "RandomizedDelaySec=$randomized"
    fi
    echo "Persistent=$persistent"
    echo "Unit=${unit_base}.service"
    echo
    echo "[Install]"
    echo "WantedBy=timers.target"
  } > "$tmr"

  reload_user_daemon
  systemctl --user enable --now "${unit_base}.timer" >/dev/null 2>&1 || true

  msg "Timer angelegt und aktiviert:\n\nService: $svc\nTimer:   $tmr\n\nStatus:\n$(systemctl --user is-enabled "${unit_base}.timer" 2>/dev/null) / $(systemctl --user is-active "${unit_base}.timer" 2>/dev/null)"
}

# ----- Manage existing -------------------------------------------------------

show_timer_status() {
  local name="$1"
  local out
  out="$(systemctl --user status "$name" 2>&1 | sed -e 's/\x1b\[[0-9;]*m//g')"
  dialog --title "$APP_TITLE — $name" --msgbox "$out" 25 100
}

run_now_service() {
  local base="${1%.timer}"
  systemctl --user start "${base}.service"
  msg "Service ${base}.service wurde gestartet (manuell)."
}

toggle_enable() {
  local name="$1"
  if systemctl --user is-enabled "$name" >/dev/null 2>&1; then
    systemctl --user disable "$name"
    msg "$name wurde disabled."
  else
    systemctl --user enable "$name"
    msg "$name wurde enabled."
  fi
}

start_stop_timer() {
  local name="$1"
  if systemctl --user is-active "$name" >/dev/null 2>&1; then
    systemctl --user stop "$name"
    msg "$name wurde gestoppt."
  else
    systemctl --user start "$name"
    msg "$name wurde gestartet."
  fi
}

edit_timer() {
  local name="$1"
  local file="$SYSUSER_DIR/$name"
  edit_in_editor "$file"
  reload_user_daemon
  msg "Gespeichert. systemd neu geladen."
}

edit_service_for_timer() {
  local name="$1"
  local svc
  svc="$(timer_to_service "$name")"
  local file="$SYSUSER_DIR/$svc"
  if [[ ! -f "$file" ]]; then
    msg "Service-Datei nicht gefunden: $file"
    return
  fi
  edit_in_editor "$file"
  reload_user_daemon
  msg "Gespeichert. systemd neu geladen."
}

delete_timer() {
  local name="$1"
  local base="${name%.timer}"
  local svc="$SYSUSER_DIR/${base}.service"
  local tmr="$SYSUSER_DIR/${base}.timer"
  if yesno "Wirklich löschen?\n\n- Stop/Disable ${name}\n- Dateien entfernen\n- daemon-reload"; then
    systemctl --user stop "$name" >/dev/null 2>&1 || true
    systemctl --user disable "$name" >/dev/null 2>&1 || true
    rm -f "$tmr" "$svc"
    reload_user_daemon
    msg "Gelöscht: $tmr und $svc"
  fi
}

manage_existing_flow() {
  local timers
  mapfile -t timers < <(list_user_timers)
  if [[ ${#timers[@]} -eq 0 ]]; then
    msg "Keine Timer in $SYSUSER_DIR gefunden."
    return
  fi

  # Build menu list (tag desc)
  local items=()
  for t in "${timers[@]}"; do
    local active="inactive"
    systemctl --user is-active "$t" >/dev/null 2>&1 && active="active"
    items+=("$t" "$active")
  done

  local pick
  pick=$(dialog --title "$APP_TITLE" --menu "Timer auswählen" 20 80 12 "${items[@]}" 3>&1 1>&2 2>&3) || return

  while true; do
    local act
    act=$(dialog --title "$APP_TITLE — $pick" --menu "Aktion" 18 80 10 \
      status "Status anzeigen" \
      startstop "Start/Stop Timer" \
      enabletoggle "Enable/Disable" \
      runnow "Service jetzt ausführen (sofort)" \
      edit_timer "Timer-Datei bearbeiten" \
      edit_service "Service-Datei bearbeiten" \
      delete "Timer + Service löschen" \
      back "Zurück" \
      3>&1 1>&2 2>&3) || break

    case "$act" in
      status) show_timer_status "$pick" ;;
      startstop) start_stop_timer "$pick" ;;
      enabletoggle) toggle_enable "$pick" ;;
      runnow) run_now_service "$pick" ;;
      edit_timer) edit_timer "$pick" ;;
      edit_service) edit_service_for_timer "$pick" ;;
      delete) delete_timer "$pick"; break ;;
      back) break ;;
    esac
  done
}

# ----- Main ------------------------------------------------------------------

main_menu() {
  while true; do
    local choice
    choice=$(dialog --title "$APP_TITLE" --menu "Was möchtest du tun?" 15 80 8 \
      create "Neuen Timer anlegen" \
      manage "Bestehende Timer verwalten" \
      reload "systemd --user neu laden" \
      journal "Journal (Logs) ansehen" \
      quit "Beenden" \
      3>&1 1>&2 2>&3) || { clear; exit 0; }

    case "$choice" in
      create) create_timer_flow ;;
      manage) manage_existing_flow ;;
      reload) reload_user_daemon; msg "daemon-reload ausgeführt." ;;
      journal)
        # Kurzer Log-Viewer über dialog (tail -n 200)
        local unit
        unit="$(inputbox "Unit-Name (z. B. my-job.service oder .timer)" "")" || continue
        local out
        out="$(journalctl --user -u "$unit" -n 200 --no-pager 2>&1 | sed -e 's/\x1b\[[0-9;]*m//g')"
        dialog --title "$APP_TITLE — Logs: $unit" --msgbox "$out" 25 100
        ;;
      quit) clear; exit 0 ;;
    esac
  done
}

# ----- Run -------------------------------------------------------------------

need_dialog
ensure_dirs

# Prüfe, ob systemd --user läuft (typisch ok in Desktop-Sessions)
if ! systemctl --user status >/dev/null 2>&1; then
  msg "Achtung: 'systemctl --user' ist nicht aktiv. Falls du per SSH ohne Login-Session arbeitest, aktiviere linger:\n\n  loginctl enable-linger \"$USER\"\n\nund melde dich neu an."
fi

main_menu
