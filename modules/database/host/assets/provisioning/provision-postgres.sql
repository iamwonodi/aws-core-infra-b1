-- ============================================================================
-- STANDARD PROVISIONING: POSTGRESQL
--
-- Creates the service's database and its user, and gives that user ownership of
-- that database and nothing else. Core owns this script so that every service is
-- provisioned the same way and no service writes its own CREATE DATABASE.
--
-- provision.sh sets these before this file runs:
--   :target_db  :target_user  :target_pass
--
-- It is run as the administrator (postgres), and it must be safe to run again:
-- Terraform triggers provisioning on every apply. So every step is conditional,
-- and the password is set each time -- which is what makes a rotated secret heal
-- itself on the next apply.
--
-- CREATE DATABASE cannot run inside a transaction block or from a DO block, so
-- the database is created with \gexec: the SELECT produces the statement only
-- when the database is missing, and \gexec runs whatever the query returned.
-- ============================================================================

\set ON_ERROR_STOP on

-- The role: created once, its password set every time.
SELECT format('CREATE ROLE %I LOGIN', :'target_user')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'target_user')
\gexec

SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'target_user', :'target_pass')
\gexec

-- The database, owned by that role.
SELECT format('CREATE DATABASE %I OWNER %I', :'target_db', :'target_user')
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'target_db')
\gexec

SELECT format('ALTER DATABASE %I OWNER TO %I', :'target_db', :'target_user')
\gexec

-- Only the owner may connect. PUBLIC has CONNECT on every database by default,
-- so it is revoked: another service's user must not reach this database.
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'target_db')
\gexec

SELECT format('GRANT ALL PRIVILEGES ON DATABASE %I TO %I', :'target_db', :'target_user')
\gexec

-- The public schema inside the new database. Since PostgreSQL 15 it is owned by
-- pg_database_owner and PUBLIC can no longer create in it, so the owner is set
-- explicitly for older versions and the grant is made either way.
\connect :target_db

SELECT format('ALTER SCHEMA public OWNER TO %I', :'target_user')
\gexec

SELECT format('GRANT ALL ON SCHEMA public TO %I', :'target_user')
\gexec

REVOKE ALL ON SCHEMA public FROM PUBLIC;

\echo 'Provisioned.'
