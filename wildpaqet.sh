#!/bin/bash
#=================================================
# WildPaqet Tunnel Manager
# Version: 9.9-v3
# Branch: wild-paqet-v3 (real HTTP/2 cover + TLS 1.3 + authenticated resilient pools)
# HTTP/2-covered TLS with legacy direct TLS and raw KCP compatibility
# Core (vendored): ./core  ·  Upstream: https://github.com/hanselime/paqet
# Manager: https://github.com/infowild/WildPaqet-Tunnel
# Forked from: https://github.com/behzadea12/Paqet-Tunnel-Manager
#=================================================

# ================================================
# CONFIGURATION DEFAULTS (Easily modifiable)
# ================================================

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly WHITE='\033[1;37m'
readonly ORANGE='\033[0;33m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m'

# Script Configuration
readonly SCRIPT_VERSION="9.9-v3"
readonly MANAGER_NAME="wildpaqet"
readonly MANAGER_PATH="/usr/local/bin/$MANAGER_NAME"
readonly MANAGER_SCRIPT_FILE="wildpaqet.sh"
readonly MANAGER_BRANCH="wild-paqet-v3"

# Paths
readonly CONFIG_DIR="${WILDPAQET_CONFIG_DIR:-/etc/paqet}"
readonly SERVICE_DIR="${WILDPAQET_SERVICE_DIR:-/etc/systemd/system}"
readonly BIN_DIR="/usr/local/bin"
readonly INSTALL_DIR="/opt/paqet"
readonly BACKUP_DIR="/root/paqet-backups"
readonly CORE_SRC_DIR="/opt/wildpaqet-core-src"
readonly GO_TOOLCHAIN_DIR="/opt/wildpaqet-go"

# Repositories
# Upstream binary fallback (hanselime). WildPaqet v2 core builds publish on MANAGER repo.
readonly GITHUB_REPO="hanselime/paqet"
readonly CORE_GITHUB_REPO="infowild/WildPaqet-Tunnel"
readonly MANAGER_GITHUB_REPO="infowild/WildPaqet-Tunnel"
readonly SERVICE_NAME="paqet"
readonly TELEGRAM_API_BASE="${TELEGRAM_API_BASE:-https://api.telegram.org}"
# Default wire profile for new configs (Core v2).
# "default" = stable midstream crafting; use "restrictive" only if path needs it.
readonly DEFAULT_TCP_PRESET="default"

# Kernel optimization settings (Safe/Auto network optimizer)
readonly STATE_DIR="${WILDPAQET_STATE_DIR:-/var/lib/wildpaqet}"
readonly SYSCTL_FILE="${WILDPAQET_SYSCTL_FILE:-/etc/sysctl.d/99-paqet-tunnel.conf}"
readonly LIMITS_FILE="${WILDPAQET_LIMITS_FILE:-/etc/security/limits.d/99-paqet.conf}"
readonly NETOPT_STATE_DIR="${WILDPAQET_NETOPT_STATE_DIR:-$STATE_DIR/netopt}"
readonly NETOPT_MARKER="wildpaqet-managed"
readonly NETOPT_QDISC_UNIT="wildpaqet-qdisc.service"
readonly NETOPT_QDISC_SCRIPT="${WILDPAQET_QDISC_SCRIPT:-/usr/local/lib/wildpaqet/fix-qdisc.sh}"
readonly FIREWALL_COMMENT="wildpaqet-managed"
readonly FIREWALL_STATE_FILE="${WILDPAQET_FIREWALL_STATE_FILE:-$STATE_DIR/firewall.rules}"
readonly IP_FORWARD_FILE="${WILDPAQET_IP_FORWARD_FILE:-/etc/sysctl.d/30-ip_forward.conf}"
readonly IP_FORWARD_BACKUP="$STATE_DIR/ip-forward.before"
readonly IP_FORWARD_ABSENT_MARKER="$STATE_DIR/ip-forward.absent"

# Default Values
readonly DEFAULT_LISTEN_PORT="8888"
readonly DEFAULT_KCP_MODE="normal"
readonly DEFAULT_ENCRYPTION="aes-128-gcm"
readonly DEFAULT_CONNECTIONS="1"
readonly DEFAULT_CONNECTIONS_CLIENT="1"
readonly DEFAULT_MTU="1350"
readonly DEFAULT_SMUX_KEEPALIVE="15"
readonly DEFAULT_SMUX_KEEPALIVE_TIMEOUT="60"
readonly DEFAULT_V3_CONNECTIONS_PER_ENDPOINT="4"
readonly DEFAULT_PCAP_SOCKBUF_SERVER="8388608"
readonly DEFAULT_PCAP_SOCKBUF_CLIENT="4194304"
readonly DEFAULT_TRANSPORT_TCPBUF="8192"
readonly DEFAULT_TRANSPORT_UDPBUF="4096"
readonly DEFAULT_AUTO_RESTART_INTERVAL="1hour"
readonly DEFAULT_V2RAY_PORTS="9090"
readonly DEFAULT_SOCKS5_PORT="1080"

# KCP Mode Descriptions (name:description)
declare -A KCP_MODES=(
    ["0"]="normal:Normal speed / Normal latency / Low usage"
    ["1"]="fast:Balanced speed / Low latency / Normal usage"
    ["2"]="fast2:High speed / Lower latency / Medium usage"
    ["3"]="fast3:Max speed / Very low latency / High CPU"
    ["4"]="manual:Advanced settings"
)

# Encryption Options
declare -A ENCRYPTION_OPTIONS=(
    ["1"]="aes-128-gcm:Very high security / Very fast / Recommended"
    ["2"]="aes:High security / Medium speed / General use"
    ["3"]="aes-128:High security / Fast / Low CPU usage"
    ["4"]="aes-192:Very high security / Medium speed / Moderate CPU usage"
    ["5"]="aes-256:Maximum security / Slower / Higher CPU usage"
    ["6"]="none:No encryption / Max speed / Insecure"
    ["7"]="null:No encryption / Max speed / Insecure"
)

# Auto-restart intervals
declare -A RESTART_INTERVALS=(
    ["1min"]="*/1 * * * *"
    ["5min"]="*/5 * * * *"
    ["15min"]="*/15 * * * *"
    ["30min"]="*/30 * * * *"
    ["1hour"]="0 */1 * * *"
    ["12hour"]="0 */12 * * *"
    ["1day"]="0 0 * * *"
)

# IP detection services
readonly IP_SERVICES=(
    "ifconfig.me"
    "icanhazip.com"
    "api.ipify.org"
    "checkip.amazonaws.com"
    "ipinfo.io/ip"
)

# Test domains for DNS
readonly TEST_DOMAINS=(
    "google.com"
    "github.com"
    "cloudflare.com"
    "wikipedia.org"
)

# DNS servers for testing
readonly DNS_SERVERS=(
    "8.8.8.8"
    "1.1.1.1"
    "208.67.222.222"
    "system"
)

# MTU test sizes
readonly MTU_TESTS=(
    "1500"
    "1470"
    "1400"
    "1350"
    "1300"
    "1200"
    "1100"
)

# Common ports for testing
readonly COMMON_PORTS=("443" "80" "22" "53")

# Manager versions for switch option
declare -A MANAGER_VERSIONS=(
	["v3"]="https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/wild-paqet-v3/wildpaqet.sh"
    ["v2"]="https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/wild-paqet-v2/wildpaqet.sh"
    ["latest"]="https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/wild-paqet-v3/wildpaqet.sh"
    ["main-7.1"]="https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/main/wildpaqet.sh"
    ["6.0"]="https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/main/paqet-manager6-0.sh"
    ["5.1"]="https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/main/paqet-manager5-1.sh"
    ["3.8"]="https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/main/paqet-manager3-8.sh"
)

# Raw URL for this branch's manager script (install / self-update shortcut)
manager_script_url() {
    echo "https://raw.githubusercontent.com/${MANAGER_GITHUB_REPO}/${MANAGER_BRANCH}/${MANAGER_SCRIPT_FILE}"
}

# ================================================
# UTILITY FUNCTIONS
# ================================================

# Print functions
print_step() { echo -e "${BLUE}[*]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_info() { echo -e "${CYAN}[i]${NC} $1"; }
print_input() { echo -e "${YELLOW}[?]${NC} $1"; }

# Pause with custom message
pause() {
    local msg="${1:-Press Enter to continue...}"
    echo ""
    read -p "$msg" </dev/tty
}

# Clear screen and show banner
show_banner() {
    clear
    echo ""
    echo -e "${CYAN}    ╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}    ║${NC}                                                            ${CYAN}║${NC}"
    echo -e "${CYAN}    ║${NC}  ${WHITE}██╗    ██╗██╗██╗     ██████╗${NC}                            ${CYAN}║${NC}"
    echo -e "${CYAN}    ║${NC}  ${WHITE}██║    ██║██║██║     ██╔══██╗${NC}                           ${CYAN}║${NC}"
    echo -e "${CYAN}    ║${NC}  ${WHITE}██║ █╗ ██║██║██║     ██║  ██║${NC}                           ${CYAN}║${NC}"
    echo -e "${CYAN}    ║${NC}  ${WHITE}██║███╗██║██║██║     ██║  ██║${NC}                           ${CYAN}║${NC}"
    echo -e "${CYAN}    ║${NC}  ${WHITE}╚███╔███╔╝██║███████╗██████╔╝${NC}                           ${CYAN}║${NC}"
    echo -e "${CYAN}    ║${NC}   ${WHITE}╚══╝╚══╝ ╚═╝╚══════╝╚═════╝${NC}                            ${CYAN}║${NC}"
    echo -e "${CYAN}    ║${NC}                                                            ${CYAN}║${NC}"
    echo -e "${CYAN}    ║${NC}  ${GREEN}██████╗  █████╗  ██████╗ ███████╗████████╗${NC}              ${CYAN}║${NC}"
    echo -e "${CYAN}    ║${NC}  ${GREEN}██╔══██╗██╔══██╗██╔═══██╗██╔════╝╚══██╔══╝${NC}              ${CYAN}║${NC}"
    echo -e "${CYAN}    ║${NC}  ${GREEN}██████╔╝███████║██║   ██║█████╗     ██║${NC}                 ${CYAN}║${NC}"
    echo -e "${CYAN}    ║${NC}  ${GREEN}██╔═══╝ ██╔══██║██║▄▄ ██║██╔══╝     ██║${NC}                 ${CYAN}║${NC}"
    echo -e "${CYAN}    ║${NC}  ${GREEN}██║     ██║  ██║╚██████╔╝███████╗   ██║${NC}                 ${CYAN}║${NC}"
    echo -e "${CYAN}    ║${NC}  ${GREEN}╚═╝     ╚═╝  ╚═╝ ╚══▀▀═╝ ╚══════╝   ╚═╝${NC}                 ${CYAN}║${NC}"
    echo -e "${CYAN}    ║${NC}                                                            ${CYAN}║${NC}"
    echo -e "${CYAN}    ║${NC}     ${YELLOW}✦  Raw Packet Tunnel  ·  Firewall Bypass  ✦${NC}          ${CYAN}║${NC}"
    echo -e "${CYAN}    ║${NC}              ${MAGENTA}Manager v${SCRIPT_VERSION}${NC}  ·  ${WHITE}by InfoWild${NC}              ${CYAN}║${NC}"
    echo -e "${CYAN}    ║${NC}           ${ORANGE}branch: ${MANAGER_BRANCH}${NC}                              ${CYAN}║${NC}"
    echo -e "${CYAN}    ║${NC}                                                            ${CYAN}║${NC}"
    echo -e "${CYAN}    ║${NC}  ${BLUE}https://github.com/infowild/WildPaqet-Tunnel${NC}             ${CYAN}║${NC}"
    echo -e "${CYAN}    ║${NC}                                                            ${CYAN}║${NC}"
    echo -e "${CYAN}    ╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# Check root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        echo -e "${YELLOW}Try:${NC} ${CYAN}sudo wildpaqet${NC}  or  ${CYAN}sudo bash <(curl -fsSL $(manager_script_url))${NC}"
        exit 1
    fi
}

# Ensure /usr/local/bin/wildpaqet exists so the command works after first run
# IMPORTANT: never cp from process-substitution (/dev/fd/*) — that consumes the
# remaining script stream and installs a truncated file (e.g. only "main_menu").
is_manager_binary_ok() {
    local f="${1:-$MANAGER_PATH}"
    [ -f "$f" ] && [ -x "$f" ] || return 1
    grep -q 'MANAGER_NAME="wildpaqet"' "$f" 2>/dev/null || return 1
    grep -q '^main_menu()' "$f" 2>/dev/null || return 1
    local sz
    sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ' || echo 0)
    [ "$sz" -gt 50000 ] || return 1
    return 0
}

ensure_manager_command() {
    if is_manager_binary_ok "$MANAGER_PATH"; then
        if grep -q $'\r' "$MANAGER_PATH" 2>/dev/null; then
            sed -i 's/\r$//' "$MANAGER_PATH" 2>/dev/null || true
            chmod +x "$MANAGER_PATH"
        fi
    else
        print_step "Installing system command ${CYAN}wildpaqet${NC} ..."
        # Remove broken/truncated previous install
        rm -f "$MANAGER_PATH" 2>/dev/null || true

        local installed_ok=0
        local src="${BASH_SOURCE[0]:-}"

        # Only copy from a real on-disk script path (not /dev/fd or /proc/self/fd)
        if [ -n "$src" ] && [ -f "$src" ] \
            && [[ "$src" != /dev/fd/* && "$src" != /proc/self/fd/* && "$src" != /dev/stdin ]]; then
            if cp -f "$src" "$MANAGER_PATH" 2>/dev/null; then
                sed -i 's/\r$//' "$MANAGER_PATH" 2>/dev/null || true
                chmod +x "$MANAGER_PATH"
                if is_manager_binary_ok "$MANAGER_PATH"; then
                    installed_ok=1
                fi
            fi
        fi

        if [ "$installed_ok" -eq 0 ]; then
            local manager_url
            manager_url="$(manager_script_url)"
            if curl -fsSL "$manager_url" -o "$MANAGER_PATH" 2>/dev/null; then
                sed -i 's/\r$//' "$MANAGER_PATH" 2>/dev/null || true
                chmod +x "$MANAGER_PATH"
                if is_manager_binary_ok "$MANAGER_PATH"; then
                    installed_ok=1
                fi
            fi
        fi

        if [ "$installed_ok" -eq 0 ]; then
            rm -f "$MANAGER_PATH" 2>/dev/null || true
            print_warning "Could not install a valid wildpaqet command"
            print_info "After this session, run: ${CYAN}curl -fsSL $(manager_script_url) -o $MANAGER_PATH && chmod +x $MANAGER_PATH${NC}"
            return 1
        fi

        rm -f /usr/local/bin/paqet-manager 2>/dev/null || true
        print_success "Installed: $MANAGER_PATH ($(wc -c < "$MANAGER_PATH" | tr -d ' ') bytes)"
    fi

    # Fallback PATH for minimal systems
    if ! command -v wildpaqet >/dev/null 2>&1; then
        ln -sf "$MANAGER_PATH" /usr/bin/wildpaqet 2>/dev/null || true
    fi
    hash -r 2>/dev/null || true

    if command -v wildpaqet >/dev/null 2>&1; then
        print_info "Run anytime with: ${CYAN}wildpaqet${NC}"
    else
        print_warning "Command not in PATH yet. Use: ${CYAN}$MANAGER_PATH${NC}"
        print_info "Or: ${CYAN}export PATH=\"/usr/local/bin:\$PATH\" && hash -r${NC}"
    fi
}

# Keep /usr/local/bin/wildpaqet on the same version as this running session.
# Otherwise a curl one-liner heals this run, then the next `wildpaqet` is the old copy
# that still writes network.tcp.preset: restrictive.
sync_installed_manager_if_outdated() {
    local installed_ver=""
    if [ -f "$MANAGER_PATH" ]; then
        installed_ver=$(grep '^readonly SCRIPT_VERSION=' "$MANAGER_PATH" 2>/dev/null | head -1 | cut -d'"' -f2)
    fi
    [ "$installed_ver" = "$SCRIPT_VERSION" ] && return 0

    local src="${BASH_SOURCE[0]:-}"
    local ok=0
    if [ -n "$src" ] && [ -f "$src" ] \
        && [[ "$src" != /dev/fd/* && "$src" != /proc/self/fd/* && "$src" != /dev/stdin && "$src" != "$MANAGER_PATH" ]]; then
        if cp -f "$src" "$MANAGER_PATH" 2>/dev/null; then
            sed -i 's/\r$//' "$MANAGER_PATH" 2>/dev/null || true
            chmod +x "$MANAGER_PATH"
            is_manager_binary_ok "$MANAGER_PATH" && ok=1
        fi
    fi
    if [ "$ok" -eq 0 ]; then
        local manager_url
        manager_url="$(manager_script_url)"
        if curl -fsSL "$manager_url" -o "$MANAGER_PATH" 2>/dev/null; then
            sed -i 's/\r$//' "$MANAGER_PATH" 2>/dev/null || true
            chmod +x "$MANAGER_PATH"
            is_manager_binary_ok "$MANAGER_PATH" && ok=1
        fi
    fi
    if [ "$ok" -eq 1 ]; then
        print_success "Manager command updated to v${SCRIPT_VERSION}"
    else
        print_warning "This session is v${SCRIPT_VERSION}; installed manager is v${installed_ver:-unknown}"
        print_info "After GitHub is updated: ${CYAN}wildpaqet${NC} → 0 → 5"
    fi
}

# Core v2 now treats "restrictive" as an alias of the hardened default, so this
# only normalises older YAML to the name the examples and docs use.
migrate_tcp_preset_to_default() {
    [ -d "$CONFIG_DIR" ] || return 0

    local changed=()
    local f name svc
    local old_nullglob
    old_nullglob=$(shopt -p nullglob)
    shopt -s nullglob
    for f in "$CONFIG_DIR"/*.yaml "$CONFIG_DIR"/*.yml; do
        [ -f "$f" ] || continue
        grep -qE '^[[:space:]]*preset:[[:space:]]*"?restrictive"?' "$f" 2>/dev/null || continue
        sed -i -E 's/^([[:space:]]*)preset:[[:space:]]*"?restrictive"?[[:space:]]*$/\1preset: "default"/' "$f"
        if grep -qE '^[[:space:]]*preset:[[:space:]]*"?default"?' "$f"; then
            name=$(basename "$f")
            name=${name%.yaml}
            name=${name%.yml}
            changed+=("$name")
        fi
    done
    eval "$old_nullglob" 2>/dev/null || shopt -u nullglob

    [ ${#changed[@]} -eq 0 ] && return 0

    echo ""
    print_info "Normalized tcp preset 'restrictive' to 'default' on: ${changed[*]}"
    for name in "${changed[@]}"; do
        svc="paqet-${name}.service"
        if [ -f "$SERVICE_DIR/$svc" ]; then
            if systemctl restart "$svc" >/dev/null 2>&1; then
                print_success "Restarted $svc"
            else
                print_warning "Could not restart $svc"
            fi
        fi
    done
    echo ""
    sleep 2
}

# Detect OS
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    elif [ -f /etc/redhat-release ]; then
        echo "rhel"
    else
        echo "$(uname -s | tr '[:upper:]' '[:lower:]')"
    fi
}

# Detect architecture
detect_arch() {
    local arch
    arch=$(uname -m)
    
    case $arch in
        x86_64|x86-64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l|armhf) echo "armv7" ;;
        i386|i686) echo "386" ;;
        *)
            print_error "Unsupported architecture: $arch"
            return 1
            ;;
    esac
}

# Get public IP
get_public_ip() {
    for service in "${IP_SERVICES[@]}"; do
        local ip
        ip=$(curl -4 -s --max-time 2 "$service" 2>/dev/null)
        if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    
    local ip
    ip=$(hostname -I | awk '{print $1}' 2>/dev/null)
    if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ip"
        return 0
    fi
    
    echo "Not Detected"
}

# Get network information
get_network_info() {
    NETWORK_INTERFACE=""
    LOCAL_IP=""
    GATEWAY_IP=""
    GATEWAY_MAC=""
    
    if command -v ip &>/dev/null; then
        NETWORK_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)
        LOCAL_IP=$(ip -4 addr show "$NETWORK_INTERFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
        GATEWAY_IP=$(ip route | grep default | awk '{print $3}' | head -1)
        
        if [ -n "$GATEWAY_IP" ]; then
            ping -c 1 -W 1 "$GATEWAY_IP" >/dev/null 2>&1 || true
            GATEWAY_MAC=$(ip neigh show "$GATEWAY_IP" 2>/dev/null | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | head -1)
            
            if [ -z "$GATEWAY_MAC" ] && command -v arp &>/dev/null; then
                GATEWAY_MAC=$(arp -n "$GATEWAY_IP" 2>/dev/null | awk "/^$GATEWAY_IP/ {print \$3}" | head -1)
            fi
        fi
    fi
    
    NETWORK_INTERFACE="${NETWORK_INTERFACE:-eth0}"
}

# Validate IP address
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        local IFS='.'
        read -ra octets <<< "$ip"
        for octet in "${octets[@]}"; do
            if [[ $octet -lt 0 || $octet -gt 255 ]]; then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

# Validate port
validate_port() {
    local port=$1
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

# Clean port list
clean_port_list() {
    local ports="$1"
    ports=$(echo "$ports" | tr -d ' ')
    local cleaned=""
    
    IFS=',' read -ra port_array <<< "$ports"
    for port in "${port_array[@]}"; do
        if validate_port "$port"; then
            cleaned="${cleaned:+$cleaned,}$port"
        else
            print_warning "Invalid port '$port' removed from list"
        fi
    done
    
    echo "$cleaned"
}

# Clean config name
clean_config_name() {
    local name="$1"
    name=$(echo "$name" | tr -cd '[:alnum:]-_')
    echo "${name:-default}"
}

# Check port conflict
check_port_conflict() {
    local port="$1"
    
    if ss -tuln 2>/dev/null | grep -q ":${port} "; then
        print_warning "Port $port is already in use!"
        
        local pid
        pid=$(lsof -t -i:"$port" 2>/dev/null | head -1)
        if [ -n "$pid" ]; then
            local pname
            pname=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
            print_info "Process: $pname (PID: $pid)"
            
            echo ""
            read -p "Kill this process? (y/N): " kill_choice
            
            if [[ "$kill_choice" =~ ^[Yy]$ ]]; then
                kill -9 "$pid" 2>/dev/null || true
                sleep 1
                print_success "Process killed"
            else
                print_error "Cannot continue with port in use"
                return 1
            fi
        fi
    fi
    return 0
}

normalize_host_for_compare() {
    local host="$1"
    host=$(echo "$host" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    host="${host#[}"; host="${host%]}"
    case "$host" in
        ""|"localhost"|"0.0.0.0"|"::") echo "127.0.0.1" ;;
        *) echo "$host" ;;
    esac
}

normalize_port() {
    local input="$1"
    input=$(echo "$input" | tr -cd '0-9')
    [[ "$input" =~ ^[1-9][0-9]{0,4}$ && "$input" -le 65535 ]] && echo "$input" || echo ""
}

# ────────────────────────────────────────────────────────────────
# Check for dangerous forward rules that point back to Paqet listener
# Prevents traffic loop / infinite bandwidth consumption
# ────────────────────────────────────────────────────────────────
validate_forward_rules() {
    # Only relevant for Port Forwarding mode
    [[ "$traffic_type" != "1" ]] && return 0

    local srv_host srv_port
    srv_host=$(normalize_host_for_compare "$server_ip")
    srv_port=$(normalize_port "$server_port")

    [ -z "$srv_host" ] || [ -z "$srv_port" ] && return 0

    echo -e "${CYAN}Checking forward rules for traffic loop prevention...${NC}"

    local dangerous=0
    IFS=',' read -ra PORTS <<< "$forward_ports"

    for p in "${PORTS[@]}"; do
        p=$(echo "$p" | tr -d '[:space:]')   # Remove whitespace

        if ! validate_port "$p"; then
            continue
        fi

        # Main case: if forward port equals server port
        if [ "$p" = "$srv_port" ]; then
            print_error "⚠️ TRAFFIC LOOP DETECTED!"
            echo -e "   • Local port: ${YELLOW}$p${NC}"
            echo -e "   • Paqet server port: ${YELLOW}$server_ip:$server_port${NC}"
            echo -e "   This will create an infinite traffic loop and consume all bandwidth!"
            ((dangerous++))
        fi
    done

    if (( dangerous > 0 )); then
        echo ""
        print_error "❌ Configuration aborted due to loop detection."
        echo -e "${YELLOW}Solution:${NC}"
        echo -e "  • Change your forward ports (e.g., 443, 8443, 2053, etc.)"
        echo -e "  • Make sure no port matches the tunnel port (${YELLOW}$server_port${NC})"
        echo -e "  • Forward ports should point to actual services (v2ray/xray/...)"
        pause
        return 1
    fi

    print_success "No dangerous forward rules found ✓"
    return 0
}

# Generate secret key
generate_secret_key() {
    if command -v openssl &>/dev/null; then
        openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32
    else
        tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 32
    fi
}

# Get latest Paqet / WildPaqet Core version from GitHub
# Prefer WildPaqet-Tunnel core releases (tag core-v*), then upstream hanselime/paqet.
get_latest_paqet_version() {
    local version=""
    version=$(curl -fsSL "https://api.github.com/repos/${CORE_GITHUB_REPO}/releases" 2>/dev/null \
        | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4 \
        | grep -E '^core-v|^v2\.|^wild-' | head -1)
    if [ -z "$version" ]; then
        version=$(curl -fsSL "https://api.github.com/repos/${CORE_GITHUB_REPO}/releases/latest" 2>/dev/null \
            | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4)
    fi
    if [ -z "$version" ]; then
        version=$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" 2>/dev/null \
            | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4)
    fi
    if [ -n "$version" ]; then
        echo "$version"
    else
        echo "v1.0.0-alpha.20"
    fi
}

# Resolve download URL for a core release asset (Wild repo first, then upstream)
resolve_core_download_url() {
    local version="$1"
    local expected_file="$2"
    local url
    url="https://github.com/${CORE_GITHUB_REPO}/releases/download/${version}/${expected_file}"
    if curl -fsI "$url" >/dev/null 2>&1; then
        echo "$url"
        return 0
    fi
    url="https://github.com/${GITHUB_REPO}/releases/download/${version}/${expected_file}"
    echo "$url"
}

# Compare floats (with bc fallback)
compare_floats() {
    local value=$1
    local threshold=$2
    local comparison=$3
    
    if ! command -v bc &>/dev/null; then
        local value_int=${value%.*}
        local threshold_int=${threshold%.*}
        
        case $comparison in
            "lt") [[ $value_int -lt $threshold_int ]] ;;
            "le") [[ $value_int -le $threshold_int ]] ;;
            "gt") [[ $value_int -gt $threshold_int ]] ;;
            "ge") [[ $value_int -ge $threshold_int ]] ;;
            *) return 1 ;;
        esac
        return $?
    fi
    
    case $comparison in
        "lt") (($(echo "$value < $threshold" | bc -l 2>/dev/null || echo 0))) ;;
        "le") (($(echo "$value <= $threshold" | bc -l 2>/dev/null || echo 0))) ;;
        "gt") (($(echo "$value > $threshold" | bc -l 2>/dev/null || echo 0))) ;;
        "ge") (($(echo "$value >= $threshold" | bc -l 2>/dev/null || echo 0))) ;;
        *) return 1 ;;
    esac
}

# ================================================
# CONFIGURATION FUNCTIONS
# ================================================

ensure_state_dir() {
    mkdir -p "$STATE_DIR" 2>/dev/null || return 1
    chmod 700 "$STATE_DIR" 2>/dev/null || true
}

# Persist only firewall rules that this script actually introduced. Existing
# UFW/firewalld allowances are deliberately not claimed or removed later.
record_managed_firewall_rule() {
    local backend="$1"
    local protocol="$2"
    local port="$3"
    validate_port "$port" || return 1
    case "$backend:$protocol" in
        ufw:tcp|firewalld:tcp) ;;
        *) return 1 ;;
    esac

    ensure_state_dir || return 1
    touch "$FIREWALL_STATE_FILE" || return 1
    chmod 600 "$FIREWALL_STATE_FILE" 2>/dev/null || true
    local entry="$backend|$protocol|$port"
    grep -Fxq "$entry" "$FIREWALL_STATE_FILE" 2>/dev/null || printf '%s\n' "$entry" >> "$FIREWALL_STATE_FILE"
}

# Configure iptables
configure_iptables() {
    local port="$1"
    local protocol="$2"
    
    print_step "Configuring iptables for port $port protocol $protocol..."
    
    if ! command -v iptables &>/dev/null; then
        print_warning "iptables not found, skipping"
        return 0
    fi
    
    local protocols=()
    [ "$protocol" = "both" ] && protocols=("tcp" "udp") || protocols=("$protocol")
    
    for proto in "${protocols[@]}"; do
        iptables -t raw -D PREROUTING -p "$proto" --dport "$port" -m comment --comment "$FIREWALL_COMMENT" -j NOTRACK 2>/dev/null || true
        iptables -t raw -D OUTPUT -p "$proto" --sport "$port" -m comment --comment "$FIREWALL_COMMENT" -j NOTRACK 2>/dev/null || true
        iptables -t raw -D PREROUTING -p "$proto" --dport "$port" -j NOTRACK 2>/dev/null || true
        iptables -t raw -D OUTPUT -p "$proto" --sport "$port" -j NOTRACK 2>/dev/null || true
        
        iptables -t raw -A PREROUTING -p "$proto" --dport "$port" -m comment --comment "$FIREWALL_COMMENT" -j NOTRACK
        iptables -t raw -A OUTPUT -p "$proto" --sport "$port" -m comment --comment "$FIREWALL_COMMENT" -j NOTRACK
        
        if [ "$proto" = "tcp" ]; then
            # Drop kernel RSTs on BOTH directions: the local kernel has no socket
            # for our raw flow, so it would answer inbound segments with a RST and
            # also emit outbound RSTs — either one tears the tunnel down.
            iptables -t mangle -D OUTPUT -p tcp --sport "$port" --tcp-flags RST RST -m comment --comment "$FIREWALL_COMMENT" -j DROP 2>/dev/null || true
            iptables -t mangle -D PREROUTING -p tcp --dport "$port" --tcp-flags RST RST -m comment --comment "$FIREWALL_COMMENT" -j DROP 2>/dev/null || true
            iptables -t mangle -D OUTPUT -p tcp --sport "$port" --tcp-flags RST RST -j DROP 2>/dev/null || true
            iptables -t mangle -D PREROUTING -p tcp --dport "$port" --tcp-flags RST RST -j DROP 2>/dev/null || true
            iptables -t mangle -A OUTPUT -p tcp --sport "$port" --tcp-flags RST RST -m comment --comment "$FIREWALL_COMMENT" -j DROP
            iptables -t mangle -A PREROUTING -p tcp --dport "$port" --tcp-flags RST RST -m comment --comment "$FIREWALL_COMMENT" -j DROP
        fi
    done
    
    print_success "iptables configured for $protocol on port $port"
    save_iptables
}

# Apply Anti-RST + NOTRACK for a client's remote peer (server ip:port). This is
# the tunnel leg the client dials out on; without it the local kernel RSTs the
# raw flow and conntrack burns memory. Idempotent (checks before adding).
protect_client_peer() {
    local sip="$1"
    local sport="$2"

    command -v iptables &>/dev/null || return 0
    validate_ip "$sip" 2>/dev/null || return 0
    validate_port "$sport" 2>/dev/null || return 0

    iptables -t raw -C OUTPUT -p tcp -d "$sip" --dport "$sport" -m comment --comment "$FIREWALL_COMMENT" -j NOTRACK 2>/dev/null || \
        iptables -t raw -C OUTPUT -p tcp -d "$sip" --dport "$sport" -j NOTRACK 2>/dev/null || \
        iptables -t raw -A OUTPUT -p tcp -d "$sip" --dport "$sport" -m comment --comment "$FIREWALL_COMMENT" -j NOTRACK
    iptables -t raw -C PREROUTING -p tcp -s "$sip" --sport "$sport" -m comment --comment "$FIREWALL_COMMENT" -j NOTRACK 2>/dev/null || \
        iptables -t raw -C PREROUTING -p tcp -s "$sip" --sport "$sport" -j NOTRACK 2>/dev/null || \
        iptables -t raw -A PREROUTING -p tcp -s "$sip" --sport "$sport" -m comment --comment "$FIREWALL_COMMENT" -j NOTRACK
    iptables -t mangle -C OUTPUT -p tcp -d "$sip" --dport "$sport" --tcp-flags RST RST -m comment --comment "$FIREWALL_COMMENT" -j DROP 2>/dev/null || \
        iptables -t mangle -C OUTPUT -p tcp -d "$sip" --dport "$sport" --tcp-flags RST RST -j DROP 2>/dev/null || \
        iptables -t mangle -A OUTPUT -p tcp -d "$sip" --dport "$sport" --tcp-flags RST RST -m comment --comment "$FIREWALL_COMMENT" -j DROP
    iptables -t mangle -C PREROUTING -p tcp -s "$sip" --sport "$sport" --tcp-flags RST RST -m comment --comment "$FIREWALL_COMMENT" -j DROP 2>/dev/null || \
        iptables -t mangle -C PREROUTING -p tcp -s "$sip" --sport "$sport" --tcp-flags RST RST -j DROP 2>/dev/null || \
        iptables -t mangle -A PREROUTING -p tcp -s "$sip" --sport "$sport" --tcp-flags RST RST -m comment --comment "$FIREWALL_COMMENT" -j DROP
}

# Protect a client's primary server.addr plus every server.addrs[] failover
# entry found in a config file.
configure_client_iptables() {
    local config="$1"

    if ! command -v iptables &>/dev/null; then
        print_warning "iptables not found, skipping client tunnel protection"
        return 0
    fi

    local applied=0
    local addr sip sport
    while IFS= read -r addr; do
        [ -z "$addr" ] && continue
        sip="${addr%:*}"
        sport="${addr##*:}"
        if validate_ip "$sip" 2>/dev/null && validate_port "$sport" 2>/dev/null; then
            protect_client_peer "$sip" "$sport"
            ((applied++))
        fi
    done < <(extract_client_server_addrs "$config")

    if [ "$applied" -gt 0 ]; then
        print_success "Client tunnel protection applied to $applied peer(s)"
        save_iptables
    fi
}

# Print every server address (primary addr + addrs[] list) from a client config,
# one ip:port per line.
extract_client_server_addrs() {
    local config="$1"
    [ -f "$config" ] || return 0
    awk '
        /^server:/ { in_server=1; next }
        /^[^[:space:]]/ { if (in_server) in_server=0 }
        in_server {
            if ($1 == "addr:") { v=$2; gsub(/"/,"",v); print v }
            else if ($1 == "-") { v=$2; gsub(/"/,"",v); print v }
        }
    ' "$config"
}

# Return the protocol under the top-level transport section without confusing
# it with forward[].protocol entries.
config_transport_protocol() {
    local config="$1"
    awk '
        /^transport:/ { in_transport=1; next }
        /^[^[:space:]]/ { if (in_transport) exit }
        in_transport && $1 == "protocol:" {
            value=$2; gsub(/"/, "", value); print value; exit
        }
    ' "$config" 2>/dev/null
}

# Install a binary onto a possibly-running path without hitting ETXTBSY.
# Writing directly to a file that is currently executing fails with
# "Text file busy"; renaming a sibling temp file swaps the directory entry
# atomically and leaves the running inode untouched.
atomic_install_binary() {
    local src="$1"
    local dest="${2:-$BIN_DIR/paqet}"
    local dir
    dir="$(dirname "$dest")"
    mkdir -p "$dir"

    local tmp="${dir}/.paqet.new.$$"
    if ! cp -f "$src" "$tmp" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    chmod 0755 "$tmp" 2>/dev/null || true
    if ! mv -f "$tmp" "$dest" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    return 0
}

# Create systemd service
create_systemd_service() {
    local config_name="$1"
    local service_name="paqet-${config_name}"
    
    cat > "$SERVICE_DIR/${service_name}.service" << EOF
[Unit]
Description=Paqet Tunnel (${config_name})
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=$BIN_DIR/paqet run -c $CONFIG_DIR/${config_name}.yaml
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    print_success "Service created: ${service_name}"
}

# Enabling an already-running unit does not reload a newly written config.
# Always restart an active service after a wizard overwrite; start it otherwise.
enable_and_refresh_service() {
    local service_name="$1"

    systemctl enable "$service_name" >/dev/null 2>&1 || return 1
    if systemctl is-active --quiet "$service_name"; then
        systemctl restart "$service_name" >/dev/null 2>&1
    else
        systemctl start "$service_name" >/dev/null 2>&1
    fi
}

# ================================================
# CRONJOB MANAGEMENT
# ================================================

# Add auto-restart cronjob
add_auto_restart_cronjob() {
    local service_name="$1"
    local cron_interval="$2"
    local cron_command="systemctl restart ${service_name}"
    
    local cron_line="${RESTART_INTERVALS[$cron_interval]} $cron_command"
    [ -z "$cron_line" ] && { print_error "Invalid cron interval"; return 1; }
    
    if crontab -l 2>/dev/null | grep -q "$cron_command"; then
        crontab -l 2>/dev/null | grep -v "$cron_command" | crontab -
    fi
    
    (crontab -l 2>/dev/null; echo "$cron_line") | crontab -
    
    if [ $? -eq 0 ]; then
        print_success "Cronjob added: $cron_interval restart for $service_name"
        return 0
    else
        print_error "Failed to add cronjob"
        return 1
    fi
}

# Remove cronjob
remove_cronjob() {
    local service_name="$1"
    local cron_command="systemctl restart ${service_name}"
    
    if crontab -l 2>/dev/null | grep -q "$cron_command"; then
        crontab -l 2>/dev/null | grep -v "$cron_command" | crontab -
        print_success "Cronjob removed for $service_name"
        return 0
    fi
    print_info "No cronjob found for $service_name"
    return 1
}

# View cronjob
view_cronjob() {
    local service_name="$1"
    local cron_command="systemctl restart ${service_name}"
    
    echo -e "${YELLOW}Cronjobs for $service_name:${NC}"
    if crontab -l 2>/dev/null | grep -q "$cron_command"; then
        crontab -l 2>/dev/null | grep "$cron_command"
    else
        print_info "No cronjob found"
    fi
}

# Manage cronjob menu
manage_cronjob() {
    local service_name="$1"
    local display_name="$2"
    
    while true; do
        clear
        show_banner
        echo -e "${YELLOW}Manage Cronjob for: $display_name${NC}\n"
        
        echo -e "${CYAN}Current cronjob:${NC}"
        view_cronjob "$service_name"
        echo -e "\n${CYAN}Add/Change Cronjob:${NC}"
        
        local i=1
        for interval in "${!RESTART_INTERVALS[@]}"; do
            echo " $((i++)). $interval"
        done
        echo " $i. Remove cronjob"
        echo " 0. Back"
        echo ""
        
        read -p "Choose option [0-$i]: " cron_choice
        
        if [ "$cron_choice" = "0" ]; then
            return
        elif [ "$cron_choice" -eq "$i" ]; then
            remove_cronjob "$service_name"
            pause
        elif [ "$cron_choice" -ge 1 ] && [ "$cron_choice" -lt "$i" ]; then
            local idx=1
            for interval in "${!RESTART_INTERVALS[@]}"; do
                if [ "$cron_choice" -eq "$idx" ]; then
                    add_auto_restart_cronjob "$service_name" "$interval"
                    break
                fi
                ((idx++))
            done
            pause
        else
            print_error "Invalid choice"
            sleep 1
        fi
    done
}

# ================================================
# SERVICE MANAGEMENT
# ================================================

# Remove every artifact owned by one tunnel without touching shared manager
# state or certificates that live outside CONFIG_DIR (for example Certbot).
remove_service_artifacts() {
    local selected_service="$1"
    local display_name="$2"
    local config_file="$CONFIG_DIR/$display_name.yaml"
    local config_file_yml="$CONFIG_DIR/$display_name.yml"
    local failed=0

    [[ "$selected_service" =~ ^paqet-[[:alnum:]_-]+\.service$ ]] || return 1
    [ "$(clean_config_name "$display_name")" = "$display_name" ] || return 1

    # Firewall rules must be derived while the config still exists.
    if [ -f "$config_file" ]; then
        cleanup_paqet_iptables_from_configs "$config_file" || failed=1
        cleanup_managed_firewall_for_config "$config_file" || failed=1
    elif [ -f "$config_file_yml" ]; then
        cleanup_paqet_iptables_from_configs "$config_file_yml" || failed=1
        cleanup_managed_firewall_for_config "$config_file_yml" || failed=1
    fi

    remove_cronjob "${selected_service%.service}" >/dev/null 2>&1 || true
    systemctl stop "$selected_service" >/dev/null 2>&1 || true
    systemctl disable "$selected_service" >/dev/null 2>&1 || true

    rm -f "$SERVICE_DIR/$selected_service" \
        "/lib/systemd/system/$selected_service" \
        "/usr/lib/systemd/system/$selected_service" 2>/dev/null || failed=1
    rm -rf "$SERVICE_DIR/$selected_service.d" \
        "/lib/systemd/system/$selected_service.d" \
        "/usr/lib/systemd/system/$selected_service.d" 2>/dev/null || failed=1
    find "$SERVICE_DIR" /lib/systemd/system /usr/lib/systemd/system -type l \
        -name "$selected_service" -delete 2>/dev/null || failed=1

    rm -f "$config_file" "$config_file_yml" 2>/dev/null || failed=1
    rm -rf "$CONFIG_DIR/tls/$display_name" 2>/dev/null || failed=1

    systemctl daemon-reload >/dev/null 2>&1 || failed=1
    systemctl reset-failed "$selected_service" >/dev/null 2>&1 || true
    save_iptables >/dev/null 2>&1 || true
    return "$failed"
}

# Get service details
get_service_details() {
    local service_name="$1"
    local config_name="${service_name#paqet-}"
    local config_file="$CONFIG_DIR/$config_name.yaml"
    
    local type="unknown"
    local mode="fast"
    local mtu="-"
    local conn="-"
    local cron="No"
    
    if [ -f "$config_file" ]; then
        type=$(grep "^role:" "$config_file" 2>/dev/null | awk '{print $2}' | tr -d '"' || echo "unknown")
        
        local mode_line
        mode_line=$(grep "mode:" "$config_file" 2>/dev/null | head -1)
        [ -n "$mode_line" ] && mode=$(echo "$mode_line" | awk '{print $2}' | tr -d '"')
        
        if grep -q "mtu:" "$config_file" 2>/dev/null; then
            local mtu_line
            mtu_line=$(grep "mtu:" "$config_file" 2>/dev/null | head -1)
            [ -n "$mtu_line" ] && mtu=$(echo "$mtu_line" | awk '{print $2}' | tr -d '"')
        fi
        
        if grep -q "conn:" "$config_file" 2>/dev/null; then
            local conn_line
            conn_line=$(grep "conn:" "$config_file" 2>/dev/null | head -1)
            [ -n "$conn_line" ] && conn=$(echo "$conn_line" | awk '{print $2}' | tr -d '"')
        fi
    fi
    
    crontab -l 2>/dev/null | grep -q "systemctl restart $service_name" && cron="Yes"
    
    echo "$type $mode $mtu $conn $cron"
}

# Manage single service
manage_single_service() {
    local selected_service="$1"
    local display_name="$2"
    
    while true; do
        clear
        show_banner
        
        local short_name="${display_name:0:32}"
        [ ${#display_name} -gt 32 ] && short_name="${short_name}..."
        
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
        printf "${GREEN}║ Managing: %-50s ║${NC}\n" "$short_name"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}\n"
        
        local status
        status=$(systemctl is-active "$selected_service" 2>/dev/null || echo "unknown")
        
        echo -e "${CYAN}Status:${NC} "
        case "$status" in
            active) echo -e "${GREEN}🟢 Active${NC}" ;;
            failed) echo -e "${RED}🔴 Failed${NC}" ;;
            inactive) echo -e "${YELLOW}🟡 Inactive${NC}" ;;
            *) echo -e "${WHITE}⚪ Unknown${NC}" ;;
        esac
        
        local details
        details=$(get_service_details "${selected_service%.service}")
        local type=$(echo "$details" | awk '{print $1}')
        local mode=$(echo "$details" | awk '{print $2}')
        local mtu=$(echo "$details" | awk '{print $3}')
        local conn=$(echo "$details" | awk '{print $4}')
        local cron=$(echo "$details" | awk '{print $5}')
        
        echo -e "\n${CYAN}Details:${NC}"
        echo -e "${CYAN}┌──────────────────────────────────────────────┐${NC}"
        printf "${CYAN}│${NC} %-16s ${CYAN}:${NC} %-25s ${CYAN}│${NC}\n" "Type" "${type:-unknown}"
        printf "${CYAN}│${NC} %-16s ${CYAN}:${NC} %-25s ${CYAN}│${NC}\n" "KCP Mode" "${mode:-fast}"
        printf "${CYAN}│${NC} %-16s ${CYAN}:${NC} %-25s ${CYAN}│${NC}\n" "MTU" "${mtu:--}"
        printf "${CYAN}│${NC} %-16s ${CYAN}:${NC} %-25s ${CYAN}│${NC}\n" "Connections" "${conn:--}"
        printf "${CYAN}│${NC} %-16s ${CYAN}:${NC} %-25s ${CYAN}│${NC}\n" "Auto-Restart" "${cron:-No}"
        echo -e "${CYAN}└──────────────────────────────────────────────┘${NC}"
        
        echo -e "\n${CYAN}Actions${NC}"
        echo " 1. 🟢 Start"
        echo " 2. 🔴 Stop"
        echo " 3. 🔄 Restart"
        echo " 4. 📊 Show Status"
        echo " 5. 📝 View Recent Logs"
        echo " 6. ✏️  Edit Configuration"
        echo " 7. 📄 View Configuration"
        echo " 8. ⏰ Cronjob Management"
        echo " 9. 🗑️  Delete Service"
        echo " 0. ↩️  Back"
        echo ""
        
        read -p "Choose action [0-9]: " action
        
        case "$action" in
            0) return ;;
            1) systemctl start "$selected_service" >/dev/null 2>&1
               print_success "Service started"
               sleep 1.5 ;;
            2) systemctl stop "$selected_service" >/dev/null 2>&1
               print_success "Service stopped"
               sleep 1.5 ;;
            3) systemctl restart "$selected_service" >/dev/null 2>&1
               print_success "Service restarted"
               sleep 1.5 ;;
            4) echo ""
               systemctl status "$selected_service" --no-pager -l
               pause ;;
            5) echo ""
               journalctl -u "$selected_service" -n 25 --no-pager
               pause ;;
            6) local cfg="$CONFIG_DIR/$display_name.yaml"
               if [ -f "$cfg" ]; then
                   echo -e "\n${YELLOW}Editing: $cfg${NC}"
                   local editor="nano"
                   command -v nano &>/dev/null || editor="vi"
                   $editor "$cfg"
                   
                   read -p "Restart service to apply changes? (y/N): " restart_choice
                   if [[ "$restart_choice" =~ ^[Yy]$ ]]; then
                       systemctl restart "$selected_service" >/dev/null 2>&1
                       if systemctl is-active --quiet "$selected_service"; then
                           print_success "Service restarted"
                       else
                           print_error "Service failed to start"
                           systemctl status "$selected_service" --no-pager -l
                       fi
                   fi
               else
                   print_error "Config file not found"
               fi
               pause ;;
            7) local cfg="$CONFIG_DIR/$display_name.yaml"
               if [ -f "$cfg" ]; then
                   echo -e "\n${CYAN}$cfg${NC}\n"
                   cat "$cfg"
               else
                   print_error "Config file not found"
               fi
               pause ;;
            8) manage_cronjob "${selected_service%.service}" "$display_name" ;;
            9) read -p "Delete this service and all of its config, TLS files, firewall rules and cronjob? (y/N): " confirm
               if [[ "$confirm" =~ ^[Yy]$ ]]; then
                   if remove_service_artifacts "$selected_service" "$display_name"; then
                       print_success "Service and all owned artifacts removed"
                   else
                       print_warning "Service removal finished, but one or more artifacts could not be removed"
                   fi
                   pause
                   return
               fi ;;
            *) print_error "Invalid choice"
               sleep 1 ;;
        esac
    done
}

# Manage all services
manage_services() {
    while true; do
        clear
        show_banner
        
        echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║ Paqet Services - Manage                                                                                   ║${NC}"
        echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════════════════════════════════════════════╝${NC}\n"
        
        local services=()
        mapfile -t services < <(systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null |
                              grep -E '^paqet-.*\.service' | awk '{print $1}' || true)
        
        if [[ ${#services[@]} -eq 0 ]]; then
            echo -e "${YELLOW}No Paqet services found.${NC}\n"
            pause
            return
        fi
        
        echo -e "${CYAN}┌─────┬──────────────────────────┬─────────────┬───────────┬────────────────┬────────────┬──────────┬────────┐${NC}"
        echo -e "${CYAN}│  #  │ Service Name             │ Status      │ Type      │ Auto Restart   │ Mode       │ MTU      │ Conn   │${NC}"
        echo -e "${CYAN}├─────┼──────────────────────────┼─────────────┼───────────┼────────────────┼────────────┼──────────┼────────┤${NC}"
        
        local i=1
        for svc in "${services[@]}"; do
            local service_name="${svc%.service}"
            local display_name="${service_name#paqet-}"
            local status
            status=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
            local details
            details=$(get_service_details "$service_name")
            local type=$(echo "$details" | awk '{print $1}')
            local mode=$(echo "$details" | awk '{print $2}')
            local mtu=$(echo "$details" | awk '{print $3}')
            local conn=$(echo "$details" | awk '{print $4}')
            local cron=$(echo "$details" | awk '{print $5}')
            
            local status_color=""
            case "$status" in
                active) status_color="${GREEN}" ;;
                failed) status_color="${RED}" ;;
                inactive) status_color="${YELLOW}" ;;
                *) status_color="${WHITE}" ;;
            esac
            
            local mode_color=""
            case "$mode" in
                normal) mode_color="${CYAN}" ;;
                fast) mode_color="${GREEN}" ;;
                fast2) mode_color="${ORANGE}" ;;
                fast3) mode_color="${PURPLE}" ;;
                manual) mode_color="${RED}" ;;
                *) mode_color="${WHITE}" ;;
            esac
            
            printf "${CYAN}│${NC} %3d ${CYAN}│${NC} %-24s ${CYAN}│${NC} ${status_color}%-11s${NC} ${CYAN}│${NC} %-9s ${CYAN}│${NC} %-14s ${CYAN}│${NC} ${mode_color}%-10s${NC} ${CYAN}│${NC} %-8s ${CYAN}│${NC} %-6s ${CYAN}│${NC}\n" \
                "$i" "${display_name:0:24}" "$status" "${type:-unknown}" "${cron:-No}" "${mode:-fast}" "${mtu:--}" "${conn:--}"
            ((i++))
        done
        
        echo -e "${CYAN}└─────┴──────────────────────────┴─────────────┴───────────┴────────────────┴────────────┴──────────┴────────┘${NC}\n"
        echo -e "${YELLOW}Options:${NC}"
        echo -e " 0. ↩️ Back to Main Menu"
        echo -e " 1–${#services[@]}. Select a service to manage"
        echo ""
        
        read -p "Enter choice (0 to cancel): " choice
        
        [ "$choice" = "0" ] && return
        
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#services[@]} )); then
            print_error "Invalid selection"
            sleep 1.5
            continue
        fi
        
        local selected_service="${services[$((choice-1))]}"
        local service_name="${selected_service%.service}"
        local display_name="${service_name#paqet-}"
        manage_single_service "$selected_service" "$display_name"
    done
}

# ================================================
# KCP MANUAL SETTINGS
# ================================================
get_manual_kcp_settings() {
    local nodelay=""
    while true; do
        read -p "[1] nodelay [0-2, default 1, 0=skip]: " input
        if [ -z "$input" ]; then
            nodelay="1"
            echo -e "  ${GREEN}→ Using default: 1${NC}" >&2
            break
        elif [ "$input" = "0" ]; then
            nodelay=""
            echo -e "  ${YELLOW}→ Skipped${NC}" >&2
            break
        elif [[ "$input" =~ ^[0-2]$ ]]; then
            nodelay="$input"
            echo -e "  ${GREEN}→ Set to: $input${NC}" >&2
            break
        else
            echo -e "  ${RED}✗ Invalid: Value must be 0, 1 or 2${NC}" >&2
        fi
    done
    
    local interval=""
    while true; do
        read -p "[2] interval (ms) [default 20, 0=skip]: " input
        if [ -z "$input" ]; then
            interval="20"
            echo -e "  ${GREEN}→ Using default: 20${NC}" >&2
            break
        elif [ "$input" = "0" ]; then
            interval=""
            echo -e "  ${YELLOW}→ Skipped${NC}" >&2
            break
        elif [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 5 ] && [ "$input" -le 60000 ]; then
            interval="$input"
            echo -e "  ${GREEN}→ Set to: $input${NC}" >&2
            break
        else
            echo -e "  ${RED}✗ Invalid: Range 5–60000 ms${NC}" >&2
        fi
    done
    
    local resend=""
    while true; do
        read -p "[3] resend [0-∞, default 1, 0=skip]: " input
        if [ -z "$input" ]; then
            resend="1"
            echo -e "  ${GREEN}→ Using default: 1${NC}" >&2
            break
        elif [ "$input" = "0" ]; then
            resend=""
            echo -e "  ${YELLOW}→ Skipped${NC}" >&2
            break
        elif [[ "$input" =~ ^[0-9]+$ ]]; then
            resend="$input"
            echo -e "  ${GREEN}→ Set to: $input${NC}" >&2
            break
        else
            echo -e "  ${RED}✗ Invalid: Must be non-negative number${NC}" >&2
        fi
    done
    
    local nocongestion=""
    while true; do
        read -p "[4] nocongestion [0=enabled, 1=disabled, default 0]: " input
        if [ -z "$input" ]; then
            nocongestion="0"
            echo -e "  ${GREEN}→ Using default: 0 (congestion control enabled)${NC}" >&2
            break
        elif [[ "$input" =~ ^[01]$ ]]; then
            nocongestion="$input"
            echo -e "  ${GREEN}→ Set to: $input${NC}" >&2
            break
        else
            echo -e "  ${RED}✗ Invalid: Only 0 or 1 allowed${NC}" >&2
        fi
    done
    
    local rcvwnd=""
    while true; do
        read -p "[5] rcvwnd [default 2048, 0=skip]: " input
        if [ -z "$input" ]; then
            rcvwnd="2048"
            echo -e "  ${GREEN}→ Using default: 2048${NC}" >&2
            break
        elif [ "$input" = "0" ]; then
            rcvwnd=""
            echo -e "  ${YELLOW}→ Skipped${NC}" >&2
            break
        elif [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 128 ]; then
            rcvwnd="$input"
            echo -e "  ${GREEN}→ Set to: $input${NC}" >&2
            break
        else
            echo -e "  ${RED}✗ Invalid: Minimum 128${NC}" >&2
        fi
    done
    
    local sndwnd=""
    while true; do
        read -p "[6] sndwnd [default 2048, 0=skip]: " input
        if [ -z "$input" ]; then
            sndwnd="2048"
            echo -e "  ${GREEN}→ Using default: 2048${NC}" >&2
            break
        elif [ "$input" = "0" ]; then
            sndwnd=""
            echo -e "  ${YELLOW}→ Skipped${NC}" >&2
            break
        elif [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 128 ]; then
            sndwnd="$input"
            echo -e "  ${GREEN}→ Set to: $input${NC}" >&2
            break
        else
            echo -e "  ${RED}✗ Invalid: Minimum 128${NC}" >&2
        fi
    done
    
    local wdelay=""
    while true; do
        read -p "[7] wdelay (true/false) [default false, 0=skip]: " input
        if [ -z "$input" ]; then
            wdelay="false"
            echo -e "  ${GREEN}→ Using default: false${NC}" >&2
            break
        elif [ "$input" = "0" ]; then
            wdelay=""
            echo -e "  ${YELLOW}→ Skipped${NC}" >&2
            break
        elif [[ "${input,,}" = "false" ]]; then
            wdelay="false"
            echo -e "  ${GREEN}→ Set to: false${NC}" >&2
            break
        elif [[ "${input,,}" = "true" ]]; then
            wdelay="true"
            echo -e "  ${GREEN}→ Set to: true${NC}" >&2
            break
        else
            echo -e "  ${RED}✗ Invalid: Only true or false${NC}" >&2
        fi
    done
    
    local acknodelay=""
    while true; do
        read -p "[8] acknodelay (true/false) [default true, 0=skip]: " input
        if [ -z "$input" ]; then
            acknodelay="true"
            echo -e "  ${GREEN}→ Using default: true${NC}" >&2
            break
        elif [ "$input" = "0" ]; then
            acknodelay=""
            echo -e "  ${YELLOW}→ Skipped${NC}" >&2
            break
        elif [[ "${input,,}" = "true" ]]; then
            acknodelay="true"
            echo -e "  ${GREEN}→ Set to: true${NC}" >&2
            break
        elif [[ "${input,,}" = "false" ]]; then
            acknodelay="false"
            echo -e "  ${GREEN}→ Set to: false${NC}" >&2
            break
        else
            echo -e "  ${RED}✗ Invalid: Only true or false${NC}" >&2
        fi
    done
    
    local smuxbuf=""
    echo -en "[9] smuxbuf [default 4194304, 0=skip]: " >&2
    read -r smuxbuf_input
    if [ -z "$smuxbuf_input" ]; then
        smuxbuf="4194304"
        echo -e "  ${GREEN}→ Using default: 4194304${NC}" >&2
    elif [ "$smuxbuf_input" = "0" ]; then
        smuxbuf=""
        echo -e "  ${YELLOW}→ Skipped${NC}" >&2
    else
        smuxbuf="$smuxbuf_input"
        echo -e "  ${GREEN}→ Set to: $smuxbuf_input${NC}" >&2
    fi
    
    local streambuf=""
    echo -en "[10] streambuf [default 2097152, 0=skip]: " >&2
    read -r streambuf_input
    if [ -z "$streambuf_input" ]; then
        streambuf="2097152"
        echo -e "  ${GREEN}→ Using default: 2097152${NC}" >&2
    elif [ "$streambuf_input" = "0" ]; then
        streambuf=""
        echo -e "  ${YELLOW}→ Skipped${NC}" >&2
    else
        streambuf="$streambuf_input"
        echo -e "  ${GREEN}→ Set to: $streambuf_input${NC}" >&2
    fi
    
    local dshard=""
    echo -en "[11] dshard (FEC data) [default 10, 0=skip]: " >&2
    read -r dshard_input
    if [ -z "$dshard_input" ]; then
        dshard="10"
        echo -e "  ${GREEN}→ Using default: 10${NC}" >&2
    elif [ "$dshard_input" = "0" ]; then
        dshard=""
        echo -e "  ${YELLOW}→ Skipped${NC}" >&2
    else
        dshard="$dshard_input"
        echo -e "  ${GREEN}→ Set to: $dshard_input${NC}" >&2
    fi
    
    local pshard=""
    echo -en "[12] pshard (FEC parity) [default 3, 0=skip]: " >&2
    read -r pshard_input
    if [ -z "$pshard_input" ]; then
        pshard="3"
        echo -e "  ${GREEN}→ Using default: 3${NC}" >&2
    elif [ "$pshard_input" = "0" ]; then
        pshard=""
        echo -e "  ${YELLOW}→ Skipped${NC}" >&2
    else
        pshard="$pshard_input"
        echo -e "  ${GREEN}→ Set to: $pshard_input${NC}" >&2
    fi

    echo "" >&2

    # Only output parameters that have values
    echo "mode: \"manual\""
    [ -n "$nodelay" ] && echo "nodelay: $nodelay"
    [ -n "$interval" ] && echo "interval: $interval"
    [ -n "$resend" ] && echo "resend: $resend"
    [ -n "$nocongestion" ] && echo "nocongestion: $nocongestion"
    [ -n "$rcvwnd" ] && echo "rcvwnd: $rcvwnd"
    [ -n "$sndwnd" ] && echo "sndwnd: $sndwnd"
    [ -n "$wdelay" ] && echo "wdelay: $wdelay"
    [ -n "$acknodelay" ] && echo "acknodelay: $acknodelay"
    [ -n "$smuxbuf" ] && echo "smuxbuf: $smuxbuf"
    [ -n "$streambuf" ] && echo "streambuf: $streambuf"
    [ -n "$dshard" ] && echo "dshard: $dshard"
    [ -n "$pshard" ] && echo "pshard: $pshard"
}

# ================================================
# CONFIGURATION MENUS
# ================================================

# Open a normal kernel TCP listener. Do not apply the raw-pcap NOTRACK or RST
# suppression rules here; those rules break a real TCP/TLS transport.
configure_tls_firewall() {
    local port="$1"
    print_step "Opening TCP/$port for the v3 TLS listener..."

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        if ! ufw status 2>/dev/null | grep -Eq "^[[:space:]]*${port}/tcp[[:space:]]+ALLOW"; then
            ufw allow "$port/tcp" >/dev/null 2>&1 || return 1
            if ! record_managed_firewall_rule ufw tcp "$port"; then
                ufw --force delete allow "$port/tcp" >/dev/null 2>&1 || true
                return 1
            fi
        fi
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        if ! firewall-cmd --permanent --query-port="$port/tcp" >/dev/null 2>&1; then
            firewall-cmd --permanent --add-port="$port/tcp" >/dev/null 2>&1 || return 1
            firewall-cmd --reload >/dev/null 2>&1 || return 1
            if ! record_managed_firewall_rule firewalld tcp "$port"; then
                firewall-cmd --permanent --remove-port="$port/tcp" >/dev/null 2>&1 || true
                firewall-cmd --reload >/dev/null 2>&1 || true
                return 1
            fi
        fi
    elif command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p tcp --dport "$port" -m conntrack --ctstate NEW,ESTABLISHED \
            -m comment --comment "$FIREWALL_COMMENT" -j ACCEPT 2>/dev/null || \
            iptables -C INPUT -p tcp --dport "$port" -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT 2>/dev/null || \
            iptables -A INPUT -p tcp --dport "$port" -m conntrack --ctstate NEW,ESTABLISHED \
                -m comment --comment "$FIREWALL_COMMENT" -j ACCEPT
        save_iptables
    else
        print_warning "No supported firewall manager found; open TCP/$port manually"
    fi
    print_success "TLS firewall rule ready on TCP/$port"
}

generate_v3_tls_certificate() {
    local config_name="$1"
    local identity="$2"
    local tls_dir="$CONFIG_DIR/tls/$config_name"
    local cert_file="$tls_dir/server.crt"
    local key_file="$tls_dir/server.key"
	local san_type="DNS"
	validate_ip "$identity" 2>/dev/null && san_type="IP"

    command -v openssl >/dev/null 2>&1 || {
        print_error "OpenSSL is required to generate the v3 certificate"
        return 1
    }
    mkdir -p "$tls_dir"
    chmod 700 "$tls_dir"
    if ! openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -sha256 -days 825 -nodes -keyout "$key_file" -out "$cert_file" \
        -subj "/CN=$identity" -addext "subjectAltName=$san_type:$identity" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,digitalSignature,keyCertSign" \
        -addext "extendedKeyUsage=serverAuth" >/dev/null 2>&1; then
        print_error "Could not generate the TLS certificate"
        return 1
    fi
    chmod 600 "$key_file" "$cert_file"
    printf '%s\n%s\n' "$cert_file" "$key_file"
}

# Pairing codes move only public bootstrap data (endpoint, certificate name and
# server.crt). The shared secret and private key are deliberately excluded.
v3_validate_endpoint() {
    local endpoint="$1"
    local host port
    host="${endpoint%:*}"
    port="${endpoint##*:}"
    validate_port "$port" || return 1
    [[ "$host" =~ ^[A-Za-z0-9.-]+$ || "$host" =~ ^\[[0-9A-Fa-f:]+\]$ ]]
}

v3_validate_cover_path() {
	local cover_path="$1"
	[[ "$cover_path" =~ ^/[A-Za-z0-9._~/-]{1,159}$ ]] || return 1
	[[ "$cover_path" != *".."* && "$cover_path" != *"//"* ]]
}

v3_b64_encode() {
    base64 | tr -d '\r\n'
}

v3_verify_pairing_certificate() {
    local cert_file="$1"
    local identity="$2"
    local -a verify_name_arg
    openssl x509 -in "$cert_file" -noout -checkend 0 >/dev/null 2>&1 || return 1
    if validate_ip "$identity" 2>/dev/null; then
        verify_name_arg=(-verify_ip "$identity")
    else
        verify_name_arg=(-verify_hostname "$identity")
    fi
    openssl verify -CAfile "$cert_file" "${verify_name_arg[@]}" "$cert_file" >/dev/null 2>&1
}

v3_create_pairing_code() {
    local cert_file="$1"
    local endpoint="$2"
    local identity="$3"
	local cover_path="${4:-}"

    command -v base64 >/dev/null 2>&1 || return 1
    command -v openssl >/dev/null 2>&1 || return 1
    [ -f "$cert_file" ] || return 1
    v3_validate_endpoint "$endpoint" || return 1
    [[ "$identity" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    v3_verify_pairing_certificate "$cert_file" "$identity" || return 1

	if [ -n "$cover_path" ]; then
		v3_validate_cover_path "$cover_path" || return 1
	fi

    local endpoint_b64 identity_b64 path_b64 cert_b64
    endpoint_b64=$(printf '%s' "$endpoint" | v3_b64_encode) || return 1
    identity_b64=$(printf '%s' "$identity" | v3_b64_encode) || return 1
    cert_b64=$(v3_b64_encode < "$cert_file") || return 1
	if [ -n "$cover_path" ]; then
		path_b64=$(printf '%s' "$cover_path" | v3_b64_encode) || return 1
		printf 'WPQ4|%s|%s|%s|%s\n' "$endpoint_b64" "$identity_b64" "$path_b64" "$cert_b64"
	else
		printf 'WPQ3|%s|%s|%s\n' "$endpoint_b64" "$identity_b64" "$cert_b64"
	fi
}

# A pasted code picks up terminal wrapping, CRLF from a Windows clipboard and
# shell quotes. None of those characters belong to the base64 payload, so they
# are removed before parsing instead of being reported as a broken code.
v3_sanitize_pairing_code() {
	local code="$1"
	code="${code//[$' \t\r\n\v\f']/}"
	code="${code//\"/}"
	code="${code//\'/}"
	printf '%s' "$code"
}

# Marks the end of a wrapped code so the Iran wizard knows the paste is whole
# and never imports a chain that stopped at an intermediate certificate.
V3_PAIR_BLOCK_END="WPQEND"

# A terminal line editor discards everything past ~4095 characters, so a code
# that carries a real certificate chain can never be pasted as one line.
v3_print_pairing_code() {
	local code="$1"
	local offset
	if [ ${#code} -lt 3000 ]; then
		printf '%s\n' "$code"
		return 0
	fi
	print_warning "This code is ${#code} characters and will be cut if pasted as a single line"
	echo "Copy every line of the block below, including the last one, into the Iran wizard."
	for ((offset = 0; offset < ${#code}; offset += 120)); do
		printf '%s\n' "${code:offset:120}"
	done
	printf '%s\n' "$V3_PAIR_BLOCK_END"
}

v3_pairing_error_text() {
	case "$1" in
		incomplete) printf '%s' "the code is only partly pasted; the terminal cut the line" ;;
		too-long)   printf '%s' "the code is larger than the supported maximum" ;;
		version)    printf '%s' "this code was made by a different WildPaqet version; update Iran and Kharej to the same release" ;;
		format)     printf '%s' "this is not a pairing code (it must start with WPQ4| or WPQ3|)" ;;
		endpoint)   printf '%s' "the endpoint inside the code is not a valid host:port" ;;
		identity)   printf '%s' "the certificate name inside the code is invalid" ;;
		cover-path) printf '%s' "the HTTP/2 cover path inside the code is invalid" ;;
		expired)    printf '%s' "the Kharej certificate has expired, or this server's clock is wrong" ;;
		name)       printf '%s' "the certificate does not match its name, or its chain cannot be verified here" ;;
		*)          printf '%s' "the pairing code could not be verified" ;;
	esac
}

# Decode and validate one pairing code. Results are returned in the globals
# below and the verified public certificate is written to the requested path.
# V3_PAIR_ERROR reports why a decode failed; "incomplete" is the normal state
# while a wrapped code is still being pasted line by line.
V3_PAIR_ENDPOINT=""
V3_PAIR_IDENTITY=""
V3_PAIR_MODE=""
V3_PAIR_COVER_PATH=""
V3_PAIR_ERROR=""
v3_decode_pairing_code() {
	local code cert_out
	local prefix endpoint_b64 identity_b64 field3 field4 extra cert_b64 path_b64
	code=$(v3_sanitize_pairing_code "$1")
	cert_out="$2"
    V3_PAIR_ENDPOINT=""
    V3_PAIR_IDENTITY=""
	V3_PAIR_MODE=""
	V3_PAIR_COVER_PATH=""
	V3_PAIR_ERROR="incomplete"

	[ ${#code} -le 32768 ] || { V3_PAIR_ERROR="too-long"; return 1; }
	IFS='|' read -r prefix endpoint_b64 identity_b64 field3 field4 extra <<< "$code"
	case "$prefix" in
		WPQ4)
			path_b64="$field3"
			cert_b64="$field4"
			[ -n "$path_b64" ] && [ -n "$cert_b64" ] && [ -z "$extra" ] || return 1
			V3_PAIR_COVER_PATH=$(printf '%s' "$path_b64" | base64 -d 2>/dev/null) || return 1
			v3_validate_cover_path "$V3_PAIR_COVER_PATH" || { V3_PAIR_ERROR="cover-path"; return 1; }
			V3_PAIR_MODE="h2"
			;;
		WPQ3)
			cert_b64="$field3"
			[ -n "$cert_b64" ] && [ -z "$field4" ] && [ -z "$extra" ] || return 1
			V3_PAIR_MODE="direct"
			;;
		WPQ?*)
			V3_PAIR_ERROR="version"
			return 1
			;;
		*)
			[ -z "$prefix" ] || V3_PAIR_ERROR="format"
			return 1
			;;
	esac
	[ -n "$endpoint_b64" ] && [ -n "$identity_b64" ] || return 1

    V3_PAIR_ENDPOINT=$(printf '%s' "$endpoint_b64" | base64 -d 2>/dev/null) || return 1
    V3_PAIR_IDENTITY=$(printf '%s' "$identity_b64" | base64 -d 2>/dev/null) || return 1
	v3_validate_endpoint "$V3_PAIR_ENDPOINT" || { V3_PAIR_ERROR="endpoint"; return 1; }
	[[ "$V3_PAIR_IDENTITY" =~ ^[A-Za-z0-9.-]+$ ]] || { V3_PAIR_ERROR="identity"; return 1; }
    if ! printf '%s' "$cert_b64" | base64 -d > "$cert_out" 2>/dev/null; then
        rm -f "$cert_out"
        return 1
    fi
	# A half-pasted code still decodes to bytes, so a truncated certificate must
	# stay "incomplete" and never be reported as an expired or mismatched one.
	if ! openssl x509 -in "$cert_out" -noout >/dev/null 2>&1 \
		|| ! tail -c 64 "$cert_out" | tr -d '\r\n' | grep -q -- '-----END CERTIFICATE-----'; then
		rm -f "$cert_out"
		return 1
	fi
	if ! openssl x509 -in "$cert_out" -noout -checkend 0 >/dev/null 2>&1; then
		rm -f "$cert_out"
		V3_PAIR_ERROR="expired"
		return 1
	fi
    if ! v3_verify_pairing_certificate "$cert_out" "$V3_PAIR_IDENTITY"; then
        rm -f "$cert_out"
		V3_PAIR_ERROR="name"
        return 1
    fi
	V3_PAIR_ERROR=""
    return 0
}

v3_certificate_identity() {
    local cert_file="$1"
    openssl x509 -in "$cert_file" -noout -subject -nameopt RFC2253 2>/dev/null \
        | sed -n 's/^subject=.*CN=\([^,]*\).*$/\1/p' | head -1
}

show_v3_pairing_code() {
    clear
    show_banner
    echo -e "${GREEN}Export v3 pairing code (Kharej)${NC}\n"

	local config_name config_file protocol cert_file listen_addr listen_port cover_mode cover_path
    local identity public_ip endpoint default_endpoint code pair_file answer
    read -r -p "Existing v3 service name [server-v3]: " config_name
    config_name=$(clean_config_name "${config_name:-server-v3}")
    config_file="$CONFIG_DIR/${config_name}.yaml"
    [ -f "$config_file" ] || { print_error "Config not found: $config_file"; pause; return 1; }
    protocol=$(config_transport_protocol "$config_file")
    [ "$protocol" = "tls" ] || { print_error "Service is not a v3 TLS server"; pause; return 1; }
    grep -q '^role:[[:space:]]*"server"' "$config_file" 2>/dev/null \
        || { print_error "Service is not a server"; pause; return 1; }

    cert_file=$(awk '$1 == "cert_file:" { value=$2; gsub(/"/, "", value); print value; exit }' "$config_file")
	cover_mode=$(awk '$1 == "mode:" { value=$2; gsub(/"/, "", value); print value; exit }' "$config_file")
	cover_path=$(awk '$1 == "cover_path:" { value=$2; gsub(/"/, "", value); print value; exit }' "$config_file")
    listen_addr=$(awk '
        /^listen:/ { in_listen=1; next }
        /^[^[:space:]]/ { if (in_listen) exit }
        in_listen && $1 == "addr:" { value=$2; gsub(/"/, "", value); print value; exit }
    ' "$config_file")
    listen_port="${listen_addr##*:}"
    if [ ! -f "$cert_file" ] || ! validate_port "$listen_port"; then
        print_error "Certificate or TLS listen port is missing from the config"
        pause
        return 1
    fi

    identity=$(v3_certificate_identity "$cert_file")
    read -r -p "Certificate name/IP [${identity}]: " answer
    identity="${answer:-$identity}"
    public_ip=$(get_public_ip)
    default_endpoint="${public_ip}:${listen_port}"
    [[ "$public_ip" == *:* ]] && default_endpoint="[${public_ip}]:${listen_port}"
    read -r -p "Public endpoint for Iran [${default_endpoint}]: " endpoint
    endpoint="${endpoint:-$default_endpoint}"
	[ "$cover_mode" = "h2" ] || cover_path=""
	if ! code=$(v3_create_pairing_code "$cert_file" "$endpoint" "$identity" "$cover_path"); then
        print_error "Could not create pairing code; check the endpoint, certificate name and certificate validity"
        pause
        return 1
    fi

    pair_file="$CONFIG_DIR/tls/$config_name/pairing-code.txt"
    mkdir -p "$(dirname "$pair_file")"
    chmod 700 "$(dirname "$pair_file")"
    printf '%s\n' "$code" > "$pair_file"
    chmod 600 "$pair_file"
    print_success "Pairing code ready (contains no secret or private key)"
    echo -e "${YELLOW}Paste this into the Iran v3 wizard:${NC}"
	v3_print_pairing_code "$code"
    echo -e "${CYAN}Saved at:${NC} $pair_file"
	echo "The Iran wizard also accepts this file directly if you copy it with scp."
    pause
}

ensure_v3_core() {
    local version=""
    if [ -x "$BIN_DIR/paqet" ]; then
        version=$("$BIN_DIR/paqet" version 2>/dev/null | awk -F: '/^Version:/{gsub(/^[[:space:]]+/,"",$2); print $2; exit}')
    fi
    if [[ "$version" == v3.*-wildpaqet ]]; then
        return 0
    fi

    if [ -n "$version" ]; then
        print_warning "Installed core is $version and does not support the v3 TLS config"
    else
        print_warning "WildPaqet Core v3 is not installed"
    fi
    local answer
    read -r -p "Build Core v3 from branch ${MANAGER_BRANCH} now? (Y/n): " answer
    [[ "$answer" =~ ^[Nn]$ ]] && return 1
    local arch
    arch=$(detect_arch) || return 1
    build_wildpaqet_core_from_source "$arch"
}

# Print the total pool size for a v3 client. Keeping this calculation in one
# validated helper makes the interactive wizard and regression tests agree.
v3_total_outer_connections() {
    local endpoint_count="${1:-}"
    local per_endpoint="${2:-}"

    [[ "$endpoint_count" =~ ^[0-9]+$ ]] || return 1
    [[ "$per_endpoint" =~ ^[0-9]+$ ]] || return 1
    [ "$endpoint_count" -ge 1 ] && [ "$endpoint_count" -le 16 ] || return 1
    [ "$per_endpoint" -ge 1 ] && [ "$per_endpoint" -le 16 ] || return 1

    local total=$((endpoint_count * per_endpoint))
    [ "$total" -le 256 ] || return 1
    printf '%s\n' "$total"
}

# Certbot, acme.sh and the panel installers each store the certificate pair in
# their own layout, so the wizard scans the known locations instead of assuming
# one Certbot path named after the certificate name.
v3_certificate_search_globs() {
	if [ -n "${WILDPAQET_CERT_GLOBS:-}" ]; then
		printf '%s' "$WILDPAQET_CERT_GLOBS" | tr ':' '\n'
		return 0
	fi
	cat <<EOF
/etc/letsencrypt/live/*/fullchain.pem
/root/.acme.sh/*/fullchain.cer
/root/.acme.sh/*/*.cer
${HOME:-/root}/.acme.sh/*/fullchain.cer
${HOME:-/root}/.acme.sh/*/*.cer
/root/cert/*/fullchain.pem
/root/cert/*.crt
/root/cert/*.pem
/var/lib/marzban/certs/*.pem
/var/lib/marzneshin/certs/*.pem
/opt/hiddify-manager/ssl/*.crt
/etc/x-ui/*.crt
/etc/x-ui/*.pem
/usr/local/etc/xray/*.crt
/usr/local/etc/xray/*.pem
/etc/nginx/ssl/*.crt
/etc/nginx/ssl/*.pem
/etc/ssl/*/fullchain.pem
EOF
}

v3_certificate_key_candidates() {
	local cert_file="$1"
	local dir base stem dir_base
	dir=$(dirname "$cert_file")
	base=$(basename "$cert_file")
	stem="${base%.*}"
	dir_base=$(basename "$dir")
	printf '%s\n' \
		"$dir/privkey.pem" \
		"$dir/private.key" \
		"$dir/key.pem" \
		"$dir/$stem.key" \
		"$dir/$stem.privkey.pem" \
		"${cert_file%.*}.key" \
		"$dir/$dir_base.key" \
		"$dir/${dir_base%_ecc}.key"
}

v3_certificate_key_matches() {
	local cert_file="$1"
	local key_file="$2"
	local cert_pub key_pub
	cert_pub=$(openssl x509 -in "$cert_file" -noout -pubkey 2>/dev/null </dev/null) || return 1
	# An empty passphrase fails an encrypted key instead of blocking the wizard
	# on an interactive prompt.
	key_pub=$(openssl pkey -in "$key_file" -pubout -passin pass: 2>/dev/null </dev/null) || return 1
	[ -n "$cert_pub" ] && [ "$cert_pub" = "$key_pub" ]
}

v3_certificate_names() {
	local cert_file="$1"
	{
		v3_certificate_identity "$cert_file"
		# A long SAN list wraps over several lines, so every following line that
		# still carries entries is collected.
		openssl x509 -in "$cert_file" -noout -text 2>/dev/null </dev/null \
			| awk '
				/X509v3 Subject Alternative Name/ { inside = 1; next }
				inside && /DNS:|IP Address:/ { print; next }
				inside { inside = 0 }
			' \
			| tr ',' '\n' \
			| sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^DNS://; s/^IP Address://'
	} | awk 'NF && !seen[$0]++'
}

v3_certificate_covers_name() {
	local names_csv="$1"
	local identity="${2,,}"
	local name
	while IFS= read -r name; do
		name="${name,,}"
		[ -n "$name" ] || continue
		[ "$name" = "$identity" ] && return 0
		if [ "${name:0:2}" = "*." ] && [ "$identity" != "${identity#*.}" ] \
			&& [ "${identity#*.}" = "${name:2}" ]; then
			return 0
		fi
	done < <(printf '%s\n' "$names_csv" | tr ',' '\n')
	return 1
}

# Lower is better. Exact SAN/CN beats a wildcard, and a fullchain file from
# Certbot or /root/cert beats a duplicate acme.sh copy of the same leaf.
v3_certificate_pair_score() {
	local cert_file="$1"
	local names_csv="$2"
	local identity="${3,,}"
	local score=100 name
	while IFS= read -r name; do
		name="${name,,}"
		[ "$name" = "$identity" ] && score=$((score - 50)) && break
	done < <(printf '%s\n' "$names_csv" | tr ',' '\n')
	case "$cert_file" in
		*/letsencrypt/live/*/fullchain.pem) score=$((score - 30)) ;;
		*/fullchain.pem) score=$((score - 20)) ;;
		*/fullchain.cer) score=$((score - 10)) ;;
	esac
	if ! v3_certificate_is_self_signed "$cert_file"; then
		score=$((score - 40))
	fi
	printf '%s\n' "$score"
}

# Pick the best cert/key pair that already covers the domain the operator named.
v3_select_certificate_for_identity() {
	local identity="$1"
	local pair_line cert_file key_file names expiry score best_score=9999 best_line=""
	[ -n "$identity" ] || return 1
	while IFS= read -r pair_line; do
		[ -n "$pair_line" ] || continue
		IFS='|' read -r cert_file key_file names expiry <<< "$pair_line"
		v3_certificate_covers_name "$names" "$identity" || continue
		score=$(v3_certificate_pair_score "$cert_file" "$names" "$identity")
		if [ "$score" -lt "$best_score" ]; then
			best_score="$score"
			best_line="$pair_line"
		fi
	done < <(v3_find_certificate_pairs)
	[ -n "$best_line" ] || return 1
	v3_apply_certificate_pair_line "$best_line" || return 1
	printf '%s\n' "$best_line"
}

v3_apply_certificate_pair_line() {
	local pair_line="$1"
	V3_CERT_FILE=""
	V3_CERT_KEY=""
	V3_CERT_NAMES=""
	V3_CERT_EXPIRY=""
	[ -n "$pair_line" ] || return 1
	IFS='|' read -r V3_CERT_FILE V3_CERT_KEY V3_CERT_NAMES V3_CERT_EXPIRY <<< "$pair_line"
	[ -n "$V3_CERT_FILE" ] && [ -n "$V3_CERT_KEY" ]
}

v3_certificate_still_valid() {
	local cert_file="$1"
	[ -f "$cert_file" ] || return 1
	openssl x509 -in "$cert_file" -noout -checkend 86400 >/dev/null 2>&1 </dev/null
}

v3_find_acme_sh() {
	local candidate
	for candidate in \
		"${HOME:-/root}/.acme.sh/acme.sh" \
		/root/.acme.sh/acme.sh \
		/usr/local/bin/acme.sh
	do
		[ -x "$candidate" ] && printf '%s\n' "$candidate" && return 0
	done
	if command -v acme.sh >/dev/null 2>&1; then
		command -v acme.sh
		return 0
	fi
	return 1
}

v3_tcp_port_listening() {
	local port="$1"
	ss -tlnH 2>/dev/null | grep -qE ":${port}[[:space:]]"
}

v3_certificate_is_self_signed() {
	local cert_file="$1"
	local subject issuer
	subject=$(openssl x509 -in "$cert_file" -noout -subject -nameopt RFC2253 2>/dev/null </dev/null) || return 0
	issuer=$(openssl x509 -in "$cert_file" -noout -issuer -nameopt RFC2253 2>/dev/null </dev/null) || return 0
	[ "$subject" = "$issuer" ]
}

v3_identity_is_dns_name() {
	local identity="$1"
	[[ "$identity" == *.* ]] || return 1
	[[ "$identity" == *'*'* ]] && return 1
	[[ "$identity" =~ [A-Za-z] ]] || return 1
	[[ "$identity" =~ ^[A-Za-z0-9.-]+$ ]]
}

# Request a publicly trusted certificate for a domain the operator named on
# this server. HTTP-01 needs TCP/80 reachable from the internet.
v3_issue_public_certificate() {
	local identity="$1"
	local acme_bin=""
	v3_identity_is_dns_name "$identity" || {
		print_error "Let's Encrypt cannot issue a certificate for '$identity'; enter a DNS name whose A/AAAA record points here"
		return 1
	}
	if [ -n "${WILDPAQET_LIB_ONLY:-}" ]; then
		print_error "ACME issuance is disabled in library/test mode"
		return 1
	fi
	if v3_tcp_port_listening 80; then
		print_warning "TCP/80 is already in use, so the HTTP-01 challenge may fail"
		print_info "Stop the process on port 80, or make sure it can serve /.well-known/acme-challenge/"
	fi

	if acme_bin=$(v3_find_acme_sh); then
		print_step "Requesting Let's Encrypt certificate with acme.sh for $identity..."
		if "$acme_bin" --issue -d "$identity" --standalone --httpport 80 --server letsencrypt; then
			print_success "acme.sh issued a certificate for $identity"
			return 0
		fi
		print_warning "acme.sh standalone issue failed; trying renew"
		if "$acme_bin" --renew -d "$identity" --force; then
			print_success "acme.sh renewed the certificate for $identity"
			return 0
		fi
	fi

	if ! command -v certbot >/dev/null 2>&1; then
		print_step "Installing certbot to request a public certificate..."
		optimizer_try_install_tools >/dev/null 2>&1 || true
		if command -v apt-get >/dev/null 2>&1; then
			export DEBIAN_FRONTEND=noninteractive
			apt-get install -y -qq certbot >/dev/null 2>&1 || true
		fi
	fi
	if command -v certbot >/dev/null 2>&1; then
		print_step "Requesting Let's Encrypt certificate with certbot for $identity..."
		if certbot certonly --standalone --non-interactive --agree-tos \
			--register-unsafely-without-email --preferred-challenges http \
			-d "$identity"; then
			print_success "certbot issued a certificate for $identity"
			return 0
		fi
	fi
	print_error "Could not obtain a Let's Encrypt certificate for $identity"
	print_info "The domain's A/AAAA record must point to this server and TCP/80 must be reachable"
	return 1
}

# Reuse a still-valid public certificate for the named domain, otherwise issue one
# and scan the usual Certbot/acme.sh locations for the new files.
v3_ensure_public_certificate() {
	local identity="$1"
	local pair_line cert_file
	V3_CERT_FILE=""
	V3_CERT_KEY=""
	V3_CERT_NAMES=""
	V3_CERT_EXPIRY=""
	pair_line=$(v3_select_certificate_for_identity "$identity" 2>/dev/null || true)
	if [ -n "$pair_line" ]; then
		cert_file="${pair_line%%|*}"
		if v3_certificate_still_valid "$cert_file"; then
			if ! v3_certificate_is_self_signed "$cert_file"; then
				v3_apply_certificate_pair_line "$pair_line"
				return 0
			fi
			if [ -n "${WILDPAQET_LIB_ONLY:-}" ]; then
				v3_apply_certificate_pair_line "$pair_line"
				return 0
			fi
			print_warning "Found a self-signed certificate for $identity; requesting a public one"
		else
			print_warning "The certificate for $identity expires within 24 hours; renewing"
		fi
	fi
	if v3_issue_public_certificate "$identity"; then
		pair_line=$(v3_select_certificate_for_identity "$identity") || return 1
		v3_apply_certificate_pair_line "$pair_line"
		return 0
	fi
	# A matching self-signed pair is better than aborting the wizard after ACME
	# fails; the operator can still paste paths by hand if this is also empty.
	if [ -n "$pair_line" ]; then
		cert_file="${pair_line%%|*}"
		if v3_certificate_still_valid "$cert_file"; then
			print_warning "Using the existing certificate for $identity after Let's Encrypt failed"
			v3_apply_certificate_pair_line "$pair_line"
			return 0
		fi
	fi
	return 1
}

# Emit "cert|key|names|expiry" for every usable pair found on this server.
v3_find_certificate_pairs() {
	command -v openssl >/dev/null 2>&1 || return 0
	local pattern cert key names enddate
	local -a lines=()
	while IFS= read -r pattern || [ -n "$pattern" ]; do
		[ -n "$pattern" ] || continue
		while IFS= read -r cert || [ -n "$cert" ]; do
			[ -f "$cert" ] || continue
			openssl x509 -in "$cert" -noout >/dev/null 2>&1 </dev/null || continue
			while IFS= read -r key || [ -n "$key" ]; do
				[ -f "$key" ] || continue
				v3_certificate_key_matches "$cert" "$key" || continue
				names=$(v3_certificate_names "$cert" | tr '\n' ',' | sed 's/,$//')
				enddate=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null </dev/null | cut -d= -f2)
				lines+=("$cert|$key|$names|$enddate")
				break
			done < <(v3_certificate_key_candidates "$cert")
		done < <(compgen -G "$pattern" 2>/dev/null || true)
	done < <(v3_certificate_search_globs)
	if [ ${#lines[@]} -gt 0 ]; then
		# A leaf and its fullchain share one key; keep only the first, which the
		# glob order lists as the chain file.
		printf '%s\n' "${lines[@]}" | awk -F'|' 'NF >= 3 && !seen[$2]++'
	fi
	return 0
}

configure_v3_tls_server() {
    clear
    show_banner
	echo -e "${GREEN}Configure v3 HTTP/2-Covered TLS Server (Kharej)${NC}\n"

	local config_name port secret_key answer identity cert_file key_file svc public_ip public_endpoint default_endpoint
	local cover_path decoy_url generated_cover_path
	public_ip=$(get_public_ip)
    read -r -p "Service name [server-v3]: " config_name
    config_name=$(clean_config_name "${config_name:-server-v3}")
    if [ -f "$CONFIG_DIR/${config_name}.yaml" ]; then
        read -r -p "Config exists. Overwrite? (y/N): " answer
        [[ ! "$answer" =~ ^[Yy]$ ]] && return 0
    fi

    read -r -p "TLS listen port [443]: " port
    port="${port:-443}"
    validate_port "$port" || { print_error "Invalid port"; pause; return 1; }
    check_port_conflict "$port" || { pause; return 1; }

    default_endpoint="${public_ip}:${port}"
    [[ "$public_ip" == *:* ]] && default_endpoint="[${public_ip}]:${port}"
    read -r -p "Public endpoint for Iran [${default_endpoint}]: " public_endpoint
    public_endpoint="${public_endpoint:-$default_endpoint}"
    v3_validate_endpoint "$public_endpoint" \
        || { print_error "Invalid public endpoint (expected host:port)"; pause; return 1; }

    secret_key=$(generate_secret_key)
    read -r -s -p "Shared secret [Enter = generated]: " answer
    echo
    [ -n "$answer" ] && secret_key="$answer"
    if [ ${#secret_key} -lt 32 ]; then
        print_error "The v3 shared secret must be at least 32 characters"
        pause
        return 1
    fi

    read -r -p "Public TLS domain (A/AAAA must point to this server): " identity
    if [ -z "$identity" ]; then
        identity="$public_ip"
        print_warning "No domain entered; Let's Encrypt needs a DNS name, so public issue will fail"
    fi
    if [[ ! "$identity" =~ ^[A-Za-z0-9.-]+$ ]]; then
        print_error "Certificate name may only contain letters, numbers, dot and hyphen"
        pause
        return 1
    fi
	# The same identity + shared secret produces the same private path on every
	# Kharej node, so a four-server pool pairs automatically without publishing
	# another setting. The path is opaque routing metadata, not an auth secret;
	# invalid requests still receive only the decoy response.
	local cover_path_id
	cover_path_id=$(printf '%s' "${identity}:${secret_key}" | openssl dgst -sha256 -r 2>/dev/null | awk '{print substr($1,1,16)}')
	[ -n "$cover_path_id" ] || cover_path_id="$RANDOM$RANDOM"
	generated_cover_path="/api/v1/${cover_path_id}/events"
	read -r -p "Opaque HTTP/2 cover path [$generated_cover_path]: " cover_path
	local cover_path_is_derived=0
	[ -n "$cover_path" ] || cover_path_is_derived=1
	cover_path="${cover_path:-$generated_cover_path}"
	if ! v3_validate_cover_path "$cover_path"; then
		print_error "Cover path must start with / and contain only URL-safe path characters"
		pause
		return 1
	fi
	read -r -p "Local decoy website URL [Enter = built-in page]: " decoy_url
	if [ -n "$decoy_url" ] && [[ ! "$decoy_url" =~ ^https?://[A-Za-z0-9.:[\]-]+(/[A-Za-z0-9._~/-]*)?$ ]]; then
		print_error "Decoy URL must be a simple http(s) URL such as http://127.0.0.1:8080"
		pause
		return 1
	fi

    echo "Certificate source:"
	echo " 1. Public certificate for $identity (reuse or Let's Encrypt)"
	echo " 2. Generate a self-signed certificate (testing only; probe-visible)"
    read -r -p "Choose [1]: " answer
    answer="${answer:-1}"
    mkdir -p "$CONFIG_DIR"
	if [ "$answer" = "1" ]; then
		local pair_line
		local selected_names="" suggested_name=""
		cert_file=""
		key_file=""
		print_step "Getting a public certificate for $identity..."
		if v3_ensure_public_certificate "$identity"; then
			cert_file="$V3_CERT_FILE"
			key_file="$V3_CERT_KEY"
			selected_names="$V3_CERT_NAMES"
			print_success "Using public certificate for $identity"
			echo "  cert: $cert_file"
			echo "  key:  $key_file"
			echo "  expires: ${V3_CERT_EXPIRY:-unknown}"
		else
			print_warning "Automatic issue/reuse failed; enter the certificate paths manually"
			local default_cert="/etc/letsencrypt/live/$identity/fullchain.pem"
			local default_key="/etc/letsencrypt/live/$identity/privkey.pem"
			[ -f "$default_cert" ] || default_cert=""
			[ -f "$default_key" ] || default_key=""
			read -r -p "Certificate/fullchain path${default_cert:+ [$default_cert]}: " cert_file
			read -r -p "Private key path${default_key:+ [$default_key]}: " key_file
			cert_file="${cert_file:-$default_cert}"
			key_file="${key_file:-$default_key}"
			selected_names=$(v3_certificate_names "$cert_file" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
		fi
        [ -f "$cert_file" ] && [ -f "$key_file" ] || {
            print_error "Certificate or key file does not exist"
            pause
            return 1
        }
		if ! v3_certificate_key_matches "$cert_file" "$key_file"; then
			print_error "The private key does not belong to this certificate (or the key is passphrase-protected)"
			pause
			return 1
		fi
		# A certificate that does not carry the configured name makes every Iran
		# handshake fail, so the mismatch is resolved here instead of at runtime.
		if [ -n "$selected_names" ] && ! v3_certificate_covers_name "$selected_names" "$identity"; then
			print_warning "This certificate does not cover '$identity' (it covers: $selected_names)"
			suggested_name=$(printf '%s\n' "$selected_names" | tr ',' '\n' \
				| grep -v '^\*\.' | grep -E '^[A-Za-z0-9.-]+$' | head -1)
			if [ -n "$suggested_name" ]; then
				read -r -p "Use '$suggested_name' as the certificate name instead? (Y/n): " answer
				if [[ ! "$answer" =~ ^[Nn]$ ]]; then
					identity="$suggested_name"
					if [ "$cover_path_is_derived" -eq 1 ]; then
						cover_path_id=$(printf '%s' "${identity}:${secret_key}" \
							| openssl dgst -sha256 -r 2>/dev/null | awk '{print substr($1,1,16)}')
						[ -n "$cover_path_id" ] || cover_path_id="$RANDOM$RANDOM"
						cover_path="/api/v1/${cover_path_id}/events"
						print_info "Cover path re-derived for $identity: $cover_path"
					fi
				fi
			fi
		fi
		print_success "Using certificate: $cert_file"
    else
		print_warning "Self-signed certificates are secure for encryption but do not resist active probing"
        local cert_paths
        cert_paths=$(generate_v3_tls_certificate "$config_name" "$identity") || { pause; return 1; }
        cert_file=$(printf '%s\n' "$cert_paths" | sed -n '1p')
        key_file=$(printf '%s\n' "$cert_paths" | sed -n '2p')
    fi

    ensure_v3_core || return 1
    configure_tls_firewall "$port" || { print_error "Firewall configuration failed"; pause; return 1; }

    {
		echo "# WildPaqet v3 real HTTP/2-covered TLS server"
        echo 'role: "server"'
        echo 'log:'
        echo '  level: "info"'
        echo 'listen:'
        echo "  addr: \":$port\""
        echo 'transport:'
        echo '  protocol: "tls"'
        echo '  conn: 1'
        echo '  tls:'
		echo '    mode: "h2"'
		echo "    server_name: \"$identity\""
        echo "    cert_file: \"$cert_file\""
        echo "    key_file: \"$key_file\""
        echo "    secret: \"$secret_key\""
        echo '    alpn: "h2"'
		echo "    cover_path: \"$cover_path\""
		[ -n "$decoy_url" ] && echo "    decoy_url: \"$decoy_url\""
        echo '    connect_timeout: 10'
        echo '    handshake_timeout: 10'
        echo '    keepalive: 15'
        echo '    keepalive_timeout: 60'
		echo '    connect_jitter: 2'
		echo '    keepalive_jitter: 5'
		echo '    max_connection_age: 7200'
		echo '    connection_age_jitter: 1800'
		echo '    drain_timeout: 1800'
        echo '    breaker_failures: 3'
        echo '    breaker_cooldown: 30'
        echo '    breaker_max_cooldown: 300'
    } > "$CONFIG_DIR/${config_name}.yaml"
    chmod 600 "$CONFIG_DIR/${config_name}.yaml"

    create_systemd_service "$config_name"
    svc="paqet-${config_name}"
    if ! enable_and_refresh_service "$svc" || ! systemctl is-active --quiet "$svc"; then
        print_error "TLS server failed to start"
        systemctl status "$svc" --no-pager -l
        pause
        return 1
    fi

	print_success "v3 HTTP/2-covered TLS server started on TCP/$port"
    local pairing_code pair_file
	if pairing_code=$(v3_create_pairing_code "$cert_file" "$public_endpoint" "$identity" "$cover_path"); then
        pair_file="$CONFIG_DIR/tls/$config_name/pairing-code.txt"
        mkdir -p "$(dirname "$pair_file")"
        chmod 700 "$(dirname "$pair_file")"
        printf '%s\n' "$pairing_code" > "$pair_file"
        chmod 600 "$pair_file"
        echo -e "${YELLOW}Pairing code for the Iran wizard (public data only):${NC}"
		v3_print_pairing_code "$pairing_code"
        echo -e "${CYAN}Saved at:${NC} $pair_file"
		echo "The Iran wizard also accepts this file directly if you copy it with scp."
    else
        print_warning "Could not create a pairing code; use the certificate manually: $cert_file"
    fi
    echo -e "${YELLOW}Shared secret (enter separately on Iran):${NC} $secret_key"
    echo "For four Kharej servers, paste one pairing code from each server into the Iran wizard."
    pause
}

configure_v3_tls_client() {
    clear
    show_banner
	echo -e "${GREEN}Configure v3 HTTP/2-Covered TLS Client (Iran)${NC}\n"

    local config_name endpoints_raw secret_key server_name send_server_name ca_file traffic_type svc
    local connections_per_endpoint total_connections
	local trust_choice endpoint send_sni_answer cover_mode cover_path carrier_choice imported_identity imported_mode imported_path
	local bundle_dir bundle_tmp pair_code pair_input pair_buffer pair_complete cert_tmp pair_count fingerprint duplicate imported_endpoint
    local -a endpoints forward_entries socks5_entries
    read -r -p "Service name [iran-v3]: " config_name
    config_name=$(clean_config_name "${config_name:-iran-v3}")
    if [ -f "$CONFIG_DIR/${config_name}.yaml" ]; then
        read -r -p "Config exists. Overwrite? (y/N): " endpoints_raw
        [[ ! "$endpoints_raw" =~ ^[Yy]$ ]] && return 0
    fi

    endpoints=()
    ca_file=""
    server_name=""
    send_server_name="false"
	cover_mode="h2"
	cover_path=""
    echo "Kharej certificate setup:"
    echo " 1. Paste pairing code(s) from Kharej (recommended, automatic bundle)"
    echo " 2. Use an existing CA bundle"
    echo " 3. Use the system trust store (public certificate)"
    read -r -p "Choose [1]: " trust_choice
    trust_choice="${trust_choice:-1}"

    if [ "$trust_choice" = "1" ]; then
        if ! command -v base64 >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
            print_error "base64 and OpenSSL are required to import pairing codes"
            pause
            return 1
        fi
        bundle_dir="$CONFIG_DIR/tls/$config_name"
        mkdir -p "$bundle_dir"
        chmod 700 "$bundle_dir"
        bundle_tmp="$bundle_dir/.kharej-ca-bundle.$$"
        : > "$bundle_tmp"
        chmod 600 "$bundle_tmp"
        pair_count=0
		pair_buffer=""
		echo "Paste one WPQ4 (HTTP/2 cover) pairing code from each Kharej server."
		echo "Legacy WPQ3 direct-TLS codes are still accepted for compatibility."
		echo "A code that Kharej printed as a block of lines may be pasted as a whole block"
		echo "(including its last ${V3_PAIR_BLOCK_END} line); a file path such as /root/pairing-code.txt"
		echo "copied with scp is also accepted."
        echo "Press Enter on an empty line when all codes are imported."
        while true; do
			if [ -n "$pair_buffer" ]; then
				read -r -p "  rest of code #$((pair_count + 1)) (Enter = discard): " pair_input
			else
				read -r -p "Pairing code #$((pair_count + 1)): " pair_input
			fi
			pair_complete=0
			# A file keeps a long code intact, because a terminal line editor
			# drops everything past ~4095 characters of a pasted line.
			if [ -z "$pair_buffer" ] && [ -n "$pair_input" ] && [ -f "$pair_input" ]; then
				pair_code=$(v3_sanitize_pairing_code "$(cat "$pair_input" 2>/dev/null)")
				if [ -z "$pair_code" ]; then
					print_warning "File is empty: $pair_input"
					continue
				fi
				pair_complete=1
			else
				pair_code=$(v3_sanitize_pairing_code "$pair_input")
				if [ "$pair_code" = "$V3_PAIR_BLOCK_END" ]; then
					pair_code=""
					pair_complete=1
				fi
				# The remaining lines of a wrapped code are already in the
				# terminal buffer, so the paste is drained before it is decoded
				# and a chain is never cut at an intermediate certificate.
				if [ -t 0 ]; then
					while [ "$pair_complete" -eq 0 ]; do
						pair_input=""
						# A timed-out read still returns the start of a line that
						# was pasted without a closing newline.
						IFS= read -r -t 0.2 pair_input
						pair_input=$(v3_sanitize_pairing_code "$pair_input")
						[ -n "$pair_input" ] || break
						if [ "$pair_input" = "$V3_PAIR_BLOCK_END" ]; then
							pair_complete=1
							break
						fi
						pair_code="${pair_code}${pair_input}"
					done
				fi
			fi
			if [ -z "$pair_code" ] && [ "$pair_complete" -eq 0 ]; then
				if [ -n "$pair_buffer" ]; then
					print_warning "Discarded an incomplete code: $(v3_pairing_error_text "$V3_PAIR_ERROR")"
					pair_buffer=""
					continue
				fi
                [ "$pair_count" -gt 0 ] && break
                print_warning "At least one pairing code is required"
                continue
            fi
            [ "$pair_count" -lt 16 ] || {
                print_error "A maximum of 16 Kharej endpoints is supported by the wizard"
                rm -f "$bundle_tmp"
                pause
                return 1
            }
			pair_buffer="${pair_buffer}${pair_code}"
			[ -n "$pair_buffer" ] || continue
            cert_tmp="$bundle_dir/.pair-cert-${pair_count}.$$"
			if ! v3_decode_pairing_code "$pair_buffer" "$cert_tmp"; then
                rm -f "$cert_tmp"
				if [ "$V3_PAIR_ERROR" = "incomplete" ] && [ "$pair_complete" -eq 0 ]; then
					print_info "Code is not complete yet; paste the rest of it"
				else
					print_warning "Pairing code rejected: $(v3_pairing_error_text "$V3_PAIR_ERROR")"
					pair_buffer=""
				fi
                continue
            fi
			pair_buffer=""
            imported_endpoint="$V3_PAIR_ENDPOINT"
			imported_identity="$V3_PAIR_IDENTITY"
			imported_mode="$V3_PAIR_MODE"
			imported_path="$V3_PAIR_COVER_PATH"
			if [ "$pair_count" -eq 0 ]; then
				server_name="$imported_identity"
				cover_mode="$imported_mode"
				cover_path="$imported_path"
				[ "$cover_mode" = "h2" ] && send_server_name="true"
			elif [ "$imported_mode" != "$cover_mode" ]; then
				rm -f "$cert_tmp"
				print_warning "Cannot mix WPQ3 direct and WPQ4 HTTP/2 endpoints in one pool"
				continue
			elif [ "$cover_mode" = "h2" ] && { [ "$imported_identity" != "$server_name" ] || [ "$imported_path" != "$cover_path" ]; }; then
				rm -f "$cert_tmp"
				print_warning "All HTTP/2 endpoints must share the same certificate name and cover path"
				continue
			fi
            duplicate=0
            for endpoint in "${endpoints[@]}"; do
                [ "$endpoint" = "$imported_endpoint" ] && duplicate=1
            done
            if [ "$duplicate" -eq 1 ]; then
                rm -f "$cert_tmp"
                print_warning "Endpoint already imported: $imported_endpoint"
                continue
            fi
            cat "$cert_tmp" >> "$bundle_tmp"
            printf '\n' >> "$bundle_tmp"
            fingerprint=$(openssl x509 -in "$cert_tmp" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//')
            rm -f "$cert_tmp"
            endpoints+=("$imported_endpoint")
            pair_count=$((pair_count + 1))
            print_success "Imported $imported_endpoint ($V3_PAIR_IDENTITY)"
            echo -e "  ${CYAN}SHA-256:${NC} $fingerprint"
        done
        # Use a versioned bundle so an aborted overwrite cannot break the
        # currently running service, which may still reference an older file.
        ca_file="$bundle_dir/kharej-ca-bundle-$(date +%Y%m%d%H%M%S)-$$.crt"
        if ! mv -f "$bundle_tmp" "$ca_file"; then
            rm -f "$bundle_tmp"
            print_error "Could not install the generated CA bundle"
            pause
            return 1
        fi
        chmod 600 "$ca_file"
        print_success "CA bundle built automatically: $ca_file"
    elif [ "$trust_choice" = "2" ] || [ "$trust_choice" = "3" ]; then
        echo "Enter all Kharej endpoints. Four endpoints are recommended for your topology."
        read -r -p "Endpoints (comma-separated IP:port): " endpoints_raw
        IFS=',' read -ra endpoints <<< "$endpoints_raw"
        local -a clean_endpoints=()
        for endpoint in "${endpoints[@]}"; do
            endpoint=$(echo "$endpoint" | xargs)
            if v3_validate_endpoint "$endpoint"; then
                clean_endpoints+=("$endpoint")
            else
                print_error "Invalid endpoint: $endpoint"
                pause
                return 1
            fi
        done
        endpoints=("${clean_endpoints[@]}")
        [ ${#endpoints[@]} -gt 0 ] || { print_error "At least one endpoint is required"; pause; return 1; }

        if [ "$trust_choice" = "2" ]; then
            read -r -p "Existing CA bundle path: " ca_file
            if [ -z "$ca_file" ] || [ ! -f "$ca_file" ]; then
                print_error "CA bundle does not exist: $ca_file"
                pause
                return 1
            fi
            read -r -p "Certificate server name (Enter = CA-bundle verification only): " server_name
            if [ -n "$server_name" ]; then
                read -r -p "Send this name as TLS SNI? (y/N): " send_sni_answer
                [[ "$send_sni_answer" =~ ^[Yy]$ ]] && send_server_name="true"
            fi
        else
            read -r -p "Certificate server name (required): " server_name
            [ -n "$server_name" ] || {
                print_error "A certificate server name is required with the system trust store"
                pause
                return 1
            }
            read -r -p "Send this name as TLS SNI? (Y/n): " send_sni_answer
            [[ ! "$send_sni_answer" =~ ^[Nn]$ ]] && send_server_name="true"
        fi
		echo "TLS carrier:"
		echo " 1. Real HTTP/2 cover (recommended)"
		echo " 2. Legacy direct TLS"
		read -r -p "Choose [1]: " carrier_choice
		carrier_choice="${carrier_choice:-1}"
		if [ "$carrier_choice" = "1" ]; then
			cover_mode="h2"
			if [ -z "$server_name" ]; then
				read -r -p "Public certificate/SNI name (required): " server_name
			fi
			[ -n "$server_name" ] || { print_error "HTTP/2 cover requires a certificate/SNI name"; pause; return 1; }
			send_server_name="true"
			read -r -p "HTTP/2 cover path [/api/v1/events]: " cover_path
			cover_path="${cover_path:-/api/v1/events}"
			v3_validate_cover_path "$cover_path" \
				|| { print_error "Invalid HTTP/2 cover path"; pause; return 1; }
		else
			cover_mode="direct"
			cover_path=""
		fi
    else
        print_error "Invalid certificate setup choice"
        pause
        return 1
    fi

    echo "TLS connection pool:"
    echo "  2 per Kharej: low traffic / lower memory"
    echo "  4 per Kharej: balanced and recommended"
    echo "  8 per Kharej: high concurrent traffic on a larger Iran VPS"
    read -r -p "Outer connections per Kharej [${DEFAULT_V3_CONNECTIONS_PER_ENDPOINT}]: " connections_per_endpoint
    connections_per_endpoint="${connections_per_endpoint:-$DEFAULT_V3_CONNECTIONS_PER_ENDPOINT}"
    if ! total_connections=$(v3_total_outer_connections "${#endpoints[@]}" "$connections_per_endpoint"); then
        print_error "Connections per Kharej must be between 1 and 16 (256 total maximum)"
        pause
        return 1
    fi
    print_info "Outer pool: ${#endpoints[@]} Kharej endpoint(s) × ${connections_per_endpoint} = ${total_connections} TLS connections"

    read -r -s -p "Shared secret from Kharej: " secret_key
    echo
    if [ ${#secret_key} -lt 32 ]; then
        print_error "The v3 shared secret must be at least 32 characters"
        pause
        return 1
    fi

    echo "Traffic mode:"
    echo " 1. TCP port forwarding"
    echo " 2. SOCKS5 proxy"
    read -r -p "Choose [1]: " traffic_type
    traffic_type="${traffic_type:-1}"
    forward_entries=()
    socks5_entries=()
    if [ "$traffic_type" = "2" ]; then
        local socks_port socks_user socks_pass
        read -r -p "SOCKS5 port [1080]: " socks_port
        socks_port="${socks_port:-1080}"
        validate_port "$socks_port" || { print_error "Invalid SOCKS5 port"; pause; return 1; }
        read -r -p "SOCKS5 username (Enter = none): " socks_user
        if [ -n "$socks_user" ]; then
            read -r -s -p "SOCKS5 password: " socks_pass; echo
            [ -n "$socks_pass" ] || { print_error "Password is required"; pause; return 1; }
            socks5_entries+=("  - listen: \"0.0.0.0:$socks_port\"\n    username: \"$socks_user\"\n    password: \"$socks_pass\"")
        else
            socks5_entries+=("  - listen: \"0.0.0.0:$socks_port\"")
        fi
        configure_tls_firewall "$socks_port" || true
    else
        local forward_ports p
        read -r -p "TCP forward ports (comma-separated) [$DEFAULT_V2RAY_PORTS]: " forward_ports
        forward_ports=$(clean_port_list "${forward_ports:-$DEFAULT_V2RAY_PORTS}")
        [ -n "$forward_ports" ] || { print_error "No valid forward port"; pause; return 1; }
        IFS=',' read -ra _v3_ports <<< "$forward_ports"
        for p in "${_v3_ports[@]}"; do
            forward_entries+=("  - listen: \"0.0.0.0:$p\"\n    target: \"127.0.0.1:$p\"\n    protocol: \"tcp\"")
            configure_tls_firewall "$p" || true
        done
    fi

    ensure_v3_core || return 1
    mkdir -p "$CONFIG_DIR"
    {
		echo "# WildPaqet v3 TLS client ($cover_mode carrier)"
        echo 'role: "client"'
        echo 'log:'
        echo '  level: "info"'
        if [ ${#forward_entries[@]} -gt 0 ]; then
            echo 'forward:'
            printf '%b\n' "${forward_entries[@]}"
        fi
        if [ ${#socks5_entries[@]} -gt 0 ]; then
            echo 'socks5:'
            printf '%b\n' "${socks5_entries[@]}"
        fi
        echo 'server:'
        echo "  addr: \"${endpoints[0]}\""
        if [ ${#endpoints[@]} -gt 1 ]; then
            echo '  addrs:'
            for endpoint in "${endpoints[@]:1}"; do
                echo "    - \"$endpoint\""
            done
        fi
        echo 'transport:'
        echo '  protocol: "tls"'
        echo "  conn: $total_connections"
        echo '  tls:'
		echo "    mode: \"$cover_mode\""
        [ -n "$server_name" ] && echo "    server_name: \"$server_name\""
		[ "$send_server_name" = "true" ] && echo '    send_server_name: true'
        [ -n "$ca_file" ] && echo "    ca_file: \"$ca_file\""
        echo "    secret: \"$secret_key\""
        echo '    alpn: "h2"'
		if [ "$cover_mode" = "h2" ]; then
			echo "    cover_path: \"$cover_path\""
			echo '    client_hello: "chrome"'
			echo '    connect_jitter: 2'
			echo '    keepalive_jitter: 5'
			echo '    max_connection_age: 7200'
			echo '    connection_age_jitter: 1800'
			echo '    drain_timeout: 1800'
		fi
        echo '    connect_timeout: 10'
        echo '    handshake_timeout: 10'
        echo '    keepalive: 15'
        echo '    keepalive_timeout: 60'
        echo '    breaker_failures: 3'
        echo '    breaker_cooldown: 30'
        echo '    breaker_max_cooldown: 300'
    } > "$CONFIG_DIR/${config_name}.yaml"
    chmod 600 "$CONFIG_DIR/${config_name}.yaml"

    create_systemd_service "$config_name"
    svc="paqet-${config_name}"
    if ! enable_and_refresh_service "$svc" || ! systemctl is-active --quiet "$svc"; then
        print_error "TLS client failed to start"
        systemctl status "$svc" --no-pager -l
        pause
        return 1
    fi
	print_success "v3 $cover_mode client started with $total_connections outer connection(s) across ${#endpoints[@]} Kharej endpoint(s)"
    pause
}

# Configure as Server
configure_server() {
    echo -e "${CYAN}Transport:${NC}"
	echo " 1. v3 real HTTP/2-covered TLS (recommended, no WebSocket)"
    echo " 2. Legacy raw KCP/pcap"
    echo " 3. Export pairing code for an existing v3 server"
    echo " 0. Back"
    local transport_choice
    read -p "Choose [1]: " transport_choice
    case "${transport_choice:-1}" in
        1) configure_v3_tls_server; return ;;
        2) ;;
        3) show_v3_pairing_code; return ;;
        0) return ;;
        *) print_error "Invalid transport"; pause; return ;;
    esac
    while true; do
        clear
        show_banner
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║ Configure as Server (Abroad/Kharej)                          ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}\n"
        
        get_network_info
        local public_ip
        public_ip=$(get_public_ip)
        
        echo -e "${YELLOW}Detected Network Information${NC}"
        echo -e "┌──────────────────────────────────────────────────────────────┐"
        printf "│ %-12s : %-44s │\n" "Interface" "${NETWORK_INTERFACE:-Not found}"
        printf "│ %-12s : %-44s │\n" "Local IP" "${LOCAL_IP:-Not found}"
        printf "│ %-12s : %-44s │\n" "Public IP" "$public_ip"
        printf "│ %-12s : %-44s │\n" "Gateway MAC" "${GATEWAY_MAC:-Not found}"
        echo -e "└──────────────────────────────────────────────────────────────┘\n"
        
        echo -e "${CYAN}Server Configuration${NC}"
        echo -e "────────────────────────────────────────────────────────────────"
        
        # [1/12] Service Name
        echo -en "${YELLOW}[1/12] Service Name (e.g: myserver) : ${NC}"
        read -r config_name
        config_name=$(clean_config_name "${config_name:-server}")
        echo -e "[1/12] Service Name : ${CYAN}$config_name${NC}"
        
        if [ -f "$CONFIG_DIR/${config_name}.yaml" ]; then
            print_warning "Config '$config_name' already exists!"
            read -p "Overwrite? (y/N): " ow
            [[ ! "$ow" =~ ^[Yy]$ ]] && continue
        fi
        
        # [2/12] Listen Port
        echo -en "${YELLOW}[2/12] Listen Port (default: $DEFAULT_LISTEN_PORT) : ${NC}"
        read -r port
        port="${port:-$DEFAULT_LISTEN_PORT}"
        
        if ! validate_port "$port"; then
            print_error "Invalid port"
            sleep 1.5
            continue
        fi
        echo -e "[2/12] Listen Port : ${CYAN}$port${NC}"
        
        if ! check_port_conflict "$port"; then
            pause "Press Enter to retry..."
            continue
        fi
        
        # [3/12] Secret Key
        local secret_key
        secret_key=$(generate_secret_key)
        echo -e "${YELLOW}[3/12] Secret Key : ${GREEN}$secret_key${NC} (press Enter for auto-generate)"
        read -p "Use this key? (Y/n): " use
        
        if [[ "$use" =~ ^[Nn]$ ]]; then
            echo -en "${YELLOW}[3/12] Secret Key : ${NC}"
            read -r secret_key
            if [ ${#secret_key} -lt 8 ]; then
                print_error "Too short (min 8 characters)"
                continue
            fi
        fi
        echo -e "[3/12] Secret Key : ${GREEN}$secret_key${NC}"
        
        # [4/12] KCP Mode
        echo -e "\n${CYAN}KCP Mode Selection${NC}"
        echo -e "────────────────────────────────────────────────────────────────"
        for mode_key in 0 1 2 3 4; do
            IFS=':' read -r name desc <<< "${KCP_MODES[$mode_key]}"
            echo " [${mode_key}] ${name} - ${desc}"
        done
        echo ""

        local mode_choice
        read -p "[4/12] Choose KCP mode [0-4] (default 0 - normal): " mode_choice
        mode_choice="${mode_choice:-0}"

        local mode_name
        local kcp_fragment=""

        case $mode_choice in
            0) mode_name="normal" ;;
            1) mode_name="fast" ;;
            2) mode_name="fast2" ;;
            3) mode_name="fast3" ;;
            4) 
                mode_name="manual"
                echo -e "\n${YELLOW}Manual KCP Advanced Parameters${NC}"
                echo -e "────────────────────────────────────────────────────────────────"
                kcp_fragment=$(get_manual_kcp_settings)
                ;;
            *) mode_name="$DEFAULT_KCP_MODE" ;;
        esac
        echo -e "[4/12] KCP Mode : ${CYAN}$mode_name${NC}"
        
        # [5/12] Connections
        echo -en "${YELLOW}[5/12] Connections [1-32, 0=skip] (default $DEFAULT_CONNECTIONS): ${NC}"
        read -r conn_input
        local conn=""
        if [ -z "$conn_input" ]; then
            conn="$DEFAULT_CONNECTIONS"
            echo -e "[5/12] Connections : ${CYAN}$DEFAULT_CONNECTIONS (default)${NC}"
        elif [ "$conn_input" = "0" ]; then
            conn=""
            echo -e "[5/12] Connections : ${CYAN}- (skipped)${NC}"
        elif [[ "$conn_input" =~ ^[1-9][0-9]?$ ]] && [ "$conn_input" -ge 1 ] && [ "$conn_input" -le 32 ]; then
            conn="$conn_input"
            echo -e "[5/12] Connections : ${CYAN}$conn_input${NC}"
        else
            conn="$DEFAULT_CONNECTIONS"
            echo -e "${YELLOW}Invalid, using default $DEFAULT_CONNECTIONS${NC}"
            echo -e "[5/12] Connections : ${CYAN}$DEFAULT_CONNECTIONS (corrected)${NC}"
        fi
        
        # [6/12] MTU
        echo -en "${YELLOW}[6/12] MTU [100-9000, 0=skip] (default $DEFAULT_MTU): ${NC}"
        read -r mtu_input
        local mtu=""
        if [ -z "$mtu_input" ]; then
            mtu="$DEFAULT_MTU"
            echo -e "[6/12] MTU : ${CYAN}$DEFAULT_MTU (default)${NC}"
        elif [ "$mtu_input" = "0" ]; then
            mtu=""
            echo -e "[6/12] MTU : ${CYAN}- (skipped)${NC}"
        elif [[ "$mtu_input" =~ ^[0-9]+$ ]] && [ "$mtu_input" -ge 100 ] && [ "$mtu_input" -le 9000 ]; then
            mtu="$mtu_input"
            echo -e "[6/12] MTU : ${CYAN}$mtu_input${NC}"
        else
            mtu="$DEFAULT_MTU"
            echo -e "${YELLOW}Invalid, using default $DEFAULT_MTU${NC}"
            echo -e "[6/12] MTU : ${CYAN}$DEFAULT_MTU (corrected)${NC}"
        fi
        
        # [7/12] Encryption
        echo -e "\n${CYAN}Encryption Selection${NC}"
        echo -e "────────────────────────────────────────────────────────────────"
        for enc_key in 1 2 3 4 5 6 7; do
            IFS=':' read -r enc_name enc_desc <<< "${ENCRYPTION_OPTIONS[$enc_key]}"
            echo " [${enc_key}] ${enc_name} - ${enc_desc}"
        done
        echo ""
        
        local enc_choice
        read -p "[7/12] Choose encryption [1-7] (default 1): " enc_choice
        enc_choice="${enc_choice:-1}"
        
        local block
        IFS=':' read -r block _ <<< "${ENCRYPTION_OPTIONS[$enc_choice]}"
        block="${block:-aes-128-gcm}"
        echo -e "[7/12] Encryption : ${CYAN}$block${NC}"
        
        # [8/12] pcap sockbuf
        echo -en "${YELLOW}[8/12] pcap sockbuf [Enter=skip, 0=skip]: ${NC}"
        read -r pcap_input
        local pcap_sockbuf=""
        
        if [ -n "$pcap_input" ] && [ "$pcap_input" != "0" ]; then
            # فقط اگر عدد معتبر وارد کرد
            if [[ "$pcap_input" =~ ^[0-9]+$ ]]; then
                pcap_sockbuf="$pcap_input"
                echo -e "[8/12] pcap sockbuf : ${CYAN}$pcap_input${NC}"
            else
                print_warning "Invalid number, skipping pcap sockbuf"
                echo -e "[8/12] pcap sockbuf : ${CYAN}skipped${NC}"
            fi
        else
            echo -e "[8/12] pcap sockbuf : ${CYAN}skipped${NC}"
        fi
        
        # [9/12] transport tcpbuf
        echo -en "${YELLOW}[9/12] transport tcpbuf [Enter=skip, 0=skip]: ${NC}"
        read -r tcpbuf_input
        local transport_tcpbuf=""
        
        if [ -n "$tcpbuf_input" ] && [ "$tcpbuf_input" != "0" ]; then
            if [[ "$tcpbuf_input" =~ ^[0-9]+$ ]]; then
                transport_tcpbuf="$tcpbuf_input"
                echo -e "[9/12] transport tcpbuf : ${CYAN}$tcpbuf_input${NC}"
            else
                print_warning "Invalid number, skipping transport tcpbuf"
                echo -e "[9/12] transport tcpbuf : ${CYAN}skipped${NC}"
            fi
        else
            echo -e "[9/12] transport tcpbuf : ${CYAN}skipped${NC}"
        fi
        
        # [10/12] transport udpbuf
        echo -en "${YELLOW}[10/12] transport udpbuf [Enter=skip, 0=skip]: ${NC}"
        read -r udpbuf_input
        local transport_udpbuf=""
        
        if [ -n "$udpbuf_input" ] && [ "$udpbuf_input" != "0" ]; then
            if [[ "$udpbuf_input" =~ ^[0-9]+$ ]]; then
                transport_udpbuf="$udpbuf_input"
                echo -e "[10/12] transport udpbuf : ${CYAN}$udpbuf_input${NC}"
            else
                print_warning "Invalid number, skipping transport udpbuf"
                echo -e "[10/12] transport udpbuf : ${CYAN}skipped${NC}"
            fi
        else
            echo -e "[10/12] transport udpbuf : ${CYAN}skipped${NC}"
        fi
        
        # Apply configuration
        echo -e "\n${CYAN}Applying Configuration${NC}"
        echo -e "────────────────────────────────────────────────────────────────"
        
        if [ ! -f "$BIN_DIR/paqet" ]; then
            install_paqet || continue
        fi
        
        configure_iptables "$port" "tcp"
        mkdir -p "$CONFIG_DIR"
        
        # Build server config with proper indentation
        {
            echo "# Paqet Server Configuration"
            echo "role: \"server\""
            echo "log:"
            echo "  level: \"info\""
            echo "listen:"
            echo "  addr: \":$port\""
            echo "network:"
            echo "  interface: \"$NETWORK_INTERFACE\""
            echo "  ipv4:"
            echo "    addr: \"$LOCAL_IP:$port\""
            echo "    router_mac: \"$GATEWAY_MAC\""
            echo "  tcp:"
            echo "    local_flag: [\"PA\"]"
            echo "    remote_flag: [\"PA\"]"
            echo "    preset: \"${DEFAULT_TCP_PRESET}\""
            echo "    handshake: \"mimic\""
            echo "    track_seq: true"
            echo "    ipv4_tos: 0"
            
            if [[ -n "$pcap_sockbuf" ]]; then
                echo "  pcap:"
                echo "    sockbuf: $pcap_sockbuf"
            fi
            
            echo "transport:"
            echo "  protocol: \"kcp\""
            
            [[ -n "$conn" ]] && echo "  conn: $conn"
            [[ -n "$transport_tcpbuf" ]] && echo "  tcpbuf: $transport_tcpbuf"
            [[ -n "$transport_udpbuf" ]] && echo "  udpbuf: $transport_udpbuf"
            
            echo "  kcp:"
            echo "    key: \"$secret_key\""
            
            if [ "$mode_name" = "manual" ] && [ -n "$kcp_fragment" ]; then
                # For manual mode, add block and mtu separately
                echo "    mode: \"manual\""
                echo "    block: \"$block\""
                [[ -n "$mtu" ]] && echo "    mtu: $mtu"
                # Add remaining manual settings from kcp_fragment
                while IFS= read -r line; do
                    if [[ -n "$line" ]] && ! echo "$line" | grep -q "mode:"; then
                        echo "    $line"
                    fi
                done <<< "$kcp_fragment"
            else
                # For non-manual modes
                echo "    mode: \"$mode_name\""
                echo "    block: \"$block\""
                [[ -n "$mtu" ]] && echo "    mtu: $mtu"
            fi
            echo "    smuxkalive: $DEFAULT_SMUX_KEEPALIVE"
            echo "    smuxktimeout: $DEFAULT_SMUX_KEEPALIVE_TIMEOUT"
        } > "$CONFIG_DIR/${config_name}.yaml"
        
        echo -e "[+] Configuration saved : ${CYAN}$CONFIG_DIR/${config_name}.yaml${NC}"
        
        create_systemd_service "$config_name"
        local svc="paqet-${config_name}"
        systemctl enable "$svc" --now >/dev/null 2>&1
        
        if systemctl is-active --quiet "$svc"; then
            print_success "Server started successfully"
            add_auto_restart_cronjob "$svc" "$DEFAULT_AUTO_RESTART_INTERVAL" >/dev/null 2>&1
            
            echo -e "\n${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${GREEN}║ Server Ready                                                  ║${NC}"
            echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}\n"
            
            echo -e "${YELLOW}Server Information${NC}"
            echo -e "┌──────────────────────────────────────────────────────────────┐"
            printf "│ %-14s : %-44s │\n" "Public IP" "$public_ip"
            printf "│ %-14s : %-44s │\n" "Listen Port" "$port"
            printf "│ %-14s : %-44s │\n" "Connections" "${conn:-$DEFAULT_CONNECTIONS}"
            printf "│ %-14s : %-44s │\n" "Auto Restart" "Every ${DEFAULT_AUTO_RESTART_INTERVAL}"
            echo -e "└──────────────────────────────────────────────────────────────┘\n"
            
            echo -e "${YELLOW}Secret Key (Client Configuration)${NC}"
            echo -e "┌──────────────────────────────────────────────────────────────┐"
            printf "│ %-60s │\n" "$secret_key"
            echo -e "└──────────────────────────────────────────────────────────────┘\n"
            
            echo -e "${YELLOW}KCP Configuration${NC}"
            echo -e "┌──────────────────────────────────────────────────────────────┐"
            printf "│ %-14s : %-44s │\n" "Mode" "$mode_name"
            printf "│ %-14s : %-44s │\n" "Encryption" "$block"
            printf "│ %-14s : %-44s │\n" "MTU" "${mtu:-$DEFAULT_MTU}"
            echo -e "└──────────────────────────────────────────────────────────────┘\n"
            
            echo ""
            echo -e "${GREEN}✅ Server setup completed successfully!${NC}"
            echo -e "${CYAN}Options:${NC}"
            echo -e " 1. Press ${GREEN}Enter${NC} to go to service management for $config_name"
            echo -e " 2. Type ${YELLOW}menu${NC} to return to main menu"
            echo -e " 3. Type ${YELLOW}exit${NC} to exit"
            echo ""
            
            read -p "Your choice [Enter/menu/exit]: " post_choice
            
            case "${post_choice,,}" in
                ""|enter)
                    echo -e "${GREEN}➡️ Taking you to service management for $config_name...${NC}"
                    sleep 1
                    manage_single_service "$svc" "$config_name"
                    ;;
                menu)
                    echo -e "${CYAN}Returning to main menu...${NC}"
                    sleep 1
                    return 0
                    ;;
                exit)
                    echo -e "${GREEN}Goodbye!${NC}"
                    exit 0
                    ;;
                *)
                    echo -e "${YELLOW}Invalid choice. Returning to main menu...${NC}"
                    sleep 2
                    return 0
                    ;;
            esac
        else
            print_error "Service failed to start"
            systemctl status "$svc" --no-pager -l
            pause
        fi
        return 0
    done
}

# Configure as Client
configure_client() {
    echo -e "${CYAN}Transport:${NC}"
	echo " 1. v3 real HTTP/2-covered TLS (recommended, no WebSocket)"
    echo " 2. Legacy raw KCP/pcap"
    echo " 0. Back"
    local transport_choice
    read -p "Choose [1]: " transport_choice
    case "${transport_choice:-1}" in
        1) configure_v3_tls_client; return ;;
        2) ;;
        0) return ;;
        *) print_error "Invalid transport"; pause; return ;;
    esac
    while true; do
        clear
        show_banner
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║ Configure as Client (Iran/Domestic)                           ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}\n"
        
        get_network_info
        local public_ip
        public_ip=$(get_public_ip)
        
        echo -e "${YELLOW}Detected Network Information${NC}"
        echo -e "┌──────────────────────────────────────────────────────────────┐"
        printf "│ %-12s : %-44s │\n" "Interface" "${NETWORK_INTERFACE:-Not found}"
        printf "│ %-12s : %-44s │\n" "Local IP" "${LOCAL_IP:-Not found}"
        printf "│ %-12s : %-44s │\n" "Public IP" "$public_ip"
        printf "│ %-12s : %-44s │\n" "Gateway MAC" "${GATEWAY_MAC:-Not found}"
        echo -e "└──────────────────────────────────────────────────────────────┘\n"
        
        echo -e "${CYAN}Client Configuration${NC}"
        echo -e "────────────────────────────────────────────────────────────────"
        
        # [1/15] Service Name
        echo -en "${YELLOW}[1/15] Service Name (e.g: myclient) : ${NC}"
        read -r config_name
        config_name=$(clean_config_name "${config_name:-client}")
        echo -e "[1/15] Service Name : ${CYAN}$config_name${NC}"
        
        if [ -f "$CONFIG_DIR/${config_name}.yaml" ]; then
            print_warning "Config already exists!"
            read -p "Overwrite? (y/N): " ow
            [[ ! "$ow" =~ ^[Yy]$ ]] && continue
        fi
        
        # [2/15] Server IP
        echo -en "${YELLOW}[2/15] Server IP (kharej e.g: 45.76.123.89) : ${NC}"
        read -r server_ip
        [ -z "$server_ip" ] && { print_error "Server IP required"; continue; }
        validate_ip "$server_ip" || { print_error "Invalid IP format"; continue; }
        echo -e "[2/15] Server IP : ${CYAN}$server_ip${NC}"
        
        # [3/15] Server Port
        echo -en "${YELLOW}[3/15] Server Port (default: $DEFAULT_LISTEN_PORT) : ${NC}"
        read -r server_port
        server_port="${server_port:-$DEFAULT_LISTEN_PORT}"
        validate_port "$server_port" || { print_error "Invalid port"; continue; }
        echo -e "[3/15] Server Port : ${CYAN}$server_port${NC}"

        # Optional backup server addresses (WildPaqet Core v2 multi-addr)
        echo -en "${YELLOW}[3b/15] Backup server addrs (comma IP:port, Enter=skip): ${NC}"
        read -r backup_addrs_raw
        local backup_addrs=()
        if [ -n "$backup_addrs_raw" ]; then
            IFS=',' read -ra _bak_parts <<< "$backup_addrs_raw"
            for _b in "${_bak_parts[@]}"; do
                _b=$(echo "$_b" | xargs)
                [ -n "$_b" ] && backup_addrs+=("$_b")
            done
            echo -e "[3b/15] Backups : ${CYAN}${backup_addrs[*]}${NC}"
        else
            echo -e "[3b/15] Backups : ${CYAN}none${NC}"
        fi
        
        # [4/15] Secret Key
        echo -en "${YELLOW}[4/15] Secret Key (from server) : ${NC}"
        read -r secret_key
        [ -z "$secret_key" ] && { print_error "Secret key required"; continue; }
        echo -e "[4/15] Secret Key : ${GREEN}$secret_key${NC}"
        
        # [5/15] KCP Mode
        echo -e "\n${CYAN}KCP Mode Selection${NC}"
        echo -e "────────────────────────────────────────────────────────────────"
        for mode_key in 0 1 2 3 4; do
            IFS=':' read -r name desc <<< "${KCP_MODES[$mode_key]}"
            echo " [${mode_key}] ${name} - ${desc}"
        done
        echo ""

        local mode_choice
        read -p "[5/15] Choose KCP mode [0-4] (default 0 - normal): " mode_choice
        mode_choice="${mode_choice:-0}"

        local mode_name
        local kcp_fragment=""

        case $mode_choice in
            0) mode_name="normal" ;;
            1) mode_name="fast" ;;
            2) mode_name="fast2" ;;
            3) mode_name="fast3" ;;
            4) 
                mode_name="manual"
                echo -e "\n${YELLOW}Manual KCP Advanced Parameters${NC}"
                echo -e "────────────────────────────────────────────────────────────────"
                kcp_fragment=$(get_manual_kcp_settings)
                ;;
            *) mode_name="$DEFAULT_KCP_MODE" ;;
        esac
        echo -e "[5/15] KCP Mode : ${CYAN}$mode_name${NC}"
        
        # [6/15] Connections
        echo -en "${YELLOW}[6/15] Connections [1-32, 0=skip] (default $DEFAULT_CONNECTIONS_CLIENT): ${NC}"
        read -r conn_input
        local conn=""
        if [ -z "$conn_input" ]; then
            conn="$DEFAULT_CONNECTIONS_CLIENT"
            echo -e "[6/15] Connections : ${CYAN}$DEFAULT_CONNECTIONS_CLIENT (default)${NC}"
        elif [ "$conn_input" = "0" ]; then
            conn=""
            echo -e "[6/15] Connections : ${CYAN}- (skipped)${NC}"
        elif [[ "$conn_input" =~ ^[1-9][0-9]?$ ]] && [ "$conn_input" -ge 1 ] && [ "$conn_input" -le 32 ]; then
            conn="$conn_input"
            echo -e "[6/15] Connections : ${CYAN}$conn_input${NC}"
            if [ "$conn_input" -gt 4 ]; then
                print_warning "High client conn ($conn_input) can cause reconnect loops on filtered paths; 1–2 is safer"
            fi
        else
            conn="$DEFAULT_CONNECTIONS_CLIENT"
            echo -e "${YELLOW}Invalid, using default $DEFAULT_CONNECTIONS_CLIENT${NC}"
            echo -e "[6/15] Connections : ${CYAN}$DEFAULT_CONNECTIONS_CLIENT (corrected)${NC}"
        fi
        
        # [7/15] MTU
        echo -en "${YELLOW}[7/15] MTU [100-9000, 0=skip] (default $DEFAULT_MTU): ${NC}"
        read -r mtu_input
        local mtu=""
        if [ -z "$mtu_input" ]; then
            mtu="$DEFAULT_MTU"
            echo -e "[7/15] MTU : ${CYAN}$DEFAULT_MTU (default)${NC}"
        elif [ "$mtu_input" = "0" ]; then
            mtu=""
            echo -e "[7/15] MTU : ${CYAN}- (skipped)${NC}"
        elif [[ "$mtu_input" =~ ^[0-9]+$ ]] && [ "$mtu_input" -ge 100 ] && [ "$mtu_input" -le 9000 ]; then
            mtu="$mtu_input"
            echo -e "[7/15] MTU : ${CYAN}$mtu_input${NC}"
        else
            mtu="$DEFAULT_MTU"
            echo -e "${YELLOW}Invalid, using default $DEFAULT_MTU${NC}"
            echo -e "[7/15] MTU : ${CYAN}$DEFAULT_MTU (corrected)${NC}"
        fi
        
        # [8/15] Encryption
        echo -e "\n${CYAN}Encryption Selection${NC}"
        echo -e "────────────────────────────────────────────────────────────────"
        for enc_key in 1 2 3 4 5 6 7; do
            IFS=':' read -r enc_name enc_desc <<< "${ENCRYPTION_OPTIONS[$enc_key]}"
            echo " [${enc_key}] ${enc_name} - ${enc_desc}"
        done
        echo ""
        
        local enc_choice
        read -p "[8/15] Choose encryption [1-7] (default 1): " enc_choice
        enc_choice="${enc_choice:-1}"
        
        local block
        IFS=':' read -r block _ <<< "${ENCRYPTION_OPTIONS[$enc_choice]}"
        block="${block:-aes-128-gcm}"
        echo -e "[8/15] Encryption : ${CYAN}$block${NC}"
        
         # [9/15] pcap sockbuf
        echo -en "${YELLOW}[9/15] pcap sockbuf [Enter=skip, 0=skip]: ${NC}"
        read -r pcap_input
        local pcap_sockbuf=""
        
        if [ -n "$pcap_input" ] && [ "$pcap_input" != "0" ]; then
            if [[ "$pcap_input" =~ ^[0-9]+$ ]]; then
                pcap_sockbuf="$pcap_input"
                echo -e "[9/15] pcap sockbuf : ${CYAN}$pcap_input${NC}"
            else
                print_warning "Invalid number, skipping pcap sockbuf"
                echo -e "[9/15] pcap sockbuf : ${CYAN}skipped${NC}"
            fi
        else
            echo -e "[9/15] pcap sockbuf : ${CYAN}skipped${NC}"
        fi
        
        # [10/15] transport tcpbuf
        echo -en "${YELLOW}[10/15] transport tcpbuf [Enter=skip, 0=skip]: ${NC}"
        read -r tcpbuf_input
        local transport_tcpbuf=""
        
        if [ -n "$tcpbuf_input" ] && [ "$tcpbuf_input" != "0" ]; then
            if [[ "$tcpbuf_input" =~ ^[0-9]+$ ]]; then
                transport_tcpbuf="$tcpbuf_input"
                echo -e "[10/15] transport tcpbuf : ${CYAN}$tcpbuf_input${NC}"
            else
                print_warning "Invalid number, skipping transport tcpbuf"
                echo -e "[10/15] transport tcpbuf : ${CYAN}skipped${NC}"
            fi
        else
            echo -e "[10/15] transport tcpbuf : ${CYAN}skipped${NC}"
        fi
        
        # [11/15] transport udpbuf
        echo -en "${YELLOW}[11/15] transport udpbuf [Enter=skip, 0=skip]: ${NC}"
        read -r udpbuf_input
        local transport_udpbuf=""
        
        if [ -n "$udpbuf_input" ] && [ "$udpbuf_input" != "0" ]; then
            if [[ "$udpbuf_input" =~ ^[0-9]+$ ]]; then
                transport_udpbuf="$udpbuf_input"
                echo -e "[11/15] transport udpbuf : ${CYAN}$udpbuf_input${NC}"
            else
                print_warning "Invalid number, skipping transport udpbuf"
                echo -e "[11/15] transport udpbuf : ${CYAN}skipped${NC}"
            fi
        else
            echo -e "[11/15] transport udpbuf : ${CYAN}skipped${NC}"
        fi
        
        # [12/15] Traffic Type
        echo -e "\n${CYAN}Traffic Type Selection${NC}"
        echo -e "────────────────────────────────────────────────────────────────"
        echo -e " ${GREEN}[1]${NC} Port Forwarding - Forward specific ports"
        echo -e " ${GREEN}[2]${NC} SOCKS5 Proxy - Create a SOCKS5 proxy"
        echo ""
        
        local traffic_type
        read -p "[12/15] Choose traffic type [1-2] (default 1): " traffic_type
        traffic_type="${traffic_type:-1}"
        
        local forward_entries=()
        local socks5_entries=()
        local display_ports=""
        local SOCKS5_PORT=""
        local SOCKS5_USER=""
        local SOCKS5_PASS=""
        
        case $traffic_type in
            1)
                echo -e "\n${CYAN}Port Forwarding Configuration${NC}"
                echo -e "────────────────────────────────────────────────────────────────"
                
                echo -en "${YELLOW}[13/15] Forward Ports (comma separated) [default $DEFAULT_V2RAY_PORTS]: ${NC}"
                read -r forward_ports
                forward_ports=$(clean_port_list "${forward_ports:-$DEFAULT_V2RAY_PORTS}")
                [ -z "$forward_ports" ] && { print_error "No valid ports"; continue; }
                echo -e "[13/15] Forward Ports : ${CYAN}$forward_ports${NC}"
                
                echo -e "\n${CYAN}Protocol Selection${NC}"
                echo -e "────────────────────────────────────────────────────────────────"
                echo " [1] tcp - TCP only (default)"
                echo " [2] udp - UDP only"
                echo " [3] tcp/udp - Both"
                echo ""
                
                IFS=',' read -ra PORTS <<< "$forward_ports"
                for p in "${PORTS[@]}"; do
                    p=$(echo "$p" | tr -d '[:space:]')
                    echo -en "${YELLOW}Port $p → protocol [1-3] : ${NC}"
                    read -r proto_choice
                    proto_choice="${proto_choice:-1}"
                    
                    case $proto_choice in
                        1)
                            forward_entries+=("  - listen: \"0.0.0.0:$p\"\n    target: \"127.0.0.1:$p\"\n    protocol: \"tcp\"")
                            display_ports+=" $p (TCP)"
                            configure_iptables "$p" "tcp"
                            ;;
                        2)
                            forward_entries+=("  - listen: \"0.0.0.0:$p\"\n    target: \"127.0.0.1:$p\"\n    protocol: \"udp\"")
                            display_ports+=" $p (UDP)"
                            configure_iptables "$p" "udp"
                            ;;
                        3)
                            forward_entries+=("  - listen: \"0.0.0.0:$p\"\n    target: \"127.0.0.1:$p\"\n    protocol: \"tcp\"")
                            forward_entries+=("  - listen: \"0.0.0.0:$p\"\n    target: \"127.0.0.1:$p\"\n    protocol: \"udp\"")
                            display_ports+=" $p (TCP+UDP)"
                            configure_iptables "$p" "both"
                            ;;
                        *)
                            forward_entries+=("  - listen: \"0.0.0.0:$p\"\n    target: \"127.0.0.1:$p\"\n    protocol: \"tcp\"")
                            display_ports+=" $p (TCP)"
                            configure_iptables "$p" "tcp"
                            ;;
                    esac
                done
                echo -e "[13/15] Protocol(s) : ${CYAN}${display_ports# }${NC}"
                ;;
                
            2)
                echo -e "\n${CYAN}SOCKS5 Proxy Configuration${NC}"
                echo -e "────────────────────────────────────────────────────────────────"
                
                echo -en "${YELLOW}[13/15] SOCKS5 Proxy Port (default $DEFAULT_SOCKS5_PORT): ${NC}"
                read -r socks_port
                socks_port="${socks_port:-$DEFAULT_SOCKS5_PORT}"
                validate_port "$socks_port" || { print_error "Invalid port"; continue; }
                echo -e "[13/15] SOCKS5 Port : ${CYAN}$socks_port${NC}"
                
                check_port_conflict "$socks_port" || { pause "Press Enter to retry..."; continue; }
                configure_iptables "$socks_port" "tcp"
                
                echo -e "\n${CYAN}SOCKS5 Authentication (Optional)${NC}"
                echo -e "────────────────────────────────────────────────────────────────"
                echo -e "${YELLOW}Leave empty for no authentication${NC}"
                
                echo -en "${YELLOW}SOCKS5 Username: ${NC}"
                read -r socks_user
                
                if [ -n "$socks_user" ]; then
                    echo -en "${YELLOW}SOCKS5 Password: ${NC}"
                    read -r socks_pass
                    
                    if [ -z "$socks_pass" ]; then
                        print_error "Password required if username is set"
                        continue
                    fi
                    
                    echo -e "Authentication: ${GREEN}Enabled${NC}"
                    SOCKS5_USER="$socks_user"
                    SOCKS5_PASS="$socks_pass"
                    socks5_entries+=("  - listen: \"127.0.0.1:$socks_port\"\n    username: \"$socks_user\"\n    password: \"$socks_pass\"")
                else
                    echo -e "Authentication: ${YELLOW}Disabled${NC}"
                    socks5_entries+=("  - listen: \"127.0.0.1:$socks_port\"")
                fi
                
                SOCKS5_PORT="$socks_port"
                ;;
                
            *)
                print_error "Invalid choice"
                continue
                ;;
        esac

        if [[ "$traffic_type" == "1" ]]; then
            if ! validate_forward_rules; then
                echo -e "\n${RED}⚠️  TRAFFIC LOOP DETECTED!${NC}"
                echo -e "  • Server endpoint: $server_ip:$server_port"
                echo -e "  • Forward ports: $forward_ports"
                echo -e "${YELLOW}Make sure none of the forward ports match the server port.${NC}"
                echo -e "${YELLOW}Forward ports should point to your actual services (V2Ray, web servers, etc.), not the Paqet tunnel.${NC}"
                pause
                continue
            fi
        fi

        # Apply configuration
        echo -e "\n${CYAN}Applying Configuration${NC}"
        echo -e "────────────────────────────────────────────────────────────────"
        
        if [ ! -f "$BIN_DIR/paqet" ]; then
            install_paqet || continue
        fi
        
        mkdir -p "$CONFIG_DIR"
        
        # Build client config with proper indentation
        {
            echo "# Paqet Client Configuration"
            echo "role: \"client\""
            echo "log:"
            echo "  level: \"info\""
            
            if [ ${#forward_entries[@]} -gt 0 ]; then
                echo "forward:"
                for entry in "${forward_entries[@]}"; do
                    echo -e "$entry"
                done
            fi
            
            if [ ${#socks5_entries[@]} -gt 0 ]; then
                echo "socks5:"
                for entry in "${socks5_entries[@]}"; do
                    echo -e "$entry"
                done
            fi
            
            echo "network:"
            echo "  interface: \"$NETWORK_INTERFACE\""
            echo "  ipv4:"
            echo "    addr: \"$LOCAL_IP:0\""
            echo "    router_mac: \"$GATEWAY_MAC\""
            echo "  tcp:"
            echo "    local_flag: [\"PA\"]"
            echo "    remote_flag: [\"PA\"]"
            echo "    preset: \"${DEFAULT_TCP_PRESET}\""
            echo "    handshake: \"mimic\""
            echo "    track_seq: true"
            echo "    ipv4_tos: 0"
            
            if [[ -n "$pcap_sockbuf" ]]; then
                echo "  pcap:"
                echo "    sockbuf: $pcap_sockbuf"
            fi
            
            echo "server:"
            echo "  addr: \"$server_ip:$server_port\""
            if [ ${#backup_addrs[@]} -gt 0 ]; then
                echo "  addrs:"
                for _ba in "${backup_addrs[@]}"; do
                    echo "    - \"$_ba\""
                done
            fi
            echo "transport:"
            echo "  protocol: \"kcp\""
            
            [[ -n "$conn" ]] && echo "  conn: $conn"
            [[ -n "$transport_tcpbuf" ]] && echo "  tcpbuf: $transport_tcpbuf"
            [[ -n "$transport_udpbuf" ]] && echo "  udpbuf: $transport_udpbuf"
            
            echo "  kcp:"
            echo "    key: \"$secret_key\""
            
            if [ "$mode_name" = "manual" ] && [ -n "$kcp_fragment" ]; then
                echo "    mode: \"manual\""
                echo "    block: \"$block\""
                [[ -n "$mtu" ]] && echo "    mtu: $mtu"
                while IFS= read -r line; do
                    if [[ -n "$line" ]] && ! echo "$line" | grep -q "mode:"; then
                        echo "    $line"
                    fi
                done <<< "$kcp_fragment"
            else
                echo "    mode: \"$mode_name\""
                echo "    block: \"$block\""
                [[ -n "$mtu" ]] && echo "    mtu: $mtu"
            fi
            echo "    smuxkalive: $DEFAULT_SMUX_KEEPALIVE"
            echo "    smuxktimeout: $DEFAULT_SMUX_KEEPALIVE_TIMEOUT"
        } > "$CONFIG_DIR/${config_name}.yaml"
        
        echo -e "[+] Configuration saved : ${CYAN}$CONFIG_DIR/${config_name}.yaml${NC}"
        
        # Protect the outbound tunnel leg(s) before the service starts, so the
        # first handshake is not RST'd by the local kernel.
        configure_client_iptables "$CONFIG_DIR/${config_name}.yaml"
        
        create_systemd_service "$config_name"
        local svc="paqet-${config_name}"
        systemctl enable "$svc" --now >/dev/null 2>&1
        
        if systemctl is-active --quiet "$svc"; then
            print_success "Client started successfully"
            add_auto_restart_cronjob "$svc" "$DEFAULT_AUTO_RESTART_INTERVAL" >/dev/null 2>&1
            
            echo -e "\n${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${GREEN}║ Client Ready                                                   ║${NC}"
            echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}\n"
            
            echo -e "${YELLOW}Client Information${NC}"
            echo -e "┌──────────────────────────────────────────────────────────────┐"
            printf "│ %-16s : %-42s │\n" "This Server" "$public_ip"
            printf "│ %-16s : %-42s │\n" "Remote Server" "$server_ip:$server_port"
            
            if [ "$traffic_type" = "1" ] && [ ${#forward_entries[@]} -gt 0 ]; then
                printf "│ %-16s : %-42s │\n" "Forward Ports" "${display_ports# }"
            elif [ "$traffic_type" = "2" ] && [ ${#socks5_entries[@]} -gt 0 ]; then
                printf "│ %-16s : %-42s │\n" "SOCKS5 Port" "$SOCKS5_PORT"
                if [ -n "$SOCKS5_USER" ]; then
                    printf "│ %-16s : %-42s │\n" "SOCKS5 User" "$SOCKS5_USER"
                    printf "│ %-16s : %-42s │\n" "SOCKS5 Pass" "********"
                else
                    printf "│ %-16s : %-42s │\n" "Authentication" "None"
                fi
            fi
            
            printf "│ %-16s : %-42s │\n" "Connections" "${conn:-$DEFAULT_CONNECTIONS_CLIENT}"
            printf "│ %-16s : %-42s │\n" "Auto Restart" "Every ${DEFAULT_AUTO_RESTART_INTERVAL}"
            echo -e "└──────────────────────────────────────────────────────────────┘\n"
            
            echo -e "${YELLOW}KCP Configuration${NC}"
            echo -e "┌──────────────────────────────────────────────────────────────┐"
            printf "│ %-14s : %-44s │\n" "Mode" "$mode_name"
            printf "│ %-14s : %-44s │\n" "Encryption" "$block"
            printf "│ %-14s : %-44s │\n" "MTU" "${mtu:-$DEFAULT_MTU}"
            echo -e "└──────────────────────────────────────────────────────────────┘\n"
            
            echo ""
            echo -e "${GREEN}✅ Client setup completed successfully!${NC}"
            echo -e "${CYAN}Options:${NC}"
            echo -e " 1. Press ${GREEN}Enter${NC} to go to service management for $config_name"
            echo -e " 2. Type ${YELLOW}menu${NC} to return to main menu"
            echo -e " 3. Type ${YELLOW}exit${NC} to exit"
            echo ""
            
            read -p "Your choice [Enter/menu/exit]: " post_choice
            
            case "${post_choice,,}" in
                ""|enter)
                    echo -e "${GREEN}➡️ Taking you to service management for $config_name...${NC}"
                    sleep 1
                    manage_single_service "$svc" "$config_name"
                    ;;
                menu)
                    echo -e "${CYAN}Returning to main menu...${NC}"
                    sleep 1
                    return 0
                    ;;
                exit)
                    echo -e "${GREEN}Goodbye!${NC}"
                    exit 0
                    ;;
                *)
                    echo -e "${YELLOW}Invalid choice. Returning to main menu...${NC}"
                    sleep 2
                    return 0
                    ;;
            esac
        else
            print_error "Client failed to start"
            systemctl status "$svc" --no-pager -l
            pause
        fi
        return 0
    done
}

# ================================================
# TEST FUNCTIONS
# ================================================

# Test internet connectivity
test_internet_connectivity() {
    echo -e "\n${YELLOW}Internet Connectivity Test${NC}"
    echo -e "────────────────────────────────────────────────────────────────"
    
    print_step "Testing internet connectivity...\n"
    
    local test_hosts=("8.8.8.8" "1.1.1.1" "208.67.222.222")
    local success_count=0
    local total_tests=${#test_hosts[@]}
    
    for host in "${test_hosts[@]}"; do
        echo -n " Testing connection to $host: "
        if ping -c 2 -W 1 "$host" &>/dev/null; then
            echo -e "${GREEN}✓ CONNECTED${NC}"
            ((success_count++))
        else
            echo -e "${RED}✗ FAILED${NC}"
        fi
    done
    
    echo -e "\n${CYAN}Test Results:${NC}"
    if [ "$success_count" -eq "$total_tests" ]; then
        print_success "✅ Internet connectivity: EXCELLENT (${success_count}/${total_tests})"
    elif [ "$success_count" -ge $((total_tests / 2)) ]; then
        print_warning "⚠️ Internet connectivity: PARTIAL (${success_count}/${total_tests})"
    else
        print_error "❌ Internet connectivity: POOR (${success_count}/${total_tests})"
    fi
    
    if [ "$success_count" -gt 0 ]; then
        echo -e "\n${YELLOW}Speed Test${NC}"
        echo -e "────────────────────────────────────────────────────────────────"
        local speed_test
        speed_test=$(timeout 10 curl -o /dev/null -w "%{speed_download}" --max-filesize 10485760 https://speedtest.ftp.otenet.gr/files/test10Mb.db 2>/dev/null || echo "0")
        
        if [ "$speed_test" != "0" ] && [ -n "$speed_test" ]; then
            if command -v bc &>/dev/null; then
                local speed_mbps
                speed_mbps=$(echo "scale=2; $speed_test * 8 / 1000000" | bc 2>/dev/null || echo "0")
                
                if (( $(echo "$speed_mbps > 10" | bc -l 2>/dev/null) )); then
                    echo -e " ${GREEN}✅ Download speed: ${speed_mbps} Mbps${NC}"
                elif (( $(echo "$speed_mbps > 1" | bc -l 2>/dev/null) )); then
                    echo -e " ${YELLOW}⚠️ Download speed: ${speed_mbps} Mbps${NC}"
                else
                    echo -e " ${RED}❌ Download speed: ${speed_mbps} Mbps${NC}"
                fi
            else
                local speed_mbps_int=$(( (${speed_test%.*} * 8) / 1000000 ))
                if [ "$speed_mbps_int" -gt 10 ]; then
                    echo -e " ${GREEN}✅ Download speed: ~${speed_mbps_int} Mbps${NC}"
                elif [ "$speed_mbps_int" -gt 1 ]; then
                    echo -e " ${YELLOW}⚠️ Download speed: ~${speed_mbps_int} Mbps${NC}"
                else
                    echo -e " ${RED}❌ Download speed: ~${speed_mbps_int} Mbps${NC}"
                fi
            fi
        else
            echo -e " ${YELLOW}⚠️ Speed test failed or timed out${NC}"
        fi
    fi
}

# Test DNS resolution
test_dns_resolution() {
    echo -e "\n${YELLOW}DNS Resolution Test${NC}"
    echo -e "────────────────────────────────────────────────────────────────"
    
    print_step "Testing DNS resolution...\n"
    
    echo -e "${CYAN}Testing domain resolution:${NC}\n"
    
    local resolved_count=0
    local total_domains=${#TEST_DOMAINS[@]}
    
    for domain in "${TEST_DOMAINS[@]}"; do
        echo -n " $domain: "
        if timeout 3 dig +short "$domain" &>/dev/null; then
            echo -e "${GREEN}✓ RESOLVED${NC}"
            ((resolved_count++))
        else
            echo -e "${RED}✗ FAILED${NC}"
        fi
    done
    
    echo -e "\n${CYAN}Testing DNS servers:${NC}\n"
    
    for dns in "${DNS_SERVERS[@]}"; do
        echo -n " $dns: "
        if [ "$dns" = "system" ]; then
            if timeout 3 nslookup google.com &>/dev/null; then
                echo -e "${GREEN}✓ WORKING${NC}"
            else
                echo -e "${RED}✗ FAILED${NC}"
            fi
        else
            if timeout 3 dig +short google.com @"$dns" &>/dev/null; then
                echo -e "${GREEN}✓ WORKING${NC}"
            else
                echo -e "${RED}✗ FAILED${NC}"
            fi
        fi
    done
    
    echo -e "\n${CYAN}Summary:${NC}"
    if [ "$resolved_count" -eq "$total_domains" ]; then
        print_success "✅ DNS resolution: PERFECT (${resolved_count}/${total_domains})"
    elif [ "$resolved_count" -ge $((total_domains / 2)) ]; then
        print_warning "⚠️ DNS resolution: PARTIAL (${resolved_count}/${total_domains})"
    else
        print_error "❌ DNS resolution: POOR (${resolved_count}/${total_domains})"
    fi
}

# Extract ping stats
extract_ping_stats() {
    local ping_output="$1"
    local rtt_line
    rtt_line=$(echo "$ping_output" | grep "rtt min/avg/max/mdev")
    
    if [ -n "$rtt_line" ]; then
        local stats
        stats=$(echo "$rtt_line" | sed 's/.*= //' | sed 's/ ms//')
        echo "$stats" | tr '/' ' '
    else
        echo "0 0 0 0"
    fi
}

# Test Paqet tunnel
test_paqet_tunnel() {
    clear
    echo -e "\n${YELLOW}Test Paqet Tunnel Connection${NC}"
    echo -e "────────────────────────────────────────────────────────────────"
    
    echo -e "${CYAN}This test will check if you can establish a Paqet tunnel between two servers.${NC}\n"
    
    echo -en "${YELLOW}Remote Server IP Address: ${NC}"
    read -r remote_ip
    
    [ -z "$remote_ip" ] && { print_error "IP address required"; return; }
    validate_ip "$remote_ip" || { print_error "Invalid IP address format"; return; }
    
    echo -e "\n${YELLOW}Starting comprehensive Paqet tunnel test to $remote_ip...${NC}\n"
    
    # 1. Basic connectivity
    print_step "1. Testing basic ICMP connectivity..."
    
    local ping_output
    ping_output=$(ping -c 5 -W 2 "$remote_ip" 2>&1)
    local avg_ping=""
    local packet_loss="100"
    
    if [ $? -eq 0 ] || echo "$ping_output" | grep -q "transmitted"; then
        packet_loss=$(echo "$ping_output" | grep -o "[0-9]*% packet loss" | grep -o "[0-9]*" || echo "0")
        
        if echo "$ping_output" | grep -q "rtt min/avg/max/mdev"; then
            avg_ping=$(echo "$ping_output" | grep "rtt min/avg/max/mdev" | awk -F'/' '{print $5}')
        fi
        
        print_success "✅ Basic ICMP connectivity: SUCCESS"
        echo -e " ${CYAN}Details:${NC} Avg RTT: ${avg_ping:-N/A} ms, Packet loss: ${packet_loss}%"
    else
        print_warning "⚠️ Basic ICMP: FAILED (may be blocked)"
    fi
    
    # 2. Test common ports
    echo -e "\n${YELLOW}2. Testing common ports...${NC}"
    local paqet_ports_found=0
    
    for port in "${COMMON_PORTS[@]}"; do
        echo -n " Port $port: "
        if timeout 3 bash -c "</dev/tcp/$remote_ip/$port" 2>/dev/null; then
            echo -e "${GREEN}OPEN${NC}"
            ((paqet_ports_found++))
        else
            echo -e "${CYAN}Closed/Filtered${NC}"
        fi
        sleep 0.1
    done
    
    if [ $paqet_ports_found -eq 0 ]; then
        print_warning "⚠️ No common ports found open"
    else
        print_success "✅ Found $paqet_ports_found open port(s)"
    fi
    
    # 3. MTU testing
    echo -e "\n${YELLOW}3. MTU and packet loss analysis...${NC}"
    echo -e "${CYAN}Testing different MTU sizes (10 packets each):${NC}\n"
    
    local best_mtu=""
    local best_loss=100
    local best_ping=9999
    
    for mtu in "${MTU_TESTS[@]}"; do
        local payload_size=$((mtu - 28))
        [ $payload_size -lt 0 ] && continue
        
        echo -n " MTU $mtu: "
        local ping_output
        ping_output=$(ping -c 10 -W 1 -M do -s "$payload_size" "$remote_ip" 2>&1)
        
        if echo "$ping_output" | grep -q "transmitted"; then
            local sent received loss_percent
            sent=$(echo "$ping_output" | grep transmitted | awk '{print $1}')
            received=$(echo "$ping_output" | grep transmitted | awk '{print $4}')
            loss_percent=$(( (sent - received) * 100 / sent ))
            
            local stats
            stats=$(extract_ping_stats "$ping_output")
            local min_avg_max_mdev
            read -r min_avg_max_mdev <<< "$stats"
            
            if [ "$received" -eq "$sent" ]; then
                echo -e "${GREEN}PERFECT${NC} - 0% loss"
                if [ -z "$best_mtu" ] || [ "$loss_percent" -lt "$best_loss" ] || 
                   { [ "$loss_percent" -eq "$best_loss" ] && [ "$avg_ping" -lt "$best_ping" ]; }; then
                    best_mtu="$mtu"
                    best_loss="$loss_percent"
                    best_ping="$avg_ping"
                fi
            elif [ "$loss_percent" -le 10 ]; then
                echo -e "${GREEN}GOOD${NC} - ${loss_percent}% loss"
                if [ "$loss_percent" -lt "$best_loss" ]; then
                    best_mtu="$mtu"
                    best_loss="$loss_percent"
                    best_ping="$avg_ping"
                fi
            elif [ "$loss_percent" -le 30 ]; then
                echo -e "${YELLOW}FAIR${NC} - ${loss_percent}% loss"
            else
                echo -e "${RED}POOR${NC} - ${loss_percent}% loss"
            fi
        else
            echo -e "${RED}FAILED${NC}"
        fi
    done
    
    # 4. Summary
    echo -e "\n${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║ Test Summary & Recommendations                                 ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}\n"
    
    echo -e "${CYAN}Connection Quality:${NC}"
    if [ -n "$avg_ping" ]; then
        if compare_floats "$avg_ping" "50" "lt"; then
            echo -e " ${GREEN}✅ Latency: EXCELLENT (< 50ms)${NC}"
        elif compare_floats "$avg_ping" "150" "lt"; then
            echo -e " ${GREEN}✅ Latency: GOOD (< 150ms)${NC}"
        elif compare_floats "$avg_ping" "300" "lt"; then
            echo -e " ${YELLOW}⚠️ Latency: FAIR (< 300ms)${NC}"
        else
            echo -e " ${YELLOW}⚠️ Latency: HIGH (> 300ms)${NC}"
        fi
    fi
    
    if [ -n "$packet_loss" ]; then
        if [ "$packet_loss" -eq 0 ]; then
            echo -e " ${GREEN}✅ Packet Loss: EXCELLENT (0%)${NC}"
        elif [ "$packet_loss" -le 5 ]; then
            echo -e " ${GREEN}✅ Packet Loss: GOOD (≤ 5%)${NC}"
        elif [ "$packet_loss" -le 15 ]; then
            echo -e " ${YELLOW}⚠️ Packet Loss: FAIR (≤ 15%)${NC}"
        else
            echo -e " ${RED}❌ Packet Loss: HIGH (> 15%)${NC}"
        fi
    fi
    
    echo -e "\n${CYAN}MTU Recommendations:${NC}"
    if [ -n "$best_mtu" ]; then
        if [ "$best_loss" -eq 0 ]; then
            echo -e " ${GREEN}✅ Best MTU: $best_mtu (0% loss)${NC}"
        else
            echo -e " ${YELLOW}⚠️ Best MTU: $best_mtu (${best_loss}% loss)${NC}"
        fi
        
        if [ "$best_mtu" -ge 1400 ]; then
            echo -e " ${GREEN}• Primary: 1400 (optimal)${NC}"
            echo -e " ${GREEN}• Secondary: 1350 (balanced)${NC}"
            echo -e " ${CYAN}• Fallback: 1300 (stable)${NC}"
        elif [ "$best_mtu" -ge 1300 ]; then
            echo -e " ${GREEN}• Primary: 1350 (balanced)${NC}"
            echo -e " ${GREEN}• Secondary: 1300 (stable)${NC}"
            echo -e " ${CYAN}• Fallback: 1200 (reliable)${NC}"
        else
            echo -e " ${YELLOW}• Primary: 1200 (reliable)${NC}"
            echo -e " ${YELLOW}• Secondary: 1100 (ultra stable)${NC}"
            echo -e " ${CYAN}• Fallback: 1000 (guaranteed)${NC}"
        fi
    else
        echo -e " ${RED}❌ Could not determine optimal MTU${NC}"
        echo -e " ${CYAN}Recommendation: Use MTU 1200 as default${NC}"
    fi
}

# Test connection menu
test_connection() {
    clear
    show_banner
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║ Test Paqet Connection                                         ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}\n"
    
    echo -e "${CYAN}Connection Test Options:${NC}"
    echo -e "────────────────────────────────────────────────────────────────"
    echo " 1. Test Paqet tunnel connection (server to server)"
    echo " 2. Test internet connectivity"
    echo " 3. Test DNS resolution"
    echo " 0. Back to Main Menu"
    echo ""
    
    while true; do
        read -p "Choose option [0-3]: " test_choice
        
        case $test_choice in
            1)
                test_paqet_tunnel
                pause
                return
                ;;
            2)
                test_internet_connectivity
                pause
                return
                ;;
            3)
                test_dns_resolution
                pause
                return
                ;;
            0)
                return
                ;;
            *)
                print_error "Invalid choice. Please enter 0-3."
                ;;
        esac
    done
}

# ================================================
# INSTALLATION FUNCTIONS
# ================================================

# Check dependencies
check_dependencies() {
    local missing_deps=()
    local os
    os=$(detect_os)
    
    local common_deps=("curl" "wget" "iptables" "lsof" "openssl" "base64")
    
    case $os in
        ubuntu|debian)
            common_deps+=("libpcap-dev" "iproute2" "cron" "dig")
            ;;
        centos|rhel|fedora|rocky|almalinux)
            common_deps+=("libpcap-devel" "iproute" "cronie" "bind-utils")
            ;;
    esac
    
    for dep in "${common_deps[@]}"; do
        if ! command -v "$dep" &>/dev/null && 
           ! dpkg -l | grep -q "$dep" 2>/dev/null && 
           ! rpm -q "$dep" &>/dev/null 2>&1; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -eq 0 ]; then
        return 0
    else
        echo "${missing_deps[@]}"
        return 1
    fi
}

# Install dependencies
install_dependencies() {
    clear
    show_banner
    print_step "Installing dependencies..."
    
    local os
    os=$(detect_os)
    
    case $os in
        ubuntu|debian)
            print_info "Updating package lists..."
            apt update -qq >/dev/null 2>&1 || true
            
            print_info "Installing base packages..."
            apt install -y curl wget openssl coreutils libpcap-dev iptables lsof iproute2 cron dnsutils >/dev/null 2>&1 || {
                print_warning "Some base packages may have failed to install"
            }
            
            # Install iptables persistence
            install_iptables_persistent
            ;;
            
        centos|rhel|fedora|rocky|almalinux)
            print_info "Installing base packages..."
            yum install -y curl wget openssl coreutils libpcap-devel iptables lsof iproute cronie bind-utils >/dev/null 2>&1 || {
                print_warning "Some base packages may have failed to install"
            }
            
            # Install iptables persistence
            install_iptables_persistent
            ;;
            
        *)
            print_warning "Unknown OS. Please install manually: libpcap iptables curl cron dnsutils"
            print_warning "Also ensure iptables rules persist after reboot on your system"
            ;;
    esac
    
    print_success "Dependency installation completed"
    pause
    return
}

# ================================================
# IPTABLES PERSISTENCE FUNCTIONS
# ================================================

install_iptables_persistent() {
    print_step "Installing iptables persistence..."
    local os=$(detect_os)
    case $os in
        ubuntu|debian)
            if dpkg -l | grep -q "iptables-persistent"; then
                print_success "iptables-persistent is already installed"
            else
                print_info "Installing iptables-persistent (non-interactive)..."
                export DEBIAN_FRONTEND=noninteractive
                apt-get update -qq >/dev/null 2>&1
                apt-get install -y iptables-persistent >/dev/null 2>&1
                
                if [ $? -eq 0 ]; then
                    print_success "iptables-persistent installed successfully"
                    save_iptables
                else
                    print_warning "Failed to install iptables-persistent"
                    print_info "iptables rules will NOT persist after reboot unless you install it manually"
                fi
            fi
            ;;
            
        centos|rhel|fedora|rocky|almalinux)
            local pkg="iptables-services"
            if ! rpm -q "$pkg" >/dev/null 2>&1; then
                print_info "Installing $pkg..."
                if command -v yum >/dev/null 2>&1; then
                    yum install -y "$pkg" >/dev/null 2>&1
                elif command -v dnf >/dev/null 2>&1; then
                    dnf install -y "$pkg" >/dev/null 2>&1
                fi
                
                if [ $? -eq 0 ]; then
                    print_success "$pkg installed"
                    systemctl enable iptables >/dev/null 2>&1
                    save_iptables
                else
                    print_warning "Failed to install $pkg"
                fi
            else
                print_success "$pkg is already installed"
            fi
            ;;
            
        *)
            print_warning "Unknown OS - iptables persistence may require manual setup"
            print_info "Please install iptables-persistent (Debian/Ubuntu) or iptables-services (RHEL-based)"
            ;;
    esac
    
    # Final save attempt in all cases
    save_iptables
}

# Run a long step with a heartbeat, so a slow or filtered link never looks like
# a frozen script. Returns the command's exit code (124 = timed out).
run_with_progress() {
    local secs="$1"; shift
    local label="$1"; shift

    echo -ne "${CYAN}  → ${label}${NC}"
    ( timeout "$secs" "$@" >/dev/null 2>&1 ) &
    local pid=$!
    local waited=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 5
        waited=$((waited + 5))
        echo -n "."
    done
    wait "$pid"
    local rc=$?

    case $rc in
        0)   echo -e " ${GREEN}ok${NC} (${waited}s)" ;;
        124) echo -e " ${YELLOW}timed out after ${secs}s${NC}" ;;
        *)   echo -e " ${YELLOW}failed (rc=$rc)${NC}" ;;
    esac
    return $rc
}

# True when everything the core build needs is already installed. Re-running the
# package manager is the single biggest stall on restricted links, so skip it.
build_deps_present() {
    command -v go >/dev/null 2>&1 || return 1
    command -v gcc >/dev/null 2>&1 || return 1
    command -v curl >/dev/null 2>&1 || return 1
    [ -f /usr/include/pcap.h ] || [ -f /usr/include/pcap/pcap.h ] || return 1
    return 0
}

version_at_least() {
    local have="$1"
    local need="$2"
    [ -n "$have" ] && [ "$(printf '%s\n%s\n' "$have" "$need" | sort -V | tail -1)" = "$have" ]
}

# Select a Go compiler that satisfies core/go.mod. Go 1.21+ can fetch a newer
# toolchain itself. Older distro Go versions cannot, so install an isolated,
# checksum-verified official toolchain without replacing /usr/bin/go.
prepare_build_go_toolchain() {
    local need_go="$1"
    local arch_name="$2"
    local have_go=""
    local resolved_go=""
    BUILD_GO_BIN=""

    [[ "$need_go" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || {
        print_error "Invalid Go version in core/go.mod: $need_go"
        return 1
    }

    if command -v go >/dev/null 2>&1; then
        have_go=$(go version 2>/dev/null | awk '{print $3}' | sed 's/^go//')
        if version_at_least "$have_go" "$need_go"; then
            BUILD_GO_BIN=$(command -v go)
            print_success "Using installed Go ${have_go}"
            return 0
        fi

        if version_at_least "$have_go" "1.21.0"; then
            print_warning "Installed Go is ${have_go}; source needs ${need_go}"
            if run_with_progress 420 "Fetching Go ${need_go} toolchain" \
                env GOTOOLCHAIN="go${need_go}" \
                    GOPROXY="${GOPROXY:-https://goproxy.cn,direct}" \
                    GOSUMDB="${GOSUMDB:-sum.golang.google.cn}" \
                    go version; then
                resolved_go=$(env GOTOOLCHAIN="go${need_go}" go version 2>/dev/null | awk '{print $3}' | sed 's/^go//')
                if version_at_least "$resolved_go" "$need_go"; then
                    export GOTOOLCHAIN="go${need_go}"
                    BUILD_GO_BIN=$(command -v go)
                    print_success "Go ${resolved_go} toolchain ready"
                    return 0
                fi
            fi
            print_warning "Automatic Go toolchain fetch did not produce ${need_go}; using official archive"
        else
            print_warning "Distro Go ${have_go:-unknown} is too old for automatic toolchain switching"
        fi
    else
        print_warning "No system Go found; using an isolated official toolchain"
    fi

    local go_arch=""
    case "$arch_name" in
        amd64) go_arch="amd64" ;;
        arm64) go_arch="arm64" ;;
        arm32|armv7) go_arch="armv6l" ;;
        386) go_arch="386" ;;
        *) print_error "No official Go archive mapping for architecture: $arch_name"; return 1 ;;
    esac

    local toolchain_dir="$GO_TOOLCHAIN_DIR/${need_go}"
    local toolchain_bin="$toolchain_dir/bin/go"
    if [ -x "$toolchain_bin" ]; then
        resolved_go=$("$toolchain_bin" version 2>/dev/null | awk '{print $3}' | sed 's/^go//')
        if version_at_least "$resolved_go" "$need_go"; then
            BUILD_GO_BIN="$toolchain_bin"
            print_success "Using cached isolated Go ${resolved_go}"
            return 0
        fi
    fi

    local archive="/tmp/wildpaqet-go-${need_go}-linux-${go_arch}.tar.gz"
    local checksum_file="${archive}.sha256"
    local filename="go${need_go}.linux-${go_arch}.tar.gz"
    local checksum_url="https://dl.google.com/go/${filename}.sha256"
    if ! command -v sha256sum >/dev/null 2>&1; then
        print_error "sha256sum (coreutils) is required to verify the Go toolchain"
        return 1
    fi
    local urls=(
        "https://dl.google.com/go/${filename}"
        "https://go.dev/dl/${filename}"
        "https://golang.google.cn/dl/${filename}"
    )
    local downloaded=0
    local url expected
    rm -f "$archive" "$checksum_file"
    for url in "${urls[@]}"; do
        if run_with_progress 480 "Downloading official Go ${need_go} (${go_arch})" \
            curl -fL --connect-timeout 15 --max-time 420 "$url" -o "$archive" \
            && curl -fsSL --connect-timeout 15 --max-time 60 "$checksum_url" -o "$checksum_file"; then
            expected=$(awk 'NR==1 {print $1}' "$checksum_file" 2>/dev/null)
            if [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] \
                && printf '%s  %s\n' "$expected" "$archive" | sha256sum -c - >/dev/null 2>&1; then
                downloaded=1
                break
            fi
            print_warning "Checksum verification failed for $url"
        fi
        rm -f "$archive" "$checksum_file"
    done
    rm -f "$checksum_file"
    if [ "$downloaded" -ne 1 ]; then
        print_error "Could not securely download Go ${need_go}"
        return 1
    fi

    local temp_dir="$GO_TOOLCHAIN_DIR/.${need_go}.tmp.$$"
    mkdir -p "$GO_TOOLCHAIN_DIR"
    rm -rf "$temp_dir"
    mkdir -p "$temp_dir"
    if ! tar -xzf "$archive" -C "$temp_dir" --strip-components=1; then
        rm -rf "$temp_dir"
        rm -f "$archive"
        print_error "Could not extract Go ${need_go}"
        return 1
    fi
    rm -f "$archive"
    rm -rf "$toolchain_dir"
    mv "$temp_dir" "$toolchain_dir"

    resolved_go=$("$toolchain_bin" version 2>/dev/null | awk '{print $3}' | sed 's/^go//')
    if ! version_at_least "$resolved_go" "$need_go"; then
        print_error "Installed isolated Go is ${resolved_go:-unknown}; expected ${need_go}"
        return 1
    fi
    BUILD_GO_BIN="$toolchain_bin"
    print_success "Installed isolated Go ${resolved_go} at $toolchain_dir"
}

# Build WildPaqet Core v3 from the selected manager branch (./core)
build_wildpaqet_core_from_source() {
    local arch_name="${1:-amd64}"
    print_step "Building WildPaqet Core v3 from source (branch ${MANAGER_BRANCH})..."

    local os_id
    os_id=$(detect_os)
    # Package installs are the usual place this stalls on restricted networks,
    # so skip them when possible and otherwise keep them visible and time-boxed.
    if build_deps_present; then
        print_info "Build dependencies already present, skipping package manager"
    else
        print_info "Installing build dependencies (may take a few minutes)..."
        # Never let the package manager block on a prompt or on an unreachable
        # mirror: both look identical to a frozen script from the operator side.
        export DEBIAN_FRONTEND=noninteractive
        export NEEDRESTART_MODE=a
        local apt_opts=(
            -o Acquire::http::Timeout=15
            -o Acquire::https::Timeout=15
            -o Acquire::Retries=1
            -o Dpkg::Options::=--force-confold
        )
        case "$os_id" in
            ubuntu|debian)
                run_with_progress 150 "apt-get update" \
                    apt-get update -y "${apt_opts[@]}" \
                    || print_warning "Using existing package lists"
                run_with_progress 420 "apt-get install (go, libpcap, gcc)" \
                    apt-get install -y "${apt_opts[@]}" golang-go libpcap-dev build-essential git curl \
                    || print_warning "Install incomplete; continuing if go/gcc already present"
                ;;
            centos|rhel|fedora|rocky|almalinux)
                local pm="yum"
                command -v dnf >/dev/null 2>&1 && pm="dnf"
                run_with_progress 420 "$pm install (go, libpcap, gcc)" \
                    "$pm" install -y --setopt=timeout=15 --setopt=retries=1 golang libpcap-devel gcc git curl \
                    || print_warning "Install incomplete; continuing if go/gcc already present"
                ;;
        esac
    fi

    command -v gcc >/dev/null 2>&1 || {
        print_error "GCC is required to build the CGO/libpcap core"
        pause
        return 1
    }
    if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
        print_error "curl and tar are required to fetch the source/toolchain"
        pause
        return 1
    fi
    if [ ! -f /usr/include/pcap.h ] && [ ! -f /usr/include/pcap/pcap.h ]; then
        print_error "libpcap development headers are required"
        pause
        return 1
    fi
    print_success "Native build dependencies ready"

    rm -rf "$CORE_SRC_DIR"
    mkdir -p "$CORE_SRC_DIR"
    print_info "Fetching ${MANAGER_GITHUB_REPO}@${MANAGER_BRANCH} ..."

    # git clone often stalls on restricted networks, so fetch the branch tarball
    # over plain HTTPS (direct, then mirror) and keep git only as a last resort.
    local tarball="/tmp/wildpaqet-core-${MANAGER_BRANCH}.tar.gz"
    local codeload="https://codeload.github.com/${MANAGER_GITHUB_REPO}/tar.gz/refs/heads/${MANAGER_BRANCH}"
    local sources=(
        "$codeload"
        "https://gh-proxy.com/${codeload}"
    )

    local fetched=0 url
    rm -f "$tarball"
    for url in "${sources[@]}"; do
        if curl -fsSL --connect-timeout 15 --max-time 300 "$url" -o "$tarball" 2>/dev/null \
            && [ -s "$tarball" ] \
            && tar -xzf "$tarball" -C "$CORE_SRC_DIR" --strip-components=1 2>/dev/null; then
            fetched=1
            break
        fi
        rm -f "$tarball"
    done
    rm -f "$tarball"

    if [ "$fetched" -eq 0 ] && command -v git >/dev/null 2>&1; then
        print_warning "Tarball download failed; trying git clone..."
        rm -rf "$CORE_SRC_DIR"
        if GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=30 \
            git clone --depth 1 --branch "$MANAGER_BRANCH" \
            "https://github.com/${MANAGER_GITHUB_REPO}.git" "$CORE_SRC_DIR"; then
            fetched=1
        fi
    fi

    if [ "$fetched" -eq 0 ]; then
        print_error "Could not download source from GitHub"
        print_info "Check network, or copy core/ manually to ${CORE_SRC_DIR}/core"
        pause
        return 1
    fi

    if [ ! -d "$CORE_SRC_DIR/core" ]; then
        print_error "core/ directory missing in downloaded source"
        pause
        return 1
    fi

    # Resolve a compatible compiler explicitly. This also handles fresh
    # Ubuntu/Debian releases whose packaged Go predates toolchain switching.
    local need_go
    need_go=$(awk '/^go /{print $2; exit}' "$CORE_SRC_DIR/core/go.mod" 2>/dev/null)
    if ! prepare_build_go_toolchain "$need_go" "$arch_name"; then
        echo ""
        print_info "Build on a Kharej server instead, then copy the binary here:"
        echo -e "  ${CYAN}Kharej:${NC} cd $BIN_DIR && python3 -m http.server 8899"
        echo -e "  ${CYAN}Here:${NC}   curl -fsSL http://<KHAREJ_IP>:8899/paqet -o /tmp/paqet.new \\"
        echo -e "           && chmod +x /tmp/paqet.new && mv -f /tmp/paqet.new $BIN_DIR/paqet"
        pause
        return 1
    fi

    local build_out="/tmp/paqet_linux_${arch_name}"
    print_info "Compiling (CGO + libpcap)..."
    (
        cd "$CORE_SRC_DIR/core" || exit 1
        export CGO_ENABLED=1
        # Iran-friendly module/toolchain mirrors (override if already set)
        export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"
        export GOSUMDB="${GOSUMDB:-sum.golang.google.cn}"
        timeout 1800 "$BUILD_GO_BIN" build -trimpath -ldflags "-s -w \
			-X 'paqet/cmd/version.Version=v3.1.0-wildpaqet' \
            -X 'paqet/cmd/version.GitTag=${MANAGER_BRANCH}' \
            -X 'paqet/cmd/version.BuildTime=$(date -u +%Y-%m-%dT%H:%M:%SZ)'" \
            -o "$build_out" ./cmd/main.go
    )
    local build_rc=$?
    if [ "$build_rc" -eq 124 ]; then
        print_error "Build timed out after 30 minutes"
        print_info "Usually the Go toolchain download is blocked. Build on a Kharej server, then copy the binary to $BIN_DIR/paqet"
        pause
        return 1
    fi
    if [ "$build_rc" -ne 0 ] || [ ! -f "$build_out" ]; then
        print_error "Build failed"
        pause
        return 1
    fi

    mkdir -p "$INSTALL_DIR" "$BIN_DIR"
    if [ -f "$BIN_DIR/paqet" ]; then
        cp -f "$BIN_DIR/paqet" "$BIN_DIR/paqet.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    fi
    if ! atomic_install_binary "$build_out" "$BIN_DIR/paqet"; then
        print_error "Failed to install binary to $BIN_DIR/paqet"
        pause
        return 1
    fi
    ln -sf "$BIN_DIR/paqet" "$INSTALL_DIR/paqet" 2>/dev/null || true

    print_success "WildPaqet Core v3 installed to $BIN_DIR/paqet"
    "$BIN_DIR/paqet" version 2>/dev/null || true
    echo ""
	echo -e "${YELLOW}Tip:${NC} New v3 configs use real HTTP/2 cover, visible SNI, authenticated paths and jittered rotation."
	echo -e "Legacy KCP configs still use ${CYAN}network.tcp.preset: ${DEFAULT_TCP_PRESET}${NC} with the hardened raw handshake."
	echo -e "${YELLOW}Update BOTH sides${NC} (Iran + Kharej) before enabling the HTTP/2 cover mode."
    pause
    return 0
}

# Install Paqet binary
install_paqet() {
    clear
    show_banner
    print_step "Paqet Core Installation\n"
    
    local os
    os=$(detect_os)
    local arch
    arch=$(detect_arch) || return 1
    
    # Get current version if installed
    local current_version="Not installed"
    if [ -f "$BIN_DIR/paqet" ]; then
        current_version=$("$BIN_DIR/paqet" version 2>/dev/null | grep "^Version:" | head -1 | cut -d':' -f2 | xargs)
        [ -z "$current_version" ] && current_version="unknown"
    fi
    
    # Get latest version from GitHub
    local latest_version
    latest_version=$(get_latest_paqet_version)
    
    echo -e "${YELLOW}System Information:${NC}"
    echo -e " OS: ${CYAN}$os${NC}"
    echo -e " Arch: ${CYAN}$arch${NC}"
    echo -e " Current Version: ${CYAN}$current_version${NC}"
    echo -e " Latest Version: ${CYAN}$latest_version${NC}\n"
    mkdir -p "/root/paqet"
    local arch_name=""
    case $arch in
        amd64) arch_name="amd64" ;;
        arm64) arch_name="arm64" ;;
        armv7) arch_name="arm32" ;;
        386) arch_name="386" ;;
        *) arch_name="$arch" ;;
    esac
    
    local expected_file="paqet-linux-${arch_name}-${latest_version}.tar.gz"
    local download_url
    download_url=$(resolve_core_download_url "$latest_version" "$expected_file")
    
    echo -e "${YELLOW}Download URL:${NC} ${CYAN}$download_url${NC}\n"
    
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN} WildPaqet Core v3 / paqet${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}Installation Options (core):${NC}"
    echo -e " 1) ${GREEN}Download/Update from GitHub (latest: $latest_version)${NC}"
    echo -e " 2) ${CYAN}Use local file from /root/paqet/${NC}"
    echo -e " 3) ${PURPLE}Download from custom URL${NC}"
    echo -e " 8) ${ORANGE}Build WildPaqet Core v3 from source (branch ${MANAGER_BRANCH})${NC}"
    echo -e ""
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN} WildPaqet manager${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}Installation Options (manager):${NC}"
    echo -e " 4) ${BLUE}Install script${NC}"
    echo -e " 5) ${BLUE}Update script${NC}"
    echo -e " 6) ${BLUE}Switch version${NC}"
    echo -e " 7) ${RED}Uninstall script${NC}"
    echo -e ""
    echo -e " 0) ${YELLOW}↩️ Back to main menu${NC}\n"
    
    read -p "Choose option [0-8]: " install_choice
    
    case $install_choice in
        1)
            print_info "Downloading ($latest_version) for $os/$arch_name..."
            
            if ! curl -fsSL "$download_url" -o "/tmp/paqet.tar.gz" 2>/dev/null; then
                print_error "Download failed from GitHub"
                echo -e "\n${YELLOW}Please check:${NC}"
                echo -e " 1. Internet connection"
                echo -e " 2. GitHub repository access / release exists"
                echo -e " 3. Or use option ${ORANGE}8${NC} to build Core v3 from source"
                echo -e "\n${YELLOW}You can also:${NC}"
                echo -e " - Download manually from: $download_url"
                echo -e " - Save to: /root/paqet/$expected_file"
                echo -e " - Then use option 2 to install from local file"
                pause
                return 1
            else
                print_success "Downloaded version ${latest_version}"
                cp "/tmp/paqet.tar.gz" "/root/paqet/$expected_file" 2>/dev/null && \
                print_info "Saved copy to /root/paqet/$expected_file for future use"
            fi
            ;;
        2)
            local local_files=()
            if [ -d "/root/paqet" ]; then
                while IFS= read -r file; do
                    if [[ "$file" =~ paqet-linux-.*\.tar\.gz$ ]]; then
                        local_files+=("$file")
                    fi
                done < <(find "/root/paqet" -name "*.tar.gz" -type f 2>/dev/null | sort)
            fi
            
            if [ ${#local_files[@]} -eq 0 ]; then
                print_error "No valid paqet archives found in /root/paqet"
                echo -e "\n${YELLOW}Expected filename format:${NC} paqet-linux-{arch}-{version}.tar.gz"
                echo -e "${YELLOW}Example:${NC} paqet-linux-amd64-v1.0.0-alpha.16.tar.gz"
                pause
                return 1
            fi
            
            echo -e "\n${YELLOW}Found local paqet archives:${NC}\n"
            
            for i in "${!local_files[@]}"; do
                local filename
                filename=$(basename "${local_files[$i]}")
                local filesize
                filesize=$(du -h "${local_files[$i]}" | cut -f1)
                local file_arch=""
                if [[ "$filename" =~ linux-([^-]+)- ]]; then
                    file_arch="${BASH_REMATCH[1]}"
                fi
                
                if [ "$file_arch" = "$arch_name" ]; then
                    echo -e " $((i+1)). ${GREEN}$filename${NC} (${filesize}) - ${GREEN}✓ Compatible${NC}"
                else
                    echo -e " $((i+1)). ${YELLOW}$filename${NC} (${filesize}) - ${YELLOW}⚠️ Not compatible (need: $arch_name)${NC}"
                fi
            done
            
            echo ""
            read -p "Select file [1-${#local_files[@]}]: " file_choice
            
            if [[ "$file_choice" -ge 1 ]] && [[ "$file_choice" -le ${#local_files[@]} ]]; then
                local selected_file="${local_files[$((file_choice-1))]}"
                local selected_filename=$(basename "$selected_file")
                if [[ "$selected_filename" =~ linux-([^-]+)- ]]; then
                    local file_arch="${BASH_REMATCH[1]}"
                    if [ "$file_arch" != "$arch_name" ]; then
                        print_warning "This file is for architecture '$file_arch', but your system is '$arch_name'"
                        read -p "Continue anyway? (y/N): " force_install
                        if [[ ! "$force_install" =~ ^[Yy]$ ]]; then
                            continue
                        fi
                    fi
                fi
                
                print_success "Using: $selected_filename"
                cp "$selected_file" "/tmp/paqet.tar.gz"
            else
                print_error "Invalid selection"
                pause
                return 1
            fi
            ;;
        3)
            echo ""
            echo -en "${YELLOW}Enter custom URL: ${NC}"
            read -r custom_url
            
            if [ -z "$custom_url" ]; then
                print_error "URL cannot be empty"
                pause
                return 1
            fi
            
            print_info "Downloading from custom URL..."
            if ! curl -fsSL "$custom_url" -o "/tmp/paqet.tar.gz" 2>/dev/null; then
                print_error "Download failed"
                echo -e "\n${YELLOW}Please check:${NC}"
                echo -e " 1. URL is correct"
                echo -e " 2. Internet connection"
                pause
                return 1
            else
                print_success "Downloaded from custom URL"
            fi
            ;;
        8)
            build_wildpaqet_core_from_source "$arch_name"
            return $?
            ;;
        4)
            install_manager_script
            return 0
            ;;
        5)
            update_manager_script
            return 0
            ;;
        6)
            switch_manager_version
            return 0
            ;;
        7)
            uninstall_manager_script
            return 0
            ;;
        0)
            return 0
            ;;
        *)
            print_error "Invalid choice"
            pause
            return 1
            ;;
    esac

    mkdir -p "$INSTALL_DIR"
    print_step "Extracting archive..."

    # Extract to a temp dir first so a bad archive cannot wipe a working install
    local extract_tmp
    extract_tmp=$(mktemp -d /tmp/paqet-extract.XXXXXX 2>/dev/null || mktemp -d)
    if ! tar -xzf "/tmp/paqet.tar.gz" -C "$extract_tmp" 2>/dev/null; then
        print_error "Failed to extract archive"
        echo -e "\n${YELLOW}Possible issues:${NC}"
        echo -e " 1. Corrupted download"
        echo -e " 2. Wrong file format"
        echo -e " 3. Incompatible archive"
        rm -rf "$extract_tmp"
        rm -f "/tmp/paqet.tar.gz"
        pause
        return 1
    fi

    local binary_file=""
    # Support both naming styles: paqet_linux_amd64 and paqet-linux-amd64
    for candidate in \
        "$extract_tmp/paqet_linux_${arch_name}" \
        "$extract_tmp/paqet-linux-${arch_name}" \
        "$extract_tmp/paqet" \
        "$extract_tmp/paqet_linux_arm64" \
        "$extract_tmp/paqet-linux-arm64"; do
        if [ -f "$candidate" ]; then
            binary_file="$candidate"
            break
        fi
    done

    if [ -z "$binary_file" ] || [ ! -f "$binary_file" ]; then
        binary_file=$(find "$extract_tmp" -type f \( -name "*paqet*" -o -name "paqet" \) 2>/dev/null | while read -r f; do
            if file "$f" 2>/dev/null | grep -qiE 'executable|ELF'; then
                echo "$f"
                break
            fi
        done)
    fi

    if [ -z "$binary_file" ] || [ ! -f "$binary_file" ]; then
        while IFS= read -r -d '' file; do
            if [ -x "$file" ] || file "$file" 2>/dev/null | grep -qiE 'executable|ELF'; then
                binary_file="$file"
                break
            fi
        done < <(find "$extract_tmp" -type f -print0 2>/dev/null)
    fi

    if [ -z "$binary_file" ] || [ ! -f "$binary_file" ]; then
        print_error "Binary not found in archive"
        echo -e "\n${YELLOW}Archive contents:${NC}"
        ls -la "$extract_tmp"
        rm -rf "$extract_tmp"
        rm -f "/tmp/paqet.tar.gz"
        pause
        return 1
    fi

    # Promote extracted files only after binary is found
    rm -rf "$INSTALL_DIR"/*
    cp -a "$extract_tmp"/. "$INSTALL_DIR"/
    rm -rf "$extract_tmp"

    print_success "Archive extracted to $INSTALL_DIR"
    # Prefer promoted path under INSTALL_DIR
    if [ -f "$INSTALL_DIR/$(basename "$binary_file")" ]; then
        binary_file="$INSTALL_DIR/$(basename "$binary_file")"
    else
        binary_file=$(find "$INSTALL_DIR" -type f -name "$(basename "$binary_file")" 2>/dev/null | head -1)
    fi

    if [ -n "$binary_file" ] && [ -f "$binary_file" ]; then
        print_info "Found binary: $(basename "$binary_file")"
        local previous_binary=""
        if [ -f "$BIN_DIR/paqet" ]; then
            previous_binary="${BIN_DIR}/paqet.bak-$(date +%Y%m%d-%H%M%S)"
            cp "$BIN_DIR/paqet" "$previous_binary" 2>/dev/null || true
        fi
        if ! atomic_install_binary "$binary_file" "$BIN_DIR/paqet"; then
            print_error "Failed to install binary to $BIN_DIR/paqet (is a paqet process wedged?)"
            print_info "Stop the services (menu → service management) and re-run the install."
            rm -f "/tmp/paqet.tar.gz"
            pause
            return 1
        fi
        
        print_success "Paqet installed to $BIN_DIR/paqet"
        
        local new_version
        new_version=$("$BIN_DIR/paqet" version 2>/dev/null | grep "^Version:" | head -1 | cut -d':' -f2 | xargs)
        if [ -n "$new_version" ]; then
            print_info "Installed version: ${CYAN}$new_version${NC}"
            
            if [ -n "$latest_version" ] && [ "$new_version" != "$latest_version" ]; then
                print_warning "Expected version $latest_version but got $new_version"
            fi
        else
            print_warning "Could not determine installed version (binary may still work)"
            if [ -n "$previous_binary" ] && [ -f "$previous_binary" ]; then
                print_info "Previous binary backup kept at: $previous_binary"
            fi
        fi
    else
        print_error "Binary not found after install promotion"
        rm -f "/tmp/paqet.tar.gz"
        pause
        return 1
    fi
    
    # پاک کردن فایل موقت
    rm -f "/tmp/paqet.tar.gz"
    
    print_success "Paqet core installation completed!"
    pause
    return 0
}

# Install manager script
install_manager_script() {
    clear
    show_banner
    print_step "Installing WildPaqet Manager script...\n"
    
    local manager_url
    manager_url="$(manager_script_url)"
    
    print_info "Downloading from: $manager_url"
    
    if curl -fsSL "$manager_url" -o "$MANAGER_PATH" 2>/dev/null; then
        sed -i 's/\r$//' "$MANAGER_PATH" 2>/dev/null || true
        chmod +x "$MANAGER_PATH"
        # Remove legacy command name if present
        rm -f "/usr/local/bin/paqet-manager" 2>/dev/null || true
        ln -sf "$MANAGER_PATH" /usr/bin/wildpaqet 2>/dev/null || true
        hash -r 2>/dev/null || true
        print_success "✅ WildPaqet Manager installed to $MANAGER_PATH"
        echo -e "\n${GREEN}You can now run the manager with:${NC}"
        echo -e " ${CYAN}wildpaqet${NC}"
        if ! command -v wildpaqet >/dev/null 2>&1; then
            echo -e "\n${YELLOW}If command not found:${NC}"
            echo -e " ${CYAN}export PATH=\"/usr/local/bin:\$PATH\" && hash -r${NC}"
            echo -e " or run: ${CYAN}$MANAGER_PATH${NC}"
        fi
    else
        print_error "Failed to download manager script"
        pause
        return 1
    fi
    
    pause
    return 0
}

# Update manager script
update_manager_script() {
    clear
    show_banner
    print_step "Updating WildPaqet Manager script...\n"
    
    if [ ! -f "$MANAGER_PATH" ]; then
        print_warning "Manager script not found at $MANAGER_PATH"
        read -p "Install it now? (y/N): " install_now
        if [[ "$install_now" =~ ^[Yy]$ ]]; then
            install_manager_script
        fi
        return
    fi
    
    mkdir -p "$BACKUP_DIR"
    local backup_path="${BACKUP_DIR}/wildpaqet.backup-$(date +%Y%m%d-%H%M%S)"
    cp "$MANAGER_PATH" "$backup_path"
    print_info "Backup created at $backup_path"
    
    local manager_url
    manager_url="$(manager_script_url)"
    
    print_info "Downloading latest version..."
    
    if curl -fsSL "$manager_url" -o "$MANAGER_PATH" 2>/dev/null; then
        sed -i 's/\r$//' "$MANAGER_PATH" 2>/dev/null || true
        chmod +x "$MANAGER_PATH"
        rm -f "/usr/local/bin/paqet-manager" 2>/dev/null || true
        ln -sf "$MANAGER_PATH" /usr/bin/wildpaqet 2>/dev/null || true
        hash -r 2>/dev/null || true
        print_success "✅ WildPaqet Manager updated successfully!"
        echo -e "\n${GREEN}Manager updated to latest version${NC}"
        echo -e "${GREEN}Run with:${NC} ${CYAN}wildpaqet${NC}"
        echo -e "${YELLOW}Backup saved at:${NC} $backup_path"
        
        local new_version
        new_version=$(grep "SCRIPT_VERSION=" "$MANAGER_PATH" | head -1 | cut -d'"' -f2)
        [ -n "$new_version" ] && echo -e "${CYAN}New version:${NC} $new_version"
    else
        print_error "Failed to download manager script"
        mv "$backup_path" "$MANAGER_PATH" 2>/dev/null
        pause
        return 1
    fi
    
    pause
    return 0
}

# Switch manager version
switch_manager_version() {
    clear
    show_banner
    print_step "Switch WildPaqet Manager Version\n"
    
    echo -e "${YELLOW}Available versions:${NC}"
    echo -e "────────────────────────────────────────────────────────────────"
    
    local sorted_versions=()
    while IFS= read -r line; do
        sorted_versions+=("$line")
    done < <(for v in "${!MANAGER_VERSIONS[@]}"; do echo "$v"; done | sort -rV)
    
    local i=1
    declare -A version_map
    
    local current_version=""
    [ -f "$MANAGER_PATH" ] && current_version=$(grep "SCRIPT_VERSION=" "$MANAGER_PATH" 2>/dev/null | head -1 | cut -d'"' -f2)
    
    for version in "${sorted_versions[@]}"; do
        if [ "$version" = "$current_version" ]; then
            printf " %2d. ${CYAN}%s${NC} ${GREEN}(current)${NC}\n" "$i" "$version"
        else
            printf " %2d. ${CYAN}%s${NC}\n" "$i" "$version"
        fi
        version_map[$i]="$version"
        ((i++))
    done
    
    echo -e "\n 0) ${YELLOW}↩️ Back${NC}\n"
    
    read -p "Select version [0-$((i-1))]: " version_choice
    
    [ "$version_choice" = "0" ] && return 0
    
    if ! [[ "$version_choice" =~ ^[0-9]+$ ]] || (( version_choice < 1 || version_choice >= i )); then
        print_error "Invalid selection"
        pause
        return 1
    fi
    
    local selected_version="${version_map[$version_choice]}"
    local selected_url="${MANAGER_VERSIONS[$selected_version]}"
    
    print_info "Switching to version $selected_version..."
    
    if [ -f "$MANAGER_PATH" ]; then
        mkdir -p "$BACKUP_DIR"
        local backup_path="${BACKUP_DIR}/wildpaqet.backup-$(date +%Y%m%d-%H%M%S)"
        cp "$MANAGER_PATH" "$backup_path"
        print_info "Backup created at $backup_path"
    fi
    
    if curl -fsSL "$selected_url" -o "$MANAGER_PATH" 2>/dev/null; then
        chmod +x "$MANAGER_PATH"
        rm -f "/usr/local/bin/paqet-manager" 2>/dev/null || true
        print_success "✅ Switched to version $selected_version"
        echo -e "\n${GREEN}Manager version changed successfully!${NC}"
        echo -e "${GREEN}Run with:${NC} ${CYAN}wildpaqet${NC}"
        echo -e "${YELLOW}Backup saved at:${NC} $backup_path"
    else
        print_error "Failed to download version $selected_version"
        pause
        return 1
    fi
    
    pause
    return 0
}

# Uninstall manager script
uninstall_manager_script() {
    clear
    show_banner
    print_step "Uninstall WildPaqet Manager\n"
    
    if [ ! -f "$MANAGER_PATH" ]; then
        print_info "Manager script not found at $MANAGER_PATH"
        pause
        return 0
    fi
    
    echo -e "${RED}WARNING: This will remove the WildPaqet command (${MANAGER_NAME}).${NC}"
    echo -e "${YELLOW}The manager script will be deleted from:${NC} $MANAGER_PATH\n"
    
    read -p "Are you sure you want to uninstall? (y/N): " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Uninstall cancelled"
        pause
        return 0
    fi
    
    mkdir -p "$BACKUP_DIR"
    local backup_path="${BACKUP_DIR}/wildpaqet.backup-$(date +%Y%m%d-%H%M%S)"
    cp "$MANAGER_PATH" "$backup_path"
    print_info "Backup created at $backup_path"
    
    rm -f "$MANAGER_PATH"
    
    if [ ! -f "$MANAGER_PATH" ]; then
        print_success "✅ WildPaqet Manager uninstalled successfully"
        echo -e "\n${YELLOW}Backup saved at:${NC} $backup_path"
        echo -e "${YELLOW}To restore, run:${NC} cp $backup_path $MANAGER_PATH"
    else
        print_error "Failed to uninstall"
    fi
    
    pause
    return 0
}

# ================================================
# SAFE/AUTO NETWORK OPTIMIZER
# ================================================
# Designed for WildPaqet raw-packet tunnels:
# - Never apply fq (per-flow 100p limit collapses KCP inject)
# - Preserve mq root on multi-queue NICs; only retarget fq leaves
# - Snapshot before mutate; rollback restores exact prior state
# - Conservative buffers; no remote curl|bash BBR installers

# --- OPTIMIZER_TEST_EXPORT_BEGIN ---
optimizer_owned_sysctl_keys() {
    cat <<'EOF'
net.core.rmem_max
net.core.wmem_max
net.core.netdev_max_backlog
net.core.somaxconn
net.core.optmem_max
net.core.default_qdisc
net.ipv4.tcp_rmem
net.ipv4.tcp_wmem
net.ipv4.tcp_congestion_control
net.ipv4.tcp_slow_start_after_idle
net.ipv4.tcp_mtu_probing
net.ipv4.ip_local_port_range
fs.file-max
EOF
}

optimizer_ram_mb() {
    local kb
    kb=$(awk '/MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)
    echo $((kb / 1024))
}

# Pure helper (also used by tests): print safe profile as "key = value"
optimizer_build_safe_profile() {
    local ram_mb="${1:-0}"
    local rmem_max=16777216
    local wmem_max=16777216
    local backlog=5000
    local somax=4096
    local tcp_rmem_max=16777216
    local tcp_wmem_max=16777216
    local file_max=1048576

    if [ "$ram_mb" -ge 8192 ] 2>/dev/null; then
        rmem_max=33554432
        wmem_max=33554432
        backlog=10000
        somax=8192
        tcp_rmem_max=33554432
        tcp_wmem_max=33554432
        file_max=2097152
    elif [ "$ram_mb" -ge 4096 ] 2>/dev/null; then
        rmem_max=25165824
        wmem_max=25165824
        backlog=8000
        somax=6144
        tcp_rmem_max=25165824
        tcp_wmem_max=25165824
    elif [ "$ram_mb" -gt 0 ] && [ "$ram_mb" -lt 2048 ] 2>/dev/null; then
        rmem_max=8388608
        wmem_max=8388608
        backlog=2500
        somax=2048
        tcp_rmem_max=8388608
        tcp_wmem_max=8388608
        file_max=524288
    fi

    cat <<EOF
# WildPaqet Safe/Auto network profile (${NETOPT_MARKER})
# Paqet uses raw-packet inject; never set default_qdisc=fq on tunnel hosts.
net.core.rmem_max = ${rmem_max}
net.core.wmem_max = ${wmem_max}
net.core.netdev_max_backlog = ${backlog}
net.core.somaxconn = ${somax}
net.core.optmem_max = 65536
net.core.default_qdisc = fq_codel
net.ipv4.tcp_rmem = 4096 131072 ${tcp_rmem_max}
net.ipv4.tcp_wmem = 4096 16384 ${tcp_wmem_max}
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.ip_local_port_range = 10000 65535
fs.file-max = ${file_max}
EOF
}

optimizer_iface_is_virtual() {
    local iface="$1"
    case "$iface" in
        lo|docker*|br-*|veth*|virbr*|tun*|tap*|wg*|flannel*|cni*|tailscale*|zt*|vmnet*) return 0 ;;
    esac
    [ -d "/sys/class/net/$iface/device" ] || return 0
    return 1
}
# --- OPTIMIZER_TEST_EXPORT_END ---

# Default-route interfaces only (IPv4 then IPv6), skip virtuals.
optimizer_detect_target_ifaces() {
    local seen="" iface
    while IFS= read -r iface; do
        [ -n "$iface" ] || continue
        optimizer_iface_is_virtual "$iface" && continue
        case " $seen " in
            *" $iface "*) continue ;;
        esac
        seen="$seen $iface"
        printf '%s\n' "$iface"
    done < <(
        ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
        ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
    )
}

optimizer_try_install_tools() {
    local os
    os=$(detect_os 2>/dev/null || echo unknown)
    case "$os" in
        ubuntu|debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq >/dev/null 2>&1 || true
            apt-get install -y -qq iproute2 procps kmod >/dev/null 2>&1 || true
            ;;
        centos|rhel|rocky|almalinux|fedora|oracle)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y iproute procps-ng kmod >/dev/null 2>&1 || true
            else
                yum install -y iproute procps-ng kmod >/dev/null 2>&1 || true
            fi
            ;;
    esac
}

optimizer_preflight() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This must be run as root"
        return 1
    fi
    local miss=()
    command -v ip >/dev/null 2>&1 || miss+=("ip")
    command -v tc >/dev/null 2>&1 || miss+=("tc")
    command -v sysctl >/dev/null 2>&1 || miss+=("sysctl")
    if [ ${#miss[@]} -gt 0 ]; then
        print_step "Installing network tools (${miss[*]})..."
        optimizer_try_install_tools
        miss=()
        command -v ip >/dev/null 2>&1 || miss+=("ip")
        command -v tc >/dev/null 2>&1 || miss+=("tc")
        command -v sysctl >/dev/null 2>&1 || miss+=("sysctl")
    fi
    if [ ${#miss[@]} -gt 0 ]; then
        print_error "Missing tools: ${miss[*]}"
        print_info "Install iproute2 / procps first (menu 1 Dependencies)"
        return 1
    fi
    return 0
}

optimizer_ensure_bbr_module() {
    if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        return 0
    fi
    modprobe tcp_bbr 2>/dev/null || true
    sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr
}

optimizer_latest_snapshot() {
    local d
    d=$(ls -1dt "$NETOPT_STATE_DIR"/snap-* 2>/dev/null | head -1)
    [ -n "$d" ] && [ -d "$d" ] && echo "$d"
}

optimizer_oldest_snapshot() {
    local d
    d=$(ls -1dt "$NETOPT_STATE_DIR"/snap-* 2>/dev/null | tail -1)
    [ -n "$d" ] && [ -d "$d" ] && echo "$d"
}

optimizer_snapshot() {
    local stamp snap
    stamp=$(date +%Y%m%d-%H%M%S)
    snap="${NETOPT_STATE_DIR}/snap-${stamp}"
    mkdir -p "$snap/qdisc" "$snap/sysctl_values"

    local key
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        sysctl -n "$key" 2>/dev/null > "$snap/sysctl_values/$key" || true
    done < <(optimizer_owned_sysctl_keys)

    [ -f "$SYSCTL_FILE" ] && cp -a "$SYSCTL_FILE" "$snap/sysctl.dropin" || true
    [ -f "$LIMITS_FILE" ] && cp -a "$LIMITS_FILE" "$snap/limits.dropin" || true

    local iface
    while IFS= read -r iface; do
        [ -n "$iface" ] || continue
        tc qdisc show dev "$iface" 2>/dev/null > "$snap/qdisc/${iface}.txt" || true
    done < <(optimizer_detect_target_ifaces)

    echo "$stamp" > "$snap/meta.stamp"
    echo "safe-auto" > "$snap/meta.profile"
    hostname > "$snap/meta.host" 2>/dev/null || true
    echo "$snap"
}

# mq-safe fq remediation. Never replace mq root with a single fq_codel.
optimizer_fix_fq_on_iface() {
    local iface="$1"
    local force="${2:-0}"
    command -v tc >/dev/null 2>&1 || return 1
    ip link show "$iface" >/dev/null 2>&1 || return 1

    local root_kind
    root_kind=$(tc qdisc show dev "$iface" 2>/dev/null | awk '/^qdisc / && $0 !~ /parent/ {print $2; exit}')
    [ -n "$root_kind" ] || return 0

    case "$root_kind" in
        mq)
            local line parent
            while IFS= read -r line; do
                [[ "$line" =~ ^qdisc\ fq\  ]] || continue
                parent=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="parent"){print $(i+1); exit}}')
                [ -n "$parent" ] || continue
                if tc qdisc replace dev "$iface" parent "$parent" fq_codel 2>/dev/null; then
                    print_success "qdisc leaf on $iface ($parent): fq -> fq_codel"
                else
                    print_warning "Could not retarget fq leaf on $iface ($parent)"
                    return 1
                fi
            done < <(tc qdisc show dev "$iface" 2>/dev/null)
            ;;
        fq)
            if tc qdisc replace dev "$iface" root fq_codel 2>/dev/null; then
                print_success "qdisc on $iface: fq -> fq_codel"
            else
                print_warning "Could not change root qdisc on $iface"
                return 1
            fi
            ;;
        htb|hfsc|cake|prio|tbf|clsact)
            if [ "$force" = "1" ]; then
                print_warning "Forced skip of classful/custom root qdisc ($root_kind) on $iface"
            else
                print_info "Leaving custom root qdisc ($root_kind) on $iface untouched"
            fi
            ;;
        *)
            # pfifo_fast / fq_codel / noqueue / etc. — OK
            :
            ;;
    esac
    return 0
}

optimizer_apply_qdisc_targets() {
    local iface rc=0
    while IFS= read -r iface; do
        [ -n "$iface" ] || continue
        optimizer_fix_fq_on_iface "$iface" 0 || rc=1
    done < <(optimizer_detect_target_ifaces)
    return $rc
}

optimizer_write_qdisc_helper_script() {
    mkdir -p "$(dirname "$NETOPT_QDISC_SCRIPT")"
    cat > "$NETOPT_QDISC_SCRIPT" <<'EOF'
#!/bin/bash
# wildpaqet-managed: re-apply Safe qdisc after boot (default_qdisc alone is not enough)
set -euo pipefail
is_virtual() {
  case "$1" in
    lo|docker*|br-*|veth*|virbr*|tun*|tap*|wg*|flannel*|cni*|tailscale*|zt*|vmnet*) return 0 ;;
  esac
  [ -d "/sys/class/net/$1/device" ] || return 0
  return 1
}
targets() {
  local seen="" iface
  while IFS= read -r iface; do
    [ -n "$iface" ] || continue
    is_virtual "$iface" && continue
    case " $seen " in *" $iface "*) continue ;; esac
    seen="$seen $iface"
    printf '%s\n' "$iface"
  done < <(
    ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
    ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
  )
}
fix_iface() {
  local iface="$1" root parent line
  root=$(tc qdisc show dev "$iface" 2>/dev/null | awk '/^qdisc / && $0 !~ /parent/ {print $2; exit}')
  case "$root" in
    mq)
      while IFS= read -r line; do
        [[ "$line" =~ ^qdisc\ fq\  ]] || continue
        parent=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="parent"){print $(i+1); exit}}')
        [ -n "$parent" ] || continue
        tc qdisc replace dev "$iface" parent "$parent" fq_codel 2>/dev/null || true
      done < <(tc qdisc show dev "$iface" 2>/dev/null)
      ;;
    fq)
      tc qdisc replace dev "$iface" root fq_codel 2>/dev/null || true
      ;;
  esac
}
modprobe sch_fq_codel 2>/dev/null || true
sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1 || true
while IFS= read -r iface; do
  [ -n "$iface" ] || continue
  fix_iface "$iface"
done < <(targets)
exit 0
EOF
    chmod 0755 "$NETOPT_QDISC_SCRIPT"
}

optimizer_install_qdisc_persistence() {
    optimizer_write_qdisc_helper_script
    cat > "/etc/systemd/system/${NETOPT_QDISC_UNIT}" <<EOF
[Unit]
Description=WildPaqet Safe qdisc (fq_codel, mq-preserving)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${NETOPT_QDISC_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now "$NETOPT_QDISC_UNIT" >/dev/null 2>&1 || \
        systemctl enable "$NETOPT_QDISC_UNIT" >/dev/null 2>&1 || true
}

optimizer_remove_qdisc_persistence() {
    systemctl disable --now "$NETOPT_QDISC_UNIT" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${NETOPT_QDISC_UNIT}" 2>/dev/null || true
    rm -f "$NETOPT_QDISC_SCRIPT" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
}

optimizer_apply_sysctl_file() {
    local file="$1"
    local key val line failed=0
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        key=$(echo "$line" | awk -F= '{print $1}' | xargs)
        val=$(echo "$line" | awk -F= '{sub(/^[^=]*=[[:space:]]*/,""); print}' | xargs)
        [ -n "$key" ] || continue
        if ! sysctl -w "$key=$val" >/dev/null 2>&1; then
            print_warning "sysctl failed: $key=$val"
            failed=1
        else
            print_info "sysctl ok: $key"
        fi
    done < "$file"
    return $failed
}

optimizer_write_limits_file() {
    cat > "$LIMITS_FILE" <<EOF
# WildPaqet Safe/Auto limits (${NETOPT_MARKER})
# Note: systemd units use LimitNOFILE; PAM limits apply to login sessions only.
*               soft    nofile          1048576
*               hard    nofile          1048576
root            soft    nofile          1048576
root            hard    nofile          1048576
EOF
}

optimizer_iface_has_fq() {
    local iface="$1"
    tc qdisc show dev "$iface" 2>/dev/null | grep -qE '^qdisc fq [0-9]'
}

optimizer_verify() {
    local ok=1 iface
    if [ ! -f "$SYSCTL_FILE" ]; then
        print_warning "Drop-in missing: $SYSCTL_FILE"
        ok=0
    fi
    local dq
    dq=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "")
    if [ "$dq" != "fq_codel" ]; then
        print_warning "Runtime default_qdisc is '$dq' (want fq_codel)"
        ok=0
    fi
    while IFS= read -r iface; do
        [ -n "$iface" ] || continue
        if optimizer_iface_has_fq "$iface"; then
            print_warning "Live fq still present on $iface"
            ok=0
        fi
        local root
        root=$(tc qdisc show dev "$iface" 2>/dev/null | awk '/^qdisc / && $0 !~ /parent/ {print $2; exit}')
        if [ "$root" = "mq" ]; then
            print_info "Preserved mq root on $iface"
        fi
    done < <(optimizer_detect_target_ifaces)
    [ "$ok" -eq 1 ]
}

optimizer_restore_qdisc_snapshot() {
    local snap="$1"
    command -v tc >/dev/null 2>&1 || return 0

    local qfile iface root_kind line parent
    for qfile in "$snap"/qdisc/*.txt; do
        [ -f "$qfile" ] || continue
        iface=$(basename "$qfile" .txt)
        ip link show "$iface" >/dev/null 2>&1 || continue
        root_kind=$(awk '/^qdisc / && $0 !~ /parent/ {print $2; exit}' "$qfile")
        case "$root_kind" in
            fq)
                tc qdisc replace dev "$iface" root fq >/dev/null 2>&1 || true
                ;;
            mq)
                while IFS= read -r line; do
                    [[ "$line" =~ ^qdisc\ fq\  ]] || continue
                    parent=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="parent"){print $(i+1); exit}}')
                    [ -n "$parent" ] || continue
                    tc qdisc replace dev "$iface" parent "$parent" fq >/dev/null 2>&1 || true
                done < "$qfile"
                ;;
        esac
    done
}

# Restore the selected snapshot. Menu rollback uses the newest snapshot; full
# uninstall selects the oldest one so repeated optimizer runs return to the
# true pre-WildPaqet baseline.
optimizer_restore_snapshot() {
    local snap="${1:-}"
    if [ -z "$snap" ]; then
        snap=$(optimizer_latest_snapshot)
    fi
    if [ -z "$snap" ] || [ ! -d "$snap" ]; then
        return 1
    fi

    print_step "Restoring snapshot: $(basename "$snap")"

    if [ -f "$snap/sysctl.dropin" ]; then
        cp -a "$snap/sysctl.dropin" "$SYSCTL_FILE"
    else
        rm -f "$SYSCTL_FILE"
    fi
    if [ -f "$snap/limits.dropin" ]; then
        cp -a "$snap/limits.dropin" "$LIMITS_FILE"
    else
        rm -f "$LIMITS_FILE"
    fi

    # Reload restored distro/user drop-ins first, then reapply captured runtime
    # values so sysctl --system cannot overwrite the snapshot.
    sysctl --system >/dev/null 2>&1 || true

    local keyfile key val
    for keyfile in "$snap"/sysctl_values/*; do
        [ -f "$keyfile" ] || continue
        key=$(basename "$keyfile")
        val=$(cat "$keyfile" 2>/dev/null || true)
        [ -n "$val" ] || continue
        sysctl -w "$key=$val" >/dev/null 2>&1 || true
    done

    optimizer_restore_qdisc_snapshot "$snap"
    print_success "Snapshot restored"
    return 0
}

optimizer_rollback_or_reset() {
    if optimizer_restore_snapshot; then
        return 0
    fi
    print_info "No snapshot found; removing owned drop-ins only"
    rm -f "$SYSCTL_FILE" "$LIMITS_FILE"
    optimizer_remove_qdisc_persistence
    sysctl --system >/dev/null 2>&1 || true
    # Keep fq_codel as safe runtime default for tunnel hosts if possible
    sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1 || \
        sysctl -w net.core.default_qdisc=pfifo_fast >/dev/null 2>&1 || true
    optimizer_apply_qdisc_targets || true
    return 0
}

apply_kernel_optimizations() {
    clear
    show_banner
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║ Safe/Auto Network Optimizer                              ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}\n"

    print_info "Profile: Safe/Auto for WildPaqet raw-packet + co-located TCP"
    print_info "Never applies fq; preserves mq; snapshots before change"
    echo ""

    if ! optimizer_preflight; then
        pause
        return 1
    fi

    local targets
    targets=$(optimizer_detect_target_ifaces | tr '\n' ' ')
    print_info "Target interfaces: ${targets:-none}"
    echo ""
    read -p "Apply Safe/Auto optimizations now? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Cancelled"
        pause
        return 0
    fi

    mkdir -p "$NETOPT_STATE_DIR" "$BACKUP_DIR"
    modprobe sch_fq_codel 2>/dev/null || true

    local snap
    snap=$(optimizer_snapshot) || true
    [ -n "$snap" ] && print_success "Snapshot: $snap"

    local ram_mb tmp_sysctl
    ram_mb=$(optimizer_ram_mb)
    print_info "Detected RAM: ${ram_mb} MiB"
    tmp_sysctl=$(mktemp)
    optimizer_build_safe_profile "$ram_mb" > "$tmp_sysctl"

    if ! optimizer_ensure_bbr_module; then
        print_warning "BBR not available; keeping cubic in profile"
        sed -i 's/tcp_congestion_control = bbr/tcp_congestion_control = cubic/' "$tmp_sysctl"
    fi

    print_step "Writing drop-in $SYSCTL_FILE"
    install -m 0644 "$tmp_sysctl" "$SYSCTL_FILE"
    rm -f "$tmp_sysctl"

    print_step "Applying sysctl keys..."
    optimizer_apply_sysctl_file "$SYSCTL_FILE" || print_warning "Some sysctl keys failed (see above)"

    print_step "Writing session limits (PAM)..."
    optimizer_write_limits_file
    print_success "Wrote $LIMITS_FILE"

    print_step "Remediating live fq on default-route interfaces..."
    optimizer_apply_qdisc_targets || print_warning "Some qdisc changes failed"

    print_step "Installing boot persistence for qdisc..."
    optimizer_install_qdisc_persistence
    print_success "Enabled $NETOPT_QDISC_UNIT"

    echo ""
    if optimizer_verify; then
        echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN} Safe/Auto optimizer applied and verified${NC}"
        echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    else
        print_error "Verification failed — rolling back"
        optimizer_restore_snapshot "$snap" || optimizer_rollback_or_reset
        pause
        return 1
    fi

    echo -e "\n${YELLOW}Runtime:${NC}"
    echo -e "  • Congestion: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo N/A)"
    echo -e "  • default_qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo N/A)"
    echo -e "  • rmem_max: $(sysctl -n net.core.rmem_max 2>/dev/null || echo N/A)"
    local iface
    while IFS= read -r iface; do
        [ -n "$iface" ] || continue
        echo -e "  • $iface: $(tc qdisc show dev "$iface" 2>/dev/null | head -n 1)"
    done < <(optimizer_detect_target_ifaces)
    [ -n "$snap" ] && echo -e "\n${CYAN}Rollback snapshot:${NC} $snap"
    pause
    return 0
}

remove_kernel_optimizations() {
    clear
    show_banner
    echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║ Rollback Network Optimizer                               ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}\n"

    local snap
    snap=$(optimizer_latest_snapshot)
    if [ -n "$snap" ]; then
        echo -e "${YELLOW}Will restore snapshot:${NC} $snap"
    else
        echo -e "${YELLOW}No snapshot found — will only remove WildPaqet-owned drop-ins.${NC}"
    fi
    echo ""
    read -p "Continue? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Cancelled"
        pause
        return 0
    fi

    optimizer_rollback_or_reset
    print_success "Optimizer rolled back / reset"
    pause
}

optimizer_reset_owned_settings() {
    clear
    show_banner
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║ Reset Owned Settings Only                                ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}\n"
    print_warning "Removes $SYSCTL_FILE / $LIMITS_FILE / qdisc oneshot without restoring a snapshot."
    echo ""
    read -p "Continue? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Cancelled"
        pause
        return 0
    fi
    rm -f "$SYSCTL_FILE" "$LIMITS_FILE"
    optimizer_remove_qdisc_persistence
    sysctl --system >/dev/null 2>&1 || true
    sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1 || true
    optimizer_apply_qdisc_targets || true
    print_success "Owned settings removed"
    pause
}

view_kernel_status() {
    clear
    show_banner
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║ Network Optimizer Status                                 ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}\n"

    echo -e "${YELLOW}Profile / files:${NC}"
    if [ -f "$SYSCTL_FILE" ]; then
        echo -e "  • ${GREEN}✓${NC} $SYSCTL_FILE ($(date -r "$SYSCTL_FILE" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown))"
        grep -q "$NETOPT_MARKER" "$SYSCTL_FILE" 2>/dev/null && echo -e "    └─ marker: ${NETOPT_MARKER}"
    else
        echo -e "  • ${RED}✗${NC} $SYSCTL_FILE (absent)"
    fi
    if [ -f "$LIMITS_FILE" ]; then
        echo -e "  • ${GREEN}✓${NC} $LIMITS_FILE"
    else
        echo -e "  • ${RED}✗${NC} $LIMITS_FILE (absent)"
    fi

    local snap
    snap=$(optimizer_latest_snapshot)
    echo -e "\n${YELLOW}Snapshot:${NC} ${snap:-none}"

    echo -e "\n${YELLOW}Runtime sysctl:${NC}"
    echo -e "  • congestion: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo N/A)"
    echo -e "  • available: $(sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | cut -d= -f2 | xargs || echo N/A)"
    echo -e "  • default_qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo N/A)"
    echo -e "  • rmem_max / wmem_max: $(sysctl -n net.core.rmem_max 2>/dev/null) / $(sysctl -n net.core.wmem_max 2>/dev/null)"
    echo -e "  • backlog / somaxconn: $(sysctl -n net.core.netdev_max_backlog 2>/dev/null) / $(sysctl -n net.core.somaxconn 2>/dev/null)"
    echo -e "  • port range: $(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null || echo N/A)"

    echo -e "\n${YELLOW}Default-route interfaces / live qdisc:${NC}"
    local iface found_fq=0
    while IFS= read -r iface; do
        [ -n "$iface" ] || continue
        echo -e "  • ${CYAN}$iface${NC}"
        tc qdisc show dev "$iface" 2>/dev/null | sed 's/^/      /' | head -n 6
        if optimizer_iface_has_fq "$iface"; then
            found_fq=1
            echo -e "      ${RED}WARNING: fq present — harmful for WildPaqet raw tunnels${NC}"
        fi
    done < <(optimizer_detect_target_ifaces)

    if [ "$found_fq" -eq 1 ]; then
        echo -e "\n${RED}Action:${NC} run Safe/Auto Apply to migrate fq -> fq_codel"
    fi

    echo -e "\n${YELLOW}Persistence:${NC}"
    if systemctl is-enabled "$NETOPT_QDISC_UNIT" >/dev/null 2>&1; then
        echo -e "  • ${GREEN}✓${NC} $NETOPT_QDISC_UNIT enabled"
    else
        echo -e "  • ${YELLOW}○${NC} $NETOPT_QDISC_UNIT not enabled"
    fi

    echo -e "\n${YELLOW}Paqet service LimitNOFILE (sample):${NC}"
    local svc
    svc=$(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '/^paqet-.*\.service/{print $1; exit}')
    if [ -n "$svc" ]; then
        systemctl show "$svc" -p LimitNOFILE --value 2>/dev/null | awk '{print "  • '$svc': "$0}'
    else
        echo -e "  • no paqet-*.service found"
    fi

    echo -e "\n${CYAN}Note:${NC} BBR paces kernel TCP (e.g. Xray), not paqet raw inject."
    echo -e "The critical WildPaqet knob is egress qdisc != fq."
    pause
}

# Compatibility wrappers kept for any external callers
apply_qdisc_to_live_ifaces() {
    optimizer_apply_qdisc_targets
}

# ================================================
# OPTIMIZATION MENU (DNS / Mirror helpers retained)
# ================================================

# Install DNS Finder
install_dns_finder() {
    clear
    show_banner
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║ Install DNS Finder                                       ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}\n"
    
    echo -e "${YELLOW}This tool finds the best DNS servers for Iran by testing latency.${NC}"
    echo -e "${YELLOW}It will help improve your internet speed and connectivity.${NC}\n"
    
    read -p "Do you want to find the best DNS servers? (y/N): " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}DNS Finder installation cancelled.${NC}"
        pause
        return
    fi
    
    print_step "Downloading and running DNS Finder..."
    
    if bash <(curl -Ls https://github.com/alinezamifar/IranDNSFinder/raw/refs/heads/main/dns.sh); then
        print_success "✅ DNS Finder completed successfully!"
        echo -e "\n${YELLOW}The tool has tested various DNS servers and shown the best options.${NC}"
    else
        print_error "Failed to run DNS Finder"
        echo -e "\n${YELLOW}You can run DNS Finder manually with:${NC}"
        echo -e "${CYAN}bash <(curl -Ls https://github.com/alinezamifar/IranDNSFinder/raw/refs/heads/main/dns.sh)${NC}"
    fi
    
    pause
    return
}

# Install Mirror Selector
install_mirror_selector() {
    clear
    show_banner
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║ Install Mirror Selector                                  ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}\n"
    
    local os
    os=$(detect_os)
    if [[ "$os" != "ubuntu" ]] && [[ "$os" != "debian" ]]; then
        print_error "This tool is only for Ubuntu/Debian based systems"
        echo -e "${YELLOW}Your OS is: $os${NC}"
        pause
        return
    fi
    
    echo -e "${YELLOW}This tool finds the fastest apt repository mirror for your location.${NC}"
    echo -e "${YELLOW}It will significantly improve package download speeds.${NC}\n"
    
    read -p "Do you want to find the fastest apt mirror? (y/N): " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Mirror Selector installation cancelled.${NC}"
        pause
        return
    fi
    
    print_step "Downloading and running Mirror Selector..."
    
    if bash <(curl -Ls https://github.com/alinezamifar/DetectUbuntuMirror/raw/refs/heads/main/DUM.sh); then
        print_success "✅ Mirror Selector completed successfully!"
        echo -e "\n${YELLOW}The tool has tested various mirrors and selected the fastest one.${NC}"
    else
        print_error "Failed to run Mirror Selector"
        echo -e "\n${YELLOW}You can run Mirror Selector manually with:${NC}"
        echo -e "${CYAN}bash <(curl -Ls https://github.com/alinezamifar/DetectUbuntuMirror/raw/refs/heads/main/DUM.sh)${NC}"
    fi
    
    pause
    return
}

# Optimization menu
optimize_server() {
    while true; do
        clear
        show_banner
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║ Server Optimization Tools                                ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}\n"
        
        echo -e "${CYAN}1.${NC} ${GREEN}Safe/Auto Network Optimizer${NC} - fq_codel + BBR + safe buffers (recommended)"
        echo -e "${CYAN}2.${NC} ${CYAN}Diagnose / Status${NC} - desired vs runtime, live qdisc, fq warnings"
        echo -e "${CYAN}3.${NC} ${YELLOW}Rollback to snapshot${NC} - restore pre-apply network state"
        echo -e "${CYAN}4.${NC} ${ORANGE}Reset owned settings${NC} - remove WildPaqet drop-ins only"
        echo -e "${CYAN}5.${NC} ${PURPLE}DNS Finder${NC} - Find the best DNS servers for Iran"
        echo -e "${CYAN}6.${NC} ${ORANGE}Mirror Selector${NC} - Find the fastest apt repository mirror"
        echo -e "${CYAN}0.${NC} ↩️ Back to Main Menu"
        echo ""
        echo -e "${YELLOW}Note:${NC} Legacy remote BBR installers were removed — they reintroduced fq."
        echo ""
        
        read -p "Select option [0-6]: " choice
        
        case $choice in
            1) apply_kernel_optimizations ;;
            2) view_kernel_status ;;
            3) remove_kernel_optimizations ;;
            4) optimizer_reset_owned_settings ;;
            5) install_dns_finder ;;
            6) install_mirror_selector ;;
            0) return ;;
            *) print_error "Invalid option"; sleep 1 ;;
        esac
    done
}

# ================================================
# MANAGE ALL SERVICES
# ================================================
manage_all_services() {
    while true; do
        clear
        show_banner
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║                 Manage All Paqet Services                    ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}\n"
        
        local services=()
        mapfile -t services < <(systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null |
                              grep -E '^paqet-.*\.service' | awk '{print $1}' || true)
        
        if [[ ${#services[@]} -eq 0 ]]; then
            echo -e "${YELLOW}No Paqet services found.${NC}\n"
            pause
            return
        fi
        
        echo -e "${CYAN}Found ${#services[@]} Paqet service(s):${NC}\n"
        
        local i=1
        for svc in "${services[@]}"; do
            local service_name="${svc%.service}"
            local display_name="${service_name#paqet-}"
            local status
            status=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
            
            local status_color=""
            case "$status" in
                active) status_color="${GREEN}" ;;
                failed) status_color="${RED}" ;;
                inactive) status_color="${YELLOW}" ;;
                *) status_color="${WHITE}" ;;
            esac
            
            printf " %2d. ${CYAN}%-25s${NC} [${status_color}%s${NC}]\n" "$i" "$display_name" "$status"
            ((i++))
        done
        
        echo -e "\n${YELLOW}══════════════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}🔒 CONNECTION PROTECTION${NC}"
        echo -e "────────────────────────────────────────────────────────────────"
        echo -e " ${GREEN}[1]${NC} 🛡️ Apply Connection Protection (Anti-RST + NOTRACK | Recommended)"
        echo -e " ${GREEN}[2]${NC} ❌ Remove Protection Rules"
        
        echo -e "\n${YELLOW}══════════════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}🔄 NAT PORT FORWARDING${NC}"
        echo -e "────────────────────────────────────────────────────────────────"
        echo -e " ${GREEN}[3]${NC} 🌐 Multi-Port Forward (specific ports)"
        echo -e " ${GREEN}[4]${NC} 🌍 All-Ports Forward (except excluded)"
        echo -e " ${GREEN}[5]${NC} 📋 View NAT Rules"
        echo -e " ${GREEN}[6]${NC} 🗑️ Remove Forwarding by Destination IP"
        echo -e " ${GREEN}[7]${NC} 💣 Flush All NAT Rules"
        
        echo -e "\n${YELLOW}══════════════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}🚀 SERVICE CONTROL${NC}"
        echo -e "────────────────────────────────────────────────────────────────"
        echo -e " ${GREEN}[8]${NC} ▶️  Start All Services"
        echo -e " ${GREEN}[9]${NC} ⏹️  Stop All Services"
        echo -e " ${GREEN}[10]${NC} 🔄 Restart All Services"
        
        echo -e "\n${YELLOW}══════════════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}📊 MONITORING & DIAGNOSTICS${NC}"
        echo -e "────────────────────────────────────────────────────────────────"
        echo -e " ${GREEN}[11]${NC} 📋 Live Log Monitoring (All Services)"
        echo -e " ${GREEN}[12]${NC} 📊 Test MTU / Packet Loss"
        
        echo -e "\n${YELLOW}══════════════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}⚙️  BULK CONFIGURATION${NC}"
        echo -e "────────────────────────────────────────────────────────────────"
        echo -e " ${GREEN}[13]${NC} 🔧 Change Mode All Services"
        echo -e " ${GREEN}[14]${NC} 🔌 Change Connections All Services"
        echo -e " ${GREEN}[15]${NC} 📦 Change MTU All Services"
        echo -e " ${GREEN}[16]${NC} 🔒 Change Block All Services"
        
        echo -e "\n${YELLOW}══════════════════════════════════════════════════════════════${NC}"
        echo -e " ${GREEN}[17]${NC} 🗑️  Delete All Tunnels"
        echo -e " ${GREEN}[0]${NC} ↩️ Back to Main Menu"
        echo ""
        
        read -p "Choose option [0-17]: " mgmt_choice
        
        case $mgmt_choice in
            1) apply_connection_protection ;;
            2) remove_connection_protection ;;
            3) add_nat_forward_multi_port ;;
            4) add_nat_forward_all_ports ;;
            5) view_nat_rules ;;
            6) remove_nat_forward_by_dest ;;
            7) flush_nat_rules ;;
            8) start_all_services "${services[@]}" ;;
            9) stop_all_services "${services[@]}" ;;
            10) restart_all_services "${services[@]}" ;;
            11) live_log_all_services "${services[@]}" ;;
            12) test_mtu ;;
            13) change_mode_all_services ;;
            14) change_conn_all_services ;;
            15) set_global_mtu ;;
            16) change_block_all_services ;;
            17) delete_all_tunnels "${services[@]}" ;;
            0) return ;;
            *) print_error "Invalid choice"; sleep 1.5 ;;
        esac
    done
}

# ================================================
# BULK CONFIGURATION FUNCTIONS
# ================================================

start_all_services() {
    local services=("$@")
    echo -e "\n${YELLOW}Starting all Paqet services...${NC}"
    
    local success_count=0
    local fail_count=0
    
    for svc in "${services[@]}"; do
        local service_name="${svc%.service}"
        local display_name="${service_name#paqet-}"
        
        echo -n " Starting $display_name... "
        
        if systemctl start "$svc" >/dev/null 2>&1; then
            sleep 1
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                echo -e "${GREEN}✅ SUCCESS${NC}"
                ((success_count++))
            else
                echo -e "${RED}❌ FAILED (not running)${NC}"
                ((fail_count++))
            fi
        else
            echo -e "${RED}❌ FAILED${NC}"
            ((fail_count++))
        fi
    done
    
    echo -e "\n${CYAN}Results:${NC}"
    echo -e " ${GREEN}✅ Success:${NC} $success_count service(s)"
    echo -e " ${RED}❌ Failed:${NC} $fail_count service(s)"
    pause
}

stop_all_services() {
    local services=("$@")
    echo -e "\n${YELLOW}Stopping all Paqet services...${NC}"
    
    local success_count=0
    local fail_count=0
    
    for svc in "${services[@]}"; do
        local service_name="${svc%.service}"
        local display_name="${service_name#paqet-}"
        
        echo -n " Stopping $display_name... "
        
        if systemctl stop "$svc" >/dev/null 2>&1; then
            sleep 1
            if ! systemctl is-active --quiet "$svc" 2>/dev/null; then
                echo -e "${GREEN}✅ SUCCESS${NC}"
                ((success_count++))
            else
                echo -e "${RED}❌ FAILED (still running)${NC}"
                ((fail_count++))
            fi
        else
            echo -e "${RED}❌ FAILED${NC}"
            ((fail_count++))
        fi
    done
    
    echo -e "\n${CYAN}Results:${NC}"
    echo -e " ${GREEN}✅ Success:${NC} $success_count service(s)"
    echo -e " ${RED}❌ Failed:${NC} $fail_count service(s)"
    pause
}

change_mode_all_services() {
    clear
    echo -e "\n${YELLOW}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}Change KCP Mode for ALL Services${NC}"
    echo -e "${YELLOW}══════════════════════════════════════════════════════════════${NC}\n"
    echo -e "${CYAN}Available KCP Modes:${NC}"
    echo -e "────────────────────────────────────────────────────────────────"
    echo -e " ${GREEN}[1]${NC} normal  - Normal speed / Normal latency / Low usage"
    echo -e " ${GREEN}[2]${NC} fast    - Balanced speed / Low latency / Normal usage"
    echo -e " ${GREEN}[3]${NC} fast2   - High speed / Lower latency / Medium usage"
    echo -e " ${GREEN}[4]${NC} fast3   - Max speed / Very low latency / High CPU"
    echo -e " ${GREEN}[5]${NC} manual  - Advanced settings"
    echo ""
    
    read -p "Select new mode [1-5]: " mode_choice
    
    local new_mode=""
    case $mode_choice in
        1) new_mode="normal" ;;
        2) new_mode="fast" ;;
        3) new_mode="fast2" ;;
        4) new_mode="fast3" ;;
        5) 
            echo -e "\n${YELLOW}Manual mode requires individual configuration.${NC}"
            echo -e "${YELLOW}Please configure each service separately.${NC}"
            pause
            return
            ;;
        *) print_error "Invalid choice"; return ;;
    esac
    
    echo -e "\n${YELLOW}Applying mode '$new_mode' to all configurations...${NC}"
    
    local configs=()
    while IFS= read -r -d '' file; do
        configs+=("$file")
    done < <(find "$CONFIG_DIR" -name "*.yaml" -type f -print0 2>/dev/null)
    
    local modified=0
    for config in "${configs[@]}"; do
        local config_name=$(basename "$config" .yaml)
        
        if grep -qE '^[[:space:]]*mode:' "$config"; then
            sed -i -E "s/^([[:space:]]*)mode:.*/\\1mode: \"$new_mode\"/" "$config"
            echo -e " ${GREEN}✓${NC} Updated $config_name"
            ((modified++))
        else
            if grep -q "kcp:" "$config"; then
                sed -i "/kcp:/a \    mode: \"$new_mode\"" "$config"
                echo -e " ${GREEN}✓${NC} Added mode to $config_name"
                ((modified++))
            fi
        fi
    done
    
    echo -e "\n${GREEN}✅ Mode set to '$new_mode' on $modified configuration(s)${NC}"
    
    read -p "Restart all services to apply changes? (y/N): " restart_choice
    if [[ "$restart_choice" =~ ^[Yy]$ ]]; then
        local services=()
        mapfile -t services < <(systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null |
                              grep -E '^paqet-.*\.service' | awk '{print $1}' || true)
        restart_all_services "${services[@]}"
    fi
    
    pause
}

change_conn_all_services() {
    clear
    echo -e "\n${YELLOW}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}Change Connections Count for ALL Services${NC}"
    echo -e "${YELLOW}══════════════════════════════════════════════════════════════${NC}\n"
    
    echo -e "${CYAN}Current connections per service:${NC}"
    echo -e "────────────────────────────────────────────────────────────────"
    
    local configs=()
    while IFS= read -r -d '' file; do
        configs+=("$file")
        local config_name=$(basename "$file" .yaml)
        # Match indented conn under transport (not only ^conn:)
        local current_conn
        current_conn=$(grep -E '^[[:space:]]*conn:' "$file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')
        echo -e " ${config_name}: ${current_conn:-Not set (using default: $DEFAULT_CONNECTIONS)}"
    done < <(find "$CONFIG_DIR" -name "*.yaml" -type f -print0 2>/dev/null)
    
    echo -e "\n${CYAN}Enter new connections value [1-32]:${NC}"
    read -p "New connections count: " new_conn
    
    if ! [[ "$new_conn" =~ ^[1-9][0-9]?$ ]] || [ "$new_conn" -lt 1 ] || [ "$new_conn" -gt 32 ]; then
        print_error "Invalid value. Must be between 1 and 32"
        pause
        return
    fi
    
    echo -e "\n${YELLOW}Applying connections=$new_conn to all configurations...${NC}"
    
    local modified=0
    for config in "${configs[@]}"; do
        local config_name=$(basename "$config" .yaml)
        
        if grep -qE '^[[:space:]]*conn:' "$config"; then
            # Preserve indentation; update existing conn line only
            sed -i -E "s/^([[:space:]]*)conn:.*/\\1conn: $new_conn/" "$config"
            echo -e " ${GREEN}✓${NC} Updated $config_name"
            ((modified++))
        else
            # Add under transport section
            if grep -q "transport:" "$config"; then
                sed -i "/transport:/a \  conn: $new_conn" "$config"
                echo -e " ${GREEN}✓${NC} Added conn to $config_name"
                ((modified++))
            fi
        fi
    done
    
    echo -e "\n${GREEN}✅ Connections set to $new_conn on $modified configuration(s)${NC}"
    
    read -p "Restart all services to apply changes? (y/N): " restart_choice
    if [[ "$restart_choice" =~ ^[Yy]$ ]]; then
        local services=()
        mapfile -t services < <(systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null |
                              grep -E '^paqet-.*\.service' | awk '{print $1}' || true)
        restart_all_services "${services[@]}"
    fi
    
    pause
}

change_block_all_services() {
    clear
    echo -e "\n${YELLOW}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}Change Block/Encryption for ALL Services${NC}"
    echo -e "${YELLOW}══════════════════════════════════════════════════════════════${NC}\n"
    
    echo -e "${CYAN}Available Encryption Options:${NC}"
    echo -e "────────────────────────────────────────────────────────────────"
    echo -e " ${GREEN}[1]${NC} aes-128-gcm - Very high security / Very fast / Recommended"
    echo -e " ${GREEN}[2]${NC} aes         - High security / Medium speed / General use"
    echo -e " ${GREEN}[3]${NC} aes-128     - High security / Fast / Low CPU usage"
    echo -e " ${GREEN}[4]${NC} aes-192     - Very high security / Medium speed / Moderate CPU"
    echo -e " ${GREEN}[5]${NC} aes-256     - Maximum security / Slower / Higher CPU"
    echo -e " ${GREEN}[6]${NC} none        - No encryption / Max speed / Insecure"
    echo -e " ${GREEN}[7]${NC} null        - No encryption / Max speed / Insecure"
    echo ""
    
    read -p "Select encryption [1-7]: " enc_choice
    
    local new_block=""
    case $enc_choice in
        1) new_block="aes-128-gcm" ;;
        2) new_block="aes" ;;
        3) new_block="aes-128" ;;
        4) new_block="aes-192" ;;
        5) new_block="aes-256" ;;
        6) new_block="none" ;;
        7) new_block="null" ;;
        *) print_error "Invalid choice"; return ;;
    esac
    
    echo -e "\n${YELLOW}Applying block='$new_block' to all configurations...${NC}"
    
    local configs=()
    while IFS= read -r -d '' file; do
        configs+=("$file")
    done < <(find "$CONFIG_DIR" -name "*.yaml" -type f -print0 2>/dev/null)
    
    local modified=0
    for config in "${configs[@]}"; do
        local config_name=$(basename "$config" .yaml)
        
        if grep -qE '^[[:space:]]*block:' "$config"; then
            sed -i -E "s/^([[:space:]]*)block:.*/\\1block: \"$new_block\"/" "$config"
            echo -e " ${GREEN}✓${NC} Updated $config_name"
            ((modified++))
        else
            if grep -q "kcp:" "$config"; then
                sed -i "/kcp:/a \    block: \"$new_block\"" "$config"
                echo -e " ${GREEN}✓${NC} Added block to $config_name"
                ((modified++))
            fi
        fi
    done
    
    echo -e "\n${GREEN}✅ Block/Encryption set to '$new_block' on $modified configuration(s)${NC}"
    
    read -p "Restart all services to apply changes? (y/N): " restart_choice
    if [[ "$restart_choice" =~ ^[Yy]$ ]]; then
        local services=()
        mapfile -t services < <(systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null |
                              grep -E '^paqet-.*\.service' | awk '{print $1}' || true)
        restart_all_services "${services[@]}"
    fi
    
    pause
}

# ================================================
# CONNECTION PROTECTION FUNCTIONS
# ================================================
apply_connection_protection() {
    clear
    echo -e "\n${YELLOW}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}Apply Connection Protection (Anti-RST + NOTRACK)${NC}"
    echo -e "${YELLOW}══════════════════════════════════════════════════════════════${NC}\n"
    
    print_step "Scanning active Paqet configurations..."
    
    local configs=()
    while IFS= read -r -d '' file; do
        configs+=("$file")
    done < <(find "$CONFIG_DIR" -name "*.yaml" -type f -print0 2>/dev/null)
    
    if [[ ${#configs[@]} -eq 0 ]]; then
        print_warning "No Paqet configuration files found in $CONFIG_DIR"
        pause
        return 1
    fi
    
    echo -e "${CYAN}Found ${#configs[@]} configuration(s)${NC}\n"
    
    local server_protected=0
    local client_protected=0
    local rules_added=0
    local rules_skipped=0
    
    for config in "${configs[@]}"; do
        local config_name=$(basename "$config" .yaml)
        local role=$(grep "^role:" "$config" | awk '{print $2}' | tr -d '"' 2>/dev/null)
		local transport_protocol
		transport_protocol=$(config_transport_protocol "$config")
        
        echo -n "  Processing $config_name (${role:-unknown})... "

		if [ "$transport_protocol" = "tls" ]; then
			echo -e "${CYAN}skipped (normal kernel TCP; raw protection is unsafe)${NC}"
			continue
		fi
        
        if [[ "$role" != "server" && "$role" != "client" ]]; then
            echo -e "${YELLOW}skipped (unknown role)${NC}"
            continue
        fi
        
        if [ "$role" = "server" ]; then
            # Server: extract listen port
            local port=$(grep -A5 "listen:" "$config" | grep "addr:" | \
                         sed -n 's/.*:\([0-9]*\)".*/\1/p' | head -1 | tr -d ' ')
            
            if ! validate_port "$port"; then
                echo -e "${YELLOW}⚠ No valid port found${NC}"
                continue
            fi
            
            # Apply protection rules (check before add)
            local added=0
            
            iptables -t raw -C PREROUTING -p tcp --dport "$port" -m comment --comment "$FIREWALL_COMMENT" -j NOTRACK 2>/dev/null || \
            iptables -t raw -C PREROUTING -p tcp --dport "$port" -j NOTRACK 2>/dev/null || {
                iptables -t raw -A PREROUTING -p tcp --dport "$port" -m comment --comment "$FIREWALL_COMMENT" -j NOTRACK
                ((added++))
            }
            iptables -t raw -C OUTPUT -p tcp --sport "$port" -m comment --comment "$FIREWALL_COMMENT" -j NOTRACK 2>/dev/null || \
            iptables -t raw -C OUTPUT -p tcp --sport "$port" -j NOTRACK 2>/dev/null || {
                iptables -t raw -A OUTPUT -p tcp --sport "$port" -m comment --comment "$FIREWALL_COMMENT" -j NOTRACK
                ((added++))
            }
            iptables -t mangle -C OUTPUT -p tcp --sport "$port" --tcp-flags RST RST -m comment --comment "$FIREWALL_COMMENT" -j DROP 2>/dev/null || \
            iptables -t mangle -C OUTPUT -p tcp --sport "$port" --tcp-flags RST RST -j DROP 2>/dev/null || {
                iptables -t mangle -A OUTPUT -p tcp --sport "$port" --tcp-flags RST RST -m comment --comment "$FIREWALL_COMMENT" -j DROP
                ((added++))
            }
            iptables -t mangle -C PREROUTING -p tcp --dport "$port" --tcp-flags RST RST -m comment --comment "$FIREWALL_COMMENT" -j DROP 2>/dev/null || \
            iptables -t mangle -C PREROUTING -p tcp --dport "$port" --tcp-flags RST RST -j DROP 2>/dev/null || {
                iptables -t mangle -A PREROUTING -p tcp --dport "$port" --tcp-flags RST RST -m comment --comment "$FIREWALL_COMMENT" -j DROP
                ((added++))
            }
            
            if [ $added -gt 0 ]; then
                echo -e "${GREEN}✓ Protected (port $port, $added new rules)${NC}"
                ((rules_added += added))
                ((server_protected++))
            else
                echo -e "${CYAN}already protected${NC}"
                ((rules_skipped++))
            fi
            
        elif [ "$role" = "client" ]; then
            # Client: protect the primary server.addr AND every server.addrs[]
            # failover peer, so switching to a backup does not lose protection.
            local peers=()
            local addr sip sport
            while IFS= read -r addr; do
                [ -z "$addr" ] && continue
                sip="${addr%:*}"
                sport="${addr##*:}"
                validate_ip "$sip" 2>/dev/null && validate_port "$sport" 2>/dev/null && peers+=("$sip:$sport")
            done < <(extract_client_server_addrs "$config")

            if [ ${#peers[@]} -eq 0 ]; then
                echo -e "${YELLOW}⚠ Invalid or missing server address${NC}"
                continue
            fi

            local added=0
            local peer
            for peer in "${peers[@]}"; do
                sip="${peer%:*}"
                sport="${peer##*:}"
                iptables -t raw -C OUTPUT -p tcp -d "$sip" --dport "$sport" -m comment --comment "$FIREWALL_COMMENT" -j NOTRACK 2>/dev/null || \
                iptables -t raw -C OUTPUT -p tcp -d "$sip" --dport "$sport" -j NOTRACK 2>/dev/null || {
                    iptables -t raw -A OUTPUT -p tcp -d "$sip" --dport "$sport" -m comment --comment "$FIREWALL_COMMENT" -j NOTRACK; ((added++)); }
                iptables -t raw -C PREROUTING -p tcp -s "$sip" --sport "$sport" -m comment --comment "$FIREWALL_COMMENT" -j NOTRACK 2>/dev/null || \
                iptables -t raw -C PREROUTING -p tcp -s "$sip" --sport "$sport" -j NOTRACK 2>/dev/null || {
                    iptables -t raw -A PREROUTING -p tcp -s "$sip" --sport "$sport" -m comment --comment "$FIREWALL_COMMENT" -j NOTRACK; ((added++)); }
                iptables -t mangle -C OUTPUT -p tcp -d "$sip" --dport "$sport" --tcp-flags RST RST -m comment --comment "$FIREWALL_COMMENT" -j DROP 2>/dev/null || \
                iptables -t mangle -C OUTPUT -p tcp -d "$sip" --dport "$sport" --tcp-flags RST RST -j DROP 2>/dev/null || {
                    iptables -t mangle -A OUTPUT -p tcp -d "$sip" --dport "$sport" --tcp-flags RST RST -m comment --comment "$FIREWALL_COMMENT" -j DROP; ((added++)); }
                iptables -t mangle -C PREROUTING -p tcp -s "$sip" --sport "$sport" --tcp-flags RST RST -m comment --comment "$FIREWALL_COMMENT" -j DROP 2>/dev/null || \
                iptables -t mangle -C PREROUTING -p tcp -s "$sip" --sport "$sport" --tcp-flags RST RST -j DROP 2>/dev/null || {
                    iptables -t mangle -A PREROUTING -p tcp -s "$sip" --sport "$sport" --tcp-flags RST RST -m comment --comment "$FIREWALL_COMMENT" -j DROP; ((added++)); }
            done

            if [ $added -gt 0 ]; then
                echo -e "${GREEN}✓ Protected (${#peers[@]} peer(s), $added new rules)${NC}"
                ((rules_added += added))
                ((client_protected++))
            else
                echo -e "${CYAN}already protected${NC}"
                ((rules_skipped++))
            fi
        fi
    done
    
    echo -e "\n${GREEN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Protection Summary:${NC}"
    echo -e " ${GREEN}✓${NC} Servers protected: $server_protected"
    echo -e " ${GREEN}✓${NC} Clients protected: $client_protected"
    echo -e " ${GREEN}✓${NC} New iptables rules added: $rules_added"
    echo -e " ${CYAN}i${NC} Rules already existed (skipped): $rules_skipped"
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    
    # Save rules persistently
    if command -v iptables-save &>/dev/null; then
        mkdir -p /etc/iptables 2>/dev/null
        iptables-save > /etc/iptables/rules.v4 2>/dev/null && \
            print_success "Iptables rules saved to /etc/iptables/rules.v4"
        
        # Try netfilter-persistent if installed
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save 2>/dev/null && \
                print_success "Rules saved via netfilter-persistent"
        fi
    else
        print_warning "iptables-save not found - rules not persisted after reboot"
    fi
    
    save_iptables

    echo ""
    read -p "Restart all Paqet services now? (y/N): " restart_choice
    if [[ "$restart_choice" =~ ^[Yy]$ ]]; then
        local services=()
        mapfile -t services < <(systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null |
                              grep -E '^paqet-.*\.service' | awk '{print $1}' || true)
        
        for svc in "${services[@]}"; do
            systemctl restart "$svc" 2>/dev/null && \
                echo -e "  Restarted: ${CYAN}${svc%.service}${NC}"
        done
        
        if [[ ${#services[@]} -gt 0 ]]; then
            print_success "All Paqet services restarted"
        else
            print_info "No Paqet services found to restart"
        fi
    fi
    
    pause
    return 0
}
remove_connection_protection() {
    clear
    echo -e "\n${YELLOW}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}Remove Connection Protection Rules${NC}"
    echo -e "${YELLOW}══════════════════════════════════════════════════════════════${NC}\n"
    
    print_warning "This will remove Paqet-related iptables protection rules (from configs)."
    echo -e "${CYAN}Note: This does NOT flush entire raw/mangle tables.${NC}"
    echo ""
    read -p "Are you sure? (y/N): " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Operation cancelled"
        pause
        return
    fi
    
    cleanup_paqet_iptables_from_configs
    save_iptables >/dev/null 2>&1 || true
    print_success "Paqet protection rules removed (best-effort)"
    
    pause
}

# ================================================
# MTU MANAGEMENT FUNCTIONS
# ================================================

set_global_mtu() {
    clear
    echo -e "\n${YELLOW}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}Set Global MTU for ALL Paqet Tunnels${NC}"
    echo -e "${YELLOW}══════════════════════════════════════════════════════════════${NC}\n"
    
    echo -e "${CYAN}MTU Recommendations:${NC}"
    echo -e " • 1500: Default Ethernet (may be detected/fragmented)"
    echo -e " • 1400: Good balance for most connections"
    echo -e " • 1350: Recommended for Iran (avoids fragmentation)"
    echo -e " • 1300: More stable in restricted networks"
    echo -e " • 1280: IPv6 minimum MTU (very stable)"
    echo -e " • 1200: Ultra stable for heavily filtered connections"
    echo ""
    
    local current_mtu=""
    local configs=()
    while IFS= read -r -d '' file; do
        configs+=("$file")
        # Try to get current MTU from first config
        if [ -z "$current_mtu" ]; then
            current_mtu=$(grep "mtu:" "$file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')
        fi
    done < <(find "$CONFIG_DIR" -name "*.yaml" -type f -print0 2>/dev/null)
    
    if [[ ${#configs[@]} -eq 0 ]]; then
        print_warning "No configuration files found in $CONFIG_DIR"
        pause
        return
    fi
    
    echo -e "${YELLOW}Current MTU:${NC} ${current_mtu:-Not set (using default)}"
    echo -e "${YELLOW}Total configs:${NC} ${#configs[@]}\n"
    
    local new_mtu=""
    while true; do
        read -p "Enter new MTU [1000-1500] (recommend 1280-1350): " input_mtu
        
        if [ -z "$input_mtu" ]; then
            print_error "MTU cannot be empty"
            continue
        fi
        
        if [[ "$input_mtu" =~ ^[0-9]+$ ]] && [ "$input_mtu" -ge 1000 ] && [ "$input_mtu" -le 1500 ]; then
            new_mtu="$input_mtu"
            break
        else
            print_error "Invalid MTU. Must be between 1000 and 1500"
        fi
    done
    
    echo -e "\n${YELLOW}Applying MTU $new_mtu to all configurations...${NC}"
    
    local modified=0
    for config in "${configs[@]}"; do
        local config_name=$(basename "$config" .yaml)
		if [ "$(config_transport_protocol "$config")" != "kcp" ]; then
			echo -e " ${CYAN}i${NC} Skipped $config_name (not KCP)"
			continue
		fi
        
        if grep -qE '^[[:space:]]*mtu:' "$config"; then
            # Update existing mtu (preserve indentation)
            sed -i -E "s/^([[:space:]]*)mtu:.*/\\1mtu: $new_mtu/" "$config"
            echo -e " ${GREEN}✓${NC} Updated $config_name"
        else
            # Add mtu under kcp section
            if grep -q "kcp:" "$config"; then
                # Find kcp section and add mtu after it with proper indentation
                sed -i "/kcp:/a\    mtu: $new_mtu" "$config"
                echo -e " ${GREEN}✓${NC} Added mtu to $config_name"
            fi
        fi
        ((modified++))
    done
    
    echo -e "\n${GREEN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✅ MTU set to $new_mtu on $modified configuration(s)${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}\n"
    
    echo -e "${YELLOW}Note: Changes are saved to config files but services are not restarted.${NC}"
    read -p "Restart all services now to apply changes? (y/N): " restart_choice
    
    if [[ "$restart_choice" =~ ^[Yy]$ ]]; then
        restart_all_services "${services[@]}"
    fi
    
    pause
}

test_mtu() {
    clear
    echo -e "\n${YELLOW}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}MTU / Packet Loss Test${NC}"
    echo -e "${YELLOW}══════════════════════════════════════════════════════════════${NC}\n"    
    echo -e "${CYAN}This test checks different MTU sizes against target servers.${NC}"
    echo -e "${CYAN}Smaller MTUs are more stable but slightly slower.${NC}\n"

    local client_configs=()
    local server_ips=()
    local server_names=()

    while IFS= read -r -d '' file; do
        if grep -q "role:.*client" "$file" 2>/dev/null; then
            client_configs+=("$file")
            local config_name=$(basename "$file" .yaml)
            local server_line=$(grep -A2 "server:" "$file" | grep "addr:" | head -1)
            local server=$(echo "$server_line" | awk '{print $2}' | tr -d '"')
            
            if [ -n "$server" ]; then
                local sip=$(echo "$server" | cut -d: -f1)
                if validate_ip "$sip"; then
                    server_ips+=("$sip")
                    server_names+=("$config_name → $sip")
                fi
            fi
        fi
    done < <(find "$CONFIG_DIR" -name "*.yaml" -type f -print0 2>/dev/null)

    echo -e "${YELLOW}Select test target:${NC}"
    echo -e "────────────────────────────────────────────────────────────────"
    
    local menu_options=()
    local i=1

    echo -e " ${GREEN}[$i]${NC} Manual IP entry"
    menu_options+=("manual")
    ((i++))
    
    if [ ${#server_names[@]} -gt 0 ]; then
        echo -e "\n${CYAN}Detected client configurations:${NC}"
        for idx in "${!server_names[@]}"; do
            echo -e " ${GREEN}[$i]${NC} ${server_names[$idx]}"
            menu_options+=("client_$idx")
            ((i++))
        done
    fi

    echo -e "\n ${GREEN}[0]${NC} ↩️ Back"
    echo ""
    
    local target_ip=""
    local choice
    read -p "Choose option [0-$((i-1))]: " choice
    
    [ "$choice" = "0" ] && return
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -ge "$i" ]; then
        print_error "Invalid choice"
        pause
        return
    fi
    
    local selected="${menu_options[$((choice-1))]}"
    
    case "$selected" in
        "manual")
            echo -en "\n${YELLOW}Enter target IP address: ${NC}"
            read -r manual_ip
            manual_ip=$(echo "$manual_ip" | tr -d ' ')
            if validate_ip "$manual_ip"; then
                target_ip="$manual_ip"
                run_mtu_test "$target_ip" "Manual target: $manual_ip"
            else
                print_error "Invalid IP address"
                pause
                return
            fi
            ;;
        *)
            # Client selection
            if [[ "$selected" =~ ^client_([0-9]+)$ ]]; then
                local client_idx="${BASH_REMATCH[1]}"
                target_ip="${server_ips[$client_idx]}"
                run_mtu_test "$target_ip" "${server_names[$client_idx]}"
            fi
            ;;
    esac
    pause
}

run_mtu_test() {
    local target_ip="$1"
    local target_name="$2"
    local silent_mode="${3:-normal}"

    if [[ "$target_ip" == *":"* ]]; then
        target_ip=$(echo "$target_ip" | cut -d: -f1)
    fi
    
    if [ "$silent_mode" = "normal" ]; then
        clear
        echo -e "\n${YELLOW}══════════════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}MTU Test for: $target_name${NC}"
        echo -e "${YELLOW}══════════════════════════════════════════════════════════════${NC}\n"
    fi
    
    local test_results=()
    local best_mtu=""
    local best_loss=100
    local best_ping=""
    
    echo -e "${CYAN}┌──────────┬──────────────┬─────────────┬──────────────┬─────────────────┐${NC}"
    echo -e "${CYAN}│ MTU Size │ Payload Size │ Packet Loss │   Ping (ms)  │     Status      │${NC}"
    echo -e "${CYAN}├──────────┼──────────────┼─────────────┼──────────────┼─────────────────┤${NC}"
    
    local test_sizes=(
        "1472:1500"
        "1400:1428"
        "1350:1378"
        "1300:1328"
        "1280:1308"
        "1200:1228"
        "1100:1128"
        "1000:1028"
    )
    
    for test in "${test_sizes[@]}"; do
        local payload="${test%%:*}"
        local mtu="${test##*:}"
        local ping_output
        ping_output=$(ping -c 5 -W 1 -M do -s "$payload" "$target_ip" 2>&1)
        local loss="100"
        local avg_ping="-"
        local status

        if echo "$ping_output" | grep -q "0% packet loss"; then
            loss="0"
            if echo "$ping_output" | grep -q "rtt"; then
                avg_ping=$(echo "$ping_output" | grep "rtt" | awk -F'/' '{print $5}' | cut -d'.' -f1)
                [ -z "$avg_ping" ] && avg_ping=$(echo "$ping_output" | grep "rtt" | sed -n 's/.*= \([0-9.]*\)\/[0-9.]*\/[0-9.]*\/[0-9.]* ms.*/\1/p' | cut -d'.' -f1)
            fi
            status="${GREEN}✓ PERFECT${NC}"

            if [ "$mtu" -gt "${best_mtu:-0}" ]; then
                best_mtu="$mtu"
                best_loss="$loss"
                best_ping="$avg_ping"
            fi
            
        elif echo "$ping_output" | grep -q "[0-9]\+% packet loss"; then
            loss=$(echo "$ping_output" | grep -o "[0-9]\+% packet loss" | grep -o "[0-9]\+")
            if echo "$ping_output" | grep -q "rtt"; then
                avg_ping=$(echo "$ping_output" | grep "rtt" | awk -F'/' '{print $5}' | cut -d'.' -f1)
            fi
            
            if [ "$loss" -le 10 ]; then
                status="${GREEN}✓ GOOD${NC}"
                if [ -z "$best_mtu" ] || [ "$loss" -lt "$best_loss" ]; then
                    best_mtu="$mtu"
                    best_loss="$loss"
                    best_ping="$avg_ping"
                fi
            elif [ "$loss" -le 30 ]; then
                status="${YELLOW}⚠ FAIR${NC}"
                if [ -z "$best_mtu" ] || [ "$loss" -lt "$best_loss" ]; then
                    best_mtu="$mtu"
                    best_loss="$loss"
                    best_ping="$avg_ping"
                fi
            else
                status="${RED}✗ POOR${NC}"
            fi
            
        elif echo "$ping_output" | grep -q "packets transmitted" && echo "$ping_output" | grep -q "received"; then
            local transmitted received
            transmitted=$(echo "$ping_output" | grep -o "[0-9]\+ packets transmitted" | grep -o "[0-9]\+")
            received=$(echo "$ping_output" | grep -o "[0-9]\+ packets received" | grep -o "[0-9]\+")
            
            if [ -n "$transmitted" ] && [ -n "$received" ] && [ "$transmitted" -gt 0 ] 2>/dev/null; then
                loss=$(( (transmitted - received) * 100 / transmitted ))
                
                if echo "$ping_output" | grep -q "rtt"; then
                    avg_ping=$(echo "$ping_output" | grep "rtt" | awk -F'/' '{print $5}' | cut -d'.' -f1)
                fi
                
                if [ "$loss" -eq 0 ]; then
                    status="${GREEN}✓ PERFECT${NC}"
                    if [ "$mtu" -gt "${best_mtu:-0}" ]; then
                        best_mtu="$mtu"
                        best_loss="$loss"
                        best_ping="$avg_ping"
                    fi
                elif [ "$loss" -le 10 ]; then
                    status="${GREEN}✓ GOOD${NC}"
                    if [ -z "$best_mtu" ] || [ "$loss" -lt "$best_loss" ]; then
                        best_mtu="$mtu"
                        best_loss="$loss"
                        best_ping="$avg_ping"
                    fi
                elif [ "$loss" -le 30 ]; then
                    status="${YELLOW}⚠ FAIR${NC}"
                    if [ -z "$best_mtu" ] || [ "$loss" -lt "$best_loss" ]; then
                        best_mtu="$mtu"
                        best_loss="$loss"
                        best_ping="$avg_ping"
                    fi
                else
                    status="${RED}✗ POOR${NC}"
                fi
            else
                status="${RED}✗ FAILED${NC}"
            fi
        else
            status="${RED}✗ FAILED${NC}"
        fi
        
        test_results+=("$mtu:$loss:$avg_ping")

        printf "│ %-8s │ %-12s │ " "$mtu" "$payload"
        printf "%-11s │ " "${loss}%"
        printf "%-12s │ " "$avg_ping"
        echo -e " $status      │"
    done
    
    echo -e "${CYAN}└──────────┴──────────────┴─────────────┴──────────────┴─────────────────┘${NC}\n"

    if [ -z "$best_mtu" ] || [ "$best_loss" -eq 100 ]; then
        local min_loss=100
        for result in "${test_results[@]}"; do
            local mtu=$(echo "$result" | cut -d: -f1)
            local loss=$(echo "$result" | cut -d: -f2)
            if [[ "$loss" =~ ^[0-9]+$ ]] && [ "$loss" -lt "$min_loss" ]; then
                min_loss="$loss"
                best_mtu="$mtu"
                best_loss="$loss"
            fi
        done
    fi
    
    if [ "$silent_mode" = "normal" ]; then
        echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}Recommendations for $target_name${NC}"
        echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}\n"
        
        if [ -n "$best_mtu" ] && [ "$best_loss" -lt 100 ]; then
            if [ "$best_loss" -eq 0 ]; then
                echo -e " ${GREEN}✓ Best MTU: $best_mtu (0% loss, ${best_ping:-?}ms)${NC}"
            else
                echo -e " ${YELLOW}⚠ Best MTU: $best_mtu (${best_loss}% loss, ${best_ping:-?}ms)${NC}"
            fi
            
            echo -e "\n${CYAN}Recommended MTU settings:${NC}"
            local recommended=""
            
            if [ "$best_mtu" -ge 1428 ]; then
                echo -e " • ${GREEN}Recommended: 1350${NC} (best balance)"
                recommended="1350"
            elif [ "$best_mtu" -ge 1378 ]; then
                echo -e " • ${GREEN}Recommended: 1350${NC} (stable)"
                recommended="1350"
            elif [ "$best_mtu" -ge 1308 ]; then
                echo -e " • ${GREEN}Recommended: 1300${NC} (very stable)"
                recommended="1300"
            elif [ "$best_mtu" -ge 1228 ]; then
                echo -e " • ${GREEN}Recommended: 1280${NC} (ultra stable)"
                recommended="1280"
            else
                echo -e " • ${GREEN}Recommended: 1200${NC} (maximum compatibility)"
                recommended="1200"
            fi
            
            echo ""
            read -p "Apply recommended MTU ($recommended) to this server's client config? (y/N): " apply_mtu
            
            if [[ "$apply_mtu" =~ ^[Yy]$ ]]; then
                local target_config=""
                while IFS= read -r -d '' file; do
                    if grep -q "$target_ip" "$file" 2>/dev/null; then
                        target_config="$file"
                        break
                    fi
                done < <(find "$CONFIG_DIR" -name "*.yaml" -type f -print0 2>/dev/null)
                
                if [ -n "$target_config" ]; then
                    local backup_file="${target_config}.backup-$(date +%Y%m%d-%H%M%S)"
                    cp "$target_config" "$backup_file"
                    print_info "Backup created: $(basename "$backup_file")"

                    if grep -q "mtu:" "$target_config"; then
                        sed -i -E "s/^([[:space:]]*)mtu:.*/\\1mtu: $recommended/" "$target_config"
                    else
                        if grep -q "kcp:" "$target_config"; then
                            sed -i "/kcp:/a\    mtu: $recommended" "$target_config"
                        else
                            sed -i "/transport:/a \  kcp:\n    mtu: $recommended" "$target_config"
                        fi
                    fi
                    print_success "MTU set to $recommended in $(basename "$target_config")"

                    local config_name=$(basename "$target_config" .yaml)
                    local service_name="paqet-${config_name}.service"
                    
                    if systemctl list-unit-files 2>/dev/null | grep -q "$service_name"; then
                        echo ""
                        read -p "Restart this service now? (y/N): " restart_svc
                        if [[ "$restart_svc" =~ ^[Yy]$ ]]; then
                            systemctl restart "$service_name"
                            if systemctl is-active --quiet "$service_name"; then
                                print_success "Service restarted successfully"
                            else
                                print_error "Service failed to restart"
                            fi
                        fi
                    fi
                else
                    print_warning "Could not find config file for this server"
                fi
            fi
        else
            echo -e " ${RED}✗ No successful MTU test${NC}"
            echo -e " • The target server may be unreachable or blocking ICMP"
            echo -e " • Recommended MTU: 1200 (safe default)"
        fi
    fi
    
    if [ "$silent_mode" = "silent" ]; then
        local summary="SUMMARY: $target_name → Best MTU: ${best_mtu:-None} (${best_loss:-100}% loss)"
        echo "$summary"
        echo "BEST_MTU:${best_mtu:-1200}"
    fi
}

# Helper function to restart all services
restart_all_services() {
    local services=("$@")
    echo -e "\n${YELLOW}Restarting all Paqet services...${NC}"
    
    local success_count=0
    local fail_count=0
    
    for svc in "${services[@]}"; do
        local service_name="${svc%.service}"
        local display_name="${service_name#paqet-}"
        
        echo -n " Restarting $display_name... "
        
        if systemctl restart "$svc" >/dev/null 2>&1; then
            sleep 1
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                echo -e "${GREEN}✅ SUCCESS${NC}"
                ((success_count++))
            else
                echo -e "${RED}❌ FAILED (not running)${NC}"
                ((fail_count++))
            fi
        else
            echo -e "${RED}❌ FAILED${NC}"
            ((fail_count++))
        fi
    done
    
    echo -e "\n${CYAN}Results:${NC}"
    echo -e " ${GREEN}✅ Success:${NC} $success_count service(s)"
    echo -e " ${RED}❌ Failed:${NC} $fail_count service(s)"
}

# Helper function for live logs
live_log_all_services() {
    local services=("$@")
    echo -e "\n${YELLOW}Live Log Monitoring - All Paqet Tunnels${NC}"
    echo -e "────────────────────────────────────────────────────────────────"
    echo -e "${CYAN}Showing logs from all paqet services (Ctrl+C to exit)${NC}\n"
    sleep 2
    
    local journal_args=""
    for svc in "${services[@]}"; do
        journal_args="$journal_args -u $svc"
    done
    
    journalctl $journal_args -f --output=short-iso
    echo -e "\n${YELLOW}Returned from log monitoring${NC}"
    pause
}

# Helper function to delete all tunnels
delete_all_tunnels() {
    local services=("$@")
    echo -e "\n${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                          WARNING!                            ║${NC}"
    echo -e "${RED}║    This will delete ALL Paqet tunnels and configurations!    ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}\n"
    
    echo -e "${YELLOW}Services to be deleted:${NC}"
    for svc in "${services[@]}"; do
        local service_name="${svc%.service}"
        local display_name="${service_name#paqet-}"
        echo -e " - ${CYAN}$display_name${NC}"
    done
    
    echo ""
    read -p "Are you ABSOLUTELY SURE? (type 'yes' to confirm): " confirm
    
    if [ "$confirm" != "yes" ]; then
        echo -e "${YELLOW}Operation cancelled.${NC}"
        pause
        return
    fi
    
    echo ""
    print_step "Stopping and removing all services..."
    
    local deleted_count=0
    local failed_count=0
    
    for svc in "${services[@]}"; do
        local service_name="${svc%.service}"
        local display_name="${service_name#paqet-}"
        echo -n " Removing $display_name... "

        if remove_service_artifacts "$svc" "$display_name"; then
            echo -e "${GREEN}✅ Removed${NC}"
            ((deleted_count++))
        else
            echo -e "${YELLOW}⚠️ Partially removed${NC}"
            ((failed_count++))
        fi
    done
    
    echo -e "\n${CYAN}Results:${NC}"
    echo -e " ${GREEN}✅ Deleted:${NC} $deleted_count service(s)"
    [ "$failed_count" -eq 0 ] \
        && print_success "All tunnels and their owned artifacts deleted successfully!" \
        || print_warning "$failed_count service(s) left one or more artifacts behind"
    pause
}

# ================================================
# NAT PORT FORWARDING FUNCTIONS
# ================================================

snapshot_ip_forwarding_dropin() {
    ensure_state_dir || return 1
    [ -e "$IP_FORWARD_BACKUP" ] || [ -e "$IP_FORWARD_ABSENT_MARKER" ] || {
        if [ -e "$IP_FORWARD_FILE" ]; then
            cp -a "$IP_FORWARD_FILE" "$IP_FORWARD_BACKUP" || return 1
        else
            touch "$IP_FORWARD_ABSENT_MARKER" || return 1
        fi
    }
}

write_managed_ip_forwarding_dropin() {
    local value="$1"
    [[ "$value" =~ ^[01]$ ]] || return 1
    snapshot_ip_forwarding_dropin || return 1
    {
        echo "# WildPaqet NAT helper ($NETOPT_MARKER)"
        echo "net.ipv4.ip_forward=$value"
    } > "$IP_FORWARD_FILE"
}

restore_ip_forwarding_dropin() {
    if [ -e "$IP_FORWARD_BACKUP" ]; then
        cp -a "$IP_FORWARD_BACKUP" "$IP_FORWARD_FILE" 2>/dev/null || return 1
    elif [ -e "$IP_FORWARD_ABSENT_MARKER" ]; then
        rm -f "$IP_FORWARD_FILE" 2>/dev/null || return 1
    elif [ -f "$IP_FORWARD_FILE" ]; then
        # Backward compatibility for versions that wrote an unmarked one-line
        # 30-ip_forward.conf. Never remove a file with any other content.
        local content
        content=$(tr -d '\r' < "$IP_FORWARD_FILE" 2>/dev/null)
        if grep -q "$NETOPT_MARKER" "$IP_FORWARD_FILE" 2>/dev/null \
            || [ "$content" = "net.ipv4.ip_forward=1" ] \
            || [ "$content" = "net.ipv4.ip_forward=0" ]; then
            rm -f "$IP_FORWARD_FILE" 2>/dev/null || return 1
        fi
    fi
    rm -f "$IP_FORWARD_BACKUP" "$IP_FORWARD_ABSENT_MARKER" 2>/dev/null || true
}

ensure_ip_forwarding() {
    local current=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
    if [ "$current" != "1" ]; then
        print_step "Enabling IP forwarding..."
        write_managed_ip_forwarding_dropin 1 || {
            print_error "Could not safely snapshot/write $IP_FORWARD_FILE"
            return 1
        }
        sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
        sysctl --system > /dev/null 2>&1
        print_success "IP forwarding enabled"
    fi
}

add_nat_forward_multi_port() {
    clear
    echo -e "\n${YELLOW}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}Multi-Port NAT Forward${NC}"
    echo -e "${YELLOW}══════════════════════════════════════════════════════════════${NC}\n"
    
    echo -e "${CYAN}Forward specific ports (TCP+UDP) to a destination server${NC}"
    echo ""
    
    local dest_ip
    while true; do
        echo -e "${YELLOW}Enter destination server IP (e.g. 1.2.3.4). Press Enter to cancel:${NC}"
        read -p "> " dest_ip
        [ -z "$dest_ip" ] && { print_info "Cancelled."; pause; return 0; }
        if validate_ip "$dest_ip"; then
            break
        fi
        print_error "Invalid IP address format. Try again or press Enter to cancel."
    done
    
    local ports
    while true; do
        echo -e "${YELLOW}Enter ports to forward (comma-separated, e.g. 443,8443,2053):${NC}"
        read -p "> " ports
        [ -z "$ports" ] && { print_error "Ports required"; continue; }
        ports=$(echo "$ports" | tr -d ' ')
        if [[ "$ports" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
            break
        fi
        print_error "Invalid port format. Use comma-separated numbers (e.g. 443,8443)."
    done
    
    ensure_ip_forwarding || { pause; return 1; }
    
    print_step "Adding NAT forwarding rules: ports $ports -> $dest_ip ..."
    
    # TCP
    iptables -t nat -A PREROUTING -p tcp --match multiport --dports $ports \
        -m comment --comment "$FIREWALL_COMMENT" -j DNAT --to-destination "$dest_ip"
    iptables -t nat -A POSTROUTING -p tcp --match multiport --dports $ports \
        -m comment --comment "$FIREWALL_COMMENT" -j MASQUERADE
    # UDP
    iptables -t nat -A PREROUTING -p udp --match multiport --dports $ports \
        -m comment --comment "$FIREWALL_COMMENT" -j DNAT --to-destination "$dest_ip"
    iptables -t nat -A POSTROUTING -p udp --match multiport --dports $ports \
        -m comment --comment "$FIREWALL_COMMENT" -j MASQUERADE
    
    save_iptables
    print_success "NAT forwarding added: ports $ports -> $dest_ip (TCP+UDP)"
    pause
}

add_nat_forward_all_ports() {
    clear
    echo -e "\n${YELLOW}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}All-Ports NAT Forward${NC}"
    echo -e "${YELLOW}══════════════════════════════════════════════════════════════${NC}\n"
    
    echo -e "${CYAN}Forward ALL ports to a destination, except specified exclusions${NC}"
    echo ""
    
    local relay_ip
    while true; do
        echo -e "${YELLOW}Enter THIS server's IP (relay IP). Press Enter to cancel:${NC}"
        read -p "> " relay_ip
        [ -z "$relay_ip" ] && { print_info "Cancelled."; pause; return 0; }
        if validate_ip "$relay_ip"; then
            break
        fi
        print_error "Invalid IP address format. Try again or press Enter to cancel."
    done
    
    local dest_ip
    while true; do
        echo -e "${YELLOW}Enter destination server IP. Press Enter to cancel:${NC}"
        read -p "> " dest_ip
        [ -z "$dest_ip" ] && { print_info "Cancelled."; pause; return 0; }
        if validate_ip "$dest_ip"; then
            break
        fi
        print_error "Invalid IP address format. Try again or press Enter to cancel."
    done
    
    local exclude_ports
    while true; do
        echo -e "${YELLOW}Enter ports to EXCLUDE (comma-separated, e.g. 22,80). Press Enter to cancel:${NC}"
        read -p "> " exclude_ports
        [ -z "$exclude_ports" ] && { print_info "Cancelled."; pause; return 0; }
        exclude_ports=$(echo "$exclude_ports" | tr -d ' ')
        if [[ "$exclude_ports" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
            break
        fi
        print_error "Invalid port format. Use comma-separated numbers (e.g. 22,80)."
    done
    
    # Warn about SSH
    if ! echo ",$exclude_ports," | grep -q ",22,"; then
        print_warning "⚠️  Port 22 (SSH) is NOT in your exclusion list!"
        echo -e "${RED}You may lose SSH access if port 22 is forwarded.${NC}"
        read -p "Continue without excluding port 22? (y/N): " skip_ssh_warn
        if [[ ! "$skip_ssh_warn" =~ ^[Yy]$ ]]; then
            print_info "Cancelled. Add port 22 to your exclusion list."
            pause
            return 1
        fi
    fi
    
    ensure_ip_forwarding || { pause; return 1; }
    
    print_step "Adding all-ports NAT forwarding to $dest_ip (excluding $exclude_ports)..."
    
    # First: redirect excluded ports back to this server (keeps them local)
    iptables -t nat -A PREROUTING -p tcp --match multiport --dports $exclude_ports \
        -m comment --comment "$FIREWALL_COMMENT" -j DNAT --to-destination "$relay_ip"
    iptables -t nat -A PREROUTING -p udp --match multiport --dports $exclude_ports \
        -m comment --comment "$FIREWALL_COMMENT" -j DNAT --to-destination "$relay_ip"
    # Then: catch-all forward everything else to destination
    iptables -t nat -A PREROUTING -p tcp -m comment --comment "$FIREWALL_COMMENT" \
        -j DNAT --to-destination "$dest_ip"
    iptables -t nat -A PREROUTING -p udp -m comment --comment "$FIREWALL_COMMENT" \
        -j DNAT --to-destination "$dest_ip"
    iptables -t nat -A POSTROUTING -m comment --comment "$FIREWALL_COMMENT" -j MASQUERADE
    
    save_iptables
    print_success "All-ports NAT forwarding added to $dest_ip (excluding $exclude_ports)"
    pause
}

view_nat_rules() {
    clear
    echo -e "\n${YELLOW}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}Current NAT Table Rules${NC}"
    echo -e "${YELLOW}══════════════════════════════════════════════════════════════${NC}\n"
    
    if iptables -t nat -L -v --line-numbers 2>/dev/null | grep -q "Chain"; then
        iptables -t nat -L -v --line-numbers 2>/dev/null || print_error "Failed to read NAT rules"
    else
        print_info "No NAT rules found"
    fi
    
    echo ""
    pause
}

remove_nat_forward_by_dest() {
    clear
    echo -e "\n${YELLOW}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}Remove NAT Forwarding Rules by Destination${NC}"
    echo -e "${YELLOW}══════════════════════════════════════════════════════════════${NC}\n"
    
    view_nat_rules
    echo ""
    
    echo -e "${YELLOW}Enter destination IP to remove rules for. Press Enter to cancel:${NC}"
    read -p "> " dest_ip
    if [ -z "$dest_ip" ]; then
        print_info "Cancelled."
        pause
        return 0
    fi
    
    if ! validate_ip "$dest_ip"; then
        print_error "Invalid IP address"
        pause
        return 1
    fi
    
    print_step "Removing NAT rules targeting $dest_ip..."
    
    local removed=0
    
    # Remove PREROUTING rules targeting this IP (reverse order to preserve line numbers)
    local pre_rules
    pre_rules=$(iptables -t nat -L PREROUTING --line-numbers -n 2>/dev/null | grep "to:${dest_ip}" | awk '{print $1}' | sort -rn)
    for num in $pre_rules; do
        iptables -t nat -D PREROUTING $num 2>/dev/null && ((removed++))
    done
    
    # Remove POSTROUTING rules that reference this IP (if any)
    local post_rules
    post_rules=$(iptables -t nat -L POSTROUTING --line-numbers -n 2>/dev/null | grep "to:${dest_ip}" | awk '{print $1}' | sort -rn)
    for num in $post_rules; do
        iptables -t nat -D POSTROUTING $num 2>/dev/null && ((removed++))
    done
    
    if [ $removed -gt 0 ]; then
        save_iptables
        print_success "Removed $removed NAT rule(s) targeting $dest_ip"
    else
        print_warning "No NAT rules found targeting $dest_ip"
    fi
    
    pause
}

flush_nat_rules() {
    clear
    echo -e "\n${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                     WARNING!                                  ║${NC}"
    echo -e "${RED}║         This will flush ALL iptables NAT rules!               ║${NC}"
    echo -e "${RED}║   Connection protection rules (raw/mangle) will NOT be affected${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}\n"
    
    read -p "Are you sure? (type 'yes' to confirm): " confirm
    if [ "$confirm" != "yes" ]; then
        print_info "Flush cancelled"
        pause
        return
    fi
    
    print_step "Flushing NAT table..."
    iptables -t nat -F
    iptables -t nat -X 2>/dev/null || true
    
    save_iptables
    print_success "All NAT rules flushed"
    
    echo ""
    read -p "Also disable IP forwarding? (y/N): " disable_fwd
    if [[ "$disable_fwd" =~ ^[Yy]$ ]]; then
        write_managed_ip_forwarding_dropin 0 || {
            print_error "Could not safely snapshot/write $IP_FORWARD_FILE"
            pause
            return 1
        }
        sysctl -w net.ipv4.ip_forward=0 > /dev/null 2>&1
        sysctl --system > /dev/null 2>&1
        print_success "IP forwarding disabled"
    fi
    
    pause
}

save_iptables() {
    if ! command -v iptables-save >/dev/null 2>&1; then
        print_warning "iptables-save not found - rules will NOT persist after reboot!"
        return 1
    fi

    mkdir -p /etc/iptables 2>/dev/null

    if iptables-save > /etc/iptables/rules.v4 2>/dev/null; then
        chmod 600 /etc/iptables/rules.v4 2>/dev/null
        print_success "iptables rules saved to /etc/iptables/rules.v4"
    else
        print_error "Failed to save iptables rules!"
        return 1
    fi

    # Try distribution-specific persistence tools
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 && \
            print_info "Rules also saved via netfilter-persistent"
    elif command -v service >/dev/null 2>&1 && systemctl is-active iptables >/dev/null 2>&1; then
        service iptables save >/dev/null 2>&1 && \
            print_info "Rules saved via iptables service"
    fi

    return 0
}

# ================================================
# UNINSTALL & UTILITY FUNCTIONS
# ================================================

# Remove every iptables rule created by current versions, even when its YAML
# was deleted manually. The comment is attached to raw/mangle/filter/NAT rules.
cleanup_tagged_iptables_rules() {
    command -v iptables >/dev/null 2>&1 || return 0
    local table chain number
    while read -r table chain; do
        while true; do
            number=$(iptables -t "$table" -L "$chain" --line-numbers -n 2>/dev/null \
                | awk -v marker="$FIREWALL_COMMENT" 'index($0, marker) {print $1; exit}')
            [[ "$number" =~ ^[0-9]+$ ]] || break
            iptables -t "$table" -D "$chain" "$number" 2>/dev/null || break
        done
    done <<'EOF'
raw PREROUTING
raw OUTPUT
mangle PREROUTING
mangle OUTPUT
filter INPUT
filter OUTPUT
nat PREROUTING
nat POSTROUTING
EOF
}

cleanup_managed_firewall_rules() {
    local backend protocol port firewalld_changed=0 failed=0
    local remaining_file="${FIREWALL_STATE_FILE}.remaining.$$"
    local firewalld_reload_file="${FIREWALL_STATE_FILE}.firewalld-reload.$$"
    rm -f "$remaining_file" "$firewalld_reload_file" 2>/dev/null || true
    if [ -f "$FIREWALL_STATE_FILE" ]; then
        while IFS='|' read -r backend protocol port; do
            if ! validate_port "$port" 2>/dev/null || [ "$protocol" != "tcp" ]; then
                printf '%s|%s|%s\n' "$backend" "$protocol" "$port" >> "$remaining_file"
                failed=1
                continue
            fi
            case "$backend" in
                ufw)
                    local ufw_added=""
                    if ! command -v ufw >/dev/null 2>&1 \
                        || ! ufw_added=$(ufw show added 2>/dev/null); then
                        printf '%s|%s|%s\n' "$backend" "$protocol" "$port" >> "$remaining_file"
                        failed=1
                    elif printf '%s\n' "$ufw_added" | grep -Eq "^ufw[[:space:]]+allow[[:space:]]+${port}/tcp([[:space:]]|$)" \
                        && ! ufw --force delete allow "$port/tcp" >/dev/null 2>&1; then
                        printf '%s|%s|%s\n' "$backend" "$protocol" "$port" >> "$remaining_file"
                        failed=1
                    fi
                    ;;
                firewalld)
                    if command -v firewall-cmd >/dev/null 2>&1 \
                        && firewall-cmd --state >/dev/null 2>&1; then
                        if firewall-cmd --permanent --query-port="$port/tcp" >/dev/null 2>&1; then
                            if firewall-cmd --permanent --remove-port="$port/tcp" >/dev/null 2>&1; then
                                firewalld_changed=1
                                printf '%s|%s|%s\n' "$backend" "$protocol" "$port" >> "$firewalld_reload_file"
                            else
                                printf '%s|%s|%s\n' "$backend" "$protocol" "$port" >> "$remaining_file"
                                failed=1
                            fi
                        fi
                    else
                        printf '%s|%s|%s\n' "$backend" "$protocol" "$port" >> "$remaining_file"
                        failed=1
                    fi
                    ;;
                *)
                    printf '%s|%s|%s\n' "$backend" "$protocol" "$port" >> "$remaining_file"
                    failed=1
                    ;;
            esac
        done < "$FIREWALL_STATE_FILE"
    fi
    if [ "$firewalld_changed" -ne 0 ]; then
        if firewall-cmd --reload >/dev/null 2>&1; then
            rm -f "$firewalld_reload_file" 2>/dev/null || true
        else
            cat "$firewalld_reload_file" >> "$remaining_file" 2>/dev/null || true
            failed=1
        fi
    fi
    cleanup_tagged_iptables_rules
    if [ -s "$remaining_file" ]; then
        mv -f "$remaining_file" "$FIREWALL_STATE_FILE" 2>/dev/null || true
        chmod 600 "$FIREWALL_STATE_FILE" 2>/dev/null || true
    else
        rm -f "$remaining_file" "$FIREWALL_STATE_FILE" 2>/dev/null || true
    fi
    rm -f "$firewalld_reload_file" 2>/dev/null || true
    return "$failed"
}

# Delete matching iptables rules repeatedly (duplicates possible)
_iptables_delete_loop() {
    local table="$1"
    shift
    local i
    for ((i=0; i<20; i++)); do
        iptables -t "$table" -D "$@" 2>/dev/null || return 0
    done
}

cleanup_tls_iptables_port() {
    local port="$1"
    validate_port "$port" 2>/dev/null || return 0
    _iptables_delete_loop filter INPUT -p tcp --dport "$port" -m conntrack --ctstate NEW,ESTABLISHED \
        -m comment --comment "$FIREWALL_COMMENT" -j ACCEPT
    # Legacy v3 releases created this same rule without an ownership comment.
    _iptables_delete_loop filter INPUT -p tcp --dport "$port" -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT
}

# Remove persistent UFW/firewalld openings that were recorded when one v3
# service was created. Untracked administrator rules are deliberately kept.
cleanup_managed_firewall_for_config() {
    local config="$1"
    [ -f "$config" ] || return 0
    [ -f "$FIREWALL_STATE_FILE" ] || return 0

    local role port backend protocol tracked_port matched failed=0 firewalld_changed=0
    local remaining_file="${FIREWALL_STATE_FILE}.service-remove.$$"
    local -a ports=()
    role=$(awk '$1 == "role:" {gsub(/"/, "", $2); print $2; exit}' "$config" 2>/dev/null)

    if [ "$role" = "server" ]; then
        port=$(awk '
            /^listen:/ {in_listen=1; next}
            in_listen && /^[^[:space:]]/ {exit}
            in_listen && $1 == "addr:" {
                value=$2; gsub(/"/, "", value); sub(/^.*:/, "", value); print value; exit
            }
        ' "$config" 2>/dev/null)
        validate_port "$port" 2>/dev/null && ports+=("$port")
    elif [ "$role" = "client" ]; then
        while IFS= read -r port; do
            validate_port "$port" 2>/dev/null && ports+=("$port")
        done < <(grep -E 'listen:[[:space:]]*"' "$config" 2>/dev/null \
            | grep -oE ':[0-9]+' | tr -d ':' | sort -u)
    fi

    [ ${#ports[@]} -gt 0 ] || return 0
    : > "$remaining_file" || return 1
    chmod 600 "$remaining_file" 2>/dev/null || true

    while IFS='|' read -r backend protocol tracked_port; do
        matched=0
        for port in "${ports[@]}"; do
            [ "$protocol" = "tcp" ] && [ "$tracked_port" = "$port" ] && matched=1
        done
        if [ "$matched" -eq 0 ]; then
            printf '%s|%s|%s\n' "$backend" "$protocol" "$tracked_port" >> "$remaining_file"
            continue
        fi

        case "$backend" in
            ufw)
                if ! command -v ufw >/dev/null 2>&1; then
                    printf '%s|%s|%s\n' "$backend" "$protocol" "$tracked_port" >> "$remaining_file"
                    failed=1
                elif ufw show added 2>/dev/null \
                    | grep -Eq "^ufw[[:space:]]+allow[[:space:]]+${tracked_port}/tcp([[:space:]]|$)" \
                    && ! ufw --force delete allow "$tracked_port/tcp" >/dev/null 2>&1; then
                    printf '%s|%s|%s\n' "$backend" "$protocol" "$tracked_port" >> "$remaining_file"
                    failed=1
                fi
                ;;
            firewalld)
                if ! command -v firewall-cmd >/dev/null 2>&1 \
                    || ! firewall-cmd --state >/dev/null 2>&1; then
                    printf '%s|%s|%s\n' "$backend" "$protocol" "$tracked_port" >> "$remaining_file"
                    failed=1
                elif firewall-cmd --permanent --query-port="$tracked_port/tcp" >/dev/null 2>&1; then
                    if firewall-cmd --permanent --remove-port="$tracked_port/tcp" >/dev/null 2>&1; then
                        firewalld_changed=1
                    else
                        printf '%s|%s|%s\n' "$backend" "$protocol" "$tracked_port" >> "$remaining_file"
                        failed=1
                    fi
                fi
                ;;
            *)
                printf '%s|%s|%s\n' "$backend" "$protocol" "$tracked_port" >> "$remaining_file"
                failed=1
                ;;
        esac
    done < "$FIREWALL_STATE_FILE"

    if [ "$firewalld_changed" -ne 0 ] && ! firewall-cmd --reload >/dev/null 2>&1; then
        failed=1
    fi
    if [ -s "$remaining_file" ]; then
        mv -f "$remaining_file" "$FIREWALL_STATE_FILE" || failed=1
    else
        rm -f "$remaining_file" "$FIREWALL_STATE_FILE" || failed=1
    fi
    return "$failed"
}

# Remove WildPaqet/Paqet protection rules derived from live configs
cleanup_paqet_iptables_from_configs() {
    command -v iptables &>/dev/null || return 0

    local config port sip sport proto endpoint
    local -a requested_configs=("$@")
    while IFS= read -r -d '' config; do
        local role
        role=$(grep "^role:" "$config" 2>/dev/null | awk '{print $2}' | tr -d '"' || true)

        if [ "$role" = "server" ]; then
            port=$(grep -A5 "^listen:" "$config" 2>/dev/null | grep "addr:" | \
                   sed -n 's/.*:\([0-9]*\)".*/\1/p' | head -1 | tr -d ' ')
            if ! validate_port "$port"; then
                port=$(grep -A8 "^network:" "$config" 2>/dev/null | grep -E 'addr:[[:space:]]*"' | \
                       head -1 | sed -n 's/.*:\([0-9]*\)".*/\1/p' | tr -d ' ')
            fi
            if validate_port "$port"; then
                cleanup_tls_iptables_port "$port"
                for proto in tcp udp; do
                    _iptables_delete_loop raw PREROUTING -p "$proto" --dport "$port" -m comment --comment "$FIREWALL_COMMENT" -j NOTRACK
                    _iptables_delete_loop raw OUTPUT -p "$proto" --sport "$port" -m comment --comment "$FIREWALL_COMMENT" -j NOTRACK
                    _iptables_delete_loop raw PREROUTING -p "$proto" --dport "$port" -j NOTRACK
                    _iptables_delete_loop raw OUTPUT -p "$proto" --sport "$port" -j NOTRACK
                    _iptables_delete_loop filter INPUT -p "$proto" --dport "$port" -j ACCEPT
                    _iptables_delete_loop filter OUTPUT -p "$proto" --sport "$port" -j ACCEPT
                done
                _iptables_delete_loop mangle OUTPUT -p tcp --sport "$port" --tcp-flags RST RST -m comment --comment "$FIREWALL_COMMENT" -j DROP
                _iptables_delete_loop mangle PREROUTING -p tcp --dport "$port" --tcp-flags RST RST -m comment --comment "$FIREWALL_COMMENT" -j DROP
                _iptables_delete_loop mangle OUTPUT -p tcp --sport "$port" --tcp-flags RST RST -j DROP
                _iptables_delete_loop mangle PREROUTING -p tcp --dport "$port" --tcp-flags RST RST -j DROP
            fi
        elif [ "$role" = "client" ]; then
            # Primary server.addr + every server.addrs[] entry
            while IFS= read -r endpoint; do
                endpoint=$(echo "$endpoint" | tr -d '"' | xargs)
                [ -z "$endpoint" ] && continue
                sip="${endpoint%%:*}"
                sport="${endpoint##*:}"
                if [ -n "$sip" ] && validate_port "$sport"; then
                    _iptables_delete_loop raw OUTPUT -p tcp -d "$sip" --dport "$sport" -m comment --comment "$FIREWALL_COMMENT" -j NOTRACK
                    _iptables_delete_loop raw PREROUTING -p tcp -s "$sip" --sport "$sport" -m comment --comment "$FIREWALL_COMMENT" -j NOTRACK
                    _iptables_delete_loop mangle OUTPUT -p tcp -d "$sip" --dport "$sport" --tcp-flags RST RST -m comment --comment "$FIREWALL_COMMENT" -j DROP
                    _iptables_delete_loop mangle PREROUTING -p tcp -s "$sip" --sport "$sport" --tcp-flags RST RST -m comment --comment "$FIREWALL_COMMENT" -j DROP
                    _iptables_delete_loop raw OUTPUT -p tcp -d "$sip" --dport "$sport" -j NOTRACK
                    _iptables_delete_loop raw PREROUTING -p tcp -s "$sip" --sport "$sport" -j NOTRACK
                    _iptables_delete_loop mangle OUTPUT -p tcp -d "$sip" --dport "$sport" --tcp-flags RST RST -j DROP
                    _iptables_delete_loop mangle PREROUTING -p tcp -s "$sip" --sport "$sport" --tcp-flags RST RST -j DROP
                fi
            done < <(
                awk '
                  /^server:/ { in_server=1; next }
                  in_server && /^[^[:space:]#]/ { in_server=0 }
                  in_server && /addr:[[:space:]]*"/ {
                    line=$0
                    sub(/^[^"]*"/, "", line)
                    sub(/".*/, "", line)
                    if (line != "") print line
                  }
                  in_server && /addrs:/ { in_addrs=1; next }
                  in_server && in_addrs && /^[[:space:]]*-[[:space:]]*"/ {
                    line=$0
                    sub(/^[^"]*"/, "", line)
                    sub(/".*/, "", line)
                    if (line != "") print line
                    next
                  }
                  in_server && in_addrs && /^[[:space:]]*[^[:space:]-]/ { in_addrs=0 }
                ' "$config" 2>/dev/null
            )

            # Forward / SOCKS listen ports from client yaml
            while IFS= read -r port; do
                [ -z "$port" ] && continue
                if validate_port "$port"; then
                    cleanup_tls_iptables_port "$port"
                    for proto in tcp udp; do
                        _iptables_delete_loop raw PREROUTING -p "$proto" --dport "$port" -m comment --comment "$FIREWALL_COMMENT" -j NOTRACK
                        _iptables_delete_loop raw OUTPUT -p "$proto" --sport "$port" -m comment --comment "$FIREWALL_COMMENT" -j NOTRACK
                        _iptables_delete_loop raw PREROUTING -p "$proto" --dport "$port" -j NOTRACK
                        _iptables_delete_loop raw OUTPUT -p "$proto" --sport "$port" -j NOTRACK
                    done
                    _iptables_delete_loop mangle OUTPUT -p tcp --sport "$port" --tcp-flags RST RST -m comment --comment "$FIREWALL_COMMENT" -j DROP
                    _iptables_delete_loop mangle PREROUTING -p tcp --dport "$port" --tcp-flags RST RST -m comment --comment "$FIREWALL_COMMENT" -j DROP
                    _iptables_delete_loop mangle OUTPUT -p tcp --sport "$port" --tcp-flags RST RST -j DROP
                    _iptables_delete_loop mangle PREROUTING -p tcp --dport "$port" --tcp-flags RST RST -j DROP
                fi
            done < <(grep -E 'listen:[[:space:]]*"' "$config" 2>/dev/null | grep -oE ':[0-9]+' | tr -d ':' | sort -u)
        fi
    done < <(
        if [ ${#requested_configs[@]} -gt 0 ]; then
            printf '%s\0' "${requested_configs[@]}"
        else
            find "$CONFIG_DIR" -name "*.yaml" -type f -print0 2>/dev/null
        fi
    )
}

cleanup_wildpaqet_bot_silent() {
    systemctl stop "${BOT_SERVICE:-telegram-paqet-bot}" 2>/dev/null || true
    systemctl disable "${BOT_SERVICE:-telegram-paqet-bot}" 2>/dev/null || true
    rm -f "/etc/systemd/system/${BOT_SERVICE:-telegram-paqet-bot}.service" 2>/dev/null || true
    rm -f "/lib/systemd/system/${BOT_SERVICE:-telegram-paqet-bot}.service" 2>/dev/null || true
    rm -f "/usr/lib/systemd/system/${BOT_SERVICE:-telegram-paqet-bot}.service" 2>/dev/null || true
    find /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system -type l \
        -name "${BOT_SERVICE:-telegram-paqet-bot}.service" -delete 2>/dev/null || true
    rm -f "${BOT_SCRIPT:-/usr/local/bin/telegram-paqet-bot}" 2>/dev/null || true
    rm -rf "${BOT_CONFIG_DIR:-/etc/telegram-paqet-bot}" 2>/dev/null || true
    rm -f "${BOT_LOG_FILE:-/var/log/telegram-paqet-bot.log}" 2>/dev/null || true
}

cleanup_kernel_optimizations_silent() {
    # Stop persistence before restoring the oldest snapshot (the baseline that
    # predates the first optimizer run, not a later WildPaqet profile).
    optimizer_remove_qdisc_persistence >/dev/null 2>&1 || true
    restore_ip_forwarding_dropin >/dev/null 2>&1 || true
    local restored=0
    if [ -d "$NETOPT_STATE_DIR" ]; then
        local snap
        snap=$(optimizer_oldest_snapshot 2>/dev/null || true)
        if [ -n "$snap" ] && [ -d "$snap" ]; then
            optimizer_restore_snapshot "$snap" >/dev/null 2>&1 && restored=1
        fi
    fi

    if [ "$restored" -eq 0 ]; then
        grep -q "$NETOPT_MARKER" "$SYSCTL_FILE" 2>/dev/null && rm -f "$SYSCTL_FILE" 2>/dev/null || true
        grep -q "$NETOPT_MARKER" "$LIMITS_FILE" 2>/dev/null && rm -f "$LIMITS_FILE" 2>/dev/null || true
        sysctl --system >/dev/null 2>&1 || true
    fi

    rm -rf "$NETOPT_STATE_DIR" 2>/dev/null || true
}

verify_full_uninstall_cleanup() {
    local leftovers=()
    local path unit table chain
    for path in \
        "$BIN_DIR/paqet" "$CONFIG_DIR" "$INSTALL_DIR" "$CORE_SRC_DIR" "$GO_TOOLCHAIN_DIR" \
        "$MANAGER_PATH" /usr/local/bin/paqet-manager /usr/bin/paqet /usr/bin/wildpaqet \
        /usr/bin/paqet-manager /bin/wildpaqet "$STATE_DIR" "$NETOPT_QDISC_SCRIPT" \
        "$(dirname "$NETOPT_QDISC_SCRIPT")" /root/paqet "$BACKUP_DIR" \
        "/etc/systemd/system/$NETOPT_QDISC_UNIT" \
        "/etc/systemd/system/${BOT_SERVICE:-telegram-paqet-bot}.service" \
        "/lib/systemd/system/${BOT_SERVICE:-telegram-paqet-bot}.service" \
        "/usr/lib/systemd/system/${BOT_SERVICE:-telegram-paqet-bot}.service" \
        "${BOT_SCRIPT:-/usr/local/bin/telegram-paqet-bot}" \
        "${BOT_CONFIG_DIR:-/etc/telegram-paqet-bot}" \
        "${BOT_LOG_FILE:-/var/log/telegram-paqet-bot.log}"; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            leftovers+=("$path")
        fi
    done
    for path in "$BIN_DIR"/paqet.bak-* "$BIN_DIR"/paqet.bak.*; do
        [ -e "$path" ] && leftovers+=("$path")
    done
    for path in /tmp/paqet.tar.gz /tmp/paqet-extract.* /tmp/paqet_linux_* \
        /tmp/paqet-linux-* /tmp/wildpaqet-go-* /tmp/wildpaqet-core-*; do
        [ -e "$path" ] && leftovers+=("$path")
    done
    for path in "$SERVICE_DIR"/paqet.service "$SERVICE_DIR"/paqet-*.service \
        /lib/systemd/system/paqet.service /lib/systemd/system/paqet-*.service \
        /usr/lib/systemd/system/paqet.service /usr/lib/systemd/system/paqet-*.service \
        "$SERVICE_DIR"/paqet.service.d "$SERVICE_DIR"/paqet-*.service.d; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            leftovers+=("$path")
        fi
    done
    while IFS= read -r path; do
        [ -n "$path" ] && leftovers+=("$path")
    done < <(find "$SERVICE_DIR" /lib/systemd/system /usr/lib/systemd/system -type l \
        \( -name 'paqet.service' -o -name 'paqet-*.service' \) -print 2>/dev/null)
    while IFS= read -r path; do
        [ -n "$path" ] && leftovers+=("$path")
    done < <(find "$SERVICE_DIR" /lib/systemd/system /usr/lib/systemd/system -type l \
        -name "${BOT_SERVICE:-telegram-paqet-bot}.service" -print 2>/dev/null)

    while IFS= read -r unit; do
        [ -n "$unit" ] && leftovers+=("systemd:$unit")
    done < <(systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null \
        | awk '/^paqet(-.*)?\.service/ {print $1}')
    unit=$(systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null \
        | awk '$1 == "telegram-paqet-bot.service" {print $1; exit}')
    [ -z "$unit" ] || leftovers+=("systemd:$unit")

    if crontab -l 2>/dev/null | grep -Eq 'systemctl[[:space:]]+restart[[:space:]]+paqet(-[^[:space:]]+|\.service)?([[:space:]]|$)|/usr/local/bin/paqet|/opt/paqet'; then
        leftovers+=("root-crontab:paqet")
    fi

    if command -v iptables >/dev/null 2>&1; then
        while read -r table chain; do
            if iptables -t "$table" -L "$chain" -n 2>/dev/null | grep -q "$FIREWALL_COMMENT"; then
                leftovers+=("iptables:$table/$chain")
            fi
        done <<'EOF'
raw PREROUTING
raw OUTPUT
mangle PREROUTING
mangle OUTPUT
filter INPUT
filter OUTPUT
nat PREROUTING
nat POSTROUTING
EOF
    fi

    if [ ${#leftovers[@]} -gt 0 ]; then
        print_error "Uninstall verification found ${#leftovers[@]} leftover item(s):"
        printf '  - %s\n' "${leftovers[@]}"
        return 1
    fi
    print_success "Post-uninstall verification passed: no managed artifacts remain"
    return 0
}

# Full uninstall: remove every WildPaqet/Paqet script + tunnel artifact
uninstall_paqet() {
    clear
    show_banner
    echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║ Uninstall WildPaqet (Full Cleanup)                       ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}\n"

    echo -e "${YELLOW}This will remove ALL script/tunnel-related items:${NC}"
    echo -e "  • All paqet-* systemd units + auto-restart cron jobs"
    echo -e "  • Core binary: ${CYAN}$BIN_DIR/paqet${NC} (+ all .bak backups)"
    echo -e "  • Install tree: ${CYAN}$INSTALL_DIR${NC}"
    echo -e "  • Core source clone: ${CYAN}$CORE_SRC_DIR${NC}"
    echo -e "  • Isolated Go toolchain: ${CYAN}$GO_TOOLCHAIN_DIR${NC}"
    echo -e "  • Configs: ${CYAN}$CONFIG_DIR${NC}"
    echo -e "  • Manager: ${CYAN}wildpaqet${NC} (+ legacy paqet-manager links)"
    echo -e "  • Telegram bot service/files/logs"
    echo -e "  • Kernel sysctl/limits drop-ins from this script"
    echo -e "  • Managed firewall/NAT rules (iptables marker + tracked UFW/firewalld rules)"
    echo -e "  • Download cache ${CYAN}/root/paqet${NC} and backups ${CYAN}$BACKUP_DIR${NC}"
    echo -e "  • Temp build/extract files under /tmp/paqet*"
    echo ""
    echo -e "${CYAN}Optional (asked once):${NC} flush untracked legacy NAT rules"
    echo ""
    echo -e "${RED}Type YES to continue full uninstall:${NC}"
    read -p "> " confirm
    if [ "$confirm" != "YES" ]; then
        print_info "Uninstall cancelled"
        pause
        return
    fi

    # --- 1) iptables protection (before deleting configs) ---
    print_step "Removing Paqet iptables protection rules..."
    cleanup_paqet_iptables_from_configs
    if cleanup_managed_firewall_rules; then
        print_success "Managed firewall and NAT rules cleaned"
    else
        print_warning "Some tracked firewall rules could not be removed; final verification will list their state"
    fi

    # --- 2) NAT leftovers (optional — can affect non-Paqet DNAT) ---
    echo ""
    read -p "Flush ALL remaining iptables NAT rules, including non-WildPaqet rules? (y/N): " flush_nat
    if [[ "$flush_nat" =~ ^[Yy]$ ]]; then
        print_step "Flushing NAT table..."
        if command -v iptables &>/dev/null; then
            iptables -t nat -F 2>/dev/null || true
            iptables -t nat -X 2>/dev/null || true
            print_success "NAT table flushed"
        fi
    else
        print_info "NAT table left unchanged"
    fi

    # --- 3) Stop services + cron (unit list + files on disk) ---
    print_step "Stopping and removing Paqet services..."
    local services=()
    local unit
    while IFS= read -r unit; do
        [ -n "$unit" ] && services+=("$unit")
    done < <(
        {
            systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null | awk '/^paqet(-.*)?\.service/ {print $1}'
            systemctl list-units --type=service --all --no-legend --no-pager 2>/dev/null | awk '$1 ~ /^paqet(-.*)?\.service$/ {print $1}'
            find "$SERVICE_DIR" /lib/systemd/system /usr/lib/systemd/system -maxdepth 1 \
                \( -name 'paqet.service' -o -name 'paqet-*.service' \) -printf '%f\n' 2>/dev/null
        } | sed 's/\.service$/.service/' | sort -u
    )

    local service
    for service in "${services[@]}"; do
        [[ "$service" == *.service ]] || service="${service}.service"
        local service_name="${service%.service}"
        print_info "Removing $service_name"
        remove_cronjob "$service_name" >/dev/null 2>&1 || true
        systemctl stop "$service" 2>/dev/null || true
        systemctl disable "$service" 2>/dev/null || true
        rm -f "$SERVICE_DIR/$service" 2>/dev/null || true
        rm -f "/lib/systemd/system/$service" 2>/dev/null || true
        rm -f "/usr/lib/systemd/system/$service" 2>/dev/null || true
    done
    find "$SERVICE_DIR" /lib/systemd/system /usr/lib/systemd/system -type l \
        \( -name 'paqet.service' -o -name 'paqet-*.service' \) -delete 2>/dev/null || true
    rm -rf "$SERVICE_DIR"/paqet.service.d "$SERVICE_DIR"/paqet-*.service.d 2>/dev/null || true

    # Catch leftover paqet restart cron lines (any user crontab for root)
    if crontab -l >/dev/null 2>&1; then
        crontab -l 2>/dev/null | grep -vE 'systemctl[[:space:]]+restart[[:space:]]+paqet(-[^[:space:]]+|\.service)?([[:space:]]|$)|/usr/local/bin/paqet|/opt/paqet' | crontab - 2>/dev/null || true
    fi

    # --- 4) Telegram bot ---
    print_step "Removing Telegram bot..."
    cleanup_wildpaqet_bot_silent
    print_success "Telegram bot removed"

    # --- 5) Kernel / limits / ip_forward drop-in ---
    print_step "Removing kernel optimizations and limits..."
    cleanup_kernel_optimizations_silent
    print_success "Kernel drop-in configs removed"

    # --- 6) Binaries, install dirs, source clone, configs ---
    print_step "Removing binaries, configs, and source trees..."
    # Stop any stray paqet processes
    pkill -f "$BIN_DIR/paqet" 2>/dev/null || true
    pkill -f '/usr/local/bin/paqet ' 2>/dev/null || true
    sleep 0.5 2>/dev/null || true

    rm -f "$BIN_DIR/paqet" 2>/dev/null || true
    rm -f "$BIN_DIR"/paqet.bak-* 2>/dev/null || true
    rm -f "$BIN_DIR"/paqet.bak.* 2>/dev/null || true
    rm -f /usr/bin/paqet 2>/dev/null || true
    rm -rf "$CONFIG_DIR" 2>/dev/null || true
    rm -rf "$INSTALL_DIR" 2>/dev/null || true
    rm -rf "$CORE_SRC_DIR" 2>/dev/null || true
    rm -rf "$GO_TOOLCHAIN_DIR" 2>/dev/null || true
    print_success "Core, configs, source, and isolated Go toolchain removed"

    # --- 7) Manager command + legacy names ---
    print_step "Removing WildPaqet manager command..."
    rm -f "$MANAGER_PATH" 2>/dev/null || true
    rm -f /usr/local/bin/paqet-manager 2>/dev/null || true
    rm -f /usr/bin/wildpaqet 2>/dev/null || true
    rm -f /usr/bin/paqet-manager 2>/dev/null || true
    rm -f /bin/wildpaqet 2>/dev/null || true
    hash -r 2>/dev/null || true
    print_success "Manager command removed (wildpaqet / paqet-manager)"

    # --- 8) Caches, backups, temp artifacts (always for full uninstall) ---
    print_step "Removing caches, backups, and temp files..."
    rm -rf /root/paqet 2>/dev/null || true
    rm -rf "$BACKUP_DIR" 2>/dev/null || true
    rm -f /tmp/paqet.tar.gz 2>/dev/null || true
    rm -rf /tmp/paqet-extract.* 2>/dev/null || true
    rm -f /tmp/paqet_linux_* 2>/dev/null || true
    rm -f /tmp/paqet-linux-* 2>/dev/null || true
    rm -f /tmp/wildpaqet-go-* 2>/dev/null || true
    rm -f /tmp/wildpaqet-core-* 2>/dev/null || true
    # orphaned mktemp dirs if glob failed on some shells
    find /tmp -maxdepth 1 -type d -name 'paqet-extract.*' -exec rm -rf {} + 2>/dev/null || true
    rmdir "$STATE_DIR" 2>/dev/null || true
    rmdir "$(dirname "$NETOPT_QDISC_SCRIPT")" 2>/dev/null || true
    print_success "Removed /root/paqet, $BACKUP_DIR, and /tmp/paqet* leftovers"

    # --- 9) Persist firewall + reload units ---
    print_step "Reloading systemd and saving firewall rules..."
    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed 2>/dev/null || true
    save_iptables >/dev/null 2>&1 || true

    local verification_ok=1
    verify_full_uninstall_cleanup || verification_ok=0

    echo ""
    if [ "$verification_ok" -eq 1 ]; then
        echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}✅ WildPaqet full uninstall completed and verified${NC}"
        echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    else
        echo -e "${RED}══════════════════════════════════════════════════════════════${NC}"
        echo -e "${RED}⚠ WildPaqet uninstall completed with leftovers (listed above)${NC}"
        echo -e "${RED}══════════════════════════════════════════════════════════════${NC}"
    fi
    echo -e "${YELLOW}Notes:${NC}"
    echo -e "  • Distro packages (curl, iptables-persistent, golang, libpcap-dev, …) were NOT removed"
    echo -e "  • Safe/Auto optimizer: the oldest snapshot baseline is restored, then owned state is removed"
    echo -e "  • External third-party BBR installs (if any) are left alone — undo separately if needed"
    echo -e "  • Reboot recommended for a fully clean sysctl/limits session state"
    echo ""
    pause
    [ "$verification_ok" -eq 1 ]
}
# ================================================
# TELEGRAM BOT CONFIGURATION
# ================================================

readonly BOT_CONFIG_DIR="/etc/telegram-paqet-bot"
readonly BOT_CONFIG_FILE="$BOT_CONFIG_DIR/config.conf"
readonly BOT_LOG_FILE="/var/log/telegram-paqet-bot.log"
readonly BOT_SERVICE="telegram-paqet-bot"
readonly BOT_SCRIPT="/usr/local/bin/telegram-paqet-bot"

# ================================================
# BOT CORE FUNCTIONS
# ================================================

# Read yes/no confirmation
read_confirm() {
    local prompt="$1"
    local varname="$2"
    local default="$3"
    local value=""
    
    while true; do
        if [ "$default" = "y" ]; then
            echo -e "${YELLOW}${prompt} (Y/n):${NC}"
        elif [ "$default" = "n" ]; then
            echo -e "${YELLOW}${prompt} (y/N):${NC}"
        else
            echo -e "${YELLOW}${prompt} (y/n):${NC}"
        fi
        read -p "> " value < /dev/tty
        
        if [ -z "$value" ] && [ -n "$default" ]; then
            value="$default"
        fi
        
        case "$value" in
            [Yy]|[Yy][Ee][Ss]) eval "$varname=true"; return 0 ;;
            [Nn]|[Nn][Oo]) eval "$varname=false"; return 0 ;;
            *) print_error "Please enter 'y' for yes or 'n' for no."; echo "" ;;
        esac
    done
}

# Initialize bot configuration
init_bot_config() {
    mkdir -p "$BOT_CONFIG_DIR"
    if [ ! -f "$BOT_CONFIG_FILE" ]; then
        cat > "$BOT_CONFIG_FILE" << EOF
# WildPaqet Telegram Bot Configuration
# Last updated: $(date)
BOT_TOKEN=""
CHAT_ID=""
ENABLE_BOT="false"
ENABLE_BOOT_REPORT="true"
ENABLE_SERVICE_WATCH="true"
WATCH_INTERVAL="60"
SOCKS5_PROXY=""
USE_SOCKS5="false"
TELEGRAM_API_BASE="https://api.telegram.org"
EOF
        chmod 600 "$BOT_CONFIG_FILE"
        print_success "Bot configuration created at $BOT_CONFIG_FILE"
    fi
}

# Load bot configuration
load_bot_config() {
    if [ -f "$BOT_CONFIG_FILE" ]; then
        source "$BOT_CONFIG_FILE"
    else
        BOT_TOKEN=""
        CHAT_ID=""
        ENABLE_BOT="false"
        ENABLE_BOOT_REPORT="true"
        ENABLE_SERVICE_WATCH="true"
        WATCH_INTERVAL="60"
        SOCKS5_PROXY=""
        USE_SOCKS5="false"
        TELEGRAM_API_BASE="https://api.telegram.org"
    fi
}

# Save bot configuration
save_bot_config() {
    cat > "$BOT_CONFIG_FILE" << EOF
# WildPaqet Telegram Bot Configuration
# Last updated: $(date)
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
ENABLE_BOT="$ENABLE_BOT"
ENABLE_BOOT_REPORT="$ENABLE_BOOT_REPORT"
ENABLE_SERVICE_WATCH="$ENABLE_SERVICE_WATCH"
WATCH_INTERVAL="$WATCH_INTERVAL"
SOCKS5_PROXY="$SOCKS5_PROXY"
USE_SOCKS5="$USE_SOCKS5"
TELEGRAM_API_BASE="${TELEGRAM_API_BASE:-https://api.telegram.org}"
EOF
    chmod 600 "$BOT_CONFIG_FILE"
    print_success "Bot configuration saved"
}

# ================================================
# Detect SOCKS5 proxy from client configs
# ================================================
detect_socks5_proxy() {
    local socks5_found=""
    local socks5_port=""
    echo "Checking Paqet client configs for SOCKS5 proxy..." >> "$BOT_LOG_FILE"
    
    # Find all client configs
    while IFS= read -r -d '' file; do
        if grep -q "role:.*client" "$file" 2>/dev/null; then
            local config_name=$(basename "$file" .yaml)
            echo "Checking client: $config_name" >> "$BOT_LOG_FILE"
            
            # Look for socks5 section
            if grep -q "socks5:" "$file"; then
                # Extract port from socks5 listen address
                socks5_port=$(grep -A2 "socks5:" "$file" | grep "listen:" | grep -oE ':[0-9]+' | tr -d ':' | head -1)
                
                if [ -n "$socks5_port" ]; then
                    socks5_found="127.0.0.1:$socks5_port"
                    echo "Found SOCKS5 proxy in $config_name on port $socks5_port" >> "$BOT_LOG_FILE"
                    break
                fi
            fi
        fi
    done < <(find "$CONFIG_DIR" -name "*.yaml" -type f -print0 2>/dev/null)
    echo "$socks5_found"
}

# ================================================
# Add SOCKS5 to first client if not exists
# ================================================
add_socks5_to_client() {
    local first_client=""
    local client_file=""
    local result=""
    
    # Find first client config
    while IFS= read -r -d '' file; do
        if grep -q "role:.*client" "$file" 2>/dev/null; then
            first_client=$(basename "$file" .yaml)
            client_file="$file"
            break
        fi
    done < <(find "$CONFIG_DIR" -name "*.yaml" -type f -print0 2>/dev/null)
    
    if [ -n "$client_file" ]; then
        echo "Adding SOCKS5 proxy to client: $first_client" >> "$BOT_LOG_FILE"
        
        # Check if socks5 section already exists
        if grep -q "socks5:" "$client_file"; then
            echo "SOCKS5 already exists in this config" >> "$BOT_LOG_FILE"
            # Extract existing port
            local existing_port=$(grep -A2 "socks5:" "$client_file" | grep "listen:" | grep -oE ':[0-9]+' | tr -d ':' | head -1)
            result="127.0.0.1:$existing_port"
        else
            # Add socks5 section before network or at the end
            if grep -q "network:" "$client_file"; then
                # Insert before network section
                sed -i '/network:/i\
socks5:\
  - listen: "127.0.0.1:1080"\
' "$client_file"
            else
                # Add at the end
                echo "" >> "$client_file"
                echo "socks5:" >> "$client_file"
                echo "  - listen: \"127.0.0.1:1080\"" >> "$client_file"
            fi
            echo "SOCKS5 proxy added to $first_client on port 1080" >> "$BOT_LOG_FILE"
            
            # Restart the client service
            systemctl restart "paqet-$first_client" 2>/dev/null
            echo "Service paqet-$first_client restarted" >> "$BOT_LOG_FILE"
            
            result="127.0.0.1:1080"
        fi
    fi
    echo "$result"
}

# Send Telegram message with multiple fallbacks
send_telegram_message() {
    local message="$1"
    local parse_mode="${2:-HTML}"
    
    if [ "$ENABLE_BOT" != "true" ] || [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ]; then
        return 1
    fi

    message=$(echo -e "$message" | sed 's/"/\\"/g')
    
    local success=1
    local response
    local api_base="${TELEGRAM_API_BASE:-https://api.telegram.org}"
    
    # Prefer SOCKS5 when configured (useful on restricted networks)
    if [ "$USE_SOCKS5" = "true" ] && [ -n "$SOCKS5_PROXY" ]; then
        response=$(curl -s --max-time 8 --socks5-hostname "$SOCKS5_PROXY" \
            -X POST "$api_base/bot$BOT_TOKEN/sendMessage" \
            -H "Content-Type: application/json" \
            -d "$(printf '{"chat_id":"%s","text":"%s","parse_mode":"%s"}' "$CHAT_ID" "$message" "$parse_mode")" 2>&1)
        
        if echo "$response" | grep -q '"ok":true'; then
            success=0
            echo "[$(date)] Message sent via SOCKS5 proxy" >> "$BOT_LOG_FILE"
        fi
    fi
    
    # Direct Telegram API (JSON)
    if [ $success -ne 0 ]; then
        response=$(curl -s --max-time 8 \
            -X POST "$api_base/bot$BOT_TOKEN/sendMessage" \
            -H "Content-Type: application/json" \
            -d "$(printf '{"chat_id":"%s","text":"%s","parse_mode":"%s"}' "$CHAT_ID" "$message" "$parse_mode")" 2>&1)
        
        if echo "$response" | grep -q '"ok":true'; then
            success=0
            echo "[$(date)] Message sent via Telegram API" >> "$BOT_LOG_FILE"
        fi
    fi
    
    # Fallback: form-urlencoded
    if [ $success -ne 0 ]; then
        response=$(curl -s --max-time 8 \
            -X POST "$api_base/bot$BOT_TOKEN/sendMessage" \
            --data-urlencode "chat_id=$CHAT_ID" \
            --data-urlencode "text=$message" \
            --data-urlencode "parse_mode=$parse_mode" 2>&1)
        
        if echo "$response" | grep -q '"ok":true'; then
            success=0
            echo "[$(date)] Message sent via Telegram API (form)" >> "$BOT_LOG_FILE"
        fi
    fi
    
    if [ $success -eq 0 ]; then
        return 0
    else
        echo "[$(date)] Failed to send message. Last response: $response" >> "$BOT_LOG_FILE"
        return 1
    fi
}

# Debug function
print_debug() {
    if [ "$BOT_DEBUG" = "true" ]; then
        echo "[DEBUG] $1" >> "$BOT_LOG_FILE"
    fi
}

# Create bot main script
create_bot_script() {
    cat > "$BOT_SCRIPT" << 'EOF'
#!/bin/bash

# Paqet Telegram Bot - Monitor Service
# Auto-generated by Paqet Manager

BOT_CONFIG="/etc/telegram-paqet-bot/config.conf"
LOG_FILE="/var/log/telegram-paqet-bot.log"
LAST_STATE_FILE="/etc/telegram-paqet-bot/last_state"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

load_config() {
    if [ -f "$BOT_CONFIG" ]; then
        source "$BOT_CONFIG"
    else
        log "ERROR: Config file not found"
        exit 1
    fi
}

send_alert() {
    local message="$1"
    if [ -n "$BOT_TOKEN" ] && [ -n "$CHAT_ID" ] && [ "$ENABLE_BOT" = "true" ]; then
        message=$(echo -e "$message" | sed 's/"/\\"/g')
        
        local success=1
        local response
        local api_base="${TELEGRAM_API_BASE:-https://api.telegram.org}"
        
        if [ "$USE_SOCKS5" = "true" ] && [ -n "$SOCKS5_PROXY" ]; then
            response=$(curl -s --max-time 8 --socks5-hostname "$SOCKS5_PROXY" \
                -X POST "$api_base/bot$BOT_TOKEN/sendMessage" \
                -H "Content-Type: application/json" \
                -d "$(printf '{"chat_id":"%s","text":"%s","parse_mode":"HTML"}' "$CHAT_ID" "$message")" 2>&1)
            
            if echo "$response" | grep -q '"ok":true'; then
                success=0
                log "Alert sent via SOCKS5 proxy"
            fi
        fi
        
        if [ $success -ne 0 ]; then
            response=$(curl -s --max-time 8 \
                -X POST "$api_base/bot$BOT_TOKEN/sendMessage" \
                -H "Content-Type: application/json" \
                -d "$(printf '{"chat_id":"%s","text":"%s","parse_mode":"HTML"}' "$CHAT_ID" "$message")" 2>&1)
            
            if echo "$response" | grep -q '"ok":true'; then
                success=0
                log "Alert sent via Telegram API"
            fi
        fi
        
        if [ $success -ne 0 ]; then
            response=$(curl -s --max-time 8 \
                -X POST "$api_base/bot$BOT_TOKEN/sendMessage" \
                --data-urlencode "chat_id=$CHAT_ID" \
                --data-urlencode "text=$message" \
                --data-urlencode "parse_mode=HTML" 2>&1)
            
            if echo "$response" | grep -q '"ok":true'; then
                success=0
                log "Alert sent via Telegram API (form)"
            fi
        fi
        
        if [ $success -eq 0 ]; then
            log "Alert delivered successfully"
        else
            log "Failed to send alert after all methods. Last response: $response"
        fi
    fi
}

check_services() {
    local changes=""
    local current_state=""
    
    while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        local status=$(systemctl is-active "$svc" 2>/dev/null)
        local service_name="${svc%.service}"
        local config_name="${service_name#paqet-}"
        
        current_state="$current_state${svc}:${status}\n"
        
        local last_status=$(grep "^${svc}:" "$LAST_STATE_FILE" 2>/dev/null | cut -d: -f2)
        if [ "$last_status" != "$status" ]; then
            local emoji=""
            case "$status" in
                active) emoji="✅" ;;
                failed) emoji="❌" ;;
                inactive) emoji="💤" ;;
                *) emoji="❓" ;;
            esac
            
            local message="$emoji <b>Service $config_name</b>\n"
            message+="Status: $status\n"
            message+="Time: $(date '+%Y-%m-%d %H:%M:%S')"
            
            changes="$changes$message\n\n"
        fi
    done < <(systemctl list-units --type=service --all --no-legend 2>/dev/null | grep "paqet-" | awk '{print $1}' || true)
    
    echo -e "$current_state" > "$LAST_STATE_FILE"
    
    if [ -n "$changes" ]; then
        send_alert "🔔 <b>Paqet Service Status Changes</b>\n\n$changes"
    fi
}

send_boot_report() {
    local report="🚀 <b>Server Boot Report - $(hostname)</b>\n\n"
    report+="⏰ <b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')\n\n"
    
    report+="🔧 <b>Paqet Services:</b>\n"
    local services=()
    while IFS= read -r svc; do
        services+=("$svc")
    done < <(systemctl list-units --type=service --all --no-legend 2>/dev/null | grep "paqet-" | awk '{print $1}' || true)
    
    if [ ${#services[@]} -gt 0 ]; then
        for svc in "${services[@]}"; do
            local status=$(systemctl is-active "$svc" 2>/dev/null)
            local emoji=""
            case "$status" in
                active) emoji="✅" ;;
                failed) emoji="❌" ;;
                inactive) emoji="💤" ;;
                *) emoji="❓" ;;
            esac
            report+="  $emoji $svc: $status\n"
        done
    else
        report+="  No Paqet services found\n"
    fi
    
    # Add SOCKS5 status if configured
    if [ -n "$SOCKS5_PROXY" ]; then
        report+="\n🔄 <b>Proxy Status:</b>\n"
        report+="  SOCKS5: $SOCKS5_PROXY (enabled)\n"
    fi
    
    send_alert "$report"
}

main() {
    load_config
    touch "$LAST_STATE_FILE"
    
    if [ "$ENABLE_BOT" = "true" ] && [ "$ENABLE_BOOT_REPORT" = "true" ]; then
        send_boot_report
    fi
    
    log "Bot started with interval: ${WATCH_INTERVAL}s"
    
    while true; do
        if [ "$ENABLE_BOT" = "true" ] && [ "$ENABLE_SERVICE_WATCH" = "true" ]; then
            check_services
        fi
        sleep "${WATCH_INTERVAL:-60}"
    done
}

main
EOF
    chmod +x "$BOT_SCRIPT"
    touch "$BOT_CONFIG_DIR/last_state"
    chmod 666 "$BOT_CONFIG_DIR/last_state"
    print_success "Bot script created at $BOT_SCRIPT"
}

# Create bot service file
create_bot_service() {
    cat > "/etc/systemd/system/$BOT_SERVICE.service" << EOF
[Unit]
Description=Paqet Telegram Bot Monitor
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=$BOT_SCRIPT
Restart=always
RestartSec=10
User=root
Group=root
Environment="BOT_CONFIG=$BOT_CONFIG_FILE"

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    print_success "Bot service created"
}

# Remove bot completely
remove_bot() {
    clear
    echo -e "\n${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║              Uninstall Telegram Bot                           ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}\n"
    
    print_warning "This will completely remove the Telegram bot and all its files."
    echo -e "${GREEN}Note: This only removes the Telegram bot files.${NC}"
    echo -e "${GREEN}Your Paqet tunnels and services will NOT be affected.${NC}"
    echo ""
    read_confirm "Are you ABSOLUTELY SURE?" confirm_remove "n"
    
    if [ "$confirm_remove" != "true" ]; then
        print_info "Removal cancelled"
        pause
        return
    fi
    
    print_step "Stopping bot service..."
    systemctl stop $BOT_SERVICE 2>/dev/null
    systemctl disable $BOT_SERVICE 2>/dev/null
    
    print_step "Removing service file..."
    rm -f "/etc/systemd/system/$BOT_SERVICE.service"
    systemctl daemon-reload
    
    print_step "Removing bot script..."
    rm -f "$BOT_SCRIPT"
    
    print_step "Removing configuration and logs..."
    read_confirm "Remove all configuration files and logs?" remove_configs "n"
    
    if [ "$remove_configs" = "true" ]; then
        rm -rf "$BOT_CONFIG_DIR"
        rm -f "$BOT_LOG_FILE"
        print_success "All bot files removed"
    else
        print_info "Configuration preserved at $BOT_CONFIG_DIR"
        print_info "Logs preserved at $BOT_LOG_FILE"
    fi
    
    print_success "✅ Bot uninstalled successfully"
    pause
}

# ================================================
# BOT SETUP WIZARD
# ================================================
setup_bot_wizard() {
    clear
    show_banner
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              🤖 Telegram Bot Setup Wizard                    ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}\n"
    
    print_step "This wizard will configure and start the Telegram bot in one go"
    echo ""
    
    # 1. Get Bot Token
    print_input "Step 1: Enter your Bot Token"
    echo -e "${CYAN}How to get:${NC}"
    echo "  1. Open Telegram and search for @BotFather"
    echo "  2. Send /newbot and follow instructions"
    echo "  3. Copy the token (looks like: 123456789:ABCdefGHIjklMNOpqrsTUVwxyz)"
    echo ""
    
    local token=""
    while [ -z "$token" ]; do
        read -p "Bot Token > " token
        token=$(echo "$token" | tr -d '[:space:]')
        if [ -z "$token" ]; then
            print_error "Token cannot be empty"
        fi
    done
    BOT_TOKEN="$token"
    print_success "Bot token saved"
    echo ""
    
    # 2. Get Chat ID
    print_input "Step 2: Enter your Telegram Chat ID"
    echo -e "${CYAN}How to get:${NC}"
    echo "  1. Open Telegram and search for @userinfobot"
    echo "  2. Send /start"
    echo "  3. Your ID will be shown (usually a number)"
    echo ""
    
    local chat_id=""
    while [ -z "$chat_id" ]; do
        read -p "Chat ID > " chat_id
        chat_id=$(echo "$chat_id" | tr -d '[:space:]')
        if [ -z "$chat_id" ]; then
            print_error "Chat ID cannot be empty"
        fi
    done
    CHAT_ID="$chat_id"
    print_success "Chat ID saved"
    echo ""
    
    # 3. Detect or configure SOCKS5 proxy
    print_input "Step 3: Configuring SOCKS5 proxy for Telegram"
    echo -e "${CYAN}Checking existing client configs for SOCKS5...${NC}"
    
    # Try to detect existing SOCKS5
    local detected_proxy=$(detect_socks5_proxy)
    
    if [ -n "$detected_proxy" ]; then
        SOCKS5_PROXY="$detected_proxy"
        print_success "Found existing SOCKS5 proxy: $SOCKS5_PROXY"
        USE_SOCKS5="true"
    else
        print_warning "No SOCKS5 proxy found in client configs"
        read_confirm "Add SOCKS5 proxy to first client? (recommended)" add_socks5 "y"
        
        if [ "$add_socks5" = "true" ]; then
            local added_proxy=$(add_socks5_to_client)
            if [ -n "$added_proxy" ]; then
                SOCKS5_PROXY="$added_proxy"
                print_success "SOCKS5 proxy added: $SOCKS5_PROXY"
                USE_SOCKS5="true"
            else
                print_error "Failed to add SOCKS5 proxy"
                USE_SOCKS5="false"
                SOCKS5_PROXY=""
            fi
        else
            print_info "Continuing without SOCKS5 proxy"
            USE_SOCKS5="false"
            SOCKS5_PROXY=""
        fi
    fi
    echo ""
    
    # 4. Ask for notification preferences
    print_input "Step 4: Configure notification settings"
    read_confirm "Enable boot reports? (recommended)" ENABLE_BOOT_REPORT "y"
    read_confirm "Enable service status monitoring?" ENABLE_SERVICE_WATCH "y"
    echo ""
    
    # 5. Ask for watch interval
    print_input "Step 5: Set check interval"
    echo -e "${CYAN}How often should the bot check for changes? (30-3600 seconds)${NC}"
    read -p "Interval [60]: " interval
    interval="${interval:-60}"
    if [[ "$interval" =~ ^[0-9]+$ ]] && [ "$interval" -ge 30 ] && [ "$interval" -le 3600 ]; then
        WATCH_INTERVAL="$interval"
    else
        print_warning "Invalid interval, using default: 60 seconds"
        WATCH_INTERVAL="60"
    fi
    echo ""
    
    # 6. Enable bot and save
    ENABLE_BOT="true"
    save_bot_config
    
    # 7. Create bot files
    print_step "Creating bot files..."
    create_bot_script
    create_bot_service
    
    # 8. Start bot service
    print_step "Starting bot service..."
    systemctl enable $BOT_SERVICE >/dev/null 2>&1
    systemctl start $BOT_SERVICE
    sleep 2
    
    # 9. Check status and send test message
    if systemctl is-active --quiet $BOT_SERVICE; then
        print_success "✅ Bot service started successfully!"
        
        print_step "Sending test message..."
        local test_message="✅ <b>Paqet Bot Successfully Installed!</b>\n\n"
        test_message="${test_message}Bot is now active and monitoring your server.\n"
        test_message="${test_message}📋 You will receive:\n"
        test_message="${test_message}• Boot reports when server restarts\n"
        test_message="${test_message}• Service status changes\n"
        test_message="${test_message}• Packet loss alerts\n\n"
        test_message="${test_message}⚙️ Settings:\n"
        test_message="${test_message}• Watch interval: ${WATCH_INTERVAL}s\n"
        test_message="${test_message}• Boot reports: ${ENABLE_BOOT_REPORT}\n"
        test_message="${test_message}• Service watch: ${ENABLE_SERVICE_WATCH}\n"
        
        if [ -n "$SOCKS5_PROXY" ]; then
            test_message="${test_message}• SOCKS5 proxy: ${SOCKS5_PROXY} (enabled)\n"
        fi
        
        test_message="${test_message}\n🚀 Happy tunneling!"
        
        if send_telegram_message "$test_message"; then
            print_success "Test message sent! Check your Telegram"
        else
            print_warning "Test message may have failed. Check your token and chat ID"
            sleep 2
            print_info "If you received the message in Telegram, it's working fine"
        fi
    else
        print_error "❌ Bot service failed to start"
        journalctl -u $BOT_SERVICE -n 20 --no-pager
    fi
    
    echo ""
    print_success "✅ Bot setup completed!"
    pause
}

# ================================================
# BOT MANAGEMENT MENU
# ================================================

telegram_bot_menu() {
    init_bot_config
    load_bot_config
    
    while true; do
        clear
        # show_banner
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║              🤖 Telegram Bot Management                      ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}\n"
        
        # Status Overview
        echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║                      STATUS OVERVIEW                         ║${NC}"
        echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
        
        # Bot Status
        if [ "$ENABLE_BOT" = "true" ]; then
            echo -e "  ${GREEN}●${NC} Bot: ${GREEN}ENABLED${NC}"
        else
            echo -e "  ${RED}○${NC} Bot: ${RED}DISABLED${NC}"
        fi
        
        # Configuration Status
        if [ -n "$BOT_TOKEN" ] && [ -n "$CHAT_ID" ]; then
            echo -e "  ${GREEN}✓${NC} Configuration: ${GREEN}Complete${NC}"
            echo -e "  ${CYAN}  Token: ${BOT_TOKEN:0:15}...${NC}"
            echo -e "  ${CYAN}  Chat ID: $CHAT_ID${NC}"
        else
            echo -e "  ${RED}✗${NC} Configuration: ${RED}Incomplete${NC}"
        fi
        
        # Service Status
        if systemctl is-active --quiet $BOT_SERVICE 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} Service: ${GREEN}Running${NC}"
            local uptime=$(systemctl show $BOT_SERVICE -p ActiveEnterTimestamp 2>/dev/null | cut -d= -f2)
            [ -n "$uptime" ] && echo -e "  ${CYAN}  Started: $uptime${NC}"
        else
            echo -e "  ${RED}✗${NC} Service: ${RED}Stopped${NC}"
        fi
        
        # SOCKS5 Status
        if [ -n "$SOCKS5_PROXY" ] && [ "$USE_SOCKS5" = "true" ]; then
            echo -e "  ${GREEN}✓${NC} SOCKS5 Proxy: ${CYAN}$SOCKS5_PROXY${NC}"
        fi
        
        echo -e "\n${YELLOW}══════════════════════════════════════════════════════════════${NC}"
        echo -e "${CYAN}MAIN ACTIONS:${NC}"
        echo -e "  ${WHITE}[S]${NC} 🚀 ${GREEN}Setup Bot Wizard${NC} - Complete setup in one go"
        echo -e "  ${WHITE}[R]${NC} 🗑️  ${RED}Remove Bot${NC} - Uninstall completely"
        
        echo -e "\n${YELLOW}══════════════════════════════════════════════════════════════${NC}"
        echo -e "${CYAN}NOTIFICATION SETTINGS:${NC}"
        echo -e "  ${WHITE}[1]${NC} Boot Report [$( [ "$ENABLE_BOOT_REPORT" = "true" ] && echo "✅ ON" || echo "❌ OFF")]"
        echo -e "  ${WHITE}[2]${NC} Service Watch [$( [ "$ENABLE_SERVICE_WATCH" = "true" ] && echo "✅ ON" || echo "❌ OFF")]"
        echo -e "  ${WHITE}[3]${NC} Watch Interval (current: ${CYAN}${WATCH_INTERVAL}s${NC})"
        
        echo -e "\n${YELLOW}══════════════════════════════════════════════════════════════${NC}"
        echo -e "${CYAN}PROXY SETTINGS:${NC}"
        echo -e "  ${WHITE}[4]${NC} Toggle SOCKS5 Proxy [$( [ "$USE_SOCKS5" = "true" ] && echo "✅ ON" || echo "❌ OFF")]"
        echo -e "  ${WHITE}[5]${NC} Set SOCKS5 Proxy (current: ${CYAN}${SOCKS5_PROXY:-Not set}${NC})"
        
        echo -e "\n${YELLOW}══════════════════════════════════════════════════════════════${NC}"
        echo -e "${CYAN}SERVICE CONTROL:${NC}"
        echo -e "  ${WHITE}[6]${NC} Start Bot Service"
        echo -e "  ${WHITE}[7]${NC} Stop Bot Service"
        echo -e "  ${WHITE}[8]${NC} Restart Bot Service"
        echo -e "  ${WHITE}[9]${NC} View Bot Logs"
        echo -e "  ${WHITE}[10]${NC} Test Bot (Send test message)"
        
        echo -e "\n${YELLOW}══════════════════════════════════════════════════════════════${NC}"
        echo -e "  ${WHITE}[0]${NC} ↩️ Back to Main Menu"
        echo ""
        
        read -p "Choose option: " bot_choice
        
        case $bot_choice in
            [Ss]) setup_bot_wizard ;;
            [Rr]) remove_bot ;;
            
            1)
                [ "$ENABLE_BOOT_REPORT" = "true" ] && ENABLE_BOOT_REPORT="false" || ENABLE_BOOT_REPORT="true"
                save_bot_config
                print_success "Boot Report: $([ "$ENABLE_BOOT_REPORT" = "true" ] && echo "ON" || echo "OFF")"
                sleep 1
                ;;
            2)
                [ "$ENABLE_SERVICE_WATCH" = "true" ] && ENABLE_SERVICE_WATCH="false" || ENABLE_SERVICE_WATCH="true"
                save_bot_config
                print_success "Service Watch: $([ "$ENABLE_SERVICE_WATCH" = "true" ] && echo "ON" || echo "OFF")"
                sleep 1
                ;;
            3)
                echo -e "\n${YELLOW}Enter watch interval in seconds (30-3600):${NC}"
                read -p "> " new_interval
                if [[ "$new_interval" =~ ^[0-9]+$ ]] && [ "$new_interval" -ge 30 ] && [ "$new_interval" -le 3600 ]; then
                    WATCH_INTERVAL="$new_interval"
                    save_bot_config
                    print_success "Watch interval set to ${WATCH_INTERVAL}s"
                    
                    if systemctl is-active --quiet $BOT_SERVICE; then
                        systemctl restart $BOT_SERVICE
                        print_info "Bot service restarted to apply new interval"
                    fi
                else
                    print_error "Invalid interval (must be 30-3600)"
                    sleep 2
                fi
                ;;
            4)
                if [ -n "$SOCKS5_PROXY" ]; then
                    [ "$USE_SOCKS5" = "true" ] && USE_SOCKS5="false" || USE_SOCKS5="true"
                    save_bot_config
                    print_success "SOCKS5 Proxy: $([ "$USE_SOCKS5" = "true" ] && echo "ON" || echo "OFF")"
                    sleep 1
                else
                    print_error "Please set SOCKS5 proxy first (option 5)"
                    sleep 2
                fi
                ;;
            5)
                echo -e "\n${YELLOW}Enter SOCKS5 proxy (host:port):${NC}"
                read -p "> " new_proxy
                if [ -n "$new_proxy" ]; then
                    SOCKS5_PROXY="$new_proxy"
                    USE_SOCKS5="true"
                    save_bot_config
                    print_success "SOCKS5 proxy set to $SOCKS5_PROXY"
                    sleep 1
                fi
                ;;
            6)
                if [ ! -f "$BOT_SCRIPT" ]; then
                    create_bot_script
                fi
                if [ ! -f "/etc/systemd/system/$BOT_SERVICE.service" ]; then
                    create_bot_service
                fi
                systemctl start $BOT_SERVICE
                sleep 2
                if systemctl is-active --quiet $BOT_SERVICE; then
                    print_success "Bot service started"
                else
                    print_error "Failed to start bot service"
                    journalctl -u $BOT_SERVICE -n 10 --no-pager
                fi
                sleep 1
                ;;
            7)
                systemctl stop $BOT_SERVICE
                print_info "Bot service stopped"
                sleep 1
                ;;
            8)
                systemctl restart $BOT_SERVICE
                sleep 2
                if systemctl is-active --quiet $BOT_SERVICE; then
                    print_success "Bot service restarted"
                else
                    print_error "Failed to restart bot service"
                fi
                sleep 1
                ;;
            9)
                echo -e "\n${CYAN}Last 20 lines of bot log:${NC}\n"
                if [ -f "$BOT_LOG_FILE" ]; then
                    tail -20 "$BOT_LOG_FILE"
                else
                    journalctl -u $BOT_SERVICE -n 20 --no-pager
                fi
                echo ""
                pause
                ;;
            10)
                if [ -n "$BOT_TOKEN" ] && [ -n "$CHAT_ID" ] && [ "$ENABLE_BOT" = "true" ]; then
                    print_step "Sending test message..."
                    local test_msg="✅ <b>Paqet Bot Test</b>\n\n"
                    test_msg+="If you see this, bot is working correctly!\n"
                    test_msg+="Time: $(date '+%Y-%m-%d %H:%M:%S')"
                    
                    if send_telegram_message "$test_msg"; then
                        print_success "Test message sent! Check your Telegram"
                    else
                        print_error "Failed to send message. Check token and chat ID."
                    fi
                else
                    print_error "Bot not properly configured or enabled"
                    print_info "Please run Setup Wizard [S] first"
                fi
                pause
                ;;
            0) return ;;
            *) print_error "Invalid choice"; sleep 1 ;;
        esac
    done
}
# ================================================
# MAIN MENU
# ================================================

main_menu() {
    while true; do
        clear
        show_banner
        
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║ WildPaqet Main Menu                                      ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}\n"
        
        if [ -f "$BIN_DIR/paqet" ]; then
            echo -e "${GREEN}✅ Paqet is installed${NC}"
            local core_version
            core_version=$("$BIN_DIR/paqet" version 2>/dev/null | grep "^Version:" | head -1 | cut -d':' -f2 | xargs)
            if [ -n "$core_version" ]; then
                echo -e "   ${GREEN}└─ Version: ${CYAN}$core_version${NC}"
            fi
        else
            echo -e "${YELLOW}⚠️ Paqet not installed${NC}"
        fi
        
        local missing_deps
        missing_deps=$(check_dependencies)
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ Dependencies are installed${NC}"
        else
            echo -e "${YELLOW}⚠️ Missing dependencies: $missing_deps${NC}"
        fi
        
        echo -e "\n${CYAN}0.${NC}⚙️  Install Paqet Binary / Manager"
        echo -e "${CYAN}1.${NC}📦 Install Dependencies"
        echo -e "${CYAN}2.${NC}🌍 Configure as Server (kharej)"
        echo -e "${CYAN}3.${NC}🇮🇷 Configure as Client (Iran) [Port Forwarding / SOCKS5]"
        echo -e "${CYAN}4.${NC}🛠️  Manage Services"
        echo -e "${CYAN}5.${NC}🔄 Manage All Services (Restart/Logs/Delete)"
        echo -e "${CYAN}6.${NC}📊 Test Connection"
        echo -e "${CYAN}7.${NC}🚀 Optimize Server"
        echo -e "${CYAN}8.${NC}🗑️  Uninstall WildPaqet (Full Cleanup)"
        echo -e "${CYAN}9.${NC}🤖 Telegram Bot Manager"
        echo -e "${CYAN}10.${NC}🚪 Exit"
        echo ""
        
        read -p "Select option [0-10]: " choice
        
        case $choice in
            0) install_paqet ;;
            1) install_dependencies ;;
            2) configure_server ;;
            3) configure_client ;;
            4) manage_services ;;
            5) manage_all_services ;;
            6) test_connection ;;
            7) optimize_server ;;
            8) uninstall_paqet ;;
            9) telegram_bot_menu ;;
            10)
                echo -e "\n${GREEN}══════════════════════════════════════════════════════════════${NC}"
                echo -e "${GREEN} Goodbye! ${NC}"
                echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}\n"
                exit 0
                ;;
            *) print_error "Invalid option"; sleep 1 ;;
        esac
    done
}

# ================================================
# START
# ================================================

# WILDPAQET_LIB_ONLY=1 lets a test harness source this file for its functions
# without running the root check or launching the interactive manager.
if [ -z "${WILDPAQET_LIB_ONLY:-}" ]; then
    check_root
    ensure_manager_command
    sync_installed_manager_if_outdated
    migrate_tcp_preset_to_default
    main_menu
fi
