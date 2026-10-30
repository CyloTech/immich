# Stage 1: Extract PostgreSQL vector extensions from the Immich PostgreSQL image.
# These extensions (VectorChord + pgvecto.rs) provide the vector data types and
# indexing that Immich's database schema requires — even without ML enabled.
# Pinned to the digest in upstream docker/docker-compose.yml at v3.3.5 (the same
# image Immich 3.1.0 used, so existing databases need no extension upgrade).
FROM ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23 AS pgext

# Stage 2: Build on the ImageGenius monolithic Immich container.
# This image bundles the Immich server into a single container using the
# LinuxServer.io base (s6-overlay init, PUID/PGID support).
#
# The :noml tag excludes machine learning (facial recognition, CLIP search)
# to reduce memory and CPU requirements for shared hosting.
FROM ghcr.io/imagegenius/immich:3.3.5-noml@sha256:05425278bf487584b4b6c5872625e40af17ca0fa2e328f2a4a01abced20fa33c

# Install PostgreSQL 14, Redis, and required tools.
#
# PostgreSQL 14 matches the version the vectorchord/pgvectors extensions
# were built against. Using a different major version will cause .so load
# failures. If upgrading PostgreSQL, rebuild extensions for that version.
#
# Base image is Ubuntu (Noble). Tested with imagegenius/immich:noml.
RUN curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | \
        gpg --dearmor -o /usr/share/keyrings/postgresql.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt $(. /etc/os-release && echo "$VERSION_CODENAME")-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        postgresql-14 \
        redis-server \
        gosu && \
    rm -rf /var/lib/apt/lists/*

RUN npm install -g bcryptjs

# Copy vector extensions from the Immich PostgreSQL image (stage 1).
# Three extensions: vectors (pgvecto.rs), vchord (VectorChord), vector (pgvector).
# vchord depends on vector; Immich uses vectors for embeddings.
COPY --from=pgext /usr/lib/postgresql/14/lib/vectors.so /usr/lib/postgresql/14/lib/
COPY --from=pgext /usr/lib/postgresql/14/lib/vchord.so /usr/lib/postgresql/14/lib/
COPY --from=pgext /usr/lib/postgresql/14/lib/vector.so /usr/lib/postgresql/14/lib/
COPY --from=pgext /usr/share/postgresql/14/extension/vectors* /usr/share/postgresql/14/extension/
COPY --from=pgext /usr/share/postgresql/14/extension/vchord* /usr/share/postgresql/14/extension/
COPY --from=pgext /usr/share/postgresql/14/extension/vector* /usr/share/postgresql/14/extension/

# ---------------------------------------------------------------------------
# s6-overlay service: svc-postgres (longrun)
# ---------------------------------------------------------------------------
# PostgreSQL runs in the foreground under s6 supervision. If the process
# crashes, s6 restarts it automatically. On container stop, s6 sends SIGTERM
# which triggers a clean PostgreSQL shutdown.
#
# The data directory is initialized by entrypoint.sh BEFORE /init runs, so
# svc-postgres always finds a ready data directory at /config/postgres.
RUN mkdir -p /etc/s6-overlay/s6-rc.d/svc-postgres && \
    echo "longrun" > /etc/s6-overlay/s6-rc.d/svc-postgres/type && \
    touch /etc/s6-overlay/s6-rc.d/user/contents.d/svc-postgres

COPY svc-postgres-run /etc/s6-overlay/s6-rc.d/svc-postgres/run
RUN chmod +x /etc/s6-overlay/s6-rc.d/svc-postgres/run

# ---------------------------------------------------------------------------
# s6-overlay service: svc-redis (longrun)
# ---------------------------------------------------------------------------
# Redis runs in the foreground under s6 supervision with the same lifecycle
# guarantees as PostgreSQL.
RUN mkdir -p /etc/s6-overlay/s6-rc.d/svc-redis && \
    echo "longrun" > /etc/s6-overlay/s6-rc.d/svc-redis/type && \
    touch /etc/s6-overlay/s6-rc.d/user/contents.d/svc-redis

COPY svc-redis-run /etc/s6-overlay/s6-rc.d/svc-redis/run
RUN chmod +x /etc/s6-overlay/s6-rc.d/svc-redis/run

# ---------------------------------------------------------------------------
# Override init-config-immich: skip the expensive recursive chown of
# /app/immich (thousands of immutable image-layer files) that the base
# image runs on every boot. Cuts startup from minutes to seconds.
# ---------------------------------------------------------------------------
COPY init-config-immich /etc/s6-overlay/s6-rc.d/init-config-immich/run
RUN chmod +x /etc/s6-overlay/s6-rc.d/init-config-immich/run

# ---------------------------------------------------------------------------
# s6 dependency fix: services must wait for LSIO init to complete
# ---------------------------------------------------------------------------
# The base image's s6-rc oneshot services (init-adduser, init-config-immich,
# etc.) and its longrun services (svc-microservices, svc-server) have no
# explicit dependency chain between them. s6-rc resolves them in parallel,
# so services can start before init-config-immich has chowned /photos.
#
# init-config-immich is the critical oneshot: it creates /photos subdirs and
# fixes their ownership. legacy-cont-init covers the legacy /etc/cont-init.d/
# scripts. Both must complete before any service starts.
RUN mkdir -p /etc/s6-overlay/s6-rc.d/svc-microservices/dependencies.d && \
    touch /etc/s6-overlay/s6-rc.d/svc-microservices/dependencies.d/legacy-cont-init && \
    touch /etc/s6-overlay/s6-rc.d/svc-microservices/dependencies.d/init-config-immich && \
    mkdir -p /etc/s6-overlay/s6-rc.d/svc-server/dependencies.d && \
    touch /etc/s6-overlay/s6-rc.d/svc-server/dependencies.d/legacy-cont-init && \
    touch /etc/s6-overlay/s6-rc.d/svc-server/dependencies.d/init-config-immich && \
    mkdir -p /etc/s6-overlay/s6-rc.d/svc-postgres/dependencies.d && \
    touch /etc/s6-overlay/s6-rc.d/svc-postgres/dependencies.d/legacy-cont-init && \
    mkdir -p /etc/s6-overlay/s6-rc.d/svc-redis/dependencies.d && \
    touch /etc/s6-overlay/s6-rc.d/svc-redis/dependencies.d/legacy-cont-init

# ---------------------------------------------------------------------------
# Appbox scripts
# ---------------------------------------------------------------------------
ADD entrypoint.sh /entrypoint.sh
ADD moduser.sh /moduser.sh
ADD appbox-installed-callback /usr/local/bin/appbox-installed-callback
RUN chmod +x /entrypoint.sh /moduser.sh && chmod 755 /usr/local/bin/appbox-installed-callback

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/init"]

EXPOSE 8080

# Immich 3.1.0 to 3.3.5 can open database connections before migrations create the
# album-role enum. Postgres.js then has no serializer for that new enum array
# and sends "owner" instead of an array literal. Use its built-in text-array
# serializer and keep PostgreSQL's enum validation for each role.
RUN python3 - <<'PY'
from pathlib import Path
import subprocess
path = Path('/app/immich/server/dist/repositories/album.repository.js')
source = path.read_text()
before = 'unnest(${roles}::album_user_role_enum[])'
after = 'unnest(${roles}::text[])::album_user_role_enum'
if source.count(before) != 1:
    raise SystemExit('Unexpected upstream album query; review the role-array patch')
path.write_text(source.replace(before, after))
subprocess.run(['node', '--check', str(path)], check=True)
PY
