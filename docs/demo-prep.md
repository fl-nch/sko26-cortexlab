# Cortex Cloud on EKS — Demo Prep

## Lab 内容 (What this demo covers)

A deliberately vulnerable banking app running on AWS EKS, secured live with
Cortex Cloud (posture management + runtime protection).

Flow:
1. Deploy AWS infrastructure (VPC, VMs, CloudTrail) and onboard the account to Cortex Cloud
2. Deploy the EKS cluster (~15 min, unattended)
3. Deploy the vulnerable app and exploit it (SQL injection, Tomcat RCE)
4. Deploy Cortex's Kubernetes connector (KSPM + runtime protection)
5. Re-run the exploit and show Cortex catching it live, plus posture findings

**Duration:** ~90 minutes, plus the ~15 min unattended EKS build.

## 准备 (Preparation checklist)

**Accounts**
- AWS temp account: LaaS — https://laas.paloaltonetworks.com/ (one per demo)
- Cortex Cloud console — https://japac-ccr.xdr.jp.paloaltonetworks.com/login
- Region: ap-southeast-2
- Note: LaaS credentials are temporary (expire in a few hours) — grab fresh ones close to demo time

**Install beforehand**
- Git, AWS CLI v2, AWS Session Manager plugin, Python 3
- Node.js 18+ (to run the guided app)

**Set up the repo**
```bash
git clone https://github.com/paliguoqing/sko26-cortexlab.git
cd sko26-cortexlab
```
Edit `config/config.yaml` and set a unique `stackPrefix`, e.g.:
```yaml
stackPrefix: sko26-grp01-cortexlab
```

**Run it**
- Guided app (recommended): `cd app && npm install && npm start` → open `localhost:4848`
- Or follow [lab-guide.md](lab-guide.md) manually, command by command
