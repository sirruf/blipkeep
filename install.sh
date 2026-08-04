#!/usr/bin/env bash
#
# Install the panel in one command — together with the things you would
# otherwise have to look up separately: where the administrator password is
# stored, where to get an enrollment token, and the exact command that installs
# an agent.
#
#   sudo ./install.sh --host mon.example.com
#
# The panel itself is deployed by server/bootstrap; this script only calls it
# and does what comes after: the token and a ready-to-paste command for the
# monitored server. That command is the whole point — assembling it by hand out
# of an address, a scheme and a token is exactly where installations stall.
#
# English only, deliberately: this file ships in the public installation kit.

set -euo pipefail

cd "$(dirname "$0")"

HOST=""
SCHEME="https"
STACK_NAME="tinymon"

# Arguments are inspected, not consumed: bootstrap receives all of them as is,
# and only those needed to build the agent command are read here
for (( i = 1; i <= $#; i++ )); do
  case "${!i}" in
    --host)   j=$((i + 1)); HOST="${!j}" ;;
    --scheme) j=$((i + 1)); SCHEME="${!j}" ;;
    --stack)  j=$((i + 1)); STACK_NAME="${!j}" ;;
  esac
done

if [[ -z "$HOST" ]]; then
  echo "Specify the panel address:" >&2
  echo "  sudo ./install.sh --host mon.example.com" >&2
  echo >&2
  echo "For the other options see ./server/bootstrap --help" >&2
  exit 1
fi

[[ $EUID -eq 0 ]] || {
  echo "root privileges required: run through sudo" >&2
  exit 1
}

# ---- The panel -------------------------------------------------------------

./server/bootstrap "$@"

# ---- Token and the agent command -------------------------------------------

container="$(docker ps -q -f "name=${STACK_NAME}_tinymon" | head -1)"

if [[ -z "$container" ]]; then
  echo "The panel is deployed, but its container was not found — take the token from the panel, the Agents screen" >&2
  exit 0
fi

echo
echo "==> creating an enrollment token for agents"

# The token is printed as ENROLLMENT_TOKEN=<value>; we extract the value to
# paste it straight into the command instead of making anyone copy it by hand
token_output="$(docker exec "$container" /app/bin/tinymon eval \
  'Tinymon.Release.enrollment_token()' 2>/dev/null || true)"

TOKEN="$(printf '%s' "$token_output" | grep -o 'ENROLLMENT_TOKEN=.*' | cut -d= -f2- | tr -d '\r')"

if [[ -z "$TOKEN" ]]; then
  echo "    failed — create a token in the panel on the Agents screen" >&2
  exit 0
fi

WS_SCHEME="wss"
[[ "$SCHEME" == "https" ]] || WS_SCHEME="ws"

cat <<EOF

────────────────────────────────────────────────────────────────────────

THE PANEL IS READY: ${SCHEME}://${HOST}

Sign in:
  email and password are in /opt/tinymon/.initial-credentials
  you will have to change the password on first sign-in

Installing an agent — run this on the server you want to monitor:

  curl -fsSL ${SCHEME}://${HOST}/install.sh | sudo bash -s -- \\
    --server ${WS_SCHEME}://${HOST}/agent \\
    --token ${TOKEN}

The installer prints a key fingerprint. Compare it in the panel on the
Agents screen and approve the request — the host then appears in the overview.

The token is reusable: the same command enrolls a whole batch of servers.

────────────────────────────────────────────────────────────────────────
EOF
