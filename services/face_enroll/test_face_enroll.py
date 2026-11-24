#!/usr/bin/env python3
"""
Tests af face-enroll-workeren.

  python3 -m unittest -v test_face_enroll.py

Workerens flow testes med en falsk encoder og et falsk repository, saa der
ikke skal vaere noget installeret. Den rigtige encoder (face_recognition +
dlib) testes kun, hvis pakken findes, og kun paa et billede uden ansigt.
"""

import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "access_service"))
import face_enroll as fe  # noqa: E402


class FakeRepo:
    def __init__(self, images):
        self.images = images
        self.finished = []

    def pending_images(self, limit=20):
        done = {f[0] for f in self.finished}
        return [i for i in self.images if i["id"] not in done][:limit]

    def finish_image(self, image_id, user_id, status, embedding):
        self.finished.append((image_id, user_id, status, embedding))


class ClassifyTest(unittest.TestCase):
    def test_no_face(self):
        self.assertEqual(fe.classify([]), (fe.NO_FACE, None))

    def test_one_face(self):
        status, emb = fe.classify([[0.1] * 128])
        self.assertEqual(status, fe.OK)
        self.assertEqual(len(emb), 128)

    def test_multiple_faces(self):
        self.assertEqual(fe.classify([[0.1] * 128, [0.2] * 128]), (fe.MULTIPLE_FACES, None))


class WorkerTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()

    def make_file(self, name):
        with open(os.path.join(self.dir, name), "wb") as f:
            f.write(b"x")

    def test_processes_and_deletes_images(self):
        faces = {"a.jpg": [[0.5] * 128], "b.jpg": [], "c.jpg": [[0.1] * 128, [0.2] * 128]}
        for name in faces:
            self.make_file(name)
        repo = FakeRepo([{"id": i, "user_id": 7, "file_name": n} for i, n in enumerate(faces, 1)])
        worker = fe.FaceEnrollWorker(repo, self.dir, encoder=lambda p: faces[os.path.basename(p)])

        self.assertEqual(worker.run_once(), 3)
        self.assertEqual([(f[0], f[2]) for f in repo.finished],
                         [(1, fe.OK), (2, fe.NO_FACE), (3, fe.MULTIPLE_FACES)])
        self.assertEqual(repo.finished[0][3], [0.5] * 128)
        self.assertIsNone(repo.finished[1][3])
        self.assertEqual(os.listdir(self.dir), [])      # billederne er slettet
        self.assertEqual(worker.run_once(), 0)

    def test_unreadable_image_is_error(self):
        def broken(path):
            raise OSError("cannot identify image file")
        repo = FakeRepo([{"id": 1, "user_id": 7, "file_name": "mangler.jpg"}])
        fe.FaceEnrollWorker(repo, self.dir, encoder=broken).run_once()
        self.assertEqual(repo.finished, [(1, 7, fe.ERROR, None)])

    def test_file_name_cannot_escape_upload_dir(self):
        seen = []
        repo = FakeRepo([{"id": 1, "user_id": 7, "file_name": "../../etc/passwd"}])
        fe.FaceEnrollWorker(repo, self.dir, encoder=lambda p: seen.append(p) or []).run_once()
        self.assertEqual(seen, [os.path.join(self.dir, "passwd")])


try:
    import face_recognition  # noqa: F401
    from PIL import Image
except ImportError:
    face_recognition = None


@unittest.skipIf(face_recognition is None, "face_recognition er ikke installeret")
class RealEncoderTest(unittest.TestCase):
    def test_blank_image_has_no_face(self):
        with tempfile.NamedTemporaryFile(suffix=".jpg") as f:
            Image.new("RGB", (4000, 3000), (200, 180, 160)).save(f, "JPEG")
            self.assertEqual(fe.encode_image(f.name), [])


if __name__ == "__main__":
    unittest.main()
