#!/usr/bin/env bash
# resolve-digests.sh — resolve o digest sha256 de uma imagem OCI pela fonte
# primária (registry API, header Docker-Content-Digest). Suporta ghcr.io,
# Docker Hub (incl. proxies que delegam a auth.docker.io, ex. Redpanda).
#
# Uso:
#   ./resolve-digests.sh ghcr.io/posthog/posthog/capture master
#   ./resolve-digests.sh clickhouse/clickhouse-server 25.8.12.129
#   ./resolve-digests.sh docker.redpanda.com/redpandadata/redpanda v25.1.9
#
# Sem args, re-resolve TODAS as imagens do images.lock e imprime uma tabela
# comparativa (lock vs atual) — use para auditar drift antes de atualizar a
# âncora. NUNCA cravar digest sem ter rodado isto (anti-pattern
# premissa-de-fonte-secundaria-nao-verificada).
set -euo pipefail

ACCEPTS=(
  -H "Accept: application/vnd.oci.image.index.v1+json"
  -H "Accept: application/vnd.oci.image.manifest.v1+json"
  -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json"
  -H "Accept: application/vnd.docker.distribution.manifest.v2+json"
)

_digest_header() { tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}'; }

# resolve <registry-host> <repo> <ref>
_resolve() {
  local host="$1" repo="$2" ref="$3" realm svc scope tok
  # descobre o desafio de auth a partir de /v2/
  local chal
  chal=$(curl -sI --max-time 25 "https://${host}/v2/" | tr -d '\r' \
    | awk 'tolower($1)=="www-authenticate:"{sub(/^[^ ]+ /,""); print}')
  if [ -n "$chal" ]; then
    realm=$(sed -n 's/.*realm="\([^"]*\)".*/\1/p' <<<"$chal")
    svc=$(sed -n 's/.*service="\([^"]*\)".*/\1/p' <<<"$chal")
    scope="repository:${repo}:pull"
    tok=$(curl -s --max-time 25 "${realm}?service=${svc}&scope=${scope}" \
      | jq -r '.token // .access_token // empty' 2>/dev/null)
  fi
  local auth=()
  [ -n "${tok:-}" ] && auth=(-H "Authorization: Bearer ${tok}")
  curl -sI --max-time 25 "${auth[@]}" "${ACCEPTS[@]}" \
    "https://${host}/v2/${repo}/manifests/${ref}" | _digest_header
}

# normaliza "registry/repo" ou "repo" (Docker Hub oficial -> library/<x>)
resolve_ref() {
  local image="$1" ref="$2" host repo
  case "$image" in
    *.*/*|localhost/*) host="${image%%/*}"; repo="${image#*/}" ;;   # tem host
    */*)               host="registry-1.docker.io"; repo="$image" ;; # org/name no Hub
    *)                 host="registry-1.docker.io"; repo="library/$image" ;;
  esac
  _resolve "$host" "$repo" "$ref"
}

if [ "$#" -ge 2 ]; then
  resolve_ref "$1" "$2"
  exit 0
fi

# modo auditoria: re-resolve tudo do images.lock
LOCK="$(dirname "$0")/../images.lock"
[ -f "$LOCK" ] || { echo "images.lock não encontrado em $LOCK" >&2; exit 1; }
printf '%-24s %-12s %s\n' "SERVIÇO" "STATUS" "DIGEST-ATUAL"
grep -vE '^\s*#|^\s*$' "$LOCK" | while read -r svc ref _; do
  full="${ref%@*}"; locked="${ref##*@}"
  image="${full%%:*}"; tag="${full##*:}"; [ "$tag" = "$image" ] && tag="latest"
  current=$(resolve_ref "$image" "$tag" || echo "ERRO")
  if [ "$current" = "$locked" ]; then st="ok"; else st="DRIFT"; fi
  printf '%-24s %-12s %s\n' "$svc" "$st" "$current"
done
