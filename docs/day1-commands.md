# Day 1 — command sheet

PowerShell, run from `C:\Users\C2K\wiz-tech-exercise`. Work top to bottom.

Fill this in before you start — you will paste these values repeatedly:

```
SUBSCRIPTION_ID : ______________________________________
GITHUB_USERNAME : ______________________________________
REPO NAME       : wiz-tech-exercise
MONGO PASSWORD  : ______________________________________   (make one up, 16+ chars, no quotes or backticks)
ALERT EMAIL     : ______________________________________
LOCATION        : eastus
```

---

# PART 1 — Local only. No Azure. Clock stays stopped.

## 1.1 Install the toolchain

```powershell
# ELEVATED PowerShell (Run as Administrator)
cd C:\Users\C2K\wiz-tech-exercise
.\bootstrap\install-tools.ps1
```

**Reboot.** Docker Desktop needs it. Then open a **new normal** terminal:

```powershell
cd C:\Users\C2K\wiz-tech-exercise
git --version; az version; terraform version; kubectl version --client; gh --version; docker version
```

All seven must report a version before continuing.

## 1.2 Build and test the image locally

```powershell
docker build -t tasky:local app/

# Requirement check - must print: Christine Furby
# --entrypoint cat is REQUIRED. The image's ENTRYPOINT is /app/tasky, so
# without it Docker passes "cat /app/wizexercise.txt" to the app as arguments.
docker run --rm --entrypoint cat tasky:local /app/wizexercise.txt
```

## 1.3 Full end-to-end test against local MongoDB

```powershell
docker network create tasky-test
docker run -d --name mongo-test --network tasky-test mongo:4.4

docker run -d --name tasky-test --network tasky-test -p 8080:8080 `
  -e MONGODB_URI="mongodb://mongo-test:27017" `
  -e SECRET_KEY="localtestsecret" `
  tasky:local

docker logs tasky-test          # expect: Connected to MONGO -> ...
```

Open <http://localhost:8080>, **sign up**, **add two or three todos**. Then:

```powershell
docker exec mongo-test mongo go-mongodb --eval "db.todos.find().pretty()"
docker exec mongo-test mongo go-mongodb --eval "db.user.find().pretty()"
```

Your todos and your signup must appear. Then tear it down:

```powershell
docker rm -f tasky-test mongo-test
docker network rm tasky-test
```

## 1.4 Validate the Terraform offline

```powershell
cd terraform
terraform fmt -recursive
terraform init -backend=false
terraform validate
cd ..
```

Must print **`Success! The configuration is valid.`**

Errors here are expected on the first run — that is exactly why we do this
before the clock starts. Bring me any error text and I will fix it.

---

> ## ⏱️ STOP — DECISION GATE
>
> Everything above is free. Everything below consumes lab days.
> Do not continue until 1.1–1.4 all pass.

---

# PART 2 — Azure. The clock starts at 2.2.

## 2.1 Sign in (read-only — creates nothing)

```powershell
az login
az account show --output table
az account set --subscription "<SUBSCRIPTION_ID>"
az account show --query "{name:name, id:id, tenant:tenantId}" -o table
```

Confirm this is the CloudLabs subscription before going further.

## 2.2 Bootstrap ⏱️ THIS STARTS YOUR 14 DAYS

```powershell
.\bootstrap\bootstrap-azure.ps1 `
  -GitHubOrg "<GITHUB_USERNAME>" `
  -GitHubRepo "wiz-tech-exercise" `
  -Location "eastus" | Tee-Object -FilePath .\bootstrap-output.txt
```

`Tee-Object` saves the output — it contains your GitHub secrets and backend
values, and you will need them on Day 4. **Do not commit `bootstrap-output.txt`.**

## 2.3 Create the backend and variable files

Take the values the script printed and create `terraform\backend.conf`:

```hcl
resource_group_name  = "wizex-tfstate-rg"
storage_account_name = "<from the script output>"
container_name       = "tfstate"
key                  = "wiz-exercise.tfstate"
```

Then the variables:

```powershell
cd terraform
Copy-Item terraform.tfvars.example terraform.tfvars
notepad terraform.tfvars
```

Set `subscription_id`, `alert_email`, `owner_tag = "Christine Furby"`, and
`ssh_public_key` — get the key with:

```powershell
Get-Content $env:USERPROFILE\.ssh\wiz_exercise.pub
```

Password goes in the environment, never in the file:

```powershell
$env:TF_VAR_mongo_admin_password = "<MONGO PASSWORD>"
```

> This is set **per terminal session**. If you open a new window, set it again
> or Terraform will prompt.

## 2.4 Deploy

```powershell
terraform init -backend-config=backend.conf
terraform plan -out=tfplan
```

Read the plan summary. Expect roughly 30 resources to add. Then:

```powershell
terraform apply tfplan
```

**15–25 minutes.** AKS is the slow part. If it fails partway, read the error,
fix it, and re-run `terraform apply` — Terraform is idempotent and will pick up
where it left off.

## 2.5 Save the outputs

```powershell
terraform output | Tee-Object -FilePath ..\env-outputs.txt
terraform output -raw public_backup_listing_url
terraform output -raw ssh_command
```

Keep `env-outputs.txt` open all week.

## 2.6 Verify the database VM

```powershell
$MONGO_IP = terraform output -raw mongo_public_ip
ssh -i $env:USERPROFILE\.ssh\wiz_exercise azureuser@$MONGO_IP
```

On the VM:

```bash
cat /etc/os-release | head -2        # expect Ubuntu 20.04
mongod --version | head -1           # expect db version v4.4.x
systemctl status mongod --no-pager   # expect active (running)
sudo tail -40 /var/log/wiz-setup.log
sudo cat /etc/cron.d/mongo-backup
sudo tail -20 /var/log/wiz-backup.log
exit
```

**If MongoDB is not running**, cloud-init is still working or has failed.
`sudo cloud-init status` tells you which. The setup log is the place to look —
send me the tail of it and I will diagnose.

## 2.7 Confirm the public bucket

```powershell
terraform output -raw public_backup_listing_url
```

Open that URL in an **InPrivate browser window** (no Azure session). You should
see XML listing the backup blobs. Screenshot it — this is your headline finding.

---

# Day 1 done

You should now have:

- [ ] Image built and proven locally
- [ ] Terraform validated
- [ ] Full Azure environment deployed
- [ ] MongoDB 4.4 running on Ubuntu 20.04
- [ ] A backup already in a publicly listable bucket
- [ ] `env-outputs.txt` and `bootstrap-output.txt` saved

**Next:** Day 2 in `docs/project-plan.md` — the application onto Kubernetes.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `terraform apply` — insufficient privileges on role assignment | Lab restricts subscription-scope RBAC. Set `vm_identity_role_scope = "resource_group"` in tfvars, re-apply, and note the deviation for the panel. |
| `terraform apply` — Defender pricing fails | Set `enable_defender_plans = false`, apply, and enable the plans in the Portal by hand instead. |
| VM image not found | The 20.04 image is unavailable in that region. Try `westus2`, or switch `vm_image` to `Canonical / UbuntuServer / 18.04-LTS`. |
| `docker build` cannot connect | Docker Desktop is not running. Start it and wait for the whale icon to settle. |
| Terraform prompts for `mongo_admin_password` | `$env:TF_VAR_mongo_admin_password` is not set in *this* terminal. |
| SSH connection refused | The VM is still booting. Wait two minutes and retry. |
