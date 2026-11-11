#!/bin/bash
#
# ============================================================
# Script   : menu.sh
# Version  : 3.2 (Sesi v46: Visual redesign — 4 info panel + real-time query + Region auto-detect)
# Repo     : panggongfilm/cfnfree
# Path     : /update/menu.sh (di repo) → /usr/bin/menu (di VPS)
# Brand    : HAXOR PANEL TUNNELING
# Tagline  : DEKENG ANE BIAK BELITONG
# Source   : Redesign visual dari menu.sh v3.1 (panggongfilm/cfnfree)
#            Adaptasi design "SC1FORCR NEXUS" screenshot user v46
# Catatan  : Header 2 baris (HAXOR + BELITONG), footer dihapus,
#            4 panel info real-time (SERVER/NETWORK/TRAFFIC/SERVICES),
#            ACCOUNTS strip, border merah rounded, Region cache 24h,
#            CPU snapshot (BUKAN live monitoring, anti interfere read -p)
# ============================================================

# --- Palette 256-color (ANSI-C quoting $'...' — LESSON v6 FIX1) ---
CYAN=$'\033[38;5;51m'       # Bright cyan - primary (values, chevrons)
TEAL=$'\033[38;5;80m'       # Teal - secondary
GREEN=$'\033[38;5;48m'      # Mint green - status OK, dots, uptime
YELLOW=$'\033[38;5;227m'    # Soft yellow - menu numbers, special keys
ORANGE=$'\033[38;5;215m'    # Soft orange - warning
RED=$'\033[38;5;203m'       # Soft red - border, error
PINK=$'\033[38;5;213m'      # Soft pink - accent
MAGENTA=$'\033[38;5;177m'   # Magenta - version, separator diamond
WHITE=$'\033[38;5;255m'     # Off-white - text normal
BWHITE=$'\033[1;38;5;255m'  # Bold white - labels
GRAY=$'\033[38;5;245m'      # Light gray - subtle, secondary metrics
DGRAY=$'\033[38;5;238m'     # Dark gray - dim border
NC=$'\033[0m'               # Reset

# --- Constants ---
SCRIPT_VERSION="3.2"
REGION_CACHE="/tmp/.haxor-region"
REGION_TTL=86400  # 24 jam cache
PANEL_W=66        # panel inner width (inside │ │ border)

# ============================================================
# Helper functions
# ============================================================

# Detect region (cache ke /tmp/.haxor-region, TTL 24 jam)
get_region() {
    if [ -f "${REGION_CACHE}" ]; then
        local cache_mtime
        cache_mtime=$(stat -c %Y "${REGION_CACHE}" 2>/dev/null || echo 0)
        local now
        now=$(date +%s)
        local age=$((now - cache_mtime))
        if [ "${age}" -lt "${REGION_TTL}" ]; then
            cat "${REGION_CACHE}"
            return
        fi
    fi
    local vps_ip
    vps_ip=$(hostname -I | awk '{print $1}')
    local country
    country=$(curl -s --max-time 5 "http://ipinfo.io/${vps_ip}/country" 2>/dev/null | tr -d '[:space:]')
    local region_name="Unknown"
    case "${country}" in
        ID) region_name="Indonesia" ;;
        SG) region_name="Singapore" ;;
        US) region_name="United States" ;;
        HK) region_name="Hong Kong" ;;
        JP) region_name="Japan" ;;
        NL) region_name="Netherlands" ;;
        DE) region_name="Germany" ;;
        CA) region_name="Canada" ;;
        AU) region_name="Australia" ;;
        IN) region_name="India" ;;
        "") region_name="Unknown" ;;
        *)  region_name="${country}" ;;
    esac
    printf '%s' "${region_name}" > "${REGION_CACHE}"
    cat "${REGION_CACHE}"
}

# Render bar graph 10 blok (▮▯)
# $1 = persentase (0-100)
render_bar() {
    local pct=$1
    [ "${pct}" -gt 100 ] && pct=100
    [ "${pct}" -lt 0 ] && pct=0
    local filled=$((pct / 10))
    local empty=$((10 - filled))
    local i bar=""
    for ((i=0; i<filled; i++)); do bar="${bar}▮"; done
    for ((i=0; i<empty; i++)); do bar="${bar}▯"; done
    printf '%s' "${bar}"
}

# CPU usage snapshot (baca /proc/stat 2x dengan jeda 100ms — LESSON v46: snapshot BUKAN live)
get_cpu_usage() {
    local cpu1 cpu2
    cpu1=$(grep '^cpu ' /proc/stat)
    sleep 0.1
    cpu2=$(grep '^cpu ' /proc/stat)
    local idle1 idle2 total1=0 total2=0
    idle1=$(echo "${cpu1}" | awk '{print $5}')
    idle2=$(echo "${cpu2}" | awk '{print $5}')
    local arr1 arr2
    read -ra arr1 <<< "${cpu1}"
    read -ra arr2 <<< "${cpu2}"
    local i
    for ((i=1; i<${#arr1[@]}; i++)); do total1=$((total1 + arr1[i])); done
    for ((i=1; i<${#arr2[@]}; i++)); do total2=$((total2 + arr2[i])); done
    local total_diff=$((total2 - total1))
    local idle_diff=$((idle2 - idle1))
    [ "${total_diff}" -le 0 ] && { echo "0"; return; }
    echo $((100 * (total_diff - idle_diff) / total_diff))
}

# Status dot untuk service (● hijau aktif, ○ merah mati)
# $1 = service name (systemctl)
status_dot_service() {
    if systemctl is-active --quiet "$1" 2>/dev/null; then
        printf '%s●%s' "${GREEN}" "${NC}"
    else
        printf '%s○%s' "${RED}" "${NC}"
    fi
}

# Status dot untuk process (pgrep -x)
# $1 = process name
status_dot_process() {
    if pgrep -x "$1" >/dev/null 2>&1; then
        printf '%s●%s' "${GREEN}" "${NC}"
    else
        printf '%s○%s' "${RED}" "${NC}"
    fi
}

# Status dot untuk pattern (pgrep -f)
# $1 = pattern
status_dot_pattern() {
    if pgrep -f "$1" >/dev/null 2>&1; then
        printf '%s●%s' "${GREEN}" "${NC}"
    else
        printf '%s○%s' "${RED}" "${NC}"
    fi
}

# Pad string to fixed width (visible chars only, ignore ANSI)
# $1 = string, $2 = target width
pad_right() {
    local str="$1"
    local target="$2"
    # Strip ANSI escape sequences for length calculation
    local visible
    visible=$(printf '%s' "${str}" | sed 's/\x1b\[[0-9;]*m//g')
    local len=${#visible}
    local pad=$((target - len))
    [ "${pad}" -lt 0 ] && pad=0
    printf '%s%*s' "${str}" "${pad}" ""
}

# ============================================================
# Render functions
# ============================================================

# Render header banner (gradient cyan→biru→ungu→magenta→pink)
render_header() {
    local W=70
    local segments=5
    local seg_len=$((W / segments))
    local rem=$((W - seg_len * segments))
    local colors=(51 33 99 165 213)

    # Top gradient bar
    printf '%s' "${RED}"
    printf '╔'
    local i
    for i in 0 1 2 3 4; do
        printf '\033[48;5;%dm' "${colors[i]}"
        printf '%*s' "${seg_len}" ""
    done
    [ "${rem}" -gt 0 ] && printf '\033[48;5;%dm%*s' "${colors[4]}" "${rem}" ""
    printf '%s' "${NC}"
    printf '%s\n' "${RED}╗${NC}"

    # Empty line (black bg)
    printf '%s║%s' "${RED}" "${NC}"
    printf '%*s' "${W}" ""
    printf '%s║%s\n' "${RED}" "${NC}"

    # Brand line 1: HAXOR PANEL TUNNELING
    local brand1="HAXOR PANEL TUNNELING"
    local pad1=$(((W - ${#brand1}) / 2))
    printf '%s║%s' "${RED}" "${NC}"
    printf '%*s' "${pad1}" ""
    printf '%s%s%s' "${BWHITE}" "${brand1}" "${NC}"
    printf '%*s' "$((W - pad1 - ${#brand1}))" ""
    printf '%s║%s\n' "${RED}" "${NC}"

    # Brand line 2: DEKENG ANE BIAK BELITONG
    local brand2="DEKENG ANE BIAK BELITONG"
    local pad2=$(((W - ${#brand2}) / 2))
    printf '%s║%s' "${RED}" "${NC}"
    printf '%*s' "${pad2}" ""
    printf '%s%s%s' "${MAGENTA}" "${brand2}" "${NC}"
    printf '%*s' "$((W - pad2 - ${#brand2}))" ""
    printf '%s║%s\n' "${RED}" "${NC}"

    # Empty line
    printf '%s║%s' "${RED}" "${NC}"
    printf '%*s' "${W}" ""
    printf '%s║%s\n' "${RED}" "${NC}"

    # Bottom gradient bar
    printf '%s' "${RED}"
    printf '╚'
    for i in 0 1 2 3 4; do
        printf '\033[48;5;%dm' "${colors[i]}"
        printf '%*s' "${seg_len}" ""
    done
    [ "${rem}" -gt 0 ] && printf '\033[48;5;%dm%*s' "${colors[4]}" "${rem}" ""
    printf '%s' "${NC}"
    printf '%s╝%s\n' "${RED}" "${NC}"
}

# Render sub-header (hostname ◆ version ◆ uptime)
render_subheader() {
    local hostname_str
    hostname_str=$(hostname -s 2>/dev/null || echo "vps")
    local version_str="v${SCRIPT_VERSION}"
    local uptime_str
    uptime_str=$(uptime -p 2>/dev/null | sed 's/up //' || echo "unknown")
    printf '\n  %s%s%s %s◆%s %s%s%s %s◆%s %s%s%s\n\n' \
        "${BWHITE}" "${hostname_str}" "${NC}" \
        "${MAGENTA}" "${NC}" \
        "${MAGENTA}" "${version_str}" "${NC}" \
        "${MAGENTA}" "${NC}" \
        "${GREEN}" "${uptime_str}" "${NC}"
}

# Panel border helpers (rounded corners)
panel_top() {
    local title="$1"
    local title_len=${#title}
    local inner=$((PANEL_W - 4 - title_len))
    [ "${inner}" -lt 0 ] && inner=0
    printf '%s╭─ %s%s%s ' "${RED}" "${BWHITE}" "${title}" "${NC}"
    printf '%s' "${RED}"
    printf '%*s' "${inner}" ""
    printf '╮%s\n' "${NC}"
}

panel_bottom() {
    printf '%s╰' "${RED}"
    printf '%*s' "$((PANEL_W - 2))" ""
    printf '╯%s\n' "${NC}"
}

panel_row() {
    # $1 = label (10 chars), $2 = value (rest), $3 = optional annotation
    local label="$1"
    local value="$2"
    local annot="$3"
    printf '%s│%s %s%-9s%s %s>%s ' "${RED}" "${NC}" "${GRAY}" "${label}" "${NC}" "${CYAN}" "${NC}"
    if [ -n "${annot}" ]; then
        # Value + annotation
        printf '%s%-30s%s %s%s%s' "${WHITE}" "${value}" "${NC}" "${GRAY}" "${annot}" "${NC}"
        # Pad to fit
        local visible_len=$((12 + ${#value} + 1 + ${#annot}))
        local pad=$((PANEL_W - 4 - visible_len))
        [ "${pad}" -lt 0 ] && pad=0
        printf '%*s' "${pad}" ""
    else
        printf '%s%-50s%s' "${WHITE}" "${value}" "${NC}"
    fi
    printf '%s │%s\n' "${RED}" "${NC}"
}

# Render [ SERVER ] panel
render_server_panel() {
    local os_name
    os_name=$(grep '^PRETTY_NAME' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "Linux")
    [ -z "${os_name}" ] && os_name="Linux"
    local kernel
    kernel=$(uname -r)
    local cpu_pct
    cpu_pct=$(get_cpu_usage)
    local load
    load=$(cut -d' ' -f1-3 /proc/loadavg)
    local ram_total ram_used ram_pct
    ram_total=$(free -m | awk '/^Mem:/ {print $2}')
    ram_used=$(free -m | awk '/^Mem:/ {print $3}')
    ram_pct=$((ram_used * 100 / ram_total))
    local disk_total disk_used disk_pct
    disk_total=$(df -m / | awk 'NR==2 {print $2}')
    disk_used=$(df -m / | awk 'NR==2 {print $3}')
    disk_pct=$((disk_used * 100 / disk_total))
    local uptime_str
    uptime_str=$(uptime -p 2>/dev/null | sed 's/up //' || echo "unknown")
    local swap_total swap_used
    swap_total=$(free -m | awk '/^Swap:/ {print $2}')
    swap_used=$(free -m | awk '/^Swap:/ {print $3}')
    local now
    now=$(date '+%d %b %Y %H:%M %Z')

    panel_top "[ SERVER ]"
    panel_row "OS" "${os_name:0:50}"
    panel_row "KERNEL" "${kernel:0:50}"
    # CPU with bar graph
    printf '%s│%s %s%-9s%s %s>%s %s%-10s%s %s%3d%%%s  %sload %s%s' \
        "${RED}" "${NC}" "${GRAY}" "CPU" "${NC}" "${CYAN}" "${NC}" \
        "${GREEN}" "$(render_bar ${cpu_pct})" "${NC}" "${WHITE}" "${cpu_pct}" "${NC}" "${GRAY}" "${load}" "${NC}"
    local pad=$((PANEL_W - 4 - 12 - 10 - 4 - 7 - ${#load}))
    [ "${pad}" -lt 0 ] && pad=0
    printf '%*s' "${pad}" ""
    printf '%s │%s\n' "${RED}" "${NC}"
    # RAM with bar graph
    printf '%s│%s %s%-9s%s %s>%s %s%-10s%s %s%3d%%%s  %s%dM/%dM%s' \
        "${RED}" "${NC}" "${GRAY}" "RAM" "${NC}" "${CYAN}" "${NC}" \
        "${GREEN}" "$(render_bar ${ram_pct})" "${NC}" "${WHITE}" "${ram_pct}" "${NC}" "${GRAY}" "${ram_used}" "${ram_total}" "${NC}"
    local pad2=$((PANEL_W - 4 - 12 - 10 - 4 - 9))
    [ "${pad2}" -lt 0 ] && pad2=0
    printf '%*s' "${pad2}" ""
    printf '%s │%s\n' "${RED}" "${NC}"
    # DISK with bar graph
    printf '%s│%s %s%-9s%s %s>%s %s%-10s%s %s%3d%%%s  %s%dG/%dG%s' \
        "${RED}" "${NC}" "${GRAY}" "DISK" "${NC}" "${CYAN}" "${NC}" \
        "${GREEN}" "$(render_bar ${disk_pct})" "${NC}" "${WHITE}" "${disk_pct}" "${NC}" "${GRAY}" "$((disk_used/1024))" "$((disk_total/1024))" "${NC}"
    local pad3=$((PANEL_W - 4 - 12 - 10 - 4 - 9))
    [ "${pad3}" -lt 0 ] && pad3=0
    printf '%*s' "${pad3}" ""
    printf '%s │%s\n' "${RED}" "${NC}"
    # UPTIME
    printf '%s│%s %s%-9s%s %s>%s %s%-20s%s %sswap %dM/%dM%s' \
        "${RED}" "${NC}" "${GRAY}" "UPTIME" "${NC}" "${CYAN}" "${NC}" \
        "${WHITE}" "${uptime_str:0:20}" "${NC}" "${GRAY}" "${swap_used}" "${swap_total}" "${NC}"
    local pad4=$((PANEL_W - 4 - 12 - 20 - 12))
    [ "${pad4}" -lt 0 ] && pad4=0
    printf '%*s' "${pad4}" ""
    printf '%s │%s\n' "${RED}" "${NC}"
    # TIME
    panel_row "TIME" "${now:0:50}"
    panel_bottom
}

# Render [ NETWORK ] panel
render_network_panel() {
    local vps_ip
    vps_ip=$(hostname -I | awk '{print $1}')
    local region
    region=$(get_region)
    local domain="id.chans1st.my.id"

    panel_top "[ NETWORK ]"
    panel_row "IP" "${vps_ip}" "${region}"
    panel_row "REGION" "${region}"
    panel_row "DOMAIN" "${domain}"
    panel_bottom
}

# Render [ TRAFFIC ] panel
render_traffic_panel() {
    local today_rx="0KiB" today_tx="0KiB"
    local month_rx="0GiB" month_tx="0GiB"
    local speed_now="0 bit/s"
    if command -v vnstat >/dev/null 2>&1; then
        local line
        line=$(vnstat -i eth0 --oneline 2>/dev/null)
        if [ -n "${line}" ]; then
            # vnstat 2.x --oneline format (Ubuntu 20.04 default):
            # 1;name;date;rx_bytes;tx_bytes;rx_human;tx_human;month;month_rx_bytes;month_tx_bytes;month_rx_human;month_tx_human;...
            today_rx=$(echo "${line}" | awk -F';' '{print $6}')
            today_tx=$(echo "${line}" | awk -F';' '{print $7}')
            month_rx=$(echo "${line}" | awk -F';' '{print $11}')
            month_tx=$(echo "${line}" | awk -F';' '{print $12}')
        fi
        speed_now=$(vnstat -i eth0 --tr 2 2>/dev/null | grep -oE '[0-9.]+ [KM]?bit/s' | head -1)
        [ -z "${speed_now}" ] && speed_now="0 bit/s"
    fi
    local month_name
    month_name=$(date '+%B')

    panel_top "[ TRAFFIC ]"
    # TODAY row: show total + down arrow (rx) + up arrow (tx)
    printf '%s│%s %s%-9s%s %s>%s %s▼%-12s%s %s▲%-12s%s' \
        "${RED}" "${NC}" "${GRAY}" "TODAY" "${NC}" "${CYAN}" "${NC}" \
        "${GREEN}" "${today_rx:0:12}" "${NC}" \
        "${GREEN}" "${today_tx:0:12}" "${NC}"
    local pad=$((PANEL_W - 4 - 12 - 13 - 13))
    [ "${pad}" -lt 0 ] && pad=0
    printf '%*s' "${pad}" ""
    printf '%s │%s\n' "${RED}" "${NC}"
    # MONTH row: show month_rx + month_tx + month_name
    printf '%s│%s %s%-9s%s %s>%s %s▼%-12s%s %s▲%-12s%s %s%s%s' \
        "${RED}" "${NC}" "${GRAY}" "MONTH" "${NC}" "${CYAN}" "${NC}" \
        "${GREEN}" "${month_rx:0:12}" "${NC}" \
        "${GREEN}" "${month_tx:0:12}" "${NC}" \
        "${GRAY}" "${month_name}" "${NC}"
    local pad2=$((PANEL_W - 4 - 12 - 13 - 13 - 1 - ${#month_name}))
    [ "${pad2}" -lt 0 ] && pad2=0
    printf '%*s' "${pad2}" ""
    printf '%s │%s\n' "${RED}" "${NC}"
    # SPEED row
    panel_row "SPEED" "${speed_now:0:50}"
    panel_bottom
}

# Render [ SERVICES ] panel
render_services_panel() {
    panel_top "[ SERVICES ]"
    # Row 1: SSH DROPBEAR SSLH STUNNEL5 NGINX
    printf '%s│%s ' "${RED}" "${NC}"
    printf '%s %s%s%s  ' "$(status_dot_service ssh)" "${BWHITE}" "SSH" "${NC}"
    printf '%s %s%s%s  ' "$(status_dot_service dropbear)" "${BWHITE}" "DROPBEAR" "${NC}"
    printf '%s %s%s%s  ' "$(status_dot_service sslh)" "${BWHITE}" "SSLH" "${NC}"
    printf '%s %s%s%s  ' "$(status_dot_service stunnel5)" "${BWHITE}" "STUNNEL5" "${NC}"
    printf '%s %s%s%s' "$(status_dot_service nginx)" "${BWHITE}" "NGINX" "${NC}"
    # Pad to fit
    local content="● SSH  ● DROPBEAR  ● SSLH  ● STUNNEL5  ● NGINX"
    local visible=${#content}
    local pad=$((PANEL_W - 4 - 2 - visible - 4))
    [ "${pad}" -lt 0 ] && pad=0
    printf '%*s' "${pad}" ""
    printf ' %s│%s\n' "${RED}" "${NC}"
    # Row 2: BADVPN WS-TLS WS-NONTLS
    printf '%s│%s ' "${RED}" "${NC}"
    printf '%s %s%s%s  ' "$(status_dot_process badvpn-udpgw)" "${BWHITE}" "BADVPN" "${NC}"
    printf '%s %s%s%s  ' "$(status_dot_pattern 'python.*ws-tls')" "${BWHITE}" "WS-TLS" "${NC}"
    printf '%s %s%s%s' "$(status_dot_pattern 'python.*ws-nontls')" "${BWHITE}" "WS-NONTLS" "${NC}"
    local content2="● BADVPN  ● WS-TLS  ● WS-NONTLS"
    local visible2=${#content2}
    local pad2=$((PANEL_W - 4 - 2 - visible2 - 4))
    [ "${pad2}" -lt 0 ] && pad2=0
    printf '%*s' "${pad2}" ""
    printf ' %s│%s\n' "${RED}" "${NC}"
    # HEALTH row
    local cpu_count
    cpu_count=$(nproc)
    local ram_total_mb
    ram_total_mb=$(free -m | awk '/^Mem:/ {print $2}')
    local ram_gb
    ram_gb=$(awk "BEGIN {printf \"%.0f\", ${ram_total_mb}/1024}")
    printf '%s│%s %s%-9s%s %s>%s %sGOOD%s  %sspec %dGB / %d vCPU%s' \
        "${RED}" "${NC}" "${GRAY}" "HEALTH" "${NC}" "${CYAN}" "${NC}" \
        "${GREEN}" "${NC}" "${GRAY}" "${ram_gb}" "${cpu_count}" "${NC}"
    local health_visible="HEALTH > GOOD  spec ${ram_gb}GB / ${cpu_count} vCPU"
    local pad3=$((PANEL_W - 4 - ${#health_visible} - 2))
    [ "${pad3}" -lt 0 ] && pad3=0
    printf '%*s' "${pad3}" ""
    printf '%s │%s\n' "${RED}" "${NC}"
    panel_bottom
}

# Render [ ACCOUNTS ] strip
render_accounts_strip() {
    local ssh_count
    ssh_count=$(awk -F: '$3 >= 1000 && $3 < 65534 && $1 != "nobody" {count++} END {print count+0}' /etc/passwd)
    local dropbear_count
    dropbear_count=$(ss -tn state established 2>/dev/null | grep -E ":(109|143) " | wc -l)
    local limit_count=0
    if [ -f /etc/bw-limit/blacklist.txt ]; then
        limit_count=$(grep -v '^#' /etc/bw-limit/blacklist.txt 2>/dev/null | grep -v '^$' | wc -l)
    fi

    panel_top "[ ACCOUNTS ]"
    printf '%s│%s  %sSSH:%s %s%d user%s   %s|%s   %sDropbear:%s %s%d koneksi%s   %s|%s   %sLimit:%s %s%d user%s' \
        "${RED}" "${NC}" \
        "${BWHITE}" "${NC}" "${CYAN}" "${ssh_count}" "${NC}" \
        "${GRAY}" "${NC}" \
        "${BWHITE}" "${NC}" "${CYAN}" "${dropbear_count}" "${NC}" \
        "${GRAY}" "${NC}" \
        "${BWHITE}" "${NC}" "${CYAN}" "${limit_count}" "${NC}"
    local content="  SSH: ${ssh_count} user   |   Dropbear: ${dropbear_count} koneksi   |   Limit: ${limit_count} user"
    local pad=$((PANEL_W - 4 - ${#content}))
    [ "${pad}" -lt 0 ] && pad=0
    printf '%*s' "${pad}" ""
    printf '%s │%s\n' "${RED}" "${NC}"
    panel_bottom
}

# Render [ MAIN MENU ] box (2-kolom 9+8)
render_main_menu_box() {
    panel_top "[ MAIN MENU ]"
    # Empty line
    printf '%s│%s' "${RED}" "${NC}"
    printf '%*s' "$((PANEL_W - 2))" ""
    printf '%s│%s\n' "${RED}" "${NC}"

    local left_items=(
        "[01] SSH Account Menu"
        "[02] Restart Service"
        "[03] Backup & Restore"
        "[04] Settings"
        "[05] Cek Service"
        "[06] Reboot VPS"
        "[07] Banner Manager"
        "[08] Upgrade Dropbear"
        "[09] Update Script"
    )
    local right_items=(
        "[10] Cek RAM/CPU (htop)"
        "[11] Bandwidth VPS (bw)"
        "[12] Speedtest VPS"
        "[13] Bandwidth Per-User"
        "[14] Pantau User"
        "[15] Limit Speed"
        "[16] Clear Log"
        "[17] Clear Cache"
    )

    local col_w=30
    local i
    for i in 0 1 2 3 4 5 6 7 8; do
        local left="${YELLOW}${left_items[i]}${NC}"
        local right=""
        [ $i -lt 8 ] && right="${YELLOW}${right_items[i]}${NC}"
        local left_visible="${left_items[i]}"
        local left_pad=$((col_w - ${#left_visible}))
        [ "${left_pad}" -lt 0 ] && left_pad=0
        local right_visible=""
        [ -n "${right}" ] && right_visible="${right_items[i]}"
        local right_pad=$((col_w - ${#right_visible}))
        [ "${right_pad}" -lt 0 ] && right_pad=0
        printf '%s│%s  %b%*s  %b%*s %s│%s\n' \
            "${RED}" "${NC}" \
            "${left}" "${left_pad}" "" \
            "${right}" "${right_pad}" "" \
            "${RED}" "${NC}"
    done

    # Empty line before exit
    printf '%s│%s' "${RED}" "${NC}"
    printf '%*s' "$((PANEL_W - 2))" ""
    printf '%s│%s\n' "${RED}" "${NC}"

    # Exit row centered
    local exit_label="${YELLOW}[0X] EXIT${NC}"
    local exit_visible="[0X] EXIT"
    local exit_pad=$(((PANEL_W - 2 - ${#exit_visible}) / 2))
    [ "${exit_pad}" -lt 0 ] && exit_pad=0
    local exit_rem=$((PANEL_W - 2 - ${#exit_visible} - exit_pad))
    [ "${exit_rem}" -lt 0 ] && exit_rem=0
    printf '%s│%s' "${RED}" "${NC}"
    printf '%*s' "${exit_pad}" ""
    printf '%b' "${exit_label}"
    printf '%*s' "${exit_rem}" ""
    printf '%s│%s\n' "${RED}" "${NC}"

    panel_bottom
}

# ============================================================
# Main menu logic (re-entrant while-loop — Pattern 3)
# ============================================================

show_menu() {
    while true; do
        clear
        render_header
        render_subheader
        render_server_panel
        echo ""
        render_network_panel
        echo ""
        render_traffic_panel
        echo ""
        render_services_panel
        echo ""
        render_accounts_strip
        echo ""
        render_main_menu_box
        echo ""
        printf '  %sPilih opsi%s %s[01-17 / 0X untuk keluar]%s: ' \
            "${GRAY}" "${NC}" "${YELLOW}" "${NC}"
        local choice
        read -r choice
        handle_choice "${choice}"
    done
}

# Handle choice (case pattern konsisten LESSON v9 FIX1)
handle_choice() {
    local choice="$1"
    case "${choice}" in
        01|1) clear; maddssh; echo; read -p "${GRAY}Tekan enter untuk kembali ke menu utama...${NC}" dummy ;;
        02|2) clear; sslh-fix-reboot; echo; read -p "${GRAY}Tekan enter untuk kembali ke menu utama...${NC}" dummy ;;
        03|3) clear; mbackup; echo; read -p "${GRAY}Tekan enter untuk kembali ke menu utama...${NC}" dummy ;;
        04|4) clear; msetting; echo; read -p "${GRAY}Tekan enter untuk kembali ke menu utama...${NC}" dummy ;;
        05|5) clear; start-menu; echo; read -p "${GRAY}Tekan enter untuk kembali ke menu utama...${NC}" dummy ;;
        06|6) clear; reboot_vps ;;
        07|7) clear; banner-manager; echo; read -p "${GRAY}Tekan enter untuk kembali ke menu utama...${NC}" dummy ;;
        08|8) clear; upgrade-dropbear; echo; read -p "${GRAY}Tekan enter untuk kembali ke menu utama...${NC}" dummy ;;
        09|9) clear; getupdate; echo; read -p "${GRAY}Tekan enter untuk kembali ke menu utama...${NC}" dummy ;;
        10) clear; htop ;;
        11) clear; bw; echo; read -p "${GRAY}Tekan enter untuk kembali ke menu utama...${NC}" dummy ;;
        12) clear; speedtest-haxor; echo; read -p "${GRAY}Tekan enter untuk kembali ke menu utama...${NC}" dummy ;;
        13) clear; bw-user; echo; read -p "${GRAY}Tekan enter untuk kembali ke menu utama...${NC}" dummy ;;
        14) clear; pantau; echo; read -p "${GRAY}Tekan enter untuk kembali ke menu utama...${NC}" dummy ;;
        15) clear; bw-limit; echo; read -p "${GRAY}Tekan enter untuk kembali ke menu utama...${NC}" dummy ;;
        16) clear; clearlog; echo; read -p "${GRAY}Tekan enter untuk kembali ke menu utama...${NC}" dummy ;;
        17) clear; clearcache; echo; read -p "${GRAY}Tekan enter untuk kembali ke menu utama...${NC}" dummy ;;
        0|00|x|X|0x|0X) clear; exit_script ;;
        *)
            printf '%sOpsi tidak dikenal. Pilih 01-17 atau 0X (exit).%s\n' "${RED}" "${NC}"
            sleep 2
            ;;
    esac
}

# Reboot VPS (with confirmation + root check — Pattern 2)
reboot_vps() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "${RED}Akses ditolak. Hanya root yang dapat melakukan reboot VPS.${NC}"
        echo
        read -p "${GRAY}Tekan enter untuk kembali ke menu utama...${NC}" dummy
        return
    fi
    echo "${ORANGE}PERINGATAN: Reboot VPS akan memutus koneksi SEMUA user selama 1-3 menit.${NC}"
    echo
    read -p "${YELLOW}Yakin ingin reboot VPS? (ketik 'YA' untuk konfirmasi): ${NC}" confirm
    if [ "${confirm}" = "YA" ]; then
        echo "${GREEN}Melakukan reboot VPS...${NC}"
        sleep 2
        reboot
    else
        echo "${GRAY}Reboot dibatalkan.${NC}"
        sleep 2
    fi
}

# Exit script (with confirmation — Pattern 2)
exit_script() {
    echo
    read -p "${YELLOW}Yakin ingin keluar? (y/n): ${NC}" confirm
    if [[ "${confirm}" =~ ^[Yy]$ ]]; then
        clear
        exit 0
    fi
}

# Main entry
main() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "${RED}Script ini harus dijalankan sebagai root.${NC}"
        echo "${GRAY}Jalankan: sudo menu${NC}"
        exit 1
    fi
    show_menu
}

main "$@"
