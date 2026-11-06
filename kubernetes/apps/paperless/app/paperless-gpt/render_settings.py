import json
import os
import shutil
import sys
import time
import urllib.request

API_URL = "http://paperless-ngx:8000/api/custom_fields/?page_size=100"
TEMPLATE_PATH = "/src/settings/settings.template.json"
PROMPTS_SRC = "/src/prompts"
PROMPTS_DST = "/app/prompts"
SETTINGS_PATH = "/app/config/settings.json"
RETRY_DELAY_SECONDS = 30
DEADLINE_SECONDS = 900
REQUEST_TIMEOUT_SECONDS = 10


def fetch_fields(token):
    request = urllib.request.Request(API_URL, headers={"Authorization": f"Token {token}"})
    with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
        return json.load(response)["results"]


def resolve(names, fields):
    by_name = {field["name"]: field["id"] for field in fields}
    missing = [name for name in names if name not in by_name]
    if missing:
        raise LookupError(f"custom fields not found: {', '.join(missing)}")
    return [by_name[name] for name in names]


def build_settings(template, ids):
    settings = {key: value for key, value in template.items() if key != "custom_field_names"}
    settings["custom_fields_selected_ids"] = ids
    settings["ocr"] = {}
    return settings


def wait_for_ids(names, fetch, sleep=time.sleep, clock=time.monotonic):
    deadline = clock() + DEADLINE_SECONDS
    while True:
        try:
            return resolve(names, fetch())
        except (LookupError, OSError, ValueError, KeyError) as error:
            if clock() >= deadline:
                raise
            print(f"waiting for custom fields: {type(error).__name__}", file=sys.stderr, flush=True)
            sleep(RETRY_DELAY_SECONDS)


def main():
    token = os.environ["PAPERLESS_API_TOKEN"]
    with open(TEMPLATE_PATH, encoding="utf-8") as handle:
        template = json.load(handle)
    ids = wait_for_ids(template["custom_field_names"], lambda: fetch_fields(token))
    for name in os.listdir(PROMPTS_SRC):
        shutil.copyfile(os.path.join(PROMPTS_SRC, name), os.path.join(PROMPTS_DST, name))
    with open(SETTINGS_PATH, "w", encoding="utf-8") as handle:
        json.dump(build_settings(template, ids), handle, indent=2, ensure_ascii=False)


if __name__ == "__main__":
    main()
