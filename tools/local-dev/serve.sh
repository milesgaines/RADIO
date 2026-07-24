#!/usr/bin/env bash
# One-command local Subsonic server with a generated demo library.
#
# Spins up supysonic (an independent Subsonic API implementation, pure
# Python) on http://127.0.0.1:4747 with 10 tagged MP3s, then runs the
# contract verifier that pins every field RadioKit's NavidromeClient reads.
#
#   ./tools/local-dev/serve.sh          # setup + serve + verify
#
# NOTE: supysonic implements Subsonic API 1.12.0 (password auth) — fine for
# contract checks and curl. The iOS app itself uses salted-token auth
# (API >= 1.13), so to run the *app* against a local server use real
# Navidrome on your Mac:  brew install navidrome && navidrome
# (see https://www.navidrome.org/docs/installation/)
set -euo pipefail
cd "$(dirname "$0")"

VENV=".venv"
if [ ! -d "$VENV" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" -q install supysonic waitress lameenc mutagen
fi

LIB="$HOME/radio-music"
if [ ! -d "$LIB" ]; then
  "$VENV/bin/python" make_library.py
fi

CONF_DIR="$HOME/.config/supysonic"
if [ ! -f "$CONF_DIR/supysonic.db" ]; then
  mkdir -p "$CONF_DIR"
  cat > "$CONF_DIR/supysonic.conf" <<EOF
[base]
database_uri = sqlite:///$CONF_DIR/supysonic.db
scanner_extensions = mp3
EOF
  "$VENV/bin/supysonic-cli" folder add music "$LIB"
  "$VENV/bin/supysonic-cli" user add radioplus --password radio-dev-pass
  "$VENV/bin/supysonic-cli" folder scan music
fi

"$VENV/bin/supysonic-server" --host 127.0.0.1 --port 4747 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT
sleep 3

"$VENV/bin/python" verify_contract.py

echo
echo "Server running at http://127.0.0.1:4747  (user: radioplus / radio-dev-pass)"
echo "Ctrl-C to stop."
wait $SERVER_PID
