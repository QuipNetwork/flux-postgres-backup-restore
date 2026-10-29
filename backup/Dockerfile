# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The backup image: the sidecar that dumps a derived Postgres to object
# storage on a cadence, for the db image to restore after a Flux relocation.
# See backup/backup-loop.sh for what a cycle does and why.
#
# Same base as the db image, so pg_dump here and pg_restore there are the same
# build: a dump is always readable by the image that restores it.
#
# Build context is the repo root:  docker build -f backup/Dockerfile .
ARG PG_IMAGE=postgres:17-alpine@sha256:266d3c257594e195b309ae9d1805e54c788f1d7b375f56bf6c367aac6c917e7b
FROM ${PG_IMAGE}

# coreutils for `date -d` (the cadence is computed from the newest key's stamp).
# This container holds the object-store keys, so the trust store gets the same
# eMudhra assert as the db image (QUI-1959, parent QUI-1923).
COPY trust-store/assert-fixed-bundle.sh /tmp/assert-fixed-bundle.sh
RUN apk add --no-cache aws-cli coreutils curl \
 && apk add --no-cache --upgrade ca-certificates-bundle \
 && sh /tmp/assert-fixed-bundle.sh /etc/ssl/certs/ca-certificates.crt \
 && rm /tmp/assert-fixed-bundle.sh
ENV AWS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt

COPY lib/dump-keys.sh /usr/local/lib/dump-keys.sh
COPY backup/backup-loop.sh /usr/local/bin/backup-loop.sh
RUN chmod 0755 /usr/local/bin/backup-loop.sh

# FluxOS restarts every component with policy 'always' and has no run-once
# semantics, hence a long-running loop. Declaring ENTRYPOINT also clears the
# base image's CMD, so `docker run <image> --once` reaches the script.
ENTRYPOINT ["/usr/local/bin/backup-loop.sh"]
