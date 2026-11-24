#!/usr/bin/env python3
"""
LockdIn face-enroll-worker

Laver ansigtsbilleder, som admin-panelet har uploadet, om til embeddings.
Koerer som systemd-servicen `lockdin-face-enroll` paa VM'en.

  admin-panel --(fil + face_images 'pending')--> worker --> user_faces
                                                         +-> billedet slettes

Samme model og kode som adgangs-servicen (encode_faces, face_recognition / dlib), saa
en upload og et billede fra doerens kamera giver sammenlignelige embeddings
(afstand <= FACE_THRESHOLD).

Et billede skal indeholde praecis et ansigt - ved flere ved vi ikke, hvem
der er brugeren, og billedet afvises (multiple_faces).
"""

import logging
import os
import signal
import sys
import threading

sys.path.insert(0, os.environ.get("ACCESS_SERVICE_DIR", os.path.dirname(os.path.abspath(__file__))))
from access_service import Repository, encode_faces, pack_embedding  # noqa: E402

log = logging.getLogger("face-enroll")

OK = "ok"
NO_FACE = "no_face"
MULTIPLE_FACES = "multiple_faces"
ERROR = "error"


def encode_image(path):
    """Returnerer listen af embeddings (en pr. ansigt) i billedet. Samme
    funktion som adgangs-servicen bruger paa billeder fra doerene."""
    with open(path, "rb") as f:
        return encode_faces(f.read())


def classify(encodings):
    """(status, embedding eller None) ud fra antal fundne ansigter."""
    if not encodings:
        return NO_FACE, None
    if len(encodings) > 1:
        return MULTIPLE_FACES, None
    return OK, [float(v) for v in encodings[0]]


class FaceRepository(Repository):
    def pending_images(self, limit=20):
        return self._query(
            "SELECT id, user_id, file_name FROM face_images"
            " WHERE status = 'pending' ORDER BY id LIMIT %s", (limit,))

    def finish_image(self, image_id, user_id, status, embedding):
        # Embedding og status i samme transaktion, saa et billede aldrig
        # giver to embeddings, hvis workeren genstarter midt i
        with self._lock:
            conn = self._db()
            conn.begin()
            try:
                with conn.cursor() as cur:
                    if embedding is not None:
                        cur.execute("INSERT INTO user_faces (user_id, embedding) VALUES (%s, %s)",
                                    (user_id, pack_embedding(embedding)))
                    cur.execute("UPDATE face_images SET status = %s, processed_at = NOW()"
                                " WHERE id = %s", (status, image_id))
                conn.commit()
            except Exception:
                conn.rollback()
                raise


class FaceEnrollWorker:
    def __init__(self, repo, upload_dir, encoder=encode_image, interval=2.0):
        self.repo = repo
        self.upload_dir = upload_dir
        self.encoder = encoder
        self.interval = interval
        self._stop = threading.Event()

    def process(self, image):
        # basename: et filnavn fra DB'en kan aldrig pege uden for mappen
        path = os.path.join(self.upload_dir, os.path.basename(image["file_name"]))
        try:
            status, embedding = classify(self.encoder(path))
        except Exception as e:   # manglende/korrupt fil
            log.warning("Billede %s kunne ikke laeses: %s", image["id"], e)
            status, embedding = ERROR, None
        self.repo.finish_image(image["id"], image["user_id"], status, embedding)
        try:
            os.remove(path)      # kun embeddingen gemmes (GDPR)
        except FileNotFoundError:
            pass
        log.info("Billede %s (bruger %s): %s", image["id"], image["user_id"], status)
        return status

    def run_once(self):
        images = self.repo.pending_images()
        for image in images:
            self.process(image)
        return len(images)

    def run(self):
        while not self._stop.is_set():
            try:
                if self.run_once():
                    continue        # flere i koeen - ingen pause
            except Exception:
                log.exception("Fejl i face-enroll-loop")
            self._stop.wait(self.interval)

    def stop(self):
        self._stop.set()


def main():
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"),
                        format="%(asctime)s %(levelname)s %(message)s")
    env = os.environ
    repo = FaceRepository(host=env.get("DB_HOST", "localhost"), port=int(env.get("DB_PORT", 3306)),
                          user=env["DB_USER"], password=env["DB_PASSWORD"], database=env["DB_NAME"])
    worker = FaceEnrollWorker(repo, env.get("FACE_UPLOAD_DIR", "/var/lib/lockdin-faces"))
    signal.signal(signal.SIGTERM, lambda *_: worker.stop())
    log.info("Face-enroll-worker startet")
    worker.run()


if __name__ == "__main__":
    main()
