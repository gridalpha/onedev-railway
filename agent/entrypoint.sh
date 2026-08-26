#!/bin/bash
#
# Railway wrapper around OneDev's own agent entrypoint.
#
# The agent authenticates with a token that lives as a row in the *server's*
# database, so it cannot be expressed as a Railway variable: `${{secret(N)}}`
# would produce a value the server has never seen, and no service can write
# another service's environment. Instead the agent asks the server to mint one
# on first boot, using the same administrator credential the server was seeded
# with, and keeps it on its own volume from then on.
#
# It also serves a liveness endpoint on $PORT, because Railway reports a
# crash-looping service that publishes no HTTP as healthy forever.

set -e

WORK_DIR="${agent_work_dir:-/agent/work}"
TOKEN_FILE="$WORK_DIR/.railway-agent-token"
PROBE_PORT="${PORT:-8080}"

log() { echo "[railway] $*"; }

fetch_token() {
	local id value
	id=$(curl -fsS --max-time 30 -u "$ONEDEV_ADMIN_USER:$ONEDEV_ADMIN_PASSWORD" \
		-H 'Content-Type: application/json' \
		-X POST "$serverUrl/~api/agent-tokens") || return 1
	case "$id" in
		''|*[!0-9]*) log "unexpected agent-token id: $id"; return 1 ;;
	esac
	value=$(curl -fsS --max-time 30 -u "$ONEDEV_ADMIN_USER:$ONEDEV_ADMIN_PASSWORD" \
		-H 'Accept: application/json' \
		"$serverUrl/~api/agent-tokens/$id" | jq -r '.value') || return 1
	[ -n "$value" ] && [ "$value" != "null" ] || return 1
	printf '%s' "$value"
}

ensure_token() {
	if [ -n "$agentToken" ]; then
		log "using operator supplied agent token"
		return 0
	fi

	mkdir -p "$WORK_DIR"
	if [ -s "$TOKEN_FILE" ]; then
		agentToken=$(cat "$TOKEN_FILE")
		export agentToken
		return 0
	fi

	if [ -z "$ONEDEV_ADMIN_USER" ] || [ -z "$ONEDEV_ADMIN_PASSWORD" ]; then
		log "FATAL: no agentToken, and ONEDEV_ADMIN_USER/ONEDEV_ADMIN_PASSWORD are unset"
		exit 1
	fi

	local i token
	for i in $(seq 1 120); do
		if curl -fsS -o /dev/null --max-time 5 "$serverUrl/readyz"; then
			if token=$(fetch_token); then
				printf '%s' "$token" > "$TOKEN_FILE"
				chmod 600 "$TOKEN_FILE"
				agentToken="$token"
				export agentToken
				log "minted a new agent token"
				return 0
			fi
		fi
		sleep 10
	done

	log "FATAL: could not obtain an agent token from $serverUrl"
	exit 1
}

serve_probe() {
	local body status
	while true; do
		if pgrep -f 'io\.onedev\.agent' >/dev/null 2>&1; then
			status="200 OK"; body="ok"
		else
			status="503 Service Unavailable"; body="agent not running"
		fi
		printf 'HTTP/1.1 %s\r\nContent-Type: text/plain\r\nContent-Length: %s\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n%s' \
			"$status" "${#body}" "$body" | nc -l -p "$PROBE_PORT" -q 1 >/dev/null 2>&1 || sleep 1
	done
}

: "${serverUrl:?serverUrl must be set to the OneDev server URL}"
serverUrl="${serverUrl%/}"
export serverUrl

ensure_token

serve_probe &

exec /root/bin/entrypoint-upstream.sh
