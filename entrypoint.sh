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
CALLBACK_PENDING_FLAG="/etc/appbox_callback_pending"
CALLBACK_HELPER="/usr/local/bin/appbox-installed-callback"
IMMICH_SERVER_SERVICE="/run/service/svc-server"

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

# Send the pending Appbox installed callback once Immich answers. This runs
# in the background. The API accepts one installed callback per install or
# update and rejects the rest (401 once the token has been used or cleared,
# or when serverapi has already called back), so the old `until curl -f` loop
# retried a rejected callback every 5s for the life of the container. The
# helper retries only network errors, 408, 429 and 5xx, logs any other status
# once and stops; the flag is cleared after the attempt.
send_pending_callback() {
    set +e
    if ! wait_for_http "${LOCAL_URL}/api/server/ping" 300 2; then
        echo "WARNING: Immich did not answer; sending the installed callback anyway."
    fi
    "${CALLBACK_HELPER}"
    rm -f "${CALLBACK_PENDING_FLAG}"
}

# Print true or false from Immich's isInitialized flag, which is true once
# an admin account exists. Prints nothing and fails when Immich does not
# answer with a boolean.
server_initialized() {
    curl -sf --max-time 10 "${LOCAL_URL}/api/server/config" 2>/dev/null \
        | jq -er '.isInitialized | if type == "boolean" then . else error end' 2>/dev/null
}

# Create the admin account from EMAIL and PASSWORD. Returns 0 once Immich
# reports an admin account, made now or already there, and 1 otherwise.
# jq builds the request body from the environment, so quotes or backslashes
# in the password stay valid JSON and the password never reaches a command
# line or the log. Only isInitialized decides that an admin exists: a 400
# while it is still false means Immich rejected the account.
create_admin_user() {
    local attempts=60
    local i=0
    local initialized http_code

    while [[ "${i}" -lt "${attempts}" ]]; do
        initialized=$(server_initialized)

        if [[ "${initialized}" == "true" ]]; then
            echo "Immich already has an admin account, skipping admin creation"
            return 0
        fi

        if [[ "${initialized}" == "false" ]]; then
            http_code=$(jq -n '{email: env.EMAIL, name: "Admin", password: env.PASSWORD}' \
                | curl -s -o /dev/null -w "%{http_code}" --max-time 30 \
                    -H "Content-Type: application/json" \
                    -X POST "${LOCAL_URL}/api/auth/admin-sign-up" \
                    --data-binary @-)

            if [[ "$(server_initialized)" == "true" ]]; then
                if [[ "${http_code}" == "201" ]]; then
                    echo "Admin user created successfully"
                else
                    echo "Immich has an admin account (sign-up answered HTTP ${http_code})"
                fi
                return 0
            fi

            if [[ "${http_code}" == "400" ]]; then
                echo "ERROR: Immich rejected the admin account (HTTP 400) and still has no admin"
                return 1
            fi
        fi

        i=$((i + 1))
        sleep 5
    done

    echo "ERROR: Immich still has no admin account after ${attempts} attempts"
    return 1
}

# Stop the Immich web server so its admin sign-up page is not served while
# the instance has no admin. s6 keeps it down until the container restarts.
stop_immich_server() {
    if /command/s6-svc -d "${IMMICH_SERVER_SERVICE}" 2>/dev/null; then
        echo "Stopped the Immich web server until the next restart"
    else
        echo "WARNING: could not stop the Immich web server"
    fi
}

# Finish an install or update in the background: on a volume without
# FRESH_MARKER make sure the admin account exists, then send the pending
# installed callback. Without an admin it fails closed: no marker, no
# callback, and the web server stops. CALLBACK_PENDING_FLAG stays, so a
# restart or re-create tries again.
complete_lifecycle() {
    set +e

    if [[ ! -f "${FRESH_MARKER}" ]]; then
        echo "Fresh install detected, waiting for Immich to start..."
        wait_for_http "${LOCAL_URL}/api/server/ping" 300 2

        if ! create_admin_user; then
            echo "ERROR: admin setup failed; the install is not reported as finished. Restart the app to try again."
            stop_immich_server
            return 1
        fi
        touch "${FRESH_MARKER}"
    else
        echo "Existing data found, skipping admin creation"
    fi

    send_pending_callback
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
# A new container (fresh install or update) marks the installed callback
# pending, then sets CONFIG_FLAG. While the callback is pending, every start
# runs complete_lifecycle in the background: it waits for Immich (started by
# s6-overlay), creates the admin on a fresh volume and sends the callback.
# A restart before that finished, or after admin setup failed, tries again;
# a rejected callback is not repeated.

if [[ ! -f "${CONFIG_FLAG}" ]]; then
    touch "${CALLBACK_PENDING_FLAG}"
    touch "${CONFIG_FLAG}"
fi

if [[ -f "${CALLBACK_PENDING_FLAG}" ]]; then
    complete_lifecycle </dev/null &
fi

# =============================================================================
# STEP 5: Hand off to s6-overlay
# =============================================================================
# /init starts s6-overlay which manages svc-postgres, svc-redis, and the
# Immich server as supervised long-running services.

exec "$@"
