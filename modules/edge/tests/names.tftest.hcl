# Load balancer names fit AWS's 32-character limit for the longest project
# name init-project allows (16 characters), in every environment. Run by
# run.sh against variables.tf and locals.tf only.

variables {
  project_name              = "abcdefghijklmnop"
  aws_region                = "af-south-1"
  vpc_id                    = "vpc-0123456789abcdef0"
  private_subnet_ids        = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  internal_subnet_ids       = ["subnet-0123456789abcdef2", "subnet-0123456789abcdef3"]
  private_security_group_id = "sg-0123456789abcdef0"
  domain_name               = "example.org"
  private_domain            = "example.org"
  assets_path               = "."
}

run "development" {
  command = plan

  variables {
    environment = "development"
  }

  assert {
    condition     = local.private_load_balancer_name == "abcdefghijklmnop-dev-priv" && local.internal_load_balancer_name == "abcdefghijklmnop-dev-int"
    error_message = "Development's load balancers should be <project>-dev-priv and <project>-dev-int."
  }

  assert {
    condition     = length(local.private_load_balancer_name) <= 32 && length(local.internal_load_balancer_name) <= 32
    error_message = "Load balancer names must fit AWS's 32 characters."
  }
}

run "staging" {
  command = plan

  variables {
    environment = "staging"
  }

  assert {
    condition     = local.private_load_balancer_name == "abcdefghijklmnop-stg-priv" && length(local.private_load_balancer_name) <= 32
    error_message = "Staging's private load balancer should be <project>-stg-priv, within 32 characters."
  }
}

run "production" {
  command = plan

  variables {
    environment = "production"
  }

  assert {
    condition     = local.private_load_balancer_name == "abcdefghijklmnop-prd-priv" && length(local.private_load_balancer_name) <= 32
    error_message = "Production's private load balancer should be <project>-prd-priv, within 32 characters."
  }
}
