#!/bin/bash
# =============================================================================
# moduser.sh — Change the Admin User's Password
# =============================================================================
#
# Usage: /moduser.sh <new_password>
#
# Updates the password for the first admin user in the Immich database.
# Uses bcryptjs (installed globally via npm) to hash the password and
# writes directly to the PostgreSQL "user" table (Immich v2.x schema).
#
# Table: "user" (reserved word — requires quoting)
# Column: "isAdmin" (boolean, camelCase — Immich uses Kysely migrations)
# =============================================================================

NEW_PASSWORD="$1"
PG_BIN="/usr/lib/postgresql/14/bin"

if [[ -z "${NEW_PASSWORD}" ]]; then
    echo "Usage: /moduser.sh <new_password>"
    exit 1
fi

HASH=$(NODE_PATH=/usr/lib/node_modules node -e "
const bcrypt = require('bcryptjs');
const hash = bcrypt.hashSync(process.argv[1], 10);
process.stdout.write(hash);
" "${NEW_PASSWORD}")

if [[ -z "${HASH}" ]]; then
    echo "Failed to generate password hash"
    exit 1
fi

gosu 1000:1000 "${PG_BIN}/psql" -h localhost -U postgres -d immich -c \
    "UPDATE \"user\" SET password = '${HASH}' WHERE \"isAdmin\" = true;"

if [[ $? -eq 0 ]]; then
    echo "Password updated successfully"
else
    echo "Failed to update password"
    exit 1
fi
