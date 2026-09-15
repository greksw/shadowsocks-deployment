#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

DEFAULT_PORT=8388
DEFAULT_METHOD='chacha20-ietf-poly1305'
DEFAULT_LISTEN_MODE='ipv4'
CONFIG_DIR='/etc/shadowsocks-libev'
CONFIG_FILE="${CONFIG_DIR}/managed-server.json"
UNIT_FILE='/etc/systemd/system/shadowsocks-managed.service'
SERVICE_NAME='shadowsocks-managed.service'
SERVICE_USER='shadowsocks-managed'
SERVICE_GROUP='shadowsocks-managed'
DEFAULT_SERVICE='shadowsocks-libev.service'

PORT=$DEFAULT_PORT
METHOD=$DEFAULT_METHOD
LISTEN_MODE=$DEFAULT_LISTEN_MODE
PASSWORD_FILE=''
GENERATE_PASSWORD=0
START_SERVICE=0
PRINT_PLAN=0
PACKAGE_INSTALLED_BY_US=0
DEFAULT_SERVICE_MASKED_BY_US=0

usage() {
    cat <<'EOF'
Usage:
  install-shadowsocks.sh [options]

Options:
  --port PORT                 Server port, 1024-65535 (default: 8388)
  --method METHOD             AEAD cipher (default: chacha20-ietf-poly1305)
  --listen MODE               ipv4 or dual (default: ipv4)
  --password-file FILE        Read one password line from root-owned mode-0600 file
  --generate-password         Generate a random 64-character hexadecimal password
  --start                     Enable and start the managed service after deployment
  --print-plan                Print the resolved deployment plan and exit
  -h, --help                  Show this help

This script targets clean Debian 12/13 hosts. It does not configure DNS, Nginx,
TLS certificates, UFW/nftables, NAT, routing, or client devices.
EOF
}

fatal() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fatal "Required command not found: $1"
}

validate_cli() {
    [[ $PORT =~ ^[0-9]+$ ]] || fatal 'PORT must be numeric.'
    ((PORT >= 1024 && PORT <= 65535)) || fatal 'PORT must be between 1024 and 65535.'

    case $METHOD in
        chacha20-ietf-poly1305|aes-128-gcm|aes-256-gcm) ;;
        *) fatal 'METHOD must be one of: chacha20-ietf-poly1305, aes-128-gcm, aes-256-gcm.' ;;
    esac

    [[ $LISTEN_MODE == 'ipv4' || $LISTEN_MODE == 'dual' ]] \
        || fatal "--listen must be 'ipv4' or 'dual'."

    if ((GENERATE_PASSWORD == 1)) && [[ -n $PASSWORD_FILE ]]; then
        fatal '--generate-password and --password-file are mutually exclusive.'
    fi
}

validate_os() {
    local os_id version_id

    [[ -r /etc/os-release ]] || fatal '/etc/os-release is missing.'
    # shellcheck disable=SC1091
    source /etc/os-release
    os_id=${ID:-}
    version_id=${VERSION_ID:-}

    [[ $os_id == 'debian' ]] || fatal 'This deployment supports Debian only.'
    [[ $version_id == '12' || $version_id == '13' ]] \
        || fatal "Supported Debian releases are 12 and 13; found: ${version_id:-unknown}."
}

validate_secret_file() {
    local file=$1 owner mode

    [[ -f $file ]] || fatal "Password file not found: $file"
    [[ ! -L $file ]] || fatal 'Password file must not be a symbolic link.'

    owner=$(stat -c '%u' -- "$file")
    [[ $owner == '0' ]] || fatal 'Password file must be owned by root.'

    mode=$(stat -c '%a' -- "$file")
    [[ $mode =~ ^[0-7]{3,4}$ ]] || fatal 'Unable to validate password file mode.'
    if (( (8#$mode & 077) != 0 )); then
        fatal 'Password file must not be accessible by group/others. Use mode 0600.'
    fi
}

read_password() {
    local -a lines=()

    if ((GENERATE_PASSWORD == 1)); then
        require_command openssl
        PASSWORD=$(openssl rand -hex 32)
        return
    fi

    [[ -n $PASSWORD_FILE ]] || fatal 'Choose --password-file FILE or --generate-password.'
    validate_secret_file "$PASSWORD_FILE"
    mapfile -t lines < "$PASSWORD_FILE"
    ((${#lines[@]} == 1)) || fatal 'Password file must contain exactly one line.'
    PASSWORD=${lines[0]}

    [[ $PASSWORD =~ ^[A-Za-z0-9._~!@#%+=:-]{16,128}$ ]] \
        || fatal 'Password must be 16-128 characters using the documented safe character set.'
}

print_plan() {
    local password_source='not selected'
    if ((GENERATE_PASSWORD == 1)); then
        password_source='generated at deployment time'
    elif [[ -n $PASSWORD_FILE ]]; then
        password_source="root-only file: $PASSWORD_FILE"
    fi

    cat <<EOF
Shadowsocks deployment plan
  target OS: Debian 12/13
  package: shadowsocks-libev from configured Debian repositories
  listen mode: $LISTEN_MODE
  port: $PORT/tcp+udp
  method: $METHOD
  password source: $password_source
  managed config: $CONFIG_FILE
  managed unit: $UNIT_FILE
  start service: $START_SERVICE
  firewall changes: none
  nginx/certbot changes: none
EOF
}

cleanup_mask() {
    local rc=$?
    if ((DEFAULT_SERVICE_MASKED_BY_US == 1)); then
        systemctl unmask "$DEFAULT_SERVICE" >/dev/null 2>&1 || true
    fi
    exit "$rc"
}
trap cleanup_mask EXIT HUP INT TERM

install_packages() {
    if dpkg-query -W -f='${Status}' shadowsocks-libev 2>/dev/null | grep -q '^install ok installed$'; then
        if systemctl is-active --quiet "$DEFAULT_SERVICE" || systemctl is-enabled --quiet "$DEFAULT_SERVICE" 2>/dev/null; then
            fatal "Existing $DEFAULT_SERVICE is active or enabled. Refusing to take over an existing deployment."
        fi
        log 'shadowsocks-libev is already installed and its default service is inactive/disabled.'
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends jq openssl
        return
    fi

    log "Masking $DEFAULT_SERVICE during package installation."
    systemctl mask "$DEFAULT_SERVICE" >/dev/null
    DEFAULT_SERVICE_MASKED_BY_US=1

    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        shadowsocks-libev jq openssl
    PACKAGE_INSTALLED_BY_US=1

    systemctl disable --now "$DEFAULT_SERVICE" >/dev/null 2>&1 || true
    systemctl unmask "$DEFAULT_SERVICE" >/dev/null
    DEFAULT_SERVICE_MASKED_BY_US=0
}

create_service_identity() {
    if ! getent group "$SERVICE_GROUP" >/dev/null; then
        groupadd --system "$SERVICE_GROUP"
    fi

    if ! id "$SERVICE_USER" >/dev/null 2>&1; then
        useradd \
            --system \
            --gid "$SERVICE_GROUP" \
            --home-dir /nonexistent \
            --shell /usr/sbin/nologin \
            "$SERVICE_USER"
    fi
}

render_config() {
    local temp_config
    temp_config=$(mktemp)
    chmod 0600 "$temp_config"

    if [[ $LISTEN_MODE == 'dual' ]]; then
        jq -n \
            --arg password "$PASSWORD" \
            --arg method "$METHOD" \
            --argjson port "$PORT" \
            '{
              server: ["::0", "0.0.0.0"],
              server_port: $port,
              password: $password,
              timeout: 300,
              method: $method,
              fast_open: false,
              mode: "tcp_and_udp"
            }' > "$temp_config"
    else
        jq -n \
            --arg password "$PASSWORD" \
            --arg method "$METHOD" \
            --argjson port "$PORT" \
            '{
              server: "0.0.0.0",
              server_port: $port,
              password: $password,
              timeout: 300,
              method: $method,
              fast_open: false,
              mode: "tcp_and_udp"
            }' > "$temp_config"
    fi

    jq -e . "$temp_config" >/dev/null
    install -d -o root -g "$SERVICE_GROUP" -m 0750 "$CONFIG_DIR"
    install -o root -g "$SERVICE_GROUP" -m 0640 "$temp_config" "$CONFIG_FILE"
    rm -f -- "$temp_config"
}

install_unit() {
    cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Managed Shadowsocks-libev Server
Documentation=man:ss-server(1)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_GROUP
UMask=0077
ExecStart=/usr/bin/ss-server -c $CONFIG_FILE
Restart=on-failure
RestartSec=5s
LimitNOFILE=32768
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
EOF

    chmod 0644 "$UNIT_FILE"
    systemd-analyze verify "$UNIT_FILE"
    systemctl daemon-reload
}

validate_clean_target() {
    [[ ! -e $CONFIG_FILE ]] || fatal "Managed config already exists: $CONFIG_FILE"
    [[ ! -e $UNIT_FILE ]] || fatal "Managed systemd unit already exists: $UNIT_FILE"
}

while (($# > 0)); do
    case $1 in
        --port)
            (($# >= 2)) || fatal '--port requires a value.'
            PORT=$2
            shift 2
            ;;
        --method)
            (($# >= 2)) || fatal '--method requires a value.'
            METHOD=$2
            shift 2
            ;;
        --listen)
            (($# >= 2)) || fatal '--listen requires a value.'
            LISTEN_MODE=$2
            shift 2
            ;;
        --password-file)
            (($# >= 2)) || fatal '--password-file requires a value.'
            PASSWORD_FILE=$2
            shift 2
            ;;
        --generate-password)
            GENERATE_PASSWORD=1
            shift
            ;;
        --start)
            START_SERVICE=1
            shift
            ;;
        --print-plan)
            PRINT_PLAN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fatal "Unknown argument: $1"
            ;;
    esac
done

validate_cli

if ((PRINT_PLAN == 1)); then
    print_plan
    exit 0
fi

((EUID == 0)) || fatal 'Deployment must run as root.'
validate_os
require_command apt-get
require_command dpkg-query
require_command systemctl
require_command systemd-analyze
require_command stat
require_command getent
require_command groupadd
require_command useradd
validate_clean_target

install_packages
require_command jq
require_command ss-server
read_password
create_service_identity
render_config
install_unit

if ((START_SERVICE == 1)); then
    systemctl enable --now "$SERVICE_NAME"
    systemctl is-active --quiet "$SERVICE_NAME" \
        || fatal "Service failed to become active: $SERVICE_NAME"
    log "Service is active: $SERVICE_NAME"
else
    log "Deployment completed without starting $SERVICE_NAME."
fi

cat <<EOF

Deployment complete.
Config: $CONFIG_FILE
Service: $SERVICE_NAME
Listen: $LISTEN_MODE on TCP/UDP port $PORT
Cipher: $METHOD
Password is stored only in the protected server configuration and is not printed.

Required follow-up:
  1. Configure the host/network firewall for TCP and UDP port $PORT as appropriate.
  2. Retrieve the password as root from $CONFIG_FILE when provisioning a client.
  3. Test TCP and UDP connectivity from an authorized client network.
EOF
