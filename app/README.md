# Application

The web app is **Tasky**, the sample todo list supplied with the Wiz exercise
(`tasky-main.zip`). A Go application backed by MongoDB.

The source is **vendored into `app/tasky/`** rather than cloned at build time,
so the build has no external dependency and the exact code that ships in the
image is committed and reviewable. Two files from the original archive were
removed: its `Dockerfile` (superseded by ours) and its `.github/` workflow
(would conflict with this repo's pipelines).

## Files owned by this repo

| File | Purpose |
|---|---|
| `Dockerfile` | Multi-stage build; adds `wizexercise.txt` to the provided build |
| `wizexercise.txt` | Contains `Christine Furby` — baked into the image |
| `tasky/` | Vendored application source (MIT licensed) |

## Environment variables consumed by Tasky

| Variable | Source |
|---|---|
| `MONGODB_URI` | Kubernetes Secret `tasky-db` (see `k8s/`) |
| `SECRET_KEY` | Kubernetes Secret `tasky-db` — JWT signing key |

## Things worth knowing before the demo

**The database name is hardcoded.** `database/database.go` calls
`client.Database("go-mongodb")`, so the app writes to `go-mongodb` no matter
what database you put in `MONGODB_URI`. The collections are `todos` and `user`
(singular). Query those names or the data will look like it isn't there.

**`godotenv.Overload()` runs at startup.** It is harmless when no `.env` file
exists — the container has none, so the Kubernetes environment variables win.

## Local build and verification (no cloud, no lab clock)

```powershell
docker build -t tasky:local app/

# The exercise requirement, proven locally first.
# --entrypoint is REQUIRED: the image's ENTRYPOINT is /app/tasky, so without it
# "cat /app/wizexercise.txt" is passed to the app as arguments instead of run.
docker run --rm --entrypoint cat tasky:local /app/wizexercise.txt

# Full end-to-end against a throwaway local MongoDB
docker network create tasky-test
docker run -d --name mongo-test --network tasky-test mongo:4.4
docker run -d --name tasky-test --network tasky-test -p 8080:8080 `
  -e MONGODB_URI="mongodb://mongo-test:27017" `
  -e SECRET_KEY="localtestsecret" `
  tasky:local

# Browse http://localhost:8080 , sign up, add a todo, then:
docker exec mongo-test mongo go-mongodb --eval "db.todos.find().pretty()"

# Teardown
docker rm -f tasky-test mongo-test ; docker network rm tasky-test
```

Get this passing locally before the lab clock starts. It validates the image,
the `wizexercise.txt` requirement, the environment-variable wiring and the
database/collection names — everything except Azure itself.
