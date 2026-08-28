# Cortex Cloud on EKS — Lab Guide

A hands-on lab that stands up a deliberately vulnerable Kubernetes app on AWS EKS
and secures it with **Cortex Cloud** (KSPM + realtime protection).

- **Format:** groups of 3, working in one shared AWS account per group.
- **Duration:** one 90-minute session
- **Session possibilities:**
      *mandatory* deploy the Part 1 AWS infrastructure and onboard the account to Cortex Cloud.
      deploy Part 2 AWS infrastucture - Kubernetes (~15 min, runs unattended).
      deploy the vulnerable app, then deploy the Cortex KSPM + realtime protection agent
      deploy cortexcli and explore appsec scanning of the vulnerable app
      exploit the vulnerable app
      introduce configuration weaknesses to AWS
      explore!!

> Architecture reference: [architecture.md](architecture.md). Stack/port tables
> in that doc are the source of truth if anything here drifts.

---

## Working as a group of two or 4

You share one AWS account and one Cortex tenant view, so **only one person runs
the deploy commands at a time** — CloudFormation stacks and the EKS cluster are
shared state. Suggested split so everyone stays busy:

| Role | Owns |
|------|------|
| **Driver** | Runs the terminal commands (clone, deploy scripts, SSM sessions). |
| **Navigator** | Reads this guide aloud, tracks the checklist, watches for errors. |
| **Console** | Drives the Cortex Cloud console and the AWS console (verifying stacks, watching findings). |
| **Hacker** | Explore and execute exploits on Broken Bank. |

Consider rotating roles so everyone gets to experience each part.

---

## Before you start — Prerequisites

Install these **before the Session**. Everything in this lab runs from a Bash
shell: **Git Bash** on Windows, **Terminal** on macOS.

You need, on your workstation:

| Tool | Why |
|------|-----|
| **AWS CLI v2** | Runs every deploy/validate script and all SSM sessions. |
| **AWS Session Manager plugin** | Required for `aws ssm start-session` (shell into the VMs) and the RDP tunnel. The CLI alone is not enough. |
| **Python 3** | The deploy scripts read `config/config.yaml` through it. |
| **cfn-lint** | Validates the CloudFormation templates before you deploy. |
| **git** | Clone this repo. |
| **Git Bash** (Windows only) | Provides the Bash shell the scripts expect. |
| An **RDP client** (optional) | Only if you want a desktop on the Windows VM. Windows has `mstsc` built in; macOS uses the *Windows App* from the App Store. |

### Windows

Use **Git Bash** for every command in this guide (not PowerShell or CMD).

1. **Git (includes Git Bash)** — https://git-scm.com/download/win
   Run the installer with defaults, then open **Git Bash** for the steps below.
2. **AWS CLI v2** — https://awscli.amazonaws.com/AWSCLIV2.msi (run the MSI).
3. **AWS Session Manager plugin** — choose either installation method:
    - **WinGet** (run in PowerShell or Git Bash):
       ```powershell
       winget install --id Amazon.SessionManagerPlugin --exact
       ```
    - **Manual download:** download and run the official installer:
       https://s3.amazonaws.com/session-manager-downloads/plugin/latest/windows/SessionManagerPluginSetup.exe
       Run it as Administrator and leave the install location blank to use the
       default `%PROGRAMFILES%\Amazon\SessionManagerPlugin\bin\` location.
4. **Python 3** — https://www.python.org/downloads/windows/
   ✅ On the first installer screen, tick **"Add python.exe to PATH."**
5. **cfn-lint** — in Git Bash:
   ```bash
   python -m pip install --user cfn-lint
   ```

> Tip: after installing, **close and reopen Git Bash** so the new tools are on
> your PATH.

### macOS

Use the built-in **Terminal** (or iTerm). The easiest path is [Homebrew](https://brew.sh):

```bash
# Homebrew (skip if you already have it)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

brew install awscli python git
brew install --cask session-manager-plugin
python3 -m pip install --user cfn-lint
```

`git` is also available via Xcode Command Line Tools if you prefer
(`xcode-select --install`).

### Verify your setup

Run this in Git Bash / Terminal. Every line should print a version, not an error:

```bash
aws --version                       # aws-cli/2.x ...
session-manager-plugin --version    # a version number
python3 --version || python --version
cfn-lint --version
git --version
```

If `cfn-lint` isn't found even after installing, it's usually a PATH issue —
`scripts/validate.sh` falls back to `aws cloudformation validate-template`, so
the lab still works, but fixing PATH is worth it. On Windows the pip scripts dir
is typically `~/AppData/Roaming/Python/PythonXY/Scripts`.

---

### 1. Get an AWS account and load the credentials

Your instructor will point you at **Lab as a Service (LaaS)** to request a
temporary AWS account for your group. Request **one account per group** and share
the credentials among the group.

Once you get to the AWS login, you can get a set of temporary credentials.
In **the same Git Bash / Terminal window** you'll use for the rest of the lab,
paste them as environment variables:

```bash
export AWS_ACCESS_KEY_ID="ASIA...."
export AWS_SECRET_ACCESS_KEY="...."
export AWS_SESSION_TOKEN="...."        # LaaS creds are temporary — this is required
export AWS_REGION="ap-southeast-2"     # region this lab deploys into
```

Confirm they work and note the account number:

```bash
aws sts get-caller-identity
```

> ⚠️ **These credentials expire** (typically a few hours). They live only in
> this terminal window — if you open a new window, or come back for Session 2,
> **re-export them**. If commands suddenly fail with `ExpiredToken`, grab fresh
> creds from LaaS and re-export. See [Troubleshooting](#troubleshooting).

### 2. Clone the repo

```bash
git clone <REPO_URL>          # instructor will provide the URL
cd sko26-cortexlab
```

> ⓘ **Instructor:** fill in `<REPO_URL>` (or have students download a zip).

### 3. Set your group's stack prefix

Every group deploys into the **same shared account model**, so each group must
use a unique prefix or your stacks will collide. Edit
[config/config.yaml](../config/config.yaml) and set `stackPrefix` to your group
number:

```yaml
stackPrefix: sko26-grpNN-cortexlab      # replace NN with YOUR group number, e.g. grp07
```

The deploy scripts refuse to run if the prefix still looks like the placeholder
(it must contain `grpN` and no `XX`), so this step is enforced. All stack names,
resource names, and the `Project` tag derive from this prefix.

Also confirm `region` is `ap-southeast-2` (or whatever your instructor specifies).

### 4. Validate the templates

```bash
scripts/validate.sh
```

You should see `>> All templates valid.` This runs `cfn-lint` if available,
otherwise falls back to AWS-side validation.

### 5. Deploy Part 1

This deploys everything **except** EKS — CloudTrail, VPC, network logging, the transfer bucket, and
the Linux and Windows VMs — and stages the lab assets into the transfer bucket so
the Linux VM picks them up on boot.

```bash
scripts/deploy-part1.sh
```

This takes a few minutes. You'll see each stack deploy in order:
`cloudtrail → vpc → network-logging → transfer-bucket → linux-vm → win-vm`, then `>> Done.`

Verify in the AWS console (CloudFormation) or from the CLI:

```bash
aws cloudformation list-stacks \
  --query "StackSummaries[?starts_with(StackName, 'sko26-grpNN') && StackStatus=='CREATE_COMPLETE'].StackName" \
  --output table
```

### 6. Connect to the Linux VM (smoke test)

Grab the Linux VM instance ID from its stack output and open an SSM shell — no
SSH key, no inbound rules:

```bash
LINUX_ID=$(aws cloudformation describe-stacks \
  --stack-name sko26-grpNN-cortexlab-linux-vm \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text)

aws ssm start-session --target "$LINUX_ID"
```

Inside the session, confirm the lab assets landed and the tools are installed:

```bash
ls /opt/cortexlab            # k8s/  config/  scripts/  transfer-bucket
kubectl version --client
helm version
aws --version                # AWS CLI v2, installed on first boot
docker version               # local Docker daemon for cortexcli image scans (no sudo needed)
exit                         # leave the SSM session
```

> If `/opt/cortexlab` is empty, the first-boot pull may still be running — wait a
> minute and re-check, or re-run `scripts/deploy-part1.sh` from your workstation
> to re-stage.

### 7. Onboard the AWS account to Cortex Cloud

Now connect this AWS account to Cortex Cloud so it can assess cloud posture.

1. Log in to the **Cortex Cloud** console at the URL your instructor provides.
2. Go to the cloud account onboarding flow and start a new **AWS** connection.
3. Choose the onboarding method your instructor specifies (typically a
   CloudFormation-based role connection). Follow the wizard — it either gives you
   a CloudFormation template/stack to launch in your account, or a role ARN to
   configure.
4. Complete onboarding using **the account you're logged into** (confirm with
   `aws sts get-caller-identity` from step 1) and region `ap-southeast-2`.
5. Wait for the account to show **Connected / healthy** in the Cortex console.


**Checkpoint Part 1:** Part 1 stacks are `CREATE_COMPLETE`, you can
SSM into the Linux VM, and your AWS account shows as connected/healthy in Cortex Cloud.

---

## Break — kick off the EKS deployment

The EKS control plane and node group take **~15 minutes** to create, so start
this at the **beginning of the break** and let it run while you step away.

From your workstation (creds still exported — re-export if the window is new):

```bash
cd sko26-cortexlab
scripts/deploy-part2.sh
```

This deploys the single `eks` stack. It imports the private subnets and the VM
security groups/roles from Part 1, so Part 1 must be finished first (it is).

Leave the terminal running; it prints `>> Done.` when the cluster is ready. If
you need the window back, EKS keeps building in AWS regardless — just verify it's
`CREATE_COMPLETE` at the start of Session 2:

```bash
aws cloudformation describe-stacks --stack-name sko26-grpNN-cortexlab-eks \
  --query "Stacks[0].StackStatus" --output text
```

---

## Vulnerable Kubernetes app + KSPM + realtime protection

> **First thing:** if you're in a fresh terminal window, re-export your AWS
> credentials (step 1) — and refresh them from LaaS if they've expired.

### 1. Confirm the cluster is up and reachable

The EKS API endpoint is **private-only**, so `kubectl` only works from inside the
VPC — i.e. **from the Linux VM**, not your laptop. SSM into the Linux VM:

```bash
LINUX_ID=$(aws cloudformation describe-stacks \
  --stack-name sko26-grpNN-cortexlab-linux-vm \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text)
aws ssm start-session --target "$LINUX_ID"
```

Inside the VM:

```bash
CLUSTER=sko26-grpNN-cortexlab-eks
aws eks update-kubeconfig --region ap-southeast-2 --name "$CLUSTER"
kubectl get nodes            # should show 2 nodes in Ready state
```

### 2. Deploy the vulnerable app (GoCortex Broken Bank)

The manifest and helper scripts are already on the VM at `/opt/cortexlab`. Deploy
the app:

```bash
/opt/cortexlab/scripts/deploy-app.sh
```

This applies [k8s/gocortexbrokenbank.yaml](../k8s/gocortexbrokenbank.yaml),
waits for the rollout, then prints the node private IPs and the NodePort mapping.
The app is one pod exposing six listeners via a NodePort Service:

| Server | Native port | NodePort |
|--------|-------------|----------|
| Flask/Gunicorn (SAST, GraphQL) | 8888 | 30888 |
| Tomcat (Java RCE) | 9999 | 30999 |
| Next.js SpaceATM (CVE-2025-55182) | 7777 | 30777 |
| OTel Prometheus scrape | 9464 | 30464 |
| sshd (leaked key / weak root pw) | 2222 | 30022 |
| Live Transaction Ticker (WS) | 6666 | 30666 |

Confirm it's running:

```bash
kubectl -n gocortexbrokenbank get pods,svc
```

### 3. Exercise a vulnerability (still on the Linux VM)

The VMs are allowed to reach any node's private IP on these NodePorts. Pick a
node IP from the `deploy-app.sh` output and try a couple of exploits:

```bash
NODE=<one-of-the-node-private-IPs>

# SQL injection against the Flask banking UI
curl "http://$NODE:30888/search?q=' OR '1'='1"

# Java RCE against Tomcat
curl "http://$NODE:30999/exploit-app/execute?cmd=id"
```

Keep note of what you ran — you'll look for these in Cortex after the agent is
deployed.

### 4. Generate the Cortex Helm installer (KSPM + realtime protection)

In the **Cortex Cloud console**, generate the Kubernetes / Helm installer for
this cluster with **both** KSPM (posture) and **runtime / realtime protection**
enabled:

1. Go to the Kubernetes onboarding / defenders (agents) section.
2. Choose **Helm** as the deployment method.
3. Enable **KSPM** and **runtime (realtime) protection**.
4. Download the generated Helm chart (`.tgz`), plus any separate values file.

### 5. Upload the installer to the transfer bucket

SSM has no file copy, so relay through the transfer bucket. From **your
workstation** (where you downloaded the chart), find the bucket and upload into
its pre-created `cortex/` folder:

```bash
BUCKET=$(aws cloudformation describe-stacks \
  --stack-name sko26-grpNN-cortexlab-transfer-bucket \
  --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue" --output text)

aws s3 cp ./<cortex-installer>.tgz "s3://$BUCKET/cortex/"
# if you also have a values file:
aws s3 cp ./<values>.yaml "s3://$BUCKET/cortex/"
```
### 6. Fetch and install on the cluster (on the Linux VM)

Back in the Linux VM SSM session, pull the installer down and deploy with Helm:

```bash
/opt/cortexlab/scripts/fetch-cortex.sh          # downloads s3://<bucket>/cortex/ -> /opt/cortexlab/cortex/
ls /opt/cortexlab/cortex/

helm upgrade --install cortex /opt/cortexlab/cortex/<chart>.tgz [-f /opt/cortexlab/cortex/<values>.yaml]
```

Confirm the agent is running (namespace name depends on the chart — often
`cortex` or similar):

```bash
kubectl get pods -A | grep -i cortex
```

You should see the defender/agent pods (typically a DaemonSet, one per node)
reach `Running`.

### 7. Verify in the Cortex Cloud console

1. **KSPM:** within a few minutes the cluster should appear under Kubernetes
   posture, with configuration findings against the intentionally-weak app
   (privileged/hostPath/exposed services, hardcoded secrets, etc.).
2. **Realtime protection:** re-run one of the exploits from step 3 (e.g. the
   Tomcat RCE `curl`) and look for a corresponding **runtime detection /
   incident** in Cortex. Point out the process/exec chain the agent captured.


**Checkpoint (end of Session 2):** the vulnerable app is running, the Cortex
agent (KSPM + runtime) is deployed on the cluster, KSPM findings are visible, and
a live exploit produced a runtime detection.

---

## Teardown

When the lab is done, tear everything down from your workstation (creds
exported). This deletes all stacks in reverse order and empties the S3 buckets
first. EKS deletion also takes ~15 minutes.

```bash
cd sko26-cortexlab
scripts/delete.sh
```

It prompts for confirmation before deleting. If LaaS reclaims the account
automatically, this may be optional — check with your instructor.

If you onboarded the account to Cortex with a CloudFormation stack, remove that
too (and/or offboard the account in the Cortex console).

---

## Troubleshooting

**`ExpiredToken` / `InvalidClientTokenId` on any `aws` command**
LaaS credentials are temporary. Get fresh ones and re-export
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `AWS_SESSION_TOKEN` in your
current window. Every new terminal window needs them re-exported.

**`stackPrefix in config.yaml is still the placeholder`**
You didn't set your group number in `config/config.yaml`. It must contain
`grpN` (e.g. `sko26-grp07-cortexlab`) and no `XX`.

**`aws ssm start-session` fails / "SessionManagerPlugin is not found"**
Install the **Session Manager plugin** (separate from the AWS CLI) — see
[Prerequisites](#before-you-start--prerequisites) — and reopen your shell.

**`kubectl` hangs or "connection refused" from your laptop**
Expected — the EKS endpoint is **private-only**. Run `kubectl` from the Linux VM
over SSM, not from your workstation.

**`/opt/cortexlab` empty on the Linux VM**
First-boot asset pull may still be running; wait a minute, or re-run
`scripts/deploy-part1.sh` from your workstation to re-stage, then re-check.

**`cfn-lint: command not found`**
PATH issue for pip's user scripts dir. The lab still works via the AWS
validate-template fallback in `scripts/validate.sh`. To fix, add the pip Scripts
dir to PATH (Windows: `~/AppData/Roaming/Python/PythonXY/Scripts`).

**Broken Bank pod stuck `Pending` / `OOMKilled`**
The container is heavy (JVM + Node + Gunicorn + a small local LLM). Bump
`NodeInstanceType` in [parameters/eks.json](../parameters/eks.json) and re-run
`scripts/deploy-part2.sh`.

### Optional: RDP into the Windows VM

The lab runs fine without it, but if you want a desktop on the Windows VM (no
inbound rules — tunneled over SSM):

1. Set an Administrator password once, from a PowerShell SSM session:
   ```bash
   WIN_ID=$(aws cloudformation describe-stacks --stack-name sko26-grpNN-cortexlab-win-vm \
     --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text)
   aws ssm start-session --target "$WIN_ID"
   ```
   ```powershell
   net user Administrator "<NewPassw0rd!>"
   ```
2. Open the tunnel (leave it running):
   ```bash
   scripts/rdp-tunnel.sh          # forwards localhost:13389 -> win-vm:3389
   ```
3. Point an RDP client at `localhost:13389`, log in as `Administrator`:
   - **Windows:** `mstsc /v:localhost:13389` (run from Git Bash or Start menu).
   - **macOS:** the **Windows App** (App Store) — add a PC at `localhost:13389`.

---

## Quick reference

**Credentials (every new terminal):**
```bash
export AWS_ACCESS_KEY_ID=...  AWS_SECRET_ACCESS_KEY=...  AWS_SESSION_TOKEN=...
export AWS_REGION=ap-southeast-2
```

**Stacks** (prefix `sko26-grpNN-cortexlab-`): `cloudtrail`, `vpc`, `network-logging`,
`transfer-bucket`, `linux-vm`, `win-vm`, `eks`.

**Key commands:**
| Where | Command | Does |
|-------|---------|------|
| Workstation | `scripts/validate.sh` | Lint templates |
| Workstation | `scripts/deploy-part1.sh` | Deploy all but EKS |
| Workstation | `scripts/deploy-part2.sh` | Deploy EKS (~15 min) |
| Workstation | `aws ssm start-session --target <id>` | Shell into a VM |
| Linux VM | `/opt/cortexlab/scripts/deploy-app.sh` | Deploy vulnerable app |
| Workstation | `aws s3 cp <chart> s3://<bucket>/cortex/` | Stage Cortex installer |
| Linux VM | `/opt/cortexlab/scripts/fetch-cortex.sh` | Pull installer to VM |
| Linux VM | `helm upgrade --install cortex .../<chart>` | Deploy Cortex agent |
| Workstation | `scripts/delete.sh` | Tear everything down |
