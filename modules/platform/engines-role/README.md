# Database Engines Role Module

Generates the IAM role the **platforms team's** repository assumes. That team owns the database engines: they publish a compose file per engine and a registry to the deploy bucket, trigger the database host to apply them, open each engine's port on the isolated security group, and publish the port for services to read.

It grants nothing until `repository` is set.

| Purpose | Allowed | Scoped to |
| --- | --- | --- |
| Read the contract | `ssm:GetParameter` | `/<project>/platform/config` |
| Publish engines | S3 put, get, delete, list | deploy bucket, `database/*` |
| Apply them | `ssm:SendCommand` | the database-update document, on the instance tagged `Service=<database service>` |
| Publish ports | SSM parameters | `/<project>/database/engines/*` |
| Open ports | security group ingress | the isolated security group |
| Engine images | ECR create and push | `repository/<prefix>/*` (default `engines`) |
| Own state | S3 | state bucket, `platform/database-engines/*` |

**What AWS cannot scope:** IAM cannot limit which port or source a security group rule opens, so this role can change any inbound rule on the isolated group, where the databases live. Review changes to that repository as carefully as core's.

The database host has no internet path, so engine images must be mirrored into ECR; the ECR statement covers one repository prefix for that. Run the tests with `terraform test`.
