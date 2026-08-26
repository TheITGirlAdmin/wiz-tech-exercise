# D1.1–D1.5 explained

What each step actually does, why it is in the plan, and how to explain it to
the panel. Read this before running the commands, not after.

**The principle behind all five tasks:** validate everything that does not
require the cloud *before* touching the cloud. Your lab access is a
consumable resource. Compiler errors, typos and wrong file paths cost nothing
to find on your laptop and cost lab days to find in Azure.

That principle is itself worth saying out loud to the panel. It is how mature
teams work, and it is the same reasoning that puts scanners in a CI pipeline
rather than in production.

---

## D1.1 — Install the toolchain

### What it does

Installs seven command-line tools and generates an SSH keypair.

| Tool | What it is for |
|---|---|
| **git** | Version control. The brief requires your code in a VCS. |
| **az** | Azure CLI. Authenticates you and calls the Azure REST APIs. |
| **terraform** | Infrastructure as Code. Describes the desired state of your cloud and makes reality match it. |
| **kubectl** | The Kubernetes API client. The brief *requires* you to demonstrate it live. |
| **gh** | GitHub CLI. Creates the repo and sets pipeline secrets without clicking through the web UI. |
| **helm** | Kubernetes package manager. Not strictly needed — we use the AKS managed ingress addon instead of installing nginx by chart — but useful if you need to change approach. |
| **docker** | Builds container images and runs containers locally. |

### The SSH keypair

The script runs `ssh-keygen`, producing two files:

- `wiz_exercise` — the **private** key. Stays on your laptop. Never shared.
- `wiz_exercise.pub` — the **public** key. Goes into Terraform, which puts it
  on the VM.

This is asymmetric cryptography: the VM can verify you hold the private key
without ever seeing it. No password is transmitted, and there is no password to
guess.

> **Say to the panel:** "The VM uses key-based authentication only — password
> auth is explicitly disabled in the Terraform. The deliberate weakness the
> exercise asked for is the *exposed port*, not a weak credential."
>
> That distinction shows you scoped the vulnerability intentionally rather than
> being careless everywhere.

---

## D1.2 — Build the container image

### The three concepts

These get conflated constantly. Being crisp about them signals you understand
containers rather than just running commands.

| Term | What it is |
|---|---|
| **Dockerfile** | A recipe. Plain text instructions for assembling an image. |
| **Image** | An immutable, layered snapshot of a filesystem plus metadata. Built once, never changes. |
| **Container** | A running instance of an image. Many containers can run from one image. |

The analogy: the Dockerfile is the recipe, the image is the cake you baked, the
container is a slice being eaten. Rewriting the recipe doesn't change a cake
you already baked — you have to bake a new one. That is why every code change
means a new image build and a new tag.

### The build context

```powershell
docker build -t tasky:local app/
```

That trailing `app/` is the **build context** — the set of files Docker can
see. It gets packaged up and handed to the build engine.

This matters practically: a `COPY` instruction can only reference files
**inside the context**. It is why `wizexercise.txt` lives at `app/wizexercise.txt`
and not at the repository root — if it were outside `app/`, the `COPY` would
fail.

`-t tasky:local` tags the result. `tasky` is the name, `local` the tag. Later
you retag the same image with the ACR hostname so it can be pushed.

### Multi-stage build — the part worth explaining

Our Dockerfile has two `FROM` lines, which makes it a **multi-stage build**:

```dockerfile
FROM golang:1.19 AS build          # Stage 1: compile
WORKDIR /go/src/tasky
COPY tasky/ .
RUN go mod download                 # fetch Go dependencies
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /go/src/tasky/tasky

FROM alpine:3.17.0 AS release       # Stage 2: ship
WORKDIR /app
COPY --from=build /go/src/tasky/tasky  .      # <- pull ONLY the binary across
COPY --from=build /go/src/tasky/assets ./assets
COPY wizexercise.txt /app/wizexercise.txt
```

**Only the final stage becomes the image.** Stage 1 is scaffolding and is
discarded.

Why that is a security decision, not just a size optimisation:

| | Stage 1 (`golang:1.19`) | Stage 2 (`alpine:3.17.0`) |
|---|---|---|
| Size | ~800 MB | ~7 MB |
| Contains | Go compiler, build tools, full source | The compiled binary and assets |

The shipped image has **no compiler, no source code, and no package manager**.
An attacker who achieves code execution inside the container has almost no
tooling to work with. Fewer packages also means dramatically fewer CVEs for a
scanner to report — which matters directly, because your pipeline runs Trivy
against this image and gates on HIGH/CRITICAL findings.

### One flag worth knowing

`CGO_ENABLED=0` builds a **statically linked** binary with no external C
library dependencies. It matters because Alpine uses `musl` rather than `glibc`
— a dynamically linked Go binary built on Debian would fail to start on Alpine
with a confusing "not found" error. This flag is why the two stages can use
different base distributions at all.

> **Likely panel question:** *"Why multi-stage?"*
> **Answer:** "To keep build tooling out of the runtime image. The shipped
> container has no compiler and no source — smaller attack surface, and far
> fewer packages for a vulnerability scanner to flag. It also keeps the image
> small enough to pull quickly during a rollout."

---

## D1.3 — Prove `wizexercise.txt` is in the image

```powershell
docker run --rm --entrypoint cat tasky:local /app/wizexercise.txt
```

### Why `--entrypoint` is necessary

Our image ends with `ENTRYPOINT ["/app/tasky"]`. An ENTRYPOINT is the process
that always runs when the container starts; anything you put after the image
name becomes **arguments to it**, not a separate command.

So the obvious-looking version:

```powershell
docker run --rm tasky:local cat /app/wizexercise.txt      # WRONG
```

actually executes `/app/tasky cat /app/wizexercise.txt` — it starts the web
server and passes it two arguments it ignores. You would see the app boot, not
your name, and it would be baffling.

`--entrypoint cat` overrides the entrypoint for this one run, so the container
runs `cat /app/wizexercise.txt` and exits. `--rm` deletes the container
afterwards so you don't accumulate stopped containers.

### What this proves, and why the brief asks for it

The brief requires the file to be **in the container image**, and asks you to
explain *how you got it in* and *validate it exists in the running container*.

It is in the image because of a `COPY` instruction at build time. It is baked
into an image layer. It travels with the image everywhere the image goes.

This is the distinction the question is testing:

| Approach | Satisfies the requirement? |
|---|---|
| `COPY` in the Dockerfile | **Yes** — the file is part of the image |
| Kubernetes volume mount | No — the file is attached at runtime; the image doesn't contain it |
| ConfigMap | No — same reason |
| `kubectl cp` into a running pod | No — and it vanishes when the pod restarts |

> **Say to the panel:** "It's added with a COPY instruction in the Dockerfile,
> so it's baked into an image layer at build time — not mounted at runtime. If
> you pull this image anywhere in the world, the file is in it."

On Day 2 you prove the same thing against the live pod:

```bash
kubectl exec -n tasky deploy/tasky -- cat /app/wizexercise.txt
```

That one needs no `--entrypoint`, because `kubectl exec` starts a **new
process** inside an already-running container rather than starting the
container.

---

## D1.4 — End-to-end test against local MongoDB

This is the highest-value task of the morning. It exercises the complete
application stack with no cloud involved.

### What the commands do

```powershell
docker network create tasky-test
```

Creates a **user-defined bridge network**. The important property: containers
on it can reach each other **by container name** via Docker's built-in DNS.
That is why the connection string can say `mongo-test` instead of an IP
address.

```powershell
docker run -d --name mongo-test --network tasky-test mongo:4.4
```

Starts MongoDB 4.4 — the same version as the Azure VM, so behaviour matches.
`-d` runs it detached, in the background.

```powershell
docker run -d --name tasky-test --network tasky-test -p 8080:8080 `
  -e MONGODB_URI="mongodb://mongo-test:27017" `
  -e SECRET_KEY="localtestsecret" `
  tasky:local
```

- `-p 8080:8080` publishes the container's port 8080 to your laptop, so your
  browser can reach it.
- `-e` sets environment variables.

### Why the environment variables are the point

The app reads its configuration from the environment at startup —
`os.Getenv("MONGODB_URI")` in `database/database.go`. This is standard
twelve-factor design: **configuration lives in the environment, not in the
image**. The same image runs against a local test database, a staging database
or production, with nothing rebuilt.

That is exactly what the brief requires in Kubernetes: *"Access to MongoDB must
be configured via an environment variable configured in Kubernetes."* Locally
you supply it with `-e`; in Kubernetes a Secret supplies it. **Same mechanism,
different source.**

### Verifying the data landed

```powershell
docker exec mongo-test mongo go-mongodb --eval "db.todos.find().pretty()"
```

`docker exec` runs a command inside an already-running container. `mongo` is
the shell, `go-mongodb` the database, `--eval` runs a single statement.

The database name is not a choice — Tasky hardcodes it:

```go
client.Database("go-mongodb").Collection(collectionName)
```

It ignores whatever database you put in the connection string. The collections
are `todos` and `user` (singular — an easy typo to make live).

### What this task proves, and what it doesn't

**Proves:** the image builds and runs, the app connects to MongoDB, the
environment-variable wiring works, writes actually persist, and you know the
correct database and collection names for the Day 2 demo.

**Does not prove:** anything about Azure — the NSG rules, MongoDB
authentication, the ingress, or the load balancer. Those can only be tested in
the lab.

> **Say to the panel:** "I validated the full application stack locally against
> a matching MongoDB version before deploying anything, so when I moved to
> Azure any failure was necessarily an infrastructure problem rather than an
> application one. That let me debug one variable at a time."

---

## D1.5 — Validate the Terraform offline

```powershell
terraform fmt -recursive
terraform init -backend=false
terraform validate
```

### What Terraform is, in one paragraph

You write **declarative** configuration describing what should exist. Terraform
records what it has already built in a **state file**, compares that to your
configuration, works out the difference, and calls the cloud provider's APIs to
close the gap. You never write "create a VM" — you write "a VM exists with
these properties", and Terraform decides whether that means creating,
modifying, or doing nothing.

### The three commands

**`terraform fmt -recursive`** rewrites your `.tf` files into canonical
formatting — consistent indentation, aligned `=` signs. Cosmetic, but the CI
pipeline runs `fmt -check` and fails if files are unformatted, so running it
now avoids a pipeline failure later.

**`terraform init -backend=false`** downloads the provider plugins — the
`azurerm` provider is roughly 200 MB of code that knows how to talk to Azure.
The `-backend=false` flag is the important part: it skips configuring remote
state, which would require contacting Azure. **This is what keeps the task
free.** Nothing authenticates, nothing is created, the clock stays stopped.

**`terraform validate`** checks the configuration for correctness:

- Syntax errors
- References to variables or resources that do not exist
- Type mismatches (a string where a list is expected)
- **Arguments that do not exist in the provider's schema**

That last one is why this task is in the plan. The `azurerm` provider changes
its argument names between major versions. If I have written
`storage_account_name` where version 4 expects `storage_account_id`, this is
where it surfaces — in seconds, for free, instead of 20 minutes into a live
`terraform apply`.

### What `validate` does **not** do

This distinction is worth being precise about:

| Command | Needs credentials? | Contacts Azure? | Checks what |
|---|---|---|---|
| `validate` | No | No | Syntax and provider schema |
| `plan` | Yes | Yes (read-only) | Your config vs. what actually exists |
| `apply` | Yes | Yes (writes) | Makes reality match your config |

`validate` cannot tell you whether a storage account name is already taken
globally, whether you have quota, or whether your account has permission. Those
are runtime facts that only `plan` and `apply` discover.

> **Say to the panel:** "I validated the configuration offline before ever
> authenticating. It catches schema and syntax errors in seconds with no cloud
> access — the same shift-left principle as running IaC scanning in the
> pipeline, just earlier still."

---

## Concepts to be able to define cold

The panel may ask any of these directly. If you cannot answer in a sentence,
come back to the relevant section above.

- [ ] Difference between an image and a container
- [ ] What a build context is, and why `wizexercise.txt` lives in `app/`
- [ ] Why the build is multi-stage, and the security benefit
- [ ] Difference between ENTRYPOINT and a command you pass to `docker run`
- [ ] How `wizexercise.txt` got into the image, and why a volume mount would not satisfy the requirement
- [ ] Why configuration comes from environment variables rather than the image
- [ ] Difference between `terraform validate`, `plan` and `apply`
- [ ] What Terraform state is and why it lives in Azure Storage rather than on your laptop
- [ ] Why the SSH key is asymmetric, and what is actually exposed on the VM

---

## On the AI question

Your recruiter said generative AI is permitted, provided you understand and can
explain every step. If it comes up, answer directly: you used AI assistance to
accelerate the build, and you validated everything yourself — which is what
this document and the local-first testing sequence are for.

What would damage you is not the tool. It is being unable to explain a choice
in your own environment. That is why every task in the plan has an acceptance
criterion you verify with your own eyes, and why this document explains
mechanisms rather than just listing commands.
