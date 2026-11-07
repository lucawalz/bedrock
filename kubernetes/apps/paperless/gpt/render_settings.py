import json
import os
import shutil
import sys
import time
import urllib.request

import yaml

API_URL = "http://paperless-ngx:8000/api/custom_fields/?page_size=100"
TEMPLATE_PATH = "/src/settings/settings.template.json"
TAXONOMY_PATH = "/src/taxonomy/taxonomy.yaml"
PROMPTS_SRC = "/src/prompts"
PROMPTS_DST = "/app/prompts"
SETTINGS_PATH = "/app/config/settings.json"
RETRY_DELAY_SECONDS = 30
REQUEST_TIMEOUT_SECONDS = 10
PROMPT_SUFFIX = ".tmpl"
TAG_PROMPT = "tag_prompt.tmpl"
FIELD_PROMPT = "custom_field_prompt.tmpl"
TAG_MARKER = "@@TAG_DEFINITIONS@@"
FIELD_MARKER = "@@FIELD_DEFINITIONS@@"
TEMPLATE_DELIMITERS = ("{{", "}}")
DEFINITIONS = (
    (TAG_PROMPT, TAG_MARKER, "tags", "tag_definitions"),
    (FIELD_PROMPT, FIELD_MARKER, "custom_fields", "field_definitions"),
)


def fetch_fields(token):
    request = urllib.request.Request(API_URL, headers={"Authorization": f"Token {token}"})
    with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
        return json.load(response)["results"]


def field_names(taxonomy):
    names = [field["name"] for field in taxonomy["custom_fields"]]
    if not names:
        raise ValueError("taxonomy lists no custom fields")
    return names


def resolve(names, fields):
    by_name = {field["name"]: field["id"] for field in fields}
    missing = [name for name in names if name not in by_name]
    if missing:
        raise LookupError(f"custom fields not found: {', '.join(missing)}")
    return [by_name[name] for name in names]


def build_settings(template, ids):
    settings = dict(template)
    settings["custom_fields_selected_ids"] = ids
    settings["ocr"] = {}
    return settings


def wait_for_ids(names, fetch, sleep=time.sleep):
    while True:
        try:
            return resolve(names, fetch())
        except (LookupError, OSError, ValueError, KeyError) as error:
            print(f"waiting for custom fields: {type(error).__name__}", file=sys.stderr, flush=True)
            sleep(RETRY_DELAY_SECONDS)


# ConfigMap volumes also hold ..data and a timestamped directory beside the keys
def copy_prompts(src, dst):
    for name in os.listdir(src):
        if not name.endswith(PROMPT_SUFFIX):
            continue
        shutil.copyfile(os.path.join(src, name), os.path.join(dst, name))


def definitions(entries, element):
    lines = []
    for entry in entries:
        description = entry.get("description") if isinstance(entry, dict) else None
        if not isinstance(description, str) or not description.strip():
            raise ValueError(f"taxonomy entry {entry!r} needs a non-empty description")
        line = f"{entry['name']}: {description.strip()}"
        # the block lands in a Go text/template before it is parsed
        if any(delimiter in line for delimiter in TEMPLATE_DELIMITERS):
            raise ValueError(f"taxonomy entry {entry['name']!r} holds template delimiters")
        lines.append(line)
    return "\n".join([f"<{element}>", *lines, f"</{element}>"])


def definition_blocks(taxonomy):
    return {prompt: (marker, definitions(taxonomy[key], element)) for prompt, marker, key, element in DEFINITIONS}


def insert_definitions(directory, blocks):
    for prompt, (marker, block) in blocks.items():
        path = os.path.join(directory, prompt)
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().split("\n")
        if lines.count(marker) != 1:
            raise ValueError(f"{prompt} needs the line {marker} exactly once")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("\n".join(block if line == marker else line for line in lines))


def main():
    token = os.environ["PAPERLESS_API_TOKEN"]
    with open(TEMPLATE_PATH, encoding="utf-8") as handle:
        template = json.load(handle)
    with open(TAXONOMY_PATH, encoding="utf-8") as handle:
        taxonomy = yaml.safe_load(handle)
    names = field_names(taxonomy)
    blocks = definition_blocks(taxonomy)
    ids = wait_for_ids(names, lambda: fetch_fields(token))
    copy_prompts(PROMPTS_SRC, PROMPTS_DST)
    insert_definitions(PROMPTS_DST, blocks)
    with open(SETTINGS_PATH, "w", encoding="utf-8") as handle:
        json.dump(build_settings(template, ids), handle, indent=2, ensure_ascii=False)


if __name__ == "__main__":
    main()
