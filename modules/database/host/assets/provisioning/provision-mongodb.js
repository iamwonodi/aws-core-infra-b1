// ============================================================================
// STANDARD PROVISIONING: MONGODB
//
// Creates the service's user with readWrite on its own database and nothing
// else. MongoDB creates a database when something is first written to it, so
// there is no CREATE DATABASE step.
//
// The user lives in the admin database, with its role naming the service's own
// database. That is where DocumentDB (staging and production) keeps every user,
// so an application authenticates with authSource=admin in every environment.
//
// provision.sh defines these before this file runs:
//   target_db  target_user  target_pass
//
// Run as the administrator, and safe to run again: the user is created once and
// its password and roles are set every time, so a rotated secret heals itself.
// ============================================================================

const users = db.getSiblingDB("admin");

const existing = users.getUser(target_user);

if (existing === null) {
  users.createUser({
    user: target_user,
    pwd: target_pass,
    roles: [{ role: "readWrite", db: target_db }],
  });
  print("Created user " + target_user + " for " + target_db + ".");
} else {
  users.updateUser(target_user, {
    pwd: target_pass,
    roles: [{ role: "readWrite", db: target_db }],
  });
  print("Updated user " + target_user + " for " + target_db + ".");
}

print("Provisioned.");
