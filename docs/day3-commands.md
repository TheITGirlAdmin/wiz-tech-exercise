# Day 3 — Cloud Native Security: commands, KQL, and evidence checklist

Everything needed to complete and evidence **D3.1 – D3.9**. Run top to bottom.
Every query is copy-pasteable into either the Log Analytics portal blade or
`az monitor log-analytics query`.

Screenshots go in `docs/evidence/day3/` using the naming convention
`D3.<n>-<short-name>.png` so the evidence pack sorts itself.

---

## Read this before you start — three things that will otherwise waste your morning

**1. No alert email will arrive. That is by design, not a failure.**
`alert_email = ""` in `terraform.tfvars`, so the action group
`wizex-demo-security-ag` was created with **no receivers**. The alert rules
still evaluate, still fire, and still appear in **Azure Monitor → Alerts**.
That blade is your evidence. The Day 3 plan says "you receive the email" —
ignore that line, it predates the decision to skip email delivery.
*Panel-ready framing:* "an action group decides who gets told, not whether
detection happens."

**2. Budget 30–45 minutes from trigger to fired alert.** Two lags stack:

| Stage | Delay |
|---|---|
| Data-plane / audit log ingestion into LAW | 5–15 min |
| Alert rule evaluation (`evaluation_frequency = PT10M`) | up to 10 min |
| Window (`window_duration = PT30M`) | catches anything in the last 30 min |

So: **fire the D3.7 and D3.8 triggers FIRST thing**, then do D3.1–D3.6 while
they bake, then come back and collect the alerts. The runbook below is ordered
that way.

**3. PowerShell rules that already bit you twice on this project.**
- Judge `az` success by `$LASTEXITCODE` only — az failures are *native* errors,
  so `$ErrorActionPreference='Stop'` does not catch them.
- Never pipe native stderr with `2>&1` — an ordinary az WARNING becomes a
  terminating ErrorRecord.
- Quote any flag whose value contains a dot or a pipe.

---

## Pre-flight

```powershell
az login --use-device-code        # CloudLabs account, NOT the Gmail one
az account set --subscription 48c7ea7c-4479-4f86-b463-c49e2ed4e869
az account show --query "{sub:name, user:user.name}" -o table

az aks get-credentials --resource-group wizex-demo-rg --name wizex-demo-aks --overwrite-existing
kubectl get pods -n tasky
```

Grab the workspace GUID once — `az monitor log-analytics query` needs the
**customerId**, not the resource ID:

```powershell
$ws = az monitor log-analytics workspace show `
        --resource-group wizex-demo-rg `
        --workspace-name wizex-demo-law `
        --query customerId -o tsv
$ws
```

Helper so the rest of this document stays short:

```powershell
function q($kql) { az monitor log-analytics query --workspace $ws --analytics-query $kql -o table }
```

---

# STEP 0 (do this first) — fire both detective triggers, then walk away

## D3.7 trigger — anonymous access to the backup bucket

Run this from a context with **no Azure credentials** (plain PowerShell is
fine — `curl.exe` sends no Azure auth header). This is the attacker's-eye view,
and it is what makes the alert meaningful.

```powershell
# 1. Enumerate the container anonymously (this is the ListBlobs event)
curl.exe -s "https://wizexbak1a8vsi.blob.core.windows.net/mongo-backups?restype=container&comp=list"

# 2. Download a backup anonymously (this is the GetBlob event)
#    Substitute the newest blob name from the listing above.
curl.exe -s -o "$env:TEMP\stolen-backup.gz" `
  "https://wizexbak1a8vsi.blob.core.windows.net/mongo-backups/<blob-name>"

Get-Item "$env:TEMP\stolen-backup.gz" | Select-Object Name, Length
```

Note the wall-clock time. **Screenshot** the terminal showing both requests
succeeding with no credentials → `D3.7-anonymous-access-trigger.png`.

## D3.8 trigger — kubectl exec into a running pod

```powershell
kubectl exec -it -n tasky deploy/tasky -- /bin/sh
# inside the pod, do something that reads like an attacker:
#   cat /app/wizexercise.txt
#   env | grep -i mongo
#   cat /var/run/secrets/kubernetes.io/serviceaccount/token | head -c 60
#   exit
```

**Screenshot** the exec session → `D3.8-kubectl-exec-trigger.png`.

> Do the `env | grep -i mongo` step. It shows the Mongo connection string —
> including the password — sitting in the pod environment, which ties this
> screenshot straight into the "one secret leaks three ways" narrative.

Now leave both alone for ~30 minutes and work through D3.1–D3.6.

---

# D3.1 — Verify control-plane audit logging

The subscription Activity Log is wired to the workspace by
`azurerm_monitor_diagnostic_setting.activity_log`
(`enable_activity_log_diagnostics = true`), categories Administrative,
Security, Policy, ServiceHealth, Alert, Recommendation, Autoscale,
ResourceHealth.

**Portal:** Log Analytics workspaces → `wizex-demo-law` → Logs.

### Q1.1 — Is anything arriving at all?

```kusto
AzureActivity
| where TimeGenerated > ago(4d)
| summarize Events = count(), Latest = max(TimeGenerated) by CategoryValue
| order by Events desc
```

*Accept:* rows returned, `Administrative` present.

### Q1.2 — Your own Day 1 / Day 2 writes, the money shot

```kusto
AzureActivity
| where TimeGenerated > ago(4d)
| where CategoryValue == "Administrative"
| where ResourceGroup =~ "wizex-demo-rg"
| where ActivityStatusValue in ("Success", "Start", "Accepted")
| project TimeGenerated, Caller, OperationNameValue, ActivityStatusValue, _ResourceId
| order by TimeGenerated asc
| take 100
```

*Accept:* you can point at the creation of the AKS cluster, the Mongo VM, the
storage account and the policy assignments — i.e. **your `terraform apply` is
attributable, operation by operation, to an identity.**

### Q1.3 — Who did what, summarised (better for a slide than a raw log dump)

```kusto
AzureActivity
| where TimeGenerated > ago(4d)
| where ResourceGroup =~ "wizex-demo-rg"
| summarize Operations = count(),
            First = min(TimeGenerated),
            Last  = max(TimeGenerated)
    by Caller, CategoryValue
| order by Operations desc
```

### Q1.4 — Role assignment changes (the privilege-escalation tripwire)

Worth having ready: this is the query that would have shown the VM being given
Contributor at subscription scope.

```kusto
AzureActivity
| where TimeGenerated > ago(4d)
| where OperationNameValue has "ROLEASSIGNMENTS/WRITE"
| project TimeGenerated, Caller, ActivityStatusValue, Properties
```

**Screenshot** Q1.2 and Q1.4 → `D3.1-azureactivity.png`,
`D3.1-roleassignment-writes.png`.

---

# D3.2 — Verify Kubernetes audit logging

### Q2.1 — Confirm kube-audit is flowing

```kusto
AzureDiagnostics
| where TimeGenerated > ago(1d)
| where ResourceProvider == "MICROSOFT.CONTAINERSERVICE"
| summarize Events = count(), Latest = max(TimeGenerated) by Category
| order by Events desc
```

*Accept:* `kube-audit` and `kube-audit-admin` both present with recent
timestamps.

> **If this returns nothing**, the diagnostic setting may have landed in
> resource-specific mode. Check the dedicated tables before assuming failure:
> ```kusto
> AKSAudit | where TimeGenerated > ago(1d) | count
> ```
> Terraform did not set `log_analytics_destination_type`, so the provider
> default (AzureDiagnostics) is expected — but check rather than panic. If it
> IS in AKSAudit, the alert rule's KQL would need the same treatment, and you
> should say so honestly on the day.

### Q2.2 — Prove the audit trail is legible, not just present

```kusto
AzureDiagnostics
| where TimeGenerated > ago(1d)
| where Category == "kube-audit"
| extend audit = parse_json(column_ifexists("log_s", ""))
| where tostring(audit.stage) == "ResponseComplete"
| project TimeGenerated,
          actor     = tostring(audit.user.username),
          verb      = tostring(audit.verb),
          resource  = tostring(audit.objectRef.resource),
          namespace = tostring(audit.objectRef.namespace),
          name      = tostring(audit.objectRef.name),
          code      = toint(audit.responseStatus.code)
| order by TimeGenerated desc
| take 50
```

### Q2.3 — Everything the cluster-admin service account did

This is the one that connects logging back to intentional weakness #6.

```kusto
AzureDiagnostics
| where TimeGenerated > ago(2d)
| where Category == "kube-audit"
| extend audit = parse_json(column_ifexists("log_s", ""))
| where tostring(audit.user.username) startswith "system:serviceaccount:tasky:"
| summarize Calls = count() by verb = tostring(audit.verb),
                                resource = tostring(audit.objectRef.resource)
| order by Calls desc
```

**Screenshot** Q2.1 and Q2.2 → `D3.2-kube-audit-flowing.png`.

---

# D3.3 — Verify storage data-plane logging

### Q3.1 — Anonymous reads of the backup container

This is the query that matters. It is also the exact detection logic behind
detective control A.

```kusto
StorageBlobLogs
| where TimeGenerated > ago(2d)
| where AccountName == "wizexbak1a8vsi"
| where AuthenticationType == "Anonymous"
| project TimeGenerated, OperationName, CallerIpAddress, UserAgentHeader,
          StatusCode, ResponseBodySize, Uri
| order by TimeGenerated desc
```

*Accept:* your Day 2 anonymous download **and** this morning's D3.7 trigger
both appear, with `AuthenticationType == "Anonymous"`.

### Q3.2 — Authenticated vs anonymous, side by side

The strongest single slide in the logging section: the same container, two
access patterns, one of which has no identity attached to it.

```kusto
StorageBlobLogs
| where TimeGenerated > ago(2d)
| where AccountName == "wizexbak1a8vsi"
| summarize Requests = count(),
            BytesOut = sum(ResponseBodySize),
            Callers  = dcount(CallerIpAddress)
    by AuthenticationType, OperationName
| order by AuthenticationType asc, Requests desc
```

### Q3.3 — How much data actually left, anonymously

```kusto
StorageBlobLogs
| where TimeGenerated > ago(7d)
| where AccountName == "wizexbak1a8vsi"
| where AuthenticationType == "Anonymous" and OperationName == "GetBlob"
| summarize Downloads = count(),
            TotalMB = round(sum(ResponseBodySize) / 1024.0 / 1024.0, 2)
    by CallerIpAddress
| order by TotalMB desc
```

> **The honest point to make here:** the log records *an IP address*, not a
> principal. There is no `Caller`, no object ID, nothing to revoke. You can
> prove data left; you cannot prove who took it, and you cannot cut off their
> access without changing the container. That is the difference between logging
> an authenticated action and logging an anonymous one — and it is the reason
> "we have logging enabled" is not the same as "we would have caught it."

**Screenshot** Q3.1 and Q3.3 → `D3.3-storageblobLogs-anonymous.png`,
`D3.3-bytes-exfiltrated.png`.

---

# D3.4 — Confirm Defender for Cloud is enabled

```powershell
az security pricing list --query "value[?pricingTier=='Standard'].{Plan:name, Tier:pricingTier, Subplan:subPlan}" -o table
```

*Accept:* `VirtualMachines` (P1), `Containers`, `StorageAccounts`
(DefenderForStorageV2) all show **Standard**.

**Portal:** Microsoft Defender for Cloud → Environment settings → subscription
`Wizio Labs DS - 1540` → Defender plans.
**Screenshot** → `D3.4-defender-plans-on.png`.

---

# D3.5 — Review Defender recommendations ⭐ *do this early*

Initial CSPM assessment can take several hours after the plans are enabled;
the plans went on during Day 1's apply, so findings should be populated by now.

**Portal path:** Defender for Cloud → Recommendations → filter by resource
group `wizex-demo-rg`.

CLI equivalent via Resource Graph (install the extension if prompted):

```powershell
az extension add --name resource-graph --only-show-errors

az graph query -q "securityresources
| where type =~ 'microsoft.security/assessments'
| where properties.status.code == 'Unhealthy'
| extend resourceId = tostring(properties.resourceDetails.Id)
| where resourceId contains 'wizex-demo'
| project Finding = tostring(properties.displayName),
          Severity = tostring(properties.metadata.severity),
          Resource = tostring(split(resourceId, '/')[-1])
| order by Severity asc, Finding asc" --first 100 -o table
```

*Accept:* you can point to findings covering, at minimum:

- [ ] Storage account allows public / anonymous blob access
- [ ] Management ports (SSH/22) exposed to the internet
- [ ] VM missing OS updates / EOL operating system
- [ ] Overprivileged identity or excessive subscription role assignments
- [ ] Kubernetes RBAC / privileged workload findings

**Screenshot** the filtered recommendations list → `D3.5-defender-recommendations.png`,
plus one drill-down on the public storage finding → `D3.5-public-storage-finding.png`.

> **The Solution Engineer point — say this out loud on the day.** Defender
> found the same misconfigurations. What it hands you is *six findings on six
> screens*, each with its own severity, sorted by severity rather than by
> exploitability. What it does not tell you is that #5 alone is a reportable
> breach with no exploit required, or that #1 + #2 + #3 chain into subscription
> takeover. Finding the misconfigurations is table stakes. **Ranking them by
> the path they form is the product conversation.**

---

# D3.6 — Demonstrate the preventative control ⭐

Two Deny policies are assigned at the resource-group scope. Demonstrate both —
the brief only requires one, and the second one costs nothing.

First, show they exist:

```powershell
az policy assignment list --scope "/subscriptions/48c7ea7c-4479-4f86-b463-c49e2ed4e869/resourceGroups/wizex-demo-rg" --query "[].{Name:displayName, Enforcement:enforcementMode}" -o table
```

## 6a — Custom policy: deny internet-exposed RDP  ← lead with this one

Zero cost, zero cleanup, instant result — and it is the *custom* policy, which
is the better story. It also demonstrates deliberate scoping: it targets 3389,
**not** 22, because the exercise requires SSH to stay open. A guardrail that
fought the brief would be a worse answer, not a stricter one.

Confirm the NSG name first, then attempt the rule:

```powershell
az network nsg list -g wizex-demo-rg --query "[].name" -o tsv

az network nsg rule create `
  --resource-group wizex-demo-rg `
  --nsg-name <mongo-nsg-name-from-above> `
  --name policytest-allow-rdp-internet `
  --priority 4000 `
  --direction Inbound --access Allow --protocol Tcp `
  --source-address-prefixes Internet `
  --destination-address-prefixes "*" `
  --destination-port-ranges 3389

echo "exit code: $LASTEXITCODE"
```

*Accept:* fails with **`RequestDisallowedByPolicy`** naming
`wizex-demo-deny-rdp-internet`. Nothing is created.

## 6b — Built-in policy: deny unapproved VM sizes

Allowed list is `Standard_B1s, Standard_B2s, Standard_B2ms, Standard_D2s_v3`.
`Standard_D8s_v3` is outside it.

```powershell
az vm create `
  --resource-group wizex-demo-rg `
  --name policytest-vm `
  --image Ubuntu2204 `
  --size Standard_D8s_v3 `
  --admin-username azureuser `
  --ssh-key-values "$env:USERPROFILE\.ssh\wiz_exercise.pub" `
  --public-ip-address "" `
  --nsg ""

echo "exit code: $LASTEXITCODE"
```

*Accept:* fails with **`RequestDisallowedByPolicy`**.

> ⚠️ **Cleanup — do not skip.** ARM deployments are not transactional. The VM
> is denied, but `az vm create` may already have created a NIC (and a VNet, if
> it did not find one to reuse) before hitting the deny. Sweep for leftovers:
> ```powershell
> az resource list -g wizex-demo-rg --query "[?starts_with(name,'policytest')].{Name:name, Type:type}" -o table
> # then, for anything listed:
> az resource delete -g wizex-demo-rg --name <name> --resource-type <type>
> ```
> Re-run the list until it returns empty. Confirm the Mongo VM is untouched:
> `az vm list -g wizex-demo-rg -o table`

## 6c — Compliance evidence

**Portal:** Policy → Compliance → filter to `wizex-demo-rg`.

```powershell
az policy state list --resource-group wizex-demo-rg --query "[?complianceState=='NonCompliant'].{Policy:policyDefinitionName, Resource:resourceId, State:complianceState}" -o table
```

A denied request is itself an audited event, so it also lands in the Activity Log:

```kusto
AzureActivity
| where TimeGenerated > ago(1h)
| where ActivityStatusValue == "Failure"
| where Properties has "RequestDisallowedByPolicy" or ResourceProviderValue has "AUTHORIZATION"
| project TimeGenerated, Caller, OperationNameValue, ActivityStatusValue, Properties
| order by TimeGenerated desc
```

**Screenshot** the two deny errors and the compliance blade →
`D3.6-deny-rdp.png`, `D3.6-deny-vm-sku.png`, `D3.6-policy-compliance.png`.

---

# D3.7 — Collect detective control A (anonymous backup access)

You fired the trigger in Step 0. Now collect the evidence.

### Verify the detection logic fired on real data

This is the alert rule's KQL verbatim (from
`azurerm_monitor_scheduled_query_rules_alert_v2.anonymous_backup_access`):

```kusto
StorageBlobLogs
| where AccountName == "wizexbak1a8vsi"
| where AuthenticationType == "Anonymous"
| where OperationName in ("GetBlob", "ListBlobs")
| project TimeGenerated, OperationName, CallerIpAddress, Uri, StatusCode
```

*Accept:* rows from your Step 0 trigger. Rule config: severity **1**, evaluated
every 10 min over a 30 min window, threshold `Count > 0`.

### Confirm the alert actually fired

```powershell
az monitor scheduled-query list -g wizex-demo-rg --query "[].{Name:name, Enabled:enabled, Severity:severity, Freq:evaluationFrequency}" -o table
```

**Portal — this is the primary evidence:** Monitor → Alerts → filter to
resource group `wizex-demo-rg`, time range last 4 hours. Look for
`wizex-demo-anonymous-backup-access`, severity Sev1.

**Screenshot** the fired alert and its detail pane (showing the matching rows)
→ `D3.7-alert-fired-anonymous-access.png`, `D3.7-alert-detail.png`.

> **If it has not fired yet:** check ingestion first —
> `StorageBlobLogs | where TimeGenerated > ago(30m) | count`. If the rows are
> not in the workspace yet, the rule has nothing to fire on and you simply wait.
> If rows *are* there and the rule still shows no alert, run the KQL manually,
> screenshot the matching rows, and say so on the day. Demonstrating that the
> detection logic is correct while being straight about alerting lag is a better
> answer than pretending — and the panel will respect it more.

---

# D3.8 — Collect detective control B (kubectl exec)

### Verify the detection logic fired on real data

Alert rule KQL verbatim:

```kusto
AzureDiagnostics
| where Category == "kube-audit"
| extend audit = parse_json(column_ifexists("log_s", ""))
| where tostring(audit.objectRef.subresource) == "exec"
| where tostring(audit.stage) == "ResponseStarted"
| project TimeGenerated,
          actor     = tostring(audit.user.username),
          namespace = tostring(audit.objectRef.namespace),
          pod       = tostring(audit.objectRef.name),
          sourceIP  = tostring(audit.sourceIPs[0])
```

*Accept:* a row for your Step 0 exec, showing **your** username, the `tasky`
namespace, the pod name, and **your public IP**.

That last column is the point worth making: the cluster audit trail attributes
the action to a named principal from a specific source address. Contrast it
directly with D3.3 Q3.1, where the same environment's worst finding produced a
log line with no principal at all. **Same workspace, same day, two very
different investigations.**

**Portal:** Monitor → Alerts → `wizex-demo-kubectl-exec-detected`, Sev2.

**Screenshot** → `D3.8-alert-fired-kubectl-exec.png`, `D3.8-kube-audit-rows.png`.

---

# D3.9 — What each control would and would not catch ⭐

The highest-value 30 minutes of the exercise. Draft below — **read it, argue
with it, and edit it in your own words before the panel.** You will be asked
"would your controls have stopped this?" and the answer has to be yours.

## Chain A — internet to subscription takeover

| # | Attacker step | Prevented? | Detected? | By what | Gap |
|---|---|---|---|---|---|
| A1 | Enumerate + download every DB backup anonymously | ❌ No | ✅ Yes | Detective A (Sev1) + `StorageBlobLogs` | **Detection is after the fact. The data is already gone.** Log records an IP, not a principal — nothing to revoke. |
| A2 | Scan and connect to SSH/22 on the public IP | ❌ No | ⚠️ Partial | Defender for Servers (brute-force / suspicious login alerts); NSG flow logs not enabled | No alert on *connection*; only on Defender-recognised patterns. A key-based login from a new IP looks normal. |
| A3 | Exploit an unpatched Ubuntu 20.04 CVE for local privesc | ❌ No | ⚠️ Partial | Defender for Servers behavioural alerts | Nothing on the VM ships local process telemetry beyond Defender's agent. |
| A4 | `az login --identity` → assume the VM's managed identity | ❌ No | ❌ **No** | — | **The biggest blind spot.** Acquiring a token from IMDS is a local call to 169.254.169.254 — it never touches the Azure control plane, so it generates no Activity Log entry at all. |
| A5 | Act as Contributor across the subscription | ❌ No | ✅ Yes | `AzureActivity` (D3.1 Q1.2 / Q1.4) | Every write is logged and attributable to the VM's principal ID — **but no alert rule watches for it.** Logged ≠ alerted. |
| A6 | Delete the backups / destroy evidence | ❌ No | ✅ Yes | `AzureActivity` + blob soft-delete (7 days, `delete_retention_policy`) | Detected and recoverable — one control that genuinely works. |

**Verdict on Chain A:** the chain is **logged end-to-end except at step A4**,
and **alerted at only one step (A1)** — which is the step where the damage is
already complete. Nothing here stops the chain; one control notices the first
domino and the rest leave a trail you could reconstruct afterwards.

**What would have actually broken it, in priority order:**
1. Container access type `private` + SAS. Kills A1 outright — and A1 is a
   reportable breach on its own, with no exploit required.
2. Least-privilege on the VM identity (Storage Blob Data Contributor scoped to
   one account, not Contributor at subscription). Turns A4→A5 from *subscription
   takeover* into *write a backup file*.
3. Just-in-time / bastion access instead of SSH open to the internet. Removes A2.
4. An alert on `AzureActivity` role-assignment and resource-creation writes by
   the VM principal. Converts A5 from logged to noticed.

## Chain B — web bug to cluster takeover

| # | Attacker step | Prevented? | Detected? | By what | Gap |
|---|---|---|---|---|---|
| B1 | RCE / SSRF in the internet-facing Tasky pod | ❌ No | ❌ No | — | No WAF, no runtime sensor on the pod. Ingress is plain nginx. |
| B2 | Read the service-account token from the pod filesystem | ❌ No | ❌ No | — | Purely in-container; produces no API-server call, so kube-audit sees nothing. |
| B3 | Use the cluster-admin token to read every Secret in every namespace | ❌ No | ✅ **Yes** | kube-audit (D3.2 Q2.3) | Logged and attributed to `system:serviceaccount:tasky:tasky` — **but no alert rule fires on it.** This is the single best candidate for the next detection to build. |
| B4 | Schedule a privileged pod / mount the host filesystem | ❌ No | ✅ Yes | kube-audit; Defender for Containers | Would likely trigger a Defender alert — worth checking live rather than claiming. |
| B5 | Reach the node's kubelet identity → cloud control plane | ❌ No | ✅ Yes | `AzureActivity` | Same gap as A5: logged, not alerted. |
| B6 | `kubectl exec` for hands-on-keyboard work | ❌ No | ✅ Yes | Detective B (Sev2) | Only fires if the attacker uses the API server's exec path — an attacker already inside the pod has no reason to. **Detects a careless attacker, not a competent one.** |

**Verdict on Chain B:** detection improves as the attacker goes *deeper*, which
is exactly backwards. The earliest steps (B1, B2) are invisible; the loudest
control (B6) sits on a path a real attacker can skip entirely.

**What would have actually broken it:**
1. Drop `cluster-admin` to a Role scoped to the `tasky` namespace with no
   Secret read beyond its own. Collapses B3–B5 to nothing.
2. `automountServiceAccountToken: false` — removes B2 for a workload that never
   calls the API server anyway.
3. An alert on any `system:serviceaccount:*` reading Secrets outside its own
   namespace. This is ~10 lines of KQL; see Q2.3 for the shape of it.

## The three sentences to land

1. **Every one of these is a checkbox someone set wrong** — no zero-days, no
   exotic technique.
2. **Logging is not detection and detection is not prevention.** This
   environment logs almost everything, alerts on two things, and prevents
   nothing that matters — a distribution that is extremely common in real
   subscriptions.
3. **The risk is in the combination, not the findings.** Six findings on six
   screens is what a scanner gives you. Two attack paths ranked by exploitability
   is what a security team can act on Monday morning.

**Deliverable:** write the two verdicts into
`docs/evidence/day3/D3.9-control-coverage.md` in your own words. That file is
your Q&A cheat sheet.

---

# Evidence checklist

Tick as you go. Every ✅ needs a file in `docs/evidence/day3/`.

### Logging (D3.1 – D3.3)
- [ ] `D3.1-azureactivity.png` — Day 1 terraform operations, attributable by caller
- [ ] `D3.1-roleassignment-writes.png` — role assignment writes visible
- [ ] `D3.2-kube-audit-flowing.png` — kube-audit + kube-audit-admin ingesting
- [ ] `D3.3-storageblobLogs-anonymous.png` — anonymous GetBlob / ListBlobs
- [ ] `D3.3-bytes-exfiltrated.png` — how much data left, by caller IP

### Defender (D3.4 – D3.5)
- [ ] `D3.4-defender-plans-on.png` — Servers P1 / Containers / Storage V2 all Standard
- [ ] `D3.5-defender-recommendations.png` — findings filtered to `wizex-demo-rg`
- [ ] `D3.5-public-storage-finding.png` — drill-down on the public storage finding

### Preventative (D3.6)
- [ ] `D3.6-deny-rdp.png` — `RequestDisallowedByPolicy`, custom policy
- [ ] `D3.6-deny-vm-sku.png` — `RequestDisallowedByPolicy`, built-in policy
- [ ] `D3.6-policy-compliance.png` — Policy → Compliance blade
- [ ] **Leftover `policytest-*` resources swept and confirmed empty**

### Detective (D3.7 – D3.8)
- [ ] `D3.7-anonymous-access-trigger.png` — attacker's-eye trigger, no credentials
- [ ] `D3.7-alert-fired-anonymous-access.png` — Sev1 alert in Monitor → Alerts
- [ ] `D3.7-alert-detail.png` — matching rows in the alert detail
- [ ] `D3.8-kubectl-exec-trigger.png` — exec session
- [ ] `D3.8-alert-fired-kubectl-exec.png` — Sev2 alert
- [ ] `D3.8-kube-audit-rows.png` — actor + source IP attribution

### Analysis (D3.9)
- [ ] `D3.9-control-coverage.md` — both chains, in your own words
- [ ] You can answer "would your controls have stopped this?" without hesitating

---

# Panel Q&A this day arms you for

Have an answer ready for each — these come straight out of the work above.

1. *"You enabled logging. Would you have known you'd been breached?"*
   → Yes for the bucket, within ~30 min, by IP only. No for the identity
   assumption at A4. Be specific about which.
2. *"Why deny RDP when SSH is the port that's actually open?"*
   → Deliberate scoping: the brief requires 22 open. A control that fights the
   requirement is a worse answer, not a stricter one.
3. *"Defender found these too. What does Wiz add?"*
   → Ranking by attack path, not severity. Chain A vs six screens.
4. *"Your alert didn't email anyone."*
   → Correct, by configuration. An action group decides who gets told, not
   whether detection happens. Detection is in the rule; delivery is a routing
   decision.
5. *"What's the first thing you'd fix?"*
   → Container access type. It is one setting, it is a reportable breach on its
   own, and it needs no exploit.
6. *"What did you NOT detect?"*
   → IMDS token acquisition (A4), in-pod token theft (B2), the initial web
   exploit (B1). Knowing your blind spots is the answer.
