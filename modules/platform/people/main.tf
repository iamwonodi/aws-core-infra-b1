# ------------------------------------------------------------------------------
# PEOPLE
#
# The team members who use the team tools, from infrastructure/<env>/data/
# people.json. For each person this module generates the password of their
# database login, platform.<name>, and keeps every password and access level of
# the environment in ONE secret, which only administrators read: an
# administrator hands each person their own. The logins themselves are created on the databases by the
# provisioning path (the database host in development, the functions on the
# managed databases).
#
# The list's emails also go to the front door (modules/platform/front-door),
# which gives each person a sign-in to the team tools' web addresses.
#
# TO GIVE SOMEONE A NEW DATABASE PASSWORD: replace their random_password, e.g.
# terraform apply -replace='module.people.random_password.person["ada"]'.
# ------------------------------------------------------------------------------

locals {
  # Every person's database login, platform.<name>: this list reaches every
  # service's database. A service's own user never contains a dot, and a
  # service's agents are <service>.<name>, so the three cannot collide.
  usernames = { for name, person in var.people : name => "platform.${name}" }

  writers = [for name, person in var.people : name if person.access == "write"]
}

resource "terraform_data" "people_invariants" {
  lifecycle {
    precondition {
      condition     = !var.read_only || length(local.writers) == 0
      error_message = "This environment is read-only for everyone: set access to \"read\" for ${join(", ", local.writers)}."
    }
  }
}

# ------------------------------------------------------------------------------
# Database passwords
# ------------------------------------------------------------------------------

resource "random_password" "person" {
  for_each = var.people

  # 40 fits every engine: MySQL accepts at most 41 characters, DocumentDB 100.
  length  = 40
  special = true

  # Letters, digits and -_. only, as every generated secret in this platform:
  # safe in an env file, a connection string and SQL.
  override_special = "-_."
}

# One secret per environment, always present (empty when nobody is listed, which
# tells provisioning to remove every login):
#
#   { "platform.<name>": { "password": "...", "access": "read" | "write" }, ... }
#
# The access level lives here, not in a parameter, because the provisioning
# functions of the managed databases can reach Secrets Manager and nothing else.
#
# Its name follows the platform's <project>-<name>-<environment>-secret-vault
# convention, which the database host's permission to read secrets relies on,
# and begins with "database-", which core reserves for the platform's own
# database secrets: no service can be called that, and the fleets are denied
# every secret named so.
resource "aws_secretsmanager_secret" "this" {
  name                    = "${var.project_name}-database-people-${var.environment}-secret-vault"
  description             = "Every team member's database login password and access level, keyed by database user. Administrators hand each person their own."
  recovery_window_in_days = 7

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "this" {
  secret_id = aws_secretsmanager_secret.this.id

  secret_string = jsonencode({
    for name, person in var.people : local.usernames[name] => {
      password = random_password.person[name].result
      access   = person.access
    }
  })
}
