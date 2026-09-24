# ------------------------------------------------------------------------------
# DATABASE PROVISIONING
#
# Creates one service's database and user on a MANAGED database.
#
# The EC2 database host runs core's SQL by exec-ing into the engine's container.
# A managed database has no container to exec into, and sits in the isolated tier
# where nothing outside the VPC can reach it, so the same job is done by a Lambda
# that runs inside the VPC.
#
#   the service's infra repository  ->  lambda:InvokeFunction  ->  this function
#                                                                       |
#                            reads the administrator secret and the service's own
#                            secret, then runs the same statements core's SQL runs
#
# The payload names only the service. The function derives the secret's name from
# it, so a caller cannot point it at another service's credential, and it runs no
# SQL the caller supplies.
#
# Logs: the isolated subnets have no route to the internet, so the function can
# only reach CloudWatch Logs through an interface endpoint. The network module
# creates one. Without it the function would run and write nothing, and a failure
# would be invisible.
# ------------------------------------------------------------------------------

# The function's own group, so the database's rule names the function rather than
# a whole subnet. It needs no ingress: it only makes outbound connections.
resource "aws_security_group" "this" {
  name        = "${local.function_name}-sg"
  description = "Provisioning function ${local.function_name}."
  vpc_id      = var.vpc_id

  tags = merge(local.tags, { Name = "${local.function_name}-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "database" {
  security_group_id            = var.database_security_group_id
  referenced_security_group_id = aws_security_group.this.id

  description = "Allow ${local.function_name} to reach the database."

  ip_protocol = "tcp"
  from_port   = var.database_port
  to_port     = var.database_port

  tags = local.tags
}

resource "aws_iam_role" "this" {
  name               = "${local.function_name}-role"
  description        = "Creates services' databases and users on ${var.database_host}."
  assume_role_policy = data.aws_iam_policy_document.trust.json

  tags = local.tags
}

resource "aws_iam_role_policy" "this" {
  name   = "provisioning"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.this.json
}

# Created here rather than by the function's first run, so that it has a retention
# from the start: a log group Lambda creates keeps its logs for ever.
resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days

  tags = local.tags
}

resource "aws_lambda_function" "this" {
  function_name = local.function_name
  description   = "Creates a service's database and user on ${var.database_host}."

  role    = aws_iam_role.this.arn
  handler = "provision.handler"
  runtime = "python3.14"

  filename         = data.archive_file.provision.output_path
  source_code_hash = data.archive_file.provision.output_base64sha256

  timeout     = var.timeout_seconds
  memory_size = 256

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [aws_security_group.this.id]
  }

  environment {
    variables = merge(
      {
        DATABASE_HOST          = var.database_host
        DATABASE_PORT          = tostring(var.database_port)
        ADMIN_SECRET_ARN       = var.admin_secret_arn
        ADMIN_DATABASE         = var.admin_database
        ENGINE                 = var.engine
        SERVICE_SECRET_PATTERN = local.service_secret_pattern
      },
      var.people_secret_arn == null ? {} : { PEOPLE_SECRET_ARN = var.people_secret_arn },
    )
  }

  tags = merge(local.tags, { Name = local.function_name })

  # The role's policy and the log group must exist before the first invocation,
  # and the database must be reachable before the function is of any use.
  depends_on = [
    aws_iam_role_policy.this,
    aws_cloudwatch_log_group.this,
    aws_vpc_security_group_ingress_rule.database,
  ]

  # The function verifies every database's certificate against this bundle and
  # refuses to connect without it, so a plan without it stops here, before
  # anything is deployed.
  lifecycle {
    precondition {
      condition     = fileexists("${path.module}/lambda/certificates/rds-global-bundle.pem")
      error_message = "modules/database/provisioning/lambda/certificates/rds-global-bundle.pem is missing: the provisioning function verifies database certificates against it. Download it from AWS (certificates/README.md) and commit it."
    }
  }
}
