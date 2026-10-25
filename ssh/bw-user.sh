#!/bin/bash
# ============================================================================
# Script  : bw-user.sh
# Version : 1.0 (Sesi 2.5-A - v16)
# Purpose : Bandwidth per-user untuk SSH DIRECT (port 22) via iptables
#           accounting + Pattern 19 mapping IP→user.
#           OPSI A dari investigasi UID traffic VPS (5 PERINTAH):
#             - Port 22 (SSH direct): peer IP = IP user asli → AKURAT
#             - Port 443/8880/109/143 (tunneling): peer = Cloudfront/loopback
#               → TIDAK dihitung di sesi ini (defer OPSI B kalau perlu)
# Setup   : 1. Run `bw-user --setup` (1x) → create chain + hook + cron
#           2. Cron tiap 1 menit auto-snapshot counter
#           3. Run `bw-user` interactive atau `bw-user --display` CLI
# Source  : Original HAXOR wrapper
#           - Pattern 19 v13 (Hybrid 4-layer resolver) untuk mapping IP→user
#           - Pattern 24 v14 (Global journal cache) untuk performance
#           - Adaptasi dari pantau.sh v1.1 + tendang-safe.sh v1.2
# Brand   : HAXOR + Tagline "DEKENG ANE BIAK BELITONG"
# Usage   : bw-user                          (interactive menu, recommended)
#           bw-user --display                (CLI: tampilkan tabel bandwidth)
#           bw-user --setup                  (CLI: setup chain + cron)
#           bw-user --snap                   (CLI: cron job - snapshot counter)
#           bw-user --reset                  (CLI: reset counter + accumulation)
#           bw-user --help                   (CLI: tampilkan help)
#           bw-user --version                 (CLI: tampilkan versi)
# ============================================================================

# --- Palette 256-color (ANSI-C quoting $'...' WAJIB - Lesson FIX1 v6) ---
# Pakai ANSI-C quoting supaya byte ESC tersimpan langsung di variabel,
# sehingga warna tampil benar di echo, echo -e, read -p, dan printf.
CYAN=$'\033[38;5;51m'
TEAL=$'\033[38;5;80m'
GREEN=$'\033[38;5;46m'
YELLOW=$'\033[38;5;227m'
ORANGE=$'\033[38;5;208m'
RED=$'\033[38;5;196m'
PINK=$'\033[38;5;213m'
WHITE=$'\033[38;5;255m'
GRAY=$'\033[38;5;245m'
DGRAY=$'\033[38;5;238m'
NC=$'\033[0m'
# FIX2-A v16: Darker BG colors (was 51/80 = neon, too glaring). New: dark cyan + medium cyan
BG_CYAN=$'\033[48;5;24m'
BG_TEAL=$'\033[48;5;30m'

# --- Constants ---
SCRIPT_VERSION="1.0"
SSH_PORT="22"
CHAIN_IN="bw_user_in"
CHAIN_OUT="bw_user_out"
BANDWIDTH_DIR="/var/log/bw-user"
SNAP_FILE="${BANDWIDTH_DIR}/last-snap.log"
ACCUM_DIR="${BANDWIDTH_DIR}/accum"
CRON_FILE="/etc/cron.d/bw-user"
LOG_WINDOW="24 hours ago"

# System daemon users yang TIDAK dihitung (filter dari display)
# FIX1-B v16: Hapus "root" dari filter — root adalah admin yang valid, bandwidth root harus dihitung
# Filter hanya untuk system daemon (sslh, daemon, nobody, dll), BUKAN untuk root user login
SYSTEM_USERS_FILTER="sslh daemon nobody systemd+ sshd www-data message+ syslog usbmux dnsmasq"

# --- FIX2 v14: Global journal cache (fetched ONCE per script run) ---
# Pattern 24 v14: Fetch journalctl log 1x, reuse via grep (100x lebih cepat)
JOURNAL_LOG_CACHE=""
AUTH_LOG_CACHE=""

fetch_journal_log() {
    if [ -z "$JOURNAL_LOG_CACHE" ] && command -v journalctl >/dev/null 2>&1; then
        # Timeout 10 detik supaya tidak hang kalau journalctl lambat
        JOURNAL_LOG_CACHE=$(timeout 10 journalctl --since "$LOG_WINDOW" --no-pager -o cat 2>/dev/null)
    fi
}

fetch_auth_log() {
    if [ -z "$AUTH_LOG_CACHE" ] && [ -f /var/log/auth.log ]; then
        AUTH_LOG_CACHE=$(cat /var/log/auth.log 2>/dev/null)
    fi
}

# --- Auto-detect VPS IP (untuk safety filter, jangan hardcode) ---
detect_vps_ip() {
    local ip
    ip=$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    [ -z "$ip" ] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$ip" ] && ip="203.194.112.128"  # Fallback hardcode (info dari jembatan 16A)
    echo "$ip"
}

VPS_IP=$(detect_vps_ip)

# --- Helper: cek IP protected (127.0.0.1, VPS IP, private range) ---
is_protected_ip() {
    local ip=$1
    case "$ip" in
        127.0.0.1|0.0.0.0|::1|"") return 0 ;;
        "$VPS_IP") return 0 ;;
    esac
    case "$ip" in
        10.*) return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
        192.168.*) return 0 ;;
        169.254.*) return 0 ;;
    esac
    return 1
}

# --- Helper: format bytes ke human-readable (KB/MB/GB) ---
# Pattern 17 v12: pure bash + arithmetic (no awk, no bc, mawk-compatible)
format_bytes() {
    local bytes=$1
    if [ -z "$bytes" ] || [ "$bytes" = "0" ]; then
        echo "0 B"
        return
    fi
    local unit="B"
    local value="$bytes"
    if [ "$bytes" -ge 1073741824 ]; then
        value=$((bytes / 1073741824))
        local rem=$(( (bytes % 1073741824) * 100 / 1073741824 ))
        printf "%d.%02d GB\n" "$value" "$rem"
        return
    elif [ "$bytes" -ge 1048576 ]; then
        value=$((bytes / 1048576))
        local rem=$(( (bytes % 1048576) * 100 / 1048576 ))
        printf "%d.%02d MB\n" "$value" "$rem"
        return
    elif [ "$bytes" -ge 1024 ]; then
        value=$((bytes / 1024))
        local rem=$(( (bytes % 1024) * 100 / 1024 ))
        printf "%d.%02d KB\n" "$value" "$rem"
        return
    fi
    echo "${bytes} B"
}

# --- Helper: pause (skip kalau bukan TTY - untuk CLI automation) ---
pause() {
    if [ -t 0 ]; then
        echo
        read -rp "${GRAY}Tekan enter untuk kembali ke menu...${NC}" dummy
    fi
}

# --- Helper: show header banner ---
# Branding HAXOR + tagline BELITONG (lokasi #10 - was 9 di tendang-safe v1.2)
show_header() {
    clear
    echo -e "${BG_CYAN}                                                  ${NC}"
    echo -e "${BG_CYAN}  BANDWIDTH PER-USER - HAXOR TUNNELING             ${NC}"
    echo -e "${BG_TEAL}  DEKENG ANE BIAK BELITONG                         ${NC}"
    echo -e "${BG_CYAN}                                                  ${NC}"
    echo -e "${GRAY}  SSH Direct (port 22) only - iptables accounting${NC}"
    echo
}

# ============================================================================
# Pattern 19 v13: Hybrid 4-layer resolver (adaptasi dari pantau.sh v1.1)
# Mapping PID → username login yang sebenarnya.
# Layer 1: /proc/<pid>/loginuid (untuk SSH direct via PAM)
# Layer 2: auth.log/journalctl PID matching (untuk Dropbear via WebSocket)
# Layer 3: ps -o args= regex (untuk sshd: USER pattern)
# Layer 4: /proc/<pid>/status Uid fallback
# ============================================================================
resolve_user_from_pid() {
    local pid=$1
    if [ "$pid" = "?" ] || [ -z "$pid" ]; then
        echo "?"
        return
    fi

    # Handle race condition — cek /proc/<pid>/ exists SEBELUM ps
    if [ ! -d "/proc/$pid" ]; then
        echo "-"
        return
    fi

    # STEP 1 (PATTERN 18): /proc/<pid>/loginuid — untuk SSH direct via PAM
    if [ -r "/proc/$pid/loginuid" ]; then
        local login_uid
        login_uid=$(cat "/proc/$pid/loginuid" 2>/dev/null)
        if [ -n "$login_uid" ] && [ "$login_uid" != "-1" ] && [ "$login_uid" != "4294967295" ]; then
            if [ "$login_uid" = "0" ]; then
                echo "root"
                return
            fi
            local login_user
            login_user=$(getent passwd "$login_uid" 2>/dev/null | cut -d: -f1)
            if [ -n "$login_user" ]; then
                echo "$login_user"
                return
            fi
        fi
    fi

    # STEP 2 (PATTERN 19): auth.log/journalctl PID matching
    # Pattern 24 v14: pakai global cache (1 call per script run, 100x lebih cepat)
    fetch_journal_log
    fetch_auth_log

    local log_user=""
    # Path A: journalctl cache — grep "dropbear[PID]" atau "sshd[PID]"
    if [ -n "$JOURNAL_LOG_CACHE" ]; then
        local log_line
        log_line=$(printf '%s\n' "$JOURNAL_LOG_CACHE" | grep -E "dropbear\[$pid\]:.*Password auth succeeded" | tail -1)
        if [ -z "$log_line" ]; then
            log_line=$(printf '%s\n' "$JOURNAL_LOG_CACHE" | grep -E "sshd\[$pid\]:.*Accepted password" | tail -1)
        fi
        if [ -n "$log_line" ]; then
            if [[ $log_line =~ Password\ auth\ succeeded\ for\ \'([^\']+)\' ]]; then
                log_user="${BASH_REMATCH[1]}"
            elif [[ $log_line =~ Accepted\ password\ for\ ([a-zA-Z0-9_.-]+)\ from ]]; then
                log_user="${BASH_REMATCH[1]}"
            fi
            if [ -n "$log_user" ] && [ "$log_user" != "root" ]; then
                echo "$log_user"
                return
            fi
        fi
    fi
    # Path B: /var/log/auth.log cache fallback
    if [ -z "$log_user" ] && [ -n "$AUTH_LOG_CACHE" ]; then
        local log_line2
        log_line2=$(printf '%s\n' "$AUTH_LOG_CACHE" | grep -E "dropbear\[$pid\]:.*Password auth succeeded" | tail -1)
        if [ -z "$log_line2" ]; then
            log_line2=$(printf '%s\n' "$AUTH_LOG_CACHE" | grep -E "sshd\[$pid\]:.*Accepted password" | tail -1)
        fi
        if [ -n "$log_line2" ]; then
            if [[ $log_line2 =~ Password\ auth\ succeeded\ for\ \'([^\']+)\' ]]; then
                log_user="${BASH_REMATCH[1]}"
            elif [[ $log_line2 =~ Accepted\ password\ for\ ([a-zA-Z0-9_.-]+)\ from ]]; then
                log_user="${BASH_REMATCH[1]}"
            fi
            if [ -n "$log_user" ] && [ "$log_user" != "root" ]; then
                echo "$log_user"
                return
            fi
        fi
    fi

    # STEP 3: ps -o args= regex (untuk sshd: USER pattern)
    local args user=""
    args=$(ps -p "$pid" -o args= 2>/dev/null | head -1)
    if [ -n "$args" ]; then
        if [[ $args =~ ^sshd:\ ([a-zA-Z0-9_.-]+) ]]; then
            user="${BASH_REMATCH[1]}"
            if [ "$user" != "root" ] && [ "$user" != "system" ]; then
                echo "$user"
                return
            fi
        fi
        # Dropbear fallback: ps -o user= (process owner, BUKAN login user)
        local proc_owner
        proc_owner=$(ps -p "$pid" -o user= 2>/dev/null | head -1)
        if [ -n "$proc_owner" ] && [ "$proc_owner" != "root" ] && [ "$proc_owner" != "sshd" ] && [ "$proc_owner" != "nobody" ] && [ "$proc_owner" != "system" ]; then
            echo "$proc_owner"
            return
        fi
    fi

    # STEP 4: /proc/<pid>/status Uid fallback
    if [ -r "/proc/$pid/status" ]; then
        local status_uid
        status_uid=$(grep "^Uid:" "/proc/$pid/status" 2>/dev/null | awk '{print $2}')
        if [ -n "$status_uid" ] && [ "$status_uid" != "0" ]; then
            local status_user
            status_user=$(getent passwd "$status_uid" 2>/dev/null | cut -d: -f1)
            if [ -n "$status_user" ] && [ "$status_user" != "root" ]; then
                echo "$status_user"
                return
            fi
        fi
    fi

    echo "-"
}

# ============================================================================
# Pattern 28 (NEW v16-Sesi-2.5-A-FIX2): Resolve username by IP from auth.log
# Used when PID NOT found in current `ss` (IP disconnected/historical/scanner)
#
# Logic:
#   1. Search journalctl cache for "Accepted password for USER from IP"
#   2. Fallback to /var/log/auth.log cache
#   3. Extract username from most recent matching entry
#
# Limitation:
#   - Returns "?" untuk failed SSH attempts (no "Accepted password" log)
#   - Returns "?" untuk scanners (no auth log entry)
#   - Only works for IPs yang pernah auth sukses dalam 24 jam terakhir
# ============================================================================
resolve_user_from_ip() {
    local ip="$1"
    [ -z "$ip" ] && { echo "?"; return; }

    # Pattern 24 v14: pakai global cache (1 call per script run)
    fetch_journal_log
    fetch_auth_log

    local username=""

    # Pattern A: SSH direct port 22 - "Accepted password for USER from IP"
    # Dropbear via WS TIDAK relevant di bw-user (hanya port 22 SSH direct)
    if [ -n "$JOURNAL_LOG_CACHE" ]; then
        local match
        match=$(printf '%s\n' "$JOURNAL_LOG_CACHE" | grep -F "from $ip" | grep -E "Accepted (password|publickey) for" | tail -1)
        if [ -n "$match" ]; then
            if [[ $match =~ Accepted\ password\ for\ ([a-zA-Z0-9_.-]+)\ from ]]; then
                username="${BASH_REMATCH[1]}"
            elif [[ $match =~ Accepted\ publickey\ for\ ([a-zA-Z0-9_.-]+)\ from ]]; then
                username="${BASH_REMATCH[1]}"
            fi
        fi
    fi

    # Fallback ke /var/log/auth.log cache
    if [ -z "$username" ] && [ -n "$AUTH_LOG_CACHE" ]; then
        local match
        match=$(printf '%s\n' "$AUTH_LOG_CACHE" | grep -F "from $ip" | grep -E "Accepted (password|publickey) for" | tail -1)
        if [ -n "$match" ]; then
            if [[ $match =~ Accepted\ password\ for\ ([a-zA-Z0-9_.-]+)\ from ]]; then
                username="${BASH_REMATCH[1]}"
            elif [[ $match =~ Accepted\ publickey\ for\ ([a-zA-Z0-9_.-]+)\ from ]]; then
                username="${BASH_REMATCH[1]}"
            fi
        fi
    fi

    [ -n "$username" ] && echo "$username" || echo "?"
}

# --- Helper: get active SSH direct connections (port 22 only) ---
# Output: baris "ip|pid" per koneksi SSH direct (peer IP public, bukan protected)
# Adaptasi dari get_active_connections pantau.sh v1.1 (filter port 22 only)
get_active_ssh_connections() {
    ss -tnpH state established 2>/dev/null | while IFS= read -r line; do
        [ -z "$line" ] && continue

        # Extract PID via bash regex
        local pid="?"
        if [[ $line =~ pid=([0-9]+) ]]; then
            pid="${BASH_REMATCH[1]}"
        fi

        # Extract address tokens (Local + Peer)
        local addr_list
        addr_list=$(printf '%s\n' "$line" | awk '{
            for (i=1; i<=NF; i++) {
                if ($i ~ /:/ && $i !~ /^users:/ && $i !~ /^pid=/) {
                    print $i
                }
            }
        }')

        local local_addr peer_addr
        local_addr=$(printf '%s\n' "$addr_list" | sed -n '1p')
        peer_addr=$(printf '%s\n' "$addr_list" | sed -n '2p')
        [ -z "$local_addr" ] || [ -z "$peer_addr" ] && continue

        local local_port="${local_addr##*:}"
        local_port="${local_port%%[^0-9]*}"

        # FILTER: hanya port 22 (SSH direct)
        [ "$local_port" != "$SSH_PORT" ] && continue

        local peer_ip="${peer_addr%:*}"
        peer_ip="${peer_ip#[}"
        peer_ip="${peer_ip%]}"

        # Skip protected IP (loopback, VPS IP, private range)
        is_protected_ip "$peer_ip" && continue

        printf '%s|%s\n' "$peer_ip" "$pid"
    done
}

# --- Helper: cek apakah chain bw_user_in/bw_user_out sudah ada ---
chain_exists() {
    local chain=$1
    iptables -n -L "$chain" >/dev/null 2>&1
}

# --- Helper: cek apakah rule sudah ada di chain ---
rule_exists_in_chain() {
    local chain=$1
    local direction=$2  # "src" atau "dst"
    local ip=$3
    if [ "$direction" = "src" ]; then
        iptables -C "$chain" -s "$ip" -j RETURN 2>/dev/null
    else
        iptables -C "$chain" -d "$ip" -j RETURN 2>/dev/null
    fi
}

# --- Helper: install cron file ---
install_cron() {
    cat > "$CRON_FILE" <<EOF
# Autogenerated by bw-user v${SCRIPT_VERSION} (HAXOR Panel Tunneling)
# Cron job: snapshot iptables counter per-IP untuk SSH direct (port 22)
# Schedule: every 1 minute
* * * * * root /usr/bin/bw-user --snap >/dev/null 2>&1
EOF
    chmod 644 "$CRON_FILE"
}

# ============================================================================
# Command: --setup
# Setup chain iptables + hook rules port 22 + install cron
# Pattern: run-once dengan confirmation (mirip clearlog.sh v7, clearcache.sh v8)
# ============================================================================
cmd_setup() {
    show_header
    echo -e "${CYAN}=== SETUP BANDWIDTH PER-USER ===${NC}"
    echo
    echo -e "${WHITE}Setup akan melakukan:${NC}"
    echo -e "  ${GREEN}1.${NC} Create iptables chain ${YELLOW}${CHAIN_IN}${NC} + ${YELLOW}${CHAIN_OUT}${NC}"
    echo -e "  ${GREEN}2.${NC} Hook chain ke INPUT port ${SSH_PORT} (download counter per-IP source)"
    echo -e "  ${GREEN}3.${NC} Hook chain ke OUTPUT port ${SSH_PORT} (upload counter per-IP dest)"
    echo -e "  ${GREEN}4.${NC} Seed rules untuk IP SSH aktif saat ini"
    echo -e "  ${GREEN}5.${NC} Create directory ${YELLOW}${BANDWIDTH_DIR}${NC}"
    echo -e "  ${GREEN}6.${NC} Install cron job ${YELLOW}${CRON_FILE}${NC} (setiap 1 menit)"
    echo
    echo -e "${YELLOW}Limitation:${NC}"
    echo -e "  ${GRAY}- Hanya SSH direct (port 22) yang dihitung${NC}"
    echo -e "  ${GRAY}- Tunneling path (Cloudfront port 443, WS port 8880, Dropbear port 109/143)${NC}"
    echo -e "    ${GRAY}TIDAK dihitung (peer IP = Cloudfront/loopback, BUKAN IP user asli)${NC}"
    echo -e "  ${GRAY}- Untuk tunneling path, perlu OPSI B (HYBRID dengan /proc/<pid>/io)${NC}"
    echo
    echo -e "${RED}Prasyarat:${NC}"
    echo -e "  ${GRAY}- Akses root (iptables butuh CAP_NET_ADMIN)${NC}"
    echo -e "  ${GRAY}- Command iptables tersedia (default Ubuntu 20.04)${NC}"
    echo -e "  ${GRAY}- Cron service aktif (systemctl status cron)${NC}"
    echo

    # Validasi command -v (Pattern 6 v6)
    if ! command -v iptables >/dev/null 2>&1; then
        echo -e "${RED}ERROR: command 'iptables' tidak ditemukan.${NC}"
        echo -e "${GRAY}Install: apt install iptables${NC}"
        pause
        return 1
    fi
    if ! command -v ss >/dev/null 2>&1; then
        echo -e "${RED}ERROR: command 'ss' tidak ditemukan.${NC}"
        echo -e "${GRAY}Install: apt install iproute2${NC}"
        pause
        return 1
    fi
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}ERROR: Setup butuh akses root.${NC}"
        echo -e "${GRAY}Run: sudo bw-user --setup${NC}"
        pause
        return 1
    fi

    echo -e "${YELLOW}[?] Lanjut setup? (y/n): ${NC}"
    read -rp "" confirm
    echo
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo -e "${GRAY}Setup dibatalkan.${NC}"
        pause
        return 1
    fi

    # STEP 1: Create chain (idempotent — kalau sudah ada, skip)
    if chain_exists "$CHAIN_IN"; then
        echo -e "${YELLOW}[SKIP]${NC} Chain ${CYAN}${CHAIN_IN}${NC} sudah ada"
    else
        iptables -N "$CHAIN_IN" 2>/dev/null
        echo -e "${GREEN}[OK]${NC} Chain ${CYAN}${CHAIN_IN}${NC} created"
    fi
    if chain_exists "$CHAIN_OUT"; then
        echo -e "${YELLOW}[SKIP]${NC} Chain ${CYAN}${CHAIN_OUT}${NC} sudah ada"
    else
        iptables -N "$CHAIN_OUT" 2>/dev/null
        echo -e "${GREEN}[OK]${NC} Chain ${CYAN}${CHAIN_OUT}${NC} created"
    fi

    # STEP 2: Hook chain ke INPUT port 22 (idempotent)
    # Hook rule: jump to bw_user_in if dport 22
    if iptables -C INPUT -p tcp --dport "$SSH_PORT" -j "$CHAIN_IN" 2>/dev/null; then
        echo -e "${YELLOW}[SKIP]${NC} Hook INPUT port 22 sudah ada"
    else
        iptables -I INPUT -p tcp --dport "$SSH_PORT" -j "$CHAIN_IN" 2>/dev/null
        echo -e "${GREEN}[OK]${NC} Hook INPUT port 22 → ${CYAN}${CHAIN_IN}${NC}"
    fi
    if iptables -C OUTPUT -p tcp --sport "$SSH_PORT" -j "$CHAIN_OUT" 2>/dev/null; then
        echo -e "${YELLOW}[SKIP]${NC} Hook OUTPUT port 22 sudah ada"
    else
        iptables -I OUTPUT -p tcp --sport "$SSH_PORT" -j "$CHAIN_OUT" 2>/dev/null
        echo -e "${GREEN}[OK]${NC} Hook OUTPUT port 22 → ${CYAN}${CHAIN_OUT}${NC}"
    fi

    # STEP 3: Create directory
    mkdir -p "$BANDWIDTH_DIR" "$ACCUM_DIR"
    echo -e "${GREEN}[OK]${NC} Directory ${CYAN}${BANDWIDTH_DIR}${NC} created"

    # STEP 4: Seed rules untuk IP SSH aktif saat ini
    local active_count=0
    local seed_list
    seed_list=$(get_active_ssh_connections)
    if [ -n "$seed_list" ]; then
        while IFS='|' read -r ip pid; do
            [ -z "$ip" ] && continue
            if ! rule_exists_in_chain "$CHAIN_IN" "src" "$ip"; then
                iptables -A "$CHAIN_IN" -s "$ip" -j RETURN 2>/dev/null
            fi
            if ! rule_exists_in_chain "$CHAIN_OUT" "dst" "$ip"; then
                iptables -A "$CHAIN_OUT" -d "$ip" -j RETURN 2>/dev/null
            fi
            active_count=$((active_count + 1))
        done <<< "$seed_list"
    fi
    echo -e "${GREEN}[OK]${NC} Seed rules untuk ${YELLOW}${active_count}${NC} IP SSH aktif"

    # STEP 5: Install cron
    install_cron
    echo -e "${GREEN}[OK]${NC} Cron ${CYAN}${CRON_FILE}${NC} installed (every 1 min)"

    # STEP 6: Save iptables (persistence kalau VPS reboot)
    if command -v iptables-save >/dev/null 2>&1; then
        iptables-save > /etc/iptables.rules 2>/dev/null && \
            echo -e "${GREEN}[OK]${NC} Iptables saved to ${CYAN}/etc/iptables.rules${NC}" || \
            echo -e "${YELLOW}[WARN]${NC} iptables-save failed (non-blocking)"
    fi

    echo
    echo -e "${GREEN}=== SETUP SELESAI ===${NC}"
    echo -e "${GRAY}Cron akan auto-snapshot counter tiap 1 menit.${NC}"
    echo -e "${GRAY}Run ${CYAN}bw-user${NC} (tanpa argumen) untuk interactive menu.${NC}"
    echo -e "${GRAY}Run ${CYAN}bw-user --display${NC} untuk CLI display.${NC}"
    pause
}

# ============================================================================
# Command: --snap
# Cron job: scan ss, add rules untuk IP baru, snapshot counter ke file
# Pattern 24 v14: fetch journalctl 1x per script run (kalau resolve user)
# Note: TIDAK resolve user di snap (cron, performance), hanya simpan counter per-IP
# ============================================================================
cmd_snap() {
    # Validasi command
    command -v iptables >/dev/null 2>&1 || return 1
    command -v ss >/dev/null 2>&1 || return 1

    # Pastikan chain ada (auto-recover kalau VPS reboot)
    if ! chain_exists "$CHAIN_IN" || ! chain_exists "$CHAIN_OUT"; then
        # Auto-recover: re-create chain + hook (idempotent setup)
        chain_exists "$CHAIN_IN" || iptables -N "$CHAIN_IN" 2>/dev/null
        chain_exists "$CHAIN_OUT" || iptables -N "$CHAIN_OUT" 2>/dev/null
        iptables -C INPUT -p tcp --dport "$SSH_PORT" -j "$CHAIN_IN" 2>/dev/null || \
            iptables -I INPUT -p tcp --dport "$SSH_PORT" -j "$CHAIN_IN" 2>/dev/null
        iptables -C OUTPUT -p tcp --sport "$SSH_PORT" -j "$CHAIN_OUT" 2>/dev/null || \
            iptables -I OUTPUT -p tcp --sport "$SSH_PORT" -j "$CHAIN_OUT" 2>/dev/null
    fi

    mkdir -p "$BANDWIDTH_DIR" "$ACCUM_DIR"

    # Get active SSH connections
    local active_list
    active_list=$(get_active_ssh_connections)
    local active_ips=""
    if [ -n "$active_list" ]; then
        while IFS='|' read -r ip pid; do
            [ -z "$ip" ] && continue
            active_ips="${active_ips}${ip}|"
            # Add rule untuk IP baru (idempotent)
            if ! rule_exists_in_chain "$CHAIN_IN" "src" "$ip"; then
                iptables -A "$CHAIN_IN" -s "$ip" -j RETURN 2>/dev/null
            fi
            if ! rule_exists_in_chain "$CHAIN_OUT" "dst" "$ip"; then
                iptables -A "$CHAIN_OUT" -d "$ip" -j RETURN 2>/dev/null
            fi
        done <<< "$active_list"
    fi

    # Snapshot counter dari iptables untuk SEMUA rule yang ada di chain
    # Format snap file: timestamp|ip|in_bytes|out_bytes
    local snap_ts
    snap_ts=$(date +%s)
    : > "$SNAP_FILE.tmp"

    # Read INPUT chain counters
    # Output iptables -L -v -n -x: pkts bytes target prot opt in out source destination
    # Rule RETURN dengan source IP = per-IP counter
    iptables -L "$CHAIN_IN" -v -n -x 2>/dev/null | awk '
        /^ *[0-9]+ +[0-9]+ +RETURN/ {
            # Field 8 = source IP (kalau bukan 0.0.0.0/0)
            if ($8 != "0.0.0.0/0" && $8 != "") {
                print $8 "|" $2
            }
        }
    ' | while IFS='|' read -r ip in_bytes; do
        # Find matching out_bytes from OUTPUT chain
        # FIX1-A v16: OUTPUT chain pakai $9 (destination IP), BUKAN $8 (source = 0.0.0.0/0)
        # Format OUTPUT: pkts bytes target prot opt in out source destination
        # Rule ditambahkan dengan -d <ip> jadi destination = IP user
        local out_bytes=0
        out_bytes=$(iptables -L "$CHAIN_OUT" -v -n -x 2>/dev/null | awk -v ip="$ip" '
            /^ *[0-9]+ +[0-9]+ +RETURN/ {
                if ($9 == ip) print $2
            }
        ' | head -1)
        out_bytes=${out_bytes:-0}
        echo "${snap_ts}|${ip}|${in_bytes}|${out_bytes}" >> "$SNAP_FILE.tmp"
    done

    # Atomic move
    mv "$SNAP_FILE.tmp" "$SNAP_FILE"

    # Save iptables (persistence)
    command -v iptables-save >/dev/null 2>&1 && iptables-save > /etc/iptables.rules 2>/dev/null
}

# ============================================================================
# Command: --display
# Tampilkan tabel bandwidth per-user (map IP → user via Pattern 19)
# Source: live counter dari iptables + accumulation file (untuk IP yang disconnect)
# ============================================================================
cmd_display() {
    show_header
    echo -e "${CYAN}=== BANDWIDTH PER-USER (SSH DIRECT PORT 22) ===${NC}"
    echo

    # Validasi chain ada
    if ! chain_exists "$CHAIN_IN" 2>/dev/null; then
        echo -e "${YELLOW}[!] Chain ${CHAIN_IN} belum ada.${NC}"
        echo -e "${GRAY}    Run ${CYAN}bw-user --setup${NC}${GRAY} dulu untuk inisialisasi.${NC}"
        echo
        pause
        return 1
    fi

    # Pastikan snap file up-to-date (jalankan snap inline kalau >60 detik lalu)
    if [ -f "$SNAP_FILE" ]; then
        local snap_age=9999
        local now_ts file_ts
        now_ts=$(date +%s)
        file_ts=$(stat -c %Y "$SNAP_FILE" 2>/dev/null || echo 0)
        snap_age=$((now_ts - file_ts))
        if [ "$snap_age" -gt 60 ]; then
            # Snap file stale (>60s), run snap inline
            cmd_snap 2>/dev/null
        fi
    else
        # Snap file belum ada, run snap inline
        cmd_snap 2>/dev/null
    fi

    # Read snap file (live counter per-IP)
    local user_data=""
    declare -A ip_to_user  # Associative array: ip → username
    declare -A ip_in_bytes
    declare -A ip_out_bytes

    if [ -f "$SNAP_FILE" ]; then
        while IFS='|' read -r ts ip in_bytes out_bytes; do
            [ -z "$ip" ] && continue
            # Resolve PID dari ss untuk SSH direct port 22 dengan peer IP target
            # Filter ss hanya untuk port 22 (sport = :22) supaya tidak match IP di port lain
            local pid_resolved
            pid_resolved=$(ss -tnpH state established "( sport = :$SSH_PORT )" 2>/dev/null | \
                grep -F " $ip:" | grep -oP 'pid=\K[0-9]+' | head -1)
            [ -z "$pid_resolved" ] && pid_resolved="?"

            # Resolve user: Pattern 19 (by PID) jika aktif, fallback Pattern 28 (by IP dari auth.log)
            # FIX2-B v16: Kalau PID tidak ada di current ss (disconnected/historical),
            # resolve username via auth.log by IP
            local username
            if [ "$pid_resolved" = "?" ]; then
                username=$(resolve_user_from_ip "$ip")
            else
                username=$(resolve_user_from_pid "$pid_resolved")
            fi
            [ -z "$username" ] && username="-"

            # Skip system daemon users (sslh, daemon, dll) — root TIDAK difilter (admin valid, FIX1-B v16)
            local is_system=0
            for sys_user in $SYSTEM_USERS_FILTER; do
                if [ "$username" = "$sys_user" ]; then
                    is_system=1
                    break
                fi
            done
            [ "$is_system" -eq 1 ] && continue

            # Accumulate per-IP (kalau ada multiple PID untuk IP yang sama, sum)
            ip_to_user["$ip"]="$username"
            ip_in_bytes["$ip"]=$(( ${ip_in_bytes["$ip"]:-0} + ${in_bytes:-0} ))
            ip_out_bytes["$ip"]=$(( ${ip_out_bytes["$ip"]:-0} + ${out_bytes:-0} ))
        done < "$SNAP_FILE"
    fi

    # Display table
    if [ ${#ip_to_user[@]} -eq 0 ]; then
        echo -e "${YELLOW}Belum ada data bandwidth.${NC}"
        echo -e "${GRAY}Pastikan:${NC}"
        echo -e "  ${GRAY}- Setup sudah dijalankan (bw-user --setup)${NC}"
        echo -e "  ${GRAY}- Ada user SSH direct (port 22) yang aktif${NC}"
        echo -e "  ${GRAY}- Cron berjalan (cek /etc/cron.d/bw-user)${NC}"
        echo
        pause
        return 0
    fi

    # Header table
    echo -e "${WHITE}USERNAME        IP                    DOWN         UP           TOTAL${NC}"
    echo -e "${DGRAY}─────────────   ───────────────────   ──────────   ──────────   ──────────${NC}"

    # Sort by total bytes DESC, display
    local total_in=0
    local total_out=0
    local user_count=0

    # Build sortable output (raw bytes|username|ip|in|out)
    local sort_data=""
    for ip in "${!ip_to_user[@]}"; do
        local in_b=${ip_in_bytes["$ip"]:-0}
        local out_b=${ip_out_bytes["$ip"]:-0}
        local total_b=$((in_b + out_b))
        sort_data="${sort_data}${total_b}|${ip_to_user[$ip]}|${ip}|${in_b}|${out_b}
"
        total_in=$((total_in + in_b))
        total_out=$((total_out + out_b))
        user_count=$((user_count + 1))
    done

    # Sort DESC by total bytes (column 1)
    printf '%s' "$sort_data" | sort -t'|' -k1,1nr | while IFS='|' read -r total_b username ip in_b out_b; do
        [ -z "$total_b" ] && continue
        local down_str up_str total_str
        down_str=$(format_bytes "$in_b")
        up_str=$(format_bytes "$out_b")
        total_str=$(format_bytes "$total_b")
        # Pad columns (Pattern 17 v12: plain text, no ANSI in printf %s untuk alignment)
        printf "%-14s  %-20s  %-11s  %-11s  %-11s\n" \
            "$username" "$ip" "$down_str" "$up_str" "$total_str"
    done

    # Footer
    echo -e "${DGRAY}─────────────   ───────────────────   ──────────   ──────────   ──────────${NC}"
    local total_in_str total_out_str total_all_str
    total_in_str=$(format_bytes "$total_in")
    total_out_str=$(format_bytes "$total_out")
    total_all_str=$(format_bytes "$((total_in + total_out))")
    printf "${YELLOW}%-14s  %-20s  %-11s  %-11s  %-11s${NC}\n" \
        "TOTAL" "(${user_count} user)" "$total_in_str" "$total_out_str" "$total_all_str"

    echo
    echo -e "${GRAY}Limitation: Hanya SSH direct (port 22).${NC}"
    echo -e "${GRAY}Tunneling path (Cloudfront/WS/Dropbear) TIDAK dihitung.${NC}"
    echo -e "${GRAY}Counter di-reset saat VPS reboot. Cron tiap 1 menit auto-snapshot.${NC}"
    echo
    pause
}

# ============================================================================
# Command: --reset
# Clear all iptables rules di chain + accumulation file
# ============================================================================
cmd_reset() {
    show_header
    echo -e "${RED}=== RESET BANDWIDTH COUNTER ===${NC}"
    echo
    echo -e "${YELLOW}Reset akan:${NC}"
    echo -e "  ${RED}1.${NC} Hapus SEMUA rule di chain ${CYAN}${CHAIN_IN}${NC} + ${CYAN}${CHAIN_OUT}${NC}"
    echo -e "  ${RED}2.${NC} Hapus snap file ${CYAN}${SNAP_FILE}${NC}"
    echo -e "  ${RED}3.${NC} Hapus accumulation dir ${CYAN}${ACCUM_DIR}${NC}"
    echo -e "  ${RED}4.${NC} Hapus cron file ${CYAN}${CRON_FILE}${NC}"
    echo -e "  ${RED}5.${NC} Hook INPUT/OUTPUT port 22 di-unhook (chain tetap ada, kosong)"
    echo
    echo -e "${RED}PERINGATAN: Semua counter bandwidth per-IP akan hilang!${NC}"
    echo -e "${GRAY}Reset tidak menghapus user SSH, hanya statistik bandwidth.${NC}"
    echo

    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}ERROR: Reset butuh akses root.${NC}"
        echo -e "${GRAY}Run: sudo bw-user --reset${NC}"
        pause
        return 1
    fi

    echo -e "${YELLOW}[?] Yakin ingin reset? Ketik 'YA' (huruf besar): ${NC}"
    read -rp "" confirm
    echo
    if [ "$confirm" != "YA" ]; then
        echo -e "${GRAY}Reset dibatalkan.${NC}"
        pause
        return 1
    fi

    # STEP 1: Flush rules di chain
    if chain_exists "$CHAIN_IN"; then
        iptables -F "$CHAIN_IN" 2>/dev/null
        echo -e "${GREEN}[OK]${NC} Chain ${CYAN}${CHAIN_IN}${NC} flushed"
    fi
    if chain_exists "$CHAIN_OUT"; then
        iptables -F "$CHAIN_OUT" 2>/dev/null
        echo -e "${GREEN}[OK]${NC} Chain ${CYAN}${CHAIN_OUT}${NC} flushed"
    fi

    # STEP 2: Unhook chain dari INPUT/OUTPUT
    while iptables -C INPUT -p tcp --dport "$SSH_PORT" -j "$CHAIN_IN" 2>/dev/null; do
        iptables -D INPUT -p tcp --dport "$SSH_PORT" -j "$CHAIN_IN" 2>/dev/null
    done
    while iptables -C OUTPUT -p tcp --sport "$SSH_PORT" -j "$CHAIN_OUT" 2>/dev/null; do
        iptables -D OUTPUT -p tcp --sport "$SSH_PORT" -j "$CHAIN_OUT" 2>/dev/null
    done
    echo -e "${GREEN}[OK]${NC} Hook INPUT/OUTPUT port 22 di-unhook"

    # STEP 3: Hapus chain (kalau kosong)
    iptables -X "$CHAIN_IN" 2>/dev/null && echo -e "${GREEN}[OK]${NC} Chain ${CYAN}${CHAIN_IN}${NC} deleted"
    iptables -X "$CHAIN_OUT" 2>/dev/null && echo -e "${GREEN}[OK]${NC} Chain ${CYAN}${CHAIN_OUT}${NC} deleted"

    # STEP 4: Hapus snap file + accum dir
    rm -f "$SNAP_FILE" 2>/dev/null && echo -e "${GREEN}[OK]${NC} Snap file dihapus"
    rm -rf "$ACCUM_DIR" 2>/dev/null && echo -e "${GREEN}[OK]${NC} Accumulation dir dihapus"

    # STEP 5: Hapus cron file
    rm -f "$CRON_FILE" 2>/dev/null && echo -e "${GREEN}[OK]${NC} Cron file dihapus"

    # STEP 6: Save iptables (persistence)
    command -v iptables-save >/dev/null 2>&1 && iptables-save > /etc/iptables.rules 2>/dev/null

    echo
    echo -e "${GREEN}=== RESET SELESAI ===${NC}"
    echo -e "${GRAY}Run ${CYAN}bw-user --setup${NC}${GRAY} untuk setup ulang.${NC}"
    pause
}

# ============================================================================
# Command: --help
# ============================================================================
cmd_help() {
    show_header
    echo -e "${CYAN}=== HELP - BANDWIDTH PER-USER ===${NC}"
    echo
    echo -e "${WHITE}DESKRIPSI:${NC}"
    echo -e "  ${GRAY}Bandwidth per-user untuk SSH direct (port 22) via iptables accounting.${NC}"
    echo -e "  ${GRAY}Counter di-snapshot tiap 1 menit via cron, IP → user via Pattern 19.${NC}"
    echo
    echo -e "${WHITE}MENU OPSI (interactive):${NC}"
    echo -e "  ${YELLOW}01${NC}  Display bandwidth per-user"
    echo -e "  ${YELLOW}02${NC}  Setup (chain + cron + seed)"
    echo -e "  ${YELLOW}03${NC}  Snapshot manual (run cron logic now)"
    echo -e "  ${YELLOW}04${NC}  Reset counter + accumulation"
    echo -e "  ${YELLOW}05${NC}  Help"
    echo -e "  ${YELLOW}0X${NC}  Exit ke menu utama HAXOR"
    echo
    echo -e "${WHITE}CLI FLAGS:${NC}"
    echo -e "  ${CYAN}--display${NC}     Tampilkan tabel bandwidth"
    echo -e "  ${CYAN}--setup${NC}       Setup chain + cron"
    echo -e "  ${CYAN}--snap${NC}        Cron job - snapshot counter"
    echo -e "  ${CYAN}--reset${NC}       Reset counter + accumulation"
    echo -e "  ${CYAN}--help${NC}        Tampilkan help ini"
    echo -e "  ${CYAN}--version${NC}     Tampilkan versi"
    echo
    echo -e "${WHITE}LIMITATION:${NC}"
    echo -e "  ${YELLOW}Hanya SSH direct (port 22) yang dihitung.${NC}"
    echo -e "  ${GRAY}Tunneling path TIDAK dihitung (peer IP = Cloudfront/loopback):${NC}"
    echo -e "    ${GRAY}- Cloudfront port 443 (peer = 52.46.55.x AWS edge)${NC}"
    echo -e "    ${GRAY}- WebSocket NonTLS port 8880 (peer = 127.0.0.1)${NC}"
    echo -e "    ${GRAY}- Dropbear port 109/143 (peer = 127.0.0.1)${NC}"
    echo -e "  ${GRAY}Untuk tunneling path, perlu OPSI B (HYBRID dengan /proc/<pid>/io).${NC}"
    echo
    echo -e "${WHITE}FLOW:${NC}"
    echo -e "  ${GREEN}1.${NC} Run ${CYAN}bw-user --setup${NC} (1x, butuh root)"
    echo -e "  ${GREEN}2.${NC} Cron auto-snapshot tiap 1 menit"
    echo -e "  ${GREEN}3.${NC} Run ${CYAN}bw-user${NC} (interactive) atau ${CYAN}bw-user --display${NC}"
    echo
    echo -e "${WHITE}FILES:${NC}"
    echo -e "  ${CYAN}/usr/bin/bw-user${NC}              Script ini"
    echo -e "  ${CYAN}${CRON_FILE}${NC}      Cron schedule (every 1 min)"
    echo -e "  ${CYAN}${SNAP_FILE}${NC}      Last snapshot (timestamp|ip|in|out)"
    echo -e "  ${CYAN}${BANDWIDTH_DIR}/${NC}              Directory root"
    echo
    echo -e "${WHITE}PATTERN:${NC}"
    echo -e "  ${GRAY}Pattern 1 (re-entrant show_menu) untuk opsi 01-05${NC}"
    echo -e "  ${GRAY}Pattern 3 (re-entrant while-loop) untuk root menu${NC}"
    echo -e "  ${GRAY}Pattern 4 (pause prompt) untuk external submenu${NC}"
    echo -e "  ${GRAY}Pattern 5 (palette 256-color ANSI-C quoting)${NC}"
    echo -e "  ${GRAY}Pattern 6 (validasi command -v) untuk iptables, ss, journalctl${NC}"
    echo -e "  ${GRAY}Pattern 7 (exit 0X → menu)${NC}"
    echo -e "  ${GRAY}Pattern 8 (NO license check, NO bot integration)${NC}"
    echo -e "  ${GRAY}Pattern 9 (branding HAXOR + BELITONG)${NC}"
    echo -e "  ${GRAY}Pattern 15 (Safe append ke worklog.md)${NC}"
    echo -e "  ${GRAY}Pattern 17 (Plain text untuk kolom tabel alignment)${NC}"
    echo -e "  ${GRAY}Pattern 19 (auth.log PID matching untuk resolve user)${NC}"
    echo -e "  ${GRAY}Pattern 20 (Hybrid 4-layer resolver)${NC}"
    echo -e "  ${GRAY}Pattern 24 (Global journal cache untuk performance)${NC}"
    echo -e "  ${GRAY}Pattern 28 (resolve user by IP - fallback untuk IP disconnected)${NC}"
    echo
    pause
}

# ============================================================================
# Show menu (re-entrant while-loop - Pattern 3 v9)
# ============================================================================
show_menu() {
    while true; do
        show_header
        echo -e "${CYAN}=== MENU BANDWIDTH PER-USER ===${NC}"
        echo
        echo -e "  ${YELLOW}01${NC}  Display bandwidth per-user"
        echo -e "  ${YELLOW}02${NC}  Setup (chain + cron + seed) ${GRAY}[1x run]${NC}"
        echo -e "  ${YELLOW}03${NC}  Snapshot manual (run cron logic now)"
        echo -e "  ${YELLOW}04${NC}  Reset counter + accumulation ${GRAY}[destructive]${NC}"
        echo -e "  ${YELLOW}05${NC}  Help"
        echo
        echo -e "  ${YELLOW}0X${NC}  Exit ke menu utama HAXOR"
        echo
        read -rp "${GRAY}Pilih opsi [01-05 / 0X]: ${NC}" choice
        case "$choice" in
            01|1) cmd_display ;;
            02|2) cmd_setup ;;
            03|3) cmd_snap; echo; echo -e "${GREEN}[OK]${NC} Snapshot selesai"; pause ;;
            04|4) cmd_reset ;;
            05|5) cmd_help ;;
            0|00|x|X|0x|0X) clear; return 0 ;;
            *) echo -e "${RED}Opsi tidak dikenal. Pilih [01-05 atau 0X]${NC}"; sleep 2 ;;
        esac
    done
}

# ============================================================================
# Main: dispatch CLI args atau interactive menu
# ============================================================================
main() {
    case "${1:-}" in
        --display)    cmd_display; exit 0 ;;
        --setup)      cmd_setup; exit 0 ;;
        --snap)       cmd_snap; exit 0 ;;
        --reset)      cmd_reset; exit 0 ;;
        --help|-h)    cmd_help; exit 0 ;;
        --version|-v) echo "bw-user v${SCRIPT_VERSION} (HAXOR Panel Tunneling)"; exit 0 ;;
        "")           show_menu; exit 0 ;;
        *)            echo "Unknown: $1"; echo "Run: bw-user --help"; exit 1 ;;
    esac
}

main "$@"
