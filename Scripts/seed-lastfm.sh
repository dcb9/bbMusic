#!/bin/bash
# Stores the Last.fm application identity in the login Keychain.
#
# The shared secret is NOT part of this repository: it can sign requests as this application, so it
# lives only in the Keychain. Run this once per machine, with the values from
# https://www.last.fm/api/account/create.
#
#   ./Scripts/seed-lastfm.sh                 # prompts, input hidden
#   LASTFM_API_KEY=... LASTFM_SECRET=... ./Scripts/seed-lastfm.sh
set -euo pipefail

SERVICE="local.bbmusic.lastfm"

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

# -U updates an existing item instead of failing, so re-running is safe.
security add-generic-password -s "$SERVICE" -a "apiKey"       -w "$API_KEY" -U
security add-generic-password -s "$SERVICE" -a "sharedSecret" -w "$SECRET"  -U

echo "Stored Last.fm application identity in Keychain (service: $SERVICE)."
echo "Session keys are added by the app when you authorize in the browser."
