FROM ghcr.io/posthog/posthog@sha256:24728274ac746f2a56a0568721cc136f2fcb4c8e8e8b617fa3060f126e4e215d

COPY ./compose /compose

ENTRYPOINT [ "/compose/temporal-django-worker" ]
