# Architecture

## Overview

A single VPC with one public subnet. `sko26-lab-linux-vm` runs in the public subnet
with outbound internet access via an internet gateway, and is administered
through AWS SSM Session Manager (no SSH keypair, no inbound access).

## Stacks

| Stack   | Template | Purpose | Depends on |
|---------|----------|---------|------------|
| vpc     | `templates/network/vpc.yaml` | VPC, internet gateway, public subnet, routing. | — |
| logging | `templates/network/logging.yaml` | VPC Flow Logs and Route 53 Resolver DNS query logging, each to its own hardened S3 bucket. | vpc |
| storage | `templates/storage/s3.yaml`  | S3 file-transfer relay bucket. | — |
| linux-vm | `templates/compute/linux-vm.yaml` | `sko26-lab-linux-vm` Linux (AL2023) EC2 instance + SSM instance role with S3 access. | vpc, storage |
| win-vm  | `templates/compute/win-vm.yaml` | `sko26-lab-win-vm` Windows Server 2022 EC2 instance in the same subnet + SSM instance role with S3 access. | vpc, storage |

## Outbound internet access

The public subnet has `MapPublicIpOnLaunch: true` and a route table sending
`0.0.0.0/0` to the internet gateway. The instance therefore gets a public IP
and reaches the internet (and the SSM endpoints) directly — no NAT gateway,
which keeps lab cost low.

## Access model

No keypair. Each instance role grants `AmazonSSMManagedInstanceCore`, so you
connect with:

```bash
aws ssm start-session --target <instance-id>
```

On the Linux VM this opens a shell; on the Windows VM it opens a PowerShell
session. Each VM stack outputs its instance ID and a ready-made connect command.
The security groups have **no inbound rules**; outbound is open.

Both VMs share the public subnet and the S3 transfer bucket. The Windows VM
defaults to `t3.small` (Windows Server needs more memory than the Linux VM's
`t3.micro`).

### RDP to the Windows VM

SSM Session Manager gives a PowerShell session, but you can also get a full RDP
desktop **without opening any inbound rule** by tunnelling RDP over SSM port
forwarding.

1. **Set a password.** With no keypair there is no auto-generated Administrator
   password to retrieve, so set one from a PowerShell session first:

   ```bash
   aws ssm start-session --target <instance-id>
   ```
   ```powershell
   net user Administrator "<NewPassw0rd!>"
   ```

2. **Open the tunnel** (the `RdpTunnelCommand` stack output):

   ```bash
   aws ssm start-session --target <instance-id> \
     --document-name AWS-StartPortForwardingSession \
     --parameters portNumber=3389,localPortNumber=13389
   ```

3. **Connect an RDP client** to `localhost:13389` and log in as `Administrator`
   with the password from step 1:
   - **Windows:** `mstsc /v:localhost:13389`
   - **macOS:** the *Windows App* (formerly *Microsoft Remote Desktop*, Mac App
     Store) — add a PC pointing at `localhost:13389`.
   - **Linux:** any RDP client, e.g. `xfreerdp /v:localhost:13389 /u:Administrator`.

   On any OS the tunnel command (step 2) is identical; it requires the AWS CLI
   and the **Session Manager plugin** to be installed locally.

Traffic stays inside the SSM channel, so the security group keeps its no-inbound
posture. (The AWS console's Fleet Manager → Remote Desktop offers the same thing
in-browser, also over SSM.)

## File transfer

Since SSM Session Manager has no built-in file copy, the `storage` stack
provisions an S3 bucket as a relay, and the instance role is granted
`ListBucket` / `GetObject` / `PutObject` / `DeleteObject` on it.

```bash
BUCKET=$(aws cloudformation describe-stacks --stack-name sko26-cortexlab-storage \
  --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue" --output text)

# workstation -> instance
aws s3 cp ./file.tar.gz "s3://$BUCKET/tmp/"
# then inside the SSM session:
aws s3 cp "s3://$BUCKET/tmp/file.tar.gz" .
```

The bucket has versioning enabled and blocks all public access. Because it is
versioned, it must be emptied before the stack can be deleted — `scripts/delete.sh`
does this automatically (it removes all object versions and delete markers
before deleting the `storage` stack).

## Logging

The `logging` stack sends each log type to its own hardened bucket, so they can
be shared with an upstream analytics system independently:

| Log type | Bucket | Path |
|----------|--------|------|
| VPC Flow Logs | `sko26-cortexlab-flow-logs` (export `flow-log-bucket-arn`) | `AWSLogs/<account>/vpcflowlogs/...` |
| Resolver DNS query logs | `sko26-cortexlab-dns-logs` (export `dns-log-bucket-arn`) | `AWSLogs/<account>/vpcdnsquerylogs/...` |

Each bucket blocks all public access, uses SSE-S3, has ACLs disabled
(`BucketOwnerEnforced`), and expires objects after `LogRetentionDays` (default
90). Each policy grants only `delivery.logs.amazonaws.com`, scoped with
`aws:SourceAccount`. No KMS key or IAM delivery role is required for the S3
destination.

`scripts/delete.sh` empties both buckets (like the transfer bucket) before
deleting the stack, since CloudFormation cannot remove a non-empty bucket.

## Cross-stack references

`vpc` publishes `vpc-id` and `public-subnet-id` as CloudFormation exports;
`vm` consumes them with `Fn::ImportValue`. Because of these imports, `vm` must
be deleted before `vpc`. `scripts/delete.sh` already tears down in that order.

## Deploy order

Deploy `vpc` before `vm`; `scripts/deploy.sh` enforces this via its ordered
stack registry, and `scripts/delete.sh` reverses it.
