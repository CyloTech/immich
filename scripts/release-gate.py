#!/usr/bin/env python3
"""Disposable builder tests for the exact Immich release image."""
import atexit
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.request

EXPECTED = 'repo.cylo.net/immich:3.3.5'
PREVIOUS = 'repo.cylo.net/immich:3.1.0-1'
NEW_VERSION, OLD_VERSION = '3.3.5', '3.1.0'
RUN = 'immich-standard-release-' + secrets.token_hex(6)
LABEL = 'appbox.release-gate=' + RUN
PASSWORD = secrets.token_urlsafe(24) + '!aA1'
EMAIL = 'release-gate@example.invalid'
PHOTO = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAI0lEQVR4nGO0qdjCQApgIkk1w6gG4gATkergYFQDMYDkUAIAf4QBiHBubAwAAAAASUVORK5CYII=')
CALLBACK_PORT = '18080'
CALLBACK_TOKEN = secrets.token_hex(20)
CALLBACK_INSTANCE = 'gate' + secrets.token_hex(4)
# Mock Appbox API inside the candidate container: logs each installed
# callback's path and X-Cylo-Callback-Token, answers 200.
CALLBACK_MOCK = r'''
import http.server, json, sys
log = sys.argv[2]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get('Content-Length') or 0)
        if length:
            self.rfile.read(length)
        with open(log, 'a') as f:
            f.write(json.dumps({'path': self.path, 'token': self.headers.get('X-Cylo-Callback-Token', '')}) + '\n')
        self.send_response(200)
        self.end_headers()
    def log_message(self, *args):
        pass
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), Handler).serve_forever()
'''
# docker stop/restart wait up to 30 s for a clean shutdown; the extra time
# covers a slow builder disk, where the kill and unmount can take minutes.
STOP_TIMEOUT = 300
containers, volumes = [], []


def command(args, data=None, timeout=120, env=None):
    p = subprocess.run(args, input=data, capture_output=True, text=True, timeout=timeout, env=env)
    if p.returncode:
        raise RuntimeError('Command failed: ' + ' '.join(args[:3]) + ' exit=' + str(p.returncode))
    return p.stdout.strip()


def cleanup():
    for name in reversed(containers):
        p = subprocess.run(['docker', 'inspect', '--format', '{{index .Config.Labels "appbox.release-gate"}}', name], capture_output=True, text=True)
        if p.returncode == 0 and p.stdout.strip() == RUN:
            subprocess.run(['docker', 'rm', '-fv', name], capture_output=True)
    for name in volumes:
        p = subprocess.run(['docker', 'volume', 'inspect', '--format', '{{index .Labels "appbox.release-gate"}}', name], capture_output=True, text=True)
        if p.returncode == 0 and p.stdout.strip() == RUN:
            subprocess.run(['docker', 'volume', 'rm', name], capture_output=True)


def failure_diagnostics():
    for name in containers:
        p = subprocess.run(['docker', 'logs', '--tail', '100', name], capture_output=True, text=True)
        lines = []
        for line in (p.stdout + p.stderr).splitlines():
            if not re.search(r'error|fatal|warn|migration|permission|ready|started', line, re.I):
                continue
            if re.search(r'password|token|cookie|authorization|@|https?://', line, re.I):
                continue
            line = re.sub(r'[A-Za-z0-9_+/=-]{40,}', '[REDACTED]', line)
            lines.append(line[:400])
        if lines:
            print(name + ' filtered diagnostics:\n' + '\n'.join(lines[-20:]), file=sys.stderr)


atexit.register(cleanup)


def request(base, path, method='GET', payload=None, token=None, raw=False, content_type=None):
    headers = {}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    if isinstance(payload, dict):
        payload = json.dumps(payload).encode()
        headers['Content-Type'] = 'application/json'
    if content_type:
        headers['Content-Type'] = content_type
    req = urllib.request.Request(base + path, data=payload, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            body = response.read()
            return body if raw else json.loads(body or b'null')
    except urllib.error.HTTPError as error:
        raise RuntimeError('HTTP ' + str(error.code) + ' on ' + method + ' ' + path) from None


def wait_ready(name, version):
    base = 'http://127.0.0.1:' + command(['docker', 'port', name, '8080/tcp']).rsplit(':', 1)[1]
    deadline = time.monotonic() + 600
    while time.monotonic() < deadline:
        state = command(['docker', 'inspect', '--format', '{{.State.Status}}', name])
        if state != 'running':
            raise RuntimeError(name + ' state=' + state)
        try:
            info = request(base, '/api/server/version')
            if '.'.join(str(info[k]) for k in ('major', 'minor', 'patch')) != version:
                raise RuntimeError('Unexpected application version')
            token = login(base)
            if command(['docker', 'exec', name, 'test', '-f', '/config/.immich_configured']) == '':
                return base, token
        except (RuntimeError, OSError, json.JSONDecodeError):
            pass
        time.sleep(3)
    raise RuntimeError(name + ' failed readiness/login within 600 seconds')


def login(base, password=PASSWORD):
    return request(base, '/api/auth/login', 'POST', {'email': EMAIL, 'password': password})['accessToken']


def storage(phase):
    result = []
    for target in ('config', 'photos'):
        name = RUN + '-' + phase + '-' + target
        command(['docker', 'volume', 'create', '--label', LABEL, name])
        volumes.append(name)
        result.append((name, '/' + target))
    return result


def start_callback_mock(name, log):
    command(['docker', 'exec', '-d', '-u', '1000:1000', name, 'python3', '-c', CALLBACK_MOCK, CALLBACK_PORT, log])


def callbacks(name, log):
    p = subprocess.run(['docker', 'exec', name, 'cat', log], capture_output=True, text=True)
    return [json.loads(line) for line in p.stdout.splitlines()] if p.returncode == 0 else []


def expect_callbacks(name, log, count, settle=20):
    # The candidate sends the installed callback in the background once Immich
    # answers; wait for it, then make sure no further callback follows.
    deadline = time.monotonic() + 180
    while count and len(callbacks(name, log)) < count and time.monotonic() < deadline:
        time.sleep(3)
    time.sleep(settle)
    seen = callbacks(name, log)
    if len(seen) != count:
        raise RuntimeError('Expected ' + str(count) + ' installed callback(s), saw ' + str(len(seen)))
    for entry in seen:
        if entry['path'] != '/v1/apps/installed/' + CALLBACK_INSTANCE or entry['token'] != CALLBACK_TOKEN:
            raise RuntimeError('Installed callback had the wrong path or token')


def secrets_absent_from_log(name):
    p = subprocess.run(['docker', 'logs', name], capture_output=True, text=True)
    output = p.stdout + p.stderr
    if PASSWORD in output or CALLBACK_TOKEN in output:
        raise RuntimeError('A credential appeared in the container log')


def start(phase, image, mounts, version, callback_log=None):
    # Candidate phases send the installed callback to a mock API inside the
    # container. Old published images post to the live API in a retry loop, so
    # their callback stays disabled.
    name = RUN + '-' + phase
    containers.append(name)
    args = ['docker', 'run', '-d', '--platform', 'linux/amd64', '--name', name, '--label', LABEL,
            '--memory', '2g', '-p', '127.0.0.1::8080', '-e', 'PASSWORD', '-e', 'EMAIL=' + EMAIL,
            '-e', 'DB_HOSTNAME=localhost', '-e', 'DB_PORT=5432', '-e', 'DB_USERNAME=postgres',
            '-e', 'DB_PASSWORD=postgres', '-e', 'DB_DATABASE_NAME=immich',
            '-e', 'REDIS_HOSTNAME=localhost', '-e', 'REDIS_PORT=6379',
            '-e', 'PUID=1000', '-e', 'PGID=1000', '-e', 'TZ=Etc/UTC',
            # The catalogue gives the standard versions the same variables.
            '-e', 'MACHINE_LEARNING_HOST=0.0.0.0', '-e', 'MACHINE_LEARNING_PORT=3003',
            '-e', 'MACHINE_LEARNING_WORKERS=1', '-e', 'MACHINE_LEARNING_WORKER_TIMEOUT=120']
    if callback_log:
        args += ['-e', 'INSTANCE_ID=' + CALLBACK_INSTANCE, '-e', 'CALLBACK_TOKEN',
                 '-e', 'APPBOX_CALLBACK_BASE=http://127.0.0.1:' + CALLBACK_PORT]
    else:
        args += ['-e', 'SKIP_APPBOX_CALLBACK=1', '-e', 'INSTANCE_ID=' + RUN]
    for volume, destination in mounts:
        args += ['-v', volume + ':' + destination]
    command(args + [image], env={**os.environ, 'PASSWORD': PASSWORD, 'CALLBACK_TOKEN': CALLBACK_TOKEN})
    if callback_log:
        start_callback_mock(name, callback_log)
    base, token = wait_ready(name, version)
    print('PASS ' + phase + ': correct version, readiness, admin login and persistent install marker', flush=True)
    if callback_log:
        expect_callbacks(name, callback_log, 1)
        print('PASS ' + phase + ': exactly one installed callback with the instance path and token', flush=True)
    return name, base, token


def create_data(base, token):
    boundary = 'immichgate' + secrets.token_hex(12)
    body = bytearray()
    fields = {'fileCreatedAt': '2026-09-10T10:00:00.000Z', 'fileModifiedAt': '2026-09-10T10:00:00.000Z'}
    if request(base, '/api/server/version')['major'] < 3:
        fields.update(deviceAssetId=RUN, deviceId=RUN)
    for key, value in fields.items():
        body.extend(('--' + boundary + '\r\nContent-Disposition: form-data; name="' + key + '"\r\n\r\n' + value + '\r\n').encode())
    body.extend(('--' + boundary + '\r\nContent-Disposition: form-data; name="assetData"; filename="release-check.png"\r\nContent-Type: image/png\r\n\r\n').encode())
    body.extend(PHOTO)
    body.extend(('\r\n--' + boundary + '--\r\n').encode())
    asset = request(base, '/api/assets', 'POST', bytes(body), token, content_type='multipart/form-data; boundary=' + boundary)
    user = request(base, '/api/admin/users', 'POST', {'email': 'second@example.invalid', 'name': 'Release Check', 'password': PASSWORD}, token)
    album = request(base, '/api/albums', 'POST', {'albumName': RUN, 'assetIds': [asset['id']],
                    'albumUsers': [{'userId': user['id'], 'role': 'viewer'}]}, token)
    empty = request(base, '/api/albums', 'POST', {'albumName': RUN + '-empty'}, token)
    return {'asset': asset['id'], 'user': user['id'], 'album': album['id'], 'empty_album': empty['id']}


def verify_data(base, token, data):
    photo = request(base, '/api/assets/' + data['asset'] + '/original', token=token, raw=True)
    if hashlib.sha256(photo).digest() != hashlib.sha256(PHOTO).digest():
        raise RuntimeError('Original photo changed')
    users = request(base, '/api/admin/users', token=token)
    if not any(user['id'] == data['user'] for user in users):
        raise RuntimeError('Second account missing')
    album = request(base, '/api/albums/' + data['album'], token=token)
    if album['albumName'] != RUN:
        raise RuntimeError('Album name changed')
    if not any(u['user']['id'] == data['user'] and u['role'] == 'viewer' for u in album['albumUsers']):
        raise RuntimeError('Album sharing role was not retained')
    empty = request(base, '/api/albums/' + data['empty_album'], token=token)
    if empty['albumName'] != RUN + '-empty':
        raise RuntimeError('Empty album was not retained')
    if 'assets' in album:
        assets = album['assets']
    else:
        assets = request(base, '/api/search/metadata', 'POST', {'albumIds': [data['album']]}, token)['assets']['items']
    if not any(asset['id'] == data['asset'] for asset in assets):
        raise RuntimeError('Album membership lost')


def verify_runtime(name):
    processes = command(['docker', 'exec', name, 'ps', '-eo', 'uid,comm']).splitlines()
    # Immich sets process.title for both the worker manager and API process.
    for process in ('postgres', 'redis-server', 'immich', 'immich-api'):
        rows = [line.split() for line in processes if line.split()[-1:] == [process]]
        if not rows or any(row[0] != '1000' for row in rows):
            raise RuntimeError('Incorrect process ownership: ' + process)
    sql = "SELECT extname || ':' || extversion FROM pg_extension WHERE extname IN ('vchord','vector') ORDER BY extname;"
    output = command(['docker', 'exec', name, 'gosu', '1000:1000', '/usr/lib/postgresql/14/bin/psql', '-XAt', '-h', 'localhost', '-U', 'postgres', '-d', 'immich', '-c', sql])
    if 'vchord:0.4.3' not in output or 'vector:' not in output:
        raise RuntimeError('Vector extensions missing or incompatible')
    address = command(['docker', 'exec', name, 'gosu', '1000:1000', '/usr/lib/postgresql/14/bin/psql', '-XAt', '-h', 'localhost', '-U', 'postgres', '-c', 'SHOW listen_addresses'])
    if address != 'localhost':
        raise RuntimeError('PostgreSQL listener is not local')
    if command(['docker', 'exec', name, 'redis-cli', 'ping']) != 'PONG':
        raise RuntimeError('Redis unavailable')
    print('PASS runtime: UID 1000 services, VectorChord 0.4.3, PostgreSQL loopback and Redis', flush=True)


def verify_album_regression(name):
    # Test the SQL expression actually installed in the candidate with an enum
    # created after the Postgres.js connection has initialized its serializers.
    script = r'''
const fs = require('fs');
const postgres = require('/app/immich/server/node_modules/postgres');
const source = fs.readFileSync('/app/immich/server/dist/repositories/album.repository.js', 'utf8');
const match = source.match(/`(unnest\(\$\{roles\}[^`]+)`\.as\('role'\)/);
if (!match || !match[1].includes('::text[])::album_user_role_enum')) throw new Error('Album patch missing');
const expression = match[1].replace('${roles}', '$1').replace('album_user_role_enum', 'pg_temp.release_role');
const sql = postgres({host:'localhost',port:5432,username:'postgres',database:'immich',max:1});
(async () => {
  await sql.unsafe('select 1');
  await sql.unsafe("CREATE TYPE pg_temp.release_role AS ENUM ('owner','viewer')");
  let reproduced = false;
  try { await sql.unsafe('SELECT unnest($1::pg_temp.release_role[]) AS role', [['owner']]); }
  catch(e) { if(e.code !== '22P02') throw e; reproduced = true; }
  if (!reproduced) throw new Error('Regression control did not reproduce');
  const query = 'SELECT ' + expression + ' AS role';
  const rows = await sql.unsafe(query, [['owner','viewer']]);
  if(rows.length !== 2 || rows[0].role !== 'owner' || rows[1].role !== 'viewer') throw new Error('Role array changed');
  let rejected = false;
  try { await sql.unsafe(query, [['invalid-role']]); }
  catch(e) { if(e.code !== '22P02') throw e; rejected = true; }
  if (!rejected) throw new Error('Invalid role accepted');
  console.log('PASS album regression: original fails on stale type cache; installed patch preserves owner/viewer and rejects invalid roles');
})().catch(e => {console.error(e.code || e.message);process.exitCode=1}).finally(() => sql.end());
'''
    print(command(['docker', 'exec', '-i', '-u', '1000:1000', name, 'node', '-'], data=script), flush=True)


def main():
    if len(sys.argv) != 2 or sys.argv[1] != EXPECTED:
        raise RuntimeError('Unexpected image reference')
    if command(['docker', 'image', 'inspect', '--format', '{{.Os}}/{{.Architecture}}', EXPECTED]) != 'linux/amd64':
        raise RuntimeError('Incorrect image architecture')
    tests = Path(__file__).resolve().parent.parent / 'tests' / 'test-installed-callback.sh'
    result = subprocess.run(['bash', str(tests)], capture_output=True, text=True, timeout=600)
    if result.returncode:
        print(result.stdout[-3000:], file=sys.stderr, flush=True)
        raise RuntimeError('tests/test-installed-callback.sh failed')
    print('PASS tests/test-installed-callback.sh', flush=True)
    command(['docker', 'pull', PREVIOUS], timeout=900)
    old_id = command(['docker', 'image', 'inspect', '--format', '{{index .RepoDigests 0}}', PREVIOUS])
    print('Previous image: ' + old_id, flush=True)
    fresh, base, token = start('fresh', EXPECTED, storage('fresh'), NEW_VERSION, '/tmp/gate-callback-fresh.log')
    verify_runtime(fresh)
    verify_album_regression(fresh)
    data = create_data(base, token)
    verify_data(base, token, data)
    print('PASS fresh install: photo upload/download, second account and album', flush=True)
    command(['docker', 'restart', '-t', '30', fresh], timeout=STOP_TIMEOUT)
    start_callback_mock(fresh, '/tmp/gate-callback-restart.log')
    base, token = wait_ready(fresh, NEW_VERSION)
    verify_data(base, token, data)
    verify_runtime(fresh)
    expect_callbacks(fresh, '/tmp/gate-callback-restart.log', 0, settle=30)
    secrets_absent_from_log(fresh)
    print('PASS restart: exact photo, accounts and album retained; no second callback; no credentials in the log', flush=True)
    command(['docker', 'stop', '-t', '30', fresh], timeout=STOP_TIMEOUT)
    mounts = storage('upgrade')
    old, base, token = start('baseline', old_id, mounts, OLD_VERSION)
    # Existing installations have completed schema creation. Warm the old
    # image's connection cache after migration before seeding upgrade data.
    command(['docker', 'restart', '-t', '30', old], timeout=STOP_TIMEOUT)
    base, token = wait_ready(old, OLD_VERSION)
    print('BASELINE ONLY: normal restart after schema creation before preparing existing-install data', flush=True)
    data = create_data(base, token)
    verify_data(base, token, data)
    command(['docker', 'stop', '-t', '30', old], timeout=STOP_TIMEOUT)
    upgraded, base, token = start('upgrade', EXPECTED, mounts, NEW_VERSION, '/tmp/gate-callback-upgrade.log')
    verify_data(base, token, data)
    verify_runtime(upgraded)
    verify_album_regression(upgraded)
    secrets_absent_from_log(upgraded)
    print('PASS ' + PREVIOUS.rsplit(':', 1)[1] + ' to ' + EXPECTED.rsplit(':', 1)[1] +
          ' upgrade: exact photo, accounts, credentials and album retained', flush=True)
    new_password = secrets.token_urlsafe(24) + '!bB2'
    command(['docker', 'exec', upgraded, '/moduser.sh', new_password])
    login(base, new_password)
    try:
        login(base)
    except RuntimeError as error:
        if 'HTTP 401' not in str(error):
            raise
    else:
        raise RuntimeError('Old password still works after reset')
    print('PASS password reset: new login succeeds, old login rejected', flush=True)
    spec = importlib.util.spec_from_file_location('registry_check', Path(__file__).with_name('registry-check.py'))
    registry = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(registry)
    registry.registry_absent(EXPECTED)
    print('Release gate passed for ' + EXPECTED, flush=True)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('RELEASE GATE FAILED: ' + str(error), file=sys.stderr, flush=True)
        failure_diagnostics()
        sys.exit(1)
