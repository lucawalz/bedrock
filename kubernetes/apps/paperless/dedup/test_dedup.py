import base64
import io
import json
import os
import sys
import urllib.error
from unittest import mock

import django

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "paperless.settings")
django.setup()
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from django.contrib.auth.models import User  # noqa: E402
from django.test import TestCase  # noqa: E402
from documents.models import Correspondent, Document  # noqa: E402

from dedup import document_counts, find_pairs, open_pr  # noqa: E402

REPOSITORY = "https://api.github.com/repos/lucawalz/bedrock-secrets"
TAXONOMY_FILE = "clusters/home/apps/paperless-taxonomy.yaml"
CONFIG_MAP = """apiVersion: v1
kind: ConfigMap
metadata:
  name: paperless-taxonomy
  namespace: paperless
data:
  taxonomy.yaml: |
    document_types:
      - Rechnung
      - Kündigung
    tags:
      - Steuern
    custom_fields:
      - name: Fällig am
        data_type: date
    correspondents: []
"""
UPDATED = CONFIG_MAP.replace(
    "    correspondents: []\n",
    "    correspondents:\n      - name: Example GmbH\n        aliases:\n          - Example\n",
)
CANONICAL = CONFIG_MAP.replace("    correspondents: []\n", "    correspondents:\n      - name: Example\n")
SWAPPED = CANONICAL.replace("      - name: Example\n", "      - name: Example\n        aliases:\n          - Example GmbH\n")
PAIR = ("Example GmbH", "Example", "obvious")
TITLE = "feat(paperless): merge duplicate correspondents proposed by the weekly job"
PR_URL = "https://github.com/lucawalz/bedrock-secrets/pull/1"


class FakeGitHub:
    def __init__(self, open_pulls, closed_pulls=(), config_map=CONFIG_MAP, failing=()):
        self.calls = []
        self.failing = failing
        self.routes = {
            ("GET", f"{REPOSITORY}/pulls?state=open&per_page=100"): open_pulls,
            ("GET", f"{REPOSITORY}/pulls?state=closed&per_page=100"): list(closed_pulls),
            ("GET", REPOSITORY): {"default_branch": "main"},
            ("GET", f"{REPOSITORY}/git/ref/heads/main"): {"object": {"sha": "head"}},
            ("GET", f"{REPOSITORY}/contents/{TAXONOMY_FILE}?ref=head"): {
                "content": base64.encodebytes(config_map.encode()).decode(),
                "sha": "blob",
            },
            ("POST", f"{REPOSITORY}/git/refs"): {},
            ("PUT", f"{REPOSITORY}/contents/{TAXONOMY_FILE}"): {},
            ("POST", f"{REPOSITORY}/pulls"): {"html_url": PR_URL},
        }

    def urlopen(self, request, timeout):
        method = request.get_method()
        body = json.loads(request.data) if request.data else None
        self.calls.append((method, request.full_url, body))
        if method in self.failing:
            raise urllib.error.HTTPError(request.full_url, 500, "error", {}, None)
        if method == "DELETE":
            return io.BytesIO(b"")
        return io.BytesIO(json.dumps(self.routes[(method, request.full_url)]).encode())

    def body(self, method, url):
        return next(body for called, full_url, body in self.calls if (called, full_url) == (method, url))


def document(name, correspondent):
    return Document.objects.create(title=name, checksum=name, mime_type="application/pdf", correspondent=correspondent)


class DedupTest(TestCase):
    def github(self, open_pulls, **options):
        fake = FakeGitHub(open_pulls, **options)
        patcher = mock.patch("dedup.urllib.request.urlopen", fake.urlopen)
        patcher.start()
        self.addCleanup(patcher.stop)
        return fake

    def test_obvious_pairs(self):
        for keep, duplicate in [
            ("Example University", "Example University Campus"),
            ("Muster GmbH", "muster gmbh."),
            ("Beispiel e.V.", "Beispiel"),
        ]:
            self.assertEqual(find_pairs([keep, duplicate], {}), [(keep, duplicate, "obvious")])

    def test_unclear_pairs(self):
        self.assertEqual(
            find_pairs(["Example Bank Ulm", "Example Bank Stuttgart"], {}),
            [("Example Bank Ulm", "Example Bank Stuttgart", "unclear")],
        )
        self.assertEqual(find_pairs(["Example Bank", "Other Insurance"], {}), [])

    def test_skips_known_aliases(self):
        known = {"Example University Campus": "Example University"}
        self.assertEqual(find_pairs(["Example University", "Example University Campus"], known), [])

    def test_no_second_open_pr(self):
        fake = self.github([{"head": {"ref": "paperless/dedup-2026-11-02"}}])
        self.assertIsNone(open_pr([("Example GmbH", "Example", "obvious")], "not-a-token"))
        self.assertEqual({method for method, _, _ in fake.calls}, {"GET"})

    def test_keep_is_the_name_with_more_documents(self):
        few = Correspondent.objects.create(name="Example")
        many = Correspondent.objects.create(name="Example GmbH")
        document("one", few)
        for name in ("two", "three", "four"):
            document(name, many)
        self.assertEqual(find_pairs(list(document_counts()), {}), [("Example GmbH", "Example", "obvious")])

    def test_names_shared_across_owners_count_once(self):
        self.assertEqual(find_pairs(["Example GmbH", "Example", "Example"], {}), [PAIR])
        for username in ("first", "second"):
            document(username, Correspondent.objects.create(name="Example", owner=User.objects.create(username=username)))
        document("third", Correspondent.objects.create(name="Example GmbH"))
        self.assertEqual(document_counts(), {"Example": 2, "Example GmbH": 1})
        self.assertEqual(find_pairs(list(document_counts()), {}), [("Example", "Example GmbH", "obvious")])

    def test_pr_adds_aliases_and_keeps_the_rest_of_the_file(self):
        document("one", Correspondent.objects.create(name="Example GmbH"))
        fake = self.github([{"head": {"ref": "renovate/sops"}}])
        self.assertEqual(open_pr([("Example GmbH", "Example", "obvious")], "not-a-token"), PR_URL)
        branch = fake.body("POST", f"{REPOSITORY}/git/refs")
        self.assertRegex(branch["ref"], r"^refs/heads/paperless/dedup-\d{4}-\d{2}-\d{2}$")
        self.assertEqual(branch["sha"], "head")
        commit = fake.body("PUT", f"{REPOSITORY}/contents/{TAXONOMY_FILE}")
        self.assertEqual(base64.b64decode(commit["content"]).decode(), UPDATED)
        self.assertEqual((commit["sha"], commit["branch"]), ("blob", branch["ref"].removeprefix("refs/heads/")))
        pull = fake.body("POST", f"{REPOSITORY}/pulls")
        self.assertEqual((pull["head"], pull["base"]), (commit["branch"], "main"))
        self.assertEqual((pull["title"], commit["message"]), (TITLE, TITLE))
        self.assertIn("| Example GmbH | 1 | Example | 0 | obvious |", pull["body"])
        self.assertIn('<!-- paperless-dedup: [["Example GmbH", "Example"]] -->', pull["body"])

    def test_closed_pr_rejects_its_pairs(self):
        closed = {"head": {"ref": "paperless/dedup-2026-11-02"}, "body": '<!-- paperless-dedup: [["Example", "Example GmbH"]] -->'}
        fake = self.github([], closed_pulls=[closed, {"head": {"ref": "renovate/sops"}, "body": None}])
        self.assertIsNone(open_pr([PAIR], "not-a-token"))
        self.assertEqual({method for method, _, _ in fake.calls}, {"GET"})

    def test_canonical_duplicate_becomes_the_kept_name(self):
        fake = self.github([], config_map=CANONICAL)
        self.assertEqual(open_pr([PAIR], "not-a-token"), PR_URL)
        commit = fake.body("PUT", f"{REPOSITORY}/contents/{TAXONOMY_FILE}")
        self.assertEqual(base64.b64decode(commit["content"]).decode(), SWAPPED)
        self.assertIn("| Example | 0 | Example GmbH | 0 | obvious |", fake.body("POST", f"{REPOSITORY}/pulls")["body"])

    def test_failed_commit_deletes_the_branch(self):
        fake = self.github([], failing={"PUT"})
        with self.assertRaisesRegex(RuntimeError, "answered 500"):
            open_pr([PAIR], "not-a-token")
        branch = fake.body("POST", f"{REPOSITORY}/git/refs")["ref"]
        self.assertEqual(fake.calls[-1][:2], ("DELETE", f"{REPOSITORY}/git/{branch}"))
        self.assertNotIn(("POST", f"{REPOSITORY}/pulls"), [call[:2] for call in fake.calls])

    def test_pipes_in_names_are_escaped(self):
        fake = self.github([])
        open_pr([("Example | Partner", "Example", "obvious")], "not-a-token")
        self.assertIn("| Example \\| Partner | 0 |", fake.body("POST", f"{REPOSITORY}/pulls")["body"])
