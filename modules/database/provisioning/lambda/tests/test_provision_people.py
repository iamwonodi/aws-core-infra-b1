"""Offline tests for people's logins at both scopes: no AWS, no database.

PostgreSQL and MySQL are proven against real servers in test_real_people.py. What
is proven here: the handler (the people action, a service's agents during its
provisioning), every check on the secrets, production's write policy, and the
MongoDB (DocumentDB) path, for which no server is available offline.
"""
import importlib
import json
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
        if name in ("createUser", "updateUser"):
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
ADA = {"password": "Ada-pw.0123456789", "access": "write"}
TUNDE = {"password": "Tunde-pw.0123456789", "access": "read"}


def service_secret(agents=None):
    secret = {"db_name": "catalog", "db_user": "catalog", "db_password": "s3cret-pw.y"}
    if agents is not None:
        secret["agents"] = json.dumps(agents)
    return secret


class Base(unittest.TestCase):
    engine = "mongodb"

    def setUp(self):
        for name in ("AGENT_WRITE", "WRITE_EXCEPTIONS"):
            os.environ.pop(name, None)
        os.environ.update({
            "DATABASE_HOST": "db.internal", "DATABASE_PORT": "27017", "ADMIN_SECRET_ARN": "arn:admin",
            "ADMIN_DATABASE": "admin", "ENGINE": self.engine, "PEOPLE_SECRET_ARN": "arn:people",
            "SERVICE_SECRET_PATTERN": "core-{service}-production-secret-vault",
        })
        self.mod = importlib.reload(importlib.import_module("provision"))
        self.secrets = {
            "arn:admin": ADMIN,
            "arn:people": {"platform.ada": ADA, "platform.tunde": TUNDE},
            "core-catalog-production-secret-vault": service_secret({"ada": ADA, "bob": TUNDE}),
        }

        def read_secret(arn):
            if arn not in self.secrets:
                raise self.mod.ProvisioningError("no secret " + arn)
            return self.secrets[arn]

        self.mod.read_secret = read_secret

        # The server's users: the master user, DocumentDB's own serviceadmin, two
        # services, a platform person and one of catalog's agents who have left,
        # another service's agent, and names that only look like logins.
        self.users = {
            "platformadmin": {"roles": [{"role": "root", "db": "admin"}]},
            "serviceadmin": {"roles": [{"role": "root", "db": "admin"}]},
            "catalog": {"roles": [{"role": "readWrite", "db": "catalog"}]},
            "orders": {"roles": [{"role": "readWrite", "db": "orders"}]},
            "platform.gone": {"roles": [{"role": "readAnyDatabase", "db": "admin"}]},
            "catalog.gone": {"roles": [{"role": "read", "db": "catalog"}]},
            "orders.ada": {"roles": [{"role": "read", "db": "orders"}]},
            "catalogx.ada": {"roles": [{"role": "read", "db": "catalogx"}]},
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
        for name in ("PEOPLE_SECRET_ARN", "AGENT_WRITE", "WRITE_EXCEPTIONS"):
            os.environ.pop(name, None)
        os.environ["ENGINE"] = "postgres"


class MongoDBPlatform(Base):
    def test_platform_people_get_roles_on_every_database(self):
        result = self.mod.handler({"action": "people"}, None)
        self.assertEqual(result["status"], "people provisioned")
        self.assertEqual(self.users["platform.ada"]["roles"], [{"role": "readWriteAnyDatabase", "db": "admin"}])
        self.assertEqual(self.users["platform.tunde"]["roles"], [{"role": "readAnyDatabase", "db": "admin"}])

    def test_only_platform_logins_no_longer_listed_are_removed(self):
        result = self.mod.handler({"action": "people"}, None)
        self.assertEqual(result["removed"], ["platform.gone"])
        for kept in ("platformadmin", "serviceadmin", "catalog", "orders", "catalog.gone", "orders.ada", "catalogx.ada"):
            self.assertIn(kept, self.users, f"{kept} is not on the platform list's scope and must never be removed by it")

    def test_an_empty_platform_list_removes_every_platform_login_and_nothing_else(self):
        self.secrets["arn:people"] = {}
        self.mod.handler({"action": "people"}, None)
        self.assertFalse([u for u in self.users if u.startswith("platform.")])
        self.assertIn("orders.ada", self.users)


class MongoDBServiceAgents(Base):
    def test_a_services_agents_get_roles_on_its_database_only(self):
        result = self.mod.handler({"service_name": "catalog"}, None)
        self.assertEqual(result["agents"], ["catalog.ada", "catalog.bob"])
        self.assertEqual(self.users["catalog.ada"]["roles"], [{"role": "readWrite", "db": "catalog"}])
        self.assertEqual(self.users["catalog.bob"]["roles"], [{"role": "read", "db": "catalog"}])

    def test_only_this_services_agents_are_removed(self):
        result = self.mod.handler({"service_name": "catalog"}, None)
        self.assertEqual(result["agents_removed"], ["catalog.gone"])
        for kept in ("orders.ada", "catalogx.ada", "catalog"):
            self.assertIn(kept, self.users)

    def test_the_platform_list_is_brought_up_to_date_too(self):
        result = self.mod.handler({"service_name": "catalog"}, None)
        self.assertEqual(result["platform_people"], ["platform.ada", "platform.tunde"])
        self.assertNotIn("platform.gone", self.users)

    def test_a_service_without_agents_has_none_and_loses_any_left(self):
        self.secrets["core-catalog-production-secret-vault"] = service_secret()
        result = self.mod.handler({"service_name": "catalog"}, None)
        self.assertEqual(result["agents"], [])
        self.assertNotIn("catalog.gone", self.users)


class ProductionWritePolicy(Base):
    def production(self, exceptions=""):
        os.environ.update(AGENT_WRITE="approved", WRITE_EXCEPTIONS=exceptions)

    def test_an_agent_asking_to_write_without_approval_stops_provisioning(self):
        self.production()
        with self.assertRaises(self.mod.ProvisioningError) as refused:
            self.mod.handler({"service_name": "catalog"}, None)
        self.assertIn("catalog.ada", str(refused.exception))
        self.assertIn("agent-write-exceptions.json", str(refused.exception))
        self.assertNotIn("catalog.ada", self.users, "nothing is created once refused")

    def test_an_approved_agent_may_write(self):
        self.production("orders.x, catalog.ada")
        self.mod.handler({"service_name": "catalog"}, None)
        self.assertEqual(self.users["catalog.ada"]["roles"], [{"role": "readWrite", "db": "catalog"}])

    def test_read_needs_no_approval(self):
        self.production()
        self.secrets["core-catalog-production-secret-vault"] = service_secret({"bob": TUNDE})
        self.mod.handler({"service_name": "catalog"}, None)
        self.assertEqual(self.users["catalog.bob"]["roles"], [{"role": "read", "db": "catalog"}])

    def test_core_platform_list_is_approved_by_definition(self):
        self.production()
        self.mod.handler({"action": "people"}, None)
        self.assertEqual(self.users["platform.ada"]["roles"], [{"role": "readWriteAnyDatabase", "db": "admin"}])

    def test_elsewhere_agents_may_write(self):
        self.mod.handler({"service_name": "catalog"}, None)
        self.assertEqual(self.users["catalog.ada"]["roles"], [{"role": "readWrite", "db": "catalog"}])


class PeopleAction(Base):
    engine = "postgres"

    def test_the_action_needs_the_people_secret(self):
        os.environ.pop("PEOPLE_SECRET_ARN")
        with self.assertRaises(self.mod.ProvisioningError):
            self.mod.handler({"action": "people"}, None)

    def test_without_the_people_secret_the_platform_step_is_skipped(self):
        os.environ.pop("PEOPLE_SECRET_ARN")
        self.assertIsNone(self.mod.provision_platform_people("postgres", "h", "1", ADMIN, "postgres"))

    def test_the_action_covers_every_service_database(self):
        calls = []
        self.mod.provision_scope_postgres = lambda *a: calls.append(a) or (["catalog", "orders"], [])
        result = self.mod.handler({"action": "people"}, None)
        self.assertEqual(result["databases"], ["catalog", "orders"])
        self.assertEqual(calls[0][2:6], ("platformadmin", "Adm1n-pw.x", "admin", "platform"))
        self.assertIsNone(calls[0][7], "no database named: every service's")

    def test_a_services_agents_are_given_its_database_only(self):
        calls = []
        self.mod.provision = lambda *a: None
        self.mod.provision_schema = lambda *a: None
        self.mod.connect = lambda *a: types.SimpleNamespace(close=lambda: None)
        self.mod.provision_scope_postgres = lambda *a: calls.append(a) or ([], [])
        self.mod.handler({"service_name": "catalog"}, None)
        scopes = {call[5]: call for call in calls}
        self.assertEqual(sorted(scopes["catalog"][6]), ["catalog.ada", "catalog.bob"])
        self.assertEqual(scopes["catalog"][7], ["catalog"])
        self.assertIsNone(scopes["platform"][7])

    def test_a_payload_cannot_add_people_or_change_access(self):
        seen = []
        self.mod.provision_scope_postgres = lambda *a: seen.append(a[6]) or ([], [])
        self.mod.handler({"action": "people", "people": {"platform.evil": {"password": "x", "access": "write"}}}, None)
        self.assertEqual(sorted(seen[0]), ["platform.ada", "platform.tunde"], "only the secret decides who is listed")


class SecretChecks(Base):
    engine = "postgres"

    def platform_refused(self, secret):
        self.secrets["arn:people"] = secret
        with self.assertRaises(self.mod.ProvisioningError):
            self.mod.read_platform_people("arn:people")

    def agents_refused(self, agents):
        with self.assertRaises(self.mod.ProvisioningError):
            self.mod.service_agents("catalog", {"agents": agents if isinstance(agents, str) else json.dumps(agents)})

    def test_platform_logins_must_be_platform_dot_name(self):
        self.platform_refused({"ada": ADA})
        self.platform_refused({"agent_ada": ADA})
        self.platform_refused({"orders.ada": ADA})
        self.platform_refused({"platform.Ada": ADA})
        self.platform_refused({"platform.group_read": ADA})
        self.platform_refused(["platform.ada"])

    def test_agent_names_access_and_passwords(self):
        self.agents_refused({"Ada": ADA})
        self.agents_refused({"ada.x": ADA})
        self.agents_refused({"group_read": ADA})
        self.agents_refused({"ada": {"password": "Ada-pw.0", "access": "admin"}})
        self.agents_refused({"ada": {"password": "it's", "access": "read"}})
        self.agents_refused("not json")

    def test_a_login_longer_than_mysqls_limit(self):
        long_service = "a" * 22
        with self.assertRaises(self.mod.ProvisioningError) as refused:
            self.mod.service_agents(long_service, {"agents": json.dumps({"abcdefghijk": ADA})})
        self.assertIn("32", str(refused.exception))
        self.assertEqual(list(self.mod.service_agents(long_service, {"agents": json.dumps({"abcdefghi": ADA})})), [long_service + ".abcdefghi"])

    def test_good_secrets(self):
        self.assertEqual(self.mod.read_platform_people("arn:people"), {"platform.ada": ADA, "platform.tunde": TUNDE})
        self.assertEqual(self.mod.service_agents("catalog", {"agents": json.dumps({"ada": ADA})}), {"catalog.ada": ADA})
        self.assertEqual(self.mod.service_agents("catalog", {}), {})


if __name__ == "__main__":
    unittest.main()
