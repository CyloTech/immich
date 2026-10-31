# Stage 1: Extract PostgreSQL vector extensions from the Immich PostgreSQL image.
# These extensions (VectorChord + pgvecto.rs) provide the vector data types and
# indexing that Immich's database schema requires.
# Pinned to the digest in upstream docker/docker-compose.yml at v3.3.5 (the same
# image Immich 3.1.0 used, so existing databases need no extension upgrade).
FROM ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23 AS pgext

# Stage 2: Build on the ImageGenius monolithic Immich container.
# This image bundles the Immich server AND machine learning into a single
# container using the LinuxServer.io base (s6-overlay init, PUID/PGID support).
#
# The :latest tag includes the ML service (facial recognition, CLIP search,
# duplicate detection). ML runs on CPU — no GPU required, though CUDA and
# OpenVINO tags exist for GPU-accelerated variants.
#
# ML downloads models (~1.5 GB) on first use to /config/machine-learning/models.
FROM ghcr.io/imagegenius/immich:3.3.5@sha256:44429b30189301d45d05349fc50b394e90163415c6a2e203f191d16047671374

# Install PostgreSQL 14, Redis, and required tools.
#
# PostgreSQL 14 matches the version the vectorchord/pgvectors extensions
# were built against. Using a different major version will cause .so load
# failures. If upgrading PostgreSQL, rebuild extensions for that version.
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
RUN mkdir -p /etc/s6-overlay/s6-rc.d/svc-postgres && \
    echo "longrun" > /etc/s6-overlay/s6-rc.d/svc-postgres/type && \
    touch /etc/s6-overlay/s6-rc.d/user/contents.d/svc-postgres

COPY svc-postgres-run /etc/s6-overlay/s6-rc.d/svc-postgres/run
RUN chmod +x /etc/s6-overlay/s6-rc.d/svc-postgres/run

# ---------------------------------------------------------------------------
# s6-overlay service: svc-redis (longrun)
# ---------------------------------------------------------------------------
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
# The base image's :latest tag includes svc-machine-learning in addition to
# svc-server and svc-microservices. All must wait for init-config-immich
# (which creates /photos subdirs and fixes ownership) and legacy-cont-init.
RUN mkdir -p /etc/s6-overlay/s6-rc.d/svc-microservices/dependencies.d && \
    touch /etc/s6-overlay/s6-rc.d/svc-microservices/dependencies.d/legacy-cont-init && \
    touch /etc/s6-overlay/s6-rc.d/svc-microservices/dependencies.d/init-config-immich && \
    mkdir -p /etc/s6-overlay/s6-rc.d/svc-server/dependencies.d && \
    touch /etc/s6-overlay/s6-rc.d/svc-server/dependencies.d/legacy-cont-init && \
    touch /etc/s6-overlay/s6-rc.d/svc-server/dependencies.d/init-config-immich && \
    mkdir -p /etc/s6-overlay/s6-rc.d/svc-machine-learning/dependencies.d && \
    touch /etc/s6-overlay/s6-rc.d/svc-machine-learning/dependencies.d/legacy-cont-init && \
    touch /etc/s6-overlay/s6-rc.d/svc-machine-learning/dependencies.d/init-config-immich && \
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
# entrypoint.sh builds the admin sign-up request with jq, which the base
# image provides; fail the build if it stops doing so.
RUN chmod +x /entrypoint.sh /moduser.sh && chmod 755 /usr/local/bin/appbox-installed-callback && \
    jq --version

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
