#!/usr/bin/env python3
"""
Simuleret doer-enhed - test adgangs-servicen uden Raspberry Pi.

Sender en adgangsanmodning som doeren ville goere og venter paa svaret.
"Ansigter" er falske embeddings lavet ud fra et navn (--face mette), saa
samme navn altid giver samme ansigt: tilmeld med --enroll og test bagefter.

Paa VM'en (lokal listener, doer-brugerens login):
  python3 /opt/lockdin/simulate_door.py --user iot_device --password '...' \\
      --device door-hoveddoer --card 04:A3:2F:1B --pin 1234

Fra en laptop/Pi (TLS paa 8883, kraever mqtt-ca.crt):
  python3 simulate_door.py --host <mqtt_host> --port 8883 --cafile mqtt-ca.crt ...

Eksempler:
  --card 04:A3:2F:1B --pin 1234            RFID + PIN
  --card 04:A3:2F:1B --face mette          RFID + ansigt
  --enroll 1 --face mette                  gem "mette"-ansigtet paa bruger 1
  --listen                                 vis kommandoer (fjernaabning) til doeren
"""

import argparse
import hashlib
import json
import random
import ssl
import sys
import threading
import time
import uuid


def fake_embedding(name):
    """Deterministisk 128-dim 'ansigt' ud fra et navn (samme som face_recognition-format)."""
    rnd = random.Random(hashlib.sha256(name.encode()).digest())
    return [round(rnd.uniform(-0.25, 0.25), 6) for _ in range(128)]


def main():
    import paho.mqtt.client as mqtt  # her, saa testene kan importere fake_embedding uden paho

    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=1883)
    p.add_argument("--cafile", help="CA-certifikat -> TLS")
    p.add_argument("--user", required=True)
    p.add_argument("--password", required=True)
    p.add_argument("--device", default="door-hoveddoer")
    p.add_argument("--card")
    p.add_argument("--pin")
    p.add_argument("--face", help="navn paa et falsk ansigt")
    p.add_argument("--enroll", type=int, metavar="USER_ID", help="send --face som tilmelding til bruger")
    p.add_argument("--listen", action="store_true", help="lyt efter kommandoer til doeren")
    p.add_argument("--timeout", type=float, default=5)
    a = p.parse_args()

    base = f"iot/door/{a.device}"
    request_id = uuid.uuid4().hex[:8]
    got_reply = threading.Event()

    try:
        client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION1, f"sim-{a.device}-{request_id}")
    except AttributeError:  # paho-mqtt 1.x
        client = mqtt.Client(f"sim-{a.device}-{request_id}")
    client.username_pw_set(a.user, a.password)
    if a.cafile:
        client.tls_set(ca_certs=a.cafile, tls_version=ssl.PROTOCOL_TLS_CLIENT)
    if a.listen:
        # Som en rigtig doer: broker melder "offline", hvis forbindelsen doer
        client.will_set(f"{base}/status", json.dumps({"online": False}), qos=1, retain=True)

    sent_at = [0.0]

    def on_connect(c, userdata, flags, rc, *args):
        if rc != 0:
            sys.exit(f"MQTT-login afvist (rc={rc})")
        c.subscribe(f"{base}/response", qos=1)
        c.subscribe(f"{base}/command", qos=1)
        if a.listen:
            c.publish(f"{base}/status", json.dumps({"online": True}), qos=1, retain=True)

        if a.enroll is not None:
            c.publish(f"{base}/enroll", json.dumps(
                {"user_id": a.enroll, "embedding": fake_embedding(a.face or "x")}), qos=1)
            print(f"Tilmelding sendt: ansigt '{a.face}' -> bruger {a.enroll}")
            got_reply.set()
        elif a.card:
            req = {"request_id": request_id, "card_uid": a.card}
            if a.face:
                req.update(method="face_rfid", embedding=fake_embedding(a.face))
            else:
                req.update(method="rfid_pin", pin=a.pin or "")
            sent_at[0] = time.monotonic()
            c.publish(f"{base}/request", json.dumps(req), qos=1)
            print(f"-> {a.device}: kort {a.card} via {req['method']}")

    def on_message(c, userdata, msg):
        data = json.loads(msg.payload)
        if msg.topic.endswith("/response") and data.get("request_id") == request_id:
            rtt = (time.monotonic() - sent_at[0]) * 1000
            if data["granted"]:
                print(f"<- AABN i {data['open_seconds']} s  ({data['user']})  [{rtt:.0f} ms rundtur]")
            else:
                print(f"<- AFVIST: {data['reason']}  [{rtt:.0f} ms rundtur]")
            got_reply.set()
        elif msg.topic.endswith("/command"):
            print(f"<- kommando: {data}")

    client.on_connect = on_connect
    client.on_message = on_message
    client.connect(a.host, a.port, keepalive=30)
    client.loop_start()
    try:
        if a.listen:
            print(f"Lytter paa {base}/command (Ctrl+C for at stoppe)")
            while True:
                time.sleep(1)
        elif not got_reply.wait(a.timeout):
            print("Intet svar - koerer lockdin-access? (sudo journalctl -u lockdin-access)")
            sys.exit(1)
        time.sleep(0.2)  # lad QoS1-beskeder blive sendt faerdigt
    except KeyboardInterrupt:
        if a.listen:
            client.publish(f"{base}/status", json.dumps({"online": False}), qos=1, retain=True).wait_for_publish()
    finally:
        client.loop_stop()
        client.disconnect()


if __name__ == "__main__":
    main()
