# Tailscale Docker Forwarder (`menggatot/tailforwarder`)

This Docker image allows you to forward network traffic between your local LAN and your Tailscale network, or vice-versa, by running one or more container instances. Each instance utilizes a macvlan network to obtain its own IP address on your LAN and employs `iptables` for granular traffic control based on its configured scenario.

---

**Source code and issues:** [https://github.com/menggatot/tailforwarder](https://github.com/menggatot/tailforwarder)

## Features

*   **Multiple Forwarding Scenarios via Separate Instances**:
    *   **LAN to Tailscale Forwarding**: Access Tailscale nodes (100.x.y.z) or IPs within advertised Tailscale routes from your local network via a dedicated container instance's LAN IP.
    *   **Tailscale to LAN Forwarding**: Expose services on your local LAN to your Tailscale network via a dedicated container instance's Tailscale IP.
    *   **Exit Node**: Use the container as a Tailscale exit node to route all internet traffic from Tailscale clients through the container's network interface.
*   **Survives Auth Key Expiry**: The auth key is only used for the first login. Restarts reuse the node identity stored in the state volume, so a container keeps working after its 90-day auth key has expired. OAuth client secrets, which never expire, are supported for unattended re-authentication.
*   **Flexible Configuration**: Control forwarding rules and Tailscale settings per instance via environment variables in `docker-compose.yml`.
*   **Macvlan Integration**: Each instance operates with a dedicated IP address on your LAN.
*   **Persistent Tailscale State**: Each instance saves its Tailscale node identity in a dedicated volume.
*   **Port Exclusion**: Specify TCP/UDP ports or port ranges to exclude from LAN-to-Tailscale forwarding.
*   **Safe Startup**: The configuration is validated before Tailscale logs in, and a clear error is printed (instead of hanging or looping silently) when something is wrong. The auth key is never written to the logs.
*   **Health Check**: Docker reports the container as `unhealthy` when Tailscale is not connected.
*   **iptables and nftables Hosts**: Works on hosts with legacy iptables as well as on nftables-only kernels.

## Prerequisites for Host

*   Docker and Docker Compose installed.
*   A Tailscale account and an auth key or, preferably, an OAuth client secret (see *Authentication and Key Expiry* below).
*   Knowledge of your host's physical LAN interface name (e.g., `eth0`).
*   An available static IP address on your LAN for the container.

## How to Use with Docker Compose

Below is an example `docker-compose.yml` for running multiple instances, each for a different scenario.

```yaml
version: '3.8'

services:
  tailforwarder-one: # Scenario: Local LAN to a specific Tailscale IP
    image: menggatot/tailforwarder:latest
    container_name: tailforwarder-one
    hostname: tailforwarder-one
    restart: unless-stopped
    cap_add: [NET_ADMIN]
    devices: ["/dev/net/tun:/dev/net/tun"]
    sysctls:
      net.ipv4.ip_forward: 1
      net.ipv6.conf.all.forwarding: 1
    environment:
      - TS_AUTHKEY=${TS_AUTHKEY:-} # From .env file (only used for first login / re-login)
      - TS_HOSTNAME=tailforwarder-one
      # - TS_TAGS=tag:tailforwarder # Required when TS_AUTHKEY is an OAuth client secret
      - TS_USERSPACE=false
      - TS_STATE_DIR=/var/lib/tailscale
      - TS_ACCEPT_ROUTES=false
      - MACVLAN_IFACE=eth0
      - TS_PEER_UDP_PORT=41641 # Unique port
      - ENABLE_LOCAL_TO_TS=true
      - LISTEN_IP_ON_MACVLAN=10.10.0.10 # This instance's LAN IP
      - TARGET_TS_IP_FROM_LOCAL=100.x.y.z # Target Tailscale IP
      - ENABLE_TS_TO_LOCAL=false
    volumes:
      - ./tailscale_state_one:/var/lib/tailscale # Unique state volume
    networks:
      macvlan_net:
        ipv4_address: 10.10.0.10 # Static LAN IP for this instance

  tailforwarder-two: # Scenario: Local LAN to an IP in an advertised Tailscale route
    image: menggatot/tailforwarder:latest
    container_name: tailforwarder-two
    hostname: tailforwarder-two
    restart: unless-stopped
    cap_add: [NET_ADMIN]
    devices: ["/dev/net/tun:/dev/net/tun"]
    sysctls:
      net.ipv4.ip_forward: 1
      net.ipv6.conf.all.forwarding: 1
    environment:
      - TS_AUTHKEY=${TS_AUTHKEY:-} # From .env file (only used for first login / re-login)
      - TS_HOSTNAME=tailforwarder-two
      # - TS_TAGS=tag:tailforwarder
      - TS_USERSPACE=false
      - TS_STATE_DIR=/var/lib/tailscale
      - TS_ACCEPT_ROUTES=true # Required for this scenario
      - MACVLAN_IFACE=eth0
      - TS_PEER_UDP_PORT=41642 # Unique port
      - ENABLE_LOCAL_TO_TS=true
      - LISTEN_IP_ON_MACVLAN=10.10.0.20 # This instance's LAN IP
      - TARGET_TS_IP_FROM_LOCAL=192.168.A.B # Target IP in an advertised TS subnet
      - ENABLE_TS_TO_LOCAL=false
    volumes:
      - ./tailscale_state_two:/var/lib/tailscale # Unique state volume
    networks:
      macvlan_net:
        ipv4_address: 10.10.0.20 # Static LAN IP for this instance

  tailforwarder-three: # Scenario: Tailscale Network to a specific Local LAN IP
    image: menggatot/tailforwarder:latest
    container_name: tailforwarder-three
    hostname: tailforwarder-three
    restart: unless-stopped
    cap_add: [NET_ADMIN]
    devices: ["/dev/net/tun:/dev/net/tun"]
    sysctls:
      net.ipv4.ip_forward: 1
      net.ipv6.conf.all.forwarding: 1
    environment:
      - TS_AUTHKEY=${TS_AUTHKEY:-} # From .env file (only used for first login / re-login)
      - TS_HOSTNAME=tailforwarder-three
      # - TS_TAGS=tag:tailforwarder
      - TS_USERSPACE=false
      - TS_STATE_DIR=/var/lib/tailscale
      - MACVLAN_IFACE=eth0
      - TS_PEER_UDP_PORT=41643 # Unique port
      - ENABLE_TS_TO_LOCAL=true
      - DESTINATION_IP_FROM_TS=10.10.0.50 # Target local device IP
      - ENABLE_LOCAL_TO_TS=false
    volumes:
      - ./tailscale_state_three:/var/lib/tailscale # Unique state volume
    networks:
      macvlan_net:
        ipv4_address: 10.10.0.30 # Static LAN IP for this instance

  tailforwarder-exit: # Scenario: Exit Node for routing internet traffic
    image: menggatot/tailforwarder:latest
    container_name: tailforwarder-exit
    hostname: tailforwarder-exit
    restart: unless-stopped
    cap_add: [NET_ADMIN]
    devices: ["/dev/net/tun:/dev/net/tun"]
    sysctls:
      net.ipv4.ip_forward: 1
      net.ipv6.conf.all.forwarding: 1
    environment:
      - TS_AUTHKEY=${TS_AUTHKEY:-} # From .env file (only used for first login / re-login)
      - TS_HOSTNAME=tailforwarder-exit
      # - TS_TAGS=tag:tailforwarder
      - TS_USERSPACE=false
      - TS_STATE_DIR=/var/lib/tailscale
      - TS_ACCEPT_DNS=true # Optional: Accept Tailscale DNS configuration
      - MACVLAN_IFACE=eth0
      - TS_PEER_UDP_PORT=41644 # Unique port
      - ENABLE_EXIT_NODE=true # Also adds --advertise-exit-node automatically
      - ENABLE_LOCAL_TO_TS=false
      - ENABLE_TS_TO_LOCAL=false
    volumes:
      - ./tailscale_state_exit:/var/lib/tailscale # Unique state volume
    networks:
      macvlan_net:
        ipv4_address: 10.10.0.40 # Static LAN IP for this instance

networks:
  macvlan_net:
    driver: macvlan
    driver_opts:
      parent: eth0 # IMPORTANT: Change 'eth0' to your host's physical LAN interface
    ipam:
      config:
        - subnet: 10.10.0.0/24   # IMPORTANT: Adjust to your LAN's subnet
          gateway: 10.10.0.1    # IMPORTANT: Adjust to your LAN's gateway
          # ip_range: 10.10.0.160/28 # Optional: if you want Docker to pick from a pool, but static is recommended per service.

# You would also create corresponding state directories on your host:
# ./tailscale_state_one
# ./tailscale_state_two
# ./tailscale_state_three
# ./tailscale_state_exit
```

Create a `.env` file in the same directory as your `docker-compose.yml`. This file is primarily for your `TS_AUTHKEY`:

```env
# .env file
# --- Tailscale Authentication ---
# Used by all tailforwarder instances, only for their first login (and re-login
# after node key expiry). Prefer an OAuth client secret (tskey-client-...), which
# does not expire; it requires TS_TAGS to be set on each service.
TS_AUTHKEY=tskey-client-your-oauth-client-secret
# or a regular auth key:
# TS_AUTHKEY=tskey-auth-your-auth-key

# Other variables like TS_HOSTNAME, TS_ROUTES, etc., are set
# per-service directly in the docker-compose.yml file if needed.
```

**Important `docker-compose.yml` notes:**
*   The image `menggatot/tailforwarder:latest` is used.
*   Adjust `macvlan_net` settings (`parent`, `subnet`, `gateway`) to match your host and LAN configuration.
*   Each service instance (`tailforwarder-one`, `tailforwarder-two`, etc.) **must have a unique `ipv4_address`** on the `macvlan_net`.
*   Each service instance **should have a unique `TS_PEER_UDP_PORT`** if running on the same Docker host.
*   Each service instance **must have a unique volume path** for `TS_STATE_DIR` (e.g., `./tailscale_state_one`, `./tailscale_state_two`) to maintain separate Tailscale node identities. These directories contain the nodes' private keys; keep them out of version control.
*   If you use an OAuth client secret, uncomment `TS_TAGS` on every service.
*   Instance-specific configurations (like target IPs, enabled scenarios) are set directly in the `environment` section of each service.

## Authentication and Key Expiry

`TS_AUTHKEY` is only used when a node has to log in: on its first start, or after its node key has expired or the device was removed from the tailnet. On every other restart the container reconnects with the identity stored in its state volume, so an expired auth key does **not** stop an already registered container from starting.

There are two different expiry times to be aware of:

*   **Auth key expiry** (at most 90 days): after this, the key can no longer be used to *log in*. Already registered nodes are not affected.
*   **Node key expiry** (180 days by default for devices that are not tagged): after this, the node itself is logged out and needs a valid key to log in again.

To keep containers able to re-authenticate unattended:

*   **Recommended: use an OAuth client secret** (`tskey-client-...`) as `TS_AUTHKEY`. It does not expire.
    1.  Make sure the tag you want to use (e.g. `tag:tailforwarder`) is defined in `tagOwners` in your access control policy.
    2.  In the admin console go to **Settings → Trust credentials** (OAuth clients) and create a client with the **Auth Keys** write scope and that tag.
    3.  Put the client secret in `TS_AUTHKEY` and set `TS_TAGS=tag:tailforwarder` on each service.

    The container registers the node as non-ephemeral automatically (by appending `?ephemeral=false` to the secret). If device approval is enabled on your tailnet, append the parameters yourself, e.g. `tskey-client-xxxx?preauthorized=true&ephemeral=false`. Tagged devices also have node key expiry disabled by default.
*   **With a regular auth key** (`tskey-auth-...`): make it **reusable** if several instances share it, do **not** make it ephemeral, and disable key expiry for the forwarder devices in the admin console. Otherwise, when a device's node key expires, it needs a fresh auth key to log in again.
*   **Always persist `TS_STATE_DIR` in a volume.** Without it, every container recreation is a new login. The container prints a warning at startup if the state directory is not a mounted volume.
*   **`TS_AUTHKEY_FILE`** can point to a file containing the key (e.g. a Docker secret) instead of passing it in the environment.

If a login is needed and no valid key is available, the container exits with a clear error message instead of hanging. The image also has a `HEALTHCHECK`, so `docker compose ps` shows `unhealthy` when Tailscale is not connected.

## Environment Variables Explained

The main configuration is done via environment variables. `TS_AUTHKEY` is global (set in `.env`), while most other variables are configured per instance within the `docker-compose.yml`.

### Global Configuration (typically in `.env` file)
*   `TS_AUTHKEY`: Your Tailscale auth key or OAuth client secret. Required for the first login of each instance; afterwards the identity stored in the state volume is used, so the key may expire without breaking restarts.
*   `TS_AUTHKEY_FILE`: Optional. Path to a file containing the key (e.g. a Docker secret). Takes precedence over `TS_AUTHKEY`.

### Per-Instance Configuration (in `docker-compose.yml` for each service)

#### Core Tailscale Settings (for each instance)
*   `TS_HOSTNAME`: The hostname this specific container instance will use on the Tailscale network (e.g., `tailforwarder-one`). Default: `tailforwarder`.
*   `TS_ACCEPT_ROUTES`: Set to `true` if this instance should accept routes advertised by other nodes on your Tailscale network. Necessary for forwarding traffic to IPs within those advertised routes.
*   `TS_ACCEPT_DNS`: Set to `true` to accept Tailscale's DNS configuration. Default: `false`. When enabled, the container will use Tailscale's DNS servers (including MagicDNS). Leave as `false` (default) for most forwarding scenarios.
*   `TS_USERSPACE`: Must be `false` (the default). The iptables forwarding requires kernel mode; `true` is ignored with a warning.
*   `TS_STATE_DIR`: Directory inside the container for Tailscale state. Default: `/var/lib/tailscale`. Mapped to a unique persistent host volume per instance.
*   `TS_PEER_UDP_PORT`: Specifies the UDP port `tailscaled` for this instance should listen on. **Must be unique per instance on the same host.** Example: `41641`. `0`, `auto` or unset lets `tailscaled` pick a port. A fixed port is recommended for `ENABLE_LOCAL_TO_TS` instances, because it is automatically excluded from UDP forwarding.
*   `TS_ROUTES` (or `TS_ROUTES_ADVERTISE`): Comma-separated list of local subnets this instance should advertise to your Tailscale network.
*   `TS_TAGS` (or `TS_TAGS_ADVERTISE`): Comma-separated list of tags to apply to this instance on Tailscale. Required when `TS_AUTHKEY` is an OAuth client secret.
*   `TS_EXTRA_ARGS`: Allows passing additional flags to the `tailscale up` command for this instance. Do not put the auth key here; the container refuses to start if you do.
*   `TS_UP_TIMEOUT`: How long `tailscale up` may take before the container gives up and exits. Default: `60s`.

#### Network Configuration (for `iptables-config.sh`, per instance)
*   `MACVLAN_IFACE`: The name of the macvlan network interface *inside the container*. Default: `eth0`.

#### Scenario-Specific Variables (per instance)
*   `ENABLE_LOCAL_TO_TS`: Set to `true` to enable forwarding from your Local LAN (via this instance's macvlan IP) to Tailscale.
    *   `LISTEN_IP_ON_MACVLAN`: The macvlan IP of *this* container instance. Traffic from LAN to this IP gets forwarded. Must match the `ipv4_address` for this service. If unset, it is auto-detected from `MACVLAN_IFACE`.
    *   `TARGET_TS_IP_FROM_LOCAL`: **(Required)** The destination IP on the Tailscale network (a direct Tailscale node IP like `100.x.y.z`, or an IP within an advertised subnet like `192.168.A.B`).
    *   `EXCLUDE_PORTS_TCP`: Comma-separated TCP ports or ranges to *exclude* from this forwarding rule (e.g. `22,8000:8100`). At most 15 ports, where a range counts as two.
    *   `EXCLUDE_PORTS_UDP`: Comma-separated UDP ports or ranges to *exclude* from this forwarding rule. `TS_PEER_UDP_PORT` is excluded automatically.
*   `ENABLE_TS_TO_LOCAL`: Set to `true` to enable forwarding from the Tailscale network (to this instance's Tailscale IP) to a specific IP on your Local LAN.
    *   `DESTINATION_IP_FROM_TS`: **(Required)** The actual IP address of the target device on your local LAN that you want to expose to Tailscale.
*   `ENABLE_EXIT_NODE`: Set to `true` to configure the container as a Tailscale exit node.
    *   When enabled, all internet traffic from Tailscale clients using this exit node will be routed through the container's network interface.
    *   `--advertise-exit-node` is added to `tailscale up` automatically.
    *   `TS_ACCEPT_DNS`: Optionally set to `true` to accept Tailscale's DNS configuration.
    *   `ENABLE_LOCAL_TO_TS` and `ENABLE_TS_TO_LOCAL`: Should both be set to `false` when using exit node mode.

Only one of `ENABLE_LOCAL_TO_TS`, `ENABLE_TS_TO_LOCAL` and `ENABLE_EXIT_NODE` may be `true` per instance; the container refuses to start if more than one is enabled. Run a separate instance for each scenario.

## Troubleshooting

Check the logs with `docker compose logs <service-name>`. Common messages:

| Message | Cause and fix |
| --- | --- |
| `This node needs to log in, but neither TS_AUTHKEY nor TS_AUTHKEY_FILE is set.` | First start, or the node key expired / the device was removed. Set a valid `TS_AUTHKEY`. |
| `'tailscale up' with the auth key failed. The key may be expired, revoked, already used ...` | The key cannot be used to log in. Create a new key, preferably an OAuth client secret. For OAuth secrets, check that `TS_TAGS` matches the client's tags. |
| `... waiting for approval in the Tailscale admin console` | Device approval is enabled on your tailnet. Approve the device, or use a pre-authorized key. |
| `Could not connect to Tailscale with the existing node identity.` | The control server could not be reached within `TS_UP_TIMEOUT`. Check internet access and DNS. Docker restarts the container and it retries without using the auth key. |
| `Forwarding configuration is invalid.` | The lines above it name the variable that is wrong (e.g. an invalid IP or port, or more than one scenario enabled). |
| `tailscaled exited during startup.` | `/dev/net/tun` is missing or `NET_ADMIN` was not granted. |

The forwarding rules live in dedicated chains, which you can inspect with `docker exec <container> iptables -t nat -S TAILFWD-PREROUTING`, `... -t nat -S TAILFWD-POSTROUTING` and `... -S TAILFWD-FORWARD` (use `iptables-nft` on nftables-only hosts).

## Upgrading From Earlier Versions

Existing state directories keep working; no re-login is needed. Note these behavior changes:

*   `TS_AUTHKEY` is no longer required once a node is registered, and an expired auth key no longer prevents the container from starting.
*   `tailscale up` now runs with `--reset`, so the environment variables are the single source of truth. Settings changed by hand inside the container (e.g. with `tailscale set`) are reset on every start.
*   An auth key passed via `TS_EXTRA_ARGS` is rejected. Move it to `TS_AUTHKEY`.
*   `ENABLE_EXIT_NODE=true` adds `--advertise-exit-node` by itself. Keeping it in `TS_EXTRA_ARGS` as well is harmless.
*   `TS_ROUTES` with several subnets now advertises all of them (previously only the last one was advertised).
*   Forwarding rules now live in the `TAILFWD-*` chains instead of directly in the built-in chains, which are no longer flushed. This keeps the rules `tailscaled` installs itself intact.
