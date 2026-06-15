FROM ghcr.io/posthog/posthog/livestream:master@sha256:28c40d3a7444d3ddbe64c5fbe3beba99937154cf1c3f960cfbf714892db827eb

COPY ./posthog/docker/livestream/configs-hobby.yml /configs/configs.yml
