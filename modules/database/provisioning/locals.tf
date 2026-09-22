locals {
  name = coalesce(var.name, var.engine)

  function_name = "${var.project_name}-${var.environment}-${local.name}-provision"

  # Core's own convention, which the service-roles module and the EC2 database
  # host both already follow.
  service_secret_pattern = coalesce(
    var.service_secret_pattern,
    "${var.project_name}-{service}-${var.environment}-secret-vault",
  )

  aws_region = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id

  tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    },
    var.tags,
  )
}
