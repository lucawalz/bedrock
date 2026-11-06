import hashlib
import json
import os
import urllib.error
import urllib.request

KEYS_FILE = "/config/keys.json"
KEY_PREFIX = "sk-"
REQUEST_TIMEOUT_SECONDS = 30

api = os.environ["LITELLM_URL"].rstrip("/")
master_key = os.environ["LITELLM_MASTER_KEY"]


def call(method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(
        api + path,
        data=data,
        method=method,
        headers={"Authorization": f"Bearer {master_key}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
        raw = response.read()
    return json.loads(raw) if raw else None


def exists(key):
    # LiteLLM stores only the SHA-256 of a key, so look it up by hash and keep the key itself out of the URL
    key_hash = hashlib.sha256(key.encode()).hexdigest()
    return bool(call("GET", f"/key/list?key_hash={key_hash}")["keys"])


with open(KEYS_FILE) as handle:
    declared = json.load(handle)

for entry in declared:
    alias = entry["key_alias"]
    key = os.environ[entry.pop("env")]
    if not key.startswith(KEY_PREFIX):
        raise SystemExit(f"key for {alias} must start with {KEY_PREFIX}")

    if exists(key):
        call("POST", "/key/update", {**entry, "key": key})
    else:
        # a rotated secret leaves the old key holding the alias, which must be unique
        try:
            call("POST", "/key/delete", {"key_aliases": [alias]})
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise
        call("POST", "/key/generate", {**entry, "key": key})
    print(f"synced {alias}")
