# Derived from the Dockerfile shipped with the provided tasky source.
# The ONLY change is the wizexercise.txt COPY in the release stage - keeping the
# delta minimal means the build path is already proven, and it is a one-sentence
# answer if a panelist asks what I changed.
#
# Build context is the app/ directory (so both tasky/ and wizexercise.txt are
# visible to the build):
#   docker build -t tasky:local app/

# ---- build stage ----------------------------------------------------------
FROM golang:1.26 AS build

WORKDIR /go/src/tasky
COPY tasky/ .
RUN go mod download
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /go/src/tasky/tasky

# ---- release stage --------------------------------------------------------
FROM alpine:3.22 AS release

# Pull the latest security patches published since the base-image snapshot
# (keeps openssl and musl current without waiting for a new base tag).
RUN apk --no-cache upgrade

WORKDIR /app
COPY --from=build /go/src/tasky/tasky  .
COPY --from=build /go/src/tasky/assets ./assets

# ---------------------------------------------------------------------------
# EXERCISE REQUIREMENT: wizexercise.txt must exist inside the running container
# and contain my name. It is baked into the image at build time by this COPY -
# not mounted, not injected at runtime - so it travels with the image itself.
#
# Validate in the running container:
#   kubectl exec -n tasky deploy/tasky -- cat /app/wizexercise.txt
# ---------------------------------------------------------------------------
COPY wizexercise.txt /app/wizexercise.txt

EXPOSE 8080

ENTRYPOINT ["/app/tasky"]
