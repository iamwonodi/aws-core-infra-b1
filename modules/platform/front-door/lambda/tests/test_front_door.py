"""The front-door function against fake S3 and Cognito: which sign-ins result."""
import importlib
import io
import json
import os
import sys
import types
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

# boto3 is in the Lambda runtime; each test replaces it with fakes anyway.
if "boto3" not in sys.modules:
    stub = types.ModuleType("boto3")
    stub.client = lambda *a, **k: None
    sys.modules["boto3"] = stub


class Paginator:
    def __init__(self, pages):
        self.pages = pages

    def paginate(self, **kwargs):
        return self.pages(**kwargs)


class FakeS3:
    def __init__(self, objects):
        self.objects = objects  # key -> bytes

    def get_paginator(self, name):
        assert name == "list_objects_v2"

        def pages(Bucket, Prefix):
            keys = sorted(k for k in self.objects if k.startswith(Prefix))
            # Two pages, so pagination is exercised.
            half = len(keys) // 2
            return [{"Contents": [{"Key": k} for k in keys[:half]]}, {"Contents": [{"Key": k} for k in keys[half:]]}]

        return Paginator(pages)

    def get_object(self, Bucket, Key):
        return {"Body": io.BytesIO(self.objects[Key])}


class UsernameExistsException(Exception):
    pass


class UserNotFoundException(Exception):
    pass


class FakeCognito:
    exceptions = types.SimpleNamespace(UsernameExistsException=UsernameExistsException, UserNotFoundException=UserNotFoundException)

    def __init__(self, users):
        self.users = dict(users)  # username -> email
        self.calls = []

    def get_paginator(self, name):
        assert name == "list_users"
        return Paginator(lambda UserPoolId: [{"Users": [
            {"Username": u, "Attributes": ([{"Name": "email", "Value": e}] if e else [])} for u, e in self.users.items()
        ]}])

    def admin_create_user(self, **kwargs):
        self.calls.append(("create", kwargs))
        email = kwargs["Username"]
        if email in self.users.values():
            raise UsernameExistsException()
        self.users["sub-" + email] = email

    def admin_delete_user(self, UserPoolId, Username):
        self.calls.append(("delete", Username))
        if Username not in self.users:
            raise UserNotFoundException()
        del self.users[Username]


def declaration(*emails):
    return json.dumps({"emails": list(emails)}).encode()


class FrontDoor(unittest.TestCase):
    def setUp(self):
        os.environ.update(DECLARATIONS_BUCKET="deploy", DECLARATIONS_PREFIX="front-door/",
                          PLATFORM_KEY="front-door/_platform.json", USER_POOL_ID="pool-1")
        self.objects = {
            "front-door/_platform.json": declaration("devigma@example.org"),
            "front-door/orders.json": declaration("Ada@Example.org", "bob@example.org"),
            "front-door/billing.json": declaration("ada@example.org"),
            "deploy/other.json": b"{}",  # outside the prefix: never read
        }
        self.cognito = FakeCognito({"sub-gone": "gone@example.org", "sub-dev": "devigma@example.org"})
        self.mod = importlib.reload(importlib.import_module("front_door"))
        fake = types.SimpleNamespace(client=lambda name: {"s3": FakeS3(self.objects), "cognito-idp": self.cognito}[name])
        self.mod.boto3 = fake

    def emails(self):
        return sorted(self.cognito.users.values())

    def run_it(self):
        return self.mod.handler({"Records": []}, None)

    def test_the_sign_ins_are_the_union_of_every_declaration(self):
        result = self.run_it()
        self.assertEqual(self.emails(), ["ada@example.org", "bob@example.org", "devigma@example.org"])
        self.assertEqual(result["created"], ["ada@example.org", "bob@example.org"])
        self.assertEqual(result["removed"], ["gone@example.org"])

    def test_one_sign_in_per_email_however_many_services_declare_it(self):
        self.run_it()
        self.assertEqual(self.emails().count("ada@example.org"), 1)

    def test_a_new_sign_in_is_invited_by_email_with_its_email_verified(self):
        self.run_it()
        create = [c[1] for c in self.cognito.calls if c[0] == "create" and c[1]["Username"] == "bob@example.org"][0]
        self.assertEqual(create["DesiredDeliveryMediums"], ["EMAIL"])
        self.assertIn({"Name": "email_verified", "Value": "true"}, create["UserAttributes"])
        self.assertEqual(create["UserPoolId"], "pool-1")

    def test_removing_a_service_declaration_removes_only_what_it_alone_declared(self):
        self.run_it()
        del self.objects["front-door/orders.json"]
        self.run_it()
        self.assertEqual(self.emails(), ["ada@example.org", "devigma@example.org"], "ada is still declared by billing; bob is not")

    def test_running_again_changes_nothing(self):
        self.run_it()
        self.cognito.calls.clear()
        result = self.run_it()
        self.assertEqual((result["created"], result["removed"], self.cognito.calls), ([], [], []))

    def test_a_user_added_by_hand_is_removed(self):
        self.cognito.users["sub-hand"] = "someone@example.org"
        self.run_it()
        self.assertNotIn("someone@example.org", self.emails())

    def test_a_user_without_an_email_is_removed(self):
        self.cognito.users["sub-odd"] = ""
        self.run_it()
        self.assertNotIn("sub-odd", self.cognito.users)

    def test_a_race_with_another_run_is_harmless(self):
        original = self.cognito.admin_create_user

        def racing(**kwargs):
            if kwargs["Username"] == "bob@example.org":
                self.cognito.users["sub-bob-other"] = "bob@example.org"
            return original(**kwargs)

        self.cognito.admin_create_user = racing
        self.run_it()
        self.assertEqual(self.emails().count("bob@example.org"), 1)


class NothingChangesOnDoubt(FrontDoor):
    """Any doubt about the declarations: no sign-in is created or removed."""

    def assert_untouched(self):
        before = dict(self.cognito.users)
        with self.assertRaises(self.mod.DeclarationError):
            self.run_it()
        self.assertEqual(self.cognito.users, before)
        self.assertEqual(self.cognito.calls, [])

    def test_a_declaration_that_is_not_json(self):
        self.objects["front-door/orders.json"] = b"{not json"
        self.assert_untouched()

    def test_a_declaration_without_a_list_of_emails(self):
        self.objects["front-door/orders.json"] = json.dumps({"emails": "ada@example.org"}).encode()
        self.assert_untouched()

    def test_something_that_is_not_an_email(self):
        self.objects["front-door/orders.json"] = declaration("ada@example.org", "not-an-email")
        self.assert_untouched()

    def test_a_file_not_named_after_a_service(self):
        self.objects["front-door/../evil.json"] = declaration("evil@example.org")
        self.assert_untouched()

    def test_the_platform_declaration_missing(self):
        del self.objects["front-door/_platform.json"]
        self.assert_untouched()


if __name__ == "__main__":
    unittest.main()
