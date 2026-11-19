#!/bin/sh
#
# Configures the iptables rules for the enabled forwarding scenario.
#
# Usage:
#   iptables-config.sh           validate the configuration and apply the rules
#   iptables-config.sh --check   only validate the configuration (no iptables changes)
#
# All rules live in dedicated TAILFWD-* chains that are hooked into the built-in
# chains. The built-in chains are never flushed, so the ts-* rules installed by
# tailscaled (subnet routing / exit node SNAT, ts-forward, ts-input) stay intact
# and re-running the script is idempotent.

set -e

# Environment variables expected:
# MACVLAN_IFACE (default: eth0)
# ENABLE_TS_TO_LOCAL
# DESTINATION_IP_FROM_TS
# ENABLE_LOCAL_TO_TS
# LISTEN_IP_ON_MACVLAN
# TARGET_TS_IP_FROM_LOCAL
# EXCLUDE_PORTS_TCP
# EXCLUDE_PORTS_UDP
# TS_PEER_UDP_PORT
# ENABLE_EXIT_NODE

TAILSCALE_IFACE="tailscale0"
MACVLAN_IFACE="${MACVLAN_IFACE:-eth0}"

CHAIN_NAT_PRE="TAILFWD-PREROUTING"
CHAIN_NAT_POST="TAILFWD-POSTROUTING"
CHAIN_FWD="TAILFWD-FORWARD"

MODE="apply"
if [ "$1" = "--check" ]; then
  MODE="check"
fi

log() {
  echo "[IPTABLES-CONFIG] $1"
}

warn() {
  echo "[IPTABLES-CONFIG-WARN] $1" >&2
}

error_exit() {
  echo "[IPTABLES-CONFIG-ERROR] $1" >&2
  exit 1
}

run_cmd() {
  log "Executing: $*"
  # Run inside 'if' so 'set -e' does not abort before the error is reported.
  if ! "$@"; then
    error_exit "Command '$*' failed."
  fi
}

is_ipv4() {
  echo "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || return 1
  old_ifs=$IFS
  IFS=.
  # shellcheck disable=SC2086
  set -- $1
  IFS=$old_ifs
  for octet in "$@"; do
    [ "$octet" -le 255 ] || return 1
  done
}

is_port() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}

# Normalize a port list ("22, 80,,8000:8100,") to "22,80,8000:8100" and validate it.
# $1 = variable name (for messages), $2 = value
clean_port_list() {
  cleaned=$(echo "$2" | tr -d ' \t' | tr -s ',' | sed 's/^,//; s/,$//')
  [ -n "$cleaned" ] || return 0
  old_ifs=$IFS
  IFS=,
  for entry in $cleaned; do
    case "$entry" in
      *:*)
        lo=${entry%%:*}
        hi=${entry#*:}
        if ! is_port "$lo" || ! is_port "$hi" || [ "$lo" -gt "$hi" ]; then
          IFS=$old_ifs
          error_exit "$1 contains an invalid port range '$entry'."
        fi
        ;;
      *)
        if ! is_port "$entry"; then
          IFS=$old_ifs
          error_exit "$1 contains an invalid port '$entry'."
        fi
        ;;
    esac
  done
  IFS=$old_ifs
  echo "$cleaned"
}

# Create (if needed) and flush a TAILFWD chain, and hook it at the top of a built-in chain.
# $1 = table, $2 = built-in chain, $3 = our chain
setup_chain() {
  # Listing may fail on tables tailscaled manages via native nftables, so create
  # the chain and treat "already exists" as success; the flush below verifies it.
  log "Executing: $IPT -t $1 -N $3"
  "$IPT" -t "$1" -N "$3" 2>/dev/null || log "Chain $3 already exists in table $1."
  run_cmd "$IPT" -t "$1" -F "$3"
  if ! "$IPT" -t "$1" -C "$2" -j "$3" > /dev/null 2>&1; then
    run_cmd "$IPT" -t "$1" -I "$2" 1 -j "$3"
  fi
}

# --- Validation (no side effects) ---
validate_config() {
  log "Validating scenario configuration..."
  ENABLED_SCENARIOS=0
  [ "$ENABLE_TS_TO_LOCAL" = "true" ] && ENABLED_SCENARIOS=$((ENABLED_SCENARIOS + 1))
  [ "$ENABLE_LOCAL_TO_TS" = "true" ] && ENABLED_SCENARIOS=$((ENABLED_SCENARIOS + 1))
  [ "$ENABLE_EXIT_NODE" = "true" ] && ENABLED_SCENARIOS=$((ENABLED_SCENARIOS + 1))

  if [ "$ENABLED_SCENARIOS" -gt 1 ]; then
    error_exit "Multiple forwarding scenarios enabled. Only one of ENABLE_TS_TO_LOCAL, ENABLE_LOCAL_TO_TS, or ENABLE_EXIT_NODE should be true per instance."
  fi
  if [ "$ENABLED_SCENARIOS" -eq 0 ]; then
    warn "No forwarding scenario enabled. At least one of ENABLE_TS_TO_LOCAL, ENABLE_LOCAL_TO_TS, or ENABLE_EXIT_NODE should be true for this container to function as a forwarder."
  fi

  if ! ip link show "$MACVLAN_IFACE" > /dev/null 2>&1; then
    error_exit "MACVLAN_IFACE '$MACVLAN_IFACE' does not exist. Check your configuration."
  fi

  if [ "$ENABLE_TS_TO_LOCAL" = "true" ]; then
    [ -n "$DESTINATION_IP_FROM_TS" ] || error_exit "ENABLE_TS_TO_LOCAL=true but DESTINATION_IP_FROM_TS is not set."
    is_ipv4 "$DESTINATION_IP_FROM_TS" || error_exit "DESTINATION_IP_FROM_TS ('$DESTINATION_IP_FROM_TS') is not a valid IPv4 address."
  fi

  if [ "$ENABLE_LOCAL_TO_TS" = "true" ]; then
    [ -n "$TARGET_TS_IP_FROM_LOCAL" ] || error_exit "ENABLE_LOCAL_TO_TS=true but TARGET_TS_IP_FROM_LOCAL is not set."
    is_ipv4 "$TARGET_TS_IP_FROM_LOCAL" || error_exit "TARGET_TS_IP_FROM_LOCAL ('$TARGET_TS_IP_FROM_LOCAL') is not a valid IPv4 address."
    if [ -n "$LISTEN_IP_ON_MACVLAN" ] && ! is_ipv4 "$LISTEN_IP_ON_MACVLAN"; then
      error_exit "LISTEN_IP_ON_MACVLAN ('$LISTEN_IP_ON_MACVLAN') is not a valid IPv4 address."
    fi
    EXCLUDE_PORTS_TCP=$(clean_port_list EXCLUDE_PORTS_TCP "$EXCLUDE_PORTS_TCP")
    EXCLUDE_PORTS_UDP=$(clean_port_list EXCLUDE_PORTS_UDP "$EXCLUDE_PORTS_UDP")
  fi
}

validate_config

if [ "$MODE" = "check" ]; then
  log "Configuration is valid."
  exit 0
fi

log "Using MACVLAN_IFACE: $MACVLAN_IFACE"

# The image's default 'iptables' is the legacy backend, which does not work on
# hosts whose kernel only provides nftables. Fall back to iptables-nft there.
# entrypoint.sh detects this before tailscaled starts and exports TAILFWD_IPTABLES.
# Only legacy is probed here: after tailscaled has written native nftables rules,
# 'iptables-nft -S' fails ("table is incompatible") even though adding rules works.
IPT="${TAILFWD_IPTABLES:-}"
if [ -z "$IPT" ]; then
  IPT="iptables"
  if ! iptables -t nat -S > /dev/null 2>&1 && command -v iptables-nft > /dev/null 2>&1; then
    IPT="iptables-nft"
  fi
fi
log "Using iptables backend: $("$IPT" -V 2>/dev/null || echo "$IPT")"

# --- Wait for the Tailscale IP ---
log "Waiting for Tailscale to fully stabilize and acquire an IP..."

CONTAINER_TS_IP=""
ATTEMPT_COUNT=0
MAX_ATTEMPTS=60
while [ "$ATTEMPT_COUNT" -lt "$MAX_ATTEMPTS" ]; do
  ATTEMPT_COUNT=$((ATTEMPT_COUNT + 1))
  TEMP_IP=$(tailscale ip -4 2>/dev/null | head -n 1 || true)
  if [ -n "$TEMP_IP" ]; then
    if is_ipv4 "$TEMP_IP"; then
      CONTAINER_TS_IP="$TEMP_IP"
      log "Container's Tailscale IP: $CONTAINER_TS_IP"
      break
    fi
    log "Tailscale reported IP '$TEMP_IP', but it does not look like a valid v4 IP. Retrying... (attempt $ATTEMPT_COUNT/$MAX_ATTEMPTS)"
  else
    log "Waiting for Tailscale IP... (attempt $ATTEMPT_COUNT/$MAX_ATTEMPTS)"
  fi
  sleep 1
done

if [ -z "$CONTAINER_TS_IP" ]; then
  log "Current Tailscale status (if available):"
  tailscale status || true
  error_exit "Could not get container's Tailscale IPv4 address after $MAX_ATTEMPTS attempts. Is Tailscale up and authenticated?"
fi

VALID_PEER_PORT=""
if [ -n "$TS_PEER_UDP_PORT" ] && is_port "$TS_PEER_UDP_PORT"; then
  VALID_PEER_PORT="$TS_PEER_UDP_PORT"
fi

if [ "$ENABLE_LOCAL_TO_TS" = "true" ] && [ -z "$LISTEN_IP_ON_MACVLAN" ]; then
  log "LISTEN_IP_ON_MACVLAN not set, attempting to auto-detect from $MACVLAN_IFACE..."
  DETECT_ATTEMPT=0
  MAX_DETECT_ATTEMPTS=10
  while [ -z "$LISTEN_IP_ON_MACVLAN" ] && [ "$DETECT_ATTEMPT" -lt "$MAX_DETECT_ATTEMPTS" ]; do
    DETECT_ATTEMPT=$((DETECT_ATTEMPT + 1))
    LISTEN_IP_ON_MACVLAN=$(ip -4 addr show dev "$MACVLAN_IFACE" 2>/dev/null | awk '/inet / {split($2, a, "/"); print a[1]; exit}' || true)
    if [ -n "$LISTEN_IP_ON_MACVLAN" ]; then
      log "Auto-detected LISTEN_IP_ON_MACVLAN: $LISTEN_IP_ON_MACVLAN"
      break
    fi
    log "Waiting for IP on $MACVLAN_IFACE... (attempt $DETECT_ATTEMPT/$MAX_DETECT_ATTEMPTS)"
    sleep 1
  done
  if [ -z "$LISTEN_IP_ON_MACVLAN" ]; then
    error_exit "Could not auto-detect IP for $MACVLAN_IFACE. Please set LISTEN_IP_ON_MACVLAN or check network config."
  fi
elif [ "$ENABLE_LOCAL_TO_TS" = "true" ]; then
  log "Using provided LISTEN_IP_ON_MACVLAN: $LISTEN_IP_ON_MACVLAN"
fi

# --- Chains ---
log "Preparing TAILFWD chains (built-in chains and tailscaled's ts-* rules are left untouched)..."
setup_chain nat PREROUTING "$CHAIN_NAT_PRE"
setup_chain nat POSTROUTING "$CHAIN_NAT_POST"
setup_chain filter FORWARD "$CHAIN_FWD"
run_cmd "$IPT" -A "$CHAIN_FWD" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
log "Added FORWARD rule: Allow RELATED,ESTABLISHED connections."

if [ "$ENABLE_TS_TO_LOCAL" = "true" ]; then
  log "Configuring Tailscale to Local forwarding..."
  log "Forwarding Tailscale traffic (to $CONTAINER_TS_IP) to Local IP $DESTINATION_IP_FROM_TS via $MACVLAN_IFACE"
  run_cmd "$IPT" -t nat -A "$CHAIN_NAT_PRE" -i "$TAILSCALE_IFACE" -d "$CONTAINER_TS_IP" -j DNAT --to-destination "$DESTINATION_IP_FROM_TS"
  run_cmd "$IPT" -A "$CHAIN_FWD" -i "$TAILSCALE_IFACE" -o "$MACVLAN_IFACE" -d "$DESTINATION_IP_FROM_TS" -m conntrack --ctstate NEW -j ACCEPT
  run_cmd "$IPT" -t nat -A "$CHAIN_NAT_POST" -o "$MACVLAN_IFACE" -d "$DESTINATION_IP_FROM_TS" -j MASQUERADE
  log "Tailscale to Local forwarding configured for $DESTINATION_IP_FROM_TS."
else
  log "Tailscale to Local forwarding is disabled."
fi

if [ "$ENABLE_LOCAL_TO_TS" = "true" ]; then
  log "Configuring Local to Tailscale forwarding..."
  log "Forwarding Local traffic (to $LISTEN_IP_ON_MACVLAN on $MACVLAN_IFACE) to Tailscale IP $TARGET_TS_IP_FROM_LOCAL"

  tcp_exclusions=""
  if [ -n "$EXCLUDE_PORTS_TCP" ]; then
    log "Excluding TCP ports from DNAT: $EXCLUDE_PORTS_TCP"
    tcp_exclusions="-m multiport ! --dports $EXCLUDE_PORTS_TCP"
  fi

  udp_ports="$VALID_PEER_PORT"
  if [ -n "$VALID_PEER_PORT" ]; then
    log "UDP DNAT: Automatically excluding Tailscale daemon port $VALID_PEER_PORT."
  else
    warn "UDP DNAT: TS_PEER_UDP_PORT ('$TS_PEER_UDP_PORT') is not a fixed port. Incoming direct WireGuard connections to this node may be redirected; set a fixed TS_PEER_UDP_PORT to avoid this."
  fi
  if [ -n "$EXCLUDE_PORTS_UDP" ]; then
    log "UDP DNAT: User-defined excluded UDP ports: $EXCLUDE_PORTS_UDP."
    udp_ports="${udp_ports:+$udp_ports,}$EXCLUDE_PORTS_UDP"
  fi

  udp_exclusions=""
  if [ -n "$udp_ports" ]; then
    udp_ports=$(echo "$udp_ports" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')
    log "UDP DNAT: Final list of unique UDP ports to exclude: $udp_ports"
    udp_exclusions="-m multiport ! --dports $udp_ports"
  fi

  # shellcheck disable=SC2086 # exclusion fragments are intentionally word-split
  run_cmd "$IPT" -t nat -A "$CHAIN_NAT_PRE" -p tcp -i "$MACVLAN_IFACE" -d "$LISTEN_IP_ON_MACVLAN" $tcp_exclusions -j DNAT --to-destination "$TARGET_TS_IP_FROM_LOCAL"
  # shellcheck disable=SC2086
  run_cmd "$IPT" -t nat -A "$CHAIN_NAT_PRE" -p udp -i "$MACVLAN_IFACE" -d "$LISTEN_IP_ON_MACVLAN" $udp_exclusions -j DNAT --to-destination "$TARGET_TS_IP_FROM_LOCAL"

  run_cmd "$IPT" -A "$CHAIN_FWD" -i "$MACVLAN_IFACE" -o "$TAILSCALE_IFACE" -d "$TARGET_TS_IP_FROM_LOCAL" -m conntrack --ctstate NEW -j ACCEPT
  run_cmd "$IPT" -t nat -A "$CHAIN_NAT_POST" -o "$TAILSCALE_IFACE" -d "$TARGET_TS_IP_FROM_LOCAL" -j MASQUERADE
  log "Local to Tailscale forwarding configured for $TARGET_TS_IP_FROM_LOCAL."
else
  log "Local to Tailscale forwarding is disabled."
fi

if [ "$ENABLE_EXIT_NODE" = "true" ]; then
  log "Configuring Exit Node forwarding..."

  log "Allowing traffic forwarding from Tailscale to internet via $MACVLAN_IFACE"
  run_cmd "$IPT" -A "$CHAIN_FWD" -i "$TAILSCALE_IFACE" -o "$MACVLAN_IFACE" -m conntrack --ctstate NEW -j ACCEPT

  log "Masquerading outgoing internet traffic from Tailscale"
  run_cmd "$IPT" -t nat -A "$CHAIN_NAT_POST" -o "$MACVLAN_IFACE" -j MASQUERADE
  log "Exit Node forwarding configured successfully."
else
  log "Exit Node forwarding is disabled."
fi

log "IPTables configuration complete. Forwarder should be active."
