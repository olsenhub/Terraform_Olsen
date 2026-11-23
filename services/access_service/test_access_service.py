#!/usr/bin/env python3
"""
Tests af adgangs-servicen.

  python3 -m unittest -v test_access_service.py

Beslutningslogikken testes uden noget installeret. MQTT-rundturen kraever
paho-mqtt + en lokal `mosquitto` og springes ellers over. SQL'en mod MariaDB
testes ikke her - den koeres paa VM'en (se README.md).
"""

import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from datetime import datetime, timedelta

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import access_service as svc  # noqa: E402
from simulate_door import fake_embedding  # noqa: E402

NOW = datetime(2026, 11, 23, 14, 0)
SETTINGS = svc.Settings()


def user(**kw):
    u = dict(id=1, name="Mette Hansen", is_active=True, valid_from=None,
             valid_until=None, locked_until=None, pin_hash="hash",
             face_opt_out=False, failed_pin_attempts=0)
    u.update(kw)
    return u


def pin_ok(pin, pin_hash):
    return pin == "1234"


def face_req(name="mette"):
    return {"method": "face_rfid", "embedding": fake_embedding(name)}


def pin_req(pin="1234"):
    return {"method": "rfid_pin", "pin": pin}


METTE_FACE = [tuple(fake_embedding("mette"))]


class DecideTest(unittest.TestCase):
    def decide(self, request, u=None, perm=True, faces=METTE_FACE):
        return svc.decide(request, u, perm, faces, SETTINGS, NOW, pin_checker=pin_ok)

    def test_face_and_permission_grants(self):
        d = self.decide(face_req(), user())
        self.assertTrue(d.granted)
        self.assertIsNone(d.reason)

    def test_demo_receptionist_denied_at_economy(self):
        d = self.decide(face_req(), user(), perm=False)
        self.assertFalse(d.granted)
        self.assertEqual(d.reason, svc.NO_PERMISSION)

    def test_unknown_card(self):
        self.assertEqual(self.decide(pin_req(), None).reason, svc.UNKNOWN_CARD)

    def test_wrong_face(self):
        self.assertEqual(self.decide(face_req("fremmed"), user()).reason, svc.FACE_MISMATCH)

    def test_face_opt_out_must_use_pin(self):
        self.assertEqual(self.decide(face_req(), user(face_opt_out=True)).reason, svc.FACE_OPT_OUT)
        self.assertTrue(self.decide(pin_req(), user(face_opt_out=True)).granted)

    def test_no_face_enrolled(self):
        self.assertEqual(self.decide(face_req(), user(), faces=[]).reason, svc.NO_FACE_ENROLLED)

    def test_wrong_pin_counts_as_failed(self):
        d = self.decide(pin_req("0000"), user())
        self.assertEqual(d.reason, svc.WRONG_PIN)
        self.assertTrue(d.failed_pin)

    def test_correct_pin_resets_counter(self):
        d = self.decide(pin_req(), user(failed_pin_attempts=2))
        self.assertTrue(d.granted)
        self.assertTrue(d.reset_pin_attempts)

    def test_no_pin_set(self):
        self.assertEqual(self.decide(pin_req(), user(pin_hash=None)).reason, svc.NO_PIN)

    def test_locked_account(self):
        d = self.decide(pin_req(), user(locked_until=NOW + timedelta(minutes=3)))
        self.assertEqual(d.reason, svc.LOCKED)
        self.assertFalse(d.failed_pin)  # laast konto taeller ikke yderligere op

    def test_lock_expired(self):
        self.assertTrue(self.decide(pin_req(), user(locked_until=NOW - timedelta(minutes=1))).granted)

    def test_inactive_user(self):
        self.assertEqual(self.decide(pin_req(), user(is_active=False)).reason, svc.INACTIVE)

    def test_temporary_card_expired(self):
        d = self.decide(pin_req(), user(valid_until=NOW - timedelta(hours=1)))
        self.assertEqual(d.reason, svc.EXPIRED)

    def test_not_yet_valid(self):
        d = self.decide(pin_req(), user(valid_from=NOW + timedelta(days=1)))
        self.assertEqual(d.reason, svc.EXPIRED)

    def test_credentials_checked_before_permission(self):
        # Forkert PIN paa en doer uden adgang skal svare wrong_pin, ikke
        # no_permission - ellers afsloeres rettigheder foer ejeren er bevist
        self.assertEqual(self.decide(pin_req("0000"), user(), perm=False).reason, svc.WRONG_PIN)

    def test_bad_requests(self):
        self.assertEqual(self.decide({}, user()).reason, svc.BAD_REQUEST)
        self.assertEqual(self.decide({"method": "face_rfid", "embedding": [1, 2]}, user()).reason,
                         svc.BAD_REQUEST)
        self.assertEqual(self.decide({"method": "face_rfid", "embedding": "x" * 128}, user()).reason,
                         svc.BAD_REQUEST)


class HelpersTest(unittest.TestCase):
    def test_embedding_roundtrip(self):
        e = fake_embedding("mette")
        back = svc.unpack_embedding(svc.pack_embedding(e))
        self.assertEqual(len(back), 128)
        self.assertLess(svc.face_distance(e, back), 1e-5)

    def test_fake_faces_are_far_apart(self):
        self.assertGreater(svc.face_distance(fake_embedding("a"), fake_embedding("b")),
                           SETTINGS.face_threshold)

    def test_parse_topic(self):
        self.assertEqual(svc.parse_topic("iot/door/door-oekonomi/request"), ("door-oekonomi", "request"))
        self.assertEqual(svc.parse_topic("iot/other/x/request"), (None, None))
        self.assertEqual(svc.parse_topic("iot/door/x/y/z"), (None, None))

    def test_php_bcrypt_hash(self):
        try:
            import bcrypt
        except ImportError:
            self.skipTest("bcrypt ikke installeret")
        # Som PHP's password_hash('1234', PASSWORD_BCRYPT) - med $2y$-praefiks
        php_hash = "$2y$" + bcrypt.hashpw(b"1234", bcrypt.gensalt(4)).decode()[4:]
        self.assertTrue(svc.check_pin("1234", php_hash))
        self.assertFalse(svc.check_pin("0000", php_hash))
        self.assertFalse(svc.check_pin("1234", "ikke-en-hash"))


# ---------------------------------------------------------------------------
# MQTT-rundtur: rigtig broker + service + simulator, falsk database
# ---------------------------------------------------------------------------

class FakeRepo:
    def __init__(self):
        self.doors = {"door-hoveddoer": dict(id=1, name="Hoveddoer", is_active=True),
                      "door-oekonomi": dict(id=4, name="Oekonomiafdeling", is_active=True)}
        self.users = {"04:A3:2F:1B": user(id=1, pin_hash=None)}   # receptionist
        self.access = {(1, "door-hoveddoer")}
        self.face_store = {1: []}
        self.log = []
        self.commands = []
        self.seen = {}

    def door(self, device_id): return self.doors.get(device_id)
    def user_by_card(self, card): return self.users.get(card)
    def has_permission(self, uid, dev): return (uid, dev) in self.access
    def faces(self, uid): return self.face_store.get(uid, [])
    def add_face(self, uid, emb): self.face_store.setdefault(uid, []).append(tuple(emb))
    def register_failed_pin(self, uid, s): pass
    def reset_pin_attempts(self, uid): pass
    def log_attempt(self, *a, **kw): self.log.append((a, kw))
    def door_seen(self, dev, online): self.seen[dev] = online
    def pending_commands(self):
        cmds, self.commands = self.commands, []
        return cmds
    def finish_command(self, cid, result): pass


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@unittest.skipUnless(shutil.which("mosquitto"), "mosquitto ikke installeret")
class MqttRoundTripTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            import paho.mqtt.client  # noqa: F401
        except ImportError:
            raise unittest.SkipTest("paho-mqtt ikke installeret")
        cls.tmp = tempfile.mkdtemp()
        cls.port = free_port()
        passwd = os.path.join(cls.tmp, "passwd")
        subprocess.run(["mosquitto_passwd", "-c", "-b", passwd, "iot_device", "devpass"], check=True)
        subprocess.run(["mosquitto_passwd", "-b", passwd, "access_service", "svcpass"], check=True)
        # Samme ACL som access_service.tf ruller ud
        acl = os.path.join(cls.tmp, "acl")
        with open(acl, "w") as f:
            f.write("user iot_device\n"
                    "topic write iot/door/+/request\ntopic write iot/door/+/status\n"
                    "topic write iot/door/+/enroll\ntopic read iot/door/+/response\n"
                    "topic read iot/door/+/command\n\n"
                    "user access_service\ntopic readwrite iot/door/#\n")
        conf = os.path.join(cls.tmp, "mosquitto.conf")
        with open(conf, "w") as f:
            f.write(f"listener {cls.port} 127.0.0.1\nallow_anonymous false\n"
                    f"password_file {passwd}\nacl_file {acl}\npersistence false\n")
        cls.broker = subprocess.Popen(["mosquitto", "-c", conf],
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.5)

        cls.repo = FakeRepo()
        client = svc.make_client("test-service")
        client.username_pw_set("access_service", "svcpass")
        cls.service = svc.AccessService(cls.repo, client, SETTINGS)
        client.on_connect = cls.service.on_connect
        client.on_message = cls.service.on_message
        connected = threading.Event()
        client.on_subscribe = lambda *a: connected.set()
        client.connect("127.0.0.1", cls.port)
        client.loop_start()
        cls.client = client
        assert connected.wait(5), "servicen kom ikke paa brokeren"
        time.sleep(0.3)

    @classmethod
    def tearDownClass(cls):
        cls.client.loop_stop()
        cls.client.disconnect()
        cls.broker.terminate()
        cls.broker.wait()
        shutil.rmtree(cls.tmp)

    def door(self, *args):
        here = os.path.dirname(os.path.abspath(__file__))
        r = subprocess.run([sys.executable, os.path.join(here, "simulate_door.py"),
                            "--port", str(self.port), "--user", "iot_device",
                            "--password", "devpass", *args],
                           capture_output=True, text=True, timeout=15)
        return r.stdout + r.stderr

    def test_demo_flow(self):
        # 1) Tilmeld receptionistens ansigt via hoveddoeren
        self.door("--device", "door-hoveddoer", "--enroll", "1", "--face", "mette")
        for _ in range(20):
            if self.repo.face_store[1]:
                break
            time.sleep(0.1)
        self.assertEqual(len(self.repo.face_store[1]), 1)

        # 2) Hoveddoer: godkendt
        out = self.door("--device", "door-hoveddoer", "--card", "04:A3:2F:1B", "--face", "mette")
        self.assertIn("AABN", out)

        # 3) Oekonomiafdeling: afvist pga. rolle
        out = self.door("--device", "door-oekonomi", "--card", "04:A3:2F:1B", "--face", "mette")
        self.assertIn("AFVIST: no_permission", out)

        # 4) Fremmed ansigt paa receptionistens kort
        out = self.door("--device", "door-hoveddoer", "--card", "04:A3:2F:1B", "--face", "tyv")
        self.assertIn("AFVIST: face_mismatch", out)

        # 5) Ukendt doer
        out = self.door("--device", "door-findes-ikke", "--card", "04:A3:2F:1B", "--pin", "1")
        self.assertIn("AFVIST: unknown_door", out)

        granted = [a[4] for a, kw in self.repo.log]
        reasons = [a[5] for a, kw in self.repo.log]
        self.assertEqual(granted, [True, False, False])
        self.assertEqual(reasons, [None, "no_permission", "face_mismatch"])

    def test_remote_open_reaches_door(self):
        listener = subprocess.Popen(
            # -u: ellers ligger outputtet i bufferen, naar processen stoppes
            [sys.executable, "-u", os.path.join(os.path.dirname(os.path.abspath(__file__)), "simulate_door.py"),
             "--port", str(self.port), "--user", "iot_device", "--password", "devpass",
             "--device", "door-hoveddoer", "--listen"],
            stdout=subprocess.PIPE, text=True)
        try:
            time.sleep(1)
            self.assertTrue(self.repo.seen.get("door-hoveddoer"))
            self.repo.commands.append(dict(id=7, action="open", user_id=None, requested_by="it-admin",
                                           reason="Glemt kort", door_id=1, device_id="door-hoveddoer"))
            self.service.process_commands()
            time.sleep(1)
        finally:
            listener.terminate()
            out = listener.communicate(timeout=5)[0]
        self.assertIn("'action': 'open'", out)
        support = [kw for a, kw in self.repo.log if a[3] == "support"]
        self.assertEqual(support[-1]["support_operator"], "it-admin")
        self.assertEqual(support[-1]["note"], "Glemt kort")

    def test_door_cannot_fake_a_response(self):
        # ACL: doer-brugeren maa ikke publicere paa .../response
        import paho.mqtt.client as mqtt
        got = threading.Event()
        spy = svc.make_client("spy")
        spy.username_pw_set("access_service", "svcpass")
        spy.on_message = lambda *a: got.set()
        spy.connect("127.0.0.1", self.port)
        spy.subscribe("iot/door/+/response")
        spy.loop_start()
        evil = svc.make_client("evil")
        evil.username_pw_set("iot_device", "devpass")
        evil.connect("127.0.0.1", self.port)
        evil.loop_start()
        time.sleep(0.3)
        evil.publish("iot/door/door-oekonomi/response", '{"granted": true}', qos=1)
        try:
            self.assertFalse(got.wait(1.0), "broker videresendte et falsk svar")
        finally:
            for c in (spy, evil):
                c.loop_stop()
                c.disconnect()


if __name__ == "__main__":
    unittest.main()
