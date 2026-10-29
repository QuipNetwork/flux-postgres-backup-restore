# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The db image: stock Postgres plus restore-on-empty, for apps whose database
# is DERIVED state -- a block explorer's index, rebuildable from the chain.
#
# Why: at instances:1 a Flux relocation hands the app a virgin volume, and
# FluxOS restores nothing. A derived database survives that by re-indexing from
# genesis, but that takes hours (Subscan: ~14 h at 200k blocks, growing ~1 h a
# day). This image instead restores the newest dump that the backup image put
# in object storage, then the app indexes only what is newer.
#
# The restore runs from /docker-entrypoint-initdb.d, which the stock entrypoint
# runs ONLY on an empty data directory, so it can never touch a live database.
# It runs against the init-time temporary server, which listens on the unix
# socket only, so the app cannot connect until the restore is done.
#
# Unlike observe's Postgres image (whose data is the source of truth and so
# fails CLOSED), this one fails OPEN: any restore problem ends in an empty
# database and a re-index, which is exactly what happened before this image
# existed. See db/restore-on-empty.sh.
#
# Build context is the repo root:  docker build -f db/Dockerfile .
ARG PG_IMAGE=postgres:17-alpine@sha256:266d3c257594e195b309ae9d1805e54c788f1d7b375f56bf6c367aac6c917e7b
FROM ${PG_IMAGE}

# aws-cli reads the OS bundle on Alpine, and AWS_CA_BUNDLE pins it explicitly.
# This container holds the object-store keys, so its trust store must not hold
# the forged eMudhra chain (QUI-1959, parent QUI-1923); the assert fails the
# build if it does.
COPY trust-store/assert-fixed-bundle.sh /tmp/assert-fixed-bundle.sh
RUN apk add --no-cache aws-cli coreutils \
 && apk add --no-cache --upgrade ca-certificates-bundle \
 && sh /tmp/assert-fixed-bundle.sh /etc/ssl/certs/ca-certificates.crt \
 && rm /tmp/assert-fixed-bundle.sh
ENV AWS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt

COPY lib/dump-keys.sh /usr/local/lib/dump-keys.sh
COPY db/restore-on-empty.sh /docker-entrypoint-initdb.d/00-restore-on-empty.sh
RUN chmod 0755 /docker-entrypoint-initdb.d/00-restore-on-empty.sh

# Entrypoint and CMD are the stock image's, untouched.
# POSTGRES_* and the S3_* / DUMP_NAME / HEIGHT_SQL settings come from the Flux
# spec; credentials are never baked into a layer.
