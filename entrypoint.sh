#!/bin/bash
set -e

# =============================================================================
# Constants
# =============================================================================

CONFIG_FLAG="/etc/app_configured"
PG_DATA="/config/postgres"
PG_BIN="/usr/lib/postgresql/14/bin"
PG_PRELOAD_LIBRARIES="vectors.so,vchord.so"
REDIS_DIR="/config/redis"
FRESH_MARKER="/config/.immich_configured"
LOCAL_URL="http://localhost:8080"
APP_USER="1000:1000"

# =============================================================================
# Bootstrap: ensure UID/GID 1000 exist in the passwd/group databases.
# =============================================================================
# The entrypoint runs BEFORE LSIO's /init, which normally creates the "abc"
# user with PUID/PGID. PostgreSQL's initdb calls getpwuid() and will fail if
# the effective user has no passwd entry.

if ! getent passwd 1000 >/dev/null 2>&1; then
    echo "appuser:x:1000:1000::/config:/usr/sbin/nologin" >> /etc/passwd
fi
if ! getent group 1000 >/dev/null 2>&1; then
    echo "appuser:x:1000:" >> /etc/group
fi

# =============================================================================
# Helper Functions
# =============================================================================

wait_for_http() {
    local url="$1"
    local attempts="${2:-60}"
    local sleep_seconds="${3:-2}"
    local i=0

    until curl -sf "${url}" >/dev/null 2>&1; do
        i=$((i + 1))
        if [[ "${i}" -ge "${attempts}" ]]; then
            echo "Timed out waiting for ${url}"
            return 1
        fi
        sleep "${sleep_seconds}"
    done
}

callback_installed() {
    if [[ "${SKIP_APPBOX_CALLBACK:-0}" == "1" ]]; then
        echo "Skipping Appbox callback (SKIP_APPBOX_CALLBACK=1)"
        return 0
    fi

    local callback_url="https://api.cylo.net/v1/apps/installed/${INSTANCE_ID}"
    local headers=(
        -H "Accept: application/json"
        -H "Content-Type:application/json"
    )

    if [[ -n "${CALLBACK_TOKEN:-}" ]]; then
        headers+=(-H "Authorization: Bearer ${CALLBACK_TOKEN}")
    fi

    until curl -fsS -o /dev/null "${headers[@]}" -X POST "${callback_url}"; do
        sleep 5
    done
}

create_admin_user() {
    local attempts=30
    local i=0

    while [[ "${i}" -lt "${attempts}" ]]; do
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            -H "Content-Type: application/json" \
            -X POST "${LOCAL_URL}/api/auth/admin-sign-up" \
            --data "{\"email\":\"${EMAIL}\",\"name\":\"Admin\",\"password\":\"${PASSWORD}\"}")

        if [[ "${http_code}" == "201" ]]; then
            echo "Admin user created successfully"
            return 0
        elif [[ "${http_code}" == "400" ]]; then
            echo "Admin user already exists (HTTP 400), skipping"
            return 0
        fi

        i=$((i + 1))
        sleep 2
    done

    echo "WARNING: Admin user creation failed after ${attempts} attempts"
    return 1
}

ensure_postgres_config() {
    local conf="${PG_DATA}/postgresql.conf"

    sed -i '/^# BEGIN appbox immich postgres$/,/^# END appbox immich postgres$/d' "${conf}"
    cat >> "${conf}" <<PGCONF

# BEGIN appbox immich postgres
listen_addresses = 'localhost'
shared_preload_libraries = '${PG_PRELOAD_LIBRARIES}'
# END appbox immich postgres
PGCONF
    chown 1000:1000 "${conf}"
}

start_postgres_for_bootstrap() {
    echo "Starting PostgreSQL for bootstrap; waiting indefinitely for readiness..."

    gosu ${APP_USER} "${PG_BIN}/pg_ctl" -D "${PG_DATA}" \
        -o "-c shared_preload_libraries=${PG_PRELOAD_LIBRARIES}" \
        -l "${PG_DATA}/postgresql.log" -W start

    local missing_pid_checks=0

    while ! gosu ${APP_USER} "${PG_BIN}/pg_isready" -h localhost -U postgres >/dev/null 2>&1; do
        if [[ -f "${PG_DATA}/postmaster.pid" ]]; then
            missing_pid_checks=0
            local pid
            pid=$(head -1 "${PG_DATA}/postmaster.pid")

            if [[ -n "${pid}" ]] && ! kill -0 "${pid}" 2>/dev/null; then
                echo "PostgreSQL exited before it became ready. Recent log output:"
                tail -50 "${PG_DATA}/postgresql.log" || true
                return 1
            fi
        else
            missing_pid_checks=$((missing_pid_checks + 1))
            if [[ "${missing_pid_checks}" -ge 15 ]]; then
                echo "PostgreSQL did not create a postmaster.pid file. Recent log output:"
                tail -50 "${PG_DATA}/postgresql.log" || true
                return 1
            fi
        fi

        sleep 2
    done

    echo "PostgreSQL is ready."
}

# =============================================================================
# STEP 1: PostgreSQL data directory initialization
# =============================================================================
# Runs BEFORE s6-overlay starts. When /init launches, svc-postgres will expect
# the data directory to exist.

mkdir -p /var/run/postgresql
chown 1000:1000 /var/run/postgresql

if [[ ! -d "${PG_DATA}/base" ]]; then
    echo "Initializing PostgreSQL data directory..."
    mkdir -p "${PG_DATA}"
    chown -R 1000:1000 "${PG_DATA}"
    chmod 700 "${PG_DATA}"

    gosu ${APP_USER} "${PG_BIN}/initdb" \
        -D "${PG_DATA}" \
        -U postgres \
        --auth-local=trust \
        --auth-host=trust
fi

# Keep required preload settings in place even when reusing an existing volume
# from a failed or older install.
ensure_postgres_config

# =============================================================================
# STEP 2: Database and extension creation
# =============================================================================
# Start PostgreSQL temporarily to create the immich database and enable the
# vector extensions. This is idempotent — skipped if the database exists.
# PostgreSQL is stopped afterward; svc-postgres takes over under s6-overlay.

chmod 700 "${PG_DATA}"

if [[ -f "${PG_DATA}/postmaster.pid" ]]; then
    OLD_PID=$(head -1 "${PG_DATA}/postmaster.pid")
    if ! kill -0 "${OLD_PID}" 2>/dev/null; then
        echo "Cleaning up stale PostgreSQL PID file (PID ${OLD_PID})"
        pkill -9 -u 1000 postgres 2>/dev/null || true
        sleep 1
        rm -f "${PG_DATA}/postmaster.pid"
    fi
fi

start_postgres_for_bootstrap

if ! gosu ${APP_USER} "${PG_BIN}/psql" -h localhost -U postgres -lqt \
        | cut -d \| -f 1 | grep -qw immich; then
    echo "Creating immich database..."
    gosu ${APP_USER} "${PG_BIN}/createdb" -h localhost -U postgres immich
fi

echo "Ensuring Immich PostgreSQL extensions are available..."
gosu ${APP_USER} "${PG_BIN}/psql" -h localhost -U postgres -d immich \
    -c "CREATE EXTENSION IF NOT EXISTS vectors;"
gosu ${APP_USER} "${PG_BIN}/psql" -h localhost -U postgres -d immich \
    -c "CREATE EXTENSION IF NOT EXISTS vchord CASCADE;"

gosu ${APP_USER} "${PG_BIN}/pg_ctl" -D "${PG_DATA}" -w stop

# =============================================================================
# STEP 3: Redis data directory
# =============================================================================

mkdir -p "${REDIS_DIR}"
chown -R 1000:1000 "${REDIS_DIR}"

# =============================================================================
# STEP 4: Appbox lifecycle (first boot / upgrade detection)
# =============================================================================
# Spawns a background process that waits for Immich to come up (started by
# s6-overlay), then handles admin creation and the platform callback.

if [[ ! -f "${CONFIG_FLAG}" ]]; then
    touch "${CONFIG_FLAG}"

    (
        set +e

        if [[ ! -f "${FRESH_MARKER}" ]]; then
            echo "Fresh install detected, waiting for Immich to start..."
            wait_for_http "${LOCAL_URL}/api/server/ping" 300 2

            if create_admin_user; then
                touch "${FRESH_MARKER}"
            fi
        else
            echo "Upgrade detected: existing data found, skipping admin creation"
            wait_for_http "${LOCAL_URL}/api/server/ping" 300 2
        fi

        callback_installed
    ) &
fi

# =============================================================================
# STEP 5: Hand off to s6-overlay
# =============================================================================
# /init starts s6-overlay which manages svc-postgres, svc-redis, and the
# Immich server as supervised long-running services.

exec "$@"
