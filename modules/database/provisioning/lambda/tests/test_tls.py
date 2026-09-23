"""Offline tests: every connection is verified against the RDS certificate bundle."""
import importlib, os, ssl, sys, tempfile, types, unittest

MODULE = os.environ.get("LAMBDA_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.path.insert(0, MODULE)

if "boto3" not in sys.modules:
    fake = types.ModuleType("boto3")
    fake.client = lambda *a, **k: None
    sys.modules["boto3"] = fake



class TLS(unittest.TestCase):
    def setUp(self):
        self.mod = importlib.reload(importlib.import_module("provision"))
        self.dir = tempfile.mkdtemp()
        os.environ.pop("CA_BUNDLE", None)
        # The drivers are shared modules: put back whatever a test replaces, so
        # no later test file inherits a fake.
        self.originals = (self.mod.pg8000.dbapi.connect, self.mod.pymysql.connect, self.mod.pymongo.MongoClient)

    def tearDown(self):
        os.environ.pop("CA_BUNDLE", None)
        self.mod.pg8000.dbapi.connect, self.mod.pymysql.connect, self.mod.pymongo.MongoClient = self.originals

    def generated_bundle(self):
        # A real, throwaway certificate authority, made with openssl.
        path = os.path.join(self.dir, "ca.pem")
        os.system(f"openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout {self.dir}/k.pem -out {path} -days 1 -subj /CN=test-ca >/dev/null 2>&1")
        return path

    def test_a_missing_bundle_is_refused_before_connecting(self):
        os.environ["CA_BUNDLE"] = os.path.join(self.dir, "absent.pem")
        with self.assertRaises(self.mod.ProvisioningError) as caught:
            self.mod.tls_context()
        self.assertIn("no connection is attempted", str(caught.exception))

    def test_the_default_bundle_lives_next_to_the_function(self):
        self.assertEqual(self.mod.DEFAULT_CA_BUNDLE, os.path.join(os.path.abspath(MODULE), "certificates", "rds-global-bundle.pem"))

    def test_the_context_verifies_the_chain_and_the_host_name(self):
        os.environ["CA_BUNDLE"] = self.generated_bundle()
        context = self.mod.tls_context()
        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(context.check_hostname)

    def test_a_bundle_that_is_not_certificates_is_refused(self):
        path = os.path.join(self.dir, "junk.pem")
        with open(path, "w") as f:
            f.write("not a certificate\n")
        os.environ["CA_BUNDLE"] = path
        with self.assertRaises(self.mod.ProvisioningError):
            self.mod.tls_context()

    def test_postgres_connects_with_the_verifying_context(self):
        os.environ["CA_BUNDLE"] = self.generated_bundle()
        seen = {}
        self.mod.pg8000.dbapi.connect = lambda **kw: seen.update(kw) or types.SimpleNamespace(autocommit=False)
        self.mod.connect("db.internal", 5432, "u", "p", "postgres")
        self.assertIsInstance(seen["ssl_context"], ssl.SSLContext)
        self.assertEqual(seen["ssl_context"].verify_mode, ssl.CERT_REQUIRED)

    def test_mysql_connects_with_the_verifying_context(self):
        os.environ["CA_BUNDLE"] = self.generated_bundle()
        seen = {}
        self.mod.pymysql.connect = lambda **kw: seen.update(kw) or object()
        self.mod.connect_mysql("db.internal", 3306, "u", "p", "platform")
        self.assertTrue(seen["ssl"].check_hostname)
        self.assertEqual(seen["ssl"].verify_mode, ssl.CERT_REQUIRED)

    def test_mongodb_connects_verifying_against_the_bundle(self):
        bundle = self.generated_bundle()
        os.environ["CA_BUNDLE"] = bundle
        seen = {}

        class Client:
            def __init__(self, **kw):
                seen.update(kw)
                self.admin = types.SimpleNamespace(command=lambda *a, **k: {"ok": 1})

        self.mod.pymongo.MongoClient = Client
        self.mod.connect_mongodb("docdb.internal", 27017, "u", "p")
        self.assertEqual(seen["tlsCAFile"], bundle)
        self.assertTrue(seen["tls"])
        self.assertNotIn("tlsAllowInvalidCertificates", seen)
        self.assertNotIn("tlsInsecure", seen)

    def test_no_driver_is_reached_without_a_bundle(self):
        os.environ["CA_BUNDLE"] = os.path.join(self.dir, "absent.pem")
        reached = []
        self.mod.pg8000.dbapi.connect = lambda **kw: reached.append("pg")
        self.mod.pymysql.connect = lambda **kw: reached.append("mysql")
        self.mod.pymongo.MongoClient = lambda **kw: reached.append("mongo")
        for call in (lambda: self.mod.connect("h", 1, "u", "p", "d"),
                     lambda: self.mod.connect_mysql("h", 1, "u", "p", "d"),
                     lambda: self.mod.connect_mongodb("h", 1, "u", "p")):
            with self.assertRaises(self.mod.ProvisioningError):
                call()
        self.assertEqual(reached, [])


if __name__ == "__main__":
    unittest.main()
