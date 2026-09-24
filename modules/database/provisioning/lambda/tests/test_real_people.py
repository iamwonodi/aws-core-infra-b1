"""People's logins against REAL PostgreSQL and MySQL servers, at both scopes.

    platform.<name>   core's platform list: every service's database
    <service>.<name>  a service's agents: that service's database only

What a person can actually do is the point, so every assertion connects AS that
person and tries: read, write, create a table, reach another service's database,
sign in after removal. The administrator has only what RDS gives its master
user: on PostgreSQL a non-superuser with CREATEDB and CREATEROLE, on MySQL every
privilege WITH GRANT OPTION but no SUPER and no ROLE_ADMIN.

Two services are named so that one's name, read as a LIKE pattern, matches the
other's (a_c and axc differ only where "_" is a wildcard): removing the first's
agents must never reach the second's.

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

PW = {"ada": "Ada-pw.0123456789abc", "tunde": "Tunde-pw.0123456789", "bob": "Bob-pw.0123456789ab"}
SVC_PW = "Svc-pw.x"


def load():
    os.environ.update(DATABASE_HOST="x", DATABASE_PORT="0", ADMIN_SECRET_ARN="x", SERVICE_SECRET_PATTERN="x", CA_BUNDLE=CA)
    os.environ.pop("AGENT_WRITE", None)
    return importlib.reload(importlib.import_module("provision"))


def listed(scope, **access):
    return {f"{scope}.{name}": {"password": PW[name], "access": level} for name, level in access.items()}


class Scenarios:
    """The same scenarios for each engine. Subclasses give connections and the calls."""

    def test_1_platform_people_reach_every_service_database(self):
        self.platform(ada="write", tunde="read")
        one, two = self.services[0], self.services[1]
        self.assertTrue(self.can("platform.tunde", PW["tunde"], one, "SELECT v FROM before_people"), "read reads")
        self.assertFalse(self.can("platform.tunde", PW["tunde"], one, "INSERT INTO before_people (id, v) VALUES (1000, 'x')"), "read cannot insert")
        self.assertFalse(self.can("platform.tunde", PW["tunde"], one, "DELETE FROM before_people"), "read cannot delete")
        self.assertTrue(self.can("platform.ada", PW["ada"], one, "INSERT INTO before_people (v) VALUES ('ada')"), "write inserts")
        self.assertTrue(self.can("platform.ada", PW["ada"], one, "DELETE FROM before_people WHERE v = 'ada'"), "write deletes")
        self.assertTrue(self.can("platform.tunde", PW["tunde"], two, "SELECT 1"), "every service's database")
        self.assertFalse(self.can("platform.ada", PW["ada"], one, "CREATE TABLE mine (v INT)"), "nobody creates tables")

    def test_2_a_services_agents_reach_that_service_only(self):
        one, two = self.services[0], self.services[1]
        self.agents(one, ada="write", bob="read")
        self.agents(two, ada="read")
        self.assertTrue(self.can(f"{one}.ada", PW["ada"], one, "INSERT INTO before_people (v) VALUES ('a1')"), "write on its own service")
        self.assertTrue(self.can(f"{one}.bob", PW["bob"], one, "SELECT v FROM before_people"), "read on its own service")
        self.assertFalse(self.can(f"{one}.bob", PW["bob"], one, "INSERT INTO before_people (id, v) VALUES (1001, 'x')"), "read cannot write")
        self.assertFalse(self.can(f"{one}.ada", PW["ada"], two, "SELECT 1"), "an agent never reaches another service's database")
        self.assertFalse(self.can(f"{two}.ada", PW["ada"], one, "SELECT 1"), "nor the other way round")
        self.assertFalse(self.can(f"{one}.ada", PW["ada"], one, "CREATE TABLE mine (v INT)"), "agents create no tables")

    def test_3_tables_created_later_are_covered_at_both_scopes(self):
        one = self.services[0]
        self.platform(tunde="read")
        self.agents(one, bob="read", ada="write")
        self.as_service(one, "CREATE TABLE IF NOT EXISTS after_people (id INT PRIMARY KEY, v VARCHAR(20))")
        self.assertTrue(self.can("platform.tunde", PW["tunde"], one, "SELECT * FROM after_people"), "platform, a later table")
        self.assertTrue(self.can(f"{one}.bob", PW["bob"], one, "SELECT * FROM after_people"), "agent, a later table")
        self.assertTrue(self.can(f"{one}.ada", PW["ada"], one, "INSERT INTO after_people (id, v) VALUES (1, 'x')"), "and writing it")

    def test_4_changing_access_and_removing_take_effect(self):
        one = self.services[0]
        self.agents(one, ada="write", bob="read")
        self.agents(one, ada="read")
        self.assertFalse(self.can(f"{one}.ada", PW["ada"], one, "INSERT INTO before_people (id, v) VALUES (1002, 'x')"), "write -> read")
        self.assertFalse(self.can(f"{one}.bob", PW["bob"], one, "SELECT 1"), "a removed agent cannot sign in")
        self.platform(ada="write", tunde="read")
        self.platform(ada="write")
        self.assertFalse(self.can("platform.tunde", PW["tunde"], one, "SELECT 1"), "a removed platform person cannot sign in")
        self.assertTrue(self.can("platform.ada", PW["ada"], one, "SELECT 1"), "the others stay")

    def test_5_scopes_never_touch_each_other(self):
        one, two = self.services[0], self.services[1]
        self.agents(one, ada="read")
        self.agents(two, ada="read")
        self.platform(ada="read")
        removed = self.agents(one)  # nobody left in one
        self.assertEqual(removed, [f"{one}.ada"])
        self.assertTrue(self.can(f"{two}.ada", PW["ada"], two, "SELECT 1"), "another service's agent stays")
        self.assertTrue(self.can("platform.ada", PW["ada"], one, "SELECT 1"), "the platform's person stays")
        self.platform()  # nobody on the platform list
        self.assertTrue(self.can(f"{two}.ada", PW["ada"], two, "SELECT 1"), "emptying the platform list leaves agents alone")

    def test_6_a_wildcard_name_does_not_reach_a_lookalike_service(self):
        # a_c read as a LIKE pattern matches axc: "_" is a wildcard.
        lookalike, other = self.services[2], self.services[3]
        self.agents(other, ada="read")
        self.agents(lookalike, ada="read")
        removed = self.agents(lookalike)
        self.assertEqual(removed, [f"{lookalike}.ada"])
        self.assertTrue(self.can(f"{other}.ada", PW["ada"], other, "SELECT 1"), f"{other}.ada must survive {lookalike}'s removal")
        # And the wildcard's own grant: the a_c agent's grant on `a_c`.* would, unescaped, cover axc too.
        self.agents(lookalike, ada="read")
        self.assertFalse(self.can(f"{lookalike}.ada", PW["ada"], other, "SELECT 1"), f"{lookalike}.ada must never reach {other}'s database")

    def test_7_running_again_changes_nothing(self):
        one = self.services[0]
        self.agents(one, ada="write")
        self.assertEqual(self.agents(one, ada="write"), [])
        self.assertTrue(self.can(f"{one}.ada", PW["ada"], one, "SELECT 1"))

    def test_8_the_services_own_user_is_untouched(self):
        one = self.services[0]
        self.agents(one, ada="write")
        self.platform(ada="write")
        self.as_service(one, "CREATE TABLE svc_still_owns (v INT)")


# ------------------------------------------------------------------------------
# PostgreSQL
# ------------------------------------------------------------------------------


@unittest.skipUnless(PG_HOST and CA, "set PROVISION_TEST_PG_HOST and PROVISION_TEST_TLS_CA to run against a real PostgreSQL")
class RealPostgresPeople(Scenarios, unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.prov = load()
        cls.port = int(os.environ.get("PROVISION_TEST_PG_PORT", "5432"))
        s = uuid.uuid4().hex[:6]
        cls.admin, cls.admin_password = f"pp_admin_{s}", "Adm1n-pw.x"
        # one, two, and a pair where the first is a LIKE pattern matching the second
        cls.services = [f"pp_one_{s}", f"pp_two_{s}", f"pa_c{s}", f"paxc{s}"]
        with cls.superuser() as c:
            c.cursor().execute(f"CREATE ROLE \"{cls.admin}\" LOGIN NOSUPERUSER CREATEDB CREATEROLE PASSWORD '{cls.admin_password}'")
        for service in cls.services:
            with cls.connect("postgres", cls.admin, cls.admin_password) as c:
                cls.prov.provision(c, service, service, SVC_PW, cls.admin)
            with cls.connect(service, cls.admin, cls.admin_password) as c:
                cls.prov.provision_schema(c, service, cls.admin)
        with cls.connect(cls.services[0], cls.services[0], SVC_PW) as c:
            cur = c.cursor()
            cur.execute("CREATE TABLE before_people (id serial PRIMARY KEY, v text)")
            cur.execute("INSERT INTO before_people (v) VALUES ('seed')")

    @classmethod
    def tearDownClass(cls):
        with cls.superuser() as c:
            cur = c.cursor()
            for database in cls.services:
                cur.execute(f'DROP DATABASE IF EXISTS "{database}" WITH (FORCE)')
            cur.execute("SELECT rolname FROM pg_roles WHERE rolname LIKE 'platform.%' OR rolname LIKE %s OR rolname LIKE %s OR rolname LIKE %s",
                        (f"pp\\_%{cls.services[0][-6:]}.%", f"pa\\_c{cls.services[0][-6:]}.%", f"paxc{cls.services[0][-6:]}.%"))
            for (role,) in cur.fetchall():
                cur.execute(f'DROP ROLE IF EXISTS "{role}"')
            for role in cls.services + [cls.admin]:
                cur.execute(f'DROP ROLE IF EXISTS "{role}"')

    @classmethod
    def superuser(cls):
        import pg8000.dbapi

        class Session:
            def __enter__(self):
                self.c = pg8000.dbapi.connect(host=PG_HOST, port=cls.port, database="postgres",
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

    def platform(self, **access):
        self.prov.provision_scope_postgres(PG_HOST, self.port, self.admin, self.admin_password, "postgres",
                                           "platform", listed("platform", **access))

    def agents(self, service, **access):
        _, removed = self.prov.provision_scope_postgres(PG_HOST, self.port, self.admin, self.admin_password, "postgres",
                                                        service, listed(service, **access), [service])
        return removed

    def as_service(self, service, statement):
        with self.connect(service, service, SVC_PW) as c:
            c.cursor().execute(statement)

    def can(self, user, password, database, statement):
        try:
            with self.connect(database, user, password) as c:
                c.cursor().execute(statement)
            return True
        except Exception:
            return False


# ------------------------------------------------------------------------------
# MySQL
# ------------------------------------------------------------------------------


@unittest.skipUnless(MYSQL_HOST and CA, "set PROVISION_TEST_MYSQL_HOST and PROVISION_TEST_TLS_CA to run against a real MySQL")
class RealMySQLPeople(Scenarios, unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.prov = load()
        cls.port = int(os.environ.get("PROVISION_TEST_MYSQL_PORT", "3306"))
        s = uuid.uuid4().hex[:6]
        cls.admin, cls.admin_password = f"pm_admin_{s}", "Adm1n-pw.x"
        cls.services = [f"pm_one_{s}", f"pm_two_{s}", f"ma_c{s}", f"maxc{s}"]
        with cls.root() as c:
            cur = c.cursor()
            cur.execute(f"CREATE USER '{cls.admin}'@'%' IDENTIFIED BY '{cls.admin_password}'")
            cur.execute(
                "GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, RELOAD, PROCESS, REFERENCES, INDEX, ALTER, "
                "SHOW DATABASES, CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE, REPLICATION SLAVE, REPLICATION CLIENT, "
                "CREATE VIEW, SHOW VIEW, CREATE ROUTINE, ALTER ROUTINE, CREATE USER, EVENT, TRIGGER "
                f"ON *.* TO '{cls.admin}'@'%' WITH GRANT OPTION"
            )
        for service in cls.services:
            with cls.connect(None, cls.admin, cls.admin_password) as c:
                cls.prov.provision_mysql(c, service, service, SVC_PW)
        with cls.connect(cls.services[0], cls.services[0], SVC_PW) as c:
            cur = c.cursor()
            cur.execute("CREATE TABLE before_people (id INT AUTO_INCREMENT PRIMARY KEY, v VARCHAR(20))")
            cur.execute("INSERT INTO before_people (v) VALUES ('seed')")

    @classmethod
    def tearDownClass(cls):
        with cls.root() as c:
            cur = c.cursor()
            for name in cls.services:
                cur.execute(f"DROP DATABASE IF EXISTS `{name}`")
                cur.execute(f"DROP USER IF EXISTS '{name}'@'%'")
            cur.execute("SELECT User FROM mysql.user WHERE Host = '%%' AND (LEFT(User, 9) = 'platform.' OR LOCATE('.', User) > 0)")
            for (user,) in cur.fetchall():
                user = user.decode() if isinstance(user, bytes) else user
                if any(user.startswith(p + ".") for p in cls.services + ["platform"]):
                    cur.execute(f"DROP USER IF EXISTS '{user}'@'%'")
            cur.execute(f"DROP USER IF EXISTS '{cls.admin}'@'%'")

    @classmethod
    def root(cls):
        import pymysql

        return pymysql.connect(host=MYSQL_HOST, port=cls.port, user=os.environ["PROVISION_TEST_MYSQL_ROOT_USER"],
                               password=os.environ.get("PROVISION_TEST_MYSQL_ROOT_PASSWORD", ""), autocommit=True)

    @classmethod
    def connect(cls, database, user, password):
        class Session:
            def __enter__(self):
                self.c = cls.prov.connect_mysql(MYSQL_HOST, cls.port, user, password, database)
                return self.c

            def __exit__(self, *exc):
                self.c.close()

        return Session()

    def platform(self, **access):
        with self.connect(None, self.admin, self.admin_password) as c:
            self.prov.provision_scope_mysql(c, "platform", listed("platform", **access))

    def agents(self, service, **access):
        with self.connect(None, self.admin, self.admin_password) as c:
            _, removed = self.prov.provision_scope_mysql(c, service, listed(service, **access), [service])
        return removed

    def as_service(self, service, statement):
        with self.connect(service, service, SVC_PW) as c:
            c.cursor().execute(statement)

    def can(self, user, password, database, statement):
        try:
            with self.connect(database, user, password) as c:
                c.cursor().execute(statement)
            return True
        except Exception:
            return False


if __name__ == "__main__":
    unittest.main()
