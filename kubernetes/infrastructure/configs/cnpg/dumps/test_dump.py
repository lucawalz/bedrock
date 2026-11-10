import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dump import KEEP_PER_DATABASE, SUFFIX, dump_database, encrypt_command, import_recipient, prune  # noqa: E402

PINNED_FINGERPRINT = "1EB066F3C8C3F147DABC028DD009DE9C37E1B21D"
BUCKET = "bucket"
KEY = "dumps/app/2026-11-10.gpg"
EXTRA_DUMPS = 3


class FakeS3:
    def __init__(self, keys=(), fail_upload=False):
        self.objects = {key: b"" for key in keys}
        self.fail_upload = fail_upload

    def upload_fileobj(self, stream, bucket, key):
        if self.fail_upload:
            stream.read(1)
            raise ConnectionError("upload refused")
        self.objects[key] = stream.read()

    def delete_object(self, Bucket, Key):
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

    def test_refuses_a_key_other_than_the_pinned_one(self):
        os.environ["GNUPGHOME"] = os.path.join(self.public_home.name, "other")
        with self.assertRaises(SystemExit):
            import_recipient(self.key_file, PINNED_FINGERPRINT)

    def test_uploads_a_dump_only_the_recipient_decrypts(self):
        s3 = FakeS3()
        self.assertTrue(dump_database(s3, BUCKET, KEY, ["printf", "dump bytes"], encrypt_command(self.fingerprint)))
        self.assertNotIn(b"dump bytes", s3.objects[KEY])
        self.assertEqual(self.decrypt(s3.objects[KEY]), b"dump bytes")

    def test_a_failed_dump_fails_and_removes_the_partial_upload(self):
        s3 = FakeS3()
        dump = ["sh", "-c", "printf partial; exit 3"]
        self.assertFalse(dump_database(s3, BUCKET, KEY, dump, encrypt_command(self.fingerprint)))
        self.assertNotIn(KEY, s3.objects)

    def test_a_failed_encryption_fails_the_dump(self):
        s3 = FakeS3()
        self.assertFalse(dump_database(s3, BUCKET, KEY, ["printf", "dump bytes"], encrypt_command(PINNED_FINGERPRINT)))
        self.assertNotIn(KEY, s3.objects)

    def test_a_failed_upload_stops_the_pipeline(self):
        s3 = FakeS3(fail_upload=True)
        self.assertFalse(dump_database(s3, BUCKET, KEY, ["yes"], encrypt_command(self.fingerprint)))
        self.assertNotIn(KEY, s3.objects)

    def test_prune_keeps_the_newest_per_database(self):
        dumps = [f"dumps/paperless/2026-{month:02d}-{day:02d}{SUFFIX}" for month in (9, 10) for day in range(1, 31)]
        dumps = dumps[: KEEP_PER_DATABASE + EXTRA_DUMPS]
        neighbour = f"dumps/paperless-gpt/2026-01-01{SUFFIX}"
        s3 = FakeS3(dumps + [neighbour])
        prune(s3, BUCKET, "dumps/paperless/", KEEP_PER_DATABASE)
        self.assertEqual(sorted(s3.objects), sorted(dumps[EXTRA_DUMPS:] + [neighbour]))


if __name__ == "__main__":
    unittest.main()
