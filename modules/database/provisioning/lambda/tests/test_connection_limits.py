"""Offline tests for connection limits: no AWS, no database.

What is proven here: which number each login gets (the default, an approved
exception, the per-person cap), that the number is set on every run like the
password, that nothing is set when the limits are unset, and that a bad number
stops the run before any statement reaches the engine. That the engines then
refuse the connection over the cap is proven against real servers in
test_real_postgres.py, test_real_mysql.py and test_real_people.py.
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

LIMIT_VARIABLES = ("SERVICE_CONNECTION_LIMIT", "PERSON_CONNECTION_LIMIT", "SERVICE_CONNECTION_EXCEPTIONS")


class FakeCursor:
    def __init__(self, conn):
        self.conn, self.rows = conn, []

    def execute(self, sql, params=None):
        self.conn.statements.append(sql)
        # Every role and database already exists; no people logins exist yet.
        self.rows = [] if "starts_with" in sql or "mysql.user" in sql or "SCHEMATA" in sql else [(1,)]

    def fetchone(self):
        return self.rows[0] if self.rows else None

    def fetchall(self):
        return []

    def close(self):
        pass


class FakeConnection:
    def __init__(self):
        self.statements, self.closed, self.autocommit = [], False, False

    def cursor(self):
        return FakeCursor(self)

    def close(self):
        self.closed = True


SECRETS = {
    "arn:admin": {"username": "platformadmin", "password": "Adm1n-pw.x"},
    "arn:people": {"platform.ada": {"password": "Ada-pw.0123456789", "access": "write"}},
    "core-orders-production-secret-vault": {
        "db_name": "orders",
        "db_user": "orders",
        "db_password": "s3cret-pw.y",
        "agents": json.dumps({"bob": {"password": "Bob-pw.0123456789", "access": "read"}}),
    },
    "core-auth-production-secret-vault": {"db_name": "auth", "db_user": "auth", "db_password": "s3cret-pw.z"},
}


class Base(unittest.TestCase):
    engine = "postgres"

    def setUp(self):
        for name in LIMIT_VARIABLES + ("AGENT_WRITE", "WRITE_EXCEPTIONS"):
            os.environ.pop(name, None)
        os.environ.update({
            "DATABASE_HOST": "db.internal",
            "DATABASE_PORT": "5432",
            "ADMIN_SECRET_ARN": "arn:admin",
            "ADMIN_DATABASE": "postgres" if self.engine == "postgres" else "platform",
            "ENGINE": self.engine,
            "SERVICE_SECRET_PATTERN": "core-{service}-production-secret-vault",
            "PEOPLE_SECRET_ARN": "arn:people",
        })
        self.mod = importlib.reload(importlib.import_module("provision"))
        self.connections = []
        self.mod.read_secret = lambda arn: json.loads(json.dumps(SECRETS[arn]))

        def connect(*args, **kwargs):
            connection = FakeConnection()
            self.connections.append(connection)
            return connection

        self.mod.connect = connect
        self.mod.connect_mysql = connect

    def tearDown(self):
        for name in LIMIT_VARIABLES + ("PEOPLE_SECRET_ARN",):
            os.environ.pop(name, None)
        os.environ["ENGINE"] = "postgres"
        os.environ["ADMIN_DATABASE"] = "postgres"

    def limits(self, service="20", person="5", exceptions=None):
        os.environ["SERVICE_CONNECTION_LIMIT"] = service
        os.environ["PERSON_CONNECTION_LIMIT"] = person
        os.environ["SERVICE_CONNECTION_EXCEPTIONS"] = json.dumps(exceptions or {})

    def sql(self):
        return [statement for connection in self.connections for statement in connection.statements]

    def joined(self):
        return " | ".join(self.sql())


class PostgreSQL(Base):
    engine = "postgres"

    def test_the_service_gets_the_default(self):
        self.limits(service="20")
        self.mod.handler({"service_name": "orders"}, None)
        self.assertIn('ALTER ROLE "orders" CONNECTION LIMIT 20', self.sql())

    def test_an_approved_exception_replaces_the_default_for_that_service_only(self):
        self.limits(service="20", exceptions={"orders": 80})
        self.mod.handler({"service_name": "orders"}, None)
        self.assertIn('ALTER ROLE "orders" CONNECTION LIMIT 80', self.sql())
        self.assertNotIn('ALTER ROLE "orders" CONNECTION LIMIT 20', self.sql())

        self.connections.clear()
        self.mod.handler({"service_name": "auth"}, None)
        self.assertIn('ALTER ROLE "auth" CONNECTION LIMIT 20', self.sql())

    def test_the_limit_is_set_on_every_run_after_the_password(self):
        self.limits(service="20")
        self.mod.handler({"service_name": "orders"}, None)
        self.mod.handler({"service_name": "orders"}, None)
        sql = self.sql()
        self.assertEqual(sql.count('ALTER ROLE "orders" CONNECTION LIMIT 20'), 2)
        self.assertLess(
            sql.index("ALTER ROLE \"orders\" WITH LOGIN PASSWORD 's3cret-pw.y'"),
            sql.index('ALTER ROLE "orders" CONNECTION LIMIT 20'),
        )

    def test_every_person_gets_the_person_cap_at_both_scopes(self):
        self.limits(person="5")
        self.mod.handler({"service_name": "orders"}, None)
        self.assertIn('ALTER ROLE "orders.bob" CONNECTION LIMIT 5', self.sql())
        self.assertIn('ALTER ROLE "platform.ada" CONNECTION LIMIT 5', self.sql())

    def test_the_people_action_caps_the_platform_list(self):
        self.limits(person="3")
        self.mod.handler({"action": "people"}, None)
        self.assertIn('ALTER ROLE "platform.ada" CONNECTION LIMIT 3', self.sql())

    def test_the_groups_and_the_administrator_are_never_capped(self):
        self.limits()
        self.mod.handler({"service_name": "orders"}, None)
        capped = [s for s in self.sql() if "CONNECTION LIMIT" in s]
        self.assertTrue(capped)
        for statement in capped:
            self.assertNotIn("group_", statement)
            self.assertNotIn("platformadmin", statement)

    def test_unset_limits_set_nothing(self):
        self.mod.handler({"service_name": "orders"}, None)
        self.assertNotIn("CONNECTION LIMIT", self.joined())


class MySQL(Base):
    engine = "mysql"

    def test_the_service_gets_the_default(self):
        self.limits(service="20")
        self.mod.handler({"service_name": "orders"}, None)
        self.assertIn("ALTER USER 'orders'@'%' WITH MAX_USER_CONNECTIONS 20", self.sql())

    def test_an_approved_exception(self):
        self.limits(service="20", exceptions={"orders": 80})
        self.mod.handler({"service_name": "orders"}, None)
        self.assertIn("ALTER USER 'orders'@'%' WITH MAX_USER_CONNECTIONS 80", self.sql())

    def test_every_person_gets_the_person_cap_at_both_scopes(self):
        self.limits(person="5")
        self.mod.handler({"service_name": "orders"}, None)
        self.assertIn("ALTER USER 'orders.bob'@'%' WITH MAX_USER_CONNECTIONS 5", self.sql())
        self.assertIn("ALTER USER 'platform.ada'@'%' WITH MAX_USER_CONNECTIONS 5", self.sql())

    def test_unset_limits_set_nothing(self):
        self.mod.handler({"service_name": "orders"}, None)
        self.assertNotIn("MAX_USER_CONNECTIONS", self.joined())


class DocumentDB(Base):
    engine = "mongodb"

    def test_documentdb_has_no_per_login_limit_and_is_not_asked_for_one(self):
        self.limits()
        commands = []

        class Admin:
            def command(self, name, *args, **kwargs):
                commands.append((name, args, kwargs))
                return {"users": [], "ok": 1}

        class Client:
            admin = Admin()

            def close(self):
                pass

        self.mod.connect_mongodb = lambda *a, **k: Client()
        self.mod.handler({"service_name": "orders"}, None)
        self.assertTrue(commands)
        for _, _, kwargs in commands:
            self.assertFalse(any("conn" in key.lower() for key in kwargs))


class Refusals(Base):
    engine = "postgres"

    def refused(self, event=None):
        with self.assertRaises(self.mod.ProvisioningError):
            self.mod.handler(event or {"service_name": "orders"}, None)
        self.assertEqual(self.sql(), [], "nothing may reach the engine before the numbers are checked")

    def test_zero_would_lock_the_login_out(self):
        self.limits(service="0")
        self.refused()

    def test_a_negative_number(self):
        self.limits(service="-1")
        self.refused()

    def test_not_a_number(self):
        self.limits(service="20; DROP ROLE x")
        self.refused()

    def test_above_the_maximum(self):
        self.limits(service="10001")
        self.refused()

    def test_a_bad_person_cap_stops_a_service_run(self):
        self.limits(person="0")
        self.refused()

    def test_a_bad_person_cap_stops_the_people_action(self):
        self.limits(person="many")
        self.refused({"action": "people"})

    def test_a_bad_exception(self):
        self.limits(exceptions={"orders": 0})
        self.refused()

    def test_a_fractional_exception(self):
        self.limits(exceptions={"orders": 2.5})
        self.refused()

    def test_exceptions_that_are_not_json(self):
        self.limits()
        os.environ["SERVICE_CONNECTION_EXCEPTIONS"] = "orders=80"
        self.refused()

    def test_exceptions_that_are_not_an_object(self):
        self.limits()
        os.environ["SERVICE_CONNECTION_EXCEPTIONS"] = "[80]"
        self.refused()

    def test_another_services_bad_exception_does_not_stop_this_one(self):
        self.limits(exceptions={"billing": 0})
        self.mod.handler({"service_name": "orders"}, None)
        self.assertIn('ALTER ROLE "orders" CONNECTION LIMIT 20', self.sql())


if __name__ == "__main__":
    unittest.main()
