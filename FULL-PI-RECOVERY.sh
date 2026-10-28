#!/usr/bin/env bash
#
# FULL-PI-RECOVERY.sh
# Raspberry Pi 4 disaster-recovery installer
#
# Target:
#   Raspberry Pi OS Lite 64-bit / Debian 13 (Trixie)
#   OpenMediaVault 8
#
# What it does:
#   1. Collects recovery settings.
#   2. Installs OMV 8 using the official OMV-Plugin-Developers installer
#      with network setup skipped (-n), so the script can configure the
#      user's custom network after OMV is installed.
#   3. Reboots once.
#   4. Automatically resumes after reboot.
#   5. Installs Docker, hotspot/network packages, Samba, WireGuard tools, etc.
#   6. Recreates the user's Pi-hole, WireGuard and Jellyfin Docker projects.
#   7. Recreates hotspot + Ethernet DHCP, routing/NAT and media folders.
#   8. Creates the mediauser Samba account and working Samba shares.
#
# IMPORTANT:
#   - Use a NEW Raspberry Pi OS Lite 64-bit installation.
#   - Do NOT use Raspberry Pi OS Desktop.
#   - Do NOT run this on a working production server unless you intend to
#     rebuild/modify it.
#   - The script does NOT format disks.
#   - It does NOT contain existing private keys or existing application data.
#   - Existing files it overwrites are backed up under /root/pi-recovery-backup-*.
#   - OMV's Web UI is left at its default port 80. Change it to 8080 in
#     OMV -> System -> Workbench after recovery if desired.
#
# Official OMV installer reference:
# https://github.com/OpenMediaVault-Plugin-Developers/installScript
#

set -Eeuo pipefail

SCRIPT_VERSION="1.0"
STATE_DIR="/root/pi-full-recovery"
STATE_FILE="${STATE_DIR}/settings.env"
LOG_FILE="/root/pi-full-recovery.log"
SERVICE_FILE="/etc/systemd/system/pi-full-recovery-resume.service"
BACKUP_DIR="/root/pi-recovery-backup-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$STATE_DIR"
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export LANG=C.UTF-8
export LANGUAGE=C
export LC_ALL=C.UTF-8

trap 'rc=$?; echo; echo "[$(date -Is)] ERROR: recovery stopped with exit code ${rc}."; echo "Log: ${LOG_FILE}"; exit "${rc}"' ERR

msg()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
ok()   { echo -e "\033[1;32m[OK]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
die()  { echo -e "\033[1;31m[ERROR]\033[0m $*"; exit 1; }

require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "Run this script with: sudo bash FULL-PI-RECOVERY.sh"
}

backup_file() {
    local f="$1"
    if [[ -e "$f" || -L "$f" ]]; then
        mkdir -p "$BACKUP_DIR"
        mkdir -p "$(dirname "$BACKUP_DIR/$f")" 2>/dev/null || true
        cp -a "$f" "$BACKUP_DIR/$f" 2>/dev/null || true
    fi
}

backup_dir() {
    local d="$1"
    if [[ -d "$d" ]]; then
        mkdir -p "$BACKUP_DIR$(dirname "$d")"
        cp -a "$d" "$BACKUP_DIR$(dirname "$d")/" 2>/dev/null || true
    fi
}

ask() {
    local var="$1"
    local prompt="$2"
    local default="${3:-}"
    local value
    if [[ -n "$default" ]]; then
        read -r -p "$prompt [$default]: " value
        value="${value:-$default}"
    else
        read -r -p "$prompt: " value
    fi
    printf -v "$var" '%s' "$value"
}

ask_secret() {
    local var="$1"
    local prompt="$2"
    local value
    read -r -s -p "$prompt: " value
    echo
    [[ -n "$value" ]] || die "$var cannot be empty."
    printf -v "$var" '%s' "$value"
}

detect_iface() {
    local candidate
    for candidate in "$1" "$2" "$3"; do
        if ip link show "$candidate" >/dev/null 2>&1; then
            echo "$candidate"
            return
        fi
    done
    echo ""
}

detect_media_uuid() {
    local uuid
    uuid="$(lsblk -nrpo NAME,FSTYPE,UUID | awk '$2=="xfs" && $3!="" {print $3; exit}')"
    echo "$uuid"
}

save_settings() {
    umask 077
    cat > "$STATE_FILE" <<EOF
UPLINK_IFACE=$(printf '%q' "$UPLINK_IFACE")
HOTSPOT_IFACE=$(printf '%q' "$HOTSPOT_IFACE")
ETH_IFACE=$(printf '%q' "$ETH_IFACE")
UPLINK_ADDR=$(printf '%q' "$UPLINK_ADDR")
UPLINK_GATEWAY=$(printf '%q' "$UPLINK_GATEWAY")
UPLINK_DNS1=$(printf '%q' "$UPLINK_DNS1")
UPLINK_DNS2=$(printf '%q' "$UPLINK_DNS2")
UPLINK_SSID=$(printf '%q' "$UPLINK_SSID")
UPLINK_WIFI_PASSWORD=$(printf '%q' "$UPLINK_WIFI_PASSWORD")
MEDIA_UUID=$(printf '%q' "$MEDIA_UUID")
HOTSPOT_SSID=$(printf '%q' "$HOTSPOT_SSID")
HOTSPOT_PASSWORD=$(printf '%q' "$HOTSPOT_PASSWORD")
WG_SERVER_URL=$(printf '%q' "$WG_SERVER_URL")
WG_SERVER_PORT=$(printf '%q' "$WG_SERVER_PORT")
WG_PEERS=$(printf '%q' "$WG_PEERS")
PIHOLE_PASSWORD=$(printf '%q' "$PIHOLE_PASSWORD")
MEDIAUSER_PASSWORD=$(printf '%q' "$MEDIAUSER_PASSWORD")
EOF
    chmod 600 "$STATE_FILE"
}

load_settings() {
    [[ -f "$STATE_FILE" ]] || die "Missing recovery state: $STATE_FILE"
    # shellcheck disable=SC1090
    source "$STATE_FILE"
}

install_resume_service() {
    cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=Full Raspberry Pi Recovery Resume
After=network-online.target
Wants=network-online.target
ConditionPathExists=/root/pi-full-recovery/settings.env

[Service]
Type=oneshot
ExecStart=/root/pi-full-recovery/FULL-PI-RECOVERY.sh --resume
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable pi-full-recovery-resume.service
}

remove_resume_service() {
    systemctl disable --now pi-full-recovery-resume.service 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
}

preflight() {
    msg "Preflight checks"

    [[ -f /etc/os-release ]] || die "Cannot detect operating system."
    # shellcheck disable=SC1091
    source /etc/os-release

    if [[ "${VERSION_CODENAME:-}" != "trixie" ]]; then
        die "This recovery targets Debian 13 (Trixie) / current OMV 8. Found: ${VERSION_CODENAME:-unknown}. Flash current Raspberry Pi OS Lite 64-bit based on Debian 13."
    fi

    local arch
    arch="$(dpkg --print-architecture)"
    [[ "$arch" == "arm64" ]] || die "Expected arm64. Found ${arch}. Flash Raspberry Pi OS Lite 64-bit."

    if dpkg-query -W -f='${Status}' openmediavault 2>/dev/null | grep -q "install ok installed"; then
        die "OpenMediaVault is already installed. This script is intended for a fresh recovery OS."
    fi

    if dpkg -l 2>/dev/null | grep -Eq 'gdm3|lightdm|lxdm|sddm|slim|wdm|xdm'; then
        die "A desktop environment was detected. OMV does not support installing over a graphical desktop."
    fi

    if ! ip route get 1.1.1.1 >/dev/null 2>&1; then
        die "No working network route. Connect the Pi to the Internet before running recovery."
    fi

    ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 || warn "ICMP to 1.1.1.1 failed. Continuing; DNS/HTTPS will be tested separately."
    curl -fsSI --max-time 10 https://github.com >/dev/null || die "HTTPS access to GitHub failed."

    ok "Debian 13/Trixie + arm64 + network checks passed."
}

collect_settings() {
    msg "Recovery configuration"

    local d_uplink d_hotspot d_eth d_media
    d_uplink="$(detect_iface wlan0 wlp2s0 eth0)"
    d_hotspot="$(detect_iface wlp1s0u1u1 wlx00e0092fc95a '')"
    d_eth="$(detect_iface end0 eth0 enxb827eb '')"
    d_media="$(detect_media_uuid)"

    ask UPLINK_IFACE "Internet/uplink interface" "${d_uplink:-wlan0}"
    ask HOTSPOT_IFACE "USB Wi-Fi hotspot interface" "${d_hotspot:-wlp1s0u1u1}"
    ask ETH_IFACE "Ethernet LAN interface" "${d_eth:-end0}"

    ask UPLINK_ADDR "Uplink static IPv4/CIDR" "192.168.242.39/24"
    ask UPLINK_GATEWAY "Uplink gateway" "192.168.242.247"
    ask UPLINK_DNS1 "Primary DNS" "1.1.1.1"
    ask UPLINK_DNS2 "Secondary DNS" "8.8.8.8"
    ask UPLINK_SSID "Uplink Wi-Fi SSID" "Nihal's Galaxy F22"
    ask_secret UPLINK_WIFI_PASSWORD "Uplink Wi-Fi password"

    ask MEDIA_UUID "Main XFS media disk UUID (do NOT enter /dev/sda1)" "${d_media}"
    [[ -n "$MEDIA_UUID" ]] || die "MEDIA_UUID is required."
    [[ "$MEDIA_UUID" =~ ^[0-9a-fA-F-]{8,}$ ]] || die "MEDIA_UUID does not look valid."

    ask HOTSPOT_SSID "Hotspot SSID" "PiHome"
    ask_secret HOTSPOT_PASSWORD "Hotspot WPA2 password"

    ask WG_SERVER_URL "WireGuard public hostname/IP (blank if inbound VPN is not available)" ""
    ask WG_SERVER_PORT "WireGuard UDP port" "51820"
    ask WG_PEERS "WireGuard peer count" "1"

    ask_secret PIHOLE_PASSWORD "Pi-hole web password"
    ask_secret MEDIAUSER_PASSWORD "mediauser Samba password"

    save_settings
    ok "Settings saved securely to ${STATE_FILE}"
}

install_omv() {
    msg "Installing OpenMediaVault 8"

    # The official OMV-Plugin-Developers installer currently installs OMV 8 on
    # Debian 13/Trixie. -n skips its network setup, which is important here
    # because this recovery script has a custom wlan0/hotspot/end0 design.
    local installer="/root/omv-install"
    curl -fsSL https://github.com/OpenMediaVault-Plugin-Developers/installScript/raw/master/install -o "$installer"
    chmod 700 "$installer"

    "$installer" -n

    ok "OMV installation completed."
}

write_recovery_script_copy() {
    # The currently running script may have been downloaded directly.
    # Save a copy so the systemd resume service can invoke it after reboot.
    cp -f "$0" "${STATE_DIR}/FULL-PI-RECOVERY.sh"
    chmod 700 "${STATE_DIR}/FULL-PI-RECOVERY.sh"
}

schedule_resume_and_reboot() {
    msg "Scheduling automatic recovery resume"

    write_recovery_script_copy
    # Point service to the persistent copy.
    sed -i "s#ExecStart=.*#ExecStart=${STATE_DIR}/FULL-PI-RECOVERY.sh --resume#" "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable pi-full-recovery-resume.service

    touch "${STATE_DIR}/omv-installed"
    sync

    ok "Stage 1 finished."
    echo
    echo "The Pi will reboot now."
    echo "After reboot, the recovery service will continue automatically."
    echo "Do NOT run the script again manually."
    sleep 5
    reboot
}

install_packages() {
    msg "Installing required packages"

    apt-get update
    apt-get install -y \
        ca-certificates curl wget gnupg jq \
        docker.io docker-compose-plugin \
        hostapd dnsmasq \
        iptables iptables-persistent netfilter-persistent \
        wireguard-tools \
        samba smbclient \
        rfkill iw \
        avahi-daemon

    systemctl enable --now docker
    systemctl enable --now smbd || true
    systemctl enable --now avahi-daemon || true

    ok "Required packages installed."
}

configure_hostname() {
    msg "Configuring hostname"

    hostnamectl set-hostname cloud2SUserver

    if ! grep -qE '^[[:space:]]*127\.0\.1\.1[[:space:]]+cloud2SUserver([[:space:]]|$)' /etc/hosts; then
        backup_file /etc/hosts
        sed -i '/^[[:space:]]*127\.0\.1\.1[[:space:]]/d' /etc/hosts
        echo "127.0.1.1 cloud2SUserver" >> /etc/hosts
    fi
}

configure_uplink() {
    msg "Configuring Internet uplink"

    mkdir -p /etc/netplan
    backup_file /etc/netplan/30-openmediavault-wlan0.yaml

    cat > /etc/netplan/30-openmediavault-wlan0.yaml <<EOF
network:
  version: 2
  renderer: networkd
  wifis:
    ${UPLINK_IFACE}:
      dhcp4: no
      dhcp6: no
      addresses:
        - ${UPLINK_ADDR}
      routes:
        - to: 0.0.0.0/0
          via: ${UPLINK_GATEWAY}
      nameservers:
        addresses:
          - ${UPLINK_DNS1}
          - ${UPLINK_DNS2}
      access-points:
        "${UPLINK_SSID}":
          auth:
            key-management: wpa-psk
            password: "${UPLINK_WIFI_PASSWORD}"
          hidden: false
EOF

    chmod 600 /etc/netplan/30-openmediavault-wlan0.yaml
}

configure_hotspot_and_ethernet_network() {
    msg "Configuring hotspot and Ethernet"

    mkdir -p /etc/systemd/network
    backup_file /etc/systemd/network/20-hotspot.network
    backup_file /etc/systemd/network/21-ethernet-pc.network

    cat > /etc/systemd/network/20-hotspot.network <<EOF
[Match]
Name=${HOTSPOT_IFACE}

[Network]
Address=192.168.50.1/24
ConfigureWithoutCarrier=yes
IPv6AcceptRA=no
LinkLocalAddressing=no
EOF

    cat > /etc/systemd/network/21-ethernet-pc.network <<EOF
[Match]
Name=${ETH_IFACE}

[Network]
Address=192.168.60.1/24
ConfigureWithoutCarrier=yes
IPv6AcceptRA=no
LinkLocalAddressing=no
EOF

    chmod 644 /etc/systemd/network/20-hotspot.network /etc/systemd/network/21-ethernet-pc.network

    mkdir -p /etc/dnsmasq.d
    backup_file /etc/dnsmasq.d/hotspot.conf
    backup_file /etc/dnsmasq.d/ethernet-pc.conf

    cat > /etc/dnsmasq.d/hotspot.conf <<EOF
interface=${HOTSPOT_IFACE}
bind-interfaces
dhcp-range=192.168.50.10,192.168.50.200,255.255.255.0,12h
dhcp-option=3,192.168.50.1
dhcp-option=6,192.168.50.1
dhcp-authoritative
EOF

    cat > /etc/dnsmasq.d/ethernet-pc.conf <<EOF
interface=${ETH_IFACE}
bind-interfaces
dhcp-range=192.168.60.10,192.168.60.20,255.255.255.0,12h
dhcp-option=3,192.168.60.1
dhcp-option=6,192.168.60.1
dhcp-authoritative
EOF
}

configure_hostapd() {
    msg "Configuring USB Wi-Fi hotspot"

    backup_file /etc/hostapd/hostapd.conf
    mkdir -p /etc/hostapd

    cat > /etc/hostapd/hostapd.conf <<EOF
country_code=IN
interface=${HOTSPOT_IFACE}
driver=nl80211
ssid=${HOTSPOT_SSID}
hw_mode=g
channel=6
ieee80211n=1
wmm_enabled=1
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=${HOTSPOT_PASSWORD}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF

    chmod 600 /etc/hostapd/hostapd.conf

    # Debian packages sometimes ship hostapd disabled/commented.
    mkdir -p /etc/default
    backup_file /etc/default/hostapd
    cat > /etc/default/hostapd <<EOF
DAEMON_CONF="/etc/hostapd/hostapd.conf"
EOF

    systemctl unmask hostapd || true
    systemctl enable hostapd
}

configure_dnsmasq() {
    msg "Configuring dnsmasq"

    # Pi-hole owns DNS port 53 on 192.168.50.1. dnsmasq is DHCP-only.
    # It must not listen on port 53 or bind to the Pi-hole address.
    backup_file /etc/dnsmasq.conf

    cat > /etc/dnsmasq.conf <<'EOF'
# DHCP-only configuration for Pi recovery server.
# Pi-hole provides DNS on port 53.
port=0
conf-dir=/etc/dnsmasq.d/,*.conf
EOF

    systemctl enable dnsmasq
}

configure_sysctl() {
    msg "Configuring IP forwarding"

    backup_file /etc/sysctl.d/99-pi-router.conf
    cat > /etc/sysctl.d/99-pi-router.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=0
EOF

    sysctl --system >/dev/null
}

configure_firewall() {
    msg "Configuring routing/NAT firewall"

    # Never flush Docker chains. We only insert our own forwarding/NAT rules.
    iptables -C FORWARD -i "$HOTSPOT_IFACE" -o "$UPLINK_IFACE" -j ACCEPT 2>/dev/null ||
        iptables -I FORWARD 1 -i "$HOTSPOT_IFACE" -o "$UPLINK_IFACE" -j ACCEPT

    iptables -C FORWARD -i "$UPLINK_IFACE" -o "$HOTSPOT_IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null ||
        iptables -I FORWARD 2 -i "$UPLINK_IFACE" -o "$HOTSPOT_IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

    iptables -C FORWARD -i "$ETH_IFACE" -o "$UPLINK_IFACE" -j ACCEPT 2>/dev/null ||
        iptables -I FORWARD 3 -i "$ETH_IFACE" -o "$UPLINK_IFACE" -j ACCEPT

    iptables -C FORWARD -i "$UPLINK_IFACE" -o "$ETH_IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null ||
        iptables -I FORWARD 4 -i "$UPLINK_IFACE" -o "$ETH_IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

    # WireGuard traffic leaving through uplink.
    iptables -C FORWARD -s 10.13.13.0/24 -o "$UPLINK_IFACE" -j ACCEPT 2>/dev/null ||
        iptables -I FORWARD 5 -s 10.13.13.0/24 -o "$UPLINK_IFACE" -j ACCEPT

    iptables -t nat -C POSTROUTING -s 192.168.50.0/24 -o "$UPLINK_IFACE" -j MASQUERADE 2>/dev/null ||
        iptables -t nat -I POSTROUTING 1 -s 192.168.50.0/24 -o "$UPLINK_IFACE" -j MASQUERADE

    iptables -t nat -C POSTROUTING -s 192.168.60.0/24 -o "$UPLINK_IFACE" -j MASQUERADE 2>/dev/null ||
        iptables -t nat -I POSTROUTING 2 -s 192.168.60.0/24 -o "$UPLINK_IFACE" -j MASQUERADE

    iptables -t nat -C POSTROUTING -s 10.13.13.0/24 -o "$UPLINK_IFACE" -j MASQUERADE 2>/dev/null ||
        iptables -t nat -I POSTROUTING 3 -s 10.13.13.0/24 -o "$UPLINK_IFACE" -j MASQUERADE

    netfilter-persistent save
}

configure_storage() {
    msg "Configuring media storage"

    local mountpoint="/srv/dev-disk-by-uuid-${MEDIA_UUID}"

    if ! blkid -U "$MEDIA_UUID" >/dev/null 2>&1; then
        warn "Disk UUID ${MEDIA_UUID} is not currently present."
        warn "Media directories will be created when the disk is mounted by OMV."
        mkdir -p "$mountpoint"
    else
        mkdir -p "$mountpoint"

        # Do not format. Mount only if not already mounted.
        if ! findmnt -rn "$mountpoint" >/dev/null 2>&1; then
            local dev
            dev="$(blkid -U "$MEDIA_UUID")"
            mount "$dev" "$mountpoint" || warn "Could not mount ${dev} at ${mountpoint}. Mount it in OMV and rerun the recovery stage."
        fi
    fi

    mkdir -p "$mountpoint/Media/Movies"
    mkdir -p "$mountpoint/Media/TV Shows"
    mkdir -p "$mountpoint/Media/Music"
    mkdir -p "$mountpoint/Media/Shows"

    chown -R admin:admin "$mountpoint/Media" 2>/dev/null || true
    chmod -R 775 "$mountpoint/Media" 2>/dev/null || true

    MEDIA_ROOT="$mountpoint"
}

configure_users() {
    msg "Configuring users"

    if ! id mediauser >/dev/null 2>&1; then
        useradd -m -s /bin/bash mediauser
    fi

    echo "mediauser:${MEDIAUSER_PASSWORD}" | chpasswd
    usermod -aG admin mediauser 2>/dev/null || true
    smbpasswd -a -s mediauser <<EOF
${MEDIAUSER_PASSWORD}
${MEDIAUSER_PASSWORD}
EOF
    smbpasswd -e mediauser || true
}

write_pihole() {
    msg "Creating Pi-hole Docker project"

    mkdir -p /opt/docker/pihole
    backup_dir /opt/docker/pihole

    cat > /opt/docker/pihole/compose.yml <<EOF
services:
  pihole:
    image: pihole/pihole:latest
    container_name: piholeDNS

    environment:
      TZ: Asia/Kolkata
      FTLCONF_webserver_api_password: "${PIHOLE_PASSWORD}"
      FTLCONF_dns_listeningMode: "ALL"
      FTLCONF_dns_upstreams: "1.1.1.1;8.8.8.8"

    volumes:
      - ./etc-pihole:/etc/pihole
      - ./etc-dnsmasq.d:/etc/dnsmasq.d

    ports:
      - "192.168.50.1:53:53/tcp"
      - "192.168.50.1:53:53/udp"
      - "192.168.50.1:8181:80/tcp"

    restart: unless-stopped
EOF

    cd /opt/docker/pihole
    docker compose pull
    docker compose up -d
}

write_wireguard() {
    msg "Creating WireGuard Docker project"

    mkdir -p /opt/docker/wireguard/config
    backup_dir /opt/docker/wireguard

    cat > /opt/docker/wireguard/compose.yml <<EOF
services:
  wireguard:
    image: lscr.io/linuxserver/wireguard:latest
    container_name: wireguard

    cap_add:
      - NET_ADMIN
      - SYS_MODULE

    environment:
      PUID: 1000
      PGID: 1000
      TZ: Asia/Kolkata
      SERVERURL: "${WG_SERVER_URL}"
      SERVERPORT: "${WG_SERVER_PORT}"
      PEERS: "${WG_PEERS}"
      PEERDNS: "192.168.50.1"
      INTERNAL_SUBNET: "10.13.13.0"
      ALLOWEDIPS: "192.168.242.0/24,192.168.50.0/24,192.168.60.0/24"
      PERSISTENTKEEPALIVE_PEERS: "all"

    volumes:
      - ./config:/config
      - /lib/modules:/lib/modules:ro

    ports:
      - "${WG_SERVER_PORT}:${WG_SERVER_PORT}/udp"

    sysctls:
      net.ipv4.conf.all.src_valid_mark: "1"

    restart: unless-stopped
EOF

    cd /opt/docker/wireguard
    docker compose pull
    docker compose up -d
}

write_jellyfin() {
    msg "Creating Jellyfin Docker project"

    mkdir -p /opt/docker/jellyfin/config
    mkdir -p /opt/docker/jellyfin/cache
    backup_dir /opt/docker/jellyfin

    cat > /opt/docker/jellyfin/compose.yml <<EOF
services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    user: "1000:1000"

    ports:
      - "8096:8096"

    volumes:
      - ./config:/config
      - ./cache:/cache
      - "${MEDIA_ROOT}/Media/Movies:/media/movies"
      - "${MEDIA_ROOT}/Media/TV Shows:/media/tv"
      - "${MEDIA_ROOT}/Media/Music:/media/music"

    restart: unless-stopped
EOF

    chown -R 1000:1000 /opt/docker/jellyfin/config /opt/docker/jellyfin/cache

    cd /opt/docker/jellyfin
    docker compose pull
    docker compose up -d
}

configure_samba() {
    msg "Configuring Samba shares"

    backup_file /etc/samba/smb.conf

    cat > /etc/samba/smb.conf <<EOF
[global]
   workgroup = WORKGROUP
   server string = cloud2SUserver
   security = user
   map to guest = never
   server min protocol = SMB2
   server max protocol = SMB3
   ea support = yes
   vfs objects = acl_xattr
   map acl inherit = yes
   store dos attributes = yes

[Movies]
   path = ${MEDIA_ROOT}/Media/Movies
   browseable = yes
   read only = no
   guest ok = no
   valid users = mediauser
   force user = admin
   create mask = 0664
   directory mask = 0775

[TV Shows]
   path = ${MEDIA_ROOT}/Media/TV Shows
   browseable = yes
   read only = no
   guest ok = no
   valid users = mediauser
   force user = admin
   create mask = 0664
   directory mask = 0775

[Music]
   path = ${MEDIA_ROOT}/Media/Music
   browseable = yes
   read only = no
   guest ok = no
   valid users = mediauser
   force user = admin
   create mask = 0664
   directory mask = 0775
EOF

    testparm -s >/dev/null
    systemctl enable --now smbd
    systemctl restart smbd
}

configure_docker_startup() {
    msg "Checking Docker services"

    docker ps --format 'table {{.Names}}\t{{.Status}}'

    systemctl enable docker
}

restart_network_services() {
    msg "Starting/restarting network services"

    # Apply netplan. This can briefly interrupt SSH.
    netplan generate
    netplan apply || warn "netplan apply returned an error; inspect /var/log and netplan config."

    systemctl restart systemd-networkd || true

    # Recreate the static interface addresses immediately if networkd has not
    # picked them up yet.
    ip addr show "$HOTSPOT_IFACE" | grep -q "192.168.50.1/24" || ip addr add 192.168.50.1/24 dev "$HOTSPOT_IFACE" 2>/dev/null || true
    ip link set "$HOTSPOT_IFACE" up || true

    ip addr show "$ETH_IFACE" | grep -q "192.168.60.1/24" || ip addr add 192.168.60.1/24 dev "$ETH_IFACE" 2>/dev/null || true
    ip link set "$ETH_IFACE" up || true

    rfkill unblock wifi || true

    systemctl restart dnsmasq
    systemctl restart hostapd || true
}

verification() {
    msg "Final verification"

    echo
    echo "=== OS ==="
    cat /etc/os-release | grep -E '^(PRETTY_NAME|VERSION_CODENAME)=' || true
    echo
    echo "=== OMV ==="
    dpkg-query -W -f='${Package} ${Version}\n' openmediavault 2>/dev/null || true
    echo
    echo "=== Network ==="
    ip -br addr
    echo
    ip route
    echo
    echo "=== Docker ==="
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    echo
    echo "=== Hotspot/DHCP ==="
    systemctl --no-pager --full status hostapd 2>/dev/null | tail -n 15 || true
    systemctl --no-pager --full status dnsmasq 2>/dev/null | tail -n 15 || true
    echo
    echo "=== Firewall NAT ==="
    iptables -t nat -S POSTROUTING | grep -E '192\.168\.50\.0/24|192\.168\.60\.0/24|10\.13\.13\.0/24' || true
    echo
    echo "=== Storage ==="
    findmnt | grep 'dev-disk-by-uuid' || true
    echo
    echo "=== Samba ==="
    smbclient -L localhost -U mediauser%${MEDIAUSER_PASSWORD} 2>/dev/null || true

    echo
    echo "=== Pi-hole ==="
    curl -fsSI --max-time 5 http://192.168.50.1:8181/admin/ 2>/dev/null | head -n 3 || true

    echo
    echo "=== Jellyfin ==="
    curl -fsSI --max-time 5 http://127.0.0.1:8096/ 2>/dev/null | head -n 3 || true

    echo
    echo "=== WireGuard ==="
    docker exec wireguard wg show 2>/dev/null || true
}

final_message() {
    remove_resume_service
    rm -f "${STATE_DIR}/omv-installed"

    cat > "${STATE_DIR}/RECOVERY-COMPLETE.txt" <<EOF
Raspberry Pi server recovery completed.

Hostname:
  cloud2SUserver

OMV:
  http://<PI-LAN-IP>/

Pi-hole:
  http://192.168.50.1:8181/admin/

Jellyfin:
  http://192.168.60.1:8096

SMB:
  \\\\192.168.60.1\\Movies
  \\\\192.168.60.1\\TV Shows
  \\\\192.168.60.1\\Music

Hotspot:
  SSID: ${HOTSPOT_SSID}
  Gateway/DNS: 192.168.50.1

Ethernet:
  Pi: 192.168.60.1/24
  DHCP: 192.168.60.10-192.168.60.20

Pi-hole:
  DNS: 192.168.50.1:53

WireGuard:
  UDP port: ${WG_SERVER_PORT}
  VPN subnet: 10.13.13.0/24

Important:
  - OMV WebGUI remains at its default port 80.
  - Change it to 8080 in OMV -> System -> Workbench if you want your previous setup.
  - WireGuard inbound connections will not work through a carrier/phone hotspot
    unless the upstream network forwards UDP ${WG_SERVER_PORT} or you use a
    reachable public endpoint.
  - Existing Pi-hole/Jellyfin/WireGuard application state is NOT restored by
    this fresh rebuild. Copy your backed-up application data into the relevant
    /opt/docker/*/config directories if you have it.
EOF

    echo
    echo "============================================================"
    echo " FULL PI RECOVERY COMPLETE"
    echo "============================================================"
    echo
    echo "OMV:       http://<Pi-IP>/"
    echo "Pi-hole:   http://192.168.50.1:8181/admin/"
    echo "Jellyfin:  http://192.168.60.1:8096"
    echo
    echo "SMB shares:"
    echo "  \\\\192.168.60.1\\Movies"
    echo "  \\\\192.168.60.1\\TV Shows"
    echo "  \\\\192.168.60.1\\Music"
    echo
    echo "IMPORTANT: OMV WebGUI is still on port 80."
    echo "Change it to 8080 in OMV -> System -> Workbench."
    echo
    echo "Recovery log:"
    echo "  ${LOG_FILE}"
    echo
    echo "Recovery state:"
    echo "  ${STATE_DIR}"
    echo
}

resume() {
    require_root
    load_settings

    msg "Resuming FULL-PI-RECOVERY after reboot"

    # Give OMV/network services a little time to settle.
    sleep 10

    install_packages
    configure_hostname
    configure_uplink
    configure_hotspot_and_ethernet_network
    configure_hostapd
    configure_dnsmasq
    configure_sysctl
    configure_firewall
    configure_storage
    configure_users
    write_pihole
    write_wireguard
    write_jellyfin
    configure_samba
    configure_docker_startup
    restart_network_services

    sleep 5
    verification
    final_message
}

main() {
    require_root

    if [[ "${1:-}" == "--resume" ]]; then
        resume
        exit 0
    fi

    if [[ -f "${STATE_DIR}/omv-installed" ]]; then
        die "A recovery is already staged. Reboot/resume is expected. If this is a failed run, inspect ${LOG_FILE} and ${STATE_DIR} before restarting."
    fi

    preflight
    collect_settings

    msg "IMPORTANT FINAL CHECK"
    echo
    echo "This will install OpenMediaVault on this Raspberry Pi."
    echo "It is intended for a fresh Raspberry Pi OS Lite installation."
    echo "No disk will be formatted by this script."
    echo
    read -r -p "Type RECOVER to continue: " confirm
    [[ "$confirm" == "RECOVER" ]] || die "Recovery cancelled."

    BACKUP_DIR="/root/pi-recovery-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"

    install_resume_service
    install_omv
    schedule_resume_and_reboot
}

main "$@"
