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
k8s/           Kubernetes workloads deployed onto the EKS cluster
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

Deploy the target app (GoCortex Broken Bank) onto the cluster. The EKS endpoint
is private, so this runs **from the Linux VM**. `deploy-part1.sh` pre-stages the
manifest and deploy script to the transfer bucket and the VM pulls them to
`/opt/cortexlab/` on boot, so in an SSM session on the Linux VM you just run:

```bash
/opt/cortexlab/scripts/deploy-app.sh          # apply k8s/gocortexbrokenbank.yaml, print access info
/opt/cortexlab/scripts/deploy-app.sh delete   # remove it
```

Deploy the Cortex Helm installer. Generate the Kubernetes/Helm installer in the
Cortex console, upload it to the transfer bucket's `cortex/` folder (pre-created
by `deploy-part1.sh`) from your workstation:

```bash
aws s3 cp <installer> s3://<transfer-bucket>/cortex/
```

Then, in an SSM session on the Linux VM, fetch it and deploy with helm:

```bash
/opt/cortexlab/scripts/fetch-cortex.sh    # -> /opt/cortexlab/cortex/
helm upgrade --install cortex /opt/cortexlab/cortex/<chart> [-f <values>]
```

Open an RDP desktop on the Windows VM (over SSM, no inbound rules). Run this
**locally** — it needs the aws CLI v2 and the AWS Session Manager plugin — then
point an RDP client at `localhost:13389`:

```bash
scripts/rdp-tunnel.sh            # forward localhost:13389 -> win-vm:3389
scripts/rdp-tunnel.sh 23389      # use a different local port
```

First time, set an Administrator password from a PowerShell SSM session
(`aws ssm start-session --target <id>` then `net user Administrator <pw>`).

On Windows, run this from **Git Bash** — the tunnel binds on the Windows side so
`mstsc.exe` reaches `localhost:13389` directly. It also works from **WSL**, but:
the Linux aws CLI + Session Manager plugin (and `python3`/`pyyaml`, or an
explicit `INSTANCE_ID`) must be installed inside the distro; WSL 1 shares
`localhost` with Windows and just works; WSL 2 relies on localhost-forwarding,
so if `mstsc` can't connect, enable mirrored networking (`networkingMode=mirrored`
under `[wsl2]` in `%UserProfile%\.wslconfig`, then `wsl --shutdown`).

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
