# Intentional weaknesses — required by the brief

Every deliberately insecure configuration the exercise demands, what it is,
where it lives in this repo, and what it costs you. The panel expects you to
detail the weak configurations and their consequences — for a Solution
Engineer that section is graded, not optional.

Nothing here is an accident. Each item is tagged in code (`exercise_weakness`
tags on Azure resources, `INTENTIONAL-WEAKNESS` in resource names, and
`#checkov:skip` comments with justifications) so it is obvious these were
chosen, not missed.

---

## The six required weaknesses

### 1. Out-of-support operating system

> *"VM should be leveraging a 1+ year outdated version of Linux"*

**Built:** Ubuntu 20.04 LTS. Standard support ended **April 2025** — over a
year out of date. `terraform/variables.tf` → `vm_image`.

**Why it matters:** no security patches. Every kernel and userland CVE
disclosed since April 2025 is unpatched and permanently unpatchable without a
distribution upgrade. An attacker doesn't need a novel exploit — public
proof-of-concept code works.

**Note for Q&A:** 20.04 is also a practical choice. MongoDB 4.4 needs
`libssl1.1`, which shipped with 20.04 but was removed in 22.04. The constraint
and the requirement pointed the same direction — a good example of an
engineering trade-off you can narrate.

---

### 2. SSH open to the entire internet

> *"SSH must be exposed to the public internet"*

**Built:** NSG rule `allow-ssh-from-internet-INTENTIONAL-WEAKNESS`, source
`Internet`, port 22. `terraform/network.tf`.

**Why it matters:** the management plane of the database server is reachable
by every host on the internet. Expect credential-stuffing and brute-force
traffic within minutes of the public IP going live. Combined with #1, this is
the initial access vector.

**Worth saying:** password authentication is *disabled* — key-only. The
exposure is the open port on an unpatched host, not a guessable password. That
distinction shows deliberate scoping rather than blanket carelessness.

---

### 3. Over-permissive cloud identity on the VM

> *"VM should be granted overly permissive CSP permissions (e.g. able to create VMs)"*

**Built:** system-assigned managed identity holding **Contributor at
subscription scope**. `terraform/vm-mongo.tf` →
`vm_overprivileged_subscription`.

**Why it matters:** this is the privilege-escalation step. Anyone who lands on
the VM runs `az login --identity` and inherits the ability to create, modify
and delete **any resource in the subscription** — no password, no key, no
prompt. Crypto-mining VMs, data exfiltration, deleting the backups, creating
persistence. The identity is invisible to traditional credential hygiene: there
is nothing to rotate.

---

### 4. End-of-life database

> *"Database should be MongoDB that is a 1+ year outdated database version"*

**Built:** MongoDB 4.4, end-of-life **February 2024**.
`terraform/cloud-init/mongo.yaml.tftpl`.

**Why it matters:** no security fixes since EOL. Known CVEs in 4.4 stay open
forever. It also means no modern defaults — weaker TLS handling and none of the
newer auditing controls.

---

### 5. Publicly readable **and listable** backup storage

> *"Object storage must allow public read and public listing"*

**Built:** `container_access_type = "container"` on the `mongo-backups`
container. `terraform/storage.tf`.

**This is the worst one in the environment.** Explain why the distinction
matters:

| Setting | Effect |
|---|---|
| `blob` | Anonymous read, but only if you already know the exact blob name |
| `container` | Anonymous read **plus enumeration** — the attacker can list every file |

With listing enabled, an attacker who guesses one storage account name walks
away with **every database backup**: all user records, password hashes, and the
full application dataset. No credentials, no exploit, no alert by default —
and because the request is anonymous, standard access logs don't attribute it
to anyone. There is no "breach" to detect in the usual sense; the data simply
leaves.

**Business framing for the panel:** this single checkbox is a reportable data
breach. It is also the kind of finding that exists in real environments for
months because nothing in the deployment pipeline objected.

---

### 6. Container running as cluster-admin

> *"Container application must be assigned a cluster-wide kubernetes admin role and privilege"*

**Built:** ClusterRoleBinding from the `tasky` ServiceAccount to the built-in
`cluster-admin` ClusterRole. `k8s/10-rbac.yaml`.

**Why it matters:** this collapses the blast radius of any application bug. The
todo app is internet-facing. Any RCE, SSRF or dependency vulnerability in it
hands the attacker a service-account token with full cluster control — read
every Secret in every namespace (including the MongoDB credentials), schedule
privileged pods, mount host filesystems, and from there reach the node's own
cloud identity.

**Demonstrate it live:**

```bash
kubectl auth can-i --list --as=system:serviceaccount:tasky:tasky
kubectl auth can-i create pods --all-namespaces --as=system:serviceaccount:tasky:tasky
kubectl get secrets --all-namespaces --as=system:serviceaccount:tasky:tasky
```

---

## Requirements that are NOT weaknesses

Two requirements in the brief are genuine security controls. Do not describe
them as flaws — being able to tell them apart is part of what is being scored.

| Requirement | Why it is a control |
|---|---|
| *"Access must be restricted to Kubernetes network access only"* | NSG permits 27017 only from the AKS subnet, with an explicit deny behind it. `terraform/network.tf` |
| *"require database authentication"* | `security.authorization: enabled` in `mongod.conf`; the app authenticates with credentials delivered as a Kubernetes Secret |

---

## The two attack chains to narrate

Do not present six findings as a list. Present two paths — this is the single
biggest difference between a candidate who found misconfigurations and one who
understands risk.

### Chain A — internet to subscription takeover

```
Public backup bucket (#5)
   └─► download every DB backup anonymously — breach, on its own
Open SSH (#2) on an unpatched host (#1)
   └─► foothold on the VM
        └─► az login --identity  →  Contributor @ subscription (#3)
             └─► full control of the subscription
```

### Chain B — web bug to cluster takeover

```
Internet-facing pod
   └─► any RCE / SSRF in the app
        └─► service account is cluster-admin (#6)
             └─► every Secret in the cluster, including Mongo credentials
                  └─► node identity  →  cloud control plane
```

**The point to land:** no single finding here is exotic. Each is a checkbox
someone set wrong. The risk is in the *combination*, and that is precisely what
individual scanners and per-service consoles do not show you — they report six
findings on six different screens with no notion that they form a path.

---

## Verification checklist

Tick each off in the live environment before the panel. Screenshot each one.

- [ ] `cat /etc/os-release` on the VM shows 20.04, and `apt list --upgradable` shows unpatched packages
- [ ] `nmap -p 22 <public_ip>` from outside shows the port open
- [ ] `mongod --version` shows 4.4.x
- [ ] `az login --identity` then `az role assignment list --assignee <principal-id> --all` shows Contributor
- [ ] Anonymous browser (no Azure login) lists the backup container and downloads a dump
- [ ] `kubectl auth can-i --list --as=system:serviceaccount:tasky:tasky` shows `*` on `*`
- [ ] Backups appear in the bucket on a daily cadence (`/etc/cron.d/mongo-backup`)
- [ ] `kubectl exec -n tasky deploy/tasky -- cat /app/wizexercise.txt` prints `Christine Furby`
