import json
import os
import urllib.error
import urllib.parse
import urllib.request

CLIENTS_FILE = "/config/clients.json"
SECRETS_DIR = "/secrets"
OWNER_EMAIL_KEY = "owner-email"
ADMINS_GROUP = "admins"
REQUEST_TIMEOUT_SECONDS = 30
NOT_FOUND = 404
LOCAL_FIELDS = ("id", "allowedUserGroups")

base_url = ""
api_key = ""


def call(method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(
        base_url + path,
        data=data,
        method=method,
        headers={"X-API-Key": api_key, "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
        raw = response.read()
    return json.loads(raw) if raw else None


def exists(client_id):
    try:
        call("GET", f"/api/oidc/clients/{client_id}")
        return True
    except urllib.error.HTTPError as error:
        error.close()
        if error.code == NOT_FOUND:
            return False
        raise


def search(path, term):
    return call("GET", f"{path}?{urllib.parse.urlencode({'search': term})}")["data"]


def ensure_admins(owner_email):
    try:
        owner = next(
            (user for user in search("/api/users", owner_email) if user["email"].lower() == owner_email.lower()), None
        )
    except urllib.error.URLError as error:
        raise SystemExit(f"cannot look up the owner in Pocket ID: {error}")
    if owner is None:
        raise SystemExit(f"no Pocket ID user has the owner email, so the {ADMINS_GROUP} group would be empty")

    try:
        group = next((group for group in search("/api/user-groups", ADMINS_GROUP) if group["name"] == ADMINS_GROUP), None)
        if group is None:
            group = call("POST", "/api/user-groups", {"name": ADMINS_GROUP, "friendlyName": ADMINS_GROUP.title()})
        members = [user["id"] for user in call("GET", f"/api/user-groups/{group['id']}")["users"]]
    except urllib.error.URLError as error:
        raise SystemExit(f"cannot create the {ADMINS_GROUP} group: {error}")

    if owner["id"] not in members:
        try:
            updated = call("PUT", f"/api/user-groups/{group['id']}/users", {"userIds": members + [owner["id"]]})
        except urllib.error.URLError as error:
            raise SystemExit(f"cannot add the owner to the {ADMINS_GROUP} group: {error}")
        if owner["id"] not in [user["id"] for user in updated["users"]]:
            raise SystemExit(f"the {ADMINS_GROUP} group does not list the owner after adding them")
    return group["id"]


def sync(clients, read_secret):
    for client in clients:
        groups = client.get("allowedUserGroups", [])
        if client["isGroupRestricted"] and not groups:
            raise SystemExit(f"{client['id']} is group restricted but names no allowed group")
        if any(group != ADMINS_GROUP for group in groups):
            raise SystemExit(f"{client['id']} names a group other than {ADMINS_GROUP}")

    admins_id = None
    if any(client.get("allowedUserGroups") for client in clients):
        owner_email = (read_secret(OWNER_EMAIL_KEY) or "").strip()
        if not owner_email:
            raise SystemExit(f"secret {OWNER_EMAIL_KEY} is empty")
        admins_id = ensure_admins(owner_email)

    for client in clients:
        client_id = client["id"]
        public = client.get("isPublic", False)
        secret = None if public else read_secret(client_id)
        if not public and not secret:
            raise SystemExit(f"secret for {client_id} is empty")
        body = {k: v for k, v in client.items() if k not in LOCAL_FIELDS}

        if not exists(client_id):
            call("POST", "/api/oidc/clients", {**body, "id": client_id, "isGroupRestricted": False})
        if client.get("allowedUserGroups"):
            call("PUT", f"/api/oidc/clients/{client_id}/allowed-user-groups", {"userGroupIds": [admins_id]})
            assigned = call("GET", f"/api/oidc/clients/{client_id}")["allowedUserGroups"]
            if admins_id not in [group["id"] for group in assigned]:
                raise SystemExit(f"{client_id} does not list the {ADMINS_GROUP} group after assigning it")
        call("PUT", f"/api/oidc/clients/{client_id}", body)

        if not public:
            # Pocket ID stores only a hash, so converge by adding the declared secret and dropping every other one.
            created = call("POST", f"/api/oidc/clients/{client_id}/secrets", {"secret": secret})
            for existing in call("GET", f"/api/oidc/clients/{client_id}/secrets") or []:
                if existing["id"] != created["id"]:
                    call("DELETE", f"/api/oidc/clients/{client_id}/secrets/{existing['id']}")
        print(f"synced {client_id}")


def read_secret_file(name):
    try:
        with open(os.path.join(SECRETS_DIR, name)) as handle:
            return handle.read()
    except FileNotFoundError:
        return None


def main():
    global base_url, api_key
    base_url = os.environ["POCKET_ID_URL"].rstrip("/")
    api_key = os.environ["STATIC_API_KEY"]
    with open(CLIENTS_FILE) as handle:
        sync(json.load(handle), read_secret_file)


if __name__ == "__main__":
    main()
