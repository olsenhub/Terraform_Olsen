#!/usr/bin/env python3
"""
LockdIn adgangs-service

Bindeleddet mellem doer-enhederne (Raspberry Pi) og adgangskontrol-databasen.
Koerer som systemd-service paa VM'en og taler med Mosquitto paa den lokale
listener (127.0.0.1:1883) - doerene selv forbinder over TLS paa 8883.

MQTT-emner (<device_id> = doors.device_id, fx door-hoveddoer):
  iot/door/<device_id>/request   Pi -> service   adgangsanmodning
  iot/door/<device_id>/response  service -> Pi   aabn / afvis
  iot/door/<device_id>/status    Pi -> service   heartbeat (retained + LWT)
  iot/door/<device_id>/command   service -> Pi   fjernaabning / ansigts-tilmelding
  iot/door/<device_id>/enroll    Pi -> service   ansigts-embedding til en bruger

Request (JSON):
  {"request_id": "abc", "card_uid": "04:A3:2F:1B",
   "method": "face_rfid", "embedding": [128 floats]}      # primaer
  {"request_id": "abc", "card_uid": "04:A3:2F:1B",
   "method": "rfid_pin", "pin": "1234"}                    # alternativ

Response (JSON):
  {"request_id": "abc", "granted": true, "reason": null,
   "user": "Mette Hansen", "open_seconds": 5}

Fjernsupport: admin-siden indsaetter en raekke i door_commands. Servicen
poller tabellen, sender kommandoen til doeren og logger aabningen i
access_log med method='support'.
"""

import json
import logging
import math
import os
import signal
import struct
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timedelta

log = logging.getLogger("access-service")

TOPIC_PREFIX = "iot/door"
EMBEDDING_DIM = 128            # face_recognition / dlib giver 128 floats
EMBEDDING_FMT = f"<{EMBEDDING_DIM}f"

# Afvisningsaarsager - samme koder som access_log.reason i database.tf
UNKNOWN_CARD = "unknown_card"
INACTIVE = "inactive"
EXPIRED = "expired"
LOCKED = "locked"
NO_PERMISSION = "no_permission"
FACE_MISMATCH = "face_mismatch"
FACE_OPT_OUT = "face_opt_out"        # brugeren har fravalgt ansigt -> brug PIN
NO_FACE_ENROLLED = "no_face_enrolled"
NO_PIN = "no_pin"
WRONG_PIN = "wrong_pin"
BAD_REQUEST = "bad_request"


@dataclass
class Settings:
    face_threshold: float = 0.6       # face_recognitions standard-tolerance
    max_pin_attempts: int = 3
    lockout_minutes: int = 5
    open_seconds: int = 5


@dataclass
class Decision:
    granted: bool
    reason: str | None = None
    user_id: int | None = None
    user_name: str | None = None
    reset_pin_attempts: bool = False
    failed_pin: bool = False


# ---------------------------------------------------------------------------
# Ren beslutningslogik (ingen DB/MQTT) - det er den, testene rammer
# ---------------------------------------------------------------------------

def pack_embedding(values):
    if len(values) != EMBEDDING_DIM:
        raise ValueError(f"embedding skal have {EMBEDDING_DIM} vaerdier")
    return struct.pack(EMBEDDING_FMT, *(float(v) for v in values))


def unpack_embedding(blob):
    return struct.unpack(EMBEDDING_FMT, blob)


def face_distance(a, b):
    return math.sqrt(sum((x - y) ** 2 for x, y in zip(a, b)))


def check_pin(pin, pin_hash):
    """bcrypt-check. PHP's password_hash() giver $2y$, som er samme
    algoritme som $2b$ - python-bcrypt vil have $2b$."""
    import bcrypt
    if pin_hash.startswith("$2y$"):
        pin_hash = "$2b$" + pin_hash[4:]
    try:
        return bcrypt.checkpw(pin.encode(), pin_hash.encode())
    except ValueError:
        return False


def decide(request, user, has_permission, faces, settings, now, pin_checker=check_pin):
    """Afgoer en adgangsanmodning.

    request:        dict fra Pi'en (method, pin / embedding)
    user:           raekke fra users (dict) eller None hvis kortet er ukendt
    has_permission: om brugerens rolle maa aabne doeren lige nu (v_current_access)
    faces:          brugerens gemte embeddings (liste af tuples)

    Legitimationen (ansigt/PIN) tjekkes FOER rettigheden, saa en afvisning
    ikke afsloerer, om et kort har adgang til en doer, foer ejeren er bevist.
    """
    method = request.get("method")
    if method not in ("face_rfid", "rfid_pin"):
        return Decision(False, BAD_REQUEST)
    if user is None:
        return Decision(False, UNKNOWN_CARD)

    d = Decision(False, user_id=user["id"], user_name=user["name"])

    if not user["is_active"]:
        d.reason = INACTIVE
        return d
    if (user["valid_from"] and user["valid_from"] > now) or \
       (user["valid_until"] and user["valid_until"] <= now):
        d.reason = EXPIRED
        return d
    if user["locked_until"] and user["locked_until"] > now:
        d.reason = LOCKED
        return d

    if method == "face_rfid":
        if user["face_opt_out"]:
            d.reason = FACE_OPT_OUT
            return d
        if not faces:
            d.reason = NO_FACE_ENROLLED
            return d
        try:
            probe = [float(v) for v in request.get("embedding") or []]
        except (TypeError, ValueError):
            probe = []
        if len(probe) != EMBEDDING_DIM:
            d.reason = BAD_REQUEST
            return d
        best = min(face_distance(probe, f) for f in faces)
        if best > settings.face_threshold:
            d.reason = FACE_MISMATCH
            return d
    else:
        if not user["pin_hash"]:
            d.reason = NO_PIN
            return d
        pin = str(request.get("pin") or "")
        if not pin_checker(pin, user["pin_hash"]):
            d.reason = WRONG_PIN
            d.failed_pin = True
            return d
        d.reset_pin_attempts = user["failed_pin_attempts"] > 0

    if not has_permission:
        d.reason = NO_PERMISSION
        return d

    d.granted = True
    return d


def parse_topic(topic):
    """iot/door/<device_id>/<kind> -> (device_id, kind) eller (None, None)"""
    parts = topic.split("/")
    if len(parts) != 4 or "/".join(parts[:2]) != TOPIC_PREFIX:
        return None, None
    return parts[2], parts[3]


# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

class Repository:
    def __init__(self, **conn_args):
        self._conn_args = conn_args
        self._conn = None
        self._lock = threading.Lock()   # MQTT-traad og command-poller deler forbindelsen

    def _db(self):
        import pymysql
        if self._conn is None or not self._conn.open:
            self._conn = pymysql.connect(
                cursorclass=pymysql.cursors.DictCursor, autocommit=True,
                charset="utf8mb4", **self._conn_args)
        else:
            self._conn.ping(reconnect=True)
        return self._conn

    def _query(self, sql, args=(), one=False):
        with self._lock:
            with self._db().cursor() as cur:
                cur.execute(sql, args)
                return cur.fetchone() if one else cur.fetchall()

    def _execute(self, sql, args=()):
        with self._lock:
            with self._db().cursor() as cur:
                cur.execute(sql, args)
                return cur.lastrowid

    def door(self, device_id):
        return self._query(
            "SELECT id, name, is_active FROM doors WHERE device_id = %s",
            (device_id,), one=True)

    def user_by_card(self, card_uid):
        return self._query(
            "SELECT id, name, is_active, valid_from, valid_until, locked_until,"
            " pin_hash, face_opt_out, failed_pin_attempts"
            " FROM users WHERE card_uid = %s", (card_uid,), one=True)

    def has_permission(self, user_id, device_id):
        return self._query(
            "SELECT 1 FROM v_current_access WHERE user_id = %s AND device_id = %s",
            (user_id, device_id), one=True) is not None

    def faces(self, user_id):
        rows = self._query("SELECT embedding FROM user_faces WHERE user_id = %s", (user_id,))
        return [unpack_embedding(r["embedding"]) for r in rows]

    def add_face(self, user_id, embedding):
        self._execute("INSERT INTO user_faces (user_id, embedding) VALUES (%s, %s)",
                      (user_id, pack_embedding(embedding)))

    def register_failed_pin(self, user_id, settings):
        # Atomisk: taeller op og laaser kontoen ved max forsoeg
        self._execute(
            "UPDATE users SET failed_pin_attempts = failed_pin_attempts + 1,"
            " locked_until = IF(failed_pin_attempts >= %s,"
            "   NOW() + INTERVAL %s MINUTE, locked_until)"
            " WHERE id = %s",
            (settings.max_pin_attempts, settings.lockout_minutes, user_id))
        # (MariaDB evaluerer SET fra venstre, saa failed_pin_attempts er allerede +1)

    def reset_pin_attempts(self, user_id):
        self._execute("UPDATE users SET failed_pin_attempts = 0, locked_until = NULL"
                      " WHERE id = %s", (user_id,))

    def log_attempt(self, door_id, user_id, card_uid, method, granted, reason,
                    response_ms=None, support_operator=None, note=None):
        self._execute(
            "INSERT INTO access_log (door_id, user_id, card_uid, method, granted,"
            " reason, support_operator, note, response_ms)"
            " VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s)",
            (door_id, user_id, card_uid, method, granted, reason,
             support_operator, note, response_ms))

    def door_seen(self, device_id, online):
        self._execute("UPDATE doors SET last_seen = NOW(), is_online = %s"
                      " WHERE device_id = %s", (online, device_id))

    def pending_commands(self):
        return self._query(
            "SELECT c.id, c.action, c.user_id, c.requested_by, c.reason,"
            " d.id AS door_id, d.device_id"
            " FROM door_commands c JOIN doors d ON d.id = c.door_id"
            " WHERE c.processed_at IS NULL ORDER BY c.id")

    def finish_command(self, command_id, result):
        self._execute("UPDATE door_commands SET processed_at = NOW(), result = %s"
                      " WHERE id = %s", (result, command_id))


# ---------------------------------------------------------------------------
# MQTT-service
# ---------------------------------------------------------------------------

class AccessService:
    def __init__(self, repo, client, settings):
        self.repo = repo
        self.client = client
        self.settings = settings
        self._stop = threading.Event()

    # --- MQTT callbacks ---
    def on_connect(self, client, userdata, flags, rc, *args):
        if rc != 0:
            log.error("MQTT-forbindelse afvist (rc=%s)", rc)
            return
        log.info("Forbundet til MQTT-broker")
        for kind in ("request", "status", "enroll"):
            client.subscribe(f"{TOPIC_PREFIX}/+/{kind}", qos=1)

    def on_message(self, client, userdata, msg):
        device_id, kind = parse_topic(msg.topic)
        if device_id is None:
            return
        try:
            payload = json.loads(msg.payload.decode() or "{}")
            if not isinstance(payload, dict):
                raise ValueError("payload er ikke et JSON-objekt")
        except (ValueError, UnicodeDecodeError) as e:
            log.warning("Ugyldig besked paa %s: %s", msg.topic, e)
            payload = None
        try:
            if kind == "request":
                self.handle_request(device_id, payload)
            elif kind == "status" and payload is not None:
                self.repo.door_seen(device_id, bool(payload.get("online", True)))
            elif kind == "enroll" and payload is not None:
                self.handle_enroll(device_id, payload)
        except Exception:
            # En fejl i en enkelt besked (fx DB nede) maa ikke draebe servicen
            log.exception("Fejl ved behandling af %s", msg.topic)

    # --- Adgangsanmodning ---
    def handle_request(self, device_id, request):
        started = time.monotonic()
        request = request or {}
        reply = {"request_id": request.get("request_id")}

        door = self.repo.door(device_id)
        if door is None or not door["is_active"]:
            # door_id er NOT NULL i access_log, saa ukendte doere kan ikke logges der
            log.warning("Anmodning fra ukendt/inaktiv doer %s", device_id)
            self.publish(device_id, "response", {**reply, "granted": False, "reason": "unknown_door"})
            return

        card_uid = str(request.get("card_uid") or "").strip().upper() or None
        user = self.repo.user_by_card(card_uid) if card_uid else None
        has_perm = bool(user) and self.repo.has_permission(user["id"], device_id)
        faces = self.repo.faces(user["id"]) if user and request.get("method") == "face_rfid" else []

        d = decide(request, user, has_perm, faces, self.settings, datetime.now())

        if d.failed_pin:
            self.repo.register_failed_pin(d.user_id, self.settings)
        elif d.reset_pin_attempts:
            self.repo.reset_pin_attempts(d.user_id)

        response_ms = int((time.monotonic() - started) * 1000)
        method = request.get("method") if request.get("method") in ("face_rfid", "rfid_pin") else "unknown"
        self.repo.log_attempt(door["id"], d.user_id, card_uid, method,
                              d.granted, d.reason, response_ms)

        self.publish(device_id, "response", {
            **reply, "granted": d.granted, "reason": d.reason,
            "user": d.user_name if d.granted else None,
            "open_seconds": self.settings.open_seconds if d.granted else 0,
        })
        log.info("%s %s kort=%s bruger=%s aarsag=%s (%d ms)", device_id,
                 "GODKENDT" if d.granted else "AFVIST", card_uid, d.user_name,
                 d.reason, response_ms)

    # --- Ansigts-tilmelding: Pi sender embedding efter en enroll_face-kommando ---
    def handle_enroll(self, device_id, payload):
        user_id = payload.get("user_id")
        try:
            self.repo.add_face(int(user_id), payload.get("embedding") or [])
            log.info("Ansigt tilmeldt for bruger %s via %s", user_id, device_id)
        except (TypeError, ValueError) as e:
            log.warning("Ugyldig enroll fra %s: %s", device_id, e)

    # --- Kommandoer fra admin-siden (door_commands) ---
    def process_commands(self):
        for cmd in self.repo.pending_commands():
            # Markeres FOERST: fejler resten, aabnes doeren hellere 0 end 2 gange
            self.repo.finish_command(cmd["id"], "sent")
            if cmd["action"] == "open":
                self.publish(cmd["device_id"], "command", {
                    "action": "open", "open_seconds": self.settings.open_seconds})
                self.repo.log_attempt(cmd["door_id"], cmd["user_id"], None, "support",
                                      True, None, support_operator=cmd["requested_by"],
                                      note=cmd["reason"])
                log.info("Fjernaabning af %s af %s", cmd["device_id"], cmd["requested_by"])
            elif cmd["action"] == "enroll_face":
                self.publish(cmd["device_id"], "command", {
                    "action": "enroll_face", "user_id": cmd["user_id"]})

    def command_loop(self, interval=1.0):
        while not self._stop.wait(interval):
            try:
                self.process_commands()
            except Exception:
                log.exception("Fejl i command-poller")

    def publish(self, device_id, kind, payload):
        self.client.publish(f"{TOPIC_PREFIX}/{device_id}/{kind}", json.dumps(payload), qos=1)

    def stop(self):
        self._stop.set()


def make_client(client_id):
    import paho.mqtt.client as mqtt
    try:
        return mqtt.Client(mqtt.CallbackAPIVersion.VERSION1, client_id)
    except AttributeError:  # paho-mqtt 1.x (Ubuntu 22.04)
        return mqtt.Client(client_id)


def main():
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"),
                        format="%(asctime)s %(levelname)s %(message)s")
    env = os.environ
    settings = Settings(
        face_threshold=float(env.get("FACE_THRESHOLD", 0.6)),
        max_pin_attempts=int(env.get("MAX_PIN_ATTEMPTS", 3)),
        lockout_minutes=int(env.get("LOCKOUT_MINUTES", 5)),
        open_seconds=int(env.get("OPEN_SECONDS", 5)),
    )
    repo = Repository(host=env.get("DB_HOST", "localhost"), user=env["DB_USER"],
                      password=env["DB_PASSWORD"], database=env["DB_NAME"])

    client = make_client("lockdin-access-service")
    client.username_pw_set(env["MQTT_USER"], env["MQTT_PASSWORD"])
    service = AccessService(repo, client, settings)
    client.on_connect = service.on_connect
    client.on_message = service.on_message

    threading.Thread(target=service.command_loop, daemon=True).start()

    def shutdown(*_):
        service.stop()
        client.disconnect()
    signal.signal(signal.SIGTERM, shutdown)

    client.connect(env.get("MQTT_HOST", "127.0.0.1"), int(env.get("MQTT_PORT", 1883)), keepalive=30)
    client.loop_forever(retry_first_connection=True)


if __name__ == "__main__":
    main()
