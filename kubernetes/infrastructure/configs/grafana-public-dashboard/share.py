import base64
import json
import os
import re
import urllib.error
import urllib.request

REQUEST_TIMEOUT_SECONDS = 30
NOT_FOUND = 404
# the form Grafana generates itself; the router derives the share URL from it
ACCESS_TOKEN_PATTERN = re.compile(r"[0-9a-f]{32}")

api = os.environ["GRAFANA_URL"].rstrip("/")
dashboard_uid = os.environ["DASHBOARD_UID"]
access_token = os.environ["ACCESS_TOKEN"]
if not ACCESS_TOKEN_PATTERN.fullmatch(access_token):
    raise SystemExit("access token must be 32 lowercase hex characters")
credentials = base64.b64encode(f'{os.environ["GRAFANA_USER"]}:{os.environ["GRAFANA_PASSWORD"]}'.encode()).decode()
shares = f"/api/dashboards/uid/{dashboard_uid}/public-dashboards"


def call(method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(
        api + path,
        data=data,
        method=method,
        headers={"Authorization": f"Basic {credentials}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
        raw = response.read()
    return json.loads(raw) if raw else None


try:
    existing = call("GET", shares)
except urllib.error.HTTPError as error:
    if error.code != NOT_FOUND:
        raise
    existing = None

# Grafana keeps a share's access token fixed for its lifetime, so a rotated secret needs a new share
if existing is not None and existing["accessToken"] != access_token:
    call("DELETE", f"{shares}/{existing['uid']}")
    existing = None
    print(f"deleted the share of {dashboard_uid} holding a rotated token")

if existing is None:
    call("POST", shares, {"accessToken": access_token, "isEnabled": True, "share": "public"})
    print(f"created the public share of {dashboard_uid}")
elif not existing["isEnabled"]:
    call("PATCH", f"{shares}/{existing['uid']}", {"isEnabled": True})
    print(f"enabled the public share of {dashboard_uid}")
else:
    print(f"public share of {dashboard_uid} already in place")
