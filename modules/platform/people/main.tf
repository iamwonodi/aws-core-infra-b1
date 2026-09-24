# ------------------------------------------------------------------------------
# PEOPLE
#
# The team members who use the team tools, from infrastructure/<env>/data/
# people.json. For each person this module generates the password of their
# database login, agent_<name>, and keeps every password of the environment in
# ONE secret, which only administrators read: an administrator hands each person
# their own. The logins themselves are created on the databases by the
# provisioning path (the database host in development, the functions on the
# managed databases).
#
# Where the tools have a web address (development and staging), it also creates
# the front door: a Cognito user pool with one user per person, signed in by
# email with an authenticator app always required. Nobody can sign themselves
# up; being on the list is the only way in, and leaving it removes the sign-in.
#
# WHAT IT LEAVES TO THE TOOLS REPOSITORY: the app client and its managed login
# style. They carry the tools' own web addresses, which change with the tools,
# not with the platform.
#
# TO GIVE SOMEONE A NEW DATABASE PASSWORD: replace their random_password, e.g.
# terraform apply -replace='module.people.random_password.agent["ada"]'.
# ------------------------------------------------------------------------------

locals {
  # Every person's database user. The prefix marks a person rather than a
  # service (a service's user is its name with underscores); core refuses
  # service names beginning with "agent-" so the two can never collide.
  usernames = { for name, person in var.people : name => "agent_${name}" }

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

resource "random_password" "agent" {
  for_each = var.people

  # 40 fits every engine: MySQL accepts at most 41 characters, DocumentDB 100.
  length  = 40
  special = true

  # Letters, digits and -_. only, as every generated secret in this platform:
  # safe in an env file, a connection string and SQL.
  override_special = "-_."
}

# One secret per environment, { "agent_<name>": "<password>" }. Its name begins
# with "database-", which core reserves for the platform's own database secrets:
# no service can be called that, and the fleets are denied every secret named so.
module "secret" {
  source = "git::https://github.com/iamwonodi/terraform-aws-secrets-vault.git?ref=v1.0.0"
  count  = length(var.people) > 0 ? 1 : 0

  project_name = var.project_name
  environment  = var.environment
  service_name = "database-people"

  secret_kv_pairs = {
    for name, username in local.usernames : username => random_password.agent[name].result
  }
}

# ------------------------------------------------------------------------------
# Front door
# ------------------------------------------------------------------------------

resource "aws_cognito_user_pool" "this" {
  count = var.front_door ? 1 : 0

  name = "${var.project_name}-${var.environment}-team"

  # Essentials: its managed login walks a new user through setting up their
  # authenticator app. Free up to 10,000 monthly active users per account (the
  # Plus tier has no free allowance).
  user_pool_tier = "ESSENTIALS"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  # An authenticator app, always. No SMS (it costs per message) and no email
  # codes (the same inbox as a password reset would be one factor, not two).
  mfa_configuration = "ON"

  software_token_mfa_configuration {
    enabled = true
  }

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = false
    temporary_password_validity_days = 7
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # Cognito's own sender: free, no domain to verify, about 50 messages a day,
  # from no-reply@verificationemail.com. Enough for a team's invitations.
  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  deletion_protection = "ACTIVE"

  tags = var.tags
}

# The sign-in pages. Prefixes are shared by every account in the Region, so the
# account ID makes this one unique. Version 2 is managed login, which needs a
# style per app client: the tools repository creates it with its client.
resource "aws_cognito_user_pool_domain" "this" {
  count = var.front_door ? 1 : 0

  domain                = "${var.project_name}-${var.environment}-team-${var.account_id}"
  user_pool_id          = aws_cognito_user_pool.this[0].id
  managed_login_version = 2
}

# One sign-in per person. Cognito emails them a temporary password; at their
# first sign-in they choose their own and set up their authenticator app.
resource "aws_cognito_user" "agent" {
  for_each = var.front_door ? var.people : {}

  user_pool_id = aws_cognito_user_pool.this[0].id
  username     = lower(each.value.email)

  attributes = {
    email          = lower(each.value.email)
    email_verified = "true"
  }

  desired_delivery_mediums = ["EMAIL"]
}
