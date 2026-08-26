# Presentation outline — 45 minutes

Wiz supplies a slide template; this is the content to pour into it. The panel
scores: what you built, your methodology, challenges faced, your security
insight, and communication quality. Budget roughly **20 minutes of slides and
25 minutes of live demo**, interleaved rather than back-to-back.

---

## 1. Opening (2 min)

- Who you are, and the lens you bring: detection engineering and security
  operations, now applied to cloud infrastructure you built yourself.
- What you'll cover, and that you'll be showing live systems throughout.

## 2. The environment (5 min) — slides

- Architecture diagram (one slide, the whole picture).
- Design decisions and why: Azure, Terraform, AKS with the managed nginx
  ingress addon, GitHub Actions with OIDC rather than stored credentials.
- Name the two-tier split clearly: front-end in Kubernetes, data tier on a VM.

## 3. Build-out approach (5 min) — slides

Lead with methodology, not tools.

- Everything is IaC from day one — the environment is disposable and
  reproducible, which is what made iterating affordable on a lab budget.
- Bootstrap-then-pipeline: the state backend and OIDC identity are created once
  out of band, everything else flows through CI.
- Intentional weaknesses are **labelled in code** — tagged resources, named
  `INTENTIONAL-WEAKNESS`, and explicitly accepted with `#checkov:skip`
  justifications. Deliberate risk acceptance, not an unmanaged scanner.

## 4. LIVE: the application works (5 min)

Demo steps A–C from the README.

- Ingress URL → add a todo.
- Query MongoDB from inside the cluster → the record is really there.
- `kubectl exec … cat /app/wizexercise.txt`.

## 5. Challenges and adaptations (5 min) — slides

Be specific and honest. Candidate examples — replace with what actually
happened to you:

- MongoDB 4.4 needs `libssl1.1`, which pins the OS choice to Ubuntu 20.04.
  Turned a constraint into a feature: both tiers are genuinely out of support.
- Terraform state chicken-and-egg — resolved with a one-time bootstrap script.
- AKS nodes private but the API server public — a real trade-off, taken
  knowingly so CI could reach the cluster without a self-hosted runner.
- Whatever CloudLabs permission limits you hit, and how you worked around them.

**This section is where candidates differentiate.** Panels reward a clear
account of something that went wrong and how you reasoned about it.

## 6. LIVE: the weaknesses and what they chain into (8 min)

Demo steps E–F. Do not present these as a list of findings — present them as
**one attack path**:

> Public bucket leaks the backups → backups contain credentials and data →
> SSH is open on an unpatched host → that host's identity is Contributor at
> subscription scope → the whole subscription falls.

Then the second path:

> Internet-facing pod → cluster-admin service account → every Secret in the
> cluster, including the database credentials → node identity → cloud plane.

For each: what the misconfiguration is, what an attacker gains, what it would
cost the business.

## 7. LIVE: the controls (8 min)

Demo steps G–I.

- **Preventative:** the policy denial, live. Show the error message.
- **Detective:** trigger the alerts, show them fire, show the Defender
  recommendations for this resource group.
- **Pipeline:** the blocked PR, the blocked image, push protection.

Make the point that the controls are layered — prevent at deploy time, detect
at runtime, gate in the pipeline — and be honest about what each one would and
would not have caught in the attack paths you just walked through.

## 8. Where a CNAPP fits (5 min) — slides

This is the part that shows you understand what Wiz sells.

- The native tools each see one slice. Defender flags the public storage,
  kube-audit shows the exec, Policy blocks a SKU — but nothing correlates
  *public bucket + unpatched host + over-privileged identity* into a single
  prioritised attack path.
- Agentless scanning versus the coverage gaps you hit setting up per-resource
  logging and per-plan Defender enablement.
- Toxic combinations, not finding counts. Be ready to say which single finding
  in your environment you'd fix first, and why.

## 9. Close (2 min)

- What you'd change for production: private API server, no public bucket,
  workload identity instead of a cluster-admin service account, managed
  database instead of a VM, JIT access instead of open SSH.
- Hand over to questions.

---

## Preparation checklist

- [ ] Real name in `app/wizexercise.txt`, image rebuilt
- [ ] Full `destroy` → `apply` cycle rehearsed end to end
- [ ] Every demo command in a scratch file, ready to paste — do not type live
- [ ] Screenshots of every demo step saved as backup slides
- [ ] A recorded screen capture of the full demo as the ultimate fallback
- [ ] Alerts pre-triggered once so there is history in the workspace
- [ ] Terminal font size increased; Portal in a clean profile with no other tabs
- [ ] Know your numbers: how many resources, how long an apply takes, cost/day
- [ ] Rehearsed answer for "what would you do differently?"
