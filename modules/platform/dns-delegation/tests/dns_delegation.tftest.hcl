# The delegation set, with AWS mocked.

mock_provider "aws" {
  mock_resource "aws_route53_delegation_set" {
    defaults = {
      id           = "N0123456789ABCDEFGHIJ"
      name_servers = ["ns-1.awsdns-01.com", "ns-2.awsdns-02.net", "ns-3.awsdns-03.org", "ns-4.awsdns-04.co.uk"]
    }
  }
}

variables {
  project_name = "modart"
  environment  = "development"
}

run "named_for_its_project_and_environment" {
  command = plan

  assert {
    condition     = aws_route53_delegation_set.this.reference_name == "modart-development-public"
    error_message = "the reference name is <project>-<environment>-public"
  }
}

run "hands_out_its_id_and_name_servers" {
  command = apply

  assert {
    condition     = output.id == "N0123456789ABCDEFGHIJ"
    error_message = "the ID is what the public zone takes"
  }

  assert {
    condition     = length(output.name_servers) == 4
    error_message = "the four name servers are what the registrar is given"
  }
}

run "an_empty_environment_is_refused" {
  command = plan

  variables {
    environment = " "
  }

  expect_failures = [var.environment]
}
