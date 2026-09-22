################################################################################
# GITHUB ACTIONS OIDC
#
# The trust relationship CI itself uses to deploy this environment. 
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
module "service_roles" {
  source = "../../modules/platform/service-roles"

  project_name   = var.project_name
  environment    = local.environment
  aws_region     = var.aws_region
  account_id     = data.aws_caller_identity.current.account_id
  subject_format = var.oidc_subject_format

  entries = jsondecode(file("${path.module}/data/service-roles.json"))

  # Services run on the shared tier fleets here, so no IAM is granted to them.
  hosting_model = "shared"

  tiers = {
    private = {
      listener_arn      = nonsensitive(module.edge.private_alb_https_listener_arn)
      asg_arn           = module.compute.private_asg_arn
      security_group_id = module.network.private_security_group_id
    }
    internal = {
      listener_arn      = nonsensitive(module.edge.internal_alb_https_listener_arn)
      asg_arn           = module.compute.internal_asg_arn
      security_group_id = module.network.internal_security_group_id
    }
  }

  deploy_bucket_name         = module.compute.deploy_bucket_name
  assets_bucket_name         = module.edge.assets_bucket_id
  state_bucket_name          = local.state_bucket_name
  fleet_update_document_name = module.compute.fleet_update_document_name

  # Lets each service's infra repository create its own database on the database
  # host, through that one document and on that host alone.
  database_provision_document_name = module.database.provision_document_name
}

# The role the platforms team's pipeline assumes to publish the database engines.
# Grants nothing until database_engines_repository is set.
module "database_engines_role" {
  source = "../../modules/platform/engines-role"

  project_name   = var.project_name
  environment    = local.environment
  aws_region     = var.aws_region
  account_id     = data.aws_caller_identity.current.account_id
  subject_format = var.oidc_subject_format

  repository = var.database_engines_repository == null ? null : {
    name          = var.database_engines_repository
    owner_id      = var.database_engines_repository_owner_id
    repository_id = var.database_engines_repository_id
  }

  deploy_bucket_name            = module.compute.deploy_bucket_name
  isolated_security_group_id    = module.network.isolated_security_group_id
  database_update_document_name = module.database.update_document_name
  state_bucket_name             = local.state_bucket_name
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

  # The service roles, plus the platforms team's role when its repository is set.
  service_roles = merge(
    module.service_roles.service_roles,
    module.database_engines_role.service_roles,
  )

  tags = local.common_tags

  depends_on = [module.github_oidc]
}

################################################################################
# NETWORK
#
# The VPC, Internet Gateway, NAT Gateway, its four subnet tiers, routing, NACLs, and tier security
# groups. Every other domain module below depends on this one's outputs;
# this one depends on nothing else in this environment.
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
}

################################################################################
# COMPUTE
#
# The shared Ubuntu AMI, and the private-tier and internal-tier fleets
# that run it.
################################################################################

module "compute" {
  source = "../../modules/compute"

  project_name = var.project_name
  environment  = local.environment

  private_subnet_ids         = module.network.private_subnet_ids
  internal_subnet_ids        = module.network.internal_subnet_ids
  private_security_group_id  = module.network.private_security_group_id
  internal_security_group_id = module.network.internal_security_group_id

  ubuntu_parent_image = var.ubuntu_parent_image
  ami_description     = var.ami_description

  enable_predefined_packages = var.enable_predefined_packages
  enable_docker              = var.enable_docker
  enable_aws_cli             = var.enable_aws_cli
  enable_python              = var.enable_python

  custom_build_commands    = var.custom_build_commands
  custom_validate_commands = var.custom_validate_commands

  component_version = var.component_version
  recipe_version    = var.recipe_version

  root_volume_size = var.root_volume_size
  root_volume_type = var.root_volume_type

  ami_instance_types = var.instance_types

  build_image       = var.build_image
  ami_build_trigger = var.ami_build_trigger

  enable_pipeline            = var.enable_pipeline
  pipeline_schedule          = var.pipeline_schedule
  enable_image_tests         = var.enable_image_tests
  image_test_timeout_minutes = var.image_test_timeout_minutes
}

################################################################################
# EDGE
#
# The assets bucket, CloudFront, both ALBs, Route 53, and ACM -- how a
# request actually reaches this project, and how DNS resolves along the
# way.
################################################################################

module "edge" {
  source = "../../modules/edge"

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
# DATABASE
#
# The database host and its own secret. Deliberately a single instance,
# not a fleet -- see the database module's own README for why.
################################################################################

module "database" {
  source = "../../modules/database/host"

  project_name = var.project_name
  environment  = local.environment

  isolated_subnet_ids        = module.network.isolated_subnet_ids
  isolated_security_group_id = module.network.isolated_security_group_id

  ami_id          = module.compute.ami_id
  private_zone_id = module.edge.private_zone_id
  private_domain  = var.private_domain

  deploy_bucket_name = module.compute.deploy_bucket_name
  deploy_bucket_arn  = module.compute.deploy_bucket_arn

  db_instance_type               = var.db_instance_type
  db_root_volume_size            = var.db_root_volume_size
  db_associate_public_ip_address = var.db_associate_public_ip_address

  db_enable_route53_write_access     = var.db_enable_route53_write_access
  db_enable_ecr_read_access          = var.db_enable_ecr_read_access
  db_enable_private_dns_registration = var.db_enable_private_dns_registration

  db_enable_data_volume_mount = var.db_enable_data_volume_mount
  db_data_volume_device       = var.db_data_volume_device
  db_data_volume_size         = var.db_data_volume_size
  db_data_volume_mount_path   = var.db_data_volume_mount_path
}

################################################################################
# PLATFORM CONTRACT
#
# Everything a service repository needs to know about this environment, as one
# SSM parameter. Services read it with a data source and never read core's
# Terraform state, which holds every secret core generated. The shape and how to
# consume it are documented in docs/platform-contract.md.
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

  ami_parameter_name               = module.compute.ami_parameter_name
  scripts_manifest_parameter       = module.compute.scripts_manifest_parameter
  deploy_bucket_name               = module.compute.deploy_bucket_name
  assets_bucket_name               = module.edge.assets_bucket_id
  fleet_update_document_name       = module.compute.fleet_update_document_name
  isolated_security_group_id       = module.network.isolated_security_group_id
  database_host                    = module.database.host
  database_provision_document_name = module.database.provision_document_name
  database_update_document_name    = module.database.update_document_name

  tiers = {
    private = {
      security_group_id     = module.network.private_security_group_id
      alb_security_group_id = module.edge.private_alb_security_group_id
      asg_name              = module.compute.private_asg_name
      listener_arn          = nonsensitive(module.edge.private_alb_https_listener_arn)
    }
    internal = {
      security_group_id     = module.network.internal_security_group_id
      alb_security_group_id = module.edge.internal_alb_security_group_id
      asg_name              = module.compute.internal_asg_name
      listener_arn          = nonsensitive(module.edge.internal_alb_https_listener_arn)
    }
  }
}

resource "aws_ssm_parameter" "platform_config" {
  name        = module.platform_contract.parameter_name
  description = "What a service repository needs to know about this environment (schema version ${module.platform_contract.schema_version})."
  type        = "String"
  value       = module.platform_contract.config_json
}
