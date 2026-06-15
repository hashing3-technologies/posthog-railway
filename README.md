# PostHog self-hosted — Railway Template (HASHING3)

Template Railway para subir **PostHog self-hosted** (analytics de produto open-source).
Variante HASHING3 do template-base [`Hexatare/posthog-railway-template`](https://github.com/Hexatare/posthog-railway-template),
com **object storage 100% no Backblaze B2**, imagens **pinadas por digest** e CI próprio.

> **Repo dedicado** (1 template = 1 repo, Dockerfiles na raiz — padrão Railway).
> A **composição dos serviços** (os ~19 containers, env, volumes, ligações) é
> definida na **plataforma Railway** e publicada como template; este repo fornece
> os Dockerfiles → o workflow builda → as imagens vão pro GHCR → o template usa
> as imagens.

## Arquitetura — ~19 serviços (cada um é um container)

O PostHog moderno **não** é o "hobby" de 5 serviços; é uma arquitetura de
múltiplas tecnologias, cada uma rodando como serviço isolado na Railway:

- **App:** `web`, `worker`, `plugins`, `temporal-django-worker`
- **Captura/processamento (Rust/Go):** `capture`, `replay-capture`, `feature-flags`,
  `property-defs-rs`, `cyclotron-janitor`, `cymbal` (error tracking), `livestream`
- **Dados:** `db` (Postgres), `clickhouse` (OLAP), `redis7`
- **Streaming:** `kafka`, `zookeeper`, `kafka-init`
- **Orquestração:** `temporal`
- **Proxy:** `proxy` (Caddy)
- **Object storage:** **externo (Backblaze B2)** — SeaweedFS e MinIO do base **removidos**

> **Footprint:** ClickHouse + Kafka + Zookeeper + Temporal são *always-on*.
> Baseline oficial de self-host: ~4 vCPU / 16 GB RAM / 30 GB.

## Como funciona o build

Os Dockerfiles dependem de arquivos do **source-code do PostHog** (configs, scripts
`compose`, GeoIP) que não ficam no repo — por isso o build é **pré-buildado** no
CI (não na Railway): o workflow clona o source no commit-âncora, gera os scripts,
e publica as 19 imagens em `ghcr.io/hashing3-technologies/posthog-railway/*`. A
Railway então consome essas imagens prontas (por digest).

| Caminho | O que é |
|---|---|
| `*.Dockerfile` (raiz) | 19 Dockerfiles, cada `FROM` cravado por `@sha256` |
| `images.lock` | Fonte de verdade do digest pinning (imagem → digest + origem) |
| `.env.example` | Referência de env vars (storage B2 verificado + wiring) |
| `tools/resolve-digests.sh` | Re-resolve digests da fonte primária / audita drift |
| `docs/inventario-base.md` | Auditoria do template-base + as 4 falhas corrigidas |
| `.github/workflows/build-images.yaml` | Build & publish das 19 imagens no GHCR |

**Reprodutibilidade (ADR-014):** todo `FROM` é por digest `sha256` (nunca tag
mutável). Para atualizar a âncora, rode `tools/resolve-digests.sh` (re-resolve da
fonte; nunca cravar digest de memória) e atualize `images.lock` + o workflow.

## Object storage — 100% Backblaze B2 (ADR-015)

Substitui SeaweedFS + MinIO. `OBJECT_STORAGE_*` (exports/cache) +
`SESSION_RECORDING_V2_S3_*` (Session Replay, **ativo**) + `cymbal` (error
tracking) apontam para o B2 (S3-compatible). Detalhes e notas de compatibilidade
no [`.env.example`](.env.example). **Gate de aceite:** smoke test do replay → B2.

## Secrets necessários no CI

Configure em **Settings → Secrets and variables → Actions**:

| Secret | Valor |
|---|---|
| `DOCKERHUB_USERNAME` | usuário do Docker Hub (evita o `429` de pull anônimo) |
| `DOCKERHUB_TOKEN` | Personal Access Token (escopo *Public Repo Read*) |

O GHCR usa o `GITHUB_TOKEN` automático.

## Supply chain / segurança

- **Digest pinning** (`@sha256`) — imutabilidade (a imagem não muda sob a tag).
- **Trivy** report-only — relatório no log + SARIF no **Security tab** (não
  bloqueia: o template empacota imagens de terceiros com CVEs upstream que não
  controlamos; triagem via Security tab, não gate).
- **Provenance SLSA** — o build gera `--attest type=provenance,mode=max`.

> cosign nas imagens base não se aplica (PostHog/Docker/ClickHouse não publicam
> assinatura cosign; verificado). A garantia de imutabilidade vem do digest pin.

## Deploy na Railway

1. Garantir os 19 packages GHCR **públicos** (Settings de cada package).
2. Na Railway, compor o template: criar os 19 serviços usando
   `ghcr.io/hashing3-technologies/posthog-railway/<serviço>`, com env
   (incl. B2), volumes e ligações.
3. Publicar como template + smoke test do Session Replay → B2.
