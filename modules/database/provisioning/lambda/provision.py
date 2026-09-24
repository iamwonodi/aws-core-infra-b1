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

# People's own database logins are <scope>.<name>:
#
#   platform.<name>   core's platform list: every service's database
#   <service>.<name>  a service's agents: that service's database only
#
# A service's own user is its name with underscores and never contains a dot, and
# a person's name has no underscore, so the groups each scope uses,
# <scope>.group_read and <scope>.group_write, can be neither.
NAME = re.compile(r"^[a-z][a-z0-9]{1,19}$")
SCOPE = re.compile(r"^(platform|[a-z][a-z0-9_]{1,21})$")
LOGIN = re.compile(r"^(platform|[a-z][a-z0-9_]{1,21})\.([a-z][a-z0-9]{1,19}|group_read|group_write)$")
ACCESS_LEVELS = ("read", "write")

# MySQL's user names are at most 32 characters. Held for every engine, so a
# service's agents have the same names wherever they are provisioned.
LOGIN_MAX = 32

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



# ------------------------------------------------------------------------------
# People: <scope>.<name> logins
# ------------------------------------------------------------------------------
# One mechanism at two scopes. Each makes the engine's logins of its scope match
# a list exactly: a listed person gets their login with their password and
# access on the scope's databases; any login of the scope no longer listed is
# removed. Logins of any other scope are never touched.
#
#   platform  core's people secret (PEOPLE_SECRET_ARN): every service's database.
#             Run on {"action": "people"} after core's apply, and after every
#             service is provisioned so its new database is covered.
#   service   the "agents" entry of the service's own secret: that service's
#             database only. Run whenever the service is provisioned.
#
# "read" can look at and query data; "write" can also add, change and delete it.
# Neither can change tables, which is the services' migrations' job.
#
# Production (AGENT_WRITE=approved): a service's agent may write only if core
# lists its login in WRITE_EXCEPTIONS. Core's own platform list is core-approved
# by definition.
# ------------------------------------------------------------------------------


def quote_login(value):
    """Double-quote a login or group name that has been checked against LOGIN."""
    if not LOGIN.match(value) or len(value) > LOGIN_MAX:
        raise ProvisioningError(f"'{value}' is not a <scope>.<name> login")
    return '"' + value + '"'


def mysql_account(value):
    if not LOGIN.match(value) or len(value) > LOGIN_MAX:
        raise ProvisioningError(f"'{value}' is not a <scope>.<name> login")
    return "'" + value + "'@'%'"


def scope_pattern(scope):
    """Exactly the people logins of this scope (not its groups, not another scope's)."""
    return re.compile("^" + re.escape(scope) + r"\.[a-z][a-z0-9]{1,19}$")


def checked_people(scope, entries, source):
    """{ login: {password, access} }, every part checked, from { name: {password, access} }."""
    if not isinstance(entries, dict):
        raise ProvisioningError(f"{source} is not a JSON object")

    people = {}
    for name, entry in entries.items():
        login = f"{scope}.{name}"
        if not NAME.match(name):
            raise ProvisioningError(f"'{name}' in {source} is not a name: 2-20 lowercase letters and digits, starting with a letter")
        if len(login) > LOGIN_MAX:
            raise ProvisioningError(f"{login} is longer than {LOGIN_MAX} characters, MySQL's limit: shorten the name in {source}")
        if not isinstance(entry, dict) or entry.get("access") not in ACCESS_LEVELS:
            raise ProvisioningError(f"{login} in {source} has no access level of read or write")
        quote_literal(entry.get("password") or "")  # refused unless it is core's alphabet
        people[login] = {"password": entry["password"], "access": entry["access"]}
    return people


def read_platform_people(arn):
    """Core's people secret: { "platform.<name>": {password, access} }."""
    secret = read_secret(arn)
    if not isinstance(secret, dict):
        raise ProvisioningError("the people secret is not a JSON object")
    entries = {}
    for login, entry in secret.items():
        scope, _, name = login.partition(".")
        if scope != "platform":
            raise ProvisioningError(f"'{login}' in the people secret is not platform.<name>")
        entries[name] = entry
    return checked_people("platform", entries, "the people secret")


def service_agents(scope, credentials):
    """The "agents" entry of a service's secret: a JSON object { name: {password, access} }."""
    raw = credentials.get("agents")
    if raw in (None, ""):
        return {}
    try:
        entries = json.loads(raw) if isinstance(raw, str) else raw
    except ValueError as error:
        raise ProvisioningError("the service secret's agents entry is not JSON") from error
    return checked_people(scope, entries, "the service secret's agents")


def enforce_write_policy(scope, people):
    """In production, a service's agent writes only with core's approval."""
    if scope == "platform" or os.environ.get("AGENT_WRITE", "allowed") != "approved":
        return
    approved = {login.strip() for login in os.environ.get("WRITE_EXCEPTIONS", "").split(",") if login.strip()}
    refused = sorted(login for login, person in people.items() if person["access"] == "write" and login not in approved)
    if refused:
        raise ProvisioningError(
            f"{', '.join(refused)} ask(s) for write in production, which core has not approved. Set read, or add "
            "the login to infrastructure/production/data/agent-write-exceptions.json in core."
        )


def service_databases_postgres(cursor, admin):
    """Every service's database: owned by a role of its own name (core's convention)."""
    cursor.execute(
        "SELECT d.datname FROM pg_database d JOIN pg_roles r ON r.oid = d.datdba "
        "WHERE r.rolname = d.datname AND NOT d.datistemplate "
        "AND d.datname NOT IN ('postgres', 'rdsadmin') AND r.rolname <> %s ORDER BY 1",
        (admin,),
    )
    return [row[0] for row in cursor.fetchall() if IDENTIFIER.match(row[0])]


def people_postgres(connection, admin, scope, people, databases):
    """Logins, group membership and removals, from the administrator's database.

    Access is given through the scope's two groups rather than to each person:
    default privileges then cover tables a service creates later, and a person's
    access changes by changing one membership.
    """
    administrator = quote_identifier(admin)
    read, write = quote_login(f"{scope}.group_read"), quote_login(f"{scope}.group_write")
    cursor = connection.cursor()

    for group in (f"{scope}.group_read", f"{scope}.group_write"):
        cursor.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (group,))
        if cursor.fetchone() is None:
            cursor.execute(f"CREATE ROLE {quote_login(group)} NOLOGIN")

    for database in databases:
        name = quote_identifier(database)
        # The administrator acts for each service's owner below (grants on its
        # tables, default privileges), which needs membership, as when the
        # service was provisioned. Granting again is a no-op.
        cursor.execute(f"GRANT {name} TO {administrator}")
        cursor.execute(f"GRANT CONNECT ON DATABASE {name} TO {read}, {write}")

    for login, person in sorted(people.items()):
        role = quote_login(login)
        cursor.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (login,))
        if cursor.fetchone() is None:
            logger.info("Creating %s.", login)
            cursor.execute(f"CREATE ROLE {role} LOGIN")
        cursor.execute(f"ALTER ROLE {role} WITH LOGIN PASSWORD {quote_literal(person['password'])}")

        member, other = (write, read) if person["access"] == "write" else (read, write)
        cursor.execute(f"GRANT {member} TO {role}")
        cursor.execute(f"REVOKE {other} FROM {role}")

    # Candidates by prefix, then EXACTLY this scope's logins by pattern: "_" in a
    # service name is a LIKE wildcard, and ab_c's removal must never reach abxc's.
    removed = []
    mine = scope_pattern(scope)
    cursor.execute("SELECT rolname FROM pg_roles WHERE starts_with(rolname, %s) ORDER BY 1", (scope + ".",))
    for (login,) in cursor.fetchall():
        if mine.match(login) and login not in people:
            logger.info("Removing %s: no longer listed.", login)
            cursor.execute(f"DROP ROLE {quote_login(login)}")
            removed.append(login)

    cursor.close()
    return removed


def people_postgres_database(connection, owner, scope):
    """Inside one service's database: what the scope's groups may do, now and for tables created later."""
    owner_role = quote_identifier(owner)
    read, write = quote_login(f"{scope}.group_read"), quote_login(f"{scope}.group_write")
    cursor = connection.cursor()

    cursor.execute(f"GRANT USAGE ON SCHEMA public TO {read}, {write}")

    cursor.execute(f"GRANT SELECT ON ALL TABLES IN SCHEMA public TO {read}")
    cursor.execute(f"GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO {read}")
    cursor.execute(f"GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO {write}")
    cursor.execute(f"GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO {write}")

    # Tables and sequences the service creates later, through its migrations.
    cursor.execute(f"ALTER DEFAULT PRIVILEGES FOR ROLE {owner_role} IN SCHEMA public GRANT SELECT ON TABLES TO {read}")
    cursor.execute(f"ALTER DEFAULT PRIVILEGES FOR ROLE {owner_role} IN SCHEMA public GRANT SELECT ON SEQUENCES TO {read}")
    cursor.execute(
        f"ALTER DEFAULT PRIVILEGES FOR ROLE {owner_role} IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO {write}"
    )
    cursor.execute(
        f"ALTER DEFAULT PRIVILEGES FOR ROLE {owner_role} IN SCHEMA public GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO {write}"
    )
    cursor.close()


def provision_scope_postgres(host, port, admin, admin_password, admin_database, scope, people, databases=None):
    """databases=None: every service's database (the platform scope)."""
    connection = connect(host, port, admin, admin_password, admin_database)
    try:
        if databases is None:
            cursor = connection.cursor()
            databases = service_databases_postgres(cursor, admin)
            cursor.close()
        removed = people_postgres(connection, admin, scope, people, databases)
    finally:
        connection.close()

    for database in databases:
        connection = connect(host, port, admin, admin_password, database)
        try:
            people_postgres_database(connection, database, scope)
        finally:
            connection.close()

    return databases, removed


MYSQL_SYSTEM_SCHEMAS = ("mysql", "information_schema", "performance_schema", "sys")


def service_databases_mysql(cursor):
    """A service's database has a user of the same name (core's convention)."""
    cursor.execute(
        "SELECT s.SCHEMA_NAME FROM information_schema.SCHEMATA s "
        "WHERE s.SCHEMA_NAME NOT IN (%s, %s, %s, %s) "
        "AND EXISTS (SELECT 1 FROM mysql.user u WHERE u.User = s.SCHEMA_NAME) ORDER BY 1",
        MYSQL_SYSTEM_SCHEMAS,
    )
    return [row[0] for row in cursor.fetchall() if IDENTIFIER.match(row[0])]


def provision_scope_mysql(connection, scope, people, databases=None):
    """Logins, and grants on the scope's databases, given to each person directly.

    MySQL grants at the database level cover tables created later, so no group is
    needed; direct grants also need only what the RDS master user has (every
    privilege WITH GRANT OPTION), where granting a role would need ROLE_ADMIN.
    """
    cursor = connection.cursor()

    if databases is None:
        databases = service_databases_mysql(cursor)

    removed = []
    mine = scope_pattern(scope)
    cursor.execute("SELECT User FROM mysql.user WHERE Host = %s AND LEFT(User, %s) = %s ORDER BY 1", ("%", len(scope) + 1, scope + "."))
    for (login,) in cursor.fetchall():
        login = login.decode() if isinstance(login, bytes) else login
        if mine.match(login) and login not in people:
            logger.info("Removing %s: no longer listed.", login)
            cursor.execute(f"DROP USER {mysql_account(login)}")
            removed.append(login)

    for login, person in sorted(people.items()):
        account = mysql_account(login)
        secret = quote_literal(person["password"])

        cursor.execute(f"CREATE USER IF NOT EXISTS {account} IDENTIFIED BY {secret}")
        cursor.execute(f"ALTER USER {account} IDENTIFIED BY {secret}")

        # Start from nothing each time, so a change from write to read, or a
        # removed service, leaves no grant behind.
        cursor.execute(f"REVOKE ALL PRIVILEGES, GRANT OPTION FROM {account}")

        privileges = "SELECT, INSERT, UPDATE, DELETE" if person["access"] == "write" else "SELECT"
        for database in databases:
            quote_mysql_identifier(database)  # refused unless a plain name
            # "_" is a wildcard in a database-level grant: escaped, as for services.
            grant_name = "`" + database.replace("_", "\\_") + "`"
            cursor.execute(f"GRANT {privileges} ON {grant_name}.* TO {account}")

    cursor.close()
    return databases, removed


def provision_scope_mongodb(client, scope, people, database=None):
    """database=None: every database (readAnyDatabase / readWriteAnyDatabase on admin),
    for the platform. Otherwise read / readWrite on that database only."""
    removed = []
    mine = scope_pattern(scope)
    existing = client.admin.command("usersInfo").get("users", [])
    for entry in existing:
        login = entry.get("user", "")
        if mine.match(login) and login not in people:
            logger.info("Removing %s: no longer listed.", login)
            client.admin.command("dropUser", login)
            removed.append(login)

    present = {entry.get("user") for entry in existing}
    for login, person in sorted(people.items()):
        quote_login(login)
        if database is None:
            roles = [{"role": "readWriteAnyDatabase" if person["access"] == "write" else "readAnyDatabase", "db": "admin"}]
        else:
            roles = [{"role": "readWrite" if person["access"] == "write" else "read", "db": database}]
        if login in present:
            client.admin.command("updateUser", login, pwd=person["password"], roles=roles)
        else:
            logger.info("Creating %s.", login)
            client.admin.command("createUser", login, pwd=person["password"], roles=roles)

    return removed


def provision_scope(engine, host, port, admin, admin_database, scope, people, database=None):
    """Make this engine's logins of one scope match people. Returns what changed."""
    enforce_write_policy(scope, people)

    if engine == "mongodb":
        client = connect_mongodb(host, port, admin["username"], admin["password"])
        try:
            removed = provision_scope_mongodb(client, scope, people, database)
        finally:
            client.close()
        return {"people": sorted(people), "removed": removed}

    databases = None if database is None else [database]

    if engine == "mysql":
        connection = connect_mysql(host, port, admin["username"], admin["password"], admin_database)
        try:
            databases, removed = provision_scope_mysql(connection, scope, people, databases)
        finally:
            connection.close()
        return {"people": sorted(people), "removed": removed, "databases": databases}

    databases, removed = provision_scope_postgres(host, port, admin["username"], admin["password"], admin_database, scope, people, databases)
    return {"people": sorted(people), "removed": removed, "databases": databases}


def provision_platform_people(engine, host, port, admin, admin_database):
    secret_arn = os.environ.get("PEOPLE_SECRET_ARN")
    if not secret_arn:
        return None
    return provision_scope(engine, host, port, admin, admin_database, "platform", read_platform_people(secret_arn))


def handler(event, context):  # noqa: ARG001
    event = event or {}

    host = os.environ["DATABASE_HOST"]
    port = os.environ["DATABASE_PORT"]
    admin_secret_arn = os.environ["ADMIN_SECRET_ARN"]
    admin_database = os.environ.get("ADMIN_DATABASE", "postgres")
    engine = os.environ.get("ENGINE", "postgres")

    if engine not in ("postgres", "mysql", "mongodb"):
        raise ProvisioningError(f"this function does not speak '{engine}'")

    # {"action": "people"}: bring the team's logins in line with the people
    # secret, and nothing else. Anyone who may invoke this may ask for it; it
    # only ever applies what core wrote to that secret.
    if event.get("action") == "people":
        if not os.environ.get("PEOPLE_SECRET_ARN"):
            raise ProvisioningError("this function has no PEOPLE_SECRET_ARN: core has not given it the people secret")

        admin = read_secret(admin_secret_arn)
        logger.info("Provisioning people on %s (%s).", host, engine)
        result = provision_platform_people(engine, host, port, admin, admin_database)
        logger.info("Provisioned people: %s.", result)
        return {"status": "people provisioned", "engine": engine, **result}

    service = event.get("service_name", "")

    if not SERVICE_NAME.match(service):
        raise ProvisioningError(f"'{service}' is not a valid service name")

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

    elif engine == "mysql":
        connection = connect_mysql(host, port, admin["username"], admin["password"], admin_database)
        try:
            provision_mysql(connection, database, user, password)
        finally:
            connection.close()

    else:
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

    # The service's own agents, <service>.<name>, on its database only.
    agents = provision_scope(engine, host, port, admin, admin_database, user, service_agents(user, credentials), database)

    # The platform's people reach the new database straight away.
    platform = provision_platform_people(engine, host, port, admin, admin_database)

    logger.info("Provisioned %s.", service)

    result = {"service": service, "database": database, "user": user, "status": "provisioned", "agents": agents["people"]}
    if agents["removed"]:
        result["agents_removed"] = agents["removed"]
    if platform is not None:
        result["platform_people"] = platform["people"]
    return result
