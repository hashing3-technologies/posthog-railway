# PostHog self-hosted — Railway Template (HASHING3)

A Railway template, maintained by **HASHING3 Technologies**, to deploy
**self-hosted PostHog** (the open-source product analytics platform) in a
production-grade architecture: ~19 isolated services, **object storage 100% on
Backblaze B2**, images **pinned by `sha256` digest**, and a dedicated build
pipeline.

> **Dedicated repo** (1 template = 1 repo, Dockerfiles at the root). The
> **service composition** (the ~19 containers, env, volumes, wiring) is defined
> on the **Railway platform** and published as a template; this repo provides the
> Dockerfiles → the pipeline builds them → the images are pushed to GHCR → the
> template consumes the images (by digest).

## Architecture — ~19 services (each one a container)

Modern PostHog is a multi-technology architecture, each part running as an
isolated service on Railway:

- **App:** `web`, `worker`, `plugins`, `temporal-django-worker`
- **Capture / processing (Rust/Go):** `capture`, `replay-capture`, `feature-flags`,
  `property-defs-rs`, `cyclotron-janitor`, `cymbal` (error tracking), `livestream`
- **Data:** `db` (Postgres), `clickhouse` (OLAP), `redis7`
- **Streaming:** `kafka`, `zookeeper`, `kafka-init`
- **Orchestration:** `temporal`
- **Proxy:** `proxy` (Caddy) — **optional**; see the routing options in
  [`docs/architecture.md`](docs/architecture.md)
- **Object storage:** **external (Backblaze B2)** — no embedded local storage

> **Footprint:** ClickHouse + Kafka + Zookeeper + Temporal are *always-on*.
> Official self-host baseline: ~4 vCPU / 16 GB RAM / 30 GB.

## How the build works

The Dockerfiles depend on files from the **PostHog source code** (configs,
`compose` scripts, GeoIP) that are not vendored in this repo — so the build is
**pre-built** in CI (not on Railway): the pipeline clones the source at the
anchor commit, generates the scripts, and publishes the 19 images to
`ghcr.io/hashing3-technologies/posthog-railway/*`. Railway then consumes those
ready-made images (by digest).

| Path | What it is |
|---|---|
| `*.Dockerfile` (root) | 19 Dockerfiles, each `FROM` pinned by `@sha256` |
| `images.lock` | Source of truth for digest pinning (image → digest + origin) |
| `.env.example` | Reference for env vars (B2 storage + service wiring) |
| `tools/resolve-digests.sh` | Re-resolves digests from the upstream source / audits drift |
| `docs/architecture.md` | Template architecture decisions (services, storage, pinning, routing) |
| `.github/workflows/build-images.yaml` | Build & publish the 19 images to GHCR |

**Reproducibility:** every `FROM` is pinned by `sha256` digest (never a mutable
tag), so an image can't change underneath the template. To bump the anchor, run
`tools/resolve-digests.sh` (re-resolves from the source; never hardcode a digest
from memory) and update `images.lock` + the workflow.

## Object storage — 100% Backblaze B2

No local storage: `OBJECT_STORAGE_*` (exports/cache) +
`SESSION_RECORDING_V2_S3_*` (Session Replay, **enabled**) + `cymbal` (error
tracking) all point to B2 (S3-compatible). Details and compatibility notes live
in [`.env.example`](.env.example). **Acceptance check:** smoke-test the
replay → B2 path before going live.

> Why external storage: keeping object storage off-cluster lets every stateful
> service stay small and lets you scale storage independently. Any S3-compatible
> backend works; this template is wired for Backblaze B2.

## Required CI secrets

Configure them under **Settings → Secrets and variables → Actions**:

| Secret | Value |
|---|---|
| `DOCKERHUB_USERNAME` | Docker Hub username (avoids the anonymous-pull `429`) |
| `DOCKERHUB_TOKEN` | Personal Access Token (*Public Repo Read* scope) |

GHCR uses the automatic `GITHUB_TOKEN`.

## Supply chain / security

- **Digest pinning** (`@sha256`) — immutability (the image can't change under the tag).
- **Trivy** report-only — report in the log + SARIF in the **Security tab** (does
  not block the build: the template packages third-party images with upstream CVEs
  we don't control; triage via the Security tab instead of a hard gate).
- **SLSA provenance** — the build emits `--attest type=provenance,mode=max`.

> cosign on the base images does not apply (PostHog/Docker/ClickHouse don't
> publish cosign signatures; verified). The immutability guarantee comes from the
> digest pin.

## Deploy on Railway

1. Make sure the 19 GHCR packages are **public** (each package's Settings) so
   Railway can pull the images.
2. On Railway, compose the template: create the 19 services using
   `ghcr.io/hashing3-technologies/posthog-railway/<service>`, with env
   (incl. B2), volumes and wiring. See [`docs/railway-composition.md`](docs/railway-composition.md).
3. Publish as a template + smoke-test Session Replay → B2.
