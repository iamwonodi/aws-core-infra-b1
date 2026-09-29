locals {
  function_name      = "${var.project_name}-${var.environment}-front-door"
  declaration_prefix = "front-door/"
  platform_key       = "${local.declaration_prefix}_platform.json"
}
