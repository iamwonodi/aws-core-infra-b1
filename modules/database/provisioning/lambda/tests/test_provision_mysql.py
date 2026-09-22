"""Offline tests for the provisioning Lambda's MySQL path: no AWS, no database."""
import importlib, os, sys, types, unittest

MODULE = os.environ.get("LAMBDA_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.path.insert(0, MODULE)

if "boto3" not in sys.modules:
    fake = types.ModuleType("boto3")
    fake.client = lambda *a, **k: None
    sys.modules["boto3"] = fake


class FakeCursor:
    def __init__(self, conn): self.conn = conn
    def execute(self, sql, params=None): self.conn.statements.append(sql)
    def close(self): pass


class FakeConnection:
    def __init__(self): self.statements = []; self.closed = False
    def cursor(self): return FakeCursor(self)
    def close(self): self.closed = True


SECRETS = {
    "arn:admin": {"username": "platform_admin", "password": "Adm1n-pw.x"},
    "core-ab-c-production-secret-vault": {"db_name": "ab_c", "db_user": "ab_c", "db_password": "s3cret-pw.y"},
    "core-evil-production-secret-vault": {"db_name": "x`; DROP DATABASE y; --", "db_user": "evil", "db_password": "p"},
    "core-quote-production-secret-vault": {"db_name": "quote", "db_user": "quote", "db_password": "it's"},
}


class MySQL(unittest.TestCase):
    def setUp(self):
        os.environ.update({
            "DATABASE_HOST": "mysql.internal", "DATABASE_PORT": "3306",
            "ADMIN_SECRET_ARN": "arn:admin", "ADMIN_DATABASE": "platform", "ENGINE": "mysql",
            "SERVICE_SECRET_PATTERN": "core-{service}-production-secret-vault",
        })
        self.mod = importlib.reload(importlib.import_module("provision"))
        self.connections = []
        self.mod.read_secret = lambda arn: dict(SECRETS[arn]) if arn in SECRETS else (_ for _ in ()).throw(self.mod.ProvisioningError("no secret " + arn))

        def connect(host, port, user, password, database):
            c = FakeConnection(); c.opened_as = (host, port, user, password, database)
            self.connections.append(c); return c
        self.mod.connect_mysql = connect
        self.mod.connect = lambda *a, **k: self.fail("the PostgreSQL connection must not be used for MySQL")

    def sql(self):
        return [s for c in self.connections for s in c.statements]

    def tearDown(self):
        os.environ["ENGINE"] = "postgres"

    def test_provisions_through_one_connection_as_the_administrator(self):
        result = self.mod.handler({"service_name": "ab-c"}, None)
        self.assertEqual(result["status"], "provisioned")
        self.assertEqual(len(self.connections), 1)
        self.assertEqual(self.connections[0].opened_as, ("mysql.internal", "3306", "platform_admin", "Adm1n-pw.x", "platform"))
        self.assertTrue(self.connections[0].closed)

    def test_creates_the_database_and_user_if_missing(self):
        self.mod.handler({"service_name": "ab-c"}, None)
        sql = " | ".join(self.sql())
        self.assertIn("CREATE DATABASE IF NOT EXISTS `ab_c` CHARACTER SET utf8mb4", sql)
        self.assertIn("CREATE USER IF NOT EXISTS 'ab_c'@'%' IDENTIFIED BY 's3cret-pw.y'", sql)

    def test_sets_the_password_every_time(self):
        self.mod.handler({"service_name": "ab-c"}, None)
        self.assertIn("ALTER USER 'ab_c'@'%' IDENTIFIED BY 's3cret-pw.y'", self.sql())

    def test_the_grant_escapes_underscores_so_it_names_one_database(self):
        self.mod.handler({"service_name": "ab-c"}, None)
        self.assertIn("GRANT ALL PRIVILEGES ON `ab\\_c`.* TO 'ab_c'@'%'", self.sql())
        self.assertFalse(any("ON `ab_c`.*" in s for s in self.sql()))

    def test_never_grants_beyond_the_database(self):
        self.mod.handler({"service_name": "ab-c"}, None)
        for statement in self.sql():
            self.assertNotIn("*.*", statement)
            self.assertNotIn("WITH GRANT OPTION", statement)
            self.assertNotIn("DROP", statement)

    def test_an_identifier_that_is_not_plain_is_refused_before_any_sql(self):
        with self.assertRaises(self.mod.ProvisioningError):
            self.mod.handler({"service_name": "evil"}, None)
        self.assertEqual(self.sql(), [])

    def test_a_password_with_a_quote_is_refused_before_any_sql(self):
        with self.assertRaises(self.mod.ProvisioningError):
            self.mod.handler({"service_name": "quote"}, None)
        self.assertEqual(self.sql(), [])

    def test_an_engine_it_does_not_speak_is_refused(self):
        os.environ["ENGINE"] = "redis"
        with self.assertRaises(self.mod.ProvisioningError):
            self.mod.handler({"service_name": "ab-c"}, None)
        self.assertEqual(self.connections, [])


if __name__ == "__main__":
    unittest.main()
