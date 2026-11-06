import json
import os
import urllib.error
import urllib.request

CLIENTS_FILE = "/config/clients.json"
SECRETS_DIR = "/secrets"
REQUEST_TIMEOUT_SECONDS = 30

api = os.environ["POCKET_ID_URL"].rstrip("/") + "/api/oidc/clients"
api_key = os.environ["STATIC_API_KEY"]


def call(method, url, body=None):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={"X-API-Key": api_key, "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
        raw = response.read()
    return json.loads(raw) if raw else None


def exists(client_id):
    try:
        call("GET", f"{api}/{client_id}")
        return True
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return False
        raise


with open(CLIENTS_FILE) as handle:
    clients = json.load(handle)

for client in clients:
    client_id = client["id"]
    with open(os.path.join(SECRETS_DIR, client_id)) as handle:
        secret = handle.read()
    if not secret:
        raise SystemExit(f"secret for {client_id} is empty")

    if exists(client_id):
        call("PUT", f"{api}/{client_id}", {k: v for k, v in client.items() if k != "id"})
    else:
        call("POST", api, client)

    # Pocket ID stores only a hash, so converge by adding the declared secret and dropping every other one.
    created = call("POST", f"{api}/{client_id}/secrets", {"secret": secret})
    for existing in call("GET", f"{api}/{client_id}/secrets") or []:
        if existing["id"] != created["id"]:
            call("DELETE", f"{api}/{client_id}/secrets/{existing['id']}")
    print(f"synced {client_id}")
