#!/bin/bash
# Writes the Last.fm application identity to a local file (0600) under Application Support.
#
# Credentials live in a file rather than the Keychain on purpose: this is a single-user tool on the
# owner's own Mac, and re-authorizing every launch is worse than the local exposure. The file never
# leaves this machine and is never committed — .gitignore excludes it.
#
#   ./Scripts/seed-lastfm.sh
#   LASTFM_API_KEY=... LASTFM_SECRET=... ./Scripts/seed-lastfm.sh
set -euo pipefail

TARGET="$HOME/Library/Application Support/bbMusic/lastfm.json"

API_KEY="${LASTFM_API_KEY:-}"
SECRET="${LASTFM_SECRET:-}"

if [ -z "$API_KEY" ]; then
    read -r -p "Last.fm API key: " API_KEY
fi
if [ -z "$SECRET" ]; then
    read -r -s -p "Last.fm shared secret (hidden): " SECRET
    echo
fi

if [ -z "$API_KEY" ] || [ -z "$SECRET" ]; then
    echo "error: both values are required" >&2
    exit 1
fi

mkdir -p "$(dirname "$TARGET")"

# Preserve an existing session so re-seeding the app identity does not log the user out.
python3 - "$TARGET" "$API_KEY" "$SECRET" <<'PY'
import json, os, sys
path, api_key, secret = sys.argv[1], sys.argv[2], sys.argv[3]
payload = {"apiKey": api_key, "sharedSecret": secret}
if os.path.exists(path):
    try:
        existing = json.load(open(path))
        for key in ("sessionKey", "username"):
            if existing.get(key):
                payload[key] = existing[key]
    except Exception:
        pass
with open(path, "w") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
os.chmod(path, 0o600)
print(f"Wrote {path} (mode 600)")
PY

echo "Session keys are added by the app when you authorize in the browser."
