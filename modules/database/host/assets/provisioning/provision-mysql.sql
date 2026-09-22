-- ============================================================================
-- STANDARD PROVISIONING: MYSQL
--
-- Creates the service's database and its user, and grants that user everything
-- on that database and nothing else. Core owns this script so that every service
-- is provisioned the same way.
--
-- provision.sh sets these before this file runs:
--   @target_db  @target_user  @target_pass
--
-- Run as root, and safe to run again: Terraform triggers provisioning on every
-- apply. The user's password is set each time, so a rotated secret heals itself.
--
-- Identifiers cannot be parameterised in MySQL, so each statement is built as
-- text and run with PREPARE. The values come from the service's secret, which
-- core generated from the service name (letters, digits and _ only), and
-- provision.sh validates them before this file is reached.
--
-- The user is created for '%' rather than a fixed host: the service's containers
-- connect from the fleet's hosts, whose addresses change as the group scales.
-- ============================================================================

SET @statement = CONCAT('CREATE DATABASE IF NOT EXISTS `', @target_db, '` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci');
PREPARE statement FROM @statement; EXECUTE statement; DEALLOCATE PREPARE statement;

SET @statement = CONCAT('CREATE USER IF NOT EXISTS ''', @target_user, '''@''%'' IDENTIFIED BY ''', @target_pass, '''');
PREPARE statement FROM @statement; EXECUTE statement; DEALLOCATE PREPARE statement;

-- Set every time, so a rotated password takes effect on the next apply.
SET @statement = CONCAT('ALTER USER ''', @target_user, '''@''%'' IDENTIFIED BY ''', @target_pass, '''');
PREPARE statement FROM @statement; EXECUTE statement; DEALLOCATE PREPARE statement;

-- In a database-level GRANT, "_" and "%" in the database name are WILDCARDS.
-- Service databases are named from the service name with "-" turned into "_",
-- so an unescaped grant on `ab_c` would also cover `abxc`: another service's
-- data. The underscores are escaped so the grant names exactly one database.
SET @statement = CONCAT('GRANT ALL PRIVILEGES ON `', REPLACE(@target_db, '_', '\\_'), '`.* TO ''', @target_user, '''@''%''');
PREPARE statement FROM @statement; EXECUTE statement; DEALLOCATE PREPARE statement;

FLUSH PRIVILEGES;

SELECT 'Provisioned.' AS status;
