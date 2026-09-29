# ------------------------------------------------------------------------------
# PLATFORM CONTRACT
#
# Everything a service repository needs to know about the environment it deploys
# onto, as ONE document. Core publishes it as an SSM parameter and services read
# it with a data source; a service never reads core's Terraform state, which
# holds every secret core generated.
#
# The module only BUILDS the document. It creates no resources, so it can be
# tested without AWS; the caller creates the parameter.
#
# CHANGING THE SHAPE: adding a field is compatible. Renaming or removing one, or
# changing its meaning, must bump schema_version, and services check the
# version they were written for (see docs/platform-contract.md).
# ------------------------------------------------------------------------------

resource "terraform_data" "contract_invariants" {
  lifecycle {
    precondition {
      condition     = var.database_provision_document_name == null || var.database_provision_function_name == null
      error_message = "A database is provisioned either by an SSM document on the EC2 host or by a Lambda on a managed instance, never both. Set only one."
    }

    precondition {
      condition     = length(local.config_json) <= local.parameter_size_limit
      error_message = "The platform contract is ${length(local.config_json)} characters, over the ${local.parameter_size_limit} an SSM standard parameter can hold."
    }
  }
}
