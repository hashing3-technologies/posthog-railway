FROM temporalio/auto-setup:1.20.0@sha256:c2deeb6706ae80f91bbf61b22a5442e240f25c901cfffbba857eb8bff80e0a6d

LABEL kompose.volume.type=configMap

COPY ./posthog/docker/temporal/dynamicconfig /etc/temporal/config/dynamicconfig
