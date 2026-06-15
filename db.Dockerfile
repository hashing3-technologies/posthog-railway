FROM postgres:15.12-alpine@sha256:ef9d1517df69c4d27dbb9ddcec14f431a2442628603f4e9daa429b92ae6c3cd1

COPY ./posthog/docker/postgres-init-scripts /docker-entrypoint-initdb.d
