#!/usr/bin/env python3
"""Require an authenticated, definitive new-tag result from the builder."""
import json
import subprocess
import sys

EXPECTED = 'repo.cylo.net/immich:3.3.5-1'
PREVIOUS = 'repo.cylo.net/immich:3.3.5'


def registry_absent(image):
    if image != EXPECTED:
        raise RuntimeError('Unexpected release reference')
    baseline = subprocess.run(['docker', 'manifest', 'inspect', PREVIOUS],
                              capture_output=True, text=True, timeout=90)
    if baseline.returncode or not isinstance(json.loads(baseline.stdout), dict):
        raise RuntimeError('Registry baseline read failed; publication blocked')
    result = subprocess.run(['docker', 'manifest', 'inspect', image],
                            capture_output=True, text=True, timeout=90)
    if result.returncode == 0:
        raise RuntimeError('Registry tag already exists; refusing replacement')
    if result.stderr.strip() != 'no such manifest: ' + image:
        raise RuntimeError('Registry absence indeterminate; publication blocked')
    print('PASS registry: previous tag readable; exact release tag is MANIFEST_UNKNOWN', flush=True)


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: registry-check.py IMAGE')
    registry_absent(sys.argv[1])
