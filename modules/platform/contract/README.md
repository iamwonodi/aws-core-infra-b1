# Platform Contract Module

Builds the one document a service repository reads to learn about the environment it deploys onto. Creates no resources: the caller creates the SSM parameter from `config_json`, so the module can be tested without AWS.

| Output | Meaning |
| --- | --- |
| `parameter_name` | `/<project>/platform/config` (no environment segment: one AWS account per environment) |
| `config_json` | the document |
| `schema_version` | version of its shape |

The shape, how a service consumes it, what is deliberately left out, and how it may change are in [docs/platform-contract.md](../../docs/platform-contract.md).

The module fails the plan if the document would exceed 4,096 characters, the limit of an SSM standard parameter. Run its tests with `terraform test`.
