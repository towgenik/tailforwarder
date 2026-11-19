# Tailscale Docker Forwarder

This project provides a Dockerized solution for forwarding network traffic between your local LAN and your Tailscale network, or vice-versa. It uses a macvlan network for each container instance to have its own IP on your LAN and utilizes `iptables` for fine-grained traffic manipulation. This setup allows running multiple forwarder instances, each configured for a distinct scenario.

**Docker Hub:** [menggatot/tailforwarder](https://hub.docker.com/r/menggatot/tailforwarder)

## Features

*   **Multiple Forwarding Scenarios**: Run separate container instances for different forwarding rules:
    *   **LAN to Tailscale Forwarding**: Access specific Tailscale node IPs (100.x.y.z) from your local network.
    *   **LAN to Advertised Tailscale Route**: Access IPs within routes advertised by other Tailscale nodes from your local network.
    *   **Tailscale to LAN Forwarding**: Expose services on your local LAN to your Tailscale network.
    *   **Exit Node**: Use the container as a Tailscale exit node to route all internet traffic from Tailscale clients through the container's network interface.
*   **Survives Auth Key Expiry**: The auth key is only used for the first login. Restarts reuse the node identity stored in the state volume, so a container keeps working after its 90-day auth key has expired. OAuth client secrets, which never expire, are supported for unattended re-authentication.
*   **Flexible Configuration**: Uses environment variables within `docker-compose.yml` to control forwarding rules, Tailscale settings (hostname, advertised routes/tags, accept routes), and `iptables` behavior per instance.
*   **Macvlan Integration**: Each instance operates with its own dedicated IP address on your LAN for seamless routing.
*   **Persistent Tailscale State**: Each instance saves its Tailscale node identity and state in a dedicated volume.
*   **Customizable Port Exclusion**: Specify TCP/UDP ports or port ranges to exclude from LAN-to-Tailscale forwarding rules.
*   **Safe Startup**: The configuration is validated before Tailscale logs in, and a clear error is printed (instead of hanging or looping silently) when something is wrong.
*   **Health Check**: Docker reports the container as `unhealthy` when Tailscale is not connected.
*   **iptables and nftables Hosts**: Works on hosts with legacy iptables as well as on nftables-only kernels.
*   **Detailed Logging**: Scripts provide informative logs for setup and troubleshooting. The auth key is never written to the logs.

## Prerequisites

*   **Docker and Docker Compose:** Ensure Docker and Docker Compose are installed on your host machine (e.g., a Raspberry Pi, Linux server).
*   **Tailscale Account & Auth Key:** You'll need a Tailscale account and an auth key or, preferably, an OAuth client secret (`TS_AUTHKEY`) to authenticate the container as a Tailscale node. See [Authentication and Key Expiry](#authentication-and-key-expiry).
*   **Host Physical Interface:** Identify the name of the physical network interface on your host machine connected to your LAN (e.g., `eth0`, `enp3s0`). This is crucial for the macvlan configuration.
*   **Available LAN IP:** Choose a static IP address on your LAN that is *not* currently in use and is outside your DHCP server's dynamic assignment range (or has a DHCP reservation). This IP will be assigned to the forwarder container.
*   **Understanding of LAN Configuration:** Basic knowledge of your LAN's subnet, gateway IP, and DNS settings.

## Directory Structure

```
.
├── docker-compose.yml     # Docker Compose configuration for multiple instances
├── Dockerfile             # Defines the custom Docker image
├── entrypoint.sh          # Starts tailscaled, logs in / reconnects, runs iptables-config.sh
├── iptables-config.sh     # Validates the configuration and configures iptables rules
├── .env.example           # Example environment file (primarily for TS_AUTHKEY)
├── .dockerignore          # Keeps .env and state directories out of image builds
├── tailscale_state_one/   # Example directory to persist Tailscale state for instance 'one'
├── tailscale_state_two/   # Example directory to persist Tailscale state for instance 'two'
├── tailscale_state_three/ # Example directory to persist Tailscale state for instance 'three'
└── README.md              # This file
```

The `tailscale_state_*` directories contain each node's private keys. They are created on first start and are ignored by git.

## Installation and Setup

This guide assumes you will use the prebuilt image from Docker Hub.

1.  **Clone or Download:**
    If this project is in a Git repository:
    ```bash
    git clone <repository_url>
    cd <repository_directory>
    ```
    Or simply download the `docker-compose.yml` and `.env.example` files into a directory on your host.

2.  **Configure Global Environment Variables (primarily `TS_AUTHKEY`):**
    Copy the example environment file:
    ```bash
    cp .env.example .env
    ```
    Edit `.env` and set your `TS_AUTHKEY`. An OAuth client secret is recommended because it never expires:
    ```env
    # .env
    TS_AUTHKEY=tskey-client-your-oauth-client-secret
    ```
    A regular auth key also works:
    ```env
    # .env
    TS_AUTHKEY=tskey-auth-your-auth-key
    ```
    This `TS_AUTHKEY` will be used by all forwarder instances defined in `docker-compose.yml`. It is only needed for the first login of each instance (and re-login after node key expiry). See [Authentication and Key Expiry](#authentication-and-key-expiry) for how to create the key and which options to choose.

3.  **Configure `docker-compose.yml`:**
    Open `docker-compose.yml`. The provided file is already structured for multiple instances (e.g., `tailforwarder-one`, `tailforwarder-two`, `tailforwarder-three`). You will need to:
    *   **Review Each Service Definition:**
        *   Adjust `hostname`, `container_name`, and `TS_HOSTNAME` if desired (though the defaults are usually fine).
        *   If you use an OAuth client secret, uncomment `TS_TAGS` and set it to the tag(s) of your OAuth client (e.g. `TS_TAGS=tag:tailforwarder`).
        *   Ensure `TS_PEER_UDP_PORT` is unique for each service instance if they are running on the same host.
        *   Set the correct `ipv4_address` under `networks.macvlan_net` for each service. This IP must be unique on your LAN and suitable for your network configuration.
        *   Modify the scenario-specific environment variables for each service:
            *   For `ENABLE_LOCAL_TO_TS=true` instances (like `tailforwarder-one`, `tailforwarder-two`):
                *   Set `LISTEN_IP_ON_MACVLAN` to the same IP as `ipv4_address` for that service (or leave it unset to auto-detect it).
                *   Set `TARGET_TS_IP_FROM_LOCAL` to the target Tailscale IP or an IP in an advertised Tailscale route.
                *   For `tailforwarder-two` (LAN to advertised route), ensure `TS_ACCEPT_ROUTES=true`.
            *   For `ENABLE_TS_TO_LOCAL=true` instances (like `tailforwarder-three`):
                *   Set `DESTINATION_IP_FROM_TS` to the target local LAN IP you want to expose.
        *   Ensure the `volumes` path (e.g., `./tailscale_state_one`) is unique for each service to maintain separate Tailscale states.
    *   **Macvlan Network Configuration:**
        *   Adjust the `parent` interface in `networks.macvlan_net.driver_opts` to your host's physical LAN interface (e.g., `eth0`, `enp3s0`).
        *   Configure the `subnet` and `gateway` in `networks.macvlan_net.ipam.config` to match your LAN settings.

4.  **Start the Containers:**
    From the directory containing your `docker-compose.yml` and `.env` files, run:
    ```bash
    docker compose up -d
    ```

## Usage

Once the containers are running and Tailscale is connected in each:

*   **To check logs for a specific instance (e.g., `tailforwarder-one`):**
    ```bash
    docker compose logs -f tailforwarder-one
    ```
    On the first start you should see `No valid node identity found ... Authentication is required.` followed by a login with the auth key. On later starts you should see `Found an existing node identity ... Reconnecting with it (auth key not used).` Then `iptables-config.sh` applies its rules and the log ends with `Setup complete.`

*   **To check the health of all instances:**
    ```bash
    docker compose ps
    ```
    The `STATUS` column shows `healthy` while Tailscale is connected and `unhealthy` when it is not (for example when the node needs to log in again).

*   **Scenario Example: `tailforwarder-one` (Local LAN to specific Tailscale Node)**
    Assuming `tailforwarder-one` is configured with:
    *   `LISTEN_IP_ON_MACVLAN=10.10.0.10`
    *   `TARGET_TS_IP_FROM_LOCAL=100.x.y.z` (replace with actual Tailscale IP)
    *   If `100.x.y.z` has an SSH server on port 22, you can SSH to it from your LAN via `user@10.10.0.10`.

*   **Scenario Example: `tailforwarder-two` (Local LAN to Advertised Tailscale Route)**
    Assuming `tailforwarder-two` is configured with:
    *   `LISTEN_IP_ON_MACVLAN=10.10.0.20`
    *   `TARGET_TS_IP_FROM_LOCAL=192.168.A.B` (replace with an IP in an advertised route from another Tailscale node)
    *   `TS_ACCEPT_ROUTES=true`
    *   Devices on your LAN can access `192.168.A.B` by sending traffic to `10.10.0.20`.

*   **Scenario Example: `tailforwarder-three` (Tailscale to Local LAN)**
    Assuming `tailforwarder-three` is configured with:
    *   `TS_HOSTNAME=tailforwarder-three` (its Tailscale IP will be associated with this)
    *   `DESTINATION_IP_FROM_TS=10.10.0.50` (replace with actual local device IP)
    *   If `10.10.0.50` has a web server on port 80, devices on your Tailscale network can access it by browsing to `http://tailforwarder-three` (or its Tailscale IP).

*   **Scenario Example: Exit Node**
    Assuming an exit node instance is configured with:
    *   `ENABLE_EXIT_NODE=true` (this also adds `--advertise-exit-node` to `tailscale up` automatically)
    *   `ENABLE_LOCAL_TO_TS=false`
    *   `ENABLE_TS_TO_LOCAL=false`
    *   Optionally, `TS_ACCEPT_DNS=true` to accept Tailscale's DNS configuration
    *   Tailscale clients can use this container as an exit node to route all their internet traffic through the container's network interface, appearing to the internet with the container's public IP address. Depending on your tailnet settings, you may need to approve the exit node in the Tailscale admin console.

## Authentication and Key Expiry

`TS_AUTHKEY` is only used when a node has to log in: on its first start, or after its node key has expired or the device was removed from the tailnet. On every other restart the container reconnects with the identity stored in its state volume, so an expired auth key does **not** stop an already registered container from starting.

There are two different expiry times to be aware of:

*   **Auth key expiry** (at most 90 days): after this, the key can no longer be used to *log in*. Already registered nodes are not affected.
*   **Node key expiry** (180 days by default for devices that are not tagged): after this, the node itself is logged out and needs a valid key to log in again.

To keep containers able to re-authenticate unattended:

*   **Recommended: use an OAuth client secret** (`tskey-client-...`) as `TS_AUTHKEY`. It does not expire.
    1.  In the Tailscale admin console, make sure the tag you want to use (e.g. `tag:tailforwarder`) is defined in `tagOwners` in your access control policy.
    2.  Go to **Settings → Trust credentials** (OAuth clients) and create a client with the **Auth Keys** write scope and that tag.
    3.  Put the client secret in `TS_AUTHKEY` and set `TS_TAGS=tag:tailforwarder` on each service.

    The container registers the node as non-ephemeral automatically (by appending `?ephemeral=false` to the secret). If device approval is enabled on your tailnet, append `?preauthorized=true` yourself, e.g. `TS_AUTHKEY=tskey-client-xxxx?preauthorized=true&ephemeral=false`. Tagged devices also have node key expiry disabled by default.
*   **With a regular auth key** (`tskey-auth-...`): make it **reusable** if several instances share it, do **not** make it ephemeral (an ephemeral node is deleted when it goes offline), and disable key expiry for the forwarder devices in the admin console (**Machines → ... → Disable key expiry**). Otherwise, when a device's node key expires, it needs a fresh auth key to log in again.
*   **Always persist `TS_STATE_DIR` in a volume.** Without it, every container recreation is a new login. The container prints a warning at startup if the state directory is not a mounted volume.
*   **`TS_AUTHKEY_FILE`** can point to a file containing the key (e.g. a Docker secret) instead of passing it in the environment.

If a login is needed and no valid key is available, the container exits with a clear error message instead of hanging. Once you provide a valid key (and recreate the container with `docker compose up -d`), it logs in again and keeps its forwarding configuration.

## How It Works

On every start, `entrypoint.sh`:

1.  Validates the forwarding configuration (scenario flags, IP addresses, port lists, interface name). An invalid configuration stops the container *before* any auth key is used.
2.  Starts `tailscaled` with the state directory and, if set, the fixed `TS_PEER_UDP_PORT`. On nftables-only hosts it switches `tailscaled` and the forwarding rules to nftables automatically.
3.  Runs `tailscale up --reset` with the settings from the environment variables. `--reset` means the environment variables are the single source of truth: settings removed from `docker-compose.yml` are also removed from the node.
    *   If a valid node identity exists in the state directory, it reconnects **without** the auth key.
    *   If the node needs to log in, it uses `TS_AUTHKEY` / `TS_AUTHKEY_FILE`.
4.  Runs `iptables-config.sh`, which puts all of its rules in dedicated `TAILFWD-PREROUTING`, `TAILFWD-POSTROUTING` (nat table) and `TAILFWD-FORWARD` (filter table) chains. The built-in chains and the `ts-*` rules that `tailscaled` installs itself are left untouched.
5.  Waits for `tailscaled`. When Docker stops the container, `tailscaled` is shut down cleanly.

## Environment Variables Overview

The primary method for configuration is through environment variables set directly in the `docker-compose.yml` file for each service, and `TS_AUTHKEY` set in the `.env` file.

### Global (from `.env` file)
*   `TS_AUTHKEY`: Your Tailscale auth key or OAuth client secret. Required for the first login of each instance; afterwards the stored identity is used. Used by all instances.
*   `TS_AUTHKEY_FILE`: Optional. Path to a file containing the key (e.g. a Docker secret). Takes precedence over `TS_AUTHKEY`.

### Per-Instance (in `docker-compose.yml` under each service's `environment` section)

#### Core Tailscale Configuration (per instance)
*   `TS_HOSTNAME`: The hostname this specific container instance will use on the Tailscale network (e.g., `tailforwarder-one`). Default: `tailforwarder`.
*   `TS_ACCEPT_ROUTES`: Set to `true` if this instance should accept routes advertised by other Tailscale nodes. Essential for "LAN to Advertised Tailscale Route" scenarios.
*   `TS_ACCEPT_DNS`: Set to `true` to accept Tailscale's DNS configuration. Default: `false`. When enabled, the container will use Tailscale's DNS servers (including MagicDNS). Leave as `false` (default) for most forwarding scenarios.
*   `TS_USERSPACE`: Must be `false` (the default). The iptables forwarding requires kernel mode; `true` is ignored with a warning.
*   `TS_STATE_DIR`: Default `/var/lib/tailscale`. Mapped to a unique host volume for each instance.
*   `TS_PEER_UDP_PORT`: A unique UDP port for each `tailscaled` instance if running multiple on the same host Docker engine (e.g., `41641`, `41642`, `41643`). `0`, `auto` or unset lets `tailscaled` pick a port. A fixed port is recommended for `ENABLE_LOCAL_TO_TS` instances, because it is automatically excluded from UDP forwarding.
*   `TS_ROUTES` (formerly `TS_ROUTES_ADVERTISE`): Comma-separated local subnets this instance should advertise to Tailscale (e.g. `192.168.1.0/24,10.0.0.0/24`).
*   `TS_TAGS` (formerly `TS_TAGS_ADVERTISE`): Comma-separated tags for this instance on Tailscale. Required when `TS_AUTHKEY` is an OAuth client secret.
*   `TS_EXTRA_ARGS`: Additional flags for the `tailscale up` command for this instance. Do not put the auth key here; the container refuses to start if you do.
*   `TS_UP_TIMEOUT`: How long `tailscale up` may take before the container gives up and exits. Default `60s`.

#### Network Configuration (for `iptables-config.sh`, per instance)
*   `MACVLAN_IFACE`: The macvlan interface inside the container. Default `eth0`.

#### Scenario Configuration (per instance)

*   **For "Local LAN to Tailscale" (either direct or via advertised route):**
    *   `ENABLE_LOCAL_TO_TS`: Set to `true`.
    *   `LISTEN_IP_ON_MACVLAN`: The macvlan IP of *this* container instance (e.g., `10.10.0.10`). Traffic from your LAN to this IP will be forwarded. If unset, it is auto-detected from `MACVLAN_IFACE`.
    *   `TARGET_TS_IP_FROM_LOCAL`: **(Required)** The destination IP on the Tailscale network (e.g., `100.x.y.z` or an IP in an advertised subnet like `192.168.A.B`).
    *   `EXCLUDE_PORTS_TCP`: Comma-separated TCP ports or ranges to *exclude* from forwarding (e.g. `22,8000:8100`). At most 15 ports, where a range counts as two.
    *   `EXCLUDE_PORTS_UDP`: Comma-separated UDP ports or ranges to *exclude* from forwarding. `TS_PEER_UDP_PORT` is excluded automatically.
*   **For "Tailscale to Local LAN":**
    *   `ENABLE_TS_TO_LOCAL`: Set to `true`.
    *   `DESTINATION_IP_FROM_TS`: **(Required)** The actual IP address of the target device on your local LAN (e.g., `10.10.0.50`). Traffic sent to this container's Tailscale IP will be forwarded to this local IP.
*   **For "Exit Node":**
    *   `ENABLE_EXIT_NODE`: Set to `true` to configure the container as a Tailscale exit node.
    *   `--advertise-exit-node` is added to `tailscale up` automatically.
    *   `ENABLE_LOCAL_TO_TS`: Set to `false`.
    *   `ENABLE_TS_TO_LOCAL`: Set to `false`.

Only one of `ENABLE_LOCAL_TO_TS`, `ENABLE_TS_TO_LOCAL` and `ENABLE_EXIT_NODE` may be `true` per instance; the container refuses to start if more than one is enabled. Run a separate instance for each scenario.

## Troubleshooting

Check the logs with `docker compose logs <service-name>`. Common messages:

| Message | Cause and fix |
| --- | --- |
| `This node needs to log in, but neither TS_AUTHKEY nor TS_AUTHKEY_FILE is set.` | First start, or the node key expired / the device was removed. Set a valid `TS_AUTHKEY`. |
| `'tailscale up' with the auth key failed. The key may be expired, revoked, already used ...` | The key cannot be used to log in. Create a new key, preferably an OAuth client secret (see [Authentication and Key Expiry](#authentication-and-key-expiry)). For OAuth secrets, check that `TS_TAGS` matches the client's tags. |
| `... waiting for approval in the Tailscale admin console` | Device approval is enabled on your tailnet. Approve the device, or use a pre-authorized key. |
| `Could not connect to Tailscale with the existing node identity.` | The control server could not be reached within `TS_UP_TIMEOUT`. Check the container's internet access and DNS. Docker restarts the container and it retries without using the auth key. |
| `Forwarding configuration is invalid.` | The lines above it name the variable that is wrong (e.g. an invalid IP, an invalid port, or more than one scenario enabled). |
| `MACVLAN_IFACE 'eth0' does not exist.` | The container is not attached to the network you expect, or the interface has another name. Set `MACVLAN_IFACE`. |
| `tailscaled exited during startup.` | `/dev/net/tun` is missing or `NET_ADMIN` was not granted. Check `devices` and `cap_add` in `docker-compose.yml`. |
| `TS_STATE_DIR ... does not appear to be a mounted volume.` (warning) | Add a volume for `/var/lib/tailscale`, otherwise the node identity is lost when the container is recreated. |

Useful commands:

```bash
# Tailscale connection status
docker exec tailforwarder-one tailscale status

# Rules created by this container
docker exec tailforwarder-one iptables -t nat -S TAILFWD-PREROUTING
docker exec tailforwarder-one iptables -t nat -S TAILFWD-POSTROUTING
docker exec tailforwarder-one iptables -S TAILFWD-FORWARD
# On nftables-only hosts, use iptables-nft instead of iptables.
```

## Upgrading From Earlier Versions

Existing state directories keep working; no re-login is needed. Note these behavior changes:

*   `TS_AUTHKEY` is no longer required once a node is registered, and an expired auth key no longer prevents the container from starting.
*   `tailscale up` now runs with `--reset`. Settings that were changed by hand inside the container (e.g. with `tailscale set`) are reset to the values from the environment variables on every start.
*   An auth key passed via `TS_EXTRA_ARGS` (`--authkey=...` / `--auth-key=...`) is rejected. Move it to `TS_AUTHKEY`.
*   `ENABLE_EXIT_NODE=true` adds `--advertise-exit-node` by itself. Keeping it in `TS_EXTRA_ARGS` as well is harmless.
*   `TS_ROUTES` with several subnets now advertises all of them (previously only the last one was advertised).
*   Forwarding rules now live in the `TAILFWD-*` chains instead of directly in the built-in `PREROUTING`, `POSTROUTING` and `FORWARD` chains, which are no longer flushed.
