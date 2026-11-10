import datetime
import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dump import KEEP_PER_DATABASE, SUFFIX, dump_database, import_recipient, object_key, prune  # noqa: E402

PINNED_FINGERPRINT = "1EB066F3C8C3F147DABC028DD009DE9C37E1B21D"
BUCKET = "bucket"
DATABASE = "paperless"
EXTRA_DUMPS = 3
MORNING = datetime.datetime(2026, 11, 10, 3, 30, tzinfo=datetime.UTC)
RERUN = datetime.datetime(2026, 11, 10, 9, 15, 42, tzinfo=datetime.UTC)


class FakeS3:
    def __init__(self, keys=(), fail_upload=False, locked=False):
        self.objects = {key: b"" for key in keys}
        self.fail_upload = fail_upload
        self.locked = locked

    def upload_fileobj(self, stream, bucket, key):
        if self.fail_upload:
            stream.read(1)
            raise ConnectionError("upload refused")
        self.objects[key] = stream.read()

    def delete_object(self, Bucket, Key):
        if self.locked:
            raise PermissionError("object is locked")
        self.objects.pop(Key, None)

    def list_objects_v2(self, Bucket, Prefix):
        return {"Contents": [{"Key": key} for key in sorted(self.objects) if key.startswith(Prefix)]}


class DumpTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.home = tempfile.TemporaryDirectory()
        cls.secret_home = os.path.join(cls.home.name, "secret")
        os.makedirs(cls.secret_home, mode=0o700)
        gpg = ["gpg", "--homedir", cls.secret_home, "--batch", "--passphrase", "", "--quiet"]
        subprocess.run(gpg + ["--quick-gen-key", "fake dumps", "ed25519", "cert", "never"], check=True)
        listing = subprocess.run(
            gpg + ["--with-colons", "--list-keys"], check=True, capture_output=True, text=True
        ).stdout
        cls.fingerprint = next(line.split(":")[9] for line in listing.splitlines() if line.startswith("fpr:"))
        subprocess.run(gpg + ["--quick-add-key", cls.fingerprint, "cv25519", "encr", "never"], check=True)
        cls.key_file = os.path.join(cls.home.name, "recipient.asc")
        with open(cls.key_file, "wb") as key_file:
            key_file.write(subprocess.run(gpg + ["--armor", "--export"], check=True, capture_output=True).stdout)
        cls.encrypt = ["gpg", "--batch", "--trust-model", "always", "--recipient", cls.fingerprint, "--encrypt"]

    @classmethod
    def tearDownClass(cls):
        subprocess.run(["gpgconf", "--homedir", cls.secret_home, "--kill", "all"], check=False)
        cls.home.cleanup()

    def setUp(self):
        self.public_home = tempfile.TemporaryDirectory()
        os.environ["GNUPGHOME"] = os.path.join(self.public_home.name, "gnupg")
        import_recipient(self.key_file, self.fingerprint)

    def tearDown(self):
        self.public_home.cleanup()

    def decrypt(self, data):
        return subprocess.run(
            ["gpg", "--homedir", self.secret_home, "--batch", "--quiet", "--decrypt"],
            input=data,
            check=True,
            capture_output=True,
        ).stdout

    def test_refuses_a_key_other_than_the_pinned_one_without_importing_it(self):
        os.environ["GNUPGHOME"] = os.path.join(self.public_home.name, "other")
        with self.assertRaises(SystemExit):
            import_recipient(self.key_file, PINNED_FINGERPRINT)
        listing = subprocess.run(["gpg", "--batch", "--with-colons", "--list-keys"], capture_output=True, text=True)
        self.assertNotIn("fpr:", listing.stdout)

    def test_uploads_a_dump_only_the_recipient_decrypts(self):
        s3 = FakeS3()
        key = object_key(DATABASE, MORNING)
        self.assertTrue(dump_database(s3, BUCKET, key, ["printf", "dump bytes"], self.encrypt))
        self.assertNotIn(b"dump bytes", s3.objects[key])
        self.assertEqual(self.decrypt(s3.objects[key]), b"dump bytes")

    def test_a_rerun_on_the_same_day_keeps_both_dumps(self):
        s3 = FakeS3()
        for moment in (MORNING, RERUN):
            self.assertTrue(dump_database(s3, BUCKET, object_key(DATABASE, moment), ["printf", "dump"], self.encrypt))
        self.assertEqual(
            sorted(s3.objects),
            [f"dumps/{DATABASE}/2026-11-10T033000Z{SUFFIX}", f"dumps/{DATABASE}/2026-11-10T091542Z{SUFFIX}"],
        )

    def test_a_failed_dump_or_encryption_fails_and_removes_the_partial_upload(self):
        failing_dump = (["sh", "-c", "printf partial; exit 3"], self.encrypt)
        failing_encryption = (["printf", "dump"], self.encrypt[:-2] + [PINNED_FINGERPRINT, "--encrypt"])
        for dump, encrypt in (failing_dump, failing_encryption):
            with self.subTest(dump=dump, encrypt=encrypt):
                s3 = FakeS3()
                key = object_key(DATABASE, MORNING)
                self.assertFalse(dump_database(s3, BUCKET, key, dump, encrypt))
                self.assertNotIn(key, s3.objects)

    def test_a_failed_upload_stops_the_pipeline(self):
        s3 = FakeS3(fail_upload=True)
        key = object_key(DATABASE, MORNING)
        self.assertFalse(dump_database(s3, BUCKET, key, ["yes"], self.encrypt))
        self.assertNotIn(key, s3.objects)

    def test_a_locked_partial_upload_fails_the_dump_without_raising(self):
        s3 = FakeS3(locked=True)
        self.assertFalse(dump_database(s3, BUCKET, object_key(DATABASE, MORNING), ["false"], self.encrypt))

    def test_prune_keeps_the_newest_per_database(self):
        legacy = [f"dumps/{DATABASE}/2026-09-{day:02d}{SUFFIX}" for day in range(1, EXTRA_DUMPS + 1)]
        start = datetime.datetime(2026, 9, EXTRA_DUMPS, 3, 30, tzinfo=datetime.UTC)
        current = [object_key(DATABASE, start + datetime.timedelta(days=day)) for day in range(KEEP_PER_DATABASE)]
        neighbour = object_key("paperless-gpt", MORNING)
        s3 = FakeS3(legacy + current + [neighbour])
        prune(s3, BUCKET, f"dumps/{DATABASE}/", KEEP_PER_DATABASE)
        self.assertEqual(sorted(s3.objects), sorted(current + [neighbour]))


if __name__ == "__main__":
    unittest.main()
