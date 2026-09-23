"""The function's TLS verification against REAL PostgreSQL and MySQL servers.

Why this exists: whether a connection is verified is decided by the drivers and
the servers, not by this code's intentions. The offline tests prove the right
context is handed over; these prove it works: the right certificate authority
connects, and a wrong authority or a wrong host name is refused.

It runs only when PROVISION_TEST_TLS_CA is set: a certificate authority that
signed the servers' certificates, which must name the host in
PROVISION_TEST_TLS_HOST (localhost by default) and not 127.0.0.1. Also set
PROVISION_TEST_TLS_OTHER_CA, an unrelated authority, and the logins:

    PROVISION_TEST_TLS_CA=/path/ca.pem
    PROVISION_TEST_TLS_OTHER_CA=/path/other-ca.pem
    PROVISION_TEST_PG_SUPERUSER=postgres       PROVISION_TEST_PG_SUPERPASSWORD=...
    PROVISION_TEST_MYSQL_ROOT_USER=root        PROVISION_TEST_MYSQL_ROOT_PASSWORD=...

MongoDB is not covered: no server is available to these tests.
"""
import importlib
import os
import sys
import types
import unittest

MODULE = os.environ.get("LAMBDA_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.path.insert(0, MODULE)

if "boto3" not in sys.modules:
    stub = types.ModuleType("boto3")
    stub.client = lambda *a, **k: None
    sys.modules["boto3"] = stub

CA = os.environ.get("PROVISION_TEST_TLS_CA")
OTHER_CA = os.environ.get("PROVISION_TEST_TLS_OTHER_CA")
HOST = os.environ.get("PROVISION_TEST_TLS_HOST", "localhost")


@unittest.skipUnless(CA and OTHER_CA, "set PROVISION_TEST_TLS_CA and PROVISION_TEST_TLS_OTHER_CA to test verification against real servers")
class RealTLS(unittest.TestCase):
    def setUp(self):
        self.prov = importlib.reload(importlib.import_module("provision"))
        os.environ["CA_BUNDLE"] = CA

    def tearDown(self):
        os.environ.pop("CA_BUNDLE", None)

    # -- PostgreSQL ------------------------------------------------------------

    def postgres(self, host):
        return self.prov.connect(host, 5432, os.environ["PROVISION_TEST_PG_SUPERUSER"], os.environ["PROVISION_TEST_PG_SUPERPASSWORD"], "postgres")

    def test_postgres_connects_when_the_certificate_is_the_authoritys_and_names_the_host(self):
        connection = self.postgres(HOST)
        try:
            cursor = connection.cursor()
            cursor.execute("SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()")
            self.assertTrue(cursor.fetchone()[0], "the session must be encrypted")
        finally:
            connection.close()

    def test_postgres_refuses_a_certificate_for_another_host_name(self):
        with self.assertRaises(self.prov.ProvisioningError):
            self.postgres("127.0.0.1")

    def test_postgres_refuses_a_certificate_from_another_authority(self):
        os.environ["CA_BUNDLE"] = OTHER_CA
        with self.assertRaises(self.prov.ProvisioningError):
            self.postgres(HOST)

    # -- MySQL -----------------------------------------------------------------

    def mysql(self, host):
        return self.prov.connect_mysql(host, 3306, os.environ["PROVISION_TEST_MYSQL_ROOT_USER"], os.environ["PROVISION_TEST_MYSQL_ROOT_PASSWORD"], None)

    def test_mysql_connects_when_the_certificate_is_the_authoritys_and_names_the_host(self):
        connection = self.mysql(HOST)
        try:
            cursor = connection.cursor()
            cursor.execute("SHOW STATUS LIKE 'Ssl_cipher'")
            self.assertTrue(cursor.fetchone()[1], "the session must be encrypted")
        finally:
            connection.close()

    def test_mysql_refuses_a_certificate_for_another_host_name(self):
        with self.assertRaises(self.prov.ProvisioningError):
            self.mysql("127.0.0.1")

    def test_mysql_refuses_a_certificate_from_another_authority(self):
        os.environ["CA_BUNDLE"] = OTHER_CA
        with self.assertRaises(self.prov.ProvisioningError):
            self.mysql(HOST)


if __name__ == "__main__":
    unittest.main()
