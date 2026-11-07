import contextlib
import io
import os
import sys
from unittest import mock

import django

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "paperless.settings")
django.setup()
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from django.test import TestCase  # noqa: E402
from documents.models import (  # noqa: E402
    Correspondent,
    CustomField,
    Document,
    SavedView,
    SavedViewFilterRule,
    Tag,
    Workflow,
    WorkflowAction,
    WorkflowTrigger,
)
from paperless_mail.models import MailAccount, MailRule  # noqa: E402

from sync import sync  # noqa: E402

TAXONOMY = {
    "document_types": ["Rechnung", "Vertrag"],
    "tags": [{"name": "Steuern", "description": "Tax documents."}, {"name": "Bank", "description": "Bank statements."}],
    "custom_fields": [
        {"name": "Betrag", "description": "The main amount.", "data_type": "monetary"},
        {"name": "Steuerjahr", "description": "The tax year.", "data_type": "integer"},
    ],
    "correspondents": [{"name": "Example University", "aliases": ["EU"]}],
}
MAIL = {
    "IMAP_HOST": "imap.example.org",
    "IMAP_PORT": "993",
    "IMAP_USERNAME": "inbox",
    "IMAP_PASSWORD": "not-a-secret",
    "ATTACHMENT_ADDRESS": "docs@example.com",
    "FULL_MAIL_ADDRESS": "docs-mail@example.com",
    "ALLOWED_SENDERS": "",
}
REINDEX = "sync.bulk_update_documents.apply_async"


def mail(senders):
    return {**MAIL, "ALLOWED_SENDERS": senders}


def document(name, correspondent):
    return Document.objects.create(title=name, checksum=name, mime_type="application/pdf", correspondent=correspondent)


class SyncTest(TestCase):
    def setUp(self):
        patcher = mock.patch(REINDEX)
        self.reindex = patcher.start()
        self.addCleanup(patcher.stop)

    def run_sync(self, taxonomy=TAXONOMY, mail_env=MAIL):
        with self.captureOnCommitCallbacks(execute=True):
            return sync(taxonomy, mail_env)

    def test_sync_is_idempotent(self):
        document("one", Correspondent.objects.create(name="EU"))
        first = self.run_sync(mail_env=mail("a@x.de"))
        second = self.run_sync(mail_env=mail("a@x.de"))
        self.assertGreater(first["created"], 0)
        self.assertEqual(first["merged"], 1)
        self.assertEqual(second, {"created": 0, "updated": 0, "merged": 0, "deleted": 0})

    def test_sync_keeps_unmanaged_objects(self):
        Tag.objects.create(name="privat")
        Correspondent.objects.create(name="Bank A")
        account = MailAccount.objects.create(name="other", imap_server="imap.example.net", username="u", password="p")
        MailRule.objects.create(name="paperless-9", account=account, filter_from="c@z.de")
        self.run_sync(mail_env=mail("a@x.de"))
        self.run_sync()
        self.assertTrue(Tag.objects.filter(name="privat").exists())
        self.assertTrue(Correspondent.objects.filter(name="Bank A").exists())
        self.assertTrue(MailRule.objects.filter(name="paperless-9", account=account).exists())

    def test_workflow_excludes_web_ui(self):
        self.run_sync()
        workflow = Workflow.objects.get(name="paperless-gpt-auto")
        trigger = workflow.triggers.get()
        self.assertEqual(trigger.type, WorkflowTrigger.WorkflowTriggerType.CONSUMPTION)
        self.assertEqual({int(source) for source in trigger.sources}, {1, 2, 3})
        action = workflow.actions.get()
        self.assertEqual([tag.name for tag in action.assign_tags.all()], ["paperless-gpt-auto"])
        self.assertTrue(Tag.objects.filter(name="paperless-gpt-ocr-auto", matching_algorithm=Tag.MATCH_NONE).exists())

    def test_mail_rules_only_for_allowed_senders(self):
        self.run_sync(mail_env=mail("a@x.de,b@y.de"))
        rules = MailRule.objects.filter(account__name="paperless")
        self.assertEqual(sorted({rule.filter_from for rule in rules}), ["a@x.de", "b@y.de"])
        self.assertEqual({rule.attachment_type for rule in rules}, {MailRule.AttachmentProcessing.ATTACHMENTS_ONLY})
        self.assertEqual({rule.action for rule in rules}, {MailRule.MailAction.DELETE})

        counts = self.run_sync(mail_env=mail("b@y.de"))
        self.assertEqual({rule.filter_from for rule in rules.all()}, {"b@y.de"})
        self.assertEqual(counts["deleted"], 2)

        self.run_sync(mail_env=mail(""))
        self.assertFalse(rules.all().exists())

    def test_full_mail_rule_per_sender(self):
        self.run_sync(mail_env=mail("a@x.de,b@y.de"))
        rules = {rule.name: rule for rule in MailRule.objects.filter(account__name="paperless")}
        self.assertEqual(sorted(rules), ["paperless-1", "paperless-1-mail", "paperless-2", "paperless-2-mail"])
        self.assertEqual(len({rule.order for rule in rules.values()}), 4)
        for name, sender in (("paperless-1", "a@x.de"), ("paperless-2", "b@y.de")):
            attachment, full = rules[name], rules[name + "-mail"]
            self.assertEqual((attachment.filter_from, attachment.filter_to), (sender, "docs@example.com"))
            self.assertEqual((full.filter_from, full.filter_to), (sender, "docs-mail@example.com"))
            self.assertEqual(attachment.consumption_scope, MailRule.ConsumptionScope.ATTACHMENTS_ONLY)
            self.assertEqual(full.consumption_scope, MailRule.ConsumptionScope.EML_ONLY)
            for rule in (attachment, full):
                self.assertEqual(rule.action, MailRule.MailAction.DELETE)
                self.assertTrue(rule.enabled)
        self.assertEqual(self.run_sync(mail_env=mail("a@x.de,b@y.de")), {"created": 0, "updated": 0, "merged": 0, "deleted": 0})

    def test_removed_sender_drops_both_rules(self):
        self.run_sync(mail_env=mail("a@x.de,b@y.de"))
        counts = self.run_sync(mail_env=mail("a@x.de"))
        self.assertEqual(counts["deleted"], 2)
        self.assertEqual(
            sorted(MailRule.objects.filter(account__name="paperless").values_list("name", flat=True)),
            ["paperless-1", "paperless-1-mail"],
        )

    def test_overlapping_addresses_rejected(self):
        for attachment, full in (("docs@example.com", "mydocs@example.com"), ("a@example.com", "A@example.com")):
            env = {**mail("a@x.de"), "ATTACHMENT_ADDRESS": attachment, "FULL_MAIL_ADDRESS": full}
            with self.assertRaisesRegex(ValueError, "must not contain each other"):
                self.run_sync(mail_env=env)
        self.assertFalse(MailRule.objects.exists())

    def test_existing_rule_action_is_updated(self):
        self.run_sync(mail_env=mail("a@x.de"))
        MailRule.objects.filter(name="paperless-1").update(action=MailRule.MailAction.MARK_READ)
        counts = self.run_sync(mail_env=mail("a@x.de"))
        self.assertEqual(MailRule.objects.get(name="paperless-1").action, MailRule.MailAction.DELETE)
        self.assertEqual(counts["updated"], 1)

    def test_alias_merge_edge_cases(self):
        alias = Correspondent.objects.create(name="EU")
        moved = [document("one", alias).pk, document("two", alias).pk]
        taxonomy = {
            **TAXONOMY,
            "correspondents": [{"name": "Example University", "aliases": ["EU", "Example University", "absent"]}],
        }
        counts = self.run_sync(taxonomy=taxonomy)
        canonical = Correspondent.objects.get(name="Example University")
        self.assertFalse(Correspondent.objects.filter(name="EU").exists())
        self.assertEqual(sorted(Document.objects.filter(correspondent=canonical).values_list("pk", flat=True)), moved)
        self.assertEqual(counts["merged"], 1)
        self.reindex.assert_called_once()
        self.assertEqual(sorted(self.reindex.call_args.kwargs["kwargs"]["document_ids"]), moved)

    def test_alias_merge_repoints_references(self):
        alias = Correspondent.objects.create(name="EU")
        other = Correspondent.objects.create(name="Other")
        trigger = WorkflowTrigger.objects.create(type=WorkflowTrigger.WorkflowTriggerType.DOCUMENT_ADDED, filter_has_correspondent=alias)
        trigger.filter_has_any_correspondents.set([alias])
        trigger.filter_has_not_correspondents.set([alias, other])
        action = WorkflowAction.objects.create(assign_correspondent=alias)
        action.remove_correspondents.set([alias])
        workflow = Workflow.objects.create(name="hand-made")
        workflow.triggers.set([trigger])
        workflow.actions.set([action])
        account = MailAccount.objects.create(name="other", imap_server="imap.example.net", username="u", password="p")
        rule = MailRule.objects.create(name="manual", account=account, assign_correspondent=alias)
        view = SavedView.objects.create(name="by correspondent")
        filter_rule = SavedViewFilterRule.objects.create(saved_view=view, rule_type=3, value=str(alias.pk))

        self.run_sync()
        canonical = Correspondent.objects.get(name="Example University")
        trigger.refresh_from_db()
        action.refresh_from_db()
        rule.refresh_from_db()
        filter_rule.refresh_from_db()
        self.assertEqual(trigger.filter_has_correspondent, canonical)
        self.assertEqual(list(trigger.filter_has_any_correspondents.all()), [canonical])
        self.assertEqual(set(trigger.filter_has_not_correspondents.all()), {canonical, other})
        self.assertEqual(action.assign_correspondent, canonical)
        self.assertEqual(list(action.remove_correspondents.all()), [canonical])
        self.assertEqual(rule.assign_correspondent, canonical)
        self.assertEqual(filter_rule.value, str(canonical.pk))

    def test_reindex_failure_is_reported(self):
        document("one", Correspondent.objects.create(name="EU"))
        self.reindex.side_effect = ConnectionError("broker down")
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr), self.assertRaises(ConnectionError):
            self.run_sync()
        self.assertIn("document_index reindex", stderr.getvalue())

    def test_malformed_taxonomy_writes_nothing(self):
        CustomField.objects.create(name="Betrag", data_type=CustomField.FieldDataType.STRING)
        with self.assertRaises(ValueError):
            self.run_sync()
        self.assertFalse(Tag.objects.filter(name="Steuern").exists())
        with self.assertRaises(ValueError):
            self.run_sync(taxonomy={**TAXONOMY, "tags": "Steuern"})
        with self.assertRaises(ValueError):
            self.run_sync(mail_env=mail("x.de"))

    def test_undescribed_entries_write_nothing(self):
        field = TAXONOMY["custom_fields"][0]
        for taxonomy in (
            {**TAXONOMY, "tags": ["Steuern", "Bank"]},
            {**TAXONOMY, "tags": [{"name": "Steuern"}]},
            {**TAXONOMY, "tags": [{"name": "Steuern", "description": " "}]},
            {**TAXONOMY, "custom_fields": [{"name": "Betrag", "data_type": "monetary"}]},
            {**TAXONOMY, "custom_fields": [{**field, "description": None}]},
        ):
            with self.subTest(taxonomy=taxonomy), self.assertRaises(ValueError):
                self.run_sync(taxonomy=taxonomy)
        self.assertFalse(Tag.objects.exists())
        self.assertFalse(CustomField.objects.exists())
