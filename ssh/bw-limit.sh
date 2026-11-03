#!/bin/bash
# ============================================================================
# Script : bw-limit.sh
# Version : v1.0-FIX1 (Sesi 2.8-A - v27)
# Brand  : HAXOR TUNNELING
# Tagline: DEKENG ANE BIAK BELITONG
# Source : Original HAXOR wrapper - Pattern 36+37+38+39 v26
# ============================================================================
# Fungsi:
#   - Limit speed per user (blacklist manual by admin)
#   - cgroup net_cls v1 + tc HTB di lo interface (PATTERN 36+37 v26)
#   - Option B Force Reconnect (kill existing PID, reconnect 30 detik) (PATTERN 38 v26)
#   - Blacklist persistence file /etc/bw-limit/blacklist.txt
#
# Design FINAL v26:
#   P1=B (Combined limit, egress di lo) - DOWNLOAD + UPLOAD gabung
#   P2=B (Hard cap, rate=ceil, NO burst)
#   P3=C (manual input rate per user, no default)
#   P4=B (cron 2 menit + flock -n) - cron setup defer v28
#
# LESSON 48 v26: cgroup net_cls v1 set sk_classid di SOCKET CREATION TIME
#   Existing socket TIDAK update classid saat PID di-move ke cgroup
#   Solution: kill -TERM existing PID (Option B Force Reconnect) → reconnect
#   → new socket dibuat dengan sk_classid benar → shape apply
#
# LESSON 49 v26: classid format 0xAAAABBBB = tc class AAAA:BBBB
#   Convention v27+: user ke-N → classid 0x10000N = tc class 16:N
#   High 16-bit = 0x0010 = 16 (major), low 16-bit = N (minor)
#
# LESSON 50 v26: tc di interface lo (loopback) untuk shape Dropbear child
#   Packet Dropbear child peer 127.0.0.1 egress via lo (BUKAN eth0)
#
# LESSON 51 v26: cgroup net_cls assignment WORK untuk Dropbear child
#   (meskipun UID=root, cgroup based on PID BUKAN UID)
#
# LESSON 52 v26: IFB module tidak diperlukan untuk SSH tunneling proxy case
#
# Komitmen etis v21+v22+v23+v24+v25+v26 RETAINED:
#   - NO tendang/throttle SEMUA user (global cap)
#   - Throttle BOLEH untuk user blacklist (manual by admin, BUKAN auto-kick)
#   - Option B Force Reconnect = brief disconnect 30 detik untuk user blacklist
#     (BUKAN tendang semua user, hanya user yang di-blacklist)
#
# CLI Commands:
#   bw-limit                         Interactive menu (Pattern 1+3)
#   bw-limit --list                  List blacklist + status
#   bw-limit --add <user> <mbps>     Add user ke blacklist + force reconnect
#   bw-limit --remove <user>         Remove user dari blacklist
#   bw-limit --show                  Show detail tc + cgroup
#   bw-limit --watch                 Manual trigger assign new PID ke cgroup
#   bw-limit --reset                 Clear ALL (confirmation "YA")
#   bw-limit --help                  Help text
#   bw-limit --version               Version info
# ============================================================================

# --- Palette 256-color ANSI-C quoting $'...' (Pattern 5 + LESSON v6 FIX1) ---
CYAN=$'\033[38;5;51m'
TEAL=$'\033[38;5;80m'
GREEN=$'\033[38;5;46m'
YELLOW=$'\033[38;5;227m'
ORANGE=$'\033[38;5;208m'
RED=$'\033[38;5;196m'
PINK=$'\033[38;5;213m'
WHITE=$'\033[38;5;255m'
GRAY=$'\033[38;5;245m'
DGRAY=$'\033[38;5;240m'
NC=$'\033[0m'
BG_CYAN=$'\033[48;5;24m'
BG_TEAL=$'\033[48;5;30m'

# --- Constants ---
SCRIPT_VERSION="1.0-FIX1"
CONFIG_DIR="/etc/bw-limit"
BLACKLIST_FILE="${CONFIG_DIR}/blacklist.txt"
CGROUP_BASE="/sys/fs/cgroup/net_cls"
CGROUP_PREFIX="haxor_"
TC_MAJOR=16
TC_DEFAULT_CLASS_MINOR=9999
TC_DEFAULT_RATE="1000mbit"
LO_IFACE="lo"
LOG_FILE="/var/log/bw-limit.log"
# System daemon filter (NO root - admin boleh blacklist root kalau mau)
SYSTEM_USERS_FILTER="sslh daemon nobody systemd sshd www-data message syslog usbmux dnsmasq bin mail news proxy irc list gnats nobody4 udpdns ntpd messagebus"

# --- Global caches (Pattern 24 v14) ---
JOURNAL_LOG_CACHE=""
AUTH_LOG_CACHE=""

# ============================================================================
# Helper Functions
# ============================================================================

show_header() {
    clear
    echo -e "${BG_CYAN}${WHITE}"
    echo -e "+-------------------------------------------------------------------+"
    echo -e "|  BANDWIDTH LIMIT PER-USER - HAXOR TUNNELING                       |"
    echo -e "|  DEKENG ANE BIAK BELITONG                                          |"
    echo -e "+-------------------------------------------------------------------+"
    echo -e "${NC}"
    echo -e "${GRAY}cgroup net_cls v1 + tc HTB di lo + Option B Force Reconnect${NC}"
    echo -e "${GRAY}Pattern 36+37+38+39 v26 | v${SCRIPT_VERSION}${NC}"
    echo ""
}

pause() {
    echo ""
    echo -e "${GRAY}Tekan enter untuk kembali ke menu...${NC}"
    read -r dummy
}

log_msg() {
    local msg="$1"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${ts}] ${msg}" >> "$LOG_FILE" 2>/dev/null
}

# Pattern 24 v14 - Global cache untuk journalctl/auth.log (fetched 1x per script run)
fetch_journal_log() {
    if [ -z "$JOURNAL_LOG_CACHE" ]; then
        JOURNAL_LOG_CACHE=$(timeout 10 journalctl --since "24 hours ago" --no-pager 2>/dev/null | grep -E "dropbear|sshd" || true)
    fi
    echo "$JOURNAL_LOG_CACHE"
}

fetch_auth_log() {
    if [ -z "$AUTH_LOG_CACHE" ]; then
        if [ -r /var/log/auth.log ]; then
            AUTH_LOG_CACHE=$(grep -E "dropbear|sshd" /var/log/auth.log 2>/dev/null || true)
        fi
    fi
    echo "$AUTH_LOG_CACHE"
}

is_valid_user() {
    local user="$1"
    [ -z "$user" ] && return 1
    getent passwd "$user" >/dev/null 2>&1
}

is_system_user() {
    local user="$1"
    [ -z "$user" ] && return 0
    for sys_user in $SYSTEM_USERS_FILTER; do
        if [ "$user" = "$sys_user" ]; then
            return 0
        fi
    done
    return 1
}

# Pattern 19 v13 - auth.log PID matching untuk resolve Dropbear child PID per user
# Returns: space-separated list of alive Dropbear PIDs for user
resolve_dropbear_pids_for_user() {
    local user="$1"
    local pids=""
    local log_line pid
    
    # Cari di journalctl cache dulu (Pattern 24)
    local journal_cache
    journal_cache=$(fetch_journal_log)
    
    while IFS= read -r log_line; do
        [ -z "$log_line" ] && continue
        # Pattern: "dropbear[PID]: Password auth succeeded for 'USER' from IP:PORT"
        if [[ "$log_line" =~ dropbear\[([0-9]+)\]:\ Password\ auth\ succeeded\ for\ \'${user}\' ]]; then
            pid="${BASH_REMATCH[1]}"
            # Verify PID still alive + is Dropbear child
            if [ -d "/proc/${pid}" ]; then
                local args
                args=$(ps -p "$pid" -o args= 2>/dev/null)
                if [[ "$args" == *dropbear* ]]; then
                    pids="${pids}${pid} "
                fi
            fi
        fi
    done <<< "$journal_cache"
    
    # Fallback ke auth.log cache kalau journalctl kosong
    if [ -z "$pids" ]; then
        local auth_cache
        auth_cache=$(fetch_auth_log)
        while IFS= read -r log_line; do
            [ -z "$log_line" ] && continue
            if [[ "$log_line" =~ dropbear\[([0-9]+)\]:\ Password\ auth\ succeeded\ for\ \'${user}\' ]]; then
                pid="${BASH_REMATCH[1]}"
                if [ -d "/proc/${pid}" ]; then
                    local args
                    args=$(ps -p "$pid" -o args= 2>/dev/null)
                    if [[ "$args" == *dropbear* ]]; then
                        pids="${pids}${pid} "
                    fi
                fi
            fi
        done <<< "$auth_cache"
    fi
    
    # Dedup + trim
    pids=$(echo "$pids" | tr ' ' '\n' | sort -u | grep -v '^$' | tr '\n' ' ' | sed 's/ *$//')
    echo "$pids"
}

get_cgroup_name() {
    local user="$1"
    echo "${CGROUP_BASE}/${CGROUP_PREFIX}${user}"
}

# PATTERN 36 v26 - classid format 0xAAAABBBB = tc class AAAA:BBBB
# Convention: user ke-N → classid 0x10000N = tc class 16:N
# High 16-bit = 0x0010 = 16 (major), low 16-bit = N (minor, hex)
get_classid_hex() {
    local index="$1"
    printf "0x10%04x" "$index"
}

get_tc_classid() {
    local index="$1"
    printf "%d:%d" "$TC_MAJOR" "$index"
}

get_next_classid_index() {
    if [ ! -f "$BLACKLIST_FILE" ]; then
        echo 1
        return
    fi
    local max_idx=0 idx
    while IFS=: read -r _ _ idx; do
        [ -z "$idx" ] && continue
        if [ "$idx" -gt "$max_idx" ] 2>/dev/null; then
            max_idx=$idx
        fi
    done < "$BLACKLIST_FILE"
    echo $((max_idx + 1))
}

# ============================================================================
# TC Setup Functions (PATTERN 37 v26 - tc HTB root di lo interface)
# ============================================================================

# Idempotent: setup HTB root di lo if not already
setup_tc_root() {
    local current_qdisc
    current_qdisc=$(tc qdisc show dev "$LO_IFACE" 2>/dev/null | head -1)
    
    if [[ "$current_qdisc" == *"htb ${TC_MAJOR}:"* ]]; then
        return 0  # Already setup
    fi
    
    # Replace current qdisc dengan HTB root
    if ! tc qdisc replace dev "$LO_IFACE" root handle "${TC_MAJOR}:" htb 2>/dev/null; then
        echo -e "${RED}GAGAL: tc qdisc replace dev ${LO_IFACE} root handle ${TC_MAJOR}: htb${NC}"
        return 1
    fi
    
    # Add default class (1000mbit unlimited) - untuk traffic yang tidak di-mark
    if ! tc class replace dev "$LO_IFACE" parent "${TC_MAJOR}:" classid "${TC_MAJOR}:${TC_DEFAULT_CLASS_MINOR}" htb rate "${TC_DEFAULT_RATE}" ceil "${TC_DEFAULT_RATE}" 2>/dev/null; then
        echo -e "${RED}GAGAL: tc class add default${NC}"
        return 1
    fi
    
    log_msg "TC root setup: qdisc HTB ${TC_MAJOR}: + default class ${TC_MAJOR}:${TC_DEFAULT_CLASS_MINOR} (${TC_DEFAULT_RATE})"
    return 0
}

teardown_tc_root() {
    local current_qdisc
    current_qdisc=$(tc qdisc show dev "$LO_IFACE" 2>/dev/null | head -1)
    
    if [[ "$current_qdisc" != *"htb ${TC_MAJOR}:"* ]]; then
        return 0  # Not setup, nothing to teardown
    fi
    
    tc qdisc del dev "$LO_IFACE" root 2>/dev/null
    log_msg "TC root teardown: qdisc HTB ${TC_MAJOR}: removed, lo back to noqueue"
}

# ============================================================================
# cgroup Functions (PATTERN 36 v26 + LESSON 51 v26)
# ============================================================================

create_cgroup_for_user() {
    local user="$1"
    local classid_index="$2"
    local cgroup_name
    cgroup_name=$(get_cgroup_name "$user")
    local classid_hex
    classid_hex=$(get_classid_hex "$classid_index")
    
    if [ -d "$cgroup_name" ]; then
        echo -e "${YELLOW}NOTE: cgroup ${cgroup_name} sudah ada, akan reuse${NC}"
    else
        if ! mkdir "$cgroup_name" 2>/dev/null; then
            echo -e "${RED}GAGAL: mkdir ${cgroup_name}${NC}"
            return 1
        fi
    fi
    
    if ! echo "$classid_hex" > "${cgroup_name}/net_cls.classid" 2>/dev/null; then
        echo -e "${RED}GAGAL: set classid ${classid_hex}${NC}"
        rmdir "$cgroup_name" 2>/dev/null
        return 1
    fi
    
    log_msg "cgroup create: ${cgroup_name} classid=${classid_hex}"
    return 0
}

# PATTERN 39 v26 - cleanup fallback: move PID ke root cgroup sebelum rmdir
remove_cgroup_for_user() {
    local user="$1"
    local cgroup_name
    cgroup_name=$(get_cgroup_name "$user")
    
    if [ ! -d "$cgroup_name" ]; then
        return 0  # Not exists, nothing to remove
    fi
    
    # Move all PIDs ke root cgroup (PATTERN 39)
    local pid
    while IFS= read -r pid; do
        [ -z "$pid" ] && continue
        echo "$pid" > "${CGROUP_BASE}/tasks" 2>/dev/null
    done < "${cgroup_name}/tasks" 2>/dev/null
    
    # Now safe to rmdir
    if ! rmdir "$cgroup_name" 2>/dev/null; then
        echo -e "${YELLOW}WARNING: rmdir ${cgroup_name} GAGAL, mungkin masih ada PID${NC}"
        return 1
    fi
    
    log_msg "cgroup remove: ${cgroup_name}"
    return 0
}

assign_pid_to_cgroup() {
    local pid="$1"
    local user="$2"
    local cgroup_name
    cgroup_name=$(get_cgroup_name "$user")
    
    if [ ! -d "$cgroup_name" ]; then
        return 1
    fi
    
    if ! echo "$pid" > "${cgroup_name}/tasks" 2>/dev/null; then
        return 1
    fi
    
    return 0
}

is_pid_in_cgroup() {
    local pid="$1"
    local user="$2"
    local cgroup_name
    cgroup_name=$(get_cgroup_name "$user")
    
    if [ ! -d "$cgroup_name" ]; then
        return 1
    fi
    
    grep -q "^${pid}$" "${cgroup_name}/tasks" 2>/dev/null
}

# ============================================================================
# TC Class + Filter Functions (PATTERN 36 v26 - Hard cap P2=B)
# ============================================================================

add_tc_class_for_user() {
    local user="$1"
    local rate_mbps="$2"
    local classid_index="$3"
    local tc_classid
    tc_classid=$(get_tc_classid "$classid_index")
    local rate_str="${rate_mbps}mbit"
    
    # P2=B Hard cap: rate = ceil, NO burst
    if ! tc class replace dev "$LO_IFACE" parent "${TC_MAJOR}:" classid "${tc_classid}" htb rate "${rate_str}" ceil "${rate_str}" 2>/dev/null; then
        echo -e "${RED}GAGAL: tc class add ${tc_classid} rate=${rate_str}${NC}"
        return 1
    fi
    
    log_msg "tc class add: ${tc_classid} rate=${rate_str} ceil=${rate_str} (Hard cap P2=B)"
    return 0
}

remove_tc_class_for_user() {
    local classid_index="$1"
    local tc_classid
    tc_classid=$(get_tc_classid "$classid_index")
    
    tc class del dev "$LO_IFACE" classid "${tc_classid}" 2>/dev/null
    log_msg "tc class del: ${tc_classid}"
}

add_tc_filter_for_user() {
    local user="$1"
    local classid_index="$2"
    local classid_hex
    classid_hex=$(get_classid_hex "$classid_index")
    local tc_classid
    tc_classid=$(get_tc_classid "$classid_index")
    
    # Remove existing filter with same prio (idempotent)
    tc filter del dev "$LO_IFACE" parent "${TC_MAJOR}:" protocol ip prio "$classid_index" 2>/dev/null
    
    # CORRECT SYNTAX (FIX1 v27): handle BEFORE cgroup, NO flowid parameter
    # Verified via PERINTAH #8c Test 1: tc filter add ... handle HEX cgroup
    # cgroup classifier auto-routes packets to class matching the handle (classid)
    # flowid NOT supported (Test 2 GAGAL "What is flowid?")
    # handle REQUIRED (Test 3 GAGAL "Invalid argument")
    if ! tc filter add dev "$LO_IFACE" parent "${TC_MAJOR}:" protocol ip prio "$classid_index" handle "$classid_hex" cgroup 2>/dev/null; then
        echo -e "${RED}GAGAL: tc filter add cgroup handle ${classid_hex}${NC}"
        return 1
    fi
    
    log_msg "tc filter add: handle ${classid_hex} cgroup (auto-route to ${tc_classid})"
    return 0
}

remove_tc_filter_for_user() {
    local classid_index="$1"
    tc filter del dev "$LO_IFACE" parent "${TC_MAJOR}:" protocol ip prio "$classid_index" 2>/dev/null
    log_msg "tc filter del: prio ${classid_index}"
}

# ============================================================================
# Blacklist File Functions
# ============================================================================

ensure_config_dir() {
    if [ ! -d "$CONFIG_DIR" ]; then
        mkdir -p "$CONFIG_DIR"
        chmod 755 "$CONFIG_DIR"
    fi
    if [ ! -f "$BLACKLIST_FILE" ]; then
        touch "$BLACKLIST_FILE"
        chmod 644 "$BLACKLIST_FILE"
    fi
}

is_user_in_blacklist() {
    local user="$1"
    [ ! -f "$BLACKLIST_FILE" ] && return 1
    awk -F: -v u="$user" '$1 == u {found=1} END {exit !found}' "$BLACKLIST_FILE"
}

get_user_blacklist_entry() {
    local user="$1"
    [ ! -f "$BLACKLIST_FILE" ] && return 1
    grep "^${user}:" "$BLACKLIST_FILE" 2>/dev/null | head -1
}

add_user_to_blacklist() {
    local user="$1"
    local rate_mbps="$2"
    local classid_index="$3"
    ensure_config_dir
    echo "${user}:${rate_mbps}:${classid_index}" >> "$BLACKLIST_FILE"
    log_msg "blacklist add: ${user}:${rate_mbps}:${classid_index}"
}

remove_user_from_blacklist() {
    local user="$1"
    local tmp_file
    tmp_file=$(mktemp)
    if [ -f "$BLACKLIST_FILE" ]; then
        grep -v "^${user}:" "$BLACKLIST_FILE" > "$tmp_file" 2>/dev/null
        mv "$tmp_file" "$BLACKLIST_FILE"
    fi
    log_msg "blacklist remove: ${user}"
}

# ============================================================================
# CLI Commands
# ============================================================================

cmd_add() {
    local user="$1"
    local rate_mbps="$2"
    
    # Validate args
    if [ -z "$user" ] || [ -z "$rate_mbps" ]; then
        echo -e "${RED}Usage: bw-limit --add <user> <rate_mbps>${NC}"
        echo -e "${GRAY}Example: bw-limit --add anti 5${NC}"
        return 1
    fi
    
    # Validate user exists
    if ! is_valid_user "$user"; then
        echo -e "${RED}ERROR: user '${user}' TIDAK ADA di system (getent passwd fail)${NC}"
        return 1
    fi
    
    # Warn if system user (still allow, just warn)
    if is_system_user "$user"; then
        echo -e "${YELLOW}WARNING: '${user}' terdeteksi sebagai system daemon${NC}"
        read -p "$(echo -e "${YELLOW}Lanjut? (y/n): ${NC}")" confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && return 1
    fi
    
    # Validate rate_mbps (positive integer 1-1000)
    if ! [[ "$rate_mbps" =~ ^[0-9]+$ ]] || [ "$rate_mbps" -lt 1 ] || [ "$rate_mbps" -gt 1000 ]; then
        echo -e "${RED}ERROR: rate_mbps harus integer 1-1000${NC}"
        return 1
    fi
    
    # Check if already in blacklist
    if is_user_in_blacklist "$user"; then
        echo -e "${YELLOW}ERROR: user '${user}' SUDAH di blacklist${NC}"
        echo -e "${GRAY}Gunakan --remove dulu kalau mau ganti rate${NC}"
        return 1
    fi
    
    # Check prasyarat tc + cgroup
    if [ ! -d "$CGROUP_BASE" ]; then
        echo -e "${RED}ERROR: cgroup net_cls dir TIDAK ADA di ${CGROUP_BASE}${NC}"
        return 1
    fi
    if ! command -v tc >/dev/null; then
        echo -e "${RED}ERROR: tc binary TIDAK ADA${NC}"
        return 1
    fi
    
    # Allocate classid_index
    local classid_index
    classid_index=$(get_next_classid_index)
    local classid_hex
    classid_hex=$(get_classid_hex "$classid_index")
    local tc_classid
    tc_classid=$(get_tc_classid "$classid_index")
    
    echo -e "${CYAN}=== ADD USER KE BLACKLIST ===${NC}"
    echo -e "User           : ${YELLOW}${user}${NC}"
    echo -e "Rate (Hard cap): ${YELLOW}${rate_mbps} Mbps${NC} (rate=ceil, NO burst - P2=B)"
    echo -e "Classid index  : ${YELLOW}${classid_index}${NC}"
    echo -e "Classid (hex)  : ${YELLOW}${classid_hex}${NC}"
    echo -e "TC class       : ${YELLOW}${tc_classid}${NC}"
    echo -e "Cgroup dir     : ${YELLOW}$(get_cgroup_name "$user")${NC}"
    echo ""
    
    # Step 1: Setup tc HTB root di lo (idempotent - PATTERN 37)
    echo -e "${GRAY}[1/5] Setup tc HTB root di ${LO_IFACE} (PATTERN 37)...${NC}"
    if ! setup_tc_root; then
        echo -e "${RED}GAGAL setup tc root${NC}"
        return 1
    fi
    echo -e "${GREEN}OK${NC}"
    
    # Step 2: Create cgroup (LESSON 51 - PID-based, BUKAN UID-based)
    echo -e "${GRAY}[2/5] Create cgroup $(get_cgroup_name "$user") (LESSON 51)...${NC}"
    if ! create_cgroup_for_user "$user" "$classid_index"; then
        echo -e "${RED}GAGAL create cgroup${NC}"
        return 1
    fi
    echo -e "${GREEN}OK${NC}"
    
    # Step 3: Add tc class (Hard cap P2=B)
    echo -e "${GRAY}[3/5] Add tc class ${tc_classid} rate=${rate_mbps}mbit (Hard cap P2=B)...${NC}"
    if ! add_tc_class_for_user "$user" "$rate_mbps" "$classid_index"; then
        echo -e "${RED}GAGAL add tc class${NC}"
        remove_cgroup_for_user "$user"
        return 1
    fi
    echo -e "${GREEN}OK${NC}"
    
    # Step 4: Add tc filter (PATTERN 36)
    echo -e "${GRAY}[4/5] Add tc filter cgroup handle ${classid_hex} (PATTERN 36)...${NC}"
    if ! add_tc_filter_for_user "$user" "$classid_index"; then
        echo -e "${RED}GAGAL add tc filter${NC}"
        remove_tc_class_for_user "$classid_index"
        remove_cgroup_for_user "$user"
        return 1
    fi
    echo -e "${GREEN}OK${NC}"
    
    # Step 5: Add to blacklist file
    echo -e "${GRAY}[5/5] Update blacklist file ${BLACKLIST_FILE}...${NC}"
    add_user_to_blacklist "$user" "$rate_mbps" "$classid_index"
    echo -e "${GREEN}OK${NC}"
    
    echo ""
    echo -e "${CYAN}=== SETUP COMPLETE ===${NC}"
    echo ""
    
    # Resolve existing Dropbear PID for user (Pattern 19)
    local existing_pids
    existing_pids=$(resolve_dropbear_pids_for_user "$user")
    
    if [ -z "$existing_pids" ]; then
        echo -e "${YELLOW}NOTE: Tidak ada Dropbear PID aktif untuk user '${user}'${NC}"
        echo -e "${GRAY}User mungkin sedang offline. Saat user connect, jalankan:${NC}"
        echo -e "${WHITE}  bw-limit --watch${NC}"
        echo -e "${GRAY}untuk assign new PID ke cgroup.${NC}"
    else
        echo -e "${CYAN}Dropbear PID(s) untuk user '${user}': ${YELLOW}${existing_pids}${NC}"
        echo ""
        echo -e "${YELLOW}=== OPTION B FORCE RECONNECT (PATTERN 38 v26) ===${NC}"
        echo -e "${GRAY}LESSON 48 v26: cgroup net_cls v1 set sk_classid di SOCKET CREATION TIME${NC}"
        echo -e "${GRAY}Existing socket TIDAK update classid saat PID di-move ke cgroup${NC}"
        echo -e "${GRAY}Solution: kill -TERM existing PID → user reconnect 30 detik →${NC}"
        echo -e "${GRAY}new socket dibuat dengan sk_classid benar → shape apply${NC}"
        echo ""
        echo -e "${RED}User '${user}' akan diskonek sebentar (~30 detik) saat di-kill${NC}"
        read -p "$(echo -e "${YELLOW}Lanjut kill -TERM? (y/n): ${NC}")" confirm
        
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            local pid
            for pid in $existing_pids; do
                echo -e "${GRAY}Kill -TERM PID ${pid}...${NC}"
                if kill -TERM "$pid" 2>/dev/null; then
                    echo -e "${GREEN}OK${NC}"
                    log_msg "kill -TERM PID ${pid} for user ${user} (Option B Force Reconnect)"
                else
                    echo -e "${RED}GAGAL kill PID ${pid}${NC}"
                fi
            done
            echo ""
            echo -e "${CYAN}User '${user}' diskonek. Tunggu 30 detik untuk reconnect.${NC}"
            echo -e "${GRAY}Setelah reconnect, jalankan:${NC}"
            echo -e "${WHITE}  bw-limit --watch${NC}"
            echo -e "${GRAY}untuk assign new PID ke cgroup.${NC}"
            echo ""
            read -p "$(echo -e "${YELLOW}Tunggu 30 detik lalu auto-watch? (y/n): ${NC}")" auto_watch
            if [[ "$auto_watch" =~ ^[Yy]$ ]]; then
                echo -e "${GRAY}Menunggu 30 detik untuk user reconnect...${NC}"
                sleep 30
                echo ""
                cmd_watch
            fi
        else
            echo -e "${YELLOW}Kill dibatalkan. Existing PID tidak di-shape.${NC}"
            echo -e "${GRAY}Untuk apply shape, user harus disconnect + reconnect natural${NC}"
            echo -e "${GRAY}atau jalankan 'bw-limit --watch' manual setelah user reconnect.${NC}"
        fi
    fi
    
    return 0
}

cmd_remove() {
    local user="$1"
    
    if [ -z "$user" ]; then
        echo -e "${RED}Usage: bw-limit --remove <user>${NC}"
        return 1
    fi
    
    if ! is_user_in_blacklist "$user"; then
        echo -e "${YELLOW}User '${user}' TIDAK di blacklist${NC}"
        return 1
    fi
    
    # Get current entry
    local entry
    entry=$(get_user_blacklist_entry "$user")
    local rate_mbps classid_index
    rate_mbps=$(echo "$entry" | cut -d: -f2)
    classid_index=$(echo "$entry" | cut -d: -f3)
    
    echo -e "${CYAN}=== REMOVE USER FROM BLACKLIST ===${NC}"
    echo -e "User           : ${YELLOW}${user}${NC}"
    echo -e "Rate           : ${YELLOW}${rate_mbps} Mbps${NC}"
    echo -e "Classid index  : ${YELLOW}${classid_index}${NC}"
    echo ""
    
    # Step 1: Remove tc filter
    echo -e "${GRAY}[1/4] Remove tc filter prio ${classid_index}...${NC}"
    remove_tc_filter_for_user "$classid_index"
    echo -e "${GREEN}OK${NC}"
    
    # Step 2: Remove tc class
    echo -e "${GRAY}[2/4] Remove tc class 16:${classid_index}...${NC}"
    remove_tc_class_for_user "$classid_index"
    echo -e "${GREEN}OK${NC}"
    
    # Step 3: Remove cgroup (PATTERN 39 - move PID ke root dulu)
    echo -e "${GRAY}[3/4] Remove cgroup $(get_cgroup_name "$user") (PATTERN 39)...${NC}"
    remove_cgroup_for_user "$user"
    echo -e "${GREEN}OK${NC}"
    
    # Step 4: Remove from blacklist
    echo -e "${GRAY}[4/4] Update blacklist file...${NC}"
    remove_user_from_blacklist "$user"
    echo -e "${GREEN}OK${NC}"
    
    echo ""
    echo -e "${CYAN}=== REMOVE COMPLETE ===${NC}"
    echo -e "${GRAY}User '${user}' tidak di-limit lagi. Existing PID tetap connect.${NC}"
    
    log_msg "remove user: ${user} (rate=${rate_mbps}, idx=${classid_index})"
    return 0
}

cmd_list() {
    if [ ! -f "$BLACKLIST_FILE" ] || [ ! -s "$BLACKLIST_FILE" ]; then
        echo -e "${YELLOW}Blacklist kosong. Tidak ada user di-limit.${NC}"
        echo -e "${GRAY}Tambah user: bw-limit --add <user> <rate_mbps>${NC}"
        return 0
    fi
    
    echo -e "${CYAN}=== BLACKLIST STATUS ===${NC}"
    echo ""
    printf "%-15s %-12s %-12s %-10s %-15s %-10s\n" "USER" "RATE(Mbps)" "CLASSID(hex)" "TC CLASS" "CGROUP" "PID COUNT"
    printf "%-15s %-12s %-12s %-10s %-15s %-10s\n" "----" "----------" "------------" "--------" "------" "---------"
    
    local user rate idx classid_hex tc_classid cgroup_name pid_list pid_count cgroup_status
    while IFS=: read -r user rate idx; do
        [ -z "$user" ] && continue
        classid_hex=$(get_classid_hex "$idx")
        tc_classid=$(get_tc_classid "$idx")
        cgroup_name=$(get_cgroup_name "$user")
        if [ -d "$cgroup_name" ]; then
            cgroup_status="OK"
            pid_list=$(resolve_dropbear_pids_for_user "$user")
            if [ -n "$pid_list" ]; then
                pid_count=$(echo "$pid_list" | wc -w | tr -d ' ')
            else
                pid_count=0
            fi
        else
            cgroup_status="MISSING"
            pid_count="-"
        fi
        printf "%-15s %-12s %-12s %-10s %-15s %-10s\n" "$user" "$rate" "$classid_hex" "$tc_classid" "$cgroup_status" "$pid_count"
    done < "$BLACKLIST_FILE"
    
    echo ""
    local total
    total=$(wc -l < "$BLACKLIST_FILE" | tr -d ' ')
    echo -e "${GRAY}Total: ${total} user di blacklist${NC}"
}

cmd_show() {
    echo -e "${CYAN}=== BW-LIMIT DETAIL STATUS ===${NC}"
    echo ""
    
    echo -e "${YELLOW}--- TC qdisc di ${LO_IFACE} ---${NC}"
    tc qdisc show dev "$LO_IFACE" 2>/dev/null
    echo ""
    
    echo -e "${YELLOW}--- TC classes di ${LO_IFACE} ---${NC}"
    tc class show dev "$LO_IFACE" 2>/dev/null
    echo ""
    
    echo -e "${YELLOW}--- TC filters di ${LO_IFACE} ---${NC}"
    tc filter show dev "$LO_IFACE" 2>/dev/null
    echo ""
    
    echo -e "${YELLOW}--- cgroup net_cls haxor_* dirs ---${NC}"
    local found=0
    for dir in "${CGROUP_BASE}/${CGROUP_PREFIX}"*; do
        if [ -d "$dir" ]; then
            local name classid tasks
            name=$(basename "$dir")
            classid=$(cat "${dir}/net_cls.classid" 2>/dev/null)
            tasks=$(wc -l < "${dir}/tasks" 2>/dev/null | tr -d ' ')
            echo -e "  ${GREEN}${name}${NC} classid=${classid} tasks=${tasks}"
            if [ "${tasks:-0}" -gt 0 ] 2>/dev/null; then
                echo -e "    PIDs: $(tr '\n' ' ' < "${dir}/tasks" 2>/dev/null)"
            fi
            found=1
        fi
    done
    [ "$found" -eq 0 ] && echo -e "  ${GRAY}(tidak ada cgroup haxor_*)${NC}"
    echo ""
    
    echo -e "${YELLOW}--- Blacklist file (${BLACKLIST_FILE}) ---${NC}"
    if [ -f "$BLACKLIST_FILE" ] && [ -s "$BLACKLIST_FILE" ]; then
        cat "$BLACKLIST_FILE"
    else
        echo -e "  ${GRAY}(kosong atau tidak ada)${NC}"
    fi
}

cmd_watch() {
    echo -e "${CYAN}=== WATCH: Assign new Dropbear PID ke cgroup ===${NC}"
    echo ""
    
    if [ ! -f "$BLACKLIST_FILE" ] || [ ! -s "$BLACKLIST_FILE" ]; then
        echo -e "${YELLOW}Blacklist kosong. Tidak ada user untuk watch.${NC}"
        return 0
    fi
    
    local total_assigned=0
    local user rate idx pid_list pid
    
    while IFS=: read -r user rate idx; do
        [ -z "$user" ] && continue
        
        local cgroup_name
        cgroup_name=$(get_cgroup_name "$user")
        if [ ! -d "$cgroup_name" ]; then
            echo -e "${RED}SKIP: cgroup untuk '${user}' TIDAK ADA (mungkin sudah di-remove)${NC}"
            continue
        fi
        
        pid_list=$(resolve_dropbear_pids_for_user "$user")
        if [ -z "$pid_list" ]; then
            echo -e "${GRAY}User '${user}': TIDAK ada Dropbear PID aktif (offline)${NC}"
            continue
        fi
        
        local assigned=0
        for pid in $pid_list; do
            if is_pid_in_cgroup "$pid" "$user"; then
                echo -e "${GRAY}User '${user}' PID ${pid}: sudah di cgroup (skip)${NC}"
            else
                if assign_pid_to_cgroup "$pid" "$user"; then
                    echo -e "${GREEN}User '${user}' PID ${pid}: assigned ke cgroup${NC}"
                    log_msg "watch: assign PID ${pid} ke cgroup untuk user ${user}"
                    assigned=$((assigned + 1))
                    total_assigned=$((total_assigned + 1))
                else
                    echo -e "${RED}User '${user}' PID ${pid}: GAGAL assign${NC}"
                fi
            fi
        done
        
        if [ "$assigned" -eq 0 ]; then
            echo -e "${GRAY}User '${user}': tidak ada PID baru untuk assign${NC}"
        fi
    done < "$BLACKLIST_FILE"
    
    echo ""
    echo -e "${CYAN}Total assigned: ${total_assigned} PID${NC}"
    echo -e "${GRAY}Next: cron watcher (v28) akan auto-watch setiap 2 menit + flock${NC}"
}

cmd_reset() {
    echo -e "${RED}=== RESET: Clear ALL tc + cgroup + blacklist ===${NC}"
    echo ""
    echo -e "${YELLOW}PERINGATAN: Ini akan menghapus:${NC}"
    echo -e "  - Semua tc class + filter di ${LO_IFACE}"
    echo -e "  - Restore qdisc ${LO_IFACE} ke noqueue (default)"
    echo -e "  - Semua cgroup haxor_*"
    echo -e "  - Blacklist file (${BLACKLIST_FILE})"
    echo ""
    echo -e "${RED}User di blacklist akan reconnect tanpa limit setelah ini${NC}"
    echo ""
    read -p "$(echo -e "${YELLOW}Ketik 'YA' (huruf besar) untuk konfirmasi: ${NC}")" confirm
    
    if [ "$confirm" != "YA" ]; then
        echo -e "${YELLOW}Reset dibatalkan.${NC}"
        return 1
    fi
    
    echo ""
    echo -e "${GRAY}[1/4] Remove semua tc filter + class (delete qdisc root)...${NC}"
    tc qdisc del dev "$LO_IFACE" root 2>/dev/null
    echo -e "${GREEN}OK${NC}"
    
    echo -e "${GRAY}[2/4] Remove semua cgroup haxor_* (PATTERN 39)...${NC}"
    local removed=0
    for dir in "${CGROUP_BASE}/${CGROUP_PREFIX}"*; do
        if [ -d "$dir" ]; then
            # PATTERN 39: move PID ke root cgroup dulu
            local pid
            while IFS= read -r pid; do
                [ -z "$pid" ] && continue
                echo "$pid" > "${CGROUP_BASE}/tasks" 2>/dev/null
            done < "${dir}/tasks" 2>/dev/null
            rmdir "$dir" 2>/dev/null && echo -e "  ${GREEN}removed: $(basename "$dir")${NC}" || echo -e "  ${RED}GAGAL: $(basename "$dir")${NC}"
            removed=$((removed + 1))
        fi
    done
    [ "$removed" -eq 0 ] && echo -e "  ${GRAY}(tidak ada cgroup haxor_*)${NC}"
    echo -e "${GREEN}OK${NC}"
    
    echo -e "${GRAY}[3/4] Clear blacklist file...${NC}"
    ensure_config_dir
    > "$BLACKLIST_FILE"
    echo -e "${GREEN}OK${NC}"
    
    echo -e "${GRAY}[4/4] Verify clean state...${NC}"
    echo -e "  lo qdisc: $(tc qdisc show dev "$LO_IFACE" 2>/dev/null | head -1)"
    local cg_count
    cg_count=$(ls -d "${CGROUP_BASE}/${CGROUP_PREFIX}"* 2>/dev/null | wc -l | tr -d ' ')
    echo -e "  cgroup haxor_*: ${cg_count} dir"
    local bl_count
    bl_count=$(wc -l < "$BLACKLIST_FILE" 2>/dev/null | tr -d ' ')
    echo -e "  blacklist: ${bl_count} entry"
    echo -e "${GREEN}OK${NC}"
    
    echo ""
    echo -e "${CYAN}=== RESET COMPLETE ===${NC}"
    log_msg "reset: ALL tc + cgroup + blacklist cleared"
}

cmd_help() {
    show_header
    cat <<EOF
${CYAN}USAGE:${NC}
  bw-limit                         Interactive menu
  bw-limit --list                  List blacklist + status
  bw-limit --add <user> <mbps>     Add user ke blacklist + force reconnect
  bw-limit --remove <user>         Remove user dari blacklist
  bw-limit --show                  Show detail tc + cgroup
  bw-limit --watch                 Manual trigger assign new PID ke cgroup
  bw-limit --reset                 Clear ALL (confirmation "YA")
  bw-limit --help                  This help
  bw-limit --version               Version info

${CYAN}EXAMPLES:${NC}
  ${GRAY}# Add user 'anti' dengan limit 5 Mbps (hard cap, NO burst)${NC}
  bw-limit --add anti 5

  ${GRAY}# List semua user di blacklist${NC}
  bw-limit --list

  ${GRAY}# Remove user 'anti' dari blacklist${NC}
  bw-limit --remove anti

  ${GRAY}# Assign new PID ke cgroup setelah user reconnect${NC}
  bw-limit --watch

${CYAN}DESIGN (v26 FINAL):${NC}
  P1=B  Combined limit (download + upload gabung, egress di lo)
  P2=B  Hard cap (rate=ceil, NO burst)
  P3=C  Manual input rate per user (no default)
  P4=B  Cron 2 menit + flock -n (cron setup defer v28)

${CYAN}ARCHITECTURE (Pattern 36+37+38+39 v26):${NC}
  ${GRAY}- tc HTB root di lo interface (BUKAN eth0, PATTERN 37)${NC}
  ${GRAY}- cgroup net_cls v1 classid 0x10000N = tc class 16:N (PATTERN 36)${NC}
  ${GRAY}- Option B Force Reconnect: kill existing PID, reconnect 30 detik (PATTERN 38)${NC}
  ${GRAY}- cgroup cleanup: move PID ke root cgroup sebelum rmdir (PATTERN 39)${NC}

${CYAN}LIMITATION (LESSON 48 v26):${NC}
  ${GRAY}cgroup net_cls v1 set sk_classid di SOCKET CREATION TIME${NC}
  ${GRAY}Existing socket TIDAK update classid saat PID di-move ke cgroup${NC}
  ${GRAY}Solution: kill -TERM existing PID → user reconnect → new socket marked${NC}

${CYAN}FILES:${NC}
  /usr/bin/bw-limit                 Script ini
  /etc/bw-limit/blacklist.txt       Blacklist (user:rate_mbps:classid_index)
  /var/log/bw-limit.log             Event log

${CYAN}ETHICAL COMMITMENT (v21-v26 RETAINED):${NC}
  ${GRAY}- NO tendang/throttle SEMUA user (global cap)${NC}
  ${GRAY}- Throttle BOLEH untuk user blacklist (manual by admin, BUKAN auto-kick)${NC}
  ${GRAY}- Option B Force Reconnect = brief disconnect 30 detik untuk user blacklist${NC}
  ${GRAY}  (BUKAN tendang semua user, hanya user yang di-blacklist)${NC}

${CYAN}BELITONG: DEKENG ANE BIAK BELITONG${NC}
EOF
}

# ============================================================================
# Interactive Menu (Pattern 1+3 - re-entrant while-loop)
# ============================================================================

show_menu() {
    show_header
    echo -e "${CYAN}MENU:${NC}"
    echo ""
    printf "  ${YELLOW}01${NC}) List Blacklist\n"
    printf "  ${YELLOW}02${NC}) Add User ke Blacklist (force reconnect)\n"
    printf "  ${YELLOW}03${NC}) Remove User dari Blacklist\n"
    printf "  ${YELLOW}04${NC}) Show Detail (tc + cgroup)\n"
    printf "  ${YELLOW}05${NC}) Watch (assign new PID ke cgroup)\n"
    printf "  ${YELLOW}06${NC}) Reset (clear ALL)\n"
    printf "  ${YELLOW}07${NC}) Help\n"
    printf "  ${YELLOW}0X${NC}) Exit\n"
    echo ""
    read -p "$(echo -e "${GRAY}Pilih opsi [01-07 / 0X]: ${NC}")" choice
}

handle_choice() {
    local choice="$1"
    case "$choice" in
        01|1)
            clear
            cmd_list
            pause
            ;;
        02|2)
            clear
            echo -e "${CYAN}=== ADD USER KE BLACKLIST ===${NC}"
            echo ""
            read -p "$(echo -e "${GRAY}Username: ${NC}")" add_user
            read -p "$(echo -e "${GRAY}Rate (Mbps, 1-1000): ${NC}")" add_rate
            echo ""
            cmd_add "$add_user" "$add_rate"
            pause
            ;;
        03|3)
            clear
            echo -e "${CYAN}=== REMOVE USER DARI BLACKLIST ===${NC}"
            echo ""
            read -p "$(echo -e "${GRAY}Username: ${NC}")" rm_user
            echo ""
            cmd_remove "$rm_user"
            pause
            ;;
        04|4)
            clear
            cmd_show
            pause
            ;;
        05|5)
            clear
            cmd_watch
            pause
            ;;
        06|6)
            clear
            cmd_reset
            pause
            ;;
        07|7)
            clear
            cmd_help
            pause
            ;;
        0|00|x|X|0x|0X)
            clear
            exit 0
            ;;
        *)
            echo -e "${RED}Opsi tidak dikenal: ${choice}${NC}"
            echo -e "${GRAY}Pilihan valid: 01-07 atau 0X (exit)${NC}"
            sleep 2
            ;;
    esac
}

# ============================================================================
# Main Entry Point
# ============================================================================

main() {
    # Root check (cgroup + tc require root)
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}ERROR: bw-limit harus dijalankan sebagai root${NC}"
        echo -e "${GRAY}(cgroup net_cls + tc membutuhkan akses root)${NC}"
        exit 1
    fi
    
    # Parse CLI args
    case "${1:-}" in
        --list)
            cmd_list
            ;;
        --add)
            shift
            cmd_add "$@"
            ;;
        --remove)
            shift
            cmd_remove "$@"
            ;;
        --show)
            cmd_show
            ;;
        --watch)
            cmd_watch
            ;;
        --reset)
            cmd_reset
            ;;
        --help|-h)
            cmd_help
            ;;
        --version|-v)
            echo "bw-limit v${SCRIPT_VERSION} (Sesi 2.8-A - v27)"
            echo "HAXOR TUNNELING - DEKENG ANE BIAK BELITONG"
            ;;
        "")
            # Interactive menu (Pattern 1+3 - re-entrant while-loop)
            while true; do
                show_menu
                handle_choice "$choice"
            done
            ;;
        *)
            echo -e "${RED}Unknown command: ${1}${NC}"
            echo -e "${GRAY}Run 'bw-limit --help' for usage${NC}"
            exit 1
            ;;
    esac
}

main "$@"
