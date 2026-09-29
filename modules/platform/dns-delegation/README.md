# dns-delegation

One Route 53 **reusable delegation set** per environment: a fixed set of four name servers. The environment's public zone is created with it (the edge module's `public_delegation_set_id`), so a public zone that is destroyed and rebuilt answers on the **same** name servers, and the domain's delegation at the registrar never has to change.

The destroy workflow keeps this module, as it keeps CI's own role. It depends on nothing else, so destroying the rest never takes it along; `scripts/ci/check-environment-wiring.py` fails CI if that ever changes. To retire an environment completely, remove it from a laptop ([runbook](../../../docs/runbook.md#destroying-an-environment)).

## Inputs

| Name | Description |
| --- | --- |
| `project_name` | Project name, in the reference name |
| `environment` | Environment name, in the reference name |

## Outputs

| Name | Description |
| --- | --- |
| `id` | The delegation set's ID, for the public zone |
| `name_servers` | The four name servers to set as the domain's NS records at the registrar |

## Tests

```bash
terraform init -backend=false && terraform test
```
