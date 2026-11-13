import json
import os
import sys
import unittest
import urllib.error
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import sync  # noqa: E402

OWNER_EMAIL = "owner@example.com"
OWNER_ID = "user-owner"
OTHER_ID = "user-other"
GROUP_ID = "group-admins"
SERVER_ERROR = 500
LOOPBACK_HOSTS = ("localhost", "127.0.0.1")
SECRETS = {"restricted": "restricted-client-secret", "open": "open-client-secret", "owner-email": OWNER_EMAIL + "\n"}
RESTRICTED = {
    "id": "restricted",
    "name": "restricted",
    "callbackURLs": [],
    "isGroupRestricted": True,
    "allowedUserGroups": [sync.ADMINS_GROUP],
}
OPEN = {"id": "open", "name": "open", "callbackURLs": [], "isGroupRestricted": False}
PUBLIC = {**RESTRICTED, "id": "public", "isPublic": True}


def http_error(path):
    return urllib.error.HTTPError(path, SERVER_ERROR, "server error", {}, None)


class FakePocketId:
    def __init__(self, users=None, group_members=None, clients=(), fail=None, drop_owner=False, drop_groups=False):
        self.users = users if users is not None else [{"id": OWNER_ID, "email": OWNER_EMAIL}]
        self.group = None if group_members is None else {"id": GROUP_ID, "name": sync.ADMINS_GROUP, "users": group_members}
        self.clients = {client_id: {"isGroupRestricted": False} for client_id in clients}
        self.fail = fail
        self.drop_owner = drop_owner
        self.drop_groups = drop_groups
        self.allowed = {}
        self.calls = []

    def __call__(self, method, path, body=None):
        self.calls.append((method, path, body))
        if self.fail and (method, path) == self.fail:
            raise http_error(path)
        if path.startswith("/api/users?"):
            return {"data": self.users}
        if path.startswith("/api/user-groups?"):
            return {"data": [] if self.group is None else [self.group]}
        if (method, path) == ("POST", "/api/user-groups"):
            self.group = {"id": GROUP_ID, "name": body["name"], "users": []}
            return self.group
        if (method, path) == ("GET", f"/api/user-groups/{GROUP_ID}"):
            return self.group
        if (method, path) == ("PUT", f"/api/user-groups/{GROUP_ID}/users"):
            ids = [user_id for user_id in body["userIds"] if not (self.drop_owner and user_id == OWNER_ID)]
            self.group["users"] = [{"id": user_id} for user_id in ids]
            return self.group
        client_id = path.split("/")[4] if path.startswith("/api/oidc/clients/") else None
        if method == "GET" and path == f"/api/oidc/clients/{client_id}":
            if client_id not in self.clients:
                raise urllib.error.HTTPError(path, sync.NOT_FOUND, "not found", {}, None)
            return {**self.clients[client_id], "allowedUserGroups": self.allowed.get(client_id, [])}
        if (method, path) == ("POST", "/api/oidc/clients"):
            self.clients[body["id"]] = dict(body)
            return body
        if method == "PUT" and path == f"/api/oidc/clients/{client_id}":
            self.clients[client_id] = dict(body)
            return body
        if path.endswith("/allowed-user-groups"):
            if not self.drop_groups:
                self.allowed[path.split("/")[4]] = [{"id": group_id} for group_id in body["userGroupIds"]]
            return {}
        if method == "POST" and path.endswith("/secrets"):
            return {"id": "new-secret"}
        if method == "GET" and path.endswith("/secrets"):
            return [{"id": "new-secret"}]
        raise AssertionError(f"unexpected call {method} {path}")

    def restricted_calls(self):
        return [call for call in self.calls if call[2] and call[2].get("isGroupRestricted")]

    def index(self, method, path):
        return next(i for i, call in enumerate(self.calls) if call[:2] == (method, path))


class SyncTest(unittest.TestCase):
    def run_sync(self, fake, clients=(RESTRICTED, OPEN)):
        sync.call = fake
        sync.sync(list(clients), SECRETS.get)

    def assert_fails_unrestricted(self, fake, message):
        with self.assertRaises(SystemExit) as raised:
            self.run_sync(fake)
        self.assertIn(message, str(raised.exception.code))
        self.assertEqual(fake.restricted_calls(), [])
        self.assertFalse(any(path.endswith("/allowed-user-groups") for _, path, _ in fake.calls))

    def test_group_and_membership_precede_the_restriction(self):
        fake = FakePocketId(clients=["restricted", "open"])
        self.run_sync(fake)
        create = fake.index("POST", "/api/user-groups")
        member = fake.index("PUT", f"/api/user-groups/{GROUP_ID}/users")
        allowed = fake.index("PUT", "/api/oidc/clients/restricted/allowed-user-groups")
        restrict = fake.calls.index(fake.restricted_calls()[0])
        self.assertLess(create, member)
        self.assertLess(member, allowed)
        self.assertLess(allowed, restrict)
        self.assertEqual(fake.calls[allowed][2], {"userGroupIds": [GROUP_ID]})
        self.assertTrue(fake.clients["restricted"]["isGroupRestricted"])
        self.assertNotIn("allowedUserGroups", fake.clients["restricted"])
        self.assertFalse(fake.clients["open"]["isGroupRestricted"])

    def test_a_new_restricted_client_is_created_unrestricted_first(self):
        fake = FakePocketId(clients=[])
        self.run_sync(fake, [RESTRICTED])
        post = fake.calls[fake.index("POST", "/api/oidc/clients")]
        self.assertFalse(post[2]["isGroupRestricted"])
        self.assertLess(fake.index("POST", "/api/oidc/clients"), fake.calls.index(fake.restricted_calls()[0]))

    def test_existing_members_are_kept_and_the_owner_added(self):
        fake = FakePocketId(group_members=[{"id": OTHER_ID}], clients=["restricted"])
        self.run_sync(fake, [RESTRICTED])
        self.assertEqual(fake.group["users"], [{"id": OTHER_ID}, {"id": OWNER_ID}])

    def test_no_owner_user_fails_before_the_restriction(self):
        self.assert_fails_unrestricted(FakePocketId(users=[]), "no Pocket ID user")

    def test_a_partial_email_match_is_not_the_owner(self):
        self.assert_fails_unrestricted(
            FakePocketId(users=[{"id": OTHER_ID, "email": "co" + OWNER_EMAIL}]), "no Pocket ID user"
        )

    def test_an_api_failure_in_any_step_fails_before_the_restriction(self):
        for fail, message in (
            (("GET", "/api/users?" + sync.urllib.parse.urlencode({"search": OWNER_EMAIL})), "cannot look up the owner"),
            (("POST", "/api/user-groups"), f"cannot create the {sync.ADMINS_GROUP} group"),
            (("PUT", f"/api/user-groups/{GROUP_ID}/users"), "cannot add the owner"),
        ):
            with self.subTest(message):
                self.assert_fails_unrestricted(FakePocketId(fail=fail), message)

    def test_a_membership_write_that_drops_the_owner_fails_before_the_restriction(self):
        self.assert_fails_unrestricted(FakePocketId(drop_owner=True), "does not list the owner")

    def test_invalid_input_fails_before_any_call(self):
        for name, clients, secrets in (
            ("empty owner email", [RESTRICTED], {**SECRETS, "owner-email": "\n"}),
            ("restriction without groups", [{**RESTRICTED, "allowedUserGroups": []}], SECRETS),
            ("unknown group", [{**RESTRICTED, "allowedUserGroups": ["everyone"]}], SECRETS),
        ):
            with self.subTest(name):
                fake = FakePocketId()
                sync.call = fake
                with self.assertRaises(SystemExit):
                    sync.sync(clients, secrets.get)
                self.assertEqual(fake.calls, [])

    def test_a_group_assignment_the_client_does_not_list_fails_before_the_restriction(self):
        fake = FakePocketId(drop_groups=True, clients=["restricted"])
        with self.assertRaises(SystemExit) as raised:
            self.run_sync(fake, [RESTRICTED])
        self.assertIn(f"does not list the {sync.ADMINS_GROUP} group", str(raised.exception.code))
        self.assertEqual(fake.restricted_calls(), [])

    def test_the_declared_clients_restrict_oauth2_proxy_to_admins(self):
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "clients.json")) as handle:
            declared = json.load(handle)
        fake = FakePocketId(clients=[client["id"] for client in declared])
        sync.call = fake
        sync.sync(declared, lambda name: SECRETS["owner-email"] if name == "owner-email" else name + "-secret")
        self.assertTrue(fake.clients["oauth2-proxy"]["isGroupRestricted"])
        self.assertIn(("PUT", "/api/oidc/clients/oauth2-proxy/allowed-user-groups"), [call[:2] for call in fake.calls])

    def test_a_public_client_reads_and_writes_no_secret(self):
        fake = FakePocketId(clients=["public"])
        read = []
        sync.call = fake
        sync.sync([PUBLIC], lambda name: read.append(name) or SECRETS.get(name))
        self.assertEqual(read, ["owner-email"])
        self.assertFalse(any(path.endswith("/secrets") for _, path, _ in fake.calls))
        self.assertTrue(fake.clients["public"]["isPublic"])
        self.assertTrue(fake.clients["public"]["isGroupRestricted"])

    def test_the_declared_kubernetes_client_is_public_and_restricted_to_admins(self):
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "clients.json")) as handle:
            declared = {client["id"]: client for client in json.load(handle)}
        self.assertTrue(declared["kubernetes"]["isPublic"])
        self.assertEqual(declared["kubernetes"]["allowedUserGroups"], [sync.ADMINS_GROUP])
        for url in declared["kubernetes"]["callbackURLs"]:
            self.assertIn(urllib.parse.urlsplit(url).hostname, LOOPBACK_HOSTS)

    def test_unrestricted_clients_need_no_owner(self):
        fake = FakePocketId(users=[], clients=["open"])
        self.run_sync(fake, [OPEN])
        self.assertFalse(any(path.startswith("/api/user") for _, path, _ in fake.calls))


if __name__ == "__main__":
    unittest.main()
