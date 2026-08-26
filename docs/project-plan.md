# Wiz Technical Exercise — 4-day delivery plan

Working checklist. Tick tasks as you complete them. Every task has an
**acceptance criterion** — do not tick until it is met, because each one maps
to something a panelist can ask you to prove live.

**Priority order is fixed by the recruiter's email:**
1. WebApp environment — MANDATORY
2. Cloud Native Security — MANDATORY
3. Dev(Sec)Ops — BONUS, "complete as much as possible"

If you fall behind, you cut from the bottom. Never from the top.

---

## Ground rules

- **The lab clock starts at task D1.6.** Everything before it is local and free.
- **Capture evidence as you go.** Screenshot every acceptance criterion the
  moment it passes. Re-creating evidence later costs more than capturing it now,
  and it is your fallback if the live demo breaks.
- Keep a running `challenges.md` — every error you hit and how you solved it.
  The panel explicitly scores "challenges you experienced". Notes written in the
  moment are worth more than recollections a week later.
- **You must be able to explain every step.** If a task produces something you
  could not defend under questioning, stop and understand it before ticking.

---

# DAY 1 — Local validation, then infrastructure up

Goal by end of day: the container image is proven locally, and the full Azure
environment exists.

## Morning — clock still stopped

- [ ] **D1.1 — Install the toolchain**
  Elevated PowerShell: `.\bootstrap\install-tools.ps1`, then **reboot**.
  *Accept:* new terminal runs `git`, `az`, `terraform`, `kubectl`, `gh`,
  `helm`, `docker` — all report a version.

- [ ] **D1.2 — Build the container image locally**
  `docker build -t tasky:local app/`
  *Accept:* build completes with no errors.

- [ ] **D1.3 — Prove `wizexercise.txt` is in the image**
  `docker run --rm --entrypoint cat tasky:local /app/wizexercise.txt`
  *Accept:* prints `Christine Furby`.
  *`--entrypoint cat` is required — the image's ENTRYPOINT is `/app/tasky`, so
  without it Docker passes the arguments to the app instead of running `cat`.*

- [ ] **D1.4 — End-to-end test against local MongoDB**
  Full command sequence in `app/README.md`.
  *Accept:* you can sign up and add a todo at `http://localhost:8080`, **and**
  `docker exec mongo-test mongo go-mongodb --eval "db.todos.find()"` returns
  that todo. This proves the app, the env-var wiring and the database names all
  work before Azure is involved.

- [ ] **D1.5 — Validate Terraform offline**
  ```
  cd terraform
  terraform fmt -recursive
  terraform init -backend=false
  terraform validate
  ```
  *Accept:* `Success! The configuration is valid.`
  *Expect to fix provider-schema errors here — that is the point of this task.*
  No Azure credentials involved, no lab days consumed.

> **Decision gate:** do not proceed until D1.1–D1.5 all pass. Everything after
> this consumes lab time.

## Afternoon — clock starts

- [ ] **D1.6 — Azure bootstrap** ⏱️ **CLOCK STARTS HERE**
  `az login`, confirm the right subscription, run `bootstrap\bootstrap-azure.ps1`.
  *Accept:* state storage account exists; the script printed your GitHub
  secrets and `backend.conf` values. **Save that output to a file immediately.**

- [ ] **D1.7 — Configure Terraform variables**
  Create `terraform.tfvars` from the example; set `$env:TF_VAR_mongo_admin_password`.
  *Accept:* `terraform plan` runs without prompting for input.

- [ ] **D1.8 — Deploy the infrastructure**
  `terraform init -backend-config=backend.conf` then `terraform apply`.
  *Accept:* apply completes. Expect 15–25 minutes; AKS is the slow part.
  *If it fails partway, re-run apply — Terraform is idempotent.*

- [ ] **D1.9 — Record the outputs**
  `terraform output` — save to a scratch file you keep open all week.
  *Accept:* you have the Mongo public IP, private IP, ACR name, AKS name and
  the public backup listing URL.

- [ ] **D1.10 — Verify the VM came up correctly**
  SSH in, then check the cloud-init log.
  *Accept:* `mongod --version` shows **4.4.x**, `cat /etc/os-release` shows
  **20.04**, and `systemctl status mongod` is active. If not, read
  `/var/log/wiz-setup.log` — that is where cloud-init failures surface.

**End-of-day-1 state:** infrastructure exists, database is running, image is
proven locally. Nothing deployed to Kubernetes yet.

---

# DAY 2 — Web application on Kubernetes (MANDATORY)

Goal by end of day: every WebApp requirement in the brief is demonstrably met.

- [ ] **D2.1 — Push the image to ACR**
  `docker build` → `az acr login` → `docker push`.
  *Accept:* image visible in ACR (`az acr repository list`).

- [ ] **D2.2 — Connect to the cluster**
  `az aks get-credentials ...`
  *Accept:* `kubectl get nodes` lists your nodes.

- [ ] **D2.3 — Confirm nodes are in the private subnet**
  `kubectl get nodes -o wide`
  *Accept:* nodes show **private IPs only**, in the 10.10.1.0/24 range. This is
  the "cluster deployed in a private subnet" requirement — screenshot it.

- [ ] **D2.4 — Create the database Secret**
  From the Terraform output, `kubectl create secret generic tasky-db ...`
  *Accept:* `kubectl get secret tasky-db -n tasky` exists.

- [ ] **D2.5 — Deploy the application**
  Apply namespace, RBAC, deployment, ingress.
  *Accept:* `kubectl get pods -n tasky` shows pods **Running** and ready.
  *If CrashLoopBackOff:* `kubectl logs` — almost always the connection string.

- [ ] **D2.6 — Confirm the ingress and load balancer**
  `kubectl get ingress -n tasky`
  *Accept:* an external IP is assigned, and the Azure portal shows a Standard
  Load Balancer with that public IP. Both halves of the requirement — ingress
  *and* CSP load balancer.

- [ ] **D2.7 — Prove the app works end to end**
  Browse to the ingress IP, sign up, add several todos.
  *Accept:* todos persist across a page refresh.

- [ ] **D2.8 — Prove the data is in MongoDB** ⭐ *explicit brief requirement*
  Run a `mongo:4.4` pod inside the cluster and query `go-mongodb`.
  *Accept:* `db.todos.find()` returns the todos you just created, and
  `db.user.find()` returns your signup. Screenshot side by side with the
  browser.

- [ ] **D2.9 — Prove the network restriction**
  Run the same query from your laptop.
  *Accept:* it **times out**. The NSG only permits 27017 from the AKS subnet.
  The failure *is* the evidence — capture it.

- [ ] **D2.10 — Prove `wizexercise.txt` in the running container** ⭐
  `kubectl exec -n tasky deploy/tasky -- cat /app/wizexercise.txt`
  *Accept:* prints `Christine Furby`. Be ready to explain how it got there —
  a `COPY` at image build time, not a mount.

- [ ] **D2.11 — Demonstrate the cluster-admin weakness**
  `kubectl auth can-i --list --as=system:serviceaccount:tasky:tasky`
  *Accept:* output shows `*` on `*`. Screenshot.

- [ ] **D2.12 — Verify the automated backup**
  On the VM: check `/etc/cron.d/mongo-backup` and `/var/log/wiz-backup.log`.
  *Accept:* cron entry exists **and** at least one dump is already in the
  bucket from the initial run.

- [ ] **D2.13 — Prove the bucket is publicly readable and listable** ⭐
  Open the listing URL in a **private browser window with no Azure session**,
  then `curl` a backup down.
  *Accept:* you can enumerate the container and download a dump anonymously.
  Restore it locally to show it is real data — that is the moment that lands.

**End-of-day-2 state: every mandatory WebApp requirement is met and evidenced.**
If you are behind here, catch up before starting Day 3.

---

# DAY 3 — Cloud Native Security (MANDATORY)

Goal by end of day: audit logging, one preventative control, and detective
controls — all demonstrated working.

- [ ] **D3.1 — Verify control-plane audit logging**
  Azure Portal → Log Analytics → run a query against `AzureActivity`.
  *Accept:* your own `terraform apply` operations from Day 1 appear.

- [ ] **D3.2 — Verify Kubernetes audit logging**
  Query `AzureDiagnostics | where Category == "kube-audit"`.
  *Accept:* rows returned. *May take 10–20 minutes to start flowing after the
  diagnostic setting is created — do not panic early.*

- [ ] **D3.3 — Verify storage data-plane logging**
  Query `StorageBlobLogs`.
  *Accept:* your Day 2 anonymous download appears with
  `AuthenticationType == "Anonymous"`.

- [ ] **D3.4 — Confirm Defender for Cloud is enabled**
  Portal → Microsoft Defender for Cloud → Environment settings.
  *Accept:* Servers, Containers and Storage plans show **On**.

- [ ] **D3.5 — Review Defender recommendations** ⭐
  Filter to your resource group.
  *Accept:* you can point to Defender findings for the public storage account,
  the exposed SSH port, and the unpatched VM. Screenshot the list.
  *Note honestly:* initial assessment can take a few hours. Do this task early
  in the day, not late.

- [ ] **D3.6 — Demonstrate the preventative control** ⭐
  Attempt to create a VM with a disallowed size:
  `az vm create ... --size Standard_D8s_v3`
  *Accept:* fails with **`RequestDisallowedByPolicy`**. Screenshot the error
  and the corresponding entry in Policy → Compliance. This is your "at least
  one preventative cloud control" evidence.

- [ ] **D3.7 — Trigger detective control A (anonymous backup access)**
  Anonymously `curl` a backup blob, wait for the alert window.
  *Accept:* the scheduled query alert fires; you receive the email.

- [ ] **D3.8 — Trigger detective control B (kubectl exec)**
  `kubectl exec -it` into a pod.
  *Accept:* the kube-audit alert fires.
  *If the alert does not fire, run the underlying KQL manually and show the
  detection logic works — that is still a valid demonstration, and being honest
  about the alerting lag is better than pretending.*

- [ ] **D3.9 — Write down what each control would and would not catch**
  For each of the two attack chains in `docs/intentional-weaknesses.md`, note
  which control fires, at which step, and what gets through.
  *Accept:* you can answer "would your controls have stopped this?" without
  hesitating. **This is the highest-value 30 minutes of the whole exercise for
  a Solution Engineer.**

**End-of-day-3 state: both mandatory sections complete and evidenced.**

---

# DAY 4 — Dev(Sec)Ops bonus, then consolidation

Goal by end of day: pipelines working, evidence pack complete, demo rehearsed.

**Timebox the bonus to the morning.** If the pipelines are not working by
lunch, stop and spend the afternoon on consolidation. A rehearsed demo of the
mandatory work beats a half-finished pipeline.

## Morning — the bonus

- [ ] **D4.1 — Push the code to GitHub**
  Create a **private** repo, commit, push.
  *Accept:* repo exists with all code. Confirm `terraform.tfvars` and
  `backend.conf` are **not** in it — check before you push, not after.

- [ ] **D4.2 — Configure repository security controls** ⭐
  Branch protection on `main`, secret scanning + push protection, Dependabot.
  *Accept:* settings screenshotted. This is the "security controls in your VCS
  platform" requirement.

- [ ] **D4.3 — Set the GitHub secrets**
  From the D1.6 output, plus `VM_SSH_PUBLIC_KEY`, `ALERT_EMAIL`,
  `TASKY_SECRET_KEY`.
  *Accept:* `gh secret list` shows all of them.

- [ ] **D4.4 — Run the IaC pipeline**
  Open a PR with a trivial Terraform change.
  *Accept:* Checkov runs, plan posts, merge triggers apply successfully.

- [ ] **D4.5 — Run the app pipeline**
  Push a change under `app/`.
  *Accept:* image builds, Trivy scans, image pushes, deployment rolls out.

- [ ] **D4.6 — Demonstrate a security gate blocking something** ⭐
  Open a PR with a genuinely bad change (a storage account with TLS disabled,
  or a hardcoded secret).
  *Accept:* Checkov or push protection **blocks it**. Screenshot the failure.
  A gate you have watched block something is worth far more in Q&A than a gate
  you assume works.

## Afternoon — consolidation

- [ ] **D4.7 — Complete the evidence pack**
  Every screenshot from the verification checklist in
  `docs/intentional-weaknesses.md`, organised in one folder.
  *Accept:* you could deliver the entire demo from screenshots alone if the
  live environment failed.

- [ ] **D4.8 — Record a full demo video**
  Screen-record the complete walkthrough end to end.
  *Accept:* a video you would be willing to play to the panel. This is your
  insurance against a lab outage or a Zoom failure on the day.

- [ ] **D4.9 — Write up challenges**
  Finish `challenges.md`: what broke, how you diagnosed it, what you changed.
  *Accept:* at least three substantive entries. The panel asks about this
  directly.

- [ ] **D4.10 — Build the demo command sheet**
  Every command you will run live, in order, in one file, ready to paste.
  *Accept:* you never have to type a command from memory during the demo.

- [ ] **D4.11 — Full dry run**
  Run the entire demo against the live environment, timed.
  *Accept:* the technical walkthrough fits comfortably inside 15 minutes with
  room for the slides.

**End-of-day-4 state: complete environment, evidence pack, rehearsed demo.**

---

## What to cut if you fall behind

Cut in this order — from the bottom up:

1. D4.6 (blocking-gate demo) — nice to have
2. D4.4 / D4.5 (pipelines) — bonus section entirely
3. D3.7 / D3.8 (live alert triggering) — show the KQL logic manually instead
4. D2.11 (RBAC demonstration) — the binding still exists and is explainable

**Never cut:** D1.x, D2.1–D2.10, D2.12, D2.13, D3.1–D3.6, D3.9, D4.7, D4.11.
Those are the mandatory requirements and the things that make the demo work.

---

## Still outstanding, not on the critical path

- [ ] Request the presentation template from the recruiter — do this today
- [ ] Slide deck — separate workstream, after the technical build
- [ ] Contact the recruiter to schedule the panel when you are close to done
- [ ] Prepare Wiz product talking points for the final 15-minute discussion

---

## Cost and clock discipline

- `terraform destroy` between long gaps, if any — but note that a rebuild costs
  20+ minutes, so only do this if you are pausing for more than a day.
- Keep `enable_defender_plans = true` from Day 3 onward; the plans need time to
  generate findings, so turning them off to save money will cost you evidence.
- You have 14 days of lab access and a 4-day plan. That buffer is deliberate —
  use it for rehearsal, not for starting late.
