"""Make the team tools' sign-ins match the front-door declarations.

Invoked by S3 whenever a declaration in the deploy bucket is created, changed or
deleted (and safe to invoke by hand at any time: the event itself is ignored).

    front-door/<service>.json   a service's agents' emails
    front-door/_platform.json   core's platform list's emails

Each is { "emails": [ ... ] }. The pool's users are made to match the union of
every declaration: an email declared anywhere has exactly one sign-in, however
many services declare it, and a sign-in whose email no declaration names is
deleted. Cognito sends a new user their invitation.

It changes NOTHING unless every declaration was read and understood, and the
platform's own declaration is among them: acting on part of the picture would
delete people whose declaration merely failed to load.
"""
import json
import logging
import os
import re

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# A service name (core's rule), or "_platform", core's own declaration.
SOURCE = re.compile(r"^(_platform|[a-z][a-z0-9-]{1,20}[a-z0-9])$")
EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


class DeclarationError(Exception):
    """A declaration that cannot be trusted. Nothing is changed."""


def declared_emails(s3, bucket, prefix, platform_key):
    """{ email: [sources] } from every declaration, or DeclarationError."""
    declared = {}
    platform_seen = False

    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=prefix):
        for item in page.get("Contents", []):
            key = item["Key"]
            if not key.endswith(".json"):
                continue

            source = key[len(prefix):-len(".json")]
            if not SOURCE.match(source):
                raise DeclarationError(f"{key} is not named after a service or _platform")

            try:
                body = json.loads(s3.get_object(Bucket=bucket, Key=key)["Body"].read())
            except ValueError as error:
                raise DeclarationError(f"{key} is not JSON") from error

            emails = body.get("emails") if isinstance(body, dict) else None
            if not isinstance(emails, list):
                raise DeclarationError(f"{key} has no list of emails")

            for email in emails:
                if not isinstance(email, str) or not EMAIL.match(email):
                    raise DeclarationError(f"{key} names something that is not an email address")
                declared.setdefault(email.lower(), []).append(source)

            platform_seen = platform_seen or key == platform_key

    if not platform_seen:
        raise DeclarationError(f"{platform_key} is missing: core writes it, so the declarations are incomplete")

    return declared


def current_users(cognito, pool):
    """{ email: username } of every user in the pool."""
    users = {}
    for page in cognito.get_paginator("list_users").paginate(UserPoolId=pool):
        for user in page.get("Users", []):
            attributes = {a["Name"]: a["Value"] for a in user.get("Attributes", [])}
            email = attributes.get("email", "").lower()
            # A user without an email cannot have been declared; key it by its
            # username so that it is removed like any other undeclared sign-in.
            users[email or "(no email) " + user["Username"]] = user["Username"]
    return users


def handler(event, context):  # noqa: ARG001
    bucket = os.environ["DECLARATIONS_BUCKET"]
    prefix = os.environ["DECLARATIONS_PREFIX"]
    platform_key = os.environ["PLATFORM_KEY"]
    pool = os.environ["USER_POOL_ID"]

    s3 = boto3.client("s3")
    cognito = boto3.client("cognito-idp")

    try:
        declared = declared_emails(s3, bucket, prefix, platform_key)
    except DeclarationError as error:
        logger.error("Nothing changed: %s", error)
        raise

    users = current_users(cognito, pool)

    created, removed = [], []

    for email in sorted(set(declared) - set(users)):
        try:
            cognito.admin_create_user(
                UserPoolId=pool,
                Username=email,
                UserAttributes=[{"Name": "email", "Value": email}, {"Name": "email_verified", "Value": "true"}],
                DesiredDeliveryMediums=["EMAIL"],
            )
            logger.info("Created a sign-in for %s (declared by %s).", email, ", ".join(declared[email]))
            created.append(email)
        except cognito.exceptions.UsernameExistsException:
            # Another run created it a moment ago: the outcome is the same.
            pass

    for email in sorted(set(users) - set(declared)):
        try:
            cognito.admin_delete_user(UserPoolId=pool, Username=users[email])
            logger.info("Removed the sign-in of %s: no declaration names it.", email)
            removed.append(email)
        except cognito.exceptions.UserNotFoundException:
            pass

    result = {"declared": len(declared), "created": created, "removed": removed}
    logger.info("Front door: %s.", result)
    return result
