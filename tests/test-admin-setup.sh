#!/usr/bin/env bash
# Tests for first-boot admin creation in entrypoint.sh, run against a mock
# Immich API and mock Appbox API (needs bash, curl, jq and python3; no
# Docker):
#   - create_admin_user builds the admin-sign-up body with jq, so a password
#     with quotes, backslashes and shell syntax arrives intact, and never logs
#     the password;
#   - only isInitialized means "the admin exists": a 400 while it is still
#     false fails, a 400 after someone else created the admin succeeds, an
#     admin that already exists is not signed up again, and 5xx/no answer is
#     retried;
#   - complete_lifecycle fails closed when admin creation fails: no
#     FRESH_MARKER, no installed callback, the pending flag stays for the next
#     start and the web server is stopped; on success it sets the marker and
#     sends one callback; on existing data it skips admin creation.
#
# Usage: tests/test-admin-setup.sh
# Inside an image, test its own files instead of the repository's:
#   docker run -i --rm --entrypoint bash \
#     -e ENTRYPOINT_UNDER_TEST=/entrypoint.sh \
#     -e HELPER_UNDER_TEST=/usr/local/bin/appbox-installed-callback \
#     IMAGE -s < tests/test-admin-setup.sh
set -u

if [[ -z "${ENTRYPOINT_UNDER_TEST:-}" || -z "${HELPER_UNDER_TEST:-}" ]]; then
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
entrypoint="${ENTRYPOINT_UNDER_TEST:-${repo_root:-}/entrypoint.sh}"
helper="${HELPER_UNDER_TEST:-${repo_root:-}/appbox-installed-callback}"
email='admin@example.test'
# Everything the old string-built JSON body broke on, plus shell syntax.
password='Pa"ss\word'"'"'$(id)`x` é\n!1'

# Mock Immich and Appbox APIs on one port. Modes:
#   ok           sign-up creates the admin when given a valid JSON body
#   initialized  the admin already exists
#   reject       sign-up answers 400 and no admin is created
#   race         sign-up answers 400 because someone else created the admin
#   flaky        the first two sign-ups answer 502, then as ok
#   down         /api/server/config answers 503
# Each sign-up and installed callback is logged as a JSON line.
mock_server='
import http.server, json, sys
port, mode, log = int(sys.argv[1]), sys.argv[2], sys.argv[3]
state = {"initialized": mode == "initialized", "signups": 0}
def record(entry):
    with open(log, "a") as f:
        f.write(json.dumps(entry) + "\n")
class Handler(http.server.BaseHTTPRequestHandler):
    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def do_GET(self):
        if self.path == "/api/server/ping":
            return self.reply(200, {"res": "pong"})
        if self.path == "/api/server/config":
            if mode == "down":
                return self.reply(503, {})
            return self.reply(200, {"isInitialized": state["initialized"], "loginPageMessage": ""})
        self.reply(404, {})
    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        if self.path == "/api/auth/admin-sign-up":
            state["signups"] += 1
            entry = {"kind": "signup", "content_type": self.headers.get("Content-Type", "")}
            try:
                body = json.loads(raw)
                entry["body"] = body
            except ValueError:
                body = None
            record(entry)
            if mode == "flaky" and state["signups"] <= 2:
                return self.reply(502, {})
            if mode == "reject":
                return self.reply(400, {"message": ["rejected"]})
            if mode == "race":
                state["initialized"] = True
                return self.reply(400, {"message": "The server already has an admin"})
            if state["initialized"]:
                return self.reply(400, {"message": "The server already has an admin"})
            if not isinstance(body, dict) or not isinstance(body.get("email"), str) \
                    or not isinstance(body.get("password"), str) or not body["password"]:
                return self.reply(400, {"message": ["invalid body"]})
            state["initialized"] = True
            return self.reply(201, {"id": "admin", "email": body["email"]})
        if self.path.startswith("/v1/apps/installed/"):
            record({"kind": "callback", "path": self.path})
            return self.reply(200, {})
        self.reply(404, {})
    def log_message(self, *args):
        pass
http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
'

failures=0
work=""
server=""

pass() { echo "ok   $*"; }
fail() {
    echo "FAIL $*"
    [[ -f "${work}/output" ]] && sed 's/^/     /' "${work}/output"
    failures=$((failures + 1))
}

start_mock() {
    work="$(mktemp -d)"
    port=$((20000 + RANDOM % 20000))
    python3 -c "${mock_server}" "${port}" "$1" "${work}/requests" &
    server=$!
    for _ in $(seq 1 50); do
        curl -s -o /dev/null "http://127.0.0.1:${port}/api/server/ping" && return 0
        sleep 0.1
    done
    echo "mock API did not start" >&2
    exit 2
}

stop_mock() {
    kill "${server}" 2>/dev/null
    wait "${server}" 2>/dev/null
    rm -rf "${work}"
}

count() { cat "${work}/requests" 2>/dev/null | grep -c "\"kind\": \"$1\""; }
password_logged() { grep -cF "${password}" "${work}/output"; }

# Write a script holding the entrypoint's real admin and lifecycle functions,
# pointed at the mock and the scratch directory, with sleep shortened and
# stop_immich_server recording the call instead of using s6, then run $1.
run_function() {
    local sandbox="${work}/sandbox.sh"
    {
        echo '#!/bin/bash'
        echo "LOCAL_URL=http://127.0.0.1:${port}"
        echo "FRESH_MARKER=${work}/immich_configured"
        echo "CALLBACK_PENDING_FLAG=${work}/callback_pending"
        echo "CALLBACK_HELPER=${helper}"
        echo 'sleep() { command sleep 0.05; }'
        for function in wait_for_http send_pending_callback server_initialized \
            create_admin_user complete_lifecycle; do
            sed -n "/^${function}() {\$/,/^}\$/p" "${entrypoint}"
        done
        echo "stop_immich_server() { touch '${work}/server_stopped'; echo 'web server stopped'; }"
        echo "$1"
    } >"${sandbox}"
    timeout 120 env EMAIL="${email}" PASSWORD="${password}" \
        INSTANCE_ID=4242 CALLBACK_TOKEN=callbacktoken0123456789 \
        APPBOX_CALLBACK_BASE="http://127.0.0.1:${port}" APPBOX_CALLBACK_RETRY_DELAY=1 \
        bash "${sandbox}" >"${work}/output" 2>&1
}

# --- create_admin_user ----------------------------------------------------------

#   admin_case <mode> <want_exit> <want_signups> <log line regex>
admin_case() {
    local mode=$1 want_exit=$2 want_signups=$3 want_line=$4
    start_mock "${mode}"
    run_function create_admin_user
    local rc=$? signups leaked
    signups=$(count signup)
    leaked=$(password_logged)
    if [[ "${rc}" == "${want_exit}" && "${signups}" == "${want_signups}" && "${leaked}" == 0 ]] \
        && grep -qE "${want_line}" "${work}/output"; then
        pass "create_admin_user ${mode}: exit=${rc} sign-ups=${signups}"
    else
        fail "create_admin_user ${mode}: exit=${rc}/${want_exit} sign-ups=${signups}/${want_signups} password_logged=${leaked}"
    fi
    if [[ "${mode}" == ok ]]; then
        if python3 - "${work}/requests" "${email}" "${password}" <<'PY'
import json, sys
signup = json.loads(open(sys.argv[1]).readline())
assert signup["content_type"] == "application/json", signup["content_type"]
assert signup["body"] == {"email": sys.argv[2], "name": "Admin", "password": sys.argv[3]}, "body differs"
PY
        then
            pass "create_admin_user sends the password with quotes, backslashes and shell syntax intact"
        else
            fail "create_admin_user sign-up body"
        fi
    fi
    stop_mock
}

admin_case ok 0 1 '^Admin user created successfully$'
admin_case initialized 0 0 '^Immich already has an admin account'
admin_case reject 1 1 '^ERROR: Immich rejected the admin account \(HTTP 400\)'
admin_case race 0 1 '^Immich has an admin account \(sign-up answered HTTP 400\)$'
admin_case flaky 0 3 '^Admin user created successfully$'
admin_case down 1 0 '^ERROR: Immich still has no admin account after 60 attempts$'

# --- complete_lifecycle ---------------------------------------------------------

#   lifecycle_case <label> <mode> <fresh|existing> <want_exit> <want_signups> <want_callbacks>
lifecycle_case() {
    local label=$1 mode=$2 data=$3 want_exit=$4 want_signups=$5 want_callbacks=$6
    start_mock "${mode}"
    touch "${work}/callback_pending"
    [[ "${data}" == existing ]] && touch "${work}/immich_configured"
    run_function complete_lifecycle
    local rc=$? signups callbacks leaked marker pending stopped
    signups=$(count signup)
    callbacks=$(count callback)
    leaked=$(password_logged)
    marker=$([[ -f "${work}/immich_configured" ]] && echo yes || echo no)
    pending=$([[ -f "${work}/callback_pending" ]] && echo yes || echo no)
    stopped=$([[ -f "${work}/server_stopped" ]] && echo yes || echo no)
    local want_marker=yes want_pending=no want_stopped=no
    if [[ "${want_exit}" != 0 ]]; then
        want_marker=no want_pending=yes want_stopped=yes
    fi
    if [[ "${rc}" == "${want_exit}" && "${signups}" == "${want_signups}" \
        && "${callbacks}" == "${want_callbacks}" && "${leaked}" == 0 \
        && "${marker}" == "${want_marker}" && "${pending}" == "${want_pending}" \
        && "${stopped}" == "${want_stopped}" ]]; then
        pass "complete_lifecycle ${label}: exit=${rc} marker=${marker} pending=${pending} callbacks=${callbacks} server_stopped=${stopped}"
    else
        fail "complete_lifecycle ${label}: exit=${rc}/${want_exit} sign-ups=${signups}/${want_signups} callbacks=${callbacks}/${want_callbacks} marker=${marker}/${want_marker} pending=${pending}/${want_pending} server_stopped=${stopped}/${want_stopped} password_logged=${leaked}"
    fi
    stop_mock
}

lifecycle_case "fresh install" ok fresh 0 1 1
lifecycle_case "fresh install, admin rejected" reject fresh 1 1 0
lifecycle_case "fresh install, Immich never answers" down fresh 1 0 0
lifecycle_case "volume already has an admin" initialized fresh 0 0 1
lifecycle_case "existing data" reject existing 0 0 1

exit "${failures}"
