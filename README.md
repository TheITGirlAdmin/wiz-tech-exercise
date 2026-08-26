# Wiz Technical Exercise — Azure

Two-tier web application (containerised front-end + MongoDB VM) deployed to
Azure entirely through Infrastructure as Code, with intentional configuration
weaknesses and a layer of cloud-native security controls on top.

---

## Architecture

```
                    Internet
                       │
       ┌───────────────┼────────────────────┐
       │               │                    │
  SSH :22        HTTP :80/443        Anonymous HTTPS
  (INTENTIONAL)   (Azure Std LB)      (INTENTIONAL)
       │               │                    │
       ▼               ▼                    ▼
┌─────────────┐  ┌──────────────┐   ┌──────────────────┐
│  Mongo VM   │  │ AKS ingress  │   │ Storage account  │
│ Ubuntu20.04 │  │ (nginx addon)│   │ mongo-backups    │
│ MongoDB 4.4 │  └──────┬───────┘   │ public read+list │
│             │         │           └──────────────────┘
│ snet-db     │         ▼                    ▲
│ 10.10.2.0/24│  ┌──────────────┐            │
│             │  │ tasky pods   │            │ daily cron
│ MSI:        │  │ (cluster-    │            │ mongodump
│ Contributor │◄─┤  admin SA)   │────────────┘
│ @ sub scope │  │ snet-aks     │
└─────────────┘  │ 10.10.1.0/24 │
   :27017 only   │ PRIVATE      │
   from AKS      └──────────────┘
```

---

## Requirement traceability

Every line of the brief, mapped to where it is implemented.

### VM with Mongo database server

| Requirement | Where |
|---|---|
| 1+ year outdated Linux | `terraform/variables.tf` → `vm_image` (Ubuntu 20.04, EOL Apr 2025) |
| SSH exposed to internet | `terraform/network.tf` → `ssh_from_internet` |
| Overly permissive CSP permissions | `terraform/vm-mongo.tf` → `vm_overprivileged_subscription` (Contributor @ subscription) |
| 1+ year outdated MongoDB | `terraform/cloud-init/mongo.yaml.tftpl` (MongoDB 4.4, EOL Feb 2024) |
| Access restricted to Kubernetes only | `terraform/network.tf` → `mongo_from_aks` + `mongo_deny_all` |
| Database authentication required | cloud-init → `security.authorization: enabled` |
| Daily automated backup to object storage | cloud-init → `/opt/wiz/backup-mongo.sh` + `/etc/cron.d/mongo-backup` |
| Object storage public read **and list** | `terraform/storage.tf` → `container_access_type = "container"` |

### Web application on Kubernetes

| Requirement | Where |
|---|---|
| Cluster in a private subnet | `terraform/aks.tf` → `vnet_subnet_id`, `node_public_ip_enabled = false` |
| Mongo access via K8s environment variable | `k8s/20-deployment.yaml` → `MONGODB_URI` from Secret |
| Container image (re-)built by me | `app/Dockerfile` + `.github/workflows/app-deploy.yml` |
| `wizexercise.txt` with my name in the image | `app/wizexercise.txt`, `COPY` in `app/Dockerfile` |
| Prove the file exists in the running container | `kubectl exec -n tasky deploy/tasky -- cat /app/wizexercise.txt` |
| Cluster-wide admin role for the app | `k8s/10-rbac.yaml` → ClusterRoleBinding to `cluster-admin` |
| Exposed via ingress + CSP load balancer | `k8s/30-ingress.yaml` + AKS `web_app_routing` addon |
| Demonstrate kubectl | Demo script below |
| Prove data is in the database | Demo script below |

### Dev(Sec)Ops

| Requirement | Where |
|---|---|
| Code in VCS | This repository |
| CI/CD pipeline for IaC | `.github/workflows/iac.yml` |
| CI/CD pipeline for container build + K8s deploy | `.github/workflows/app-deploy.yml` |
| Repository security controls | Branch protection + secret scanning (setup below) |
| IaC scanning before deployment | Checkov (blocking) + Trivy config (advisory) |
| Container image scanning before deployment | Trivy image scan, blocking, **before** `docker push` |

### Cloud native security

| Requirement | Where |
|---|---|
| Control plane audit logging | `terraform/security.tf` → Activity Log + AKS `kube-audit` + storage data-plane logs |
| Preventative cloud control | Two Azure Policy **Deny** assignments (VM SKUs, internet-exposed RDP) |
| Detective cloud control | Defender for Cloud plans + two KQL scheduled-query alerts |
| Demonstrate tools and impact | Demo script below |

---

## Setup

### 0. Prerequisites

```powershell
# Elevated PowerShell
.\bootstrap\install-tools.ps1
# Reboot (Docker Desktop), then open a new terminal
```

`app/wizexercise.txt` already contains `Christine Furby`, and the Tasky source
is vendored at `app/tasky/`. Nothing to clone.

Prove the image works **before starting the lab clock** — see the local build
and verification section in `app/README.md`. It validates the image, the
`wizexercise.txt` requirement and the database wiring with no Azure at all.

### 1. Azure bootstrap (once)

```powershell
az login
az account set --subscription "<your-cloudlabs-subscription-id>"

.\bootstrap\bootstrap-azure.ps1 -GitHubOrg "<your-gh-user>" -GitHubRepo "wiz-tech-exercise"
```

This creates the Terraform state backend and a federated (OIDC) identity for
GitHub Actions — no client secrets are ever stored. It prints the `gh secret
set` commands and the `backend.conf` contents at the end.

### 2. GitHub repository

```powershell
gh repo create wiz-tech-exercise --private --source=. --remote=origin
git add . ; git commit -m "Wiz technical exercise" ; git push -u origin main
```

Then set the secrets the bootstrap script printed, plus:

```powershell
gh secret set VM_SSH_PUBLIC_KEY --body (Get-Content ~/.ssh/wiz_exercise.pub -Raw)
gh secret set ALERT_EMAIL       --body "you@example.com"
gh secret set TASKY_SECRET_KEY  --body "<random-32-char-string>"
```

**Repository security controls** (Settings → …):
- Branches → protect `main`: require a PR, require status checks
  (`Scan IaC`, `Build, scan and deploy`), require conversation resolution,
  no force pushes
- Code security → enable secret scanning **and push protection**
- Code security → enable Dependabot alerts
- Environments → create `production`, add yourself as a required reviewer

### 3. First deployment

Local (fastest feedback while iterating):

```powershell
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill it in
$env:TF_VAR_mongo_admin_password = "<strong-password>"

terraform fmt -recursive     # run once before the first push - CI gates on this
terraform init -backend-config=backend.conf
terraform plan
terraform apply
```

Then let the pipelines take over: open a PR, watch the scans run, merge.

---

## Demo script

Rehearse this end to end at least twice. Capture screenshots of every step as
a fallback in case something breaks live.

### A. Show the application working

1. Open the ingress URL (`kubectl get ingress -n tasky`), sign up, add a todo.
2. Prove the data really is in MongoDB:

```bash
# Tasky hardcodes the database name to go-mongodb; collections are todos + user
kubectl run mongo-check -n tasky --rm -it --restart=Never --image=mongo:4.4 -- \
  mongo "mongodb://<user>:<pass>@<mongo_private_ip>:27017/go-mongodb?authSource=admin" \
  --eval 'db.todos.find().pretty(); db.user.find().pretty()'
```

*(Running the client as a pod is deliberate — the NSG only permits port 27017
from the AKS subnet, so this simultaneously proves the network restriction.
Running the same command from your laptop will time out, which is the proof.)*

### B. Prove the network restriction

From the Mongo VM itself, or your laptop:

```bash
nc -zv <mongo_private_ip> 27017      # from outside AKS: times out
```

### C. wizexercise.txt

```bash
kubectl exec -n tasky deploy/tasky -- cat /app/wizexercise.txt
kubectl exec -n tasky deploy/tasky -- ls -l /app/
```

Explain: it is `COPY`d in at image build time, not mounted.

### D. Kubernetes CLI + the RBAC weakness

```bash
kubectl get nodes -o wide                       # nodes have private IPs only
kubectl get pods -n tasky -o wide
kubectl auth can-i --list --as=system:serviceaccount:tasky:tasky
kubectl auth can-i create pods --all-namespaces --as=system:serviceaccount:tasky:tasky
kubectl get secrets --all-namespaces --as=system:serviceaccount:tasky:tasky
```

### E. The public backup bucket

Open in a private browser window (no Azure login):

```
https://<storage-account>.blob.core.windows.net/mongo-backups?restype=container&comp=list
```

Download a dump anonymously with `curl`, then restore it locally to show it
really is the production data.

### F. The over-permissive VM identity

```bash
ssh -i ~/.ssh/wiz_exercise azureuser@<mongo_public_ip>
az login --identity
az account show
az role assignment list --assignee <vm-principal-id> --all -o table
az vm list -o table          # it can enumerate the whole subscription
```

This is the chain to narrate: **open SSH → outdated OS → managed identity with
Contributor → full subscription compromise.**

### G. Preventative control in action

```bash
az vm create -g <rg> -n policy-test --image Ubuntu2204 --size Standard_D8s_v3
# RequestDisallowedByPolicy - denied before anything is created
```

Show the same denial in Portal → Policy → Compliance.

### H. Detective controls

- Defender for Cloud → Recommendations, filtered to the exercise resource
  group: public storage, missing OS patches, exposed management ports,
  over-privileged identities.
- Log Analytics → run the two alert queries from `terraform/security.tf`.
- Trigger them live: `kubectl exec` into a pod, and anonymously `curl` a
  backup blob. Then show the alerts firing.

### I. Pipeline security

- Show a PR where Checkov blocks a genuinely bad change.
- Show the Trivy image scan gate in the build log.
- Show GitHub push protection rejecting a committed secret.
- Show the Security tab with SARIF findings from both scanners.

---

## Cost control

CloudLabs budgets are small. Between work sessions:

```
Actions → IaC - Terraform → Run workflow → destroy
```

Or locally: `terraform destroy`. State lives in Azure Storage, so rebuilding is
one `apply`. Set `enable_defender_plans = false` while iterating — the Defender
plans are the largest line item.

---

## Permission fallbacks

CloudLabs subscriptions are sometimes restricted. If you hit these:

| Failure | Fix |
|---|---|
| Cannot assign roles at subscription scope | `vm_identity_role_scope = "resource_group"` in tfvars. Explain the deviation in the presentation. |
| Cannot create the Activity Log diagnostic setting | `enable_activity_log_diagnostics = false`; AKS + storage logs still satisfy control-plane logging. |
| Defender plans cannot be enabled | Fall back to Azure Policy audit assignments + the KQL alerts as detective controls. |
| Ubuntu 20.04 image unavailable in region | Try another region, or switch `vm_image` to `Canonical / UbuntuServer / 18.04-LTS`. |

---

## Known trade-offs to raise before a panelist does

- **The AKS API server is public.** Nodes are private, but the control plane is
  internet-reachable so GitHub Actions can run `kubectl` without a self-hosted
  runner. Production answer: private cluster + self-hosted runner or Azure Arc.
- **Terraform state bootstrap is manual.** The state backend cannot be created
  by the pipeline that stores its state there. `bootstrap-azure.ps1` handles it
  once, out of band.
- **The `#checkov:skip` comments are deliberate.** Each intentional weakness is
  explicitly accepted with a justification rather than the scanner being turned
  off — that distinction matters, and it is worth saying out loud.
