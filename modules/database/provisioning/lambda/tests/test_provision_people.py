"""Offline tests for the people path: no AWS, no database.

PostgreSQL and MySQL are proven against real servers in test_real_people.py. What
is proven here: the handler's people action, the checks on the people secret,
and the MongoDB (DocumentDB) path, for which no server is available offline.
"""
import importlib
import os
import sys
import types
import unittest

MODULE = os.environ.get("LAMBDA_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.path.insert(0, MODULE)

if "boto3" not in sys.modules:
    fake = types.ModuleType("boto3")
    fake.client = lambda *a, **k: None
    sys.modules["boto3"] = fake


class FakeAdmin:
    """The admin database of a MongoDB-compatible server, holding real user records."""

    def __init__(self, client):
        self.client = client

    def command(self, name, *args, **kwargs):
        users = self.client.users
        self.client.commands.append((name, args, kwargs))
        if name == "usersInfo":
            if args:
                return {"users": [dict(users[args[0]], user=args[0])] if args[0] in users else []}
            return {"users": [dict(record, user=user) for user, record in users.items()]}
        if name == "createUser":
            users[args[0]] = {"roles": kwargs["roles"]}
        elif name == "updateUser":
            users[args[0]] = {"roles": kwargs["roles"]}
        elif name == "dropUser":
            del users[args[0]]
        return {"ok": 1}


class FakeClient:
    def __init__(self, users):
        self.users, self.commands, self.closed = users, [], False
        self.admin = FakeAdmin(self)

    def close(self):
        self.closed = True


ADMIN = {"username": "platformadmin", "password": "Adm1n-pw.x"}
SERVICE = {"db_name": "catalog", "db_user": "catalog", "db_password": "s3cret-pw.y"}
ADA = {"password": "Ada-pw.0123456789", "access": "write"}
TUNDE = {"password": "Tunde-pw.0123456789", "access": "read"}


class Base(unittest.TestCase):
    engine = "mongodb"

    def setUp(self):
        os.environ.update({
            "DATABASE_HOST": "db.internal", "DATABASE_PORT": "27017", "ADMIN_SECRET_ARN": "arn:admin",
            "ADMIN_DATABASE": "admin", "ENGINE": self.engine, "PEOPLE_SECRET_ARN": "arn:people",
            "SERVICE_SECRET_PATTERN": "core-{service}-production-secret-vault",
        })
        self.mod = importlib.reload(importlib.import_module("provision"))
        self.secrets = {
            "arn:admin": ADMIN,
            "arn:people": {"agent_ada": ADA, "agent_tunde": TUNDE},
            "core-catalog-production-secret-vault": SERVICE,
        }

        def read_secret(arn):
            if arn not in self.secrets:
                raise self.mod.ProvisioningError("no secret " + arn)
            return self.secrets[arn]

        self.mod.read_secret = read_secret

        # The server's users before the function runs: the master user, DocumentDB's
        # own serviceadmin, a service, a person who has since left, and a name
        # that merely begins like a person's.
        self.users = {
            "platformadmin": {"roles": [{"role": "root", "db": "admin"}]},
            "serviceadmin": {"roles": [{"role": "root", "db": "admin"}]},
            "catalog": {"roles": [{"role": "readWrite", "db": "catalog"}]},
            "agent_gone": {"roles": [{"role": "readAnyDatabase", "db": "admin"}]},
            "agentx": {"roles": [{"role": "readWrite", "db": "agentx"}]},
        }
        self.clients = []

        def connect_mongodb(host, port, user, password):
            client = FakeClient(self.users)
            client.opened_as = (user, password)
            self.clients.append(client)
            return client

        self.mod.connect_mongodb = connect_mongodb

    def tearDown(self):
        # Other test modules share os.environ.
        os.environ.pop("PEOPLE_SECRET_ARN", None)
        os.environ["ENGINE"] = "postgres"


class MongoDBPeople(Base):
    def test_each_person_gets_the_role_for_their_access_on_every_database(self):
        result = self.mod.handler({"action": "people"}, None)
        self.assertEqual(result["status"], "people provisioned")
        self.assertEqual(self.users["agent_ada"]["roles"], [{"role": "readWriteAnyDatabase", "db": "admin"}])
        self.assertEqual(self.users["agent_tunde"]["roles"], [{"role": "readAnyDatabase", "db": "admin"}])

    def test_a_person_no_longer_listed_is_removed_and_nobody_else(self):
        result = self.mod.handler({"action": "people"}, None)
        self.assertEqual(result["removed"], ["agent_gone"])
        for kept in ("platformadmin", "serviceadmin", "catalog", "agentx"):
            self.assertIn(kept, self.users, f"{kept} is not a person and must never be removed")

    def test_an_existing_person_gets_their_password_and_role_set_again(self):
        self.users["agent_ada"] = {"roles": [{"role": "readAnyDatabase", "db": "admin"}]}
        self.mod.handler({"action": "people"}, None)
        update = [c for c in self.clients[0].commands if c[0] == "updateUser" and c[1] == ("agent_ada",)][0]
        self.assertEqual(update[2], {"pwd": ADA["password"], "roles": [{"role": "readWriteAnyDatabase", "db": "admin"}]})

    def test_an_empty_list_removes_every_person(self):
        self.secrets["arn:people"] = {}
        self.mod.handler({"action": "people"}, None)
        self.assertEqual(sorted(u for u in self.users if u.startswith("agent_")), [])
        self.assertIn("agentx", self.users)

    def test_the_administrator_does_it_and_the_connection_is_closed(self):
        self.mod.handler({"action": "people"}, None)
        self.assertEqual(self.clients[0].opened_as, ("platformadmin", "Adm1n-pw.x"))
        self.assertTrue(all(c.closed for c in self.clients))

    def test_provisioning_a_service_also_brings_people_up_to_date(self):
        result = self.mod.handler({"service_name": "catalog"}, None)
        self.assertEqual(result["status"], "provisioned")
        self.assertEqual(result["people"], ["agent_ada", "agent_tunde"])
        self.assertIn("agent_ada", self.users)
        self.assertNotIn("agent_gone", self.users)


class PeopleAction(Base):
    engine = "postgres"

    def test_the_action_needs_the_people_secret(self):
        os.environ.pop("PEOPLE_SECRET_ARN")
        with self.assertRaises(self.mod.ProvisioningError):
            self.mod.handler({"action": "people"}, None)

    def test_without_the_people_secret_a_service_is_still_provisioned(self):
        # A function core has not given the people secret behaves as before.
        os.environ.pop("PEOPLE_SECRET_ARN")
        self.assertIsNone(self.mod.provision_people("postgres", "h", "1", ADMIN, "postgres"))

    def test_the_people_action_needs_no_service_name(self):
        calls = []
        self.mod.provision_people_postgres = lambda *a: calls.append(a) or (["catalog"], [])
        result = self.mod.handler({"action": "people"}, None)
        self.assertEqual(result["people"], ["agent_ada", "agent_tunde"])
        self.assertEqual(result["databases"], ["catalog"])
        self.assertEqual(calls[0][2:5], ("platformadmin", "Adm1n-pw.x", "admin"))

    def test_a_payload_cannot_add_people_or_change_access(self):
        seen = []
        self.mod.provision_people_postgres = lambda *a: seen.append(a[5]) or ([], [])
        self.mod.handler({"action": "people", "people": {"agent_evil": {"password": "x", "access": "write"}}}, None)
        self.assertEqual(sorted(seen[0]), ["agent_ada", "agent_tunde"], "only the secret decides who is listed")


class PeopleSecretChecks(Base):
    engine = "postgres"

    def refused(self, people):
        self.secrets["arn:people"] = people
        with self.assertRaises(self.mod.ProvisioningError):
            self.mod.read_people("arn:people")

    def test_a_name_that_is_not_agent_name(self):
        self.refused({"ada": ADA})
        self.refused({"agent_Ada": ADA})
        self.refused({"agent_ada-x": ADA})
        self.refused({"agent_group_read": ADA})

    def test_an_access_level_that_is_not_read_or_write(self):
        self.refused({"agent_ada": {"password": "Ada-pw.0", "access": "admin"}})
        self.refused({"agent_ada": {"password": "Ada-pw.0"}})

    def test_a_password_outside_cores_alphabet(self):
        self.refused({"agent_ada": {"password": "it's", "access": "read"}})
        self.refused({"agent_ada": {"password": "", "access": "read"}})

    def test_a_secret_that_is_not_an_object(self):
        self.refused(["agent_ada"])

    def test_a_good_secret_is_returned_as_given(self):
        self.secrets["arn:people"] = {"agent_ada": ADA}
        self.assertEqual(self.mod.read_people("arn:people"), {"agent_ada": ADA})


if __name__ == "__main__":
    unittest.main()
