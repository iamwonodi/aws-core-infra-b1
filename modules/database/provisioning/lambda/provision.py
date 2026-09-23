"""
Create one service's database and user on a managed database (PostgreSQL, MySQL
or DocumentDB, MongoDB-compatible).

The EC2 database host runs core's SQL by exec-ing into the engine's container. A
managed database has no container to exec into and sits in the isolated tier,
which nothing outside the VPC can reach, so the same job is done by this function:
it runs inside the VPC, reads the administrator credential and the service's own
credential from Secrets Manager, and executes the same statements. One function
is deployed per engine; ENGINE says which it speaks.

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
import ssl
import sys

# The drivers are committed next to this file (see vendor/README.md): the Lambda
# runtimes carry no database driver, and a compiled one would have to match the
# runtime's architecture.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "vendor"))

import boto3  # noqa: E402  (the runtime provides it)
import pg8000.dbapi  # noqa: E402
import pymysql  # noqa: E402
import pymongo  # noqa: E402

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ------------------------------------------------------------------------------
# TLS
# ------------------------------------------------------------------------------
# Every connection is encrypted AND verified: the server must present a
# certificate signed by an Amazon RDS certificate authority, for the host name
# connected to. Without verification, anything able to impersonate the database
# inside the VPC would be handed the administrator's password.
#
# RDS and DocumentDB sign with the same authorities, published by AWS as one
# bundle, committed next to this file (certificates/README.md). CA_BUNDLE
# overrides its location, which the tests use.
# ------------------------------------------------------------------------------

DEFAULT_CA_BUNDLE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "certificates", "rds-global-bundle.pem")


def ca_bundle():
    """The certificate bundle to verify against; refuses to go on without one."""
    path = os.environ.get("CA_BUNDLE") or DEFAULT_CA_BUNDLE

    if not os.path.isfile(path):
        raise ProvisioningError(
            f"no certificate bundle at {path}: the database's certificate cannot be verified, "
            "so no connection is attempted. See certificates/README.md."
        )

    return path


def tls_context():
    """A context that verifies the certificate chain and the host name."""
    try:
        context = ssl.create_default_context(cafile=ca_bundle())
    except ssl.SSLError as error:
        raise ProvisioningError(f"the certificate bundle could not be loaded: {error}") from error

    # create_default_context already does both; stated so a reader need not know.
    context.check_hostname = True
    context.verify_mode = ssl.CERT_REQUIRED
    return context

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
            ssl_context=tls_context(),
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


# ------------------------------------------------------------------------------
# MySQL
# ------------------------------------------------------------------------------


def quote_mysql_identifier(value):
    """Backquote an identifier that has already been checked against IDENTIFIER."""
    if not IDENTIFIER.match(value):
        raise ProvisioningError(f"'{value}' is not a plain identifier")
    return "`" + value + "`"


def connect_mysql(host, port, user, password, database):
    context = tls_context()

    try:
        connection = pymysql.connect(
            host=host,
            port=int(port),
            user=user,
            password=password,
            database=database,
            ssl=context,
            connect_timeout=15,
            autocommit=True,
        )
    except Exception as error:
        raise ProvisioningError(f"could not connect to {host}:{port} as {user}: {error}") from error

    return connection


def provision_mysql(connection, database, user, password):
    """Create the database and the user, and grant that user everything on that database only."""
    name = quote_mysql_identifier(database)
    account = "'" + quote_mysql_identifier(user)[1:-1] + "'@'%'"
    secret = quote_literal(password)

    # In a database-level GRANT, "_" and "%" in the name are WILDCARDS. Service
    # databases are the service name with "-" turned into "_", so an unescaped
    # grant on `ab_c` would also cover `abxc`: another service's data. IDENTIFIER
    # already rules out "%".
    grant_name = "`" + database.replace("_", "\\_") + "`"

    cursor = connection.cursor()

    logger.info("Ensuring database %s and user %s.", database, user)
    cursor.execute(f"CREATE DATABASE IF NOT EXISTS {name} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci")

    # '%' rather than a fixed host: the service's hosts change as its group scales.
    cursor.execute(f"CREATE USER IF NOT EXISTS {account} IDENTIFIED BY {secret}")

    # Set every time: a rotated secret then heals itself on the next apply.
    cursor.execute(f"ALTER USER {account} IDENTIFIED BY {secret}")

    cursor.execute(f"GRANT ALL PRIVILEGES ON {grant_name}.* TO {account}")

    cursor.close()


# ------------------------------------------------------------------------------
# DocumentDB (MongoDB-compatible)
# ------------------------------------------------------------------------------


def connect_mongodb(host, port, user, password):
    # DocumentDB keeps every user in the admin database, so the administrator
    # authenticates there. TLS is required by the cluster, and verified against
    # the same bundle as the other engines.
    # DocumentDB does not support retryable writes, and the cluster endpoint is
    # always the writer, so the client talks to it directly.
    try:
        client = pymongo.MongoClient(
            host=host,
            port=int(port),
            username=user,
            password=password,
            authSource="admin",
            tls=True,
            tlsCAFile=ca_bundle(),
            retryWrites=False,
            directConnection=True,
            serverSelectionTimeoutMS=15000,
            connectTimeoutMS=15000,
        )
        client.admin.command("ping")
    except Exception as error:
        raise ProvisioningError(f"could not connect to {host}:{port} as {user}: {error}") from error

    return client


def provision_mongodb(client, database, user, password):
    """Create the service's user, with readWrite on its own database and nothing else."""
    if not IDENTIFIER.match(database) or not IDENTIFIER.match(user):
        raise ProvisioningError("the database and user names must be plain identifiers")
    quote_literal(password)  # refused before any command if it is not core's alphabet

    # Every user lives in admin (DocumentDB puts it there whatever the context), so
    # the application authenticates with authSource=admin. The role names the
    # service's database explicitly. The database itself appears on first write.
    roles = [{"role": "readWrite", "db": database}]

    existing = client.admin.command("usersInfo", user).get("users", [])

    if existing:
        # Set every time: a rotated secret then heals itself, and the roles are
        # put back if anyone widened them.
        logger.info("Updating user %s.", user)
        client.admin.command("updateUser", user, pwd=password, roles=roles)
    else:
        logger.info("Creating user %s.", user)
        client.admin.command("createUser", user, pwd=password, roles=roles)


def handler(event, context):  # noqa: ARG001
    service = (event or {}).get("service_name", "")

    if not SERVICE_NAME.match(service):
        raise ProvisioningError(f"'{service}' is not a valid service name")

    host = os.environ["DATABASE_HOST"]
    port = os.environ["DATABASE_PORT"]
    admin_secret_arn = os.environ["ADMIN_SECRET_ARN"]
    admin_database = os.environ.get("ADMIN_DATABASE", "postgres")
    engine = os.environ.get("ENGINE", "postgres")

    if engine not in ("postgres", "mysql", "mongodb"):
        raise ProvisioningError(f"this function does not speak '{engine}'")

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

    logger.info("Provisioning %s on %s (%s).", database, host, engine)

    if engine == "mongodb":
        client = connect_mongodb(host, port, admin["username"], admin["password"])
        try:
            provision_mongodb(client, database, user, password)
        finally:
            client.close()

        logger.info("Provisioned %s.", service)
        return {"service": service, "database": database, "user": user, "status": "provisioned"}

    if engine == "mysql":
        connection = connect_mysql(host, port, admin["username"], admin["password"], admin_database)
        try:
            provision_mysql(connection, database, user, password)
        finally:
            connection.close()

        logger.info("Provisioned %s.", service)
        return {"service": service, "database": database, "user": user, "status": "provisioned"}

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
