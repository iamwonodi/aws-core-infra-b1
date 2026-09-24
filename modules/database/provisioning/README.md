# Database Provisioning Module

Creates one service's database and user on a **managed** database.

```text
   the service's infrastructure repository
                 |
                 | lambda:InvokeFunction  {"service_name": "auth"}
                 v
   +-------------------------------+        +--------------------------+
   |  provisioning function        | -----> |  Secrets Manager          |
   |  (in the VPC, isolated tier)  |        |  administrator + service  |
   +---------------+---------------+        +--------------------------+
                   |
                   | as the administrator
                   v
   +-------------------------------+
   |  RDS instance                 |   CREATE ROLE / CREATE DATABASE / GRANT
   +-------------------------------+
```

## Why a function

Development's EC2 database host runs core's SQL by `docker exec`-ing into the engine's container. A managed database has **no container to exec into**, and sits in the isolated tier where nothing outside the VPC can reach it, so the same job is done by a Lambda that runs inside the VPC.

This module is platform glue, not a general-purpose building block: it knows core's service-secret naming and is invoked by the roles core generates. That is why it lives here rather than in a `terraform-aws-*` repository, while the RDS instance itself is the published [`terraform-aws-rds-instance`](https://github.com/iamwonodi/terraform-aws-rds-instance).

## What the caller may do, and may not

The payload is **one of two** things:

```json
{ "service_name": "auth" }
{ "action": "people" }
```

The second brings the platform list's logins (`platform.<name>`) on this engine in line with core's people secret; see *People* below.

The function derives the service's secret name from its own pattern, so a caller **cannot** point it at another service's credential, and it runs **no SQL the caller supplies**. Every other field in the payload is ignored.

A service's infrastructure role is granted `lambda:InvokeFunction` on exactly this function and nothing else. Invoking it for a *different* service only re-runs that service's own provisioning, which is idempotent.

## What it does

1. Reads the administrator credential and the service's own secret (`db_name`, `db_user`, `db_password`).
2. Becomes a member of the service's role first (RDS's administrator is not a superuser, and PostgreSQL refuses to create or own a database via a role its creator cannot become), then creates the role and the database if they are missing, and **sets the password every time** — which is what makes a rotated secret heal itself on the next apply.
3. Revokes `PUBLIC` from the database and its `public` schema, so another service's user cannot reach it.

It runs on every apply of the service, so every step is conditional.

After a service is provisioned, its own agents are provisioned, then the platform list, so both reach the new database at once; see *People* below.

## People

People's logins are `<scope>.<name>`, at two scopes. Each run makes the engine's logins of that scope match its list exactly: a listed person gets a login with that password and `read` (look at and query data) or `write` (also add, change and delete rows); neither can change tables. A login of the scope no longer listed is **removed**; which logins are the scope's is decided by an exact pattern, never by `LIKE`. Nothing in the payload can add a person or change an access level: only the secrets decide.

| Scope | Logins | Reach | List | When |
| --- | --- | --- | --- | --- |
| service | `<service>.<name>` | that service's database only | the `agents` entry of the service's own secret: a JSON object `{ "<name>": { "password", "access" } }` | whenever the service is provisioned |
| platform | `platform.<name>` | every service's database | `people_secret_arn`: `{ "platform.<name>": { "password", "access" } }` | `{"action": "people"}` after core's apply, and after every service is provisioned |

| Engine | How access is given |
| --- | --- |
| PostgreSQL | The scope's groups, `<scope>.group_read` and `<scope>.group_write`, granted on its databases (every service's database is found as one owned by a role of its own name), with default privileges so tables the service creates later are covered |
| MySQL | Grants on the scope's databases (a service's database has a user of its own name), given to each person, underscores escaped; revoked and granted again on each run, so a change from write to read leaves nothing behind. Direct grants need only the master user's `WITH GRANT OPTION`; granting a role would need `ROLE_ADMIN` |
| MongoDB (DocumentDB) | Agents: `read` or `readWrite` on the service's database. Platform: `readAnyDatabase` or `readWriteAnyDatabase` on `admin` |

**Production:** with `agents_write_needs_approval`, an agent may write only if its login is in `write_exceptions` (core's `data/agent-write-exceptions.json`). A service asking for unapproved write fails its provisioning, before anything is changed. The platform list is not affected: it is core-approved.

Logins are at most 32 characters (MySQL's limit, held on every engine).

## Things that will bite you

**The driver is committed.** The Lambda runtimes carry no database driver, and a compiled one would have to match the runtime's architecture, so pure-Python `pg8000` is vendored in `lambda/vendor/` (see its README, including how to refresh it).

**PostgreSQL, MySQL and MongoDB (DocumentDB)**, one function per engine (`engine`). On DocumentDB it creates the service's user in `admin` (where DocumentDB keeps every user) with `readWrite` on the service's database only, and sets its password and roles every time; the database itself appears on first write. On MySQL it creates the database (utf8mb4) and a user for `'%'`, sets the password every time, and grants everything on that database only. The grant escapes `_`, which MySQL otherwise treats as a wildcard in a database name: unescaped, service `ab-c`'s grant would also cover service `abxc`'s database. Another engine needs its driver adding and `provision.py` teaching to use it; the `engine` variable refuses anything else rather than failing at run time.

Every connection is encrypted **and verified**: the database must present a certificate signed by an Amazon RDS certificate authority, for the host name connected to. The authorities are AWS's published bundle, committed at `lambda/certificates/rds-global-bundle.pem` (see `lambda/certificates/README.md`); RDS and DocumentDB use the same one. Without it the function refuses to connect, and this module's plan stops before anything is deployed. Verification is tested against real PostgreSQL and MySQL servers (`tests/test_real_tls.py`): the right authority connects, and another authority or another host name is refused.

**Logs need an endpoint.** The isolated subnets have no route to the internet, so the function reaches CloudWatch Logs only through the `logs` interface endpoint the network module creates. Without it the function runs and writes nothing, and a failure is invisible.

**Extra SQL is not supported here.** On the EC2 host a service may publish its own `extra.sql`, which runs as the service's own user. There is no equivalent on a managed database yet.

## What AWS cannot scope

Placing a function in a VPC needs `ec2:CreateNetworkInterface` and its companions on `*`: AWS does not scope them to one VPC or subnet.

## Inputs

| Name | Default | |
| --- | --- | --- |
| `project_name`, `environment` | — | part of the function's name |
| `name` | engine | distinguishes two functions in one environment |
| `engine` | `postgres` | `postgres`, `mysql` or `mongodb` |
| `database_host`, `database_port` | — | what to connect to |
| `database_security_group_id` | — | an ingress rule is added to it for the function |
| `admin_secret_arn` | — | the administrator credential |
| `admin_database` | `postgres` | connected to before a service's database exists (core uses `platform` on MySQL, `admin` on DocumentDB) |
| `service_secret_pattern` | `<project>-{service}-<environment>-secret-vault` | how a service's secret is named |
| `people_secret_arn` | `null` | core's people secret (the platform list); without it the function provisions services and their agents only, and refuses `{"action": "people"}` |
| `agents_write_needs_approval` | `false` | a service's agents write only if listed in `write_exceptions` (on in production) |
| `write_exceptions` | `[]` | agent logins, `<service>.<name>`, core approves to write |
| `vpc_id`, `subnet_ids` | — | the same isolated subnets as the database |
| `log_retention_days` | `30` | |
| `timeout_seconds` | `60` | |
| `tags` | `{}` | |

## Outputs

`function_name`, `function_arn` (what a service's role is granted `InvokeFunction` on), `security_group_id` and `role_arn`.

## Tests

```bash
bash lambda/tests/run.sh
```

Offline tests (no AWS, no database) prove the function's own logic: which statements it runs and where, that a second run creates nothing but still sets the password, every refusal, the people action, the checks on the people secret, and the DocumentDB people path. `test_real_postgres.py`, `test_real_mysql.py`, `test_real_people.py` and `test_real_tls.py` run the same code against **real** PostgreSQL and MySQL servers when these are set, with an administrator shaped like RDS's (not a superuser):

```bash
PROVISION_TEST_TLS_CA=/path/ca.pem   # the servers' CA; connections are verified TLS
PROVISION_TEST_PG_HOST=127.0.0.1     PROVISION_TEST_PG_SUPERUSER=postgres  PROVISION_TEST_PG_SUPERPASSWORD=...
PROVISION_TEST_MYSQL_HOST=127.0.0.1  PROVISION_TEST_MYSQL_ROOT_USER=root   PROVISION_TEST_MYSQL_ROOT_PASSWORD=...
```

The people tests connect **as each person** and try: read, write, create a table, reach a database that is not a service's, sign in after removal.
