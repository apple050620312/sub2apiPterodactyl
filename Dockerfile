# syntax=docker/dockerfile:1.7

ARG SUB2API_IMAGE=weishaw/sub2api:latest

FROM ${SUB2API_IMAGE} AS sub2api

# PostgreSQL is intentionally pinned to the major version used by Sub2API's
# official Docker Compose deployment. The tag still receives patch releases.
FROM postgres:18-alpine

LABEL org.opencontainers.image.title="Sub2API for Pterodactyl" \
      org.opencontainers.image.description="All-in-one Sub2API, PostgreSQL and Redis image for Pterodactyl" \
      org.opencontainers.image.source="https://github.com/apple050620312/sub2apiPterodactyl" \
      org.opencontainers.image.licenses="MIT AND LGPL-3.0-or-later"

RUN apk add --no-cache \
        ca-certificates \
        nss_wrapper \
        redis \
        tzdata \
    && addgroup -g 1000 container \
    && adduser -D -u 1000 -G container -h /home/container container \
    && mkdir -p /app /home/container \
    && chown -R container:container /app /home/container

COPY --from=sub2api --chown=container:container /app/sub2api /app/sub2api
COPY --from=sub2api --chown=container:container /app/resources /app/resources
COPY --chown=container:container scripts/entrypoint.sh /entrypoint.sh

RUN chmod 0755 /app/sub2api /entrypoint.sh \
    && ln -s /home/container/data /app/data

USER container
ENV HOME=/home/container \
    USER=container
WORKDIR /home/container

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD wget -q -T 3 -O /dev/null "http://127.0.0.1:${SERVER_PORT:-8080}/health" || exit 1

ENTRYPOINT []
STOPSIGNAL SIGINT
CMD ["/bin/sh", "/entrypoint.sh"]
