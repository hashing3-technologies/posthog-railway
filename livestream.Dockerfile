FROM ghcr.io/posthog/posthog/livestream:master@sha256:28c40d3a7444d3ddbe64c5fbe3beba99937154cf1c3f960cfbf714892db827eb

# A imagem :master (rolling) espera o config no formato NOVO (seção consumers.*),
# mas o configs-hobby.yml do commit-âncora 9373a2b só tem kafka.* -> falha com
# "consumers.event.brokers must be set". Usamos um config próprio no formato novo
# (espelha a master) em vez do config do source âncora. Skew documentado no
# images.lock (componentes Rust/Go só existem na tag :master).
COPY ./livestream-configs.yml /configs/configs.yml
