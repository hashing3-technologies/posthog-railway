# Template architecture

Architecture decisions for the HASHING3 self-hosted PostHog template — the
services, image pinning, object storage, and edge routing. Primary source: the
Dockerfiles and build pipeline in this repo.

## How the build works

The pipeline **builds** the images (it does not re-tag prebuilt ones): it clones
the PostHog source at a `POSTHOG_APP_TAG`, generates GeoIP + the `compose/`
scripts, and runs `docker build` for each Dockerfile. There are three kinds of
`FROM`:

- **Main Django image** `ghcr.io/posthog/posthog:<tag>` — used by `web`,
  `worker`, `plugins`, `temporal-django-worker`.
- **Prebuilt Rust/Go components** `ghcr.io/posthog/posthog/<comp>:master` —
  `capture`, `replay-capture`, `cymbal`, `feature-flags`, `livestream`,
  `property-defs-rs`, `cyclotron-janitor` (pulled ready-made from upstream).
- **Third-party infra** — clickhouse, postgres, redpanda, cp-kafka, caddy,
  redis, temporal, zookeeper.

## The 19 services

| Service | Upstream image | HASHING3 pinning |
|---|---|---|
| web | `posthog/posthog:${TAG}` | `@sha256` (anchor commit) |
| worker | `posthog/posthog:${TAG}` | `@sha256` |
| plugins | `posthog/posthog:${TAG}` | `@sha256` |
| temporal-django-worker | `posthog/posthog:${TAG}` | `@sha256` |
| capture | `.../capture:master` | `:master@sha256` |
| replay-capture | `.../capture:master` | `:master@sha256` (same image) |
| cyclotron-janitor | `.../cyclotron-janitor:master` | `:master@sha256` |
| cymbal | `.../cymbal:master` | `:master@sha256` |
| feature-flags | `.../feature-flags:master` | `:master@sha256` |
| livestream | `.../livestream:master` | `:master@sha256` |
| property-defs-rs | `.../property-defs-rs:master` | `:master@sha256` |
| clickhouse | `clickhouse-server:25.8.12.129` | `:tag@sha256` |
| db | `postgres:15.12-alpine` | `:tag@sha256` |
| kafka-init | `redpanda:v25.1.9` | `:tag@sha256` |
| kafka | `cp-kafka:7.7.7` | `:tag@sha256` |
| proxy | `caddy:2-alpine` | `@sha256` |
| redis7 | `redis:7.2-alpine` | `:tag@sha256` |
| temporal | `auto-setup:1.20.0` | `:tag@sha256` |
| zookeeper | `zookeeper:3.7.0` | `:tag@sha256` |

**Object storage is not a service** — it goes 100% to Backblaze B2 (see D4),
so the template ships **19 services** (no local MinIO/SeaweedFS).

## Architecture decisions

### D1 — Digest pinning (reproducibility)
Every `FROM` is pinned by `@sha256` (see `images.lock`) — never a mutable tag.
Why: the Rust/Go component images ship as `:master` (rolling, changes without
notice) and Caddy as `:latest`; without pinning the build is not reproducible.
The output is published with `tag = anchor commit` (not `:latest`) and
**consumed by digest** in the Railway template (the pipeline prints the published
digest in the job summary).

### D2 — Upstream version skew (known limitation)
`web` is pinnable by commit SHA, but upstream **does not publish** the Rust/Go
sub-images by SHA — only `:master` (verified: `capture:<sha>` → 404;
`capture:master` → valid digest). So the components may sit at a different commit
than `web`. Mitigation: each `:master` is pinned by its snapshot digest —
reproducible, but the skew is inherent to upstream. When bumping the anchor,
re-resolve ALL of them together (`tools/resolve-digests.sh`).

### D3 — Own registry
Images are published to `ghcr.io/hashing3-technologies/posthog-railway` —
auditable, under the org, with its own supply chain (Trivy + provenance).

### D4 — Object storage 100% Backblaze B2
No ephemeral local storage (block disk is expensive/limited and isn't volume
object storage). `OBJECT_STORAGE_*` + `SESSION_RECORDING_V2_S3_*` (Session
Replay) + `cymbal` point to B2 (S3-compatible). Any S3-compatible backend works;
the template is wired for B2.

### D5 — Edge routing (how PostHog is exposed)
PostHog has several services that receive external traffic (`web`, `capture`,
`feature-flags`, `livestream`). There are three ways to expose them; the `proxy`
service is **optional** and only used by the first one.

| Option | How | Pros | Cons |
|---|---|---|---|
| **Built-in Caddy proxy** (`proxy`) | One public domain, path-based: `/` → web, `/i/` `/e/` → capture, `/flags` → feature-flags, `/livestream` → livestream | Single domain; ad-blocker resistant (ingestion served under your own domain); simpler cookies/CORS | Needs a custom domain; on Railway TLS is terminated at the edge, so Caddy runs with `auto_https off` |
| **Railway native domains** | Expose `web` / `capture` / `feature-flags` / `livestream` each via its own `*.up.railway.app` or custom domain | Simplest; automatic TLS; no proxy to maintain | Multiple hosts; the PostHog snippet must set `api_host` (capture) and `ui_host` (web) separately; obvious capture hosts are easier for ad-blockers to block |
| **External reverse proxy** (e.g. Cloudflare Workers / your CDN) | Route the same paths to the internal services from your own edge | Single-domain + anti-adblock benefits, one less service on Railway | Requires an external edge you already operate |

**Recommendation:** for production, prefer a reverse proxy (built-in Caddy or
external) so the ingestion endpoint sits under your own domain and survives
ad-blockers, which silently drop a meaningful share of events. Drop the `proxy`
service if you pick native domains or an external proxy.

## Accepted risks

- **B2 S3 compatibility:** core S3 (PUT/GET/multipart) works; no presigned POST,
  object tagging, or per-object ACL. Server-side usage is not blocked.
  **Acceptance check:** smoke-test Session Replay → B2 (record + read back) before
  going live.
- **Replay read egress isn't free:** the `$0` Bandwidth Alliance rate is
  B2↔Cloudflare; Railway↔B2 is direct and billed. Monitor it.
- **Fallback:** if replay v2 multipart fails on B2, introduce SeaweedFS only for
  `SESSION_RECORDING_V2_S3_*` (hybrid).
