import os
import re
import sys

import yaml
from django.db import transaction
from documents.models import (
    Correspondent,
    CustomField,
    Document,
    DocumentType,
    MatchingModel,
    PaperlessTask,
    SavedViewFilterRule,
    Tag,
    Workflow,
    WorkflowAction,
    WorkflowTrigger,
)
from documents.tasks import bulk_update_documents
from paperless_mail.models import MailAccount, MailRule

TAXONOMY_PATH = "/etc/paperless-taxonomy/taxonomy.yaml"
TAXONOMY_KEYS = {"document_types", "tags", "custom_fields", "correspondents"}
NAME_MAX_LENGTH = 128
AUTO_TAG = "paperless-gpt-auto"
OCR_AUTO_TAG = "paperless-gpt-ocr-auto"
WORKFLOW_NAME = "paperless-gpt-auto"
WORKFLOW_SOURCES = [
    str(WorkflowTrigger.DocumentSourceChoices.CONSUME_FOLDER.value),
    str(WorkflowTrigger.DocumentSourceChoices.API_UPLOAD.value),
    str(WorkflowTrigger.DocumentSourceChoices.MAIL_FETCH.value),
]
MAIL_ACCOUNT_NAME = "paperless"
MAIL_RULE_NAME = re.compile(r"paperless-\d+(-mail)?")
FULL_MAIL_SUFFIX = "-mail"
MAIL_KEYS = ("IMAP_HOST", "IMAP_PORT", "IMAP_USERNAME", "IMAP_PASSWORD", "ATTACHMENT_ADDRESS", "FULL_MAIL_ADDRESS")
MAX_PORT = 65535
SENDER = re.compile(r"[^@\s,]+@[^@\s,]+\.[^@\s,]+")
COUNTERS = ("created", "updated", "merged", "deleted")
CORRESPONDENT_RULE_TYPES = (3, 26, 27)


def names(value, kind):
    if not isinstance(value, list):
        raise ValueError(f"{kind} must be a list")
    result = []
    for name in value:
        if not isinstance(name, str) or not name.strip() or len(name.strip()) > NAME_MAX_LENGTH:
            raise ValueError(f"{kind} holds an invalid name: {name!r}")
        if name.strip() in result:
            raise ValueError(f"{kind} lists {name.strip()!r} twice")
        result.append(name.strip())
    return result


def entries(value, kind, required, optional=()):
    if not isinstance(value, list) or not all(isinstance(entry, dict) for entry in value):
        raise ValueError(f"{kind} must be a list of mappings")
    for entry in value:
        if not set(required) <= entry.keys() <= set(required) | set(optional):
            raise ValueError(f"{kind} entry {entry!r} needs the keys {sorted(required)}, optionally {sorted(optional)}")
    names([entry["name"] for entry in value], kind)
    return value


def parse_taxonomy(taxonomy):
    if not isinstance(taxonomy, dict) or taxonomy.keys() != TAXONOMY_KEYS:
        raise ValueError(f"taxonomy needs exactly the keys {sorted(TAXONOMY_KEYS)}")
    fields = entries(taxonomy["custom_fields"], "custom_fields", ("name", "data_type"))
    for field in fields:
        if field["data_type"] not in CustomField.FieldDataType.values:
            raise ValueError(f"custom field {field['name']!r} has unknown data_type {field['data_type']!r}")
    correspondents = {
        entry["name"].strip(): names(entry.get("aliases", []), f"aliases of {entry['name']!r}")
        for entry in entries(taxonomy["correspondents"], "correspondents", ("name",), ("aliases",))
    }
    aliases = [alias for canonical, listed in correspondents.items() for alias in listed if alias != canonical]
    names(aliases, "aliases")
    if clash := set(aliases) & correspondents.keys():
        raise ValueError(f"aliases name canonical correspondents: {sorted(clash)}")
    return {
        "document_types": names(taxonomy["document_types"], "document_types"),
        "tags": names(taxonomy["tags"], "tags"),
        "custom_fields": {field["name"].strip(): field["data_type"] for field in fields},
        "correspondents": correspondents,
    }


def parse_mail(mail):
    missing = [key for key in MAIL_KEYS if not mail.get(key, "").strip()]
    if missing:
        raise ValueError(f"mail settings missing: {missing}")
    port = mail["IMAP_PORT"].strip()
    if not port.isdigit() or not 0 < int(port) <= MAX_PORT:
        raise ValueError("IMAP_PORT must be a port number")
    senders = list(dict.fromkeys(s.strip() for s in mail.get("ALLOWED_SENDERS", "").split(",") if s.strip()))
    if any(not SENDER.fullmatch(sender) for sender in senders):
        raise ValueError("ALLOWED_SENDERS holds an entry that is not a mail address")
    addresses = {key: mail[key].strip() for key in ("ATTACHMENT_ADDRESS", "FULL_MAIL_ADDRESS")}
    if any(not SENDER.fullmatch(address) for address in addresses.values()):
        raise ValueError("ATTACHMENT_ADDRESS and FULL_MAIL_ADDRESS must be mail addresses")
    attachment, full = (address.lower() for address in addresses.values())
    if attachment in full or full in attachment:
        raise ValueError("ATTACHMENT_ADDRESS and FULL_MAIL_ADDRESS must not contain each other: IMAP TO matches substrings")
    account = {
        "imap_server": mail["IMAP_HOST"].strip(),
        "imap_port": int(port),
        "imap_security": MailAccount.ImapSecurity.SSL,
        "username": mail["IMAP_USERNAME"].strip(),
        "password": mail["IMAP_PASSWORD"],
        "account_type": MailAccount.MailAccountType.IMAP,
    }
    return account, senders, addresses


def assign(instance, fields):
    changed = [key for key, value in fields.items() if getattr(instance, key) != value]
    for key in changed:
        setattr(instance, key, fields[key])
    if changed or instance.pk is None:
        instance.save()
    return bool(changed)


def ensure(model, name, fields, counts):
    instance = model.objects.filter(name=name).order_by("pk").first()
    if instance is None:
        counts["created"] += 1
        return model.objects.create(name=name, **fields)
    counts["updated"] += assign(instance, fields)
    return instance


def ensure_custom_field(name, data_type, counts):
    field = CustomField.objects.filter(name=name).first()
    if field is None:
        CustomField.objects.create(name=name, data_type=data_type)
        counts["created"] += 1
    elif field.data_type != data_type:
        raise ValueError(f"custom field {name!r} is {field.data_type}, the taxonomy says {data_type}")


def repoint(duplicate, canonical):
    for relation in Correspondent._meta.get_fields(include_hidden=True):
        # hidden relations include assign_correspondent fields declared with related_name "+"
        if not relation.auto_created or relation.concrete or relation.related_model._meta.auto_created:
            continue
        field = relation.field.name
        holders = relation.related_model._base_manager.filter(**{field: duplicate})
        if relation.many_to_many:
            for holder in holders:
                getattr(holder, field).add(canonical)
        else:
            holders.update(**{field: canonical})
    SavedViewFilterRule.objects.filter(rule_type__in=CORRESPONDENT_RULE_TYPES, value=str(duplicate.pk)).update(
        value=str(canonical.pk),
    )


def merge(canonical, aliases, counts):
    moved = []
    for alias in aliases:
        if alias == canonical.name:
            continue
        for duplicate in Correspondent.objects.filter(name=alias):
            moved += Document.global_objects.filter(correspondent=duplicate).values_list("pk", flat=True)
            repoint(duplicate, canonical)
            duplicate.delete()
            counts["merged"] += 1
    return moved


def sync_workflow(tag, counts):
    workflow = Workflow.objects.filter(name=WORKFLOW_NAME).first()
    created = workflow is None
    if created:
        workflow = Workflow.objects.create(name=WORKFLOW_NAME)
    trigger = workflow.triggers.first() or WorkflowTrigger()
    action = workflow.actions.first() or WorkflowAction()
    changed = assign(trigger, {"type": WorkflowTrigger.WorkflowTriggerType.CONSUMPTION, "sources": WORKFLOW_SOURCES})
    changed |= assign(action, {"type": WorkflowAction.WorkflowActionType.ASSIGNMENT})
    changed |= assign(workflow, {"enabled": True})
    if list(action.assign_tags.all()) != [tag]:
        action.assign_tags.set([tag])
        changed = True
    if list(workflow.triggers.all()) != [trigger]:
        workflow.triggers.set([trigger])
        changed = True
    if list(workflow.actions.all()) != [action]:
        workflow.actions.set([action])
        changed = True
    if created:
        counts["created"] += 1
    elif changed:
        counts["updated"] += 1


def sync_mail(account_fields, senders, addresses, counts):
    account = ensure(MailAccount, MAIL_ACCOUNT_NAME, account_fields, counts)
    attachments = {
        "attachment_type": MailRule.AttachmentProcessing.ATTACHMENTS_ONLY,
        "consumption_scope": MailRule.ConsumptionScope.ATTACHMENTS_ONLY,
        "filter_to": addresses["ATTACHMENT_ADDRESS"],
    }
    whole_mails = {
        "attachment_type": MailRule.AttachmentProcessing.ATTACHMENTS_ONLY,
        "consumption_scope": MailRule.ConsumptionScope.EML_ONLY,
        "filter_to": addresses["FULL_MAIL_ADDRESS"],
    }
    wanted = {}
    for number, sender in enumerate(senders, start=1):
        name = f"{MAIL_ACCOUNT_NAME}-{number}"
        wanted[name] = {"order": 2 * number - 1, "filter_from": sender, **attachments}
        wanted[name + FULL_MAIL_SUFFIX] = {"order": 2 * number, "filter_from": sender, **whole_mails}
    for rule in account.rules.all():
        if MAIL_RULE_NAME.fullmatch(rule.name) and rule.name not in wanted:
            rule.delete()
            counts["deleted"] += 1
    for name, fields in wanted.items():
        fields = {**fields, "action": MailRule.MailAction.DELETE, "enabled": True}
        rule = account.rules.filter(name=name).first()
        if rule is None:
            MailRule.objects.create(name=name, account=account, **fields)
            counts["created"] += 1
        else:
            counts["updated"] += assign(rule, fields)


def reindex(document_ids):
    try:
        bulk_update_documents.apply_async(
            kwargs={"document_ids": document_ids},
            headers={"trigger_source": PaperlessTask.TriggerSource.SYSTEM},
        )
    except Exception:
        print(
            f"paperless taxonomy sync: merged aliases are committed but the reindex of documents {document_ids} "
            "was not queued; run document_index reindex and document_renamer in the paperless-ngx pod",
            file=sys.stderr,
        )
        raise


def sync(taxonomy, mail):
    vocabulary = parse_taxonomy(taxonomy)
    account_fields, senders, addresses = parse_mail(mail)
    counts = dict.fromkeys(COUNTERS, 0)
    unmatched = {"matching_algorithm": MatchingModel.MATCH_NONE}
    with transaction.atomic():
        for name in vocabulary["document_types"]:
            ensure(DocumentType, name, {}, counts)
        for name in vocabulary["tags"]:
            ensure(Tag, name, unmatched, counts)
        auto_tag = ensure(Tag, AUTO_TAG, unmatched, counts)
        ensure(Tag, OCR_AUTO_TAG, unmatched, counts)
        for name, data_type in vocabulary["custom_fields"].items():
            ensure_custom_field(name, data_type, counts)
        moved = []
        for name, aliases in vocabulary["correspondents"].items():
            moved += merge(ensure(Correspondent, name, {}, counts), aliases, counts)
        sync_workflow(auto_tag, counts)
        sync_mail(account_fields, senders, addresses, counts)
        if moved:
            transaction.on_commit(lambda: reindex(moved))
    return counts


if __name__ == "__main__":
    with open(TAXONOMY_PATH) as handle:
        print("paperless taxonomy sync:", sync(yaml.safe_load(handle), os.environ))
