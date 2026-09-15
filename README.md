# Shadowsocks Deployment

A small, security-focused deployment helper for `shadowsocks-libev` on Debian 12/13.

The project intentionally does **one thing**: install and configure a standalone Shadowsocks server with a managed systemd service. It does not configure unrelated web, DNS, certificate, firewall, NAT, or client settings.

## Why this repository was rebuilt

The historical installer combined several unrelated concerns in one root script:

- full system package upgrade;
- destructive UFW reset and firewall policy replacement;
- SSH source-address ACL changes;
- Nginx and public web-site provisioning;
- Certbot certificate issuance;
- Shadowsocks configuration and service startup.

That approach made rollback and change review difficult. It also created a misleading relationship between the HTTPS certificate and the Shadowsocks service: the TLS certificate protected the Nginx site on TCP/443, while Shadowsocks listened independently on its own TCP/UDP port.

The current version separates those concerns and makes firewall/network changes an explicit operator responsibility.

## Supported target

- Debian 12 or Debian 13
- systemd
- root access for deployment
- `shadowsocks-libev` from the configured Debian repositories

The installer accepts only AEAD ciphers:

- `chacha20-ietf-poly1305` (default)
- `aes-128-gcm`
- `aes-256-gcm`

## Safety model

The installer:

- uses `set -Eeuo pipefail`;
- refuses unsupported operating systems/releases;
- refuses privileged ports below 1024;
- refuses to overwrite its managed config or unit;
- refuses to take over an already active/enabled distribution `shadowsocks-libev.service`;
- does not run `apt upgrade`;
- does not reset or modify UFW/nftables;
- does not modify SSH policy;
- does not configure Nginx, DNS, TLS certificates, NAT, routing, or clients;
- keeps the server password out of command-line arguments and normal output;
- creates a dedicated unprivileged service identity;
- validates the generated JSON configuration;
- validates the systemd unit before deployment completes;
- does not start the service unless `--start` is explicitly supplied.

## Review the plan first

```bash
sudo ./install-shadowsocks.sh \
  --port 8388 \
  --listen ipv4 \
  --method chacha20-ietf-poly1305 \
  --generate-password \
  --print-plan
```

`--print-plan` performs no installation or configuration changes.

## Password options

### Generate a password

```bash
sudo ./install-shadowsocks.sh \
  --port 8388 \
  --generate-password
```

The generated password is written only into the protected server configuration and is not printed.

### Use an existing password

Create a root-only file containing exactly one password line:

```text
replace-with-a-strong-random-password
```

Install it with restrictive permissions:

```bash
sudo install -o root -g root -m 0600 password.txt /root/shadowsocks-password
```

Then deploy:

```bash
sudo ./install-shadowsocks.sh \
  --password-file /root/shadowsocks-password
```

Accepted password length is 16-128 characters using the documented safe character set.

## Start behavior

By default, deployment installs the configuration and systemd unit but leaves the managed service stopped.

To enable and start it immediately:

```bash
sudo ./install-shadowsocks.sh \
  --generate-password \
  --start
```

Managed paths:

- `/etc/shadowsocks-libev/managed-server.json`
- `/etc/systemd/system/shadowsocks-managed.service`

The service runs as a dedicated `shadowsocks-managed` system user with systemd hardening enabled.

## Firewall and network policy

The installer deliberately does not change firewall policy.

For the selected Shadowsocks port, the operator must decide where TCP and UDP should be reachable from. A typical host firewall rule must account for **both** protocols.

Do not blindly expose management SSH or unrelated services while opening the Shadowsocks port. If the server is behind NAT, configure only the required port-forwarding separately.

## Client provisioning

Retrieve the generated password only as root:

```bash
sudo jq -r '.password' /etc/shadowsocks-libev/managed-server.json
```

The client needs:

- server address;
- TCP/UDP server port;
- password;
- cipher/method matching the server configuration.

Treat the password as a secret. Do not commit production server configurations to Git.

## Validation after deployment

Inspect the generated configuration without printing the password:

```bash
sudo jq 'del(.password)' /etc/shadowsocks-libev/managed-server.json
```

Validate service state:

```bash
systemctl status shadowsocks-managed.service
journalctl -u shadowsocks-managed.service
```

Confirm the listener after starting:

```bash
sudo ss -lntup | grep ':8388'
```

Then test from an authorized client network, including UDP-dependent traffic where relevant.

## What this project does not solve

Shadowsocks is not a substitute for:

- host patch management;
- SSH hardening and MFA;
- firewall policy design;
- centralized logging/monitoring;
- network segmentation;
- VPN access controls where those are required by the environment.

## CI scope

CI validates:

- Bash syntax;
- ShellCheck;
- CLI plan rendering;
- rejection of invalid ports/ciphers/listen modes;
- absence of obvious embedded production secrets.

CI does **not** install packages, start systemd services, modify firewall rules, or run live proxy traffic. A disposable Debian 12/13 VM is recommended before production use.

## License

No license has been selected yet.
