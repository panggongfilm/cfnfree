#!/bin/bash
# ============================================================================
# Script  : bw-user.sh
# Version : 2.0 (Sesi 2.5-B - v17)
# Purpose : Bandwidth per-user via /proc/<pid>/io untuk SEMUA path tunneling
#           (SSH direct port 22 + Dropbear child port 109/143).
#           Cloudfront/WS-TLS/WS-NonTLS user otomatis ter-cover karena
#           trafficnya di-handle oleh Dropbear child.
#
#           Approach: snapshot /proc/<pid>/io (rchar/wchar) per-PID setiap 1 menit
#           via cron, calculate delta vs last snapshot, accumulate per-user ke
#           hourly file. Periodik view: Live / Per Jam / Hari Ini / 7 Hari / 30 Hari.
#
#           Mengikuti pola script Xray (statsquery + snapshots + awk combine),
#           diadaptasi untuk SSH/Dropbear dengan /proc/<pid>/io + Pattern 19.
#
# Setup   : 1. Run `bw-user --setup` (1x) → create dirs + install cron
#           2. Cron tiap 1 menit auto-snapshot + accumulate
#           3. Run `bw-user` interactive atau `bw-user --display` CLI
#
# Source  : Original HAXOR wrapper
#           - Pattern 19 v13 (Hybrid 4-layer resolver) untuk mapping PID→user
#           - Pattern 24 v14 (Global journal cache) untuk performance
#           - Pattern 28 v16 (resolve_user_from_ip) untuk fallback (legacy)
#           - Pola snapshot + periodik view diadaptasi dari script Xray (user ref)
# Brand   : HAXOR + Tagline "DEKENG ANE BIAK BELITONG"
# Usage   : bw-user                          (interactive menu, recommended)
#           bw-user --display                (CLI: tampilkan tabel live)
#           bw-user --hourly                 (CLI: tampilkan 24 jam terakhir)
#           bw-user --today                  (CLI: total per user hari ini)
#           bw-user --7d                     (CLI: 7 hari terakhir)
#           bw-user --30d                    (CLI: 30 hari terakhir)
#           bw-user --setup                  (CLI: setup dirs + cron)
#           bw-user --snap                    (CLI: cron job - snapshot + accumulate)
#           bw-user --reset                  (CLI: clear all data)
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
SCRIPT_VERSION="2.0"
SSH_PORT="22"
DROPBEAR_PORTS="109 143"
BANDWIDTH_DIR="/var/log/bw-user"
SNAP_DIR="${BANDWIDTH_DIR}/snapshots"
HOURLY_DIR="${BANDWIDTH_DIR}/accum/hourly"
DAILY_DIR="${BANDWIDTH_DIR}/accum/daily"
LAST_SNAP="${BANDWIDTH_DIR}/last-snap.log"
CRON_FILE="/etc/cron.d/bw-user"
LOG_WINDOW="24 hours ago"
SNAPSHOT_RETAIN_DAYS=7
HOURLY_RETAIN_DAYS=30
DAILY_RETAIN_DAYS=90

# System daemon users yang TIDAK dihitung (filter dari display)
# FIX1-B v16: Hapus "root" dari filter — root adalah admin yang valid, bandwidth root harus dihitung
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
# Branding HAXOR + tagline BELITONG (lokasi #10 - retained dari v1.0-FIX2)
show_header() {
    clear
    echo -e "${BG_CYAN}                                                  ${NC}"
    echo -e "${BG_CYAN}  BANDWIDTH PER-USER - HAXOR TUNNELING             ${NC}"
    echo -e "${BG_TEAL}  DEKENG ANE BIAK BELITONG                         ${NC}"
    echo -e "${BG_CYAN}                                                  ${NC}"
    echo -e "${GRAY}  /proc/<pid>/io - Dropbear child + sshd PID tracking${NC}"
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
            if [ -n "$log_user" ]; then
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
            if [ -n "$log_user" ]; then
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
            if [ "$user" != "system" ]; then
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

# --- Helper: cek apakah username adalah system daemon (skip dari display) ---
is_system_user() {
    local user=$1
    case " $SYSTEM_USERS_FILTER " in
        *" $user "*) return 0 ;;
    esac
    return 1
}

# ============================================================================
# Pattern 28 (v16): Resolve username by IP from auth.log
# Used when PID NOT found in current `ss` (IP disconnected/historical/scanner)
# NOTE: Di v2.0, Pattern 28 RETAINED untuk backward compatibility, TAPI
#       approach utama sekarang /proc/<pid>/io tidak butuh resolve by IP
#       (karena PID-based tracking, BUKAN IP-based).
# ============================================================================
resolve_user_from_ip() {
    local ip="$1"
    [ -z "$ip" ] && { echo "?"; return; }

    # Pattern 24 v14: pakai global cache (1 call per script run)
    fetch_journal_log
    fetch_auth_log

    local username=""

    # Pattern A: SSH direct port 22 - "Accepted password for USER from IP"
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

# ============================================================================
# NEW v2.0: get_active_tunneling_pids
# Scan ss untuk Dropbear child (port 109/143) + sshd (port 22) PID yang established
# Output: list of "pid" per line (filtered: skip loopback, VPS IP, protected IP)
# Adaptasi dari get_active_connections pantau.sh + tendang-safe.sh
#
# FIX1 v17 (Sesi 2.5-B): Pisahkan filter berdasarkan local_port
# - Port 22 (sshd): peer IP harus public (skip 127.0.0.1, VPS IP, private range)
#   karena sshd peer = IP user asli (BUKAN loopback)
# - Port 109/143 (Dropbear child): JANGAN filter peer IP, karena peer SELALU
#   127.0.0.1 (loopback dari sslh/python WS proxy) — ini karakteristik arsitektur
#   Cloudfront/WS-TLS/WS-NonTLS. User resolve via Pattern 19 (auth.log PID matching),
#   BUKAN via peer IP.
# ============================================================================
get_active_tunneling_pids() {
    ss -tnpH state established 2>/dev/null | while IFS= read -r line; do
        [ -z "$line" ] && continue

        # Extract PID via bash regex (Pattern 16 v12)
        local pid=""
        if [[ $line =~ pid=([0-9]+) ]]; then
            pid="${BASH_REMATCH[1]}"
        fi
        [ -z "$pid" ] && continue

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
        [ -z "$local_addr" ] && continue

        # Extract local port
        local local_port="${local_addr##*:}"
        local_port="${local_port%%[^0-9]*}"

        # FILTER: hanya port yang relevan (Dropbear 109/143 + sshd 22)
        local is_target=0
        case "$local_port" in
            22|109|143) is_target=1 ;;
        esac
        [ "$is_target" -eq 0 ] && continue

        # Extract peer IP
        local peer_ip=""
        if [ -n "$peer_addr" ]; then
            peer_ip="${peer_addr%:*}"
            peer_ip="${peer_ip#[}"
            peer_ip="${peer_ip%]}"
        fi

        # FIX1 v17: Conditional filter berdasarkan local_port
        # - Port 22 (sshd): filter protected IP (peer harus public, BUKAN loopback)
        # - Port 109/143 (Dropbear child): JANGAN filter (peer 127.0.0.1 itu normal)
        if [ "$local_port" = "22" ]; then
            is_protected_ip "$peer_ip" && continue
        fi
        # Port 109/143: skip only if peer is empty (race condition)
        [ -z "$peer_ip" ] && continue

        echo "$pid"
    done
}

# ============================================================================
# NEW v2.0: capture_current_snapshot
# Capture /proc/<pid>/io (rchar, wchar) untuk semua active tunneling PID
# Resolve username via Pattern 19
# Output: list "pid:user:rchar:wchar" per line (sorted by rchar desc)
# ============================================================================
capture_current_snapshot() {
    local pid user rchar wchar
    while IFS= read -r pid; do
        [ -z "$pid" ] && continue

        # Read /proc/<pid>/io
        if [ ! -r "/proc/$pid/io" ]; then continue; fi
        rchar=$(awk '/^rchar:/ {print $2}' "/proc/$pid/io" 2>/dev/null)
        wchar=$(awk '/^wchar:/ {print $2}' "/proc/$pid/io" 2>/dev/null)
        [ -z "$rchar" ] && rchar=0
        [ -z "$wchar" ] && wchar=0

        # Resolve user via Pattern 19
        user=$(resolve_user_from_pid "$pid")
        [ -z "$user" ] && user="?"

        printf '%s:%s:%s:%s\n' "$pid" "$user" "$rchar" "$wchar"
    done < <(get_active_tunneling_pids)
}

# ============================================================================
# NEW v2.0: cmd_snap (cron job logic)
# 1. Capture current snapshot (all PID + rchar/wchar + user)
# 2. Save to snapshots/YYYY-MM-DD-HH-MM.log
# 3. Load last-snap.log
# 4. For each PID in current:
#    - Calculate delta rchar/wchar vs last-snap (handle PID reuse via user check)
#    - If user != "?" and not system: add delta to hourly file (today's hour)
# 5. Save current snapshot as last-snap.log
# 6. Cleanup old snapshots (>7 days) + hourly (>30 days) + daily (>90 days)
# ============================================================================
cmd_snap() {
    # Ensure dirs exist (auto-recover kalau VPS reboot)
    mkdir -p "$SNAP_DIR" "$HOURLY_DIR" "$DAILY_DIR" 2>/dev/null

    local TS_NOW=$(date +%s)
    local SNAP_DATE=$(date +%Y-%m-%d)
    local SNAP_TIME=$(date +%Y-%m-%d-%H-%M)
    local SNAP_HOUR=$(date +%Y-%m-%d-%H)
    local HOURLY_FILE="${HOURLY_DIR}/${SNAP_HOUR}.log"
    local SNAP_FILE="${SNAP_DIR}/${SNAP_TIME}.log"

    # Capture current snapshot
    local CURRENT_SNAP
    CURRENT_SNAP=$(capture_current_snapshot)

    # Save current snapshot to file (with header)
    {
        echo "# Snapshot: ${SNAP_TIME} (epoch: ${TS_NOW})"
        echo "# Format: pid:user:rchar:wchar"
        if [ -n "$CURRENT_SNAP" ]; then
            printf '%s\n' "$CURRENT_SNAP"
        fi
    } > "$SNAP_FILE"

    # Load last snapshot (skip header lines starting with #)
    local LAST_SNAP_DATA=""
    if [ -f "$LAST_SNAP" ]; then
        LAST_SNAP_DATA=$(grep -v '^#' "$LAST_SNAP" 2>/dev/null)
    fi

    # Build associative array of last snap: pid → "user:rchar:wchar"
    declare -A LAST_SNAP_MAP
    if [ -n "$LAST_SNAP_DATA" ]; then
        while IFS=: read -r l_pid l_user l_rchar l_wchar; do
            [ -z "$l_pid" ] && continue
            LAST_SNAP_MAP["$l_pid"]="${l_user}:${l_rchar}:${l_wchar}"
        done <<< "$LAST_SNAP_DATA"
    fi

    # Calculate deltas per PID, accumulate per user
    local delta_rchar delta_wchar prev_user prev_rchar prev_wchar
    local user_pid_entry
    declare -A USER_DELTA_UP
    declare -A USER_DELTA_DOWN

    if [ -n "$CURRENT_SNAP" ]; then
        while IFS=: read -r pid user rchar wchar; do
            [ -z "$pid" ] && continue

            # Skip if user is "?" or system daemon
            if [ "$user" = "?" ] || [ "$user" = "-" ]; then
                continue
            fi
            if is_system_user "$user"; then
                continue
            fi

            # Calculate delta vs last snap
            if [ -n "${LAST_SNAP_MAP[$pid]+x}" ]; then
                # PID exists in last snap
                user_pid_entry="${LAST_SNAP_MAP[$pid]}"
                prev_user="${user_pid_entry%%:*}"
                local rest="${user_pid_entry#*:}"
                prev_rchar="${rest%%:*}"
                prev_wchar="${rest##*:}"

                if [ "$prev_user" = "$user" ]; then
                    # Same user, calculate delta
                    if [ "$rchar" -ge "$prev_rchar" ] 2>/dev/null; then
                        delta_rchar=$((rchar - prev_rchar))
                    else
                        # Counter reset (impossible normally, but defensive)
                        delta_rchar="$rchar"
                    fi
                    if [ "$wchar" -ge "$prev_wchar" ] 2>/dev/null; then
                        delta_wchar=$((wchar - prev_wchar))
                    else
                        delta_wchar="$wchar"
                    fi
                else
                    # PID reuse (different user) — treat as new, delta = current
                    delta_rchar="$rchar"
                    delta_wchar="$wchar"
                fi
            else
                # New PID — delta = current (assume start from 0)
                delta_rchar="$rchar"
                delta_wchar="$wchar"
            fi

            # Accumulate per user
            USER_DELTA_UP["$user"]=$((${USER_DELTA_UP[$user]:-0} + delta_rchar))
            USER_DELTA_DOWN["$user"]=$((${USER_DELTA_DOWN[$user]:-0} + delta_wchar))
        done <<< "$CURRENT_SNAP"
    fi

    # Update hourly file (per-user accumulated deltas for this hour)
    # Format: user:up_bytes:down_bytes:total_bytes
    if [ ${#USER_DELTA_UP[@]} -gt 0 ]; then
        # Merge with existing hourly file
        local TMP_HOURLY=$(mktemp)
        if [ -f "$HOURLY_FILE" ]; then
            cp "$HOURLY_FILE" "$TMP_HOURLY"
        fi

        # Add deltas to existing values (or create new entries)
        for user in "${!USER_DELTA_UP[@]}"; do
            local du="${USER_DELTA_UP[$user]}"
            local dd="${USER_DELTA_DOWN[$user]}"
            local tmp_new=$(mktemp)

            # FIX: -v OFS=: untuk output field separator konsisten dengan input
            # (kalau tidak set, awk default OFS=spasi → format jadi rusak)
            awk -F: -v OFS=: -v u="$user" -v du="$du" -v dd="$dd" '
            BEGIN { found=0 }
            $1 == u {
                $2 = $2 + du; $3 = $3 + dd; $4 = $2 + $3;
                print;
                found=1;
                next
            }
            { print }
            END { if (!found) printf "%s:%d:%d:%d\n", u, du, dd, du+dd }
            ' "$TMP_HOURLY" > "$tmp_new"
            mv "$tmp_new" "$TMP_HOURLY"
        done

        mv "$TMP_HOURLY" "$HOURLY_FILE"
    fi

    # Save current snapshot as last-snap.log (for next run delta calc)
    cp "$SNAP_FILE" "$LAST_SNAP"

    # Cleanup old files
    find "$SNAP_DIR" -name '*.log' -mtime +$SNAPSHOT_RETAIN_DAYS -delete 2>/dev/null
    find "$HOURLY_DIR" -name '*.log' -mtime +$HOURLY_RETAIN_DAYS -delete 2>/dev/null
    find "$DAILY_DIR" -name '*.log' -mtime +$DAILY_RETAIN_DAYS -delete 2>/dev/null

    return 0
}

# ============================================================================
# NEW v2.0: cmd_display_live
# Show active users + current rchar/wchar (current values, BUKAN delta)
# Format: USERNAME | PID | UP (rchar) | DOWN (wchar) | TOTAL
# Skip user "?" dan system daemon
# ============================================================================
cmd_display_live() {
    show_header
    echo -e "${CYAN}=== BANDWIDTH PER-USER (LIVE - CURRENT SESSION) ===${NC}"
    echo -e "${GRAY}Update: snapshot real-time dari /proc/<pid>/io${NC}"
    echo

    local CURRENT_SNAP
    CURRENT_SNAP=$(capture_current_snapshot)

    if [ -z "$CURRENT_SNAP" ]; then
        echo -e "${YELLOW}Tidak ada koneksi tunneling aktif saat ini.${NC}"
        echo -e "${GRAY}(Dropbear port 109/143 + sshd port 22)${NC}"
        pause
        return 0
    fi

    # Header
    echo -e "${YELLOW}USERNAME         PID        UP (rchar)     DOWN (wchar)   TOTAL          ${NC}"
    echo -e "${DGRAY}─────────────    ─────────  ──────────     ──────────     ──────────     ${NC}"

    local total_up=0 total_down=0 user_count=0
    local pid user rchar wchar total
    local displayed_lines=""

    # Sort by rchar desc, then filter "?"
    local SORTED_SNAP
    SORTED_SNAP=$(printf '%s\n' "$CURRENT_SNAP" | sort -t: -k3 -n -r)

    while IFS=: read -r pid user rchar wchar; do
        [ -z "$pid" ] && continue

        # Skip if user is "?" or system daemon
        if [ "$user" = "?" ] || [ "$user" = "-" ]; then
            continue
        fi
        if is_system_user "$user"; then
            continue
        fi

        total=$((rchar + wchar))
        printf "%-16s %-10s %-14s %-14s %-14s\n" \
            "$user" "$pid" "$(format_bytes $rchar)" "$(format_bytes $wchar)" "$(format_bytes $total)"

        total_up=$((total_up + rchar))
        total_down=$((total_down + wchar))
        user_count=$((user_count + 1))
    done <<< "$SORTED_SNAP"

    echo -e "${DGRAY}─────────────    ─────────  ──────────     ──────────     ──────────     ${NC}"
    local total_all=$((total_up + total_down))
    printf "${YELLOW}%-16s %-10s %-14s %-14s %-14s${NC}\n" \
        "TOTAL" "($user_count)" "$(format_bytes $total_up)" "$(format_bytes $total_down)" "$(format_bytes $total_all)"

    echo
    echo -e "${GRAY}Limitation:${NC}"
    echo -e "  ${GRAY}- Hanya tampilkan user aktif dengan username ter-resolve (Pattern 19)${NC}"
    echo -e "  ${GRAY}- User '?' (scanner/failed auth) di-skip dari display${NC}"
    echo -e "  ${GRAY}- rchar = bytes di-read process (proxy untuk upload user)${NC}"
    echo -e "  ${GRAY}- wchar = bytes di-write process (proxy untuk download user)${NC}"
    echo -e "  ${GRAY}- Counter di-reset saat PID exit (user disconnect)${NC}"
    pause
}

# ============================================================================
# NEW v2.0: cmd_display_hourly
# Show last 24 hours, each row = 1 hour
# Columns: HOUR | TOTAL UP | TOTAL DOWN | TOTAL | TOP USER (with their bytes)
# Data source: accum/hourly/*.log (sum all entries per hour)
# ============================================================================
cmd_display_hourly() {
    show_header
    echo -e "${CYAN}=== BANDWIDTH PER JAM (24 JAM TERAKHIR) ===${NC}"
    echo

    echo -e "${YELLOW}HOUR                  TOTAL UP      TOTAL DOWN    TOTAL         TOP USER${NC}"
    echo -e "${DGRAY}──────────────────    ──────────    ──────────    ──────────    ──────────────${NC}"

    local total_up=0 total_down=0
    local now_epoch=$(date +%s)
    local hour_epoch

    for i in $(seq 23 -1 0); do
        hour_epoch=$((now_epoch - i * 3600))
        # Round to start of hour
        local hour_start=$((hour_epoch - (hour_epoch % 3600)))
        local hour_label=$(date -d "@$hour_start" +'%Y-%m-%d %H:00')
        local hour_file=$(date -d "@$hour_start" +'%Y-%m-%d-%H')
        local hourly_path="${HOURLY_DIR}/${hour_file}.log"

        local h_up=0 h_down=0 h_total=0
        local top_user="" top_user_total=0

        if [ -f "$hourly_path" ]; then
            while IFS=: read -r user up down total; do
                [ -z "$user" ] && continue
                up=${up:-0}; down=${down:-0}; total=${total:-0}
                h_up=$((h_up + up))
                h_down=$((h_down + down))
                h_total=$((h_total + total))
                if [ "$total" -gt "$top_user_total" ] 2>/dev/null; then
                    top_user_total="$total"
                    top_user="$user"
                fi
            done < "$hourly_path"
        fi

        local top_user_display="-"
        if [ -n "$top_user" ]; then
            top_user_display="${top_user} ($(format_bytes $top_user_total))"
        fi

        printf "%-20s  %-12s  %-12s  %-12s  %s\n" \
            "$hour_label" \
            "$(format_bytes $h_up)" \
            "$(format_bytes $h_down)" \
            "$(format_bytes $h_total)" \
            "$top_user_display"

        total_up=$((total_up + h_up))
        total_down=$((total_down + h_down))
    done

    local total_all=$((total_up + total_down))
    echo -e "${DGRAY}──────────────────    ──────────    ──────────    ──────────    ──────────────${NC}"
    printf "${YELLOW}%-20s  %-12s  %-12s  %-12s${NC}\n" \
        "TOTAL (24 jam)" \
        "$(format_bytes $total_up)" \
        "$(format_bytes $total_down)" \
        "$(format_bytes $total_all)"

    echo
    echo -e "${GRAY}Data source: ${HOURLY_DIR}/ (cron accumulate tiap 1 menit)${NC}"
    echo -e "${GRAY}Retain: ${HOURLY_RETAIN_DAYS} hari. Hour kosong = belum ada traffic jam itu.${NC}"
    pause
}

# ============================================================================
# NEW v2.0: cmd_display_today
# Total per user for today (sum all hourly files for today)
# Format: USERNAME | UPLOAD | DOWNLOAD | TOTAL (sorted by total desc)
# ============================================================================
cmd_display_today() {
    show_header
    echo -e "${CYAN}=== BANDWIDTH HARI INI (PER USER) ===${NC}"
    echo -e "${GRAY}Tanggal: $(date +'%Y-%m-%d')${NC}"
    echo

    local today=$(date +'%Y-%m-%d')
    local tmp_combined=$(mktemp)

    # Combine all hourly files for today
    for hourly_path in "${HOURLY_DIR}/${today}"-*.log; do
        [ -f "$hourly_path" ] || continue
        grep -v '^#' "$hourly_path" >> "$tmp_combined"
    done

    if [ ! -s "$tmp_combined" ]; then
        echo -e "${YELLOW}Belum ada data bandwidth untuk hari ini.${NC}"
        echo -e "${GRAY}Tunggu 1-2 menit agar cron mencatat aktivitas.${NC}"
        rm -f "$tmp_combined"
        pause
        return 0
    fi

    # Aggregate per user (sum up:up:down:total)
    awk -F: '
    {
        up[$1] += $2
        dn[$1] += $3
        tt[$1] += $4
    }
    END {
        for (u in up) printf "%s:%d:%d:%d\n", u, up[u], dn[u], up[u]+dn[u]
    }
    ' "$tmp_combined" | sort -t: -k4 -n -r > "${tmp_combined}.sorted"

    echo -e "${YELLOW}USERNAME         UPLOAD        DOWNLOAD      TOTAL         ${NC}"
    echo -e "${DGRAY}─────────────    ──────────    ──────────    ──────────   ${NC}"

    local total_up=0 total_down=0 user_count=0
    while IFS=: read -r user up down total; do
        [ -z "$user" ] && continue
        printf "%-16s %-13s %-13s %-13s\n" \
            "$user" "$(format_bytes $up)" "$(format_bytes $down)" "$(format_bytes $total)"
        total_up=$((total_up + up))
        total_down=$((total_down + down))
        user_count=$((user_count + 1))
    done < "${tmp_combined}.sorted"

    echo -e "${DGRAY}─────────────    ──────────    ──────────    ──────────   ${NC}"
    local total_all=$((total_up + total_down))
    printf "${YELLOW}%-16s %-13s %-13s %-13s${NC}\n" \
        "TOTAL" "($user_count user)" \
        "$(format_bytes $total_up)" "$(format_bytes $total_down)" "$(format_bytes $total_all)"

    rm -f "$tmp_combined" "${tmp_combined}.sorted"
    pause
}

# ============================================================================
# NEW v2.0: cmd_display_range (generic untuk 7d/30d)
# Combine hourly files for last N days, sum per user, display
# ============================================================================
cmd_display_range() {
    local DAYS=$1
    local title=$2

    show_header
    echo -e "${CYAN}=== ${title} ===${NC}"
    echo

    local tmp_combined=$(mktemp)
    local now_epoch=$(date +%s)
    local day_epoch day_date

    for i in $(seq 0 $((DAYS - 1))); do
        day_epoch=$((now_epoch - i * 86400))
        day_date=$(date -d "@$day_epoch" +'%Y-%m-%d')
        for hourly_path in "${HOURLY_DIR}/${day_date}"-*.log; do
            [ -f "$hourly_path" ] || continue
            grep -v '^#' "$hourly_path" >> "$tmp_combined"
        done
    done

    if [ ! -s "$tmp_combined" ]; then
        echo -e "${YELLOW}Belum ada data bandwidth untuk ${DAYS} hari terakhir.${NC}"
        echo -e "${GRAY}Tunggu beberapa menit agar cron mencatat aktivitas.${NC}"
        rm -f "$tmp_combined"
        pause
        return 0
    fi

    # Aggregate per user
    awk -F: '
    {
        up[$1] += $2
        dn[$1] += $3
        tt[$1] += $4
    }
    END {
        for (u in up) printf "%s:%d:%d:%d\n", u, up[u], dn[u], up[u]+dn[u]
    }
    ' "$tmp_combined" | sort -t: -k4 -n -r > "${tmp_combined}.sorted"

    echo -e "${YELLOW}USERNAME         UPLOAD        DOWNLOAD      TOTAL         ${NC}"
    echo -e "${DGRAY}─────────────    ──────────    ──────────    ──────────   ${NC}"

    local total_up=0 total_down=0 user_count=0
    while IFS=: read -r user up down total; do
        [ -z "$user" ] && continue
        printf "%-16s %-13s %-13s %-13s\n" \
            "$user" "$(format_bytes $up)" "$(format_bytes $down)" "$(format_bytes $total)"
        total_up=$((total_up + up))
        total_down=$((total_down + down))
        user_count=$((user_count + 1))
    done < "${tmp_combined}.sorted"

    echo -e "${DGRAY}─────────────    ──────────    ──────────    ──────────   ${NC}"
    local total_all=$((total_up + total_down))
    printf "${YELLOW}%-16s %-13s %-13s %-13s${NC}\n" \
        "TOTAL" "($user_count user)" \
        "$(format_bytes $total_up)" "$(format_bytes $total_down)" "$(format_bytes $total_all)"

    rm -f "$tmp_combined" "${tmp_combined}.sorted"
    pause
}

# ============================================================================
# NEW v2.0: cmd_setup
# Create directories + install cron job
# Pattern: run-once dengan confirmation (mirip clearlog.sh v7, clearcache.sh v8)
# ============================================================================
cmd_setup() {
    show_header
    echo -e "${CYAN}=== SETUP BANDWIDTH PER-USER (v2.0) ===${NC}"
    echo
    echo -e "${WHITE}Setup akan melakukan:${NC}"
    echo -e "  ${GREEN}1.${NC} Create directories:"
    echo -e "     ${GRAY}${SNAP_DIR}/${NC}"
    echo -e "     ${GRAY}${HOURLY_DIR}/${NC}"
    echo -e "     ${GRAY}${DAILY_DIR}/${NC}"
    echo -e "  ${GREEN}2.${NC} Install cron job ${YELLOW}${CRON_FILE}${NC} (setiap 1 menit)"
    echo -e "  ${GREEN}3.${NC} Capture initial snapshot + seed last-snap.log"
    echo
    echo -e "${YELLOW}Approach:${NC}"
    echo -e "  ${GRAY}- /proc/<pid>/io tracking untuk Dropbear child (port 109/143) + sshd (port 22)${NC}"
    echo -e "  ${GRAY}- Cloudfront/WS-TLS/WS-NonTLS user otomatis ter-cover (via Dropbear child)${NC}"
    echo -e "  ${GRAY}- Pattern 19 (Hybrid 4-layer resolver) untuk mapping PID → user${NC}"
    echo
    echo -e "${YELLOW}Periodik view yang tersedia:${NC}"
    echo -e "  ${GRAY}- Live (active users + current bandwidth)${NC}"
    echo -e "  ${GRAY}- Per Jam (24 jam terakhir, breakdown per jam)${NC}"
    echo -e "  ${GRAY}- Hari Ini (total per user today)${NC}"
    echo -e "  ${GRAY}- 7 Hari Terakhir (total per user last 7 days)${NC}"
    echo -e "  ${GRAY}- 30 Hari Terakhir (total per user last 30 days)${NC}"
    echo
    echo -e "${RED}Prasyarat:${NC}"
    echo -e "  ${GRAY}- Akses root (butuh baca /proc/<pid>/io + cron root)${NC}"
    echo -e "  ${GRAY}- Command ss + ps + journalctl tersedia (default Ubuntu 20.04)${NC}"
    echo -e "  ${GRAY}- Cron service aktif (systemctl status cron)${NC}"
    echo

    # Validasi command -v (Pattern 6 v6)
    local missing=0
    for cmd in ss ps journalctl getent grep awk sed cat find; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${RED}ERROR: command '$cmd' tidak ditemukan.${NC}"
            missing=1
        fi
    done
    [ "$missing" -ne 0 ] && { pause; return 1; }

    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}ERROR: Setup butuh akses root.${NC}"
        echo -e "${GRAY}Run: sudo bw-user --setup${NC}"
        pause
        return 1
    fi

    echo -e "${YELLOW}Lanjutkan setup? (y/n): ${NC}"
    read -r confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo -e "${GRAY}Setup dibatalkan.${NC}"
        pause
        return 0
    fi

    echo
    echo -e "${CYAN}[1/4] Create directories...${NC}"
    mkdir -p "$SNAP_DIR" "$HOURLY_DIR" "$DAILY_DIR"
    echo -e "  ${GREEN}OK${NC} ${SNAP_DIR}"
    echo -e "  ${GREEN}OK${NC} ${HOURLY_DIR}"
    echo -e "  ${GREEN}OK${NC} ${DAILY_DIR}"

    echo -e "${CYAN}[2/4] Install cron job...${NC}"
    cat > "$CRON_FILE" <<EOF
# Autogenerated by bw-user v${SCRIPT_VERSION} (HAXOR Panel Tunneling)
# Cron job: snapshot /proc/<pid>/io + accumulate per-user
# Schedule: every 1 minute
* * * * * root /usr/bin/bw-user --snap >/dev/null 2>&1
EOF
    chmod 644 "$CRON_FILE"
    echo -e "  ${GREEN}OK${NC} ${CRON_FILE} (every 1 minute)"

    echo -e "${CYAN}[3/4] Capture initial snapshot...${NC}"
    # Run snap once to seed last-snap.log
    /usr/bin/bw-user --snap >/dev/null 2>&1
    if [ -f "$LAST_SNAP" ]; then
        echo -e "  ${GREEN}OK${NC} last-snap.log seeded"
    else
        echo -e "  ${YELLOW}WARN${NC} last-snap.log belum ada (mungkin belum ada koneksi aktif)"
    fi

    echo -e "${CYAN}[4/4] Verify setup...${NC}"
    echo -e "  ${GRAY}Directory:${NC} $(ls -d "$SNAP_DIR" "$HOURLY_DIR" "$DAILY_DIR" 2>/dev/null | wc -l)/3 created"
    echo -e "  ${GRAY}Cron file:${NC} $([ -f "$CRON_FILE" ] && echo 'EXISTS' || echo 'MISSING')"
    echo -e "  ${GRAY}Last snap:${NC} $([ -f "$LAST_SNAP" ] && echo 'EXISTS' || echo 'NOT YET')"

    echo
    echo -e "${GREEN}=== SETUP SELESAI ===${NC}"
    echo -e "${GRAY}Cron akan auto-snapshot tiap 1 menit. Tunggu 2-3 menit lalu jalankan:${NC}"
    echo -e "  ${YELLOW}bw-user${NC}               ${GRAY}(interactive menu)${NC}"
    echo -e "  ${YELLOW}bw-user --display${NC}     ${GRAY}(live display)${NC}"
    echo -e "  ${YELLOW}bw-user --hourly${NC}      ${GRAY}(24 jam terakhir)${NC}"
    pause
}

# ============================================================================
# NEW v2.0: cmd_reset
# Clear all snapshot + accum data, keep cron + dirs
# Pattern: run-once dengan confirmation prompt "YA" huruf besar
# ============================================================================
cmd_reset() {
    show_header
    echo -e "${CYAN}=== RESET BANDWIDTH DATA ===${NC}"
    echo
    echo -e "${RED}PERINGATAN:${NC} Ini akan menghapus SEMUA data bandwidth:"
    echo -e "  ${GRAY}- Snapshots: ${SNAP_DIR}/*.log${NC}"
    echo -e "  ${GRAY}- Hourly accum: ${HOURLY_DIR}/*.log${NC}"
    echo -e "  ${GRAY}- Daily accum: ${DAILY_DIR}/*.log${NC}"
    echo -e "  ${GRAY}- Last snap: ${LAST_SNAP}${NC}"
    echo
    echo -e "${YELLOW}Cron job + directories TIDAK dihapus (tetap aktif).${NC}"
    echo -e "${YELLOW}Reset tidak bisa di-undo. Lanjutkan?${NC}"
    echo
    echo -e "${RED}Ketik 'YA' (huruf besar) untuk konfirmasi: ${NC}"
    read -r confirm
    if [ "$confirm" != "YA" ]; then
        echo -e "${GRAY}Reset dibatalkan.${NC}"
        pause
        return 0
    fi

    echo
    echo -e "${CYAN}[1/4] Hapus snapshots...${NC}"
    rm -f "${SNAP_DIR}"/*.log 2>/dev/null
    echo -e "  ${GREEN}OK${NC}"

    echo -e "${CYAN}[2/4] Hapus hourly accum...${NC}"
    rm -f "${HOURLY_DIR}"/*.log 2>/dev/null
    echo -e "  ${GREEN}OK${NC}"

    echo -e "${CYAN}[3/4] Hapus daily accum...${NC}"
    rm -f "${DAILY_DIR}"/*.log 2>/dev/null
    echo -e "  ${GREEN}OK${NC}"

    echo -e "${CYAN}[4/4] Hapus last-snap.log...${NC}"
    rm -f "$LAST_SNAP" 2>/dev/null
    echo -e "  ${GREEN}OK${NC}"

    echo
    echo -e "${GREEN}=== RESET SELESAI ===${NC}"
    echo -e "${GRAY}Data bandwidth kosong. Cron akan mulai capture baru tiap 1 menit.${NC}"
    pause
}

# ============================================================================
# NEW v2.0: cmd_help
# ============================================================================
cmd_help() {
    show_header
    echo -e "${CYAN}=== HELP - bw-user v${SCRIPT_VERSION} ===${NC}"
    echo
    echo -e "${WHITE}PURPOSE:${NC}"
    echo -e "  ${GRAY}Bandwidth per-user via /proc/<pid>/io tracking untuk SEMUA path tunneling:${NC}"
    echo -e "  ${GRAY}SSH direct (port 22) + Dropbear child (port 109/143).${NC}"
    echo -e "  ${GRAY}Cloudfront/WS-TLS/WS-NonTLS user otomatis ter-cover karena trafficnya${NC}"
    echo -e "  ${GRAY}di-handle oleh Dropbear child.${NC}"
    echo
    echo -e "${WHITE}USAGE:${NC}"
    echo -e "  ${YELLOW}bw-user${NC}              ${GRAY}Interactive menu (recommended)${NC}"
    echo -e "  ${YELLOW}bw-user --display${NC}    ${GRAY}Live display (active users + current bw)${NC}"
    echo -e "  ${YELLOW}bw-user --hourly${NC}     ${GRAY}24 jam terakhir (breakdown per jam)${NC}"
    echo -e "  ${YELLOW}bw-user --today${NC}      ${GRAY}Total per user hari ini${NC}"
    echo -e "  ${YELLOW}bw-user --7d${NC}         ${GRAY}7 hari terakhir (total per user)${NC}"
    echo -e "  ${YELLOW}bw-user --30d${NC}        ${GRAY}30 hari terakhir (total per user)${NC}"
    echo -e "  ${YELLOW}bw-user --setup${NC}      ${GRAY}Setup dirs + cron (1x setelah install)${NC}"
    echo -e "  ${YELLOW}bw-user --snap${NC}       ${GRAY}Cron job (auto, jangan manual)${NC}"
    echo -e "  ${YELLOW}bw-user --reset${NC}      ${GRAY}Clear all data (keep cron)${NC}"
    echo -e "  ${YELLOW}bw-user --version${NC}    ${GRAY}Tampilkan versi${NC}"
    echo
    echo -e "${WHITE}MENU INTERACTIVE:${NC}"
    echo -e "  ${GREEN}01${NC} Live Display       ${GRAY}- Active users + current bandwidth${NC}"
    echo -e "  ${GREEN}02${NC} Per Jam (24 jam)    ${GRAY}- Breakdown per jam (24 rows)${NC}"
    echo -e "  ${GREEN}03${NC} Hari Ini            ${GRAY}- Total per user hari ini${NC}"
    echo -e "  ${GREEN}04${NC} 7 Hari Terakhir     ${GRAY}- Total per user 7 hari${NC}"
    echo -e "  ${GREEN}05${NC} 30 Hari Terakhir    ${GRAY}- Total per user 30 hari${NC}"
    echo -e "  ${GREEN}06${NC} Setup               ${GRAY}- Install dirs + cron${NC}"
    echo -e "  ${GREEN}07${NC} Reset               ${GRAY}- Clear all data${NC}"
    echo -e "  ${GREEN}08${NC} Help                ${GRAY}- Tampilkan help ini${NC}"
    echo -e "  ${GREEN}0X${NC} Exit                ${GRAY}- Kembali ke menu utama${NC}"
    echo
    echo -e "${WHITE}ARCHITECTURE:${NC}"
    echo -e "  ${GRAY}1. Cron tiap 1 menit capture snapshot semua active PID${NC}"
    echo -e "     ${GRAY}- Scan ss untuk Dropbear (port 109/143) + sshd (port 22)${NC}"
    echo -e "     ${GRAY}- Read /proc/<pid>/io (rchar, wchar)${NC}"
    echo -e "     ${GRAY}- Resolve user via Pattern 19 (auth.log PID matching)${NC}"
    echo -e "  ${GRAY}2. Calculate delta vs last snapshot${NC}"
    echo -e "     ${GRAY}- Handle PID reuse (different user → treat as new)${NC}"
    echo -e "     ${GRAY}- Handle new PID (delta = current value)${NC}"
    echo -e "  ${GRAY}3. Accumulate per-user ke hourly file${NC}"
    echo -e "     ${GRAY}- ${HOURLY_DIR}/YYYY-MM-DD-HH.log${NC}"
    echo -e "  ${GRAY}4. Cleanup old files (snapshots 7d, hourly 30d, daily 90d)${NC}"
    echo
    echo -e "${WHITE}FILES:${NC}"
    echo -e "  ${GRAY}/usr/bin/bw-user${NC}              ${GRAY}(this script)${NC}"
    echo -e "  ${GRAY}${CRON_FILE}${NC}      ${GRAY}(cron schedule)${NC}"
    echo -e "  ${GRAY}${SNAP_DIR}/${NC}         ${GRAY}(per-minute snapshots)${NC}"
    echo -e "  ${GRAY}${HOURLY_DIR}/${NC}    ${GRAY}(accumulated per hour)${NC}"
    echo -e "  ${GRAY}${DAILY_DIR}/${NC}     ${GRAY}(daily rollup, future)${NC}"
    echo -e "  ${GRAY}${LAST_SNAP}${NC}         ${GRAY}(last snapshot for delta calc)${NC}"
    echo
    echo -e "${WHITE}PATTERNS USED:${NC}"
    echo -e "  ${GRAY}- Pattern 4 (v9): Pause prompt untuk external submenu${NC}"
    echo -e "  ${GRAY}- Pattern 5 (v6): Palette 256-color ANSI-C quoting${NC}"
    echo -e "  ${GRAY}- Pattern 6 (v6): Validasi command -v${NC}"
    echo -e "  ${GRAY}- Pattern 7 (v9): Exit 0X → menu utama${NC}"
    echo -e "  ${GRAY}- Pattern 8 (v9): NO license IP check, NO bot integration${NC}"
    echo -e "  ${GRAY}- Pattern 16 (v12): Pure bash + regex untuk parsing${NC}"
    echo -e "  ${GRAY}- Pattern 17 (v12): Plain text untuk kolom width alignment${NC}"
    echo -e "  ${GRAY}- Pattern 19 (v13): Hybrid 4-layer resolver (PID → user)${NC}"
    echo -e "  ${GRAY}- Pattern 24 (v14): Global journal cache untuk performance${NC}"
    echo -e "  ${GRAY}- Pattern 28 (v16): resolve_user_from_ip (legacy fallback)${NC}"
    echo
    echo -e "${WHITE}LIMITATIONS:${NC}"
    echo -e "  ${GRAY}- rchar/wchar adalah cumulative counter (reset saat PID exit)${NC}"
    echo -e "  ${GRAY}- Max 1 menit traffic lost saat user disconnect (acceptable)${NC}"
    echo -e "  ${GRAY}- User '?' (scanner/failed auth) di-skip dari display${NC}"
    echo -e "  ${GRAY}- Counter di-reset saat VPS reboot (accum files tetap utuh)${NC}"
    pause
}

# ============================================================================
# NEW v2.0: show_menu (re-entrant via while-loop, Pattern 3 v9)
# ============================================================================
show_menu() {
    while true; do
        clear
        echo -e "${BG_CYAN}                                                  ${NC}"
        echo -e "${BG_CYAN}  BANDWIDTH PER-USER - HAXOR TUNNELING             ${NC}"
        echo -e "${BG_TEAL}  DEKENG ANE BIAK BELITONG                         ${NC}"
        echo -e "${BG_CYAN}                                                  ${NC}"
        echo -e "${GRAY}  /proc/<pid>/io - Dropbear child + sshd PID tracking${NC}"
        echo
        echo -e "${YELLOW}=== MENU BANDWIDTH PER-USER ===${NC}"
        echo
        echo -e "  ${GREEN}01${NC}  Live Display        ${GRAY}(active users + current bw)${NC}"
        echo -e "  ${GREEN}02${NC}  Per Jam (24 jam)    ${GRAY}(breakdown per jam)${NC}"
        echo -e "  ${GREEN}03${NC}  Hari Ini            ${GRAY}(total per user today)${NC}"
        echo -e "  ${GREEN}04${NC}  7 Hari Terakhir      ${GRAY}(total per user last 7 days)${NC}"
        echo -e "  ${GREEN}05${NC}  30 Hari Terakhir     ${GRAY}(total per user last 30 days)${NC}"
        echo -e "  ${GREEN}06${NC}  Setup               ${GRAY}(install dirs + cron)${NC}"
        echo -e "  ${GREEN}07${NC}  Reset               ${GRAY}(clear all data)${NC}"
        echo -e "  ${GREEN}08${NC}  Help                ${GRAY}(tampilkan help)${NC}"
        echo -e "  ${GREEN}0X${NC}  Exit                ${GRAY}(kembali ke menu utama)${NC}"
        echo
        read -rp "${GRAY}Pilih opsi [01-08 / 0X]: ${NC}" opt

        case "$opt" in
            01|1) cmd_display_live ;;
            02|2) cmd_display_hourly ;;
            03|3) cmd_display_today ;;
            04|4) cmd_display_range 7 "BANDWIDTH 7 HARI TERAKHIR (PER USER)" ;;
            05|5) cmd_display_range 30 "BANDWIDTH 30 HARI TERAKHIR (PER USER)" ;;
            06|6) cmd_setup ;;
            07|7) cmd_reset ;;
            08|8) cmd_help ;;
            0|00|x|X|0x|0X) clear; return 0 ;;
            *)
                echo -e "${RED}Opsi tidak dikenal. Pilih: 01-08 atau 0X (exit)${NC}"
                sleep 2
                ;;
        esac
    done
}

# ============================================================================
# Main dispatch
# ============================================================================
main() {
    case "$1" in
        --display)    cmd_display_live ;;
        --hourly)     cmd_display_hourly ;;
        --today)      cmd_display_today ;;
        --7d)         cmd_display_range 7 "BANDWIDTH 7 HARI TERAKHIR (PER USER)" ;;
        --30d)        cmd_display_range 30 "BANDWIDTH 30 HARI TERAKHIR (PER USER)" ;;
        --setup)      cmd_setup ;;
        --snap)       cmd_snap ;;
        --reset)      cmd_reset ;;
        --help|-h)    cmd_help ;;
        --version|-v) echo "bw-user v${SCRIPT_VERSION} (HAXOR Panel Tunneling)" ;;
        "")           show_menu ;;
        *)
            echo "Usage: bw-user [--display|--hourly|--today|--7d|--30d|--setup|--snap|--reset|--help|--version]"
            echo "       Run 'bw-user' for interactive menu."
            exit 1
            ;;
    esac
}

main "$@"
