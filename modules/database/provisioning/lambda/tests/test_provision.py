"""Offline tests for the provisioning Lambda: no AWS, no database."""
import importlib, os, sys, types, unittest

MODULE = os.environ.get("LAMBDA_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.path.insert(0, MODULE)

# The Lambda runtime provides boto3; the tests do not need it and must not require it.
if "boto3" not in sys.modules:
    fake = types.ModuleType("boto3")
    fake.client = lambda *a, **k: None
    sys.modules["boto3"] = fake

class FakeCursor:
    def __init__(self, conn): self.conn = conn; self.result = None
    def execute(self, sql, params=None):
        self.conn.statements.append((sql, params))
        key = None
        if "pg_roles" in sql: key = "role"
        elif "pg_database" in sql: key = "database"
        self.result = None if key and key in self.conn.missing else (1,)
    def fetchone(self): return self.result
    def close(self): pass

class FakeConnection:
    def __init__(self, missing=()): self.statements = []; self.missing = set(missing); self.autocommit = False; self.closed = False
    def cursor(self): return FakeCursor(self)
    def close(self): self.closed = True

SECRETS = {
    "arn:admin": {"username": "coreadmin", "password": "Adm1n-pw.x"},
    "core-auth-production-secret-vault": {"db_name": "auth", "db_user": "auth", "db_password": "s3cret-pw.y"},
}

class Base(unittest.TestCase):
    def setUp(self):
        os.environ.update({
            "DATABASE_HOST": "db.internal", "DATABASE_PORT": "5432",
            "ADMIN_SECRET_ARN": "arn:admin", "ADMIN_DATABASE": "postgres",
            "SERVICE_SECRET_PATTERN": "core-{service}-production-secret-vault",
        })
        self.mod = importlib.reload(importlib.import_module("provision"))
        # These tests are about the service's own database and user. The people
        # steps that follow (its agents, the platform list) are proven in
        # test_provision_people.py and, against real servers, test_real_people.py.
        self.mod.provision_scope = lambda *a, **k: {"people": [], "removed": []}
        self.mod.provision_platform_people = lambda *a, **k: None
        self.connections = []
        self.mod.read_secret = lambda arn: dict(SECRETS[arn]) if arn in SECRETS else (_ for _ in ()).throw(self.mod.ProvisioningError("no secret " + arn))
        def connect(host, port, user, password, database):
            c = FakeConnection(missing=getattr(self, "missing", ()))
            c.opened_as = (user, password, database); self.connections.append(c); return c
        self.mod.connect = connect
    def sql(self):
        return [s for c in self.connections for s, _ in c.statements]

class Provisioning(Base):
    def test_creates_role_and_database_when_absent(self):
        self.missing = ("role", "database")
        result = self.mod.handler({"service_name": "auth"}, None)
        sql = " | ".join(self.sql())
        self.assertIn('CREATE ROLE "auth" LOGIN', sql)
        self.assertIn('CREATE DATABASE "auth" OWNER "auth"', sql)
        self.assertEqual(result["status"], "provisioned")

    def test_running_again_creates_nothing_but_still_sets_the_password(self):
        self.missing = ()
        self.mod.handler({"service_name": "auth"}, None)
        sql = " | ".join(self.sql())
        self.assertNotIn("CREATE ROLE", sql)
        self.assertNotIn("CREATE DATABASE", sql)
        self.assertIn("ALTER ROLE \"auth\" WITH LOGIN PASSWORD 's3cret-pw.y'", sql)

    def test_the_administrator_becomes_a_member_of_the_role_before_creating_its_database(self):
        # RDS's administrator is not a superuser, and PostgreSQL refuses to create a
        # database owned by a role its creator cannot become. Found on a real
        # PostgreSQL; the fake cursor cannot say so, so the ORDER is asserted here
        # and test_real_postgres.py proves it against the real thing.
        self.missing = ("role", "database")
        self.mod.handler({"service_name": "auth"}, None)
        sql = self.sql()
        grant = next(i for i, s in enumerate(sql) if s == 'GRANT "auth" TO "coreadmin"')
        create = next(i for i, s in enumerate(sql) if s.startswith("CREATE DATABASE"))
        self.assertLess(grant, create)

    def test_public_cannot_reach_the_database_or_its_schema(self):
        self.mod.handler({"service_name": "auth"}, None)
        sql = " | ".join(self.sql())
        self.assertIn('REVOKE ALL ON DATABASE "auth" FROM PUBLIC', sql)
        self.assertIn("REVOKE ALL ON SCHEMA public FROM PUBLIC", sql)

    def test_connects_as_the_administrator_only(self):
        self.mod.handler({"service_name": "auth"}, None)
        for c in self.connections:
            self.assertEqual(c.opened_as[0], "coreadmin")

    def test_the_schema_is_done_inside_the_services_own_database(self):
        self.mod.handler({"service_name": "auth"}, None)
        self.assertEqual([c.opened_as[2] for c in self.connections], ["postgres", "auth"])

    def test_every_connection_is_closed(self):
        self.mod.handler({"service_name": "auth"}, None)
        self.assertTrue(all(c.closed for c in self.connections))

    def test_autocommit_is_on_is_not_assumed(self):
        # CREATE DATABASE cannot run in a transaction; the real connect() sets it.
        with open(os.path.join(MODULE, "provision.py")) as source:
            self.assertIn("autocommit", source.read())

class Refusals(Base):
    def run_and_fail(self, event):
        with self.assertRaises(self.mod.ProvisioningError):
            self.mod.handler(event, None)
        self.assertEqual(self.sql(), [], "nothing must reach the database")

    def test_a_service_name_that_is_not_one(self):
        for bad in ["", "Bad", "a", "../other", "auth; DROP DATABASE x", "auth_1"]:
            with self.subTest(name=bad):
                self.connections = []
                self.run_and_fail({"service_name": bad})

    def test_an_empty_event(self):
        self.run_and_fail({})
        self.connections = []
        self.run_and_fail(None)

    def test_an_administrator_name_that_is_not_an_identifier(self):
        # The administrator's name comes from a secret and is put in SQL, so it is
        # checked like every other name, before any statement runs.
        self.mod.read_secret = lambda arn: {"username": 'admin"; DROP ROLE x; --', "password": "Adm1n-pw.x"} if arn == "arn:admin" else dict(SECRETS[arn])
        self.run_and_fail({"service_name": "auth"})

    def test_a_service_with_no_secret(self):
        self.run_and_fail({"service_name": "billing"})

    def test_a_secret_missing_a_field(self):
        for field in ("db_name", "db_user", "db_password"):
            with self.subTest(field=field):
                self.connections = []
                broken = dict(SECRETS["core-auth-production-secret-vault"]); broken[field] = ""
                self.mod.read_secret = lambda arn, b=broken: dict(SECRETS["arn:admin"]) if arn == "arn:admin" else b
                self.run_and_fail({"service_name": "auth"})

    def test_a_database_name_that_is_not_an_identifier(self):
        broken = {"db_name": "auth; DROP DATABASE core", "db_user": "auth", "db_password": "pw"}
        self.mod.read_secret = lambda arn, b=broken: dict(SECRETS["arn:admin"]) if arn == "arn:admin" else b
        with self.assertRaises(self.mod.ProvisioningError):
            self.mod.handler({"service_name": "auth"}, None)

    def test_a_password_with_a_quote(self):
        broken = {"db_name": "auth", "db_user": "auth", "db_password": "pw'; DROP DATABASE core; --"}
        self.mod.read_secret = lambda arn, b=broken: dict(SECRETS["arn:admin"]) if arn == "arn:admin" else b
        with self.assertRaises(self.mod.ProvisioningError):
            self.mod.handler({"service_name": "auth"}, None)

class CallerCannotChooseTargets(Base):
    def test_the_secret_is_derived_from_the_service_name_not_the_payload(self):
        asked = []
        self.mod.read_secret = lambda arn: (asked.append(arn), dict(SECRETS.get(arn, SECRETS["core-auth-production-secret-vault"])))[1]
        self.mod.handler({"service_name": "auth", "secret_arn": "arn:someone-elses"}, None)
        self.assertNotIn("arn:someone-elses", asked)
        self.assertIn("core-auth-production-secret-vault", asked)

    def test_extra_payload_fields_are_ignored(self):
        self.mod.handler({"service_name": "auth", "db_name": "core", "sql": "DROP DATABASE core"}, None)
        sql = " | ".join(self.sql())
        self.assertNotIn("DROP", sql)
        self.assertIn('"auth"', sql)

class VendoredDriver(unittest.TestCase):
    """Every package the driver imports must come from vendor/, not the host.

    The Lambda runtime happens to ship some of them (boto3 depends on
    python-dateutil and six), so a missing vendored package can pass on a
    developer's machine and in AWS alike -- until AWS changes its runtime.
    """

    def test_the_driver_and_its_dependencies_load_from_vendor(self):
        import asn1crypto
        import dateutil
        import pg8000
        import scramp
        import six

        vendor = os.path.realpath(os.path.join(MODULE, "vendor"))
        for module in (pg8000, scramp, asn1crypto, dateutil, six):
            with self.subTest(module=module.__name__):
                self.assertTrue(
                    os.path.realpath(module.__file__).startswith(vendor),
                    f"{module.__name__} was imported from {module.__file__}, not from vendor/",
                )


if __name__ == "__main__":
    unittest.main(verbosity=1)
