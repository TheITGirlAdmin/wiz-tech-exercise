# Challenges faced and lessons learned

Wiz Technical Exercise — build notes worth telling the panel.

This is the "challenges and adaptations" material (presentation section 5) plus
the reasoning behind the design decisions. It is written to be *spoken*, not
read aloud verbatim — each item is a challenge, what I did about it, and the
lesson. Pick the four or five that land best for your audience; you will not
have time for all of them.

The through-line: **almost nothing here was a novel technical problem. Each was
a place where a default, a tier, or a tool's blind spot quietly did something I
had to notice.** That noticing is the job.

---

## 1. The lab tenant wouldn't let me create an app registration

**What happened.** The plan was the standard GitHub-Actions-to-Azure pattern: an
Entra app registration with a federated credential, so CI authenticates with no
stored secret. The CloudLabs tenant denies lab users the directory permission to
create app registrations — "Insufficient privileges" — even though the account
is subscription **Owner**. Full control of the subscription, zero directory
write.

**What I did.** Switched to a **user-assigned managed identity** with GitHub
OIDC federated credentials. A UAMI is an ARM resource, not a directory object,
so it lives entirely within the permissions I had.

**The lesson — and why it's actually better.** This isn't a workaround I'm
apologising for; it's the stronger design. There is **no client secret anywhere
in the system** — nothing to rotate, nothing to leak, nothing to find in a
pipeline log. The identity is federated: GitHub presents a short-lived OIDC
token, Azure trades it for access, and nothing long-lived ever touches disk.
When a constraint pushes you toward the more secure option, take the win.

## 2. Terraform's state backend is a chicken-and-egg problem

**What happened.** Terraform should manage everything — but the remote state
lives in an Azure Storage account, and you can't use Terraform to create the
storage account that Terraform needs before it can run.

**What I did.** A one-time **bootstrap script** creates exactly three things out
of band: the state resource group, the state storage account, and the OIDC
identity. Everything else flows through CI. The bootstrap is idempotent and
documented, so "how does this start from nothing" has a clean answer.

**The lesson.** Know which handful of things legitimately sit outside your
automation, make that boundary explicit, and never let it grow. "Bootstrap then
pipeline" is a pattern, not a smell.

## 3. MongoDB 4.4 pinned my operating system — and I leaned into it

**What happened.** The brief wants an out-of-support database *and* an
out-of-support OS. MongoDB 4.4 depends on `libssl1.1`, which shipped with Ubuntu
20.04 but was **removed** in 22.04. So the database requirement and the OS
requirement pointed at the same box.

**What I did.** Ubuntu 20.04 (standard support ended May 2025) running MongoDB
4.4 (EOL February 2024). One VM, two genuinely end-of-life tiers, and a
dependency chain that explains *why* rather than just asserting "it's old."

**The lesson.** When two requirements happen to align, say so out loud — it
shows you understood the constraint instead of blindly satisfying a checklist.
Defender later flagged **101 stale packages** on this box, including `mongodb`,
`openssl`, and `libssl1.1` itself: concrete proof the whole userland is
unpatchable without a distribution upgrade.

## 4. The same secret leaked three ways — despite being stored correctly

**What happened.** The Mongo password is stored properly, as a Kubernetes
Secret delivered to the container as an environment variable. And yet I found it
in cleartext in three other places:
1. the application logs the full connection string (with password) to stdout on
   startup, so it lands in Log Analytics via Container Insights;
2. the VM's cloud-init runs under `set -x`, so the password is echoed into
   `/var/log/wiz-setup.log`;
3. and of course the Secret object itself, which is only base64, not encrypted.

**The lesson — this is the one that surprises people.** "We use Kubernetes
Secrets" is treated as a checkbox for secret management. But a secret is only as
protected as its *most careless consumer*. Correct storage did nothing to stop
the same value bleeding into two log sinks that a completely different set of
people can read. Secret hygiene is about the whole lifecycle, not the vault.

## 5. Debugging a bug that only showed itself as `{}`

**What happened.** Signing up an existing user returned an empty object `{}` in
the browser — no error message, nothing actionable. The real error ("user
already exists") existed only server-side.

**What I did.** Traced it with `kubectl logs` and a direct Mongo query from an
in-cluster pod. The front-end calls `JSON.stringify(response.json())` on a
Promise that hasn't resolved, so the real error body never makes it to the user.

**The lesson.** In a distributed system the signal is rarely where the symptom
is. The habit that mattered was refusing to trust the surface and going to the
logs and the data. (I deliberately did **not** fix it — it's not one of the
required weaknesses, and it's an honest example of reading a system I didn't
write.)

## 6. My own audit logging couldn't see the most dangerous change

**What happened.** I built a detective query to catch privilege escalation —
role-assignment writes in the Activity Log. It returned **nothing**. The reason:
every privilege grant that built this environment — including the VM being handed
**Contributor at subscription scope** — happened during provisioning, *before*
the diagnostic setting was live and ingesting.

**The lesson.** A diagnostic setting only captures what happens after you switch
it on. The single most dangerous change in the whole build left **no trace in my
own audit pipeline**, because the pipeline was born in the same breath as the
grant. "We have audit logging" is a statement about the future, not the past —
and the first thing an attacker does after establishing persistence is exactly
the kind of change your logging didn't retroactively capture.

## 7. The security console's coverage tracked my invoice, not my risk

**What happened.** Microsoft Defender flagged the 101 stale packages fast. But
the posture recommendations that would have caught my *other* weaknesses —
"management ports should be closed," internet-facing NSG findings — all came back
**Not Applicable**. The storage-public-access and Kubernetes-RBAC findings
weren't generated at all.

**What I did.** Confirmed with Resource Graph that these assessments had run and
were deliberately N/A — not lag. The cause is **plan tiering**: the subscription
runs Defender for Servers **Plan 1**, and the adaptive-network-hardening
recommendations that flag internet-exposed management ports require **Plan 2**.
So I didn't wait on the console — I proved the SSH exposure and the public-bucket
breach **directly**, end to end.

**The lesson.** The tool's visibility into my environment was a function of a
procurement decision, not of the risk present. A console that shows a clean
management-ports section because you're on the cheaper tier is more dangerous
than one that shows nothing, because it looks like coverage. Verify the finding;
don't let the tool's silence gate whether the risk exists.

## 8. A policy that read correctly still didn't fire

**What happened.** I wrote a custom Azure Policy to deny RDP exposed to the
internet (deliberately targeting 3389, not the SSH the brief requires open).
When I tested it by adding a standalone NSG rule, the rule was **created** — the
policy didn't block it.

**What I did.** Diagnosed it: the policy is scoped to the network security group
and inspects its `securityRules[*]` array, which evaluates when the *whole NSG*
is written. But `az network nsg rule create` writes the rule through the **child**
resource type, a separate request the parent-scoped policy never sees. The
built-in "allowed VM SKUs" policy, by contrast, denied a disallowed VM cleanly,
because it evaluates on the resource's own creation. (The stray rule was deleted
immediately.)

**The lesson.** "The policy definition is correct" and "the policy blocks the
attack" are different claims. Array-alias policies on parent resources have real
evaluation gaps against child-resource writes — the exact false confidence that a
posture which only *reads* policy JSON, instead of red-teaming it, will miss.

## 9. GitHub's security controls were gated behind a paid tier — so I went public

**What happened.** The plan was a private repo with branch protection, secret
scanning, and push protection. On a free personal account, **secret scanning and
branch protection aren't available on private repos** — they need GitHub Advanced
Security or Pro. Dependabot was the only one of the three I could turn on.

**What I did.** Since the repository contains **no secrets** (verified against the
tree and full history) and the lab is ephemeral, I made it **public** — which
unlocks all three controls for free and doubles as a portfolio artifact. Before
flipping it, I caught three things the pre-push audit surfaced: a Terraform
**plan file** (extensionless, so the `*.tfplan` ignore missed it) that embeds the
password in cleartext; evidence screenshots containing the live password; and the
live, anonymously-readable backup URL sitting in a runbook. I redacted the URL and
**rewrote the initial commit** so it never existed in the public history.

**The lesson.** Security features have price tags, and the free-tier defaults
quietly shape what protection you actually get. And "no secrets in the repo" is a
claim about *history*, not just the current tree — a redaction in a new commit
still leaves the secret one click away in the previous one.

## 10. The pipeline's own OIDC subject wasn't what I expected

**What happened.** The first pipeline run failed at Azure login with
`AADSTS700213: no matching federated identity record`. The subject GitHub
presented embedded **immutable numeric IDs** —
`repo:owner@<id>/repo@<id>:pull_request` — not the classic `repo:owner/repo` form
my federated credential was written against.

**What I did.** Read the actual subject out of the failed run, and created
federated credentials matching it exactly. It took **three**, because the subject
differs per trigger: `:pull_request` for the plan job, `:ref:refs/heads/main` for
the app build job, and `:environment:production` for the apply job (declaring an
`environment:` in the workflow changes the subject).

**The lesson.** OIDC federation is precise by design — the subject is a string
match, and "close" fails closed. It's a good property (no wildcard trust), but it
means you have to know exactly what your identity provider emits for each trigger,
not what you assume it emits.

## 11. A deliberately-vulnerable environment can't pass a zero-finding scan

**What happened.** The Checkov IaC gate, set to hard-fail, flagged ~36 findings
on the baseline — because the environment is *intentionally* misconfigured. A
security gate that always fails is a gate everyone learns to ignore.

**What I did.** Rather than blanket-disable the scanner (silences it) or bury it
under 36 inline suppressions (unmaintainable), I recorded the known posture as a
**Checkov baseline**. The gate now fails only on **new** findings — a
no-regressions guardrail — while the headline weaknesses keep inline
`#checkov:skip` justifications for traceability. I proved it by opening a PR with
a genuinely insecure storage account (TLS 1.0, plaintext HTTP): the gate caught
the new resource and blocked the merge, while leaving the accepted baseline
alone.

**A related gap I'm honest about:** one Terraform file (the security controls,
full of heredoc KQL) doesn't parse in Checkov's HCL engine, so its resources are
silently unscanned. A gate that can't parse a file gives you a green light on
code it never actually read — worth knowing before you trust it.

## 12. The pipeline would have destroyed my database — and the plan review caught it

**What happened.** The IaC pipeline's plan, on a trivial tag change, showed
`3 to destroy` — including the Mongo VM `must be replaced`. Terraform re-renders
the cloud-init `custom_data` on every plan and compares it to state; any
difference (here, the password supplied to CI rendering slightly differently than
at the original apply) "forces replacement" of the entire VM — which would have
wiped the live database and its credentials.

**What I did.** Added `lifecycle { ignore_changes = [custom_data] }` to the VM.
Cloud-init is bootstrap-only — it runs once at first boot — so it must never
trigger the replacement of a running server. The plan dropped to `0 to destroy`,
and only then did I merge.

**The lesson — the strongest one here.** This is the entire argument for
**plan-review before apply**. `terraform apply -auto-approve` on a merge is
convenient right up until the moment it quietly schedules a database for
deletion. The gate that saved me wasn't a scanner — it was a human reading the
plan on the pull request before clicking merge.

## 13. The image scanner would have blocked the deploy — and it was right

**What happened.** Running the container pipeline's Trivy gate locally, against
the same scanner image CI uses and with the same flags, the image failed on **83
fixable critical/high vulnerabilities** — from the old Go toolchain (2 critical in
the standard library alone), an end-of-life Alpine base, and stale `x/crypto`,
`x/net`, `x/text` modules. That is a hard fail: the gate runs with
`exit-code: 1` and no `continue-on-error`, so this image could not have reached
ACR or the cluster. To be precise about the evidence: **no CI run shows Trivy
failing**, because I caught and fixed this before pushing (see below).

**What I did.** The container image isn't one of the required weaknesses (that's
the cluster-admin binding), so hardening it is fair game. Bumped the Go build
image, the Alpine base (plus an `apk upgrade` to grab a patch newer than the base
tag itself carried), and the flagged modules — down to **zero** fixable
critical/high. I validated every step locally against the same scanner image the
CI uses, so I never burned a failed pipeline run finding out.

**The lesson.** Two lessons, actually. First: a blocking gate is only doing its
job when it occasionally blocks *you* — the 83 findings were real, and the gate
was configured to refuse them. Second: mirror your CI gates locally. Debugging a
scanner by pushing commits and waiting is slow and public; running the same
container image on your laptop turns a day of red X's into a tight loop.

---

## The single insight to close on

Walk back through this list. The public bucket, the open SSH, the over-privileged
identity, the cluster-admin pod, the stale packages, the leaked password — a
different native tool sees each one. Defender sees the storage account. Policy
could block a SKU. kube-audit records the exec. The scanner flags the image.

**Not one of them sees that the public bucket, the unpatched host, and the
subscription-Contributor identity form a single path from the internet to
subscription takeover.** Six findings on six screens is what the native tools
give you. The attack *path* — ranked by what an attacker can actually chain — is
the thing a security team acts on, and it's precisely the correlation that
per-service consoles structurally cannot do. That gap is the reason graph-based,
context-aware posture exists.
