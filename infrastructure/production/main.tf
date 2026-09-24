################################################################################
# GITHUB ACTIONS OIDC
#
# The trust relationship CI itself uses to deploy this environment. Kept
# at the root rather than folded into a domain module -- it has no
# natural home among network/edge, and is small enough that forcing it
# into one of them would add ceremony without benefit.
################################################################################

# Read once and shared: the account the permissions apply to.
data "aws_caller_identity" "current" {}

# The token subjects AWS trusts for the core repository. Both the repository
# name and its numeric IDs are supplied by whoever runs Terraform (CI passes
# them from the GitHub context), never committed -- this configuration is a
# blueprint that many projects clone.
module "github_identity" {
  source = "../../modules/platform/identity"

  github_repository    = var.github_repository
  github_owner_id      = var.github_owner_id
  github_repository_id = var.github_repository_id
  subject_format       = var.oidc_subject_format
  environment          = local.environment
}

# One role per service repository, each with a policy generated from its
# service-roles.json entry. Empty by default: see data/README.md.
# The permissions boundary every IAM role a service's infrastructure repository
# creates must carry (see modules/platform/service-boundary). In this environment each
# service creates its own hosts, and therefore its own instance role; the boundary
# caps what any such role can ever do, whatever is attached to it.
module "service_boundary" {
  source = "../../modules/platform/service-boundary"

  project_name = var.project_name
  environment  = local.environment
  aws_region   = var.aws_region
  account_id   = data.aws_caller_identity.current.account_id

  # A service's hosts install the platform scripts core publishes, so the
  # boundary must let them read that prefix -- and nothing else in the bucket.
  deploy_bucket_name = module.deploy.bucket_name
}

resource "aws_iam_policy" "service_boundary" {
  name        = module.service_boundary.policy_name
  path        = module.service_boundary.policy_path
  description = "Permissions boundary for the IAM roles that services' infrastructure repositories create. A ceiling, not a grant."
  policy      = module.service_boundary.policy_json
}

# Two roles per service, generated from data/service-roles.json (empty by default;
# see data/README.md). Services are hosted "dedicated" here: each service's
# infrastructure repository creates its own launch template, ASG, security group,
# configuration bucket and instance role.
module "service_roles" {
  source = "../../modules/platform/service-roles"

  project_name   = var.project_name
  environment    = local.environment
  aws_region     = var.aws_region
  account_id     = data.aws_caller_identity.current.account_id
  subject_format = var.oidc_subject_format

  entries = jsondecode(file("${path.module}/data/service-roles.json"))

  hosting_model            = "dedicated"
  permissions_boundary_arn = aws_iam_policy.service_boundary.arn

  # Lets each service's infra repository create its own database on the managed
  # instances, through their provisioning functions and nothing else.
  database_provision_function_arns = [for engine in sort(tolist(local.provisioned_engines)) : module.database_provisioning[engine].function_arn]

  # The internal tier exists only while internal_tier_enabled is on.
  tiers = merge(
    {
      private = {
        listener_arn = nonsensitive(module.edge.private_alb_https_listener_arn)
      }
    },
    var.internal_tier_enabled ? {
      internal = {
        listener_arn = nonsensitive(module.edge.internal_alb_https_listener_arn)
      }
    } : {},
  )

  assets_bucket_name = module.edge.assets_bucket_id
  state_bucket_name  = local.state_bucket_name
}

module "github_oidc" {
  source = "git::https://github.com/iamwonodi/terraform-aws-oidc.git?ref=v1.1.0"

  # ---------------------------------------------------------------------------
  # Core Repository
  # ---------------------------------------------------------------------------
  # The environment subjects come from github-identity, not the module's
  # defaults: every workflow job declares a GitHub Environment, and GitHub then
  # issues its token with an environment subject, which the default
  # pull-request and branch subjects would never match.
  # ---------------------------------------------------------------------------

  github_repository    = var.github_repository
  github_oidc_subjects = module.github_identity.oidc_subjects

  # ---------------------------------------------------------------------------
  # Core Deployment Role
  # ---------------------------------------------------------------------------
  # One administrator role per account. Its safety comes from the GitHub
  # Environments that guard it (reviewers, allowed branches), not from a trimmed
  # policy: a role that creates IAM roles can grant itself anything. See the
  # README for the controls this depends on.
  # ---------------------------------------------------------------------------

  core_role_name = local.core_deploy_role_name
  core_role_policy_arns = [
    "arn:aws:iam::aws:policy/AdministratorAccess"
  ]

  # ---------------------------------------------------------------------------
  # Tags
  # ---------------------------------------------------------------------------

  tags = local.common_tags
}

# The service roles are a SEPARATE instance of the OIDC module, on purpose.
# scripts/bootstrap-environment.sh applies module.github_oidc alone (with
# -target) to create the first role, before any other infrastructure exists.
# Terraform pulls in everything a targeted resource depends on, and the service
# roles depend on the network, fleets and buckets (their policies name them).
# Keeping them in their own instance lets the bootstrap create only the
# provider and the core role.
module "github_service_roles" {
  source = "git::https://github.com/iamwonodi/terraform-aws-oidc.git?ref=v1.1.0"

  create_oidc_provider = false # already created by module.github_oidc
  create_core_role     = false

  service_roles = module.service_roles.service_roles

  tags = local.common_tags

  depends_on = [module.github_oidc]
}

################################################################################
# NETWORK
#
# The VPC, its four subnet tiers, routing, NACLs, and tier security
# groups. The edge module below depends on this one's outputs; this one
# depends on nothing else in this environment.
################################################################################

module "network" {
  source = "../../modules/network"

  project_name = var.project_name
  environment  = local.environment

  vpc_cidr              = var.vpc_cidr
  public_subnet_cidrs   = var.public_subnet_cidrs
  private_subnet_cidrs  = var.private_subnet_cidrs
  internal_subnet_cidrs = var.internal_subnet_cidrs
  isolated_subnet_cidrs = var.isolated_subnet_cidrs

  public_summary_cidr   = var.public_summary_cidr
  private_summary_cidr  = var.private_summary_cidr
  internal_summary_cidr = var.internal_summary_cidr
  isolated_summary_cidr = var.isolated_summary_cidr

  nat_type = var.nat_type

  # The isolated tier here holds only managed databases and their provisioning
  # functions, which need Secrets Manager and nothing else. The services' own
  # hosts reach every other AWS API through the NAT. Each endpoint left out saves
  # its hourly charge.
  isolated_interface_endpoints = ["secretsmanager"]
}

################################################################################
# EDGE
#
# The assets bucket, CloudFront, both ALBs, Route 53, and ACM -- how a
# request actually reaches this project, and how DNS resolves along the
# way.
#
# This environment does not call the compute or database domain modules (see
# this environment's README) -- edge only ever needed network's outputs,
# never compute's or data's, so nothing here changes as a result.
################################################################################

module "edge" {
  source = "../../modules/edge"

  # Off: no internal-tier load balancer, and no private DNS wildcard pointing at
  # one. Turn it on when the first internal-tier service arrives.
  internal_tier_enabled = var.internal_tier_enabled

  project_name = var.project_name
  environment  = local.environment
  aws_region   = var.aws_region

  vpc_id                    = module.network.vpc_id
  private_subnet_ids        = module.network.private_subnet_ids
  internal_subnet_ids       = module.network.internal_subnet_ids
  private_security_group_id = module.network.private_security_group_id

  domain_name    = var.domain_name
  private_domain = var.private_domain

  assets_path                               = var.assets_path
  assets_force_destroy                      = var.assets_force_destroy
  assets_noncurrent_version_expiration_days = var.assets_noncurrent_version_expiration_days
}

################################################################################
# GOLDEN IMAGE AND PLATFORM SCRIPTS
#
# This environment has no shared fleets: each service creates its own hosts. Core
# still owns the IMAGE those hosts boot and the SCRIPTS they run, because
# patching decides it -- a fix is then one rebuild and one upload, not one per
# service repository, and the copy nobody remembers is the one that stays
# vulnerable.
#
# A service reads the AMI's ID from the SSM parameter named in the platform
# contract, so core rebuilding the image reaches that service on its next plan.
################################################################################

module "image" {
  source = "../../modules/compute/image"

  project_name = var.project_name
  environment  = local.environment

  parent_image = var.ubuntu_parent_image

  # The build installs packages, Docker and the AWS CLI, so it needs outbound
  # internet access: the internal tier, which routes through NAT, never the
  # isolated one.
  subnet_id          = module.network.internal_subnet_ids[0]
  security_group_ids = [module.network.internal_security_group_id]

  tags = local.common_tags
}

module "deploy" {
  source = "../../modules/compute/deploy-bucket"

  project_name = var.project_name
  environment  = local.environment

  fleet_update_script_path = "${path.module}/../../modules/compute/assets/update.sh"
}

################################################################################
# MANAGED DATABASES
#
# One instance per ACTIVE engine, in the isolated tier, shared by the services of
# this environment: each service gets its own database and user on it, exactly as
# it does on the EC2 database host that development uses.
#
# Every engine the platform offers is declared here; none is created until it is
# listed in database_engines (terraform.tfvars). Nothing runs, and nothing is
# billed, for an engine this environment does not use.
#
#   postgres   RDS for PostgreSQL
#   mysql      RDS for MySQL
#   mongodb    Amazon DocumentDB (MongoDB-compatible), a cluster of
#              documentdb_instance_count instances
#
# Production runs a standby in a second availability zone. The standby serves no reads; it exists to fail over to.
#
# The administrator credentials are generated and stored HERE. The module takes
# them as inputs rather than owning them, so they live with every other secret
# this platform generates.
################################################################################

locals {
  # Every active engine, and the ones among them that run on RDS. mongodb runs on
  # DocumentDB instead.
  database_engines   = toset(var.database_engines)
  rds_engines        = toset([for engine in var.database_engines : engine if contains(["postgres", "mysql"], engine)])
  documentdb_enabled = contains(var.database_engines, "mongodb")

  # The provisioning function speaks every engine, so each active one gets one.
  provisioned_engines = local.database_engines

  # Where each active engine is, whichever service runs it.
  database_endpoints = merge(
    {
      for engine in local.rds_engines : engine => {
        host              = module.database[engine].address
        port              = module.database[engine].port
        security_group_id = module.database[engine].security_group_id
      }
    },
    local.documentdb_enabled ? {
      mongodb = {
        host              = module.documentdb[0].endpoint
        port              = module.documentdb[0].port
        security_group_id = module.documentdb[0].security_group_id
      }
    } : {},
  )

  # The database the administrator connects to before a service's own exists.
  admin_databases = {
    postgres = "postgres"
    mysql    = "platform"
    mongodb  = "admin" # DocumentDB keeps every user there
  }

  rds_engine_settings = {
    postgres = {
      # PostgreSQL always has a "postgres" database to connect to first.
      initial_database = null
      log_exports      = ["postgresql", "upgrade"]
    }
    mysql = {
      # MySQL has no database until one is created with the instance.
      initial_database = "platform"
      # error only: the general and audit logs bill for every statement.
      log_exports = ["error"]
    }
  }
}

resource "random_password" "database_admin" {
  for_each = local.database_engines

  # 40 fits every engine: MySQL accepts at most 41 characters, DocumentDB 100.
  length  = 40
  special = true

  # Letters, digits and -_. only: the alphabet every generated secret in this
  # platform uses, so a value is safe in an env file, a connection string and SQL.
  # RDS separately rejects /, " and @.
  override_special = "-_."
}

module "database_admin_secret" {
  source   = "git::https://github.com/iamwonodi/terraform-aws-secrets-vault.git?ref=v1.0.0"
  for_each = local.database_engines

  project_name = var.project_name
  environment  = local.environment
  service_name = "database-admin-${each.key}"

  secret_kv_pairs = {
    username = local.database_admin_username
    password = random_password.database_admin[each.key].result
    engine   = each.key
    host     = local.database_endpoints[each.key].host
    port     = tostring(local.database_endpoints[each.key].port)
    dbname   = local.admin_databases[each.key]
  }
}

module "database" {
  source   = "git::https://github.com/iamwonodi/terraform-aws-rds-instance.git?ref=v1.0.1"
  for_each = local.rds_engines

  project_name = var.project_name
  environment  = local.environment

  # The engine also names the instance (<project>-<environment>-<engine>), so two
  # engines never collide.
  engine                = each.key
  initial_database_name = local.rds_engine_settings[each.key].initial_database

  instance_class = var.database_instance_class
  multi_az       = var.database_multi_az

  master_username = local.database_admin_username
  master_password = random_password.database_admin[each.key].result

  allocated_storage     = var.database_allocated_storage
  max_allocated_storage = var.database_max_allocated_storage

  backup_retention_period = var.database_backup_retention_days

  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.isolated_subnet_ids

  # Only the tiers whose hosts run the services, and the team's tools (a
  # database GUI), may reach it.
  allowed_security_group_ids = [
    module.network.private_security_group_id,
    module.network.internal_security_group_id,
    module.network.tools_security_group_id,
  ]

  enabled_cloudwatch_logs_exports = local.rds_engine_settings[each.key].log_exports

  tags = local.common_tags
}

# MongoDB: one DocumentDB cluster. Its instances are spread across the isolated
# subnets' zones; with more than one, a reader takes over if the writer fails.
module "documentdb" {
  source = "git::https://github.com/iamwonodi/terraform-aws-documentdb.git?ref=v1.0.1"
  count  = local.documentdb_enabled ? 1 : 0

  project_name = var.project_name
  environment  = local.environment
  name         = "mongodb"

  master_username = local.database_admin_username
  master_password = random_password.database_admin["mongodb"].result

  instance_count = var.documentdb_instance_count
  instance_class = var.documentdb_instance_class

  backup_retention_period = var.database_backup_retention_days

  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.isolated_subnet_ids

  # Only the tiers whose hosts run the services, and the team's tools (a
  # database GUI), may reach it.
  allowed_security_group_ids = [
    module.network.private_security_group_id,
    module.network.internal_security_group_id,
    module.network.tools_security_group_id,
  ]

  tags = local.common_tags
}

# The instances have no container to run core's provisioning script in, so a
# Lambda inside the VPC does that job, one per engine. A service's infrastructure
# repository invokes its engine's function after its own apply.
module "database_provisioning" {
  source   = "../../modules/database/provisioning"
  for_each = local.provisioned_engines

  project_name = var.project_name
  environment  = local.environment

  engine         = each.key
  admin_database = local.admin_databases[each.key]

  database_host              = local.database_endpoints[each.key].host
  database_port              = local.database_endpoints[each.key].port
  database_security_group_id = local.database_endpoints[each.key].security_group_id
  admin_secret_arn           = module.database_admin_secret[each.key].secret_arn

  # Each function also brings the team's logins (agent_<name>) on its engine in
  # line with the people secret.
  people_secret_arn = module.people.secret_arn

  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.isolated_subnet_ids

  tags = local.common_tags
}

################################################################################
# PEOPLE
#
# The team members who use the team tools, from data/people.json (ships empty;
# see data/README.md). Each gets a database login, agent_<name>, whose password
# is kept in one secret that only administrators read and hand over.
# Production's tools are reached only through a private tunnel, so there is no front door, and everyone is read-only.
################################################################################

module "people" {
  source = "../../modules/platform/people"

  project_name = var.project_name
  environment  = local.environment
  account_id   = data.aws_caller_identity.current.account_id

  people = jsondecode(file("${path.module}/data/people.json"))

  read_only  = true
  front_door = false

  tags = local.common_tags
}

################################################################################
# PLATFORM CONTRACT
#
# What a service's repositories need to know about this environment, published as
# one SSM parameter (see docs/platform-contract.md). Services here are dedicated,
# so the shared-hosting fields are absent and the permissions boundary is present.
################################################################################

module "platform_contract" {
  source = "../../modules/platform/contract"

  project_name = var.project_name
  environment  = local.environment
  aws_region   = var.aws_region
  account_id   = data.aws_caller_identity.current.account_id

  domain_name    = var.domain_name
  private_domain = var.private_domain
  vpc_id         = module.network.vpc_id

  hosting_model        = "dedicated"
  service_boundary_arn = aws_iam_policy.service_boundary.arn

  ami_parameter_name         = module.image.parameter_name
  deploy_bucket_name         = module.deploy.bucket_name
  scripts_manifest_parameter = module.deploy.scripts_manifest_parameter

  # The single-database fields keep describing PostgreSQL, for services written
  # before an environment could run more than one engine.
  database_host                    = try(module.database["postgres"].address, null)
  database_provision_function_name = try(module.database_provisioning["postgres"].function_name, null)

  database_engines = {
    for engine, endpoint in local.database_endpoints : engine => {
      host               = endpoint.host
      port               = endpoint.port
      provision_function = try(module.database_provisioning[engine].function_name, null)
    }
  }

  assets_bucket_name         = module.edge.assets_bucket_id
  isolated_security_group_id = module.network.isolated_security_group_id

  # The team's own tools run in the private subnets on hosts of their own,
  # wearing the tools group rather than a customer tier's.
  tools = {
    security_group_id = module.network.tools_security_group_id
    subnet_ids        = module.network.private_subnet_ids
  }

  # The sign-in the tools' web addresses sit behind. Null in production.
  team_front_door = module.people.front_door

  # The internal tier exists only while internal_tier_enabled is on.
  tiers = merge(
    {
      # Services here create their own hosts, so the contract tells them where the
      # tier's subnets are rather than making every service repository hard-code them.
      # Their hosts also wear the tier's security group: the databases and the
      # Secrets Manager endpoint admit that group, not each service's own.
      private = {
        listener_arn          = nonsensitive(module.edge.private_alb_https_listener_arn)
        alb_security_group_id = module.edge.private_alb_security_group_id
        security_group_id     = module.network.private_security_group_id
        subnet_ids            = module.network.private_subnet_ids
      }
    },
    var.internal_tier_enabled ? {
      internal = {
        listener_arn          = nonsensitive(module.edge.internal_alb_https_listener_arn)
        alb_security_group_id = module.edge.internal_alb_security_group_id
        security_group_id     = module.network.internal_security_group_id
        subnet_ids            = module.network.internal_subnet_ids
      }
    } : {},
  )
}

resource "aws_ssm_parameter" "platform_config" {
  name        = module.platform_contract.parameter_name
  description = "What a service's repositories need to know about this environment (schema version ${module.platform_contract.schema_version})."
  type        = "String"
  value       = module.platform_contract.config_json
}
