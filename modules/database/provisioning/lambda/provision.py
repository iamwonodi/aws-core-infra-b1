"""
Create one service's database and user on the managed database.

The EC2 database host runs core's SQL by exec-ing into the engine's container. A
managed database has no container to exec into and sits in the isolated tier,
which nothing outside the VPC can reach, so the same job is done by this function:
it runs inside the VPC, reads the administrator credential and the service's own
credential from Secrets Manager, and executes the same statements.

WHO CALLS IT. A service's infrastructure repository, with its own IAM role, after
its apply. The payload names only the service; everything else is looked up here,
so the caller cannot choose a database name, a user or a password.

SAFE TO RUN AGAIN. Terraform triggers provisioning on every apply, so every
statement is conditional and the password is set each time -- which is what makes
a rotated secret heal itself on the next apply.

WHAT IT DELIBERATELY DOES NOT DO: create the secret (the service's own repository
does), drop anything, or run SQL supplied by the caller. Extra SQL a service needs
on a managed database is not supported yet; on the EC2 host it runs as the
service's own user, and the same restriction would have to be built here.
"""

import json
import logging
import os
import re
import sys

# The driver is committed next to this file (see vendor/README.md): the Lambda
# runtimes carry no PostgreSQL driver, and a compiled one would have to match the
# runtime's architecture.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "vendor"))

import boto3  # noqa: E402  (the runtime provides it)
import pg8000.dbapi  # noqa: E402

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Core generates service names, database names and users from a service's name, so
# they are plain identifiers. Anything else is refused rather than quoted: these
# values are interpolated into SQL that runs as the administrator.
IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
SERVICE_NAME = re.compile(r"^[a-z][a-z0-9-]{1,20}[a-z0-9]$")
PASSWORD = re.compile(r"^[A-Za-z0-9._-]+$")

secrets = boto3.client("secretsmanager")


class ProvisioningError(Exception):
    """Anything that should fail the caller's workflow with a readable reason."""


def read_secret(arn):
    try:
        return json.loads(secrets.get_secret_value(SecretId=arn)["SecretString"])
    except Exception as error:
        raise ProvisioningError(f"could not read the secret {arn}: {error}") from error


def quote_identifier(value):
    """Double-quote an identifier that has already been checked against IDENTIFIER."""
    if not IDENTIFIER.match(value):
        raise ProvisioningError(f"'{value}' is not a plain identifier")
    return '"' + value + '"'


def quote_literal(value):
    """Single-quote a value that has already been checked against PASSWORD."""
    if not PASSWORD.match(value):
        raise ProvisioningError(
            "the password contains characters that are not allowed. Core generates "
            "passwords from letters, digits and -_. precisely so that they are safe here."
        )
    return "'" + value + "'"


def connect(host, port, user, password, database):
    try:
        connection = pg8000.dbapi.connect(
            host=host,
            port=int(port),
            user=user,
            password=password,
            database=database,
            ssl_context=True,  # RDS presents a certificate; the tier is isolated but the traffic is still encrypted
            timeout=15,
        )
    except Exception as error:
        raise ProvisioningError(f"could not connect to {host}:{port} as {user}: {error}") from error

    connection.autocommit = True
    return connection


def provision(connection, database, user, password, admin):
    """Create the role and the database, and give that role ownership of it."""
    role = quote_identifier(user)
    name = quote_identifier(database)
    secret = quote_literal(password)
    administrator = quote_identifier(admin)

    cursor = connection.cursor()

    cursor.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (user,))
    if cursor.fetchone() is None:
        logger.info("Creating role %s.", user)
        cursor.execute(f"CREATE ROLE {role} LOGIN")

    # Set every time: a rotated secret then heals itself on the next apply.
    cursor.execute(f"ALTER ROLE {role} WITH LOGIN PASSWORD {secret}")

    # On RDS the administrator is NOT a superuser: it is a member of rds_superuser,
    # which cannot become an arbitrary role. PostgreSQL refuses to create a
    # database, or change its owner, in favour of a role the creator cannot become
    # ("must be member of role", "must be able to SET ROLE" from PostgreSQL 16),
    # so the administrator is made a member first. Granting again is a no-op, which
    # keeps the whole function safe to run on every apply. The administrator can
    # already grant itself any role, so this widens nothing.
    cursor.execute(f"GRANT {role} TO {administrator}")

    cursor.execute("SELECT 1 FROM pg_database WHERE datname = %s", (database,))
    if cursor.fetchone() is None:
        # CREATE DATABASE cannot run inside a transaction, which is why this
        # connection is in autocommit.
        logger.info("Creating database %s.", database)
        cursor.execute(f"CREATE DATABASE {name} OWNER {role}")
    else:
        cursor.execute(f"ALTER DATABASE {name} OWNER TO {role}")

    # PUBLIC has CONNECT on every database by default: another service's user must
    # not be able to reach this one.
    cursor.execute(f"REVOKE ALL ON DATABASE {name} FROM PUBLIC")
    cursor.execute(f"GRANT ALL PRIVILEGES ON DATABASE {name} TO {role}")

    cursor.close()


def provision_schema(connection, user, admin):
    """Inside the service's own database: give it the public schema, and no one else."""
    role = quote_identifier(user)
    quote_identifier(admin)  # refused before any statement runs if it is not a plain name

    cursor = connection.cursor()
    cursor.execute(f"ALTER SCHEMA public OWNER TO {role}")
    cursor.execute(f"GRANT ALL ON SCHEMA public TO {role}")
    cursor.execute("REVOKE ALL ON SCHEMA public FROM PUBLIC")
    cursor.close()


def handler(event, context):  # noqa: ARG001
    service = (event or {}).get("service_name", "")

    if not SERVICE_NAME.match(service):
        raise ProvisioningError(f"'{service}' is not a valid service name")

    host = os.environ["DATABASE_HOST"]
    port = os.environ["DATABASE_PORT"]
    admin_secret_arn = os.environ["ADMIN_SECRET_ARN"]
    admin_database = os.environ.get("ADMIN_DATABASE", "postgres")

    # The service's secret is named, not passed: the caller cannot point this at
    # another service's credential.
    pattern = os.environ["SERVICE_SECRET_PATTERN"]
    service_secret_id = pattern.replace("{service}", service)

    admin = read_secret(admin_secret_arn)
    credentials = read_secret(service_secret_id)

    for field in ("db_name", "db_user", "db_password"):
        if not credentials.get(field):
            raise ProvisioningError(f"the secret {service_secret_id} has no {field}")

    database = credentials["db_name"]
    user = credentials["db_user"]
    password = credentials["db_password"]

    logger.info("Provisioning %s on %s.", database, host)

    connection = connect(host, port, admin["username"], admin["password"], admin_database)
    try:
        provision(connection, database, user, password, admin["username"])
    finally:
        connection.close()

    # The schema lives inside the new database, so a second connection is needed.
    connection = connect(host, port, admin["username"], admin["password"], database)
    try:
        provision_schema(connection, user, admin["username"])
    finally:
        connection.close()

    logger.info("Provisioned %s.", service)

    return {"service": service, "database": database, "user": user, "status": "provisioned"}
