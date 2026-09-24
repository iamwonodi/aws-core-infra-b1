"""People's logins (agent_<name>) against REAL PostgreSQL and MySQL servers.

What a person can actually do is the point, so every assertion connects AS that
person and tries: read, write, create a table, reach a database that is not a
service's. The administrator has only what RDS gives its master user: on
PostgreSQL a non-superuser with CREATEDB and CREATEROLE, on MySQL every
privilege WITH GRANT OPTION but no SUPER and no ROLE_ADMIN.

Connections go through the function's own connect functions, so they are TLS,
verified against PROVISION_TEST_TLS_CA. Runs only when the servers are given:

    PROVISION_TEST_TLS_CA=/path/ca.pem
    PROVISION_TEST_PG_HOST=127.0.0.1      PROVISION_TEST_PG_SUPERUSER / _SUPERPASSWORD
    PROVISION_TEST_MYSQL_HOST=127.0.0.1   PROVISION_TEST_MYSQL_ROOT_USER / _ROOT_PASSWORD
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

CA = os.environ.get("PROVISION_TEST_TLS_CA")
PG_HOST = os.environ.get("PROVISION_TEST_PG_HOST")
MYSQL_HOST = os.environ.get("PROVISION_TEST_MYSQL_HOST")

PASSWORD_ADA = "Ada-pw.0123456789abcdef"
PASSWORD_TUNDE = "Tunde-pw.0123456789abcdef"


def load():
    os.environ.update(DATABASE_HOST="x", DATABASE_PORT="0", ADMIN_SECRET_ARN="x", SERVICE_SECRET_PATTERN="x", CA_BUNDLE=CA)
    return importlib.reload(importlib.import_module("provision"))


# ------------------------------------------------------------------------------
# PostgreSQL
# ------------------------------------------------------------------------------


@unittest.skipUnless(PG_HOST and CA, "set PROVISION_TEST_PG_HOST and PROVISION_TEST_TLS_CA to run against a real PostgreSQL")
class RealPostgresPeople(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.prov = load()
        cls.port = int(os.environ.get("PROVISION_TEST_PG_PORT", "5432"))
        cls.suffix = uuid.uuid4().hex[:6]
        cls.admin = f"pp_admin_{cls.suffix}"
        cls.admin_password = "Adm1n-pw.x"
        cls.services = [f"pp_one_{cls.suffix}", f"pp_two_{cls.suffix}"]
        cls.ada, cls.tunde = f"agent_ada{cls.suffix}", f"agent_tunde{cls.suffix}"

        with cls.superuser("postgres") as c:
            c.cursor().execute(
                f"CREATE ROLE \"{cls.admin}\" LOGIN NOSUPERUSER CREATEDB CREATEROLE PASSWORD '{cls.admin_password}'"
            )

        # Two services, provisioned by the function; one already has a table
        # (created before people are provisioned), holding a row.
        for service in cls.services:
            cls.provision_service(service)
        with cls.connect(cls.services[0], cls.services[0], "Svc-pw.x") as c:
            cur = c.cursor()
            cur.execute("CREATE TABLE before_people (id serial PRIMARY KEY, v text)")
            cur.execute("INSERT INTO before_people (v) VALUES ('seed')")

    @classmethod
    def tearDownClass(cls):
        with cls.superuser("postgres") as c:
            cur = c.cursor()
            for database in cls.services + [f"pp_three_{cls.suffix}"]:
                cur.execute(f'DROP DATABASE IF EXISTS "{database}" WITH (FORCE)')
            for role in [cls.ada, cls.tunde] + cls.services + [f"pp_three_{cls.suffix}"]:
                cur.execute(f'DROP ROLE IF EXISTS "{role}"')
            # The groups hold default privileges only inside the dropped
            # databases, so they drop cleanly now; the administrator last.
            for role in ("agent_group_read", "agent_group_write", cls.admin):
                cur.execute(f'DROP ROLE IF EXISTS "{role}"')

    # --- connections -------------------------------------------------------

    @classmethod
    def superuser(cls, database):
        import pg8000.dbapi

        class Session:
            def __enter__(self):
                self.c = pg8000.dbapi.connect(host=PG_HOST, port=cls.port, database=database,
                                              user=os.environ["PROVISION_TEST_PG_SUPERUSER"],
                                              password=os.environ["PROVISION_TEST_PG_SUPERPASSWORD"], timeout=10)
                self.c.autocommit = True
                return self.c

            def __exit__(self, *exc):
                self.c.close()

        return Session()

    @classmethod
    def connect(cls, database, user, password):
        class Session:
            def __enter__(self):
                self.c = cls.prov.connect(PG_HOST, cls.port, user, password, database)
                return self.c

            def __exit__(self, *exc):
                self.c.close()

        return Session()

    @classmethod
    def provision_service(cls, name):
        with cls.connect("postgres", cls.admin, cls.admin_password) as c:
            cls.prov.provision(c, name, name, "Svc-pw.x", cls.admin)
        with cls.connect(name, cls.admin, cls.admin_password) as c:
            cls.prov.provision_schema(c, name, cls.admin)

    def provision_people(self, people):
        return self.prov.provision_people_postgres(PG_HOST, self.port, self.admin, self.admin_password, "postgres", people)

    def people(self, ada="write", tunde="read", with_tunde=True):
        people = {self.ada: {"password": PASSWORD_ADA, "access": ada}}
        if with_tunde:
            people[self.tunde] = {"password": PASSWORD_TUNDE, "access": tunde}
        return people

    def can(self, user, password, database, statement):
        try:
            with self.connect(database, user, password) as c:
                c.cursor().execute(statement)
            return True
        except Exception:
            return False

    # --- tests -------------------------------------------------------------

    def test_1_read_and_write_on_every_service_database(self):
        databases, removed = self.provision_people(self.people())
        self.assertEqual(sorted(databases), sorted(self.services))
        self.assertEqual(removed, [])

        one = self.services[0]
        self.assertTrue(self.can(self.tunde, PASSWORD_TUNDE, one, "SELECT v FROM before_people"), "read can read an existing table")
        # An explicit id, so the insert needs only the table privilege and not the
        # sequence's: a missing sequence grant must not hide a wrong table grant.
        self.assertFalse(self.can(self.tunde, PASSWORD_TUNDE, one, "INSERT INTO before_people (id, v) VALUES (1000, 'x')"), "read cannot write")
        self.assertFalse(self.can(self.tunde, PASSWORD_TUNDE, one, "UPDATE before_people SET v = 'x'"), "read cannot update")
        self.assertFalse(self.can(self.tunde, PASSWORD_TUNDE, one, "DELETE FROM before_people"), "read cannot delete")
        self.assertTrue(self.can(self.ada, PASSWORD_ADA, one, "INSERT INTO before_people (v) VALUES ('ada')"), "write can insert, sequence included")
        self.assertTrue(self.can(self.ada, PASSWORD_ADA, one, "UPDATE before_people SET v = 'u' WHERE v = 'ada'"), "write can update")
        self.assertTrue(self.can(self.ada, PASSWORD_ADA, one, "DELETE FROM before_people WHERE v = 'u'"), "write can delete")
        self.assertTrue(self.can(self.tunde, PASSWORD_TUNDE, self.services[1], "SELECT 1"), "every service's database, not just one")

    def test_2_nobody_changes_tables(self):
        self.provision_people(self.people())
        one = self.services[0]
        self.assertFalse(self.can(self.ada, PASSWORD_ADA, one, "CREATE TABLE mine (v int)"), "write cannot create a table")
        self.assertFalse(self.can(self.ada, PASSWORD_ADA, one, "DROP TABLE before_people"), "write cannot drop a table")
        self.assertFalse(self.can(self.ada, PASSWORD_ADA, one, "ALTER TABLE before_people ADD COLUMN w int"), "write cannot alter a table")

    def test_3_tables_created_later_are_covered(self):
        self.provision_people(self.people())
        two = self.services[1]
        with self.connect(two, two, "Svc-pw.x") as c:
            cur = c.cursor()
            cur.execute("CREATE TABLE IF NOT EXISTS after_people (id serial PRIMARY KEY, v text)")
        self.assertTrue(self.can(self.tunde, PASSWORD_TUNDE, two, "SELECT * FROM after_people"), "default privileges give read the new table")
        self.assertTrue(self.can(self.ada, PASSWORD_ADA, two, "INSERT INTO after_people (v) VALUES ('later')"), "and write too, with its sequence")

    def test_4_changing_access_takes_effect(self):
        self.provision_people(self.people(ada="read"))
        self.assertFalse(self.can(self.ada, PASSWORD_ADA, self.services[0], "INSERT INTO before_people (id, v) VALUES (1001, 'x')"), "write -> read removes writing")
        self.assertTrue(self.can(self.ada, PASSWORD_ADA, self.services[0], "SELECT 1 FROM before_people"), "and keeps reading")
        self.provision_people(self.people())

    def test_5_a_removed_person_can_no_longer_sign_in(self):
        self.provision_people(self.people())
        databases, removed = self.provision_people(self.people(with_tunde=False))
        self.assertEqual(removed, [self.tunde])
        self.assertFalse(self.can(self.tunde, PASSWORD_TUNDE, self.services[0], "SELECT 1"), "the login is gone")
        self.assertTrue(self.can(self.ada, PASSWORD_ADA, self.services[0], "SELECT 1"), "the others stay")

    def test_6_running_again_changes_nothing(self):
        self.provision_people(self.people())
        databases, removed = self.provision_people(self.people())
        self.assertEqual(removed, [])
        self.assertTrue(self.can(self.ada, PASSWORD_ADA, self.services[0], "SELECT 1"))

    def test_7_a_new_service_is_covered_when_people_run(self):
        three = f"pp_three_{self.suffix}"
        self.provision_service(three)
        databases, _ = self.provision_people(self.people())
        self.assertIn(three, databases)
        self.assertTrue(self.can(self.tunde, PASSWORD_TUNDE, three, "SELECT 1"))

    def test_8_a_database_that_is_not_a_services_is_not_reached(self):
        self.provision_people(self.people())
        self.assertFalse(self.can(self.ada, PASSWORD_ADA, "postgres", "CREATE TABLE x (v int)"), "no table in the administrator's database")
        self.assertFalse(self.can(self.ada, PASSWORD_ADA, "postgres", "CREATE ROLE sneaky"), "and no creating roles")

    def test_9_a_services_own_user_is_untouched(self):
        self.provision_people(self.people())
        self.assertTrue(self.can(self.services[0], "Svc-pw.x", self.services[0], "CREATE TABLE svc_still_owns (v int)"), "the service keeps full control")


# ------------------------------------------------------------------------------
# MySQL
# ------------------------------------------------------------------------------


@unittest.skipUnless(MYSQL_HOST and CA, "set PROVISION_TEST_MYSQL_HOST and PROVISION_TEST_TLS_CA to run against a real MySQL")
class RealMySQLPeople(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.prov = load()
        cls.port = int(os.environ.get("PROVISION_TEST_MYSQL_PORT", "3306"))
        cls.suffix = uuid.uuid4().hex[:6]
        cls.admin = f"pm_admin_{cls.suffix}"
        cls.admin_password = "Adm1n-pw.x"
        # "_" is a wildcard in a database-level grant: ab_c must not also cover abxc.
        cls.services = [f"pm_a_c{cls.suffix}", f"pm_two{cls.suffix}"]
        cls.lookalike = f"pmxa_c{cls.suffix}"  # not a service: no user of its name
        cls.ada, cls.tunde = f"agent_ada{cls.suffix}", f"agent_tunde{cls.suffix}"

        with cls.root() as c:
            cur = c.cursor()
            cur.execute(f"CREATE USER '{cls.admin}'@'%' IDENTIFIED BY '{cls.admin_password}'")
            cur.execute(
                "GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, RELOAD, PROCESS, REFERENCES, INDEX, ALTER, "
                "SHOW DATABASES, CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE, REPLICATION SLAVE, REPLICATION CLIENT, "
                "CREATE VIEW, SHOW VIEW, CREATE ROUTINE, ALTER ROUTINE, CREATE USER, EVENT, TRIGGER "
                f"ON *.* TO '{cls.admin}'@'%' WITH GRANT OPTION"
            )
            cur.execute(f"CREATE DATABASE `{cls.lookalike}`")
            cur.execute(f"CREATE TABLE `{cls.lookalike}`.t (v INT)")

        for service in cls.services:
            with cls.admin_connection() as c:
                cls.prov.provision_mysql(c, service, service, "Svc-pw.x")
        with cls.as_user(cls.services[0], "Svc-pw.x", cls.services[0]) as c:
            cur = c.cursor()
            cur.execute("CREATE TABLE before_people (id INT AUTO_INCREMENT PRIMARY KEY, v VARCHAR(20))")
            cur.execute("INSERT INTO before_people (v) VALUES ('seed')")

    @classmethod
    def tearDownClass(cls):
        with cls.root() as c:
            cur = c.cursor()
            for name in cls.services + [cls.lookalike, f"pm_three{cls.suffix}"]:
                cur.execute(f"DROP DATABASE IF EXISTS `{name}`")
                cur.execute(f"DROP USER IF EXISTS '{name}'@'%'")
            for user in (cls.ada, cls.tunde, cls.admin):
                cur.execute(f"DROP USER IF EXISTS '{user}'@'%'")

    @classmethod
    def root(cls):
        import pymysql

        return pymysql.connect(host=MYSQL_HOST, port=cls.port, user=os.environ["PROVISION_TEST_MYSQL_ROOT_USER"],
                               password=os.environ.get("PROVISION_TEST_MYSQL_ROOT_PASSWORD", ""), autocommit=True)

    @classmethod
    def as_user(cls, user, password, database=None):
        class Session:
            def __enter__(self):
                self.c = cls.prov.connect_mysql(MYSQL_HOST, cls.port, user, password, database)
                return self.c

            def __exit__(self, *exc):
                self.c.close()

        return Session()

    @classmethod
    def admin_connection(cls):
        return cls.as_user(cls.admin, cls.admin_password)

    def provision_people(self, people):
        with self.admin_connection() as c:
            return self.prov.provision_people_mysql(c, people)

    def people(self, ada="write", with_tunde=True):
        people = {self.ada: {"password": PASSWORD_ADA, "access": ada}}
        if with_tunde:
            people[self.tunde] = {"password": PASSWORD_TUNDE, "access": "read"}
        return people

    def can(self, user, password, database, statement):
        try:
            with self.as_user(user, password, database) as c:
                c.cursor().execute(statement)
            return True
        except Exception:
            return False

    def test_1_read_and_write_on_every_service_database(self):
        databases, removed = self.provision_people(self.people())
        for service in self.services:
            self.assertIn(service, databases)
        self.assertNotIn(self.lookalike, databases)
        one = self.services[0]
        self.assertTrue(self.can(self.tunde, PASSWORD_TUNDE, one, "SELECT v FROM before_people"))
        self.assertFalse(self.can(self.tunde, PASSWORD_TUNDE, one, "INSERT INTO before_people (v) VALUES ('x')"), "read cannot write")
        self.assertTrue(self.can(self.ada, PASSWORD_ADA, one, "INSERT INTO before_people (v) VALUES ('ada')"))
        self.assertTrue(self.can(self.ada, PASSWORD_ADA, one, "DELETE FROM before_people WHERE v = 'ada'"))

    def test_2_nobody_changes_tables(self):
        self.provision_people(self.people())
        self.assertFalse(self.can(self.ada, PASSWORD_ADA, self.services[0], "CREATE TABLE mine (v INT)"))
        self.assertFalse(self.can(self.ada, PASSWORD_ADA, self.services[0], "DROP TABLE before_people"))

    def test_3_tables_created_later_are_covered(self):
        self.provision_people(self.people())
        two = self.services[1]
        with self.as_user(two, "Svc-pw.x", two) as c:
            c.cursor().execute("CREATE TABLE IF NOT EXISTS after_people (v INT)")
        self.assertTrue(self.can(self.tunde, PASSWORD_TUNDE, two, "SELECT * FROM after_people"))

    def test_4_the_wildcard_does_not_reach_a_lookalike_database(self):
        self.provision_people(self.people())
        self.assertFalse(self.can(self.ada, PASSWORD_ADA, self.lookalike, "SELECT * FROM t"),
                         f"a grant on {self.services[0]} must not cover {self.lookalike}")

    def test_5_changing_access_and_removing_take_effect(self):
        self.provision_people(self.people(ada="read"))
        self.assertFalse(self.can(self.ada, PASSWORD_ADA, self.services[0], "INSERT INTO before_people (v) VALUES ('x')"))
        _, removed = self.provision_people(self.people(with_tunde=False))
        self.assertEqual(removed, [self.tunde])
        self.assertFalse(self.can(self.tunde, PASSWORD_TUNDE, self.services[0], "SELECT 1"))
        self.provision_people(self.people())

    def test_6_a_new_service_is_covered_when_people_run(self):
        three = f"pm_three{self.suffix}"
        with self.admin_connection() as c:
            self.prov.provision_mysql(c, three, three, "Svc-pw.x")
        databases, _ = self.provision_people(self.people())
        self.assertIn(three, databases)
        self.assertTrue(self.can(self.tunde, PASSWORD_TUNDE, three, "SELECT 1"))

    def test_7_no_access_to_the_system_schema(self):
        self.provision_people(self.people())
        self.assertFalse(self.can(self.ada, PASSWORD_ADA, "mysql", "SELECT authentication_string FROM mysql.user"),
                         "a person never sees password hashes")


if __name__ == "__main__":
    unittest.main()
