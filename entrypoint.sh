#!/bin/sh
# entrypoint.sh
#
# 1. Validates the forwarding configuration (fail fast, before using an auth key).
# 2. Starts tailscaled.
# 3. Brings Tailscale up. The auth key is ONLY used when the node has no valid
#    identity yet (first start, or node key expired / device removed). When a
#    persisted identity exists the node reconnects with it, so an expired or
#    single-use auth key does not put the container into a restart loop.
# 4. Applies iptables rules and then supervises tailscaled.

set -e

# --- Helper Functions ---
log_info() {
  echo "[ENTRYPOINT-INFO] $1"
}

log_warn() {
  echo "[ENTRYPOINT-WARN] $1" >&2
}

log_error() {
  echo "[ENTRYPOINT-ERROR] $1" >&2
}

TAILSCALED_PID=""

tailscaled_alive() {
  [ -n "$TAILSCALED_PID" ] || return 1
  kill -0 "$TAILSCALED_PID" 2>/dev/null || return 1
  # An exited-but-unreaped child still answers kill -0; treat a zombie as dead.
  proc_state=$(sed -n 's/^State:[[:space:]]*\([A-Z]\).*/\1/p' "/proc/$TAILSCALED_PID/status" 2>/dev/null || true)
  [ "$proc_state" != "Z" ]
}

stop_tailscaled() {
  if [ -n "$TAILSCALED_PID" ]; then
    kill -TERM "$TAILSCALED_PID" 2>/dev/null || true
    wait "$TAILSCALED_PID" 2>/dev/null || true
  fi
}

# fail <exit-code> <message>
fail() {
  log_error "$2"
  if [ -n "$TAILSCALED_PID" ]; then
    log_error "Stopping tailscaled (PID $TAILSCALED_PID) and exiting."
    stop_tailscaled
  fi
  exit "$1"
}

# Docker sends SIGTERM on stop. A shell running as PID 1 ignores it by default,
# which used to leave tailscaled to be SIGKILLed after the stop timeout.
on_signal() {
  log_info "Received stop signal. Shutting down tailscaled..."
  stop_tailscaled
  exit 0
}
trap on_signal TERM INT

# Collapse a comma/space separated list into a clean comma separated list.
normalize_list() {
  echo "$1" | tr ' \t' ',,' | tr -s ',' | sed 's/^,//; s/,$//'
}

ts_status_json() {
  tailscale status --json 2>/dev/null || true
}

backend_state() {
  ts_status_json | jq -r '.BackendState // empty' 2>/dev/null || true
}

have_node_key() {
  [ "$(ts_status_json | jq -r '.HaveNodeKey // false' 2>/dev/null || true)" = "true" ]
}
# --- End Helper Functions ---

SCRIPT_DIR=$(dirname "$0")
IPTABLES_SCRIPT="${SCRIPT_DIR%/}/iptables-config.sh"
TS_STATE_DIR="${TS_STATE_DIR:-/var/lib/tailscale}"
TS_UP_TIMEOUT="${TS_UP_TIMEOUT:-60s}"

# --- Validate forwarding configuration before touching Tailscale ---
# Misconfiguration used to be detected only after 'tailscale up', which could
# burn a single-use auth key on a container that would never work.
log_info "Validating forwarding configuration..."
"$IPTABLES_SCRIPT" --check || fail 1 "Forwarding configuration is invalid. Fix the environment variables above."

# --- Auth key (optional when a persisted node identity exists) ---
# AUTHKEY_ARG holds the value passed to --authkey. It is never logged.
AUTHKEY_ARG=""
if [ -n "$TS_AUTHKEY_FILE" ]; then
  if [ ! -r "$TS_AUTHKEY_FILE" ]; then
    fail 1 "TS_AUTHKEY_FILE is set to '$TS_AUTHKEY_FILE' but that file is not readable."
  fi
  log_info "Using auth key from file $TS_AUTHKEY_FILE."
  AUTHKEY_ARG="file:$TS_AUTHKEY_FILE"
elif [ -n "$TS_AUTHKEY" ]; then
  AUTHKEY_ARG="$TS_AUTHKEY"
  case "$TS_AUTHKEY" in
    tskey-client-*\?*)
      log_info "TS_AUTHKEY is an OAuth client secret with explicit parameters."
      ;;
    tskey-client-*)
      # OAuth-minted keys default to ephemeral=true, which would delete this
      # node (and its Tailscale IP) whenever the container is offline.
      log_info "TS_AUTHKEY is an OAuth client secret. Registering as a non-ephemeral node (appending ?ephemeral=false)."
      AUTHKEY_ARG="${TS_AUTHKEY}?ephemeral=false"
      ;;
  esac
fi

# --- Persistent state sanity check ---
if ! awk -v d="$TS_STATE_DIR" '$2 == d { found = 1 } END { exit !found }' /proc/mounts 2>/dev/null; then
  log_warn "TS_STATE_DIR ($TS_STATE_DIR) does not appear to be a mounted volume. The node identity will be lost when the container is recreated, and a valid auth key will be needed every time."
fi

# --- Start tailscaled ---
if [ "$TS_USERSPACE" = "true" ]; then
  log_warn "TS_USERSPACE=true is not supported: iptables forwarding requires the kernel TUN device. Running in kernel mode."
fi

# tailscaled installs its own firewall rules. On hosts whose kernel only offers
# nftables, the image's legacy iptables fails and tailscaled's router setup
# breaks; tell tailscaled to use nftables directly in that case.
# Detection must happen BEFORE tailscaled starts: once tailscaled has written
# native nftables rules, 'iptables-nft -S' reports the tables as incompatible.
if [ -z "$TAILFWD_IPTABLES" ]; then
  TAILFWD_IPTABLES=iptables
  if ! iptables -t nat -S > /dev/null 2>&1 && iptables-nft -t nat -S > /dev/null 2>&1; then
    TAILFWD_IPTABLES=iptables-nft
  fi
fi
export TAILFWD_IPTABLES
if [ "$TAILFWD_IPTABLES" = "iptables-nft" ] && [ -z "$TS_DEBUG_FIREWALL_MODE" ]; then
  log_info "Legacy iptables is not available on this host kernel. Using nftables for tailscaled (TS_DEBUG_FIREWALL_MODE=nftables)."
  export TS_DEBUG_FIREWALL_MODE=nftables
fi

set -- --statedir="$TS_STATE_DIR" --tun=tailscale0

# Peer UDP Port for tailscaled daemon
if [ -n "$TS_PEER_UDP_PORT" ]; then
  if echo "$TS_PEER_UDP_PORT" | grep -Eq '^[1-9][0-9]*$' && [ "$TS_PEER_UDP_PORT" -le 65535 ]; then
    log_info "TS_PEER_UDP_PORT is set to: $TS_PEER_UDP_PORT. Adding --port=$TS_PEER_UDP_PORT to tailscaled daemon."
    set -- "$@" --port="$TS_PEER_UDP_PORT"
  elif [ "$TS_PEER_UDP_PORT" = "0" ] || [ "$TS_PEER_UDP_PORT" = "auto" ]; then
    log_info "TS_PEER_UDP_PORT is '$TS_PEER_UDP_PORT'. Allowing tailscaled to auto-select its UDP port."
  else
    log_warn "TS_PEER_UDP_PORT ('$TS_PEER_UDP_PORT') is not a valid port (1-65535), '0', or 'auto'. Allowing tailscaled to auto-select its UDP port."
  fi
else
  log_info "TS_PEER_UDP_PORT is not set. Allowing tailscaled to auto-select its UDP port."
fi

log_info "Starting tailscaled: tailscaled $*"
tailscaled "$@" &
TAILSCALED_PID=$!
log_info "tailscaled started with PID $TAILSCALED_PID."

log_info "Waiting for tailscaled to become ready..."
ready_attempt=0
state=""
while :; do
  ready_attempt=$((ready_attempt + 1))
  tailscaled_alive || fail 1 "tailscaled exited during startup. Check that /dev/net/tun is available and NET_ADMIN is granted."
  state=$(backend_state)
  if [ -n "$state" ] && [ "$state" != "NoState" ]; then
    break
  fi
  if [ "$ready_attempt" -ge 30 ]; then
    if [ -z "$state" ]; then
      fail 1 "tailscaled did not answer on its local API within 30 seconds."
    fi
    log_warn "tailscaled is still in state '$state' after 30 seconds. Continuing anyway."
    break
  fi
  sleep 1
done
log_info "tailscaled is ready (backend state: ${state:-unknown})."

# --- Build 'tailscale up' arguments ---
log_info "Constructing 'tailscale up' arguments..."

# --reset makes every start converge to exactly the configuration below, even
# if variables were removed since the last start. Without it, 'tailscale up'
# refuses to run when an existing pref is not mentioned on the command line.
UP_ARGS="--reset --timeout=$TS_UP_TIMEOUT"

# Accept DNS
if [ "$TS_ACCEPT_DNS" = "true" ]; then
  log_info "TS_ACCEPT_DNS is true. Adding --accept-dns=true."
  UP_ARGS="$UP_ARGS --accept-dns=true"
else
  log_info "TS_ACCEPT_DNS is not 'true' (or not set). Adding --accept-dns=false (default behavior)."
  UP_ARGS="$UP_ARGS --accept-dns=false"
fi

# Hostname:
# If TS_HOSTNAME is not set, we default to 'tailforwarder'.
DESIRED_HOSTNAME=${TS_HOSTNAME:-"tailforwarder"}
UP_ARGS="$UP_ARGS --hostname=$DESIRED_HOSTNAME"
if [ -z "$TS_HOSTNAME" ]; then
  log_warn "TS_HOSTNAME not set, defaulting to '$DESIRED_HOSTNAME' for 'tailscale up'."
fi

# Advertise Routes (TS_ROUTES_ADVERTISE is the legacy name).
# --advertise-routes takes ONE comma separated list; repeating the flag would
# keep only the last route.
ROUTES=$(normalize_list "${TS_ROUTES:-$TS_ROUTES_ADVERTISE}")
if [ -n "$ROUTES" ]; then
  log_info "Advertising routes: $ROUTES"
  UP_ARGS="$UP_ARGS --advertise-routes=$ROUTES"
else
  log_info "TS_ROUTES is not set. Not advertising any routes."
fi

# Advertise Tags (TS_TAGS_ADVERTISE is the legacy name).
TAGS=$(normalize_list "${TS_TAGS:-$TS_TAGS_ADVERTISE}")
if [ -n "$TAGS" ]; then
  log_info "Advertising tags: $TAGS"
  UP_ARGS="$UP_ARGS --advertise-tags=$TAGS"
else
  log_info "TS_TAGS is not set. Not advertising any tags."
  case "$TS_AUTHKEY" in
    tskey-client-*)
      log_warn "An OAuth client secret requires tags. Set TS_TAGS (e.g. tag:tailforwarder) or authentication will fail."
      ;;
  esac
fi

# Accept Routes
if [ "$TS_ACCEPT_ROUTES" = "true" ]; then
  log_info "TS_ACCEPT_ROUTES is true. Adding --accept-routes."
  UP_ARGS="$UP_ARGS --accept-routes"
else
  log_info "TS_ACCEPT_ROUTES is not 'true' (or not set). Not adding --accept-routes (default behavior)."
fi

# Exit node: iptables rules alone are useless unless the node is advertised.
if [ "$ENABLE_EXIT_NODE" = "true" ]; then
  case " $TS_EXTRA_ARGS " in
    *" --advertise-exit-node"*) ;;
    *)
      log_info "ENABLE_EXIT_NODE is true. Adding --advertise-exit-node."
      UP_ARGS="$UP_ARGS --advertise-exit-node"
      ;;
  esac
fi

# Any other extra arguments from TS_EXTRA_ARGS
case " $TS_EXTRA_ARGS " in
  *" --authkey"*|*" --auth-key"*|*" -authkey"*|*" -auth-key"*)
    # A key here would be sent on every start (the restart-loop bug) and logged.
    fail 1 "Do not put the auth key in TS_EXTRA_ARGS. Use TS_AUTHKEY or TS_AUTHKEY_FILE instead."
    ;;
esac
if [ -n "$TS_EXTRA_ARGS" ]; then
  log_info "TS_EXTRA_ARGS is set to: $TS_EXTRA_ARGS"
  UP_ARGS="$UP_ARGS $TS_EXTRA_ARGS"
else
  log_info "TS_EXTRA_ARGS is not set."
fi

# run_up [with-key]
run_up() {
  if [ "$1" = "with-key" ]; then
    reauth=""
    # When an old (expired / removed) node key is still in the state, 'tailscale
    # up' ignores --authkey and waits for an interactive login URL instead.
    # --force-reauth makes it actually log in with the key.
    if have_node_key; then
      reauth="--force-reauth"
    fi
    log_info "Running: tailscale up $UP_ARGS $reauth --authkey=<redacted>"
    # shellcheck disable=SC2086 # UP_ARGS is intentionally word-split
    tailscale up $UP_ARGS $reauth --authkey="$AUTHKEY_ARG"
  else
    log_info "Running: tailscale up $UP_ARGS"
    # shellcheck disable=SC2086
    tailscale up $UP_ARGS
  fi
}

# --- Bring Tailscale up ---
authenticated=false
if [ "$state" != "NeedsLogin" ] && have_node_key; then
  log_info "Found an existing node identity in $TS_STATE_DIR. Reconnecting with it (auth key not used)."
  if run_up; then
    authenticated=true
  else
    state=$(backend_state)
    if [ "$state" = "NeedsMachineAuth" ]; then
      fail 1 "This device is waiting for approval in the Tailscale admin console (device approval is enabled). Approve it, or use a pre-authorized key."
    fi
    if [ "$state" != "NeedsLogin" ]; then
      log_error "'tailscale up' did not reach the Running state within $TS_UP_TIMEOUT (backend state: ${state:-unknown})."
      tailscale status 2>&1 || true
      fail 1 "Could not connect to Tailscale with the existing node identity. Check network connectivity to the Tailscale control server."
    fi
    log_warn "The existing node identity is no longer valid (node key expired or device removed from the tailnet). Re-authentication is required."
  fi
else
  log_info "No valid node identity found (backend state: ${state:-unknown}). Authentication is required."
fi

if [ "$authenticated" != "true" ]; then
  if [ -z "$AUTHKEY_ARG" ]; then
    fail 1 "This node needs to log in, but neither TS_AUTHKEY nor TS_AUTHKEY_FILE is set. Provide a valid auth key or OAuth client secret."
  fi
  if run_up with-key; then
    authenticated=true
  else
    if [ "$(backend_state)" = "NeedsMachineAuth" ]; then
      fail 1 "Logged in, but the device is waiting for approval in the Tailscale admin console. Approve it, or use a pre-authorized key (for OAuth secrets append '?preauthorized=true')."
    fi
    log_error "Current tailscale status:"
    tailscale status 2>&1 || true
    fail 1 "'tailscale up' with the auth key failed. The key may be expired, revoked, already used (single-use key), or missing required tags. Generate a new key, or use an OAuth client secret, which does not expire."
  fi
fi
log_info "'tailscale up' completed successfully."

if [ -n "$AUTHKEY_ARG" ]; then
  log_info "Note: the auth key is only needed for the first login. Later restarts reuse the identity stored in $TS_STATE_DIR."
fi

# --- iptables ---
log_info "Executing iptables configuration script $IPTABLES_SCRIPT..."
if "$IPTABLES_SCRIPT"; then
  log_info "iptables-config.sh completed successfully."
else
  SCRIPT_EXIT_CODE=$?
  fail "$SCRIPT_EXIT_CODE" "$IPTABLES_SCRIPT exited with code $SCRIPT_EXIT_CODE."
fi

log_info "Setup complete. Waiting for tailscaled (PID $TAILSCALED_PID) to terminate..."
WAIT_EXIT_CODE=0
wait "$TAILSCALED_PID" || WAIT_EXIT_CODE=$?
log_info "tailscaled process (PID $TAILSCALED_PID) ended with code $WAIT_EXIT_CODE. Container will now stop."
exit "$WAIT_EXIT_CODE"
