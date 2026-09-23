# The network module's invariants (validations.tf), tested in isolation.
# Run with: bash modules/network/tests/run.sh   -- see the note in that script.

variables {
  project_name = "core"
  environment  = "development"

  vpc_cidr              = "10.10.0.0/16"
  public_subnet_cidrs   = ["10.10.1.0/24", "10.10.2.0/24", "10.10.3.0/24"]
  private_subnet_cidrs  = ["10.10.17.0/24", "10.10.18.0/24", "10.10.19.0/24"]
  internal_subnet_cidrs = ["10.10.33.0/24", "10.10.34.0/24", "10.10.35.0/24"]
  isolated_subnet_cidrs = ["10.10.49.0/24", "10.10.50.0/24", "10.10.51.0/24"]
  public_summary_cidr   = "10.10.0.0/20"
  private_summary_cidr  = "10.10.16.0/20"
  internal_summary_cidr = "10.10.32.0/20"
  isolated_summary_cidr = "10.10.48.0/20"
}

run "the_default_layout_is_valid" {
  command = plan
}

run "another_private_range_is_valid" {
  command = plan

  variables {
    vpc_cidr              = "172.20.0.0/16"
    public_subnet_cidrs   = ["172.20.1.0/24"]
    private_subnet_cidrs  = ["172.20.17.0/24"]
    internal_subnet_cidrs = ["172.20.33.0/24"]
    isolated_subnet_cidrs = ["172.20.49.0/24"]
    public_summary_cidr   = "172.20.0.0/20"
    private_summary_cidr  = "172.20.16.0/20"
    internal_summary_cidr = "172.20.32.0/20"
    isolated_summary_cidr = "172.20.48.0/20"
  }
}

run "a_public_address_range_is_rejected" {
  command = plan

  variables {
    vpc_cidr              = "14.3.0.0/16"
    public_subnet_cidrs   = ["14.3.1.0/24"]
    private_subnet_cidrs  = ["14.3.17.0/24"]
    internal_subnet_cidrs = ["14.3.33.0/24"]
    isolated_subnet_cidrs = ["14.3.49.0/24"]
    public_summary_cidr   = "14.3.0.0/20"
    private_summary_cidr  = "14.3.16.0/20"
    internal_summary_cidr = "14.3.32.0/20"
    isolated_summary_cidr = "14.3.48.0/20"
  }

  expect_failures = [terraform_data.network_invariants]
}

run "a_vpc_larger_than_aws_allows_is_rejected" {
  command = plan

  variables {
    vpc_cidr = "10.0.0.0/8"
  }

  expect_failures = [terraform_data.network_invariants]
}

run "a_summary_outside_the_vpc_is_rejected" {
  command = plan

  variables {
    public_summary_cidr = "10.11.0.0/20"
  }

  expect_failures = [terraform_data.network_invariants]
}

run "a_subnet_outside_its_summary_is_rejected" {
  command = plan

  variables {
    private_summary_cidr = "10.10.17.0/24"
  }

  expect_failures = [terraform_data.network_invariants]
}

run "a_subnet_larger_than_its_summary_is_rejected" {
  command = plan

  variables {
    private_subnet_cidrs = ["10.10.16.0/19"]
  }

  expect_failures = [terraform_data.network_invariants]
}

run "overlapping_summaries_are_rejected" {
  command = plan

  variables {
    internal_summary_cidr = "10.10.16.0/20"
    internal_subnet_cidrs = ["10.10.17.0/24"]
  }

  expect_failures = [terraform_data.network_invariants]
}

run "a_single_interface_endpoint_is_valid" {
  command = plan

  variables {
    isolated_interface_endpoints = ["secretsmanager"]
  }
}

run "no_interface_endpoints_is_valid" {
  command = plan

  variables {
    isolated_interface_endpoints = []
  }
}

run "a_repeated_interface_endpoint_is_rejected" {
  command = plan

  variables {
    isolated_interface_endpoints = ["ssm", "ssm"]
  }

  expect_failures = [var.isolated_interface_endpoints]
}

run "an_interface_endpoint_that_is_not_a_service_name_is_rejected" {
  command = plan

  variables {
    isolated_interface_endpoints = ["com.amazonaws.af-south-1.ssm "]
  }

  expect_failures = [var.isolated_interface_endpoints]
}

run "a_nat_instance_is_valid" {
  command = plan

  variables {
    nat_type = "instance"
  }
}

run "an_unknown_nat_type_is_rejected" {
  command = plan

  variables {
    nat_type = "none"
  }

  expect_failures = [var.nat_type]
}
