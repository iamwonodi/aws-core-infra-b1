"""The provisioning SQL against a REAL PostgreSQL, as a non-superuser administrator.

Why this exists: the other tests use a fake cursor, which cannot show what
PostgreSQL itself will refuse. RDS's administrator is not a superuser, and the
first version of this function failed on exactly that ("must be able to SET
ROLE") while every fake-cursor test passed.

It runs only when PROVISION_TEST_PG_HOST is set, with a superuser it may use to
create a throwaway non-superuser administrator, which is the permission model RDS
gives its master user:

    PROVISION_TEST_PG_HOST=127.0.0.1
    PROVISION_TEST_PG_PORT=5432
    PROVISION_TEST_PG_SUPERUSER=postgres
    PROVISION_TEST_PG_SUPERPASSWORD=...

TLS is not exercised here; that is the connection's business, not the SQL's.
"""
import importlib
import os
import sys
import types
import unittest
import uuid

MODULE = os.environ.get("LAMBDA_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.path.insert(0, MODULE)

if "boto3" not in sys.modules:
    stub = types.ModuleType("boto3")
    stub.client = lambda *a, **k: None
    sys.modules["boto3"] = stub

HOST = os.environ.get("PROVISION_TEST_PG_HOST")


@unittest.skipUnless(HOST, "set PROVISION_TEST_PG_HOST to run the provisioning SQL against a real PostgreSQL")
class RealPostgres(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        os.environ.update(DATABASE_HOST="x", DATABASE_PORT="5432", ADMIN_SECRET_ARN="x", SERVICE_SECRET_PATTERN="x")
        cls.prov = importlib.import_module("provision")
        import pg8000.dbapi

        cls.pg = pg8000.dbapi
        cls.port = int(os.environ.get("PROVISION_TEST_PG_PORT", "5432"))
        cls.suffix = uuid.uuid4().hex[:8]
        cls.admin = f"pt_admin_{cls.suffix}"
        cls.admin_password = "Adm1n-pw.x"
        cls.created_roles, cls.created_databases = [], []

        with cls.connect("postgres", os.environ["PROVISION_TEST_PG_SUPERUSER"], os.environ["PROVISION_TEST_PG_SUPERPASSWORD"]) as c:
            c.cursor().execute(
                f'CREATE ROLE "{cls.admin}" LOGIN NOSUPERUSER CREATEDB CREATEROLE PASSWORD \'{cls.admin_password}\''
            )

    @classmethod
    def tearDownClass(cls):
        with cls.connect("postgres", os.environ["PROVISION_TEST_PG_SUPERUSER"], os.environ["PROVISION_TEST_PG_SUPERPASSWORD"]) as c:
            cur = c.cursor()
            for database in cls.created_databases:
                cur.execute(f'DROP DATABASE IF EXISTS "{database}" WITH (FORCE)')
            for role in cls.created_roles + [cls.admin]:
                cur.execute(f'DROP ROLE IF EXISTS "{role}"')

    @classmethod
    def connect(cls, database, user, password):
        class Session:
            def __enter__(self_inner):
                self_inner.connection = cls.pg.connect(host=HOST, port=cls.port, user=user, password=password, database=database, timeout=10)
                self_inner.connection.autocommit = True
                return self_inner.connection

            def __exit__(self_inner, *exc):
                self_inner.connection.close()

        return Session()

    def provision(self, service, password="s3cret-pw.y"):
        name = f"pt_{service}_{self.suffix}"
        if name not in self.created_roles:
            self.created_roles.append(name)
            self.created_databases.append(name)
        with self.connect("postgres", self.admin, self.admin_password) as c:
            self.prov.provision(c, name, name, password, self.admin)
        with self.connect(name, self.admin, self.admin_password) as c:
            self.prov.provision_schema(c, name, self.admin)
        return name

    def test_the_administrator_is_not_a_superuser_as_on_rds(self):
        with self.connect("postgres", self.admin, self.admin_password) as c:
            cur = c.cursor()
            cur.execute("SELECT rolsuper FROM pg_roles WHERE rolname = current_user")
            self.assertFalse(cur.fetchone()[0], "the test must run with RDS's permission model, not a superuser's")

    def test_provisions_a_database_the_service_owns_and_can_use(self):
        name = self.provision("owner")
        with self.connect(name, name, "s3cret-pw.y") as c:
            cur = c.cursor()
            cur.execute("CREATE TABLE polls (id serial PRIMARY KEY)")  # needs the public schema
            cur.execute("INSERT INTO polls DEFAULT VALUES")
            cur.execute("SELECT count(*) FROM polls")
            self.assertEqual(cur.fetchone()[0], 1)
            cur.execute("SELECT pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname = current_database()")
            self.assertEqual(cur.fetchone()[0], name)

    def test_running_it_again_succeeds_and_keeps_the_data(self):
        name = self.provision("again")
        with self.connect(name, name, "s3cret-pw.y") as c:
            c.cursor().execute("CREATE TABLE keep (id int)")
        self.provision("again")  # every apply runs it
        with self.connect(name, name, "s3cret-pw.y") as c:
            c.cursor().execute("SELECT 1 FROM keep")  # still there

    def test_a_rotated_password_takes_effect_and_the_old_one_stops_working(self):
        name = self.provision("rotate", password="first-pw.aaa")
        self.provision("rotate", password="second-pw.bbb")
        with self.connect(name, name, "second-pw.bbb"):
            pass
        with self.assertRaises(Exception):
            with self.connect(name, name, "first-pw.aaa"):
                pass

    def test_one_service_cannot_reach_another_services_database(self):
        first = self.provision("alpha", password="alpha-pw.aaa")
        second = self.provision("beta", password="beta-pw.bbb")
        with self.assertRaises(Exception):
            with self.connect(second, first, "alpha-pw.aaa"):
                pass

    def test_a_service_cannot_reach_the_administrators_database_objects_it_was_not_given(self):
        name = self.provision("scoped")
        with self.connect(name, name, "s3cret-pw.y") as c:
            cur = c.cursor()
            cur.execute("SELECT rolcreaterole, rolcreatedb, rolsuper FROM pg_roles WHERE rolname = current_user")
            self.assertEqual(list(cur.fetchone()), [False, False, False], "a service's user must hold no administrative attribute")


if __name__ == "__main__":
    unittest.main()
