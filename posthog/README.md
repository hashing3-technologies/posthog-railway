# PostHog self-hosted — Railway Template (HASHING3)

Template Railway para subir **PostHog self-hosted** (analytics de produto open-source) com
deploy 1-clique. Object storage **100% no Backblaze B2** (sem storage local).

> **Status: 🚧 Em construção (Fase A).** Esta pasta é o scaffold inicial. A composição do
> template (Dockerfiles com digest pinning, workflow de imagens próprio, `.env.example`
> documentado e `docs/`) é a próxima leva. Este README é placeholder honesto, não o overview final.

## Arquitetura (~19 serviços — variante do template-base, PostHog moderno)

O PostHog atual **não** é o "hobby" de 5 serviços. Esta variante (base: Hexatare/Railway) traz:

- **App:** `web`, `worker`, `plugins`, `temporal-django-worker`
- **Captura/processamento (Rust/Go):** `capture`, `replay-capture`, `feature-flags`,
  `property-defs-rs`, `cyclotron-janitor`, `cymbal` (error tracking), `livestream`
- **Dados:** `db` (Postgres), `clickhouse` (OLAP), `redis`
- **Streaming:** `kafka`, `zookeeper`, `kafka-init`
- **Orquestração:** `temporal`
- **Proxy:** Caddy
- **Object storage:** **externo (Backblaze B2)** — SeaweedFS e MinIO do template-base **removidos**

> **Footprint:** ClickHouse + Kafka + Zookeeper + Temporal são *always-on* (não escalam a
> zero). Baseline oficial de self-host: ~4 vCPU / 16 GB RAM / 30 GB. Planeje RAM permanente.

## Object storage — 100% Backblaze B2

Todas as camadas de object storage do PostHog apontam para o Backblaze B2 (S3-compatible),
no lugar do SeaweedFS/MinIO embarcados:

| Camada | Variáveis | Conteúdo |
|---|---|---|
| Object storage geral | `OBJECT_STORAGE_*` | exports, query cache, uploads |
| Session Replay (**ativo**) | `SESSION_RECORDING_V2_S3_*` | gravações de sessão (revisão de UX) |
| Error tracking | `OBJECT_STORAGE_ENDPOINT` do `cymbal` | artefatos de error tracking |

```
OBJECT_STORAGE_ENABLED=true
OBJECT_STORAGE_ENDPOINT=https://s3.<region>.backblazeb2.com
OBJECT_STORAGE_REGION=<region>
OBJECT_STORAGE_ACCESS_KEY_ID=<b2_application_key_id>
OBJECT_STORAGE_SECRET_ACCESS_KEY=<b2_application_key>
OBJECT_STORAGE_BUCKET=<your-bucket>

SESSION_RECORDING_V2_S3_ENDPOINT=https://s3.<region>.backblazeb2.com
SESSION_RECORDING_V2_S3_REGION=<region>
SESSION_RECORDING_V2_S3_ACCESS_KEY_ID=<b2_application_key_id>
SESSION_RECORDING_V2_S3_SECRET_ACCESS_KEY=<b2_application_key>
SESSION_RECORDING_V2_S3_BUCKET=<your-bucket>
```

> **Notas de compatibilidade.** O Backblaze B2 implementa o core S3 (PUT/GET/multipart via
> PUT), mas **não** suporta presigned POST, object tagging nem ACL por objeto. O uso é
> server-side, então isso normalmente não bloqueia — mas:
>
> - **Smoke test obrigatório (gate):** gravar uma sessão de Session Replay e **relê-la**,
>   confirmando os objetos no bucket B2 (valida o multipart contínuo do replay v2).
> - **Egress de leitura de replay não é grátis:** o `$0 egress` da Bandwidth Alliance é
>   B2↔Cloudflare; o tráfego PostHog(Railway)↔B2 é direto e pago. Monitorar.
> - **Fallback:** se o replay→B2 falhar no multipart, re-introduzir SeaweedFS apenas para
>   `SESSION_RECORDING_V2_S3_*` (híbrido).

## Roadmap de construção

- [x] Scaffold do repositório
- [ ] Dockerfiles com digest pinning (release estável do PostHog) → registry HASHING3
- [ ] Workflow de imagens próprio (digest sha256)
- [ ] `.env.example` completo + `docs/` (setup, operação, custo, contingência storage)
- [ ] Composição e publicação do template na Railway + smoke test do Session Replay → B2
