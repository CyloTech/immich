# Testing Framework — Immich Appbox App

Complete all applicable tests before submitting.

---

## Prerequisites

- Docker installed and running
- All files in the repo: `Dockerfile`, `entrypoint.sh`, `moduser.sh`, `appbox.yml`, `icon.png`,
  `svc-postgres-run`, `svc-redis-run`

---

## 1. Build

```bash
docker build -t immich-appbox .
```

**Checklist:**

- [x] Build completes without errors
- [x] PostgreSQL 14 installs from the pgdg repo
- [x] Vector extensions (`vectors.so`, `vchord.so`, `vector.so`) copy from the Immich PostgreSQL image
- [x] `bash`, `curl`, `gosu`, `redis-server` are available in the final image
- [x] `bcryptjs` is installed globally via npm
- [x] `entrypoint.sh` and `moduser.sh` are executable
- [x] s6-overlay service definitions exist: `svc-postgres`, `svc-redis`
- [x] Service `run` scripts are executable

---

## 2. Fresh Install

```bash
docker volume create immich-config
docker volume create immich-photos

docker run -d --name immich-test \
  -e EMAIL=admin@example.com \
  -e PASSWORD='TestPass123!' \
  -e INSTANCE_ID=test-fresh \
  -e SKIP_APPBOX_CALLBACK=1 \
  -e DB_HOSTNAME=localhost \
  -e DB_PORT=5432 \
  -e DB_USERNAME=postgres \
  -e DB_PASSWORD=postgres \
  -e DB_DATABASE_NAME=immich \
  -e REDIS_HOSTNAME=localhost \
  -e REDIS_PORT=6379 \
  -e PUID=1000 \
  -e PGID=1000 \
  -v immich-config:/config \
  -v immich-photos:/photos \
  -p 8080:8080 \
  immich-appbox
```

**Checklist:**

- [x] Entrypoint creates passwd/group entries for UID/GID 1000
- [x] Entrypoint creates `/var/run/postgresql` with correct ownership
- [x] Entrypoint initializes PostgreSQL data directory at `/config/postgres` (chmod 700)
- [x] Entrypoint starts PostgreSQL temporarily for DB creation, then stops it
- [x] `immich` database is created with `vectors` and `vchord` (+ dependency `vector`) extensions
- [x] `/etc/app_configured` is created
- [x] Entrypoint execs `/init` (s6-overlay takes over)
- [x] s6-overlay starts `svc-postgres` — PostgreSQL running in foreground
- [x] s6-overlay starts `svc-redis` — Redis running in foreground
- [x] s6-overlay starts the Immich server
- [x] Immich responds at `http://localhost:8080` (`curl -sf localhost:8080/api/server/ping`)
- [x] Background setup detects fresh install, creates admin via API (body built with jq, so a
      password containing `"` or `\` works; `tests/test-admin-setup.sh` and the release gates)
- [x] Admin creation that Immich rejects fails closed: no marker, no installed callback, the
      web server is stopped and the next start retries (release gate `rejected` phase)
- [x] `/config/.immich_configured` marker file is created
- [x] API callback is attempted (skipped locally via SKIP_APPBOX_CALLBACK)
- [x] You can log in at `http://localhost:8080` with the provided email/password
- [ ] Photo upload works through the web interface *(not tested — requires manual browser test)*

---

## 3. Restart

```bash
docker restart immich-test
```

**Checklist:**

- [x] Container restarts without errors
- [x] Entrypoint skips initdb (data directory exists)
- [x] Entrypoint skips DB creation (database exists) — temporary PG start/stop is fast
- [x] Entrypoint skips the Appbox setup block (`/etc/app_configured` exists from container layer)
- [x] s6-overlay starts `svc-postgres`, `svc-redis`, and Immich
- [x] No admin user creation attempted
- [x] No API callback attempted
- [x] Immich is accessible and previous data intact
- [x] Login works with original credentials

---

## 4. Upgrade

```bash
docker stop immich-test && docker rm immich-test

docker build -t immich-appbox .

docker run -d --name immich-test \
  -e EMAIL=admin@example.com \
  -e PASSWORD='TestPass123!' \
  -e INSTANCE_ID=test-upgrade \
  -e SKIP_APPBOX_CALLBACK=1 \
  -e DB_HOSTNAME=localhost \
  -e DB_PORT=5432 \
  -e DB_USERNAME=postgres \
  -e DB_PASSWORD=postgres \
  -e DB_DATABASE_NAME=immich \
  -e REDIS_HOSTNAME=localhost \
  -e REDIS_PORT=6379 \
  -e PUID=1000 \
  -e PGID=1000 \
  -v immich-config:/config \
  -v immich-photos:/photos \
  -p 8080:8080 \
  immich-appbox
```

**Checklist:**

- [x] `/etc/app_configured` does not exist (new container image)
- [x] `/config/.immich_configured` exists (previous install marker)
- [x] Entrypoint skips initdb (data directory exists) and createdb (database exists)
- [x] Entrypoint enters the Appbox lifecycle block, spawns background setup
- [x] Background setup detects UPGRADE path, skips admin creation
- [x] s6-overlay starts `svc-postgres`, `svc-redis`, and Immich
- [x] Immich runs database migrations automatically
- [x] API callback is attempted (skipped locally)
- [x] All previous data is preserved (accounts, password changes)
- [x] Login works with original credentials

---

## 5. Process and UID Verification

```bash
docker exec immich-test ps aux
```

**Checklist:**

- [x] Immich server runs as UID 1000 (`abc` user)
- [x] PostgreSQL runs as UID 1000 (supervised by s6)
- [x] Redis runs as UID 1000 (supervised by s6)

```bash
docker exec immich-test ls -ln /config/
docker exec immich-test ls -ln /config/postgres/
docker exec immich-test ls -ln /photos/
```

- [x] All data files and directories owned by 1000:1000

---

## 6. Service Supervision (s6-overlay)

Verify that s6 restarts crashed services.

```bash
# Kill PostgreSQL with SIGKILL (simulates crash) — s6 should restart it
PG_PID=$(docker exec immich-test head -1 /config/postgres/postmaster.pid)
docker exec immich-test kill -9 "$PG_PID"
sleep 15
docker exec immich-test gosu 1000:1000 /usr/lib/postgresql/14/bin/psql -h localhost -U postgres -c "SELECT 1;"

# Kill Redis — s6 should restart it
docker exec immich-test kill -9 $(docker exec immich-test pgrep redis-server)
sleep 5
docker exec immich-test redis-cli ping
```

**Checklist:**

- [x] PostgreSQL is restarted by s6 after being killed (stale shared memory is cleaned up)
- [x] Redis is restarted by s6 after being killed
- [x] Immich reconnects to PostgreSQL and Redis after service restart
- [x] No data loss from the transient service restart

---

## 7. Signal Handling

```bash
time docker stop immich-test
```

**Checklist:**

- [x] Container stops within ~10 seconds (measured 10.2s — at Docker's default grace period)
- [x] s6-overlay sends SIGTERM to PostgreSQL, Redis, and Immich
- [x] No data corruption after stop
- [x] PostgreSQL shuts down cleanly (`received fast shutdown request` → `database system is shut down`)

---

## 8. Password Change Script (moduser.sh)

```bash
docker exec immich-test /moduser.sh "NewPassword456!"
echo $?
```

**Checklist:**

- [x] Script exits with code 0
- [x] Login with old password fails (HTTP 401)
- [x] Login with new password succeeds (HTTP 201)

```bash
docker exec immich-test /moduser.sh
```

- [x] Prints usage and exits non-zero

---

## 9. Persistence Verification

1. Upload a photo through the web interface
2. Create a second user account
3. Stop and remove the container
4. Start a new container with the same volumes
5. Verify:

- [ ] Uploaded photo is still visible *(not tested — requires manual browser test)*
- [ ] Second user account still exists *(not tested — requires manual browser test)*
- [x] Admin account and credentials work (verified across container replacement in upgrade test)
- [x] App settings persist

---

## 10. Security

- [x] Admin password uses `complexPassword` type with validation
- [x] Admin setup never puts the password on a command line or in the container log
- [x] No hardcoded credentials in the image
- [x] PostgreSQL only listens on localhost (not 0.0.0.0)
- [x] Redis only binds to 127.0.0.1
- [x] No unnecessary ports exposed
- [x] `entrypoint.sh` does not download external scripts at runtime

---

## 11. appbox.yml Validation

- [x] `app.display_name` and `app.publisher` are set
- [x] `app.description` and `app.short_description` are meaningful
- [ ] `app.icon` points to a valid 512x512 PNG *(icon.png not yet created)*
- [x] `app.categories` uses existing categories
- [x] `image.name` and `image.version` are set
- [x] `volumes` covers `/config` and `/photos`
- [x] All volume `uid` fields are `1000`
- [x] `VIRTUAL_PORT` is set to `8080`
- [x] `DB_PASSWORD` is set to a non-empty value (LSIO init requires it)
- [x] `behavior.expect_callback` is `true`
- [x] `custom_fields` have appropriate validation rules

---

## Cleanup

```bash
docker stop immich-test 2>/dev/null; docker rm immich-test 2>/dev/null
docker volume rm immich-config immich-photos
```
