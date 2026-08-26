#!/bin/bash
#
# Railway wrapper around OneDev's own entrypoint.
#
# OneDev seeds its first administrator and system settings from `initial_*`
# environment variables, but two things a public deployment needs are stored in
# the database and have no environment variable at all:
#
#   * account self sign-up, which ships ENABLED (`SecuritySetting.enableSelfRegister`)
#   * a CI/CD job executor — the server cannot run OneDev's default Docker
#     executor here, because Railway blocks nested containers
#
# Both are set once, through OneDev's REST API, after the server reports ready.
# Each concern carries its own marker file on the volume so that a later image
# never re-applies a step the operator has since changed in the admin UI.

set -e

MARKER_DIR="/opt/onedev/site/railway"
LOCAL_URL="http://127.0.0.1:${http_port:-6610}"

log() { echo "[railway] $*"; }

api() {
	# api <method> <path> [body]
	local method="$1" path="$2" body="${3:-}"
	if [ -n "$body" ]; then
		curl -fsS --max-time 30 -u "$initial_user:$initial_password" \
			-H 'Content-Type: application/json' \
			-X "$method" -d "$body" "$LOCAL_URL$path"
	else
		curl -fsS --max-time 30 -u "$initial_user:$initial_password" \
			-H 'Content-Type: application/json' \
			-X "$method" "$LOCAL_URL$path"
	fi
}

close_self_signup() {
	[ -e "$MARKER_DIR/self-signup-closed" ] && return 0

	local current
	current=$(api GET /~api/settings/security) || {
		log "WARNING: could not read security setting; account self sign-up left as shipped"
		return 0
	}

	if [ "$(printf '%s' "$current" | jq -r '.enableSelfRegister')" != "true" ]; then
		touch "$MARKER_DIR/self-signup-closed"
		return 0
	fi

	local hardened
	hardened=$(printf '%s' "$current" | jq -c '.enableSelfRegister = false')

	if api POST /~api/settings/security "$hardened" >/dev/null; then
		touch "$MARKER_DIR/self-signup-closed"
		log "account self sign-up disabled"
	else
		log "WARNING: could not disable account self sign-up"
	fi
}

sync_ssh_root_url() {
	# Git over SSH is published with a Railway TCP proxy, whose hostname and port
	# are only knowable at runtime and change if the proxy is recreated. Resolve
	# them from the injected environment on every boot, but remember what we
	# wrote so an operator who sets their own SSH root URL is never overruled.
	[ -n "$RAILWAY_TCP_PROXY_DOMAIN" ] && [ -n "$RAILWAY_TCP_PROXY_PORT" ] || return 0

	local wanted stamp current
	wanted="ssh://$RAILWAY_TCP_PROXY_DOMAIN:$RAILWAY_TCP_PROXY_PORT"
	stamp="$MARKER_DIR/ssh-root-url"

	current=$(api GET /~api/settings/system) || {
		log "WARNING: could not read system setting; SSH root URL left as is"
		return 0
	}

	local stored
	stored=$(printf '%s' "$current" | jq -r '.sshRootUrl // ""')
	[ "$stored" = "$wanted" ] && { printf '%s' "$wanted" > "$stamp"; return 0; }

	if [ -n "$stored" ] && [ -e "$stamp" ] && [ "$stored" != "$(cat "$stamp")" ]; then
		log "SSH root URL was changed by an operator; leaving it alone"
		return 0
	fi

	local updated
	updated=$(printf '%s' "$current" | jq -c --arg u "$wanted" '.sshRootUrl = $u')
	if api POST /~api/settings/system "$updated" >/dev/null; then
		printf '%s' "$wanted" > "$stamp"
		log "SSH root URL set to $wanted"
	else
		log "WARNING: could not set SSH root URL"
	fi
}

seed_job_executor() {
	# The agent reports the *host's* core count (48 on Railway), and a shell
	# executor with no concurrency set takes that as its job limit — so the
	# shipped executor pins it to a number the container's 8 vCPU can serve.
	[ -e "$MARKER_DIR/job-executor-seeded" ] && return 0

	local wanted existing
	wanted=$(jq -c . /root/bin/job-executors.json)
	[ "$(printf '%s' "$wanted" | jq 'length')" = "0" ] && return 0

	existing=$(api GET /~api/settings/job-executors) || {
		log "WARNING: could not read job executors"
		return 0
	}

	# Never touch a list the operator has already populated.
	if [ "$(printf '%s' "$existing" | jq 'length')" != "0" ]; then
		touch "$MARKER_DIR/job-executor-seeded"
		return 0
	fi

	if api POST /~api/settings/job-executors "$wanted" >/dev/null; then
		touch "$MARKER_DIR/job-executor-seeded"
		log "seeded default job executor"
	else
		log "WARNING: could not seed job executor"
	fi
}

post_boot() {
	local i
	for i in $(seq 1 240); do
		curl -fsS -o /dev/null --max-time 5 "$LOCAL_URL/readyz" 2>/dev/null && break
		sleep 5
	done

	if ! curl -fsS -o /dev/null --max-time 5 "$LOCAL_URL/readyz" 2>/dev/null; then
		log "server never reported ready; skipping post-boot configuration"
		return 0
	fi

	if [ -z "$initial_user" ] || [ -z "$initial_password" ]; then
		log "initial_user/initial_password unset; skipping post-boot configuration"
		return 0
	fi

	mkdir -p "$MARKER_DIR"
	close_self_signup
	sync_ssh_root_url
	seed_job_executor
}

( post_boot || true ) &

exec /root/bin/entrypoint-upstream.sh
