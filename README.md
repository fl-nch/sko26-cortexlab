# sko26-cortexlab

AWS CloudFormation infrastructure for a single-account, single-environment
setup, organized by stack.

## Layout

```
templates/     CloudFormation templates, grouped by domain (one stack per file)
  network/     VPC and networking
  compute/     ECS / EC2 / Lambda services
  storage/     S3, DynamoDB, etc.
  iam/         Roles and policies
parameters/    Parameter values, one file per stack
config/        Deploy config: region, tags, stack order
scripts/       deploy / validate / delete helpers
tests/         cfn-lint and cfn-guard configs
docs/          Architecture notes
```

## Conventions

- **One template per stack**, grouping resources that share a lifecycle.
- **Parameters live in `parameters/<stack>.json`**, separate from templates.
- **Cross-stack wiring** via CloudFormation Exports/Imports (e.g. `vpc-id`).
- **Stacks are named** `sko26-cortexlab-<stack>` (e.g. `sko26-cortexlab-vpc`).

## Prerequisites

- AWS CLI v2, configured with credentials for the target account.
- (Recommended) [`cfn-lint`](https://github.com/aws-cloudformation/cfn-lint)
  for template validation.

## Usage

Validate all templates:

```bash
scripts/validate.sh
```

Deploy everything except the EKS stack:

```bash
scripts/deploy-part1.sh
```

Then deploy the EKS stack (takes ~15 minutes; needs part 1 in place first):

```bash
scripts/deploy-part2.sh
```

Deploy a single (non-EKS) stack:

```bash
scripts/deploy-part1.sh vpc
```

Tear down:

```bash
scripts/delete.sh
```

## Configuration

`config/config.yaml` is the single source of truth for the deployment. The
scripts read it (via `scripts/config.py`) for:

- `region` — target AWS region (override per-run with the `AWS_REGION` env var)
- `stackPrefix` — prefix for stack names (`<prefix>-<stack>`) and, via the
  `NamePrefix` template parameter, for resource names and the `Project` tag
- `tags` — applied to every stack
- `stacks` — the ordered list of stacks (deploy order; delete runs it in reverse)

## Adding a new stack

1. Add the template under the appropriate `templates/<domain>/` directory.
2. Add its parameter file under `parameters/` (use `[]` if it has no parameters).
3. Add an entry to the `stacks:` list in `config/config.yaml`, in deploy order.

No script changes are needed — the deploy scripts and `delete.sh` pick it up
from the config automatically. (The EKS stack is intentionally split out into
`deploy-part2.sh`; `deploy-part1.sh` skips it by name.)
