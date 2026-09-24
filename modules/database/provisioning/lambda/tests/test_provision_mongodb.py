"""Offline tests for the provisioning Lambda's DocumentDB path: no AWS, no database."""
import importlib, os, sys, types, unittest

MODULE = os.environ.get("LAMBDA_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.path.insert(0, MODULE)

if "boto3" not in sys.modules:
    fake = types.ModuleType("boto3")
    fake.client = lambda *a, **k: None
    sys.modules["boto3"] = fake


class FakeAdmin:
    def __init__(self, client): self.client = client
    def command(self, name, *args, **kwargs):
        self.client.commands.append((name, args, kwargs))
        if name == "usersInfo":
            return {"users": [{"user": args[0]}] if self.client.user_exists else []}
        return {"ok": 1}


class FakeClient:
    def __init__(self, user_exists=False):
        self.commands = []; self.user_exists = user_exists; self.closed = False
        self.admin = FakeAdmin(self)
    def close(self): self.closed = True


SECRETS = {
    "arn:admin": {"username": "platformadmin", "password": "Adm1n-pw.x"},
    "core-catalog-production-secret-vault": {"db_name": "catalog", "db_user": "catalog", "db_password": "s3cret-pw.y"},
    "core-evil-production-secret-vault": {"db_name": "x$where", "db_user": "evil", "db_password": "p"},
    "core-quote-production-secret-vault": {"db_name": "quote", "db_user": "quote", "db_password": "it's"},
}


class MongoDB(unittest.TestCase):
    def setUp(self):
        os.environ.update({
            "DATABASE_HOST": "docdb.internal", "DATABASE_PORT": "27017",
            "ADMIN_SECRET_ARN": "arn:admin", "ADMIN_DATABASE": "admin", "ENGINE": "mongodb",
            "SERVICE_SECRET_PATTERN": "core-{service}-production-secret-vault",
        })
        self.mod = importlib.reload(importlib.import_module("provision"))
        # These tests are about the service's own database and user. The people
        # steps that follow (its agents, the platform list) are proven in
        # test_provision_people.py and, against real servers, test_real_people.py.
        self.mod.provision_scope = lambda *a, **k: {"people": [], "removed": []}
        self.mod.provision_platform_people = lambda *a, **k: None
        self.mod.read_secret = lambda arn: dict(SECRETS[arn]) if arn in SECRETS else (_ for _ in ()).throw(self.mod.ProvisioningError("no secret " + arn))
        self.clients = []
        self.user_exists = False

        def connect(host, port, user, password):
            c = FakeClient(self.user_exists); c.opened_as = (host, port, user, password)
            self.clients.append(c); return c
        self.mod.connect_mongodb = connect
        self.mod.connect = lambda *a, **k: self.fail("the PostgreSQL connection must not be used")
        self.mod.connect_mysql = lambda *a, **k: self.fail("the MySQL connection must not be used")

    def tearDown(self):
        os.environ["ENGINE"] = "postgres"

    def commands(self):
        return [c for client in self.clients for c in client.commands]

    def test_creates_the_user_when_absent_as_the_administrator(self):
        result = self.mod.handler({"service_name": "catalog"}, None)
        self.assertEqual(result["status"], "provisioned")
        self.assertEqual(self.clients[0].opened_as, ("docdb.internal", "27017", "platformadmin", "Adm1n-pw.x"))
        self.assertIn(("createUser", ("catalog",), {"pwd": "s3cret-pw.y", "roles": [{"role": "readWrite", "db": "catalog"}]}), self.commands())
        self.assertTrue(self.clients[0].closed)

    def test_an_existing_user_gets_its_password_and_roles_set_again(self):
        self.user_exists = True
        self.mod.handler({"service_name": "catalog"}, None)
        names = [c[0] for c in self.commands()]
        self.assertIn("updateUser", names)
        self.assertNotIn("createUser", names)
        update = [c for c in self.commands() if c[0] == "updateUser"][0]
        self.assertEqual(update[2]["roles"], [{"role": "readWrite", "db": "catalog"}])

    def test_the_role_is_scoped_to_the_services_database_only(self):
        self.mod.handler({"service_name": "catalog"}, None)
        for name, args, kwargs in self.commands():
            for role in kwargs.get("roles", []):
                self.assertEqual(role, {"role": "readWrite", "db": "catalog"})

    def test_a_name_that_is_not_plain_is_refused_before_any_command(self):
        with self.assertRaises(self.mod.ProvisioningError):
            self.mod.handler({"service_name": "evil"}, None)
        self.assertEqual(self.commands(), [])

    def test_a_password_with_a_quote_is_refused_before_any_command(self):
        with self.assertRaises(self.mod.ProvisioningError):
            self.mod.handler({"service_name": "quote"}, None)
        self.assertEqual(self.commands(), [])

    def test_the_real_driver_is_pure_python(self):
        import bson, pymongo
        self.assertFalse(bson.has_c())
        self.assertFalse(pymongo.has_c())


if __name__ == "__main__":
    unittest.main()
