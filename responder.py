#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Meshtastic Auto-Responder: reply on Channel 4 to "Hi" with RX/Radio stats
# pip install meshtastic pubsub
# Install:
# pip install --upgrade meshtastic pubsub
# chmod +x responder_ch4_hi_stats.py
# ./responder_ch4_hi_stats.py


import time
import re
from collections import deque
from pubsub import pub
from meshtastic.serial_interface import SerialInterface

PORT = "/dev/ttyUSB0"        # ggf. /dev/ttyACM0 oder /dev/serial0
TARGET_CHANNEL = 4           # antwortet NUR auf Channel 4
TRIGGER_RE = re.compile(r"^\s*hi\s*$", re.I)

RATE_LIMIT_SECONDS = 10
SEEN_CACHE = deque(maxlen=200)

iface = SerialInterface(PORT)

# Versuche, ein paar Radio-Infos zu cachen (für die Antwort)
def safe_get_radio_info():
    info = {}
    try:
        # Manche Versionen befüllen diese Properties nach connect()
        rc = getattr(iface, "radioConfig", None)
        lc = getattr(iface, "localConfig", None)

        # TX-Power (dBm)
        if rc and hasattr(rc, "preferences") and rc.preferences:
            # je nach Version: rc.preferences.txPower oder .tx_power
            txp = getattr(rc.preferences, "txPower", None) or getattr(rc.preferences, "tx_power", None)
            if txp is not None:
                info["txPower_dBm"] = int(txp)

        # Region / Band
        if rc and hasattr(rc, "preferences") and rc.preferences:
            reg = getattr(rc.preferences, "region", None)
            if reg:
                info["region"] = str(reg)

        # Modem-Settings (SF/BW) – je nach Firmware ggf. unter channelSettings
        # Wir nehmen Primary als Referenz; falls Channel 4 anders ist, ist das hier “best effort”
        if rc and hasattr(rc, "channelSettings") and rc.channelSettings:
            # channelSettings ist meist ein Array (0..7)
            cs_primary = rc.channelSettings[0] if len(rc.channelSettings) > 0 else None
            if cs_primary:
                sf = getattr(cs_primary.modemConfig, "spreadFactor", None) if hasattr(cs_primary, "modemConfig") else None
                bw = getattr(cs_primary.modemConfig, "bandwidth", None) if hasattr(cs_primary, "modemConfig") else None
                if sf is not None:
                    info["sf"] = int(sf)
                if bw is not None:
                    info["bw_khz"] = int(bw)  # Firmware liefert häufig 125/250/500 (kHz)
    except Exception:
        pass
    return info

RADIO_INFO = safe_get_radio_info()

# Eigen-Node-Nummer besorgen (zur Loop-Vermeidung; best effort)
try:
    my_info = iface.getMyNodeInfo()
    MY_NUM = my_info.get("my_node_num") if isinstance(my_info, dict) else None
except Exception:
    MY_NUM = None

last_reply = {}

def ok_rate_limit(sender, now):
    t = last_reply.get(sender, 0)
    if now - t >= RATE_LIMIT_SECONDS:
        last_reply[sender] = now
        return True
    return False

def build_reply(packet, ch_idx):
    """
    Baut eine kompakte Antwort aus Packet-Metadaten.
    Wir nutzen, was das Paket hergibt: rxRssi (dBm), rxSnr (dB), hops, etc.
    + (falls vorhanden) lokale Radio-Infos (TX-Power/Region/SF/BW).
    Hinweis: 'dBi' (Antennengewinn) kann NICHT aus Paketen ermittelt werden.
    """
    fields = []

    # RX-Qualität
    rssi = packet.get("rxRssi", None)
    snr  = packet.get("rxSnr", None)

    # hops: je nach Version in decoded['hopLimit'] (Rest) oder packet['hopsAway']
    dec = packet.get("decoded", {}) or {}
    hop_limit_left = dec.get("hopLimit", None)
    hops_away = packet.get("hopsAway", None)

    if rssi is not None:
        fields.append(f"RSSI {int(rssi)} dBm")
    if snr is not None:
        # snr ist üblicherweise float
        try:
            fields.append(f"SNR {snr:.1f} dB")
        except Exception:
            fields.append(f"SNR {snr} dB")

    if hops_away is not None:
        fields.append(f"Hops {int(hops_away)}")
    elif hop_limit_left is not None:
        fields.append(f"HopLimit {int(hop_limit_left)}")

    fields.append(f"Ch {ch_idx}")

    # Lokale Radio-Settings (sofern bekannt)
    if RADIO_INFO.get("txPower_dBm") is not None:
        fields.append(f"TX {RADIO_INFO['txPower_dBm']} dBm")
    if RADIO_INFO.get("region"):
        fields.append(f"Reg {RADIO_INFO['region']}")
    if RADIO_INFO.get("sf") is not None:
        fields.append(f"SF {RADIO_INFO['sf']}")
    if RADIO_INFO.get("bw_khz") is not None:
        fields.append(f"BW {RADIO_INFO['bw_khz']} kHz")

    # dBi explizit adressieren (nicht messbar)
    fields.append("(dBi: not measurable)")

    return " | ".join(fields)

def on_receive(packet, interface):
    try:
        # Duplikate raus
        h = repr(packet)
        if h in SEEN_CACHE:
            return
        SEEN_CACHE.append(h)

        # eigene Pakete ignorieren (wenn möglich)
        if MY_NUM is not None and packet.get('from') == MY_NUM:
            return

        dec = packet.get("decoded", {}) or {}
        port = dec.get("portnum")

        # nur Textnachrichten
        if port not in ("TEXT_MESSAGE", 1, "PORTNUM_TEXT_MESSAGE"):
            return

        text = (dec.get("text") or "").strip()
        ch_idx = dec.get("channel", 0)

        # Wir reagieren NUR auf Channel 4
        if ch_idx != TARGET_CHANNEL:
            return

        # Trigger "Hi" (case-insensitive, exakt)
        if not TRIGGER_RE.match(text):
            return

        # Rate-Limit pro Absender
        sender = packet.get('fromId') or packet.get('from')
        now = time.time()
        if not ok_rate_limit(sender, now):
            return

        reply = build_reply(packet, ch_idx)
        iface.sendText(reply, channelIndex=ch_idx)
        print(f"[auto-reply@ch{ch_idx}] -> {reply}")

    except Exception as e:
        print("on_receive error:", e)

from collections import deque
SEEN_CACHE = deque(maxlen=200)

from pubsub import pub
pub.subscribe(on_receive, "meshtastic.receive")

print(f"Connected to {PORT}. Listening on channel {TARGET_CHANNEL} for 'Hi'… (Ctrl+C to exit)")
try:
    while True:
        time.sleep(0.2)
except KeyboardInterrupt:
    pass
finally:
    try:
        iface.close()
    except Exception:
        pass
