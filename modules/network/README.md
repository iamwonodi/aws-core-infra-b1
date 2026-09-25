# Network Domain Module

This module is the foundation everything else in this project sits on: the VPC, its four subnet tiers, routing, perimeter firewalling, and the security groups every other domain module attaches its resources to.

If you're new to this repo: think of this module as answering **"where can things live, and what can reach what?"** It creates no application resources of its own -- no compute, no load balancers, no database. Every other domain module (`compute`, `edge`, `data`) depends on this one; this one depends on nothing else in the project.

---

## The four tiers

| Tier | What lives here | Internet access |
| --- | --- | --- |
| Public | Only the Internet Gateway and NAT Gateway | Direct |
| Private | Frontend, backend API, DB GUI client | Outbound only, via NAT |
| Internal | Stateless internal applications (payment, notifications, and others) | Outbound only, via NAT |
| Isolated | The database | None -- no NAT route at all; reaches AWS services only through VPC endpoints |

This tiering is the backbone of the whole project's security model: a request from the internet can only ever reach the private tier (through CloudFront and an ALB, both defined in the `edge` module), the private tier is the only thing that can reach the internal tier, and the isolated tier is reachable by neither directly -- only by whatever application code the `data` module's database host runs, over the VPC endpoints this module creates.

---

## What this module creates

* **The VPC, Internet Gateway and its subnets** (`vpc_base`) -- one subnet per tier, per Availability Zone.
* **A NAT** -- gives private and internal hosts outbound internet access without exposing them. `nat_type = "gateway"` creates a managed NAT Gateway; `"instance"` a small NAT instance (`terraform-aws-nat-instance`), far cheaper but with outbound traffic stopped while it is recovered or replaced. The isolated tier has no route through either.
* **Route tables** (`route_tables`) -- wires each tier to the right target: public to the Internet Gateway, private/internal/vpc-endpoint through NAT, isolated with no default route out.
* **Network ACLs** (`nacl_security`, called internally as `../nacl-security`) -- subnet-level, stateless firewalling as a second layer of defense on top of the security groups below.
* **One security group per tier**, plus one for VPC endpoints -- each starts with no ingress rules of its own. Ingress is added by whichever domain module actually needs to open a specific port (for example, the `edge` module's ALB ingress rules), so "what's allowed in" is defined next to whatever resource actually needs it, not centralized here.
* **A single outbound (egress) rule** for public, private, internal, and vpc-endpoint security groups. Outbound traffic isn't this architecture's primary control point -- inbound rules and subnet routing are -- so this stays permissive by design. The isolated tier gets narrower ones instead: everything within the VPC (the interface endpoints and the VPC's own hosts), and HTTPS to S3 through the gateway endpoint's prefix list. It has no NAT route, so nothing it sends reaches the internet.
* **VPC endpoints** -- S3 (a gateway endpoint, free), plus the interface endpoints in `isolated_interface_endpoints` (by default ECR, SSM, Secrets Manager, KMS and Logs, for development's database host). They live in the isolated subnets but, through private DNS, serve every host in the VPC, so their security group admits the private, internal and isolated tiers on 443. Each interface endpoint is billed per hour; staging and production keep only Secrets Manager, and their services' hosts reach the other AWS APIs through the NAT.

---

## What this module hands back

| Output | Used by |
| --- | --- |
| `vpc_id` | `edge` (private Route 53 zone association), `database` (isolated tier placement, indirectly through subnet/SG outputs) |
| `private_subnet_ids` / `internal_subnet_ids` / `isolated_subnet_ids` | `compute` and `edge` (fleet/ALB placement), `database` (database placement) |
| `public_subnet_ids` | Available for future use; nothing currently consumes it |
| `private_security_group_id` / `internal_security_group_id` / `isolated_security_group_id` | `compute` and `edge` (attaching fleets/ALBs to the right tier), `database` (database placement) |
| `public_security_group_id` | Available for future use; nothing currently consumes it |

---

## On `validations.tf`

Each tier's `*_summary_cidr` is used by the NACL module as a single stand-in for "every subnet in this tier." If a summary CIDR doesn't actually cover its tier's real subnet CIDRs, NACL rules meant for the whole tier silently apply to the wrong address range instead -- a real, security-relevant mistake.

`validations.tf` enforces these invariants as **resource preconditions**, so a violation stops the plan with an error naming the offending CIDRs. (A `check` block would only print a warning and let the plan continue.)

* `vpc_cidr` has a prefix length between `/16` and `/28`, the range AWS allows.
* `vpc_cidr` sits inside private address space: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` or `100.64.0.0/10`. A public range would make the real internet hosts at those addresses unreachable from inside the VPC.
* Every summary CIDR lies inside `vpc_cidr`.
* Every subnet CIDR lies inside its own tier's summary CIDR.
* No two tier summary CIDRs overlap.

Containment is tested by comparing network addresses at the summary's prefix length, so the module still works on Terraform 1.6 without `cidrcontains()`. The preconditions live on a `terraform_data` resource, which manages no infrastructure and needs no provider; it appears once in the plan as a resource to create.

---

## Requirements

* Terraform `>= 1.6.0`
* AWS provider `>= 6.0, < 7.0`

---

## Module Structure

```text
network/
├── main.tf          -- VPC, NAT, routing, NACLs, security groups, egress rules, VPC endpoints
├── variables.tf      -- every input, each with inline validation
├── validations.tf    -- cross-variable invariants (VPC range, summary and subnet containment, no overlap)
├── locals.tf          -- naming for security groups and endpoint ports
├── outputs.tf
└── README.md
```

Calls `../nacl-security` (a sibling module) internally.
