// ============================================================================
// STANDARD PROVISIONING: MONGODB
//
// Creates the service's user with readWrite on its own database and nothing
// else. MongoDB creates a database when something is first written to it, so
// there is no CREATE DATABASE step.
//
// provision.sh defines these before this file runs:
//   target_db  target_user  target_pass
//
// Run as the administrator, and safe to run again: the user is created once and
// its password and roles are set every time, so a rotated secret heals itself.
// ============================================================================

const database = db.getSiblingDB(target_db);

const existing = database.getUser(target_user);

if (existing === null) {
  database.createUser({
    user: target_user,
    pwd: target_pass,
    roles: [{ role: "readWrite", db: target_db }],
  });
  print("Created user " + target_user + " on " + target_db + ".");
} else {
  database.updateUser(target_user, {
    pwd: target_pass,
    roles: [{ role: "readWrite", db: target_db }],
  });
  print("Updated user " + target_user + " on " + target_db + ".");
}

print("Provisioned.");
