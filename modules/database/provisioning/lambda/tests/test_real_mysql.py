"""The MySQL provisioning against a REAL MySQL, as a non-root administrator.

Why this exists: the offline tests use a fake cursor, which cannot show what MySQL
itself does with a statement. A database-level grant treats "_" as a wildcard,
which no fake can reveal, and that exact mistake once let one service read
another's data.

It runs only when PROVISION_TEST_MYSQL_HOST is set, with a root login it may use
to create a throwaway administrator shaped like the RDS master user (every
privilege on *.*, with GRANT OPTION, but not SUPER):

    PROVISION_TEST_MYSQL_HOST=127.0.0.1
    PROVISION_TEST_MYSQL_PORT=3306
    PROVISION_TEST_MYSQL_ROOT_USER=root
    PROVISION_TEST_MYSQL_ROOT_PASSWORD=...

The connection is made as the function makes it: over TLS, verified. So set
PROVISION_TEST_TLS_CA to the certificate authority that signed the server's
certificate, and PROVISION_TEST_MYSQL_HOST to the name that certificate is for
(localhost, not 127.0.0.1).
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

HOST = os.environ.get("PROVISION_TEST_MYSQL_HOST")
CA = os.environ.get("PROVISION_TEST_TLS_CA")


@unittest.skipUnless(HOST and CA, "set PROVISION_TEST_MYSQL_HOST and PROVISION_TEST_TLS_CA to run the provisioning SQL against a real MySQL")
class RealMySQL(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        os.environ.update(DATABASE_HOST="x", DATABASE_PORT="3306", ADMIN_SECRET_ARN="x", SERVICE_SECRET_PATTERN="x", ENGINE="mysql", CA_BUNDLE=CA)
        cls.prov = importlib.reload(importlib.import_module("provision"))
        cls.port = int(os.environ.get("PROVISION_TEST_MYSQL_PORT", "3306"))
        cls.suffix = uuid.uuid4().hex[:6]
        cls.admin = f"pt_admin_{cls.suffix}"
        cls.admin_password = "Adm1n-pw.x"
        cls.created = []

        with cls.root() as c:
            cur = c.cursor()
            cur.execute(f"CREATE USER '{cls.admin}'@'%' IDENTIFIED BY '{cls.admin_password}'")
            # The RDS master user's shape: everything, with GRANT OPTION, no SUPER.
            cur.execute(
                "GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, RELOAD, PROCESS, REFERENCES, INDEX, ALTER, "
                "SHOW DATABASES, CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE, REPLICATION SLAVE, REPLICATION CLIENT, "
                "CREATE VIEW, SHOW VIEW, CREATE ROUTINE, ALTER ROUTINE, CREATE USER, EVENT, TRIGGER "
                f"ON *.* TO '{cls.admin}'@'%' WITH GRANT OPTION"
            )

    @classmethod
    def tearDownClass(cls):
        with cls.root() as c:
            cur = c.cursor()
            for name in cls.created:
                cur.execute(f"DROP DATABASE IF EXISTS `{name}`")
                cur.execute(f"DROP USER IF EXISTS '{name}'@'%'")
            cur.execute(f"DROP USER IF EXISTS '{cls.admin}'@'%'")

    @classmethod
    def root(cls):
        import pymysql
        return pymysql.connect(host=HOST, port=cls.port, user=os.environ["PROVISION_TEST_MYSQL_ROOT_USER"],
                               password=os.environ.get("PROVISION_TEST_MYSQL_ROOT_PASSWORD", ""), autocommit=True)

    def as_user(self, user, password, database=None):
        return self.prov.connect_mysql(HOST, self.port, user, password, database)

    def provision(self, name, password="s3cret-pw.y", limit=None):
        if name not in self.created:
            self.created.append(name)
        connection = self.as_user(self.admin, self.admin_password)
        try:
            self.prov.provision_mysql(connection, name, name, password, limit)
        finally:
            connection.close()
        return name

    def test_the_administrator_connects_over_tls(self):
        connection = self.as_user(self.admin, self.admin_password)
        try:
            cur = connection.cursor()
            cur.execute("SHOW STATUS LIKE 'Ssl_cipher'")
            self.assertTrue(cur.fetchone()[1], "the connection must be encrypted")
        finally:
            connection.close()

    def test_provisions_a_database_the_service_can_use(self):
        name = self.provision(f"pt_use_{self.suffix}")
        connection = self.as_user(name, "s3cret-pw.y", name)
        try:
            cur = connection.cursor()
            cur.execute("CREATE TABLE t (v INT)")
            cur.execute("INSERT INTO t VALUES (1)")
            cur.execute("SELECT COUNT(*) FROM t")
            self.assertEqual(cur.fetchone()[0], 1)
        finally:
            connection.close()

    def test_an_underscore_does_not_reach_a_lookalike_database(self):
        # ab_c's grant, unescaped, would match abxc: the bug this test pins.
        victim = self.provision(f"ptx{self.suffix}xc")
        attacker = self.provision(f"pt_{self.suffix}_c")
        self.assertEqual(len(victim), len(attacker))
        with self.root() as c:
            c.cursor().execute(f"CREATE TABLE `{victim}`.secret (v INT)")
        connection = self.as_user(attacker, "s3cret-pw.y")
        try:
            with self.assertRaises(Exception):
                connection.cursor().execute(f"SELECT * FROM `{victim}`.secret")
        finally:
            connection.close()

    def test_running_it_again_keeps_the_data_and_a_rotated_password_takes_effect(self):
        name = self.provision(f"pt_rot_{self.suffix}")
        with self.root() as c:
            c.cursor().execute(f"CREATE TABLE `{name}`.kept (v INT)")
        self.provision(name, password="n3w-pw.z")
        connection = self.as_user(name, "n3w-pw.z", name)
        try:
            cur = connection.cursor()
            cur.execute("SHOW TABLES")
            self.assertIn(("kept",), cur.fetchall())
        finally:
            connection.close()
        with self.assertRaises(self.prov.ProvisioningError):
            self.as_user(name, "s3cret-pw.y", name)


    def open_as(self, name, count):
        sessions = [self.as_user(name, "s3cret-pw.y", name) for _ in range(count)]
        self.addCleanup(lambda: [s.close() for s in sessions])
        return sessions

    def test_the_connection_over_the_limit_is_refused_and_one_opens_when_another_closes(self):
        name = self.provision(f"pt_capped_{self.suffix}", limit=2)
        held = self.open_as(name, 2)
        with self.assertRaisesRegex(Exception, "max_user_connections"):
            self.open_as(name, 1)
        held.pop().close()
        self.open_as(name, 1)

    def test_a_changed_limit_takes_effect_the_next_time_it_is_provisioned(self):
        name = self.provision(f"pt_raised_{self.suffix}", limit=1)
        self.open_as(name, 1)
        with self.assertRaisesRegex(Exception, "max_user_connections"):
            self.open_as(name, 1)
        self.provision(name, limit=2)
        self.open_as(name, 1)


if __name__ == "__main__":
    unittest.main()
