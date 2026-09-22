# Golden Image Module

Builds **one AMI per environment** and publishes its ID as an SSM parameter.

```text
core                                   a service's own Terraform
────                                   ────────────────────────
Image Builder                          data "aws_ssm_parameter"
      |                                          ^
      v                                          |
/<project>/platform/ami/ubuntu  ─────────────────┘
      |
      v
launch template -> ASG
```

## Why core owns it

**Patching decides it.** One image per environment means a CVE fix is one rebuild. If each service built its own, a fix would be N rebuilds, and the one nobody remembers is the one that stays vulnerable.

Nothing in the image varies per service either: it is a container host, and the application arrives as a container. Services also then need no Image Builder permissions, no `ec2:CreateImage` and no `iam:PassRole` to a build profile, which keeps their generated policy small and the permissions boundary tight.

## Read the parameter, do not copy the ID

The AMI ID is published as an SSM parameter and the platform contract carries the **parameter's name**, not the ID.

A service's launch template reads it with a data source, so when core rebuilds the image that service gets a new launch template version on its next plan and rolls it out. An ID copied once would freeze every service on whatever was current that day.

```hcl
data "aws_ssm_parameter" "ami" {
  name = local.platform.compute.ami_parameter
}

module "launch_template" {
  image_id = data.aws_ssm_parameter.ami.insecure_value
  ...
}
```

## The build needs internet

The build instance installs packages, Docker and the AWS CLI, so `subnet_id` must be a subnet with outbound internet access. In this platform that is the **internal** tier, which routes through NAT, never the isolated tier.

## Inputs and outputs

Inputs mirror `terraform-aws-ubuntu-ami` (packages, versions, volume, instance types, pipeline) plus `project_name`, `environment`, `parent_image`, `subnet_id` and `security_group_ids`.

| Output | |
| --- | --- |
| `parameter_name` | what services should read |
| `ami_id` | the current ID; prefer the parameter |
| `image_arn`, `pipeline_arn`, `instance_profile_name` | |
