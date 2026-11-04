#!/bin/bash
# ============================================================
# Script  : bw-limit.sh
# Version : v2.1 (Sesi 2.10 - v34) — IPTABLES MARK per-UID + DYNAMIC per-ephemeral + tc HTB
# Path    : /ssh/bw-limit.sh
# Brand   : HAXOR TUNNELING
# Tagline : DEKENG ANE BIAK BELITONG
# Source  : Original HAXOR wrapper - v2.1 dynamic rule layer (PROVEN empirical test)
# ============================================================
# DESIGN v2.1 (DYNAMIC RULE LAYER — solve DOWNLOAD shaping):
#   - RETAINED v2.0: iptables -m owner --uid-owner <UID> -j MARK (UPLOAD path OK)
#   - NEW v2.1: iptables -t mangle OUTPUT -o lo -p tcp --sport 109 --dport <ephemeral> -j MARK
#     (DOWNLOAD path: mark by --sport + --dport, BUKAN by UID — because SSH tunnel socket UID=root)
#   - NEW v2.1: cron watcher (*/2 min, flock -n) scan auth.log + auto add/remove dynamic rules
#   - NEW v2.1: state file tracking dynamic rules terpasang
#   - NEW v2.1: force reconnect (PATTERN 38) di cmd_add supaya dynamic rule apply ke socket baru
# ============================================================
# LESSON 70: SSH tunnel socket (lo port 109/143) UID=root by design
#            (Dropbear master accept() before fork+setuid, socket created UID=root)
#            → iptables -m owner --uid-owner GAGAL untuk download path
# LESSON 71: Dynamic rule per ephemeral port SOLVED download shaping — PROVEN empirical test
#            (60s YouTube+TikTok+live browsing → 2,511 pkt / 20 MB matched, tc class 2:2
#            Sent +21.7 MB shaped, overlimits +3,372, backlog 7 packets, tokens negative)
# PATTERN 46: Dynamic iptables rule per ephemeral port (mark by --sport + --dport, BUKAN by UID)
# ============================================================
# DESIGN v2.0 (RETAINED — PATH X SUCCESS foundation, Dropbear 2026.94):
#   - iptables -t mangle OUTPUT -m owner --uid-owner <UID> -j MARK --set-mark <idx>
#   - tc HTB root di eth0 (shape upload) + tc HTB root di lo (shape download)
#   - tc fw classifier: handle <idx> fw flowid <MAJOR>:<idx>
#   - Blacklist manual by admin (P3=C v26 retained)
#   - Hard cap (P2=B v26 retained): rate=ceil, no burst
# ============================================================
# KOMITMEN ETIS USER v21+v24 (WAJIB dipertahankan):
#   - Throttle HANYA untuk user blacklist manual by admin
#   - BUKAN auto-kick, BUKAN throttle semua user
#   - User normal tetap full speed (default class 1Gbit)
# ============================================================

# ============================================================
# CONSTANTS
# ============================================================
SCRIPT_VERSION="2.1"
CONFIG_DIR="/etc/bw-limit"
BLACKLIST_FILE="${CONFIG_DIR}/blacklist.txt"
IPTABLES_SAVE_FILE="${CONFIG_DIR}/iptables-rules.save"
LOG_FILE="/var/log/bw-limit.log"
TC_ETH0_MAJOR=1
TC_LO_MAJOR=2
TC_DEFAULT_CLASS_MINOR=9999
ETH0_IFACE="eth0"
LO_IFACE="lo"

# NEW v2.1: Dynamic rule layer constants
STATE_FILE="${CONFIG_DIR}/ephemeral-rules.save"     # tracking dynamic rules terpasang
CRON_FILE="/etc/cron.d/bw-limit"                    # cron watcher config
CRON_INTERVAL="*/2 * * * *"                          # every 2 minutes (PATTERN 34)
FLOCK_FILE="/tmp/bw-limit.lock"                      # flock -n (PATTERN 35)
SSH_TUNNEL_PORTS="109 143"                           # Dropbear listen ports (handle kedua)
AUTH_LOG_WINDOW="5 minutes ago"                      # journalctl --since window
WATCHER_LOG_FILE="/var/log/bw-limit-watcher.log"     # cron watcher event log

# ============================================================
# PALETTE 256-COLOR (ANSI-C quoting $'...' — Pattern 5 + LESSON v6 FIX1)
# ============================================================
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

# ============================================================
# HELPER FUNCTIONS
# ============================================================

show_header() {
    echo -e "${BG_CYAN}${WHITE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BG_CYAN}${WHITE}║          BANDWIDTH LIMIT v2.1 - HAXOR TUNNELING              ║${NC}"
    echo -e "${BG_CYAN}${WHITE}║              DEKENG ANE BIAK BELITONG                        ║${NC}"
    echo -e "${BG_TEAL}${WHITE}║  iptables MARK per-UID + dynamic per-ephemeral + tc HTB     ║${NC}"
    echo -e "${BG_TEAL}${WHITE}╚══════════════════════════════════════════════════════════════╝${NC}"
}

pause() {
    [ -t 0 ] || return 0
    echo
    echo -e "${GRAY}Tekan enter untuk kembali ke menu...${NC}"
    read -r _
}

log_msg() {
    # ISO-8601 timestamp + optional second arg for custom log file
    local msg="$1"
    local log_file="${2:-$LOG_FILE}"
    mkdir -p "$(dirname "$log_file")" 2>/dev/null
    echo "$(date '+%Y-%m-%dT%H:%M:%S%z') [bw-limit v${SCRIPT_VERSION}] ${msg}" >> "$log_file"
}

is_valid_user() {
    local user="$1"
    [ -z "$user" ] && return 1
    id "$user" >/dev/null 2>&1
}

get_uid_for_user() {
    local user="$1"
    id -u "$user" 2>/dev/null
}

# System users to skip (NOT tunneling users — Pattern 26 v14 adapted)
is_system_user() {
    local user="$1"
    case "$user" in
        root|sslh|daemon|nobody|systemd+|sshd|www-data|message+|syslog|usbmux|dnsmasq|vps|sync|mail|news|proxy|irc|gnats|systemd-network|systemd-resolve|dbus|_apt|postfix|statd)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

# ============================================================
# STATE FILE MANAGEMENT (NEW v2.1)
# File: /etc/bw-limit/ephemeral-rules.save
# Format: <user>:<pid>:<ephemeral_port>:<sport>:<mark> (one per line)
# ============================================================

ensure_state_file() {
    ensure_config_dir
    [ -f "$STATE_FILE" ] || touch "$STATE_FILE"
}

add_to_state_file() {
    local user="$1" pid="$2" ephemeral_port="$3" sport="$4" mark="$5"
    ensure_state_file
    echo "${user}:${pid}:${ephemeral_port}:${sport}:${mark}" >> "$STATE_FILE"
}

remove_from_state_file() {
    local user="$1"
    [ -f "$STATE_FILE" ] || return 0
    local tmp="${STATE_FILE}.tmp.$$"
    grep -v "^${user}:" "$STATE_FILE" > "$tmp" 2>/dev/null
    mv "$tmp" "$STATE_FILE"
}

# Cek apakah kombinasi user+ephemeral_port (optional sport) sudah ada di state file
is_in_state_file() {
    local user="$1" ephemeral_port="$2" sport="${3:-}"
    [ -f "$STATE_FILE" ] || return 1
    if [ -n "$sport" ]; then
        grep -q "^${user}:[^:]*:${ephemeral_port}:${sport}:" "$STATE_FILE"
    else
        grep -q "^${user}:[^:]*:${ephemeral_port}:" "$STATE_FILE"
    fi
}

# ============================================================
# PID MATCHING — Pattern 19 (adaptasi dari pantau.sh)
# Resolve Dropbear PID + ephemeral port untuk user tunneling
# ============================================================

resolve_pid_for_user() {
    # Return PID pertama dari dropbear process milik user itu
    # Return empty string kalau user offline
    local user="$1"
    [ -z "$user" ] && { echo ""; return; }
    ps -eo pid,user,args 2>/dev/null \
        | grep dropbear \
        | grep -v grep \
        | awk -v u="$user" '$2==u{print $1; exit}'
}

resolve_ephemeral_port_for_pid() {
    # Return ephemeral port dari socket loopback established milik PID itu
    # Socket: Dropbear (lo, port 109/143) → sslh (lo, ephemeral port)
    # Return empty kalau socket tidak established
    local pid="$1"
    [ -z "$pid" ] && { echo ""; return; }
    ss -tnpe state established 2>/dev/null \
        | grep "pid=$pid" \
        | grep "127.0.0.1" \
        | grep -E ":(109|143) " \
        | awk '{
            for (i=1; i<=NF; i++) {
                if ($i ~ /^127\.0\.0\.1:[0-9]+$/ && $i !~ /:(109|143)$/) {
                    split($i, a, ":")
                    print a[2]
                }
            }
          }' \
        | head -1
}

# ============================================================
# DYNAMIC RULE MANAGEMENT (NEW v2.1 — PATTERN 46)
# iptables -t mangle OUTPUT -o lo --sport <tunnel_port> --dport <ephemeral> -j MARK
# ============================================================

add_dynamic_rule_for_user() {
    # Pasang dynamic iptables rule + catat ke state file
    # Return 0 sukses, 1 gagal
    local user="$1" pid="$2" ephemeral_port="$3" sport="$4" mark="$5"

    # Idempotent: cek apakah rule sudah ada
    if iptables -t mangle -C OUTPUT -o lo -p tcp --sport "$sport" --dport "$ephemeral_port" -j MARK --set-mark "$mark" 2>/dev/null; then
        # Rule sudah ada, pastikan state file juga ada
        if ! is_in_state_file "$user" "$ephemeral_port" "$sport"; then
            add_to_state_file "$user" "$pid" "$ephemeral_port" "$sport" "$mark"
        fi
        return 0
    fi

    if iptables -t mangle -A OUTPUT -o lo -p tcp --sport "$sport" --dport "$ephemeral_port" -j MARK --set-mark "$mark" 2>/dev/null; then
        add_to_state_file "$user" "$pid" "$ephemeral_port" "$sport" "$mark"
        return 0
    fi
    return 1
}

remove_dynamic_rule_by_ephemeral() {
    # Hapus dynamic rule berdasarkan sport + ephemeral_port + mark
    # Return 0 sukses, 1 gagal (rule tidak ada)
    local sport="$1" ephemeral_port="$2" mark="$3"

    if iptables -t mangle -D OUTPUT -o lo -p tcp --sport "$sport" --dport "$ephemeral_port" -j MARK --set-mark "$mark" 2>/dev/null; then
        return 0
    fi
    return 1
}

remove_all_dynamic_rules_for_user() {
    # Loop state file, hapus SEMUA dynamic rule untuk user itu
    # Return (echo) jumlah rule dihapus
    local user="$1"
    [ -f "$STATE_FILE" ] || { echo 0; return; }

    local count=0
    local state_copy
    state_copy=$(mktemp)
    cp "$STATE_FILE" "$state_copy"

    while IFS=: read -r st_user st_pid st_port st_sport st_mark; do
        [ -z "$st_user" ] && continue
        [ "$st_user" != "$user" ] && continue

        remove_dynamic_rule_by_ephemeral "$st_sport" "$st_port" "$st_mark" 2>/dev/null
        count=$((count + 1))
    done < "$state_copy"
    rm -f "$state_copy"

    # Hapus semua entry user itu dari state file
    remove_from_state_file "$user"

    echo "$count"
}

# ============================================================
# BLACKLIST MANAGEMENT
# File: /etc/bw-limit/blacklist.txt
# Format: user:rate_mbps:classid_index (one per line)
# ============================================================

ensure_config_dir() {
    [ -d "$CONFIG_DIR" ] || mkdir -p "$CONFIG_DIR"
    [ -f "$BLACKLIST_FILE" ] || touch "$BLACKLIST_FILE"
}

is_user_in_blacklist() {
    local user="$1"
    [ -f "$BLACKLIST_FILE" ] || return 1
    grep -q "^${user}:" "$BLACKLIST_FILE"
}

get_user_blacklist_entry() {
    local user="$1"
    [ -f "$BLACKLIST_FILE" ] || return 1
    grep "^${user}:" "$BLACKLIST_FILE" | head -1
}

get_next_classid_index() {
    [ -f "$BLACKLIST_FILE" ] || { echo 1; return; }
    local max=0 idx
    while IFS=: read -r _ _ idx; do
        [ -n "$idx" ] && [ "$idx" -gt "$max" ] 2>/dev/null && max=$idx
    done < "$BLACKLIST_FILE"
    echo $((max + 1))
}

add_user_to_blacklist() {
    local user="$1" rate="$2" idx="$3"
    ensure_config_dir
    echo "${user}:${rate}:${idx}" >> "$BLACKLIST_FILE"
}

remove_user_from_blacklist() {
    local user="$1"
    [ -f "$BLACKLIST_FILE" ] || return 0
    local tmp="${BLACKLIST_FILE}.tmp.$$"
    grep -v "^${user}:" "$BLACKLIST_FILE" > "$tmp" 2>/dev/null
    mv "$tmp" "$BLACKLIST_FILE"
}

# ============================================================
# TC SETUP (eth0 + lo, idempotent — Pattern 41 v28 adapted)
# ============================================================

setup_tc_root() {
    # eth0: HTB root, default class 9999 (1Gbit unlimited)
    tc qdisc replace dev "$ETH0_IFACE" root handle ${TC_ETH0_MAJOR}: htb default ${TC_DEFAULT_CLASS_MINOR} 2>/dev/null || return 1
    tc class replace dev "$ETH0_IFACE" parent root classid ${TC_ETH0_MAJOR}:${TC_DEFAULT_CLASS_MINOR} htb rate 1000mbit ceil 1000mbit 2>/dev/null || return 1

    # lo: HTB root, default class 9999 (1Gbit unlimited)
    tc qdisc replace dev "$LO_IFACE" root handle ${TC_LO_MAJOR}: htb default ${TC_DEFAULT_CLASS_MINOR} 2>/dev/null || return 1
    tc class replace dev "$LO_IFACE" parent root classid ${TC_LO_MAJOR}:${TC_DEFAULT_CLASS_MINOR} htb rate 1000mbit ceil 1000mbit 2>/dev/null || return 1
    return 0
}

teardown_tc_root() {
    tc qdisc del dev "$ETH0_IFACE" root 2>/dev/null
    tc qdisc del dev "$LO_IFACE" root 2>/dev/null
    # Restore default qdisc (eth0 = fq like original kernel default; lo = noqueue auto)
    tc qdisc replace dev "$ETH0_IFACE" root fq 2>/dev/null
}

add_tc_class_for_user() {
    local user="$1" rate="$2" idx="$3"
    # eth0 class + fw filter
    tc class replace dev "$ETH0_IFACE" parent ${TC_ETH0_MAJOR}: classid ${TC_ETH0_MAJOR}:${idx} htb rate ${rate}mbit ceil ${rate}mbit 2>/dev/null || return 1
    tc filter replace dev "$ETH0_IFACE" parent ${TC_ETH0_MAJOR}: protocol ip prio 1 handle ${idx} fw classid ${TC_ETH0_MAJOR}:${idx} 2>/dev/null || return 1
    # lo class + fw filter
    tc class replace dev "$LO_IFACE" parent ${TC_LO_MAJOR}: classid ${TC_LO_MAJOR}:${idx} htb rate ${rate}mbit ceil ${rate}mbit 2>/dev/null || return 1
    tc filter replace dev "$LO_IFACE" parent ${TC_LO_MAJOR}: protocol ip prio 1 handle ${idx} fw classid ${TC_LO_MAJOR}:${idx} 2>/dev/null || return 1
    return 0
}

remove_tc_class_for_user() {
    local idx="$1"
    tc class del dev "$ETH0_IFACE" classid ${TC_ETH0_MAJOR}:${idx} 2>/dev/null
    tc filter del dev "$ETH0_IFACE" parent ${TC_ETH0_MAJOR}: protocol ip prio 1 handle ${idx} fw 2>/dev/null
    tc class del dev "$LO_IFACE" classid ${TC_LO_MAJOR}:${idx} 2>/dev/null
    tc filter del dev "$LO_IFACE" parent ${TC_LO_MAJOR}: protocol ip prio 1 handle ${idx} fw 2>/dev/null
}

# ============================================================
# IPTABLES MARK MANAGEMENT (mangle OUTPUT, --uid-owner, --set-mark)
# Pattern 49 v32: real-time packet marking per-UID (UPLOAD path)
# ============================================================

add_iptables_mark_for_user() {
    local uid="$1" idx="$2"
    # Idempotent: check if rule exists
    if iptables -t mangle -C OUTPUT -m owner --uid-owner "$uid" -j MARK --set-mark "$idx" 2>/dev/null; then
        return 0
    fi
    iptables -t mangle -A OUTPUT -m owner --uid-owner "$uid" -j MARK --set-mark "$idx"
}

remove_iptables_mark_for_user() {
    local uid="$1" idx="$2"
    # Loop delete (in case of duplicate rules)
    while iptables -t mangle -D OUTPUT -m owner --uid-owner "$uid" -j MARK --set-mark "$idx" 2>/dev/null; do :; done
}

# ============================================================
# CRON WATCHER SETUP (NEW v2.1)
# Install /etc/cron.d/bw-limit — jalankan --watch setiap 2 menit dengan flock
# ============================================================

install_cron() {
    mkdir -p "$(dirname "$CRON_FILE")" 2>/dev/null
    cat > "$CRON_FILE" <<EOF
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
${CRON_INTERVAL} root flock -n ${FLOCK_FILE} /usr/bin/bw-limit --watch >/dev/null 2>&1
EOF
    chmod 644 "$CRON_FILE"
    log_msg "CRON — installed at ${CRON_FILE} schedule='${CRON_INTERVAL}'"
    return 0
}

# ============================================================
# CMD: WATCH EPHEMERAL (NEW v2.1 — cron watcher logic)
# Scan blacklist + auth.log, add/remove dynamic rules per ephemeral port
# ============================================================

cmd_watch_ephemeral() {
    ensure_config_dir
    ensure_state_file

    # Fetch journalctl cache (Pattern 24 global cache)
    local auth_cache auth_lines
    auth_cache=$(journalctl --since "$AUTH_LOG_WINDOW" -t sshd -t dropbear 2>/dev/null || tail -200 /var/log/auth.log 2>/dev/null)
    auth_lines=$(printf '%s' "$auth_cache" | wc -l)

    local total_assigned=0 total_cleanup=0

    # Phase 1: Add rules untuk user blacklist yang online
    if [ -s "$BLACKLIST_FILE" ]; then
        while IFS=: read -r user rate idx; do
            [ -z "$user" ] && continue

            local pid ephem
            pid=$(resolve_pid_for_user "$user")
            [ -z "$pid" ] && continue   # user offline

            ephem=$(resolve_ephemeral_port_for_pid "$pid")
            [ -z "$ephem" ] && continue  # socket tidak established

            # Untuk setiap SSH tunnel port (109 + 143)
            local sport
            for sport in $SSH_TUNNEL_PORTS; do
                if ! is_in_state_file "$user" "$ephem" "$sport"; then
                    if add_dynamic_rule_for_user "$user" "$pid" "$ephem" "$sport" "$idx"; then
                        total_assigned=$((total_assigned + 1))
                    fi
                fi
            done
        done < "$BLACKLIST_FILE"
    fi

    # Phase 2: Cleanup stale rules
    if [ -s "$STATE_FILE" ]; then
        # Copy state file untuk hindari race condition saat iterasi
        local state_copy
        state_copy=$(mktemp)
        cp "$STATE_FILE" "$state_copy"

        local processed_users=""
        while IFS=: read -r st_user st_pid st_port st_sport st_mark; do
            [ -z "$st_user" ] && continue

            # Skip kalau user sudah diproses di loop ini
            case " $processed_users " in
                *" $st_user "*) continue ;;
            esac
            processed_users="$processed_users $st_user"

            # Kalau user tidak lagi di blacklist → cleanup semua dynamic rule
            if ! is_user_in_blacklist "$st_user"; then
                local removed
                removed=$(remove_all_dynamic_rules_for_user "$st_user")
                total_cleanup=$((total_cleanup + removed))
                continue
            fi

            # Resolve PID saat ini
            local st_pid_check
            st_pid_check=$(resolve_pid_for_user "$st_user")

            if [ -z "$st_pid_check" ]; then
                # User offline → remove semua dynamic rule
                local removed
                removed=$(remove_all_dynamic_rules_for_user "$st_user")
                total_cleanup=$((total_cleanup + removed))
                continue
            fi

            # PID alive — cek apakah ephemeral port berubah (reconnect)
            local new_port
            new_port=$(resolve_ephemeral_port_for_pid "$st_pid_check")
            if [ -n "$new_port" ] && [ "$new_port" != "$st_port" ]; then
                # Port berubah → remove old rules + add new rules
                local removed
                removed=$(remove_all_dynamic_rules_for_user "$st_user")
                total_cleanup=$((total_cleanup + removed))

                # Add new rules untuk ephemeral port baru
                local bl_entry bl_mark sport
                bl_entry=$(get_user_blacklist_entry "$st_user")
                bl_mark=$(echo "$bl_entry" | cut -d: -f3)
                if [ -n "$bl_mark" ]; then
                    for sport in $SSH_TUNNEL_PORTS; do
                        if ! is_in_state_file "$st_user" "$new_port" "$sport"; then
                            if add_dynamic_rule_for_user "$st_user" "$st_pid_check" "$new_port" "$sport" "$bl_mark"; then
                                total_assigned=$((total_assigned + 1))
                            fi
                        fi
                    done
                fi
            fi
        done < "$state_copy"
        rm -f "$state_copy"
    fi

    echo "Total assigned: ${total_assigned} PID, Total cleanup: ${total_cleanup} stale rules"
    echo -e "${GRAY}Auth.log cache: ${auth_lines} lines (window: ${AUTH_LOG_WINDOW})${NC}"

    log_msg "WATCH — assigned=${total_assigned} cleanup=${total_cleanup} auth_lines=${auth_lines}" "$WATCHER_LOG_FILE"
}

# ============================================================
# CMD: ADD USER TO BLACKLIST + APPLY RULES + DYNAMIC LAYER
# Step 5/6: Force reconnect (PATTERN 38) supaya dynamic rule apply ke socket baru
# Step 6/6: Add dynamic rule untuk ephemeral port baru
# ============================================================

cmd_add() {
    local user="$1" rate="$2"

    if [ -z "$user" ] || [ -z "$rate" ]; then
        echo -e "${RED}Error: Usage: bw-limit --add <user> <rate_mbps>${NC}"
        return 1
    fi

    if ! is_valid_user "$user"; then
        echo -e "${RED}Error: User '${user}' tidak valid (tidak ada di /etc/passwd)${NC}"
        return 1
    fi

    if is_system_user "$user"; then
        echo -e "${RED}Error: User '${user}' adalah system user — tidak boleh di-limit${NC}"
        return 1
    fi

    if ! [[ "$rate" =~ ^[0-9]+$ ]] || [ "$rate" -lt 1 ] || [ "$rate" -gt 1000 ]; then
        echo -e "${RED}Error: Rate harus integer 1-1000 Mbps${NC}"
        return 1
    fi

    if is_user_in_blacklist "$user"; then
        echo -e "${YELLOW}Warning: User '${user}' sudah ada di blacklist — akan di-replace${NC}"
        cmd_remove "$user" >/dev/null 2>&1
    fi

    local uid
    uid=$(get_uid_for_user "$user")
    if [ -z "$uid" ]; then
        echo -e "${RED}Error: Tidak bisa resolve UID untuk user '${user}'${NC}"
        return 1
    fi

    local idx
    idx=$(get_next_classid_index)

    echo -e "${CYAN}=== ADD USER TO BLACKLIST + APPLY LIMIT (v2.1) ===${NC}"
    echo -e "User      : ${YELLOW}${user}${NC}"
    echo -e "UID       : ${YELLOW}${uid}${NC}"
    echo -e "Rate      : ${YELLOW}${rate} Mbps${NC} (hard cap, P2=B v26 retained)"
    echo -e "Class ID  : ${YELLOW}${idx}${NC} (eth0=${TC_ETH0_MAJOR}:${idx}, lo=${TC_LO_MAJOR}:${idx})"
    echo -e "Mark      : ${YELLOW}${idx}${NC} (iptables -m owner --uid-owner ${uid} -j MARK --set-mark ${idx})"
    echo -e "Dynamic   : ${YELLOW}${idx}${NC} (iptables --sport 109/143 --dport <ephemeral> -j MARK, DOWNLOAD path)"
    echo

    # Step 1/6: Setup tc root
    echo -e "${GRAY}[1/6] Setup tc HTB root (eth0 + lo)...${NC}"
    if setup_tc_root; then
        echo -e "  ${GREEN}OK ✓${NC} eth0=${TC_ETH0_MAJOR}: htb, lo=${TC_LO_MAJOR}: htb, default ${TC_DEFAULT_CLASS_MINOR} (1Gbit)"
    else
        echo -e "  ${RED}FAIL${NC} — periksa tc binary + permission"
        return 1
    fi

    # Step 2/6: Add tc class + filter (eth0 + lo)
    echo -e "${GRAY}[2/6] Add tc class + fw filter (eth0 + lo)...${NC}"
    if add_tc_class_for_user "$user" "$rate" "$idx"; then
        echo -e "  ${GREEN}OK ✓${NC} class ${TC_ETH0_MAJOR}:${idx} (${rate}Mbit) + ${TC_LO_MAJOR}:${idx} (${rate}Mbit) + fw filter handle ${idx}"
    else
        echo -e "  ${RED}FAIL${NC}"
        return 1
    fi

    # Step 3/6: Add iptables per-UID mark rule (UPLOAD path)
    echo -e "${GRAY}[3/6] Add iptables mangle OUTPUT per-UID mark rule (upload path)...${NC}"
    if add_iptables_mark_for_user "$uid" "$idx"; then
        echo -e "  ${GREEN}OK ✓${NC} -m owner --uid-owner ${uid} -j MARK --set-mark ${idx}"
    else
        echo -e "  ${RED}FAIL${NC} — periksa iptables + CAP_NET_ADMIN"
        remove_tc_class_for_user "$idx"
        return 1
    fi

    # Step 4/6: Update blacklist + save iptables
    echo -e "${GRAY}[4/6] Update blacklist + save iptables...${NC}"
    add_user_to_blacklist "$user" "$rate" "$idx"
    iptables-save > "$IPTABLES_SAVE_FILE"
    echo -e "  ${GREEN}OK ✓${NC} blacklist updated: ${user}:${rate}:${idx}"
    echo -e "  ${GREEN}OK ✓${NC} iptables saved to ${IPTABLES_SAVE_FILE}"

    # Step 5/6: Force reconnect user (PATTERN 38 v26)
    echo -e "${GRAY}[5/6] Force reconnect user (PATTERN 38, supaya dynamic rule apply ke socket baru)...${NC}"
    local existing_pid
    existing_pid=$(resolve_pid_for_user "$user")
    if [ -n "$existing_pid" ]; then
        if [ -t 0 ]; then
            echo -e "  User online, PID: ${YELLOW}${existing_pid}${NC}"
            read -p "  Force reconnect? (y/n): " confirm_reconnect
            if [ "$confirm_reconnect" = "y" ] || [ "$confirm_reconnect" = "Y" ]; then
                echo -e "  ${GRAY}Mengirim SIGTERM (graceful, BUKAN SIGKILL) ke PID ${existing_pid}...${NC}"
                kill -TERM "$existing_pid" 2>/dev/null
                echo -e "  ${GRAY}Menunggu 30 detik untuk reconnect...${NC}"
                sleep 30
                echo -e "  ${GREEN}OK ✓${NC} Force reconnect selesai"
            else
                echo -e "  ${GRAY}Skip force reconnect (user pilih n)${NC}"
            fi
        else
            echo -e "  ${GRAY}User online (PID ${existing_pid}) — skip force reconnect (non-interactive mode)${NC}"
            echo -e "  ${GRAY}Dynamic rule akan di-add otomatis oleh cron watcher${NC}"
        fi
    else
        echo -e "  ${GRAY}User offline — skip force reconnect${NC}"
        echo -e "  ${GRAY}Dynamic rule akan di-add saat user connect via cron watcher${NC}"
    fi

    # Step 6/6: Add dynamic rule untuk ephemeral port baru (DOWNLOAD path)
    echo -e "${GRAY}[6/6] Add dynamic rule untuk ephemeral port (download path)...${NC}"
    local new_pid new_ephem dyn_added=0 sport
    new_pid=$(resolve_pid_for_user "$user")
    if [ -n "$new_pid" ]; then
        new_ephem=$(resolve_ephemeral_port_for_pid "$new_pid")
        if [ -n "$new_ephem" ]; then
            for sport in $SSH_TUNNEL_PORTS; do
                if add_dynamic_rule_for_user "$user" "$new_pid" "$new_ephem" "$sport" "$idx"; then
                    dyn_added=$((dyn_added + 1))
                fi
            done
            echo -e "  ${GREEN}OK ✓${NC} ${dyn_added} dynamic rule terpasang (PID ${new_pid}, ephemeral ${new_ephem})"
        else
            echo -e "  ${YELLOW}Warning: socket belum established — dynamic rule akan di-add cron watcher${NC}"
        fi
    else
        echo -e "  ${GRAY}User belum reconnect, dynamic rule akan di-add otomatis oleh cron watcher${NC}"
    fi

    # Install cron watcher (supaya cron ter-setup saat user pertama kali di-add)
    if [ ! -f "$CRON_FILE" ]; then
        echo -e "${GRAY}Install cron watcher...${NC}"
        install_cron
        echo -e "  ${GREEN}OK ✓${NC} cron watcher ter-install di ${CRON_FILE}"
    fi

    echo
    echo -e "${GREEN}=== SETUP COMPLETE (v2.1) ===${NC}"
    echo -e "User ${YELLOW}${user}${NC} (UID ${uid}) sekarang di-limit ${YELLOW}${rate} Mbps${NC} hard cap"
    echo -e "${GRAY}UPLOAD shaping  : iptables per-UID mark (real-time, existing + new socket)${NC}"
    echo -e "${GRAY}DOWNLOAD shaping: dynamic rule per ephemeral port (cron watcher auto-manage)${NC}"
    echo -e "${GRAY}Cron watcher   : ${CRON_INTERVAL} via ${CRON_FILE}${NC}"

    log_msg "ADD user=$user uid=$uid rate=$rate idx=$idx dyn_rules=$dyn_added — OK"
}

# ============================================================
# CMD: REMOVE USER FROM BLACKLIST + CLEANUP RULES + DYNAMIC LAYER
# ============================================================

cmd_remove() {
    local user="$1"

    if [ -z "$user" ]; then
        echo -e "${RED}Error: Usage: bw-limit --remove <user>${NC}"
        return 1
    fi

    if ! is_user_in_blacklist "$user"; then
        echo -e "${YELLOW}Warning: User '${user}' tidak ada di blacklist — tidak ada yang dihapus${NC}"
        return 0
    fi

    local entry old_rate old_idx uid
    entry=$(get_user_blacklist_entry "$user")
    old_rate=$(echo "$entry" | cut -d: -f2)
    old_idx=$(echo "$entry" | cut -d: -f3)
    uid=$(get_uid_for_user "$user")

    echo -e "${CYAN}=== REMOVE USER FROM BLACKLIST + CLEANUP (v2.1) ===${NC}"
    echo -e "User      : ${YELLOW}${user}${NC}"
    echo -e "UID       : ${YELLOW}${uid}${NC}"
    echo -e "Old Rate  : ${YELLOW}${old_rate} Mbps${NC}"
    echo -e "Old Index : ${YELLOW}${old_idx}${NC}"
    echo

    # Step 1/4: Hapus SEMUA dynamic rule untuk user (NEW v2.1)
    echo -e "${GRAY}[1/4] Hapus semua dynamic rule untuk user (DOWNLOAD path)...${NC}"
    local dyn_removed
    dyn_removed=$(remove_all_dynamic_rules_for_user "$user")
    echo -e "  ${GREEN}OK ✓${NC} ${dyn_removed} dynamic rule dihapus dari iptables + state file"

    # Step 2/4: Remove iptables per-UID mark rule (UPLOAD path)
    echo -e "${GRAY}[2/4] Remove iptables mangle per-UID mark rule (upload path)...${NC}"
    remove_iptables_mark_for_user "$uid" "$old_idx"
    echo -e "  ${GREEN}OK ✓${NC} iptables mark rule untuk UID ${uid} idx ${old_idx} dihapus"

    # Step 3/4: Remove tc class + filter
    echo -e "${GRAY}[3/4] Remove tc class + fw filter (eth0 + lo)...${NC}"
    remove_tc_class_for_user "$old_idx"
    echo -e "  ${GREEN}OK ✓${NC} class ${TC_ETH0_MAJOR}:${old_idx} + ${TC_LO_MAJOR}:${old_idx} + filter dihapus"

    # Step 4/4: Remove from blacklist + save iptables
    echo -e "${GRAY}[4/4] Remove from blacklist + save iptables...${NC}"
    remove_user_from_blacklist "$user"
    iptables-save > "$IPTABLES_SAVE_FILE"
    echo -e "  ${GREEN}OK ✓${NC} blacklist entry dihapus"
    echo -e "  ${GREEN}OK ✓${NC} iptables saved"

    echo
    echo -e "${GREEN}=== REMOVE COMPLETE (v2.1) ===${NC}"
    echo -e "User ${YELLOW}${user}${NC} tidak lagi di-limit"
    echo -e "${GRAY}Dynamic rules (download) + per-UID mark (upload) + tc class semuanya dihapus${NC}"
    echo -e "${GRAY}Socket existing sekarang full speed${NC}"

    log_msg "REMOVE user=$user uid=$uid old_rate=$old_rate old_idx=$old_idx dyn_removed=$dyn_removed — OK"
}

# ============================================================
# CMD: LIST BLACKLIST (simple table)
# ============================================================

cmd_list() {
    ensure_config_dir
    if [ ! -s "$BLACKLIST_FILE" ]; then
        echo -e "${YELLOW}Blacklist kosong — belum ada user di-limit${NC}"
        return 0
    fi

    echo -e "${CYAN}=== BANDWIDTH LIMIT BLACKLIST ===${NC}"
    echo
    printf "%-15s %-8s %-8s %-8s %-15s\n" "USER" "UID" "RATE" "IDX" "STATUS"
    printf "%-15s %-8s %-8s %-8s %-15s\n" "---------------" "--------" "--------" "--------" "---------------"

    local user rate idx uid iptables_status tc_status
    while IFS=: read -r user rate idx; do
        [ -z "$user" ] && continue
        uid=$(get_uid_for_user "$user")

        # Check iptables rule exists
        if iptables -t mangle -C OUTPUT -m owner --uid-owner "$uid" -j MARK --set-mark "$idx" 2>/dev/null; then
            iptables_status="IPT OK"
        else
            iptables_status="IPT MISS"
        fi

        # Check tc class exists (eth0)
        if tc class show dev "$ETH0_IFACE" 2>/dev/null | grep -q "${TC_ETH0_MAJOR}:${idx} "; then
            tc_status="TC OK"
        else
            tc_status="TC MISS"
        fi

        printf "%-15s %-8s %-8s %-8s %-15s\n" "$user" "$uid" "${rate}M" "$idx" "${iptables_status} ${tc_status}"
    done < "$BLACKLIST_FILE"

    echo
    echo -e "${GRAY}Total: $(wc -l < "$BLACKLIST_FILE") user di blacklist${NC}"
}

# ============================================================
# CMD: SHOW DETAILED STATUS (v2.1 — tambah dynamic rules + PID section)
# ============================================================

cmd_show() {
    echo -e "${CYAN}=== BANDWIDTH LIMIT DETAILED STATUS (v2.1) ===${NC}"
    echo

    # Blacklist
    echo -e "${YELLOW}--- BLACKLIST (${BLACKLIST_FILE}) ---${NC}"
    if [ -s "$BLACKLIST_FILE" ]; then
        cat "$BLACKLIST_FILE"
    else
        echo -e "${GRAY}(kosong)${NC}"
    fi
    echo

    # iptables mangle OUTPUT
    echo -e "${YELLOW}--- IPTABLES MANGLE OUTPUT (per-UID + dynamic) ---${NC}"
    iptables -t mangle -L OUTPUT -n -v --line-numbers 2>&1 | head -40
    echo

    # tc eth0
    echo -e "${YELLOW}--- TC ETH0 (qdisc + class + filter) ---${NC}"
    tc qdisc show dev "$ETH0_IFACE"
    echo
    tc class show dev "$ETH0_IFACE" 2>/dev/null | head -20
    echo
    tc filter show dev "$ETH0_IFACE" 2>/dev/null | head -10
    echo

    # tc lo
    echo -e "${YELLOW}--- TC LO (qdisc + class + filter) ---${NC}"
    tc qdisc show dev "$LO_IFACE"
    echo
    tc class show dev "$LO_IFACE" 2>/dev/null | head -20
    echo
    tc filter show dev "$LO_IFACE" 2>/dev/null | head -10
    echo

    # NEW v2.1: Dynamic rules state file
    echo -e "${YELLOW}--- DYNAMIC RULES (state file: ${STATE_FILE}) ---${NC}"
    if [ -s "$STATE_FILE" ]; then
        printf "%-12s %-8s %-14s %-6s %-6s\n" "USER" "PID" "EPHEMERAL" "SPORT" "MARK"
        printf "%-12s %-8s %-14s %-6s %-6s\n" "------------" "--------" "--------------" "------" "------"
        while IFS=: read -r st_user st_pid st_port st_sport st_mark; do
            [ -z "$st_user" ] && continue
            printf "%-12s %-8s %-14s %-6s %-6s\n" "$st_user" "$st_pid" "$st_port" "$st_sport" "$st_mark"
        done < "$STATE_FILE"
    else
        echo -e "${GRAY}(kosong — belum ada dynamic rule terpasang)${NC}"
    fi
    echo

    # NEW v2.1: PID saat ini per blacklist user
    echo -e "${YELLOW}--- PID SAAT INI PER BLACKLIST USER ---${NC}"
    if [ -s "$BLACKLIST_FILE" ]; then
        printf "%-12s %-8s %-14s %-12s\n" "USER" "PID" "EPHEMERAL" "STATUS"
        printf "%-12s %-8s %-14s %-12s\n" "------------" "--------" "--------------" "------------"
        while IFS=: read -r bl_user bl_rate bl_idx; do
            [ -z "$bl_user" ] && continue
            local pid ephem status_str
            pid=$(resolve_pid_for_user "$bl_user")
            if [ -z "$pid" ]; then
                status_str="OFFLINE"
                printf "%-12s %-8s %-14s %-12s\n" "$bl_user" "-" "-" "$status_str"
                continue
            fi
            ephem=$(resolve_ephemeral_port_for_pid "$pid")
            if [ -z "$ephem" ]; then
                status_str="NO_TUNNEL"
                printf "%-12s %-8s %-14s %-12s\n" "$bl_user" "$pid" "-" "$status_str"
            else
                status_str="ONLINE"
                printf "%-12s %-8s %-14s %-12s\n" "$bl_user" "$pid" "$ephem" "$status_str"
            fi
        done < "$BLACKLIST_FILE"
    else
        echo -e "${GRAY}(blacklist kosong)${NC}"
    fi
    echo

    # systemd service status
    echo -e "${YELLOW}--- SYSTEMD INIT SERVICE ---${NC}"
    systemctl is-active bw-limit-init.service 2>&1 || echo "(not installed)"
    systemctl is-enabled bw-limit-init.service 2>&1 || echo "(not installed)"
    echo

    # Cron watcher status (updated v2.1)
    echo -e "${YELLOW}--- CRON WATCHER (v2.1) ---${NC}"
    if [ -f "$CRON_FILE" ]; then
        echo -e "Config: ${CRON_FILE}"
        cat "$CRON_FILE"
        echo
        if [ -f "$WATCHER_LOG_FILE" ]; then
            echo -e "Last 5 log entries (${WATCHER_LOG_FILE}):"
            tail -5 "$WATCHER_LOG_FILE" 2>/dev/null
        else
            echo -e "${GRAY}(belum ada log watcher — cron belum pernah jalan)${NC}"
        fi
    else
        echo -e "${GRAY}(cron watcher belum di-install — jalankan: bw-limit --install-cron)${NC}"
    fi
}

# ============================================================
# CMD: INIT (rebuild tc + iptables + dynamic rules dari blacklist)
# Untuk systemd boot — restore semua rule dari blacklist
# ============================================================

cmd_init() {
    echo -e "${CYAN}=== INIT: REBUILD TC + IPTABLES + DYNAMIC RULES FROM BLACKLIST (v2.1) ===${NC}"
    echo

    ensure_config_dir
    ensure_state_file

    if [ ! -s "$BLACKLIST_FILE" ]; then
        echo -e "${YELLOW}Blacklist kosong — setup tc root only${NC}"
        setup_tc_root
        echo -e "${GREEN}TC root setup OK (eth0 + lo)${NC}"
        > "$STATE_FILE"
        echo -e "${GRAY}State file dikosongkan (tidak ada user di blacklist)${NC}"
        log_msg "INIT — blacklist empty, tc root only — OK"
        return 0
    fi

    # Step 1/3: Setup tc root
    echo -e "${GRAY}[1/3] Setup tc HTB root (eth0 + lo)...${NC}"
    setup_tc_root
    echo -e "  ${GREEN}OK ✓${NC}"

    # Step 2/3: Rebuild per-UID rules dari blacklist
    echo -e "${GRAY}[2/3] Rebuild per-UID mark + tc class dari blacklist...${NC}"
    local count=0 skip=0
    while IFS=: read -r user rate idx; do
        [ -z "$user" ] && continue

        local uid
        uid=$(get_uid_for_user "$user")
        if [ -z "$uid" ]; then
            echo -e "  ${YELLOW}SKIP${NC} user '${user}' — UID tidak resolve"
            skip=$((skip + 1))
            continue
        fi

        if ! [[ "$rate" =~ ^[0-9]+$ ]] || [ "$rate" -lt 1 ]; then
            echo -e "  ${YELLOW}SKIP${NC} user '${user}' — rate tidak valid: ${rate}"
            skip=$((skip + 1))
            continue
        fi

        if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ]; then
            echo -e "  ${YELLOW}SKIP${NC} user '${user}' — idx tidak valid: ${idx}"
            skip=$((skip + 1))
            continue
        fi

        # Rebuild tc class + filter
        add_tc_class_for_user "$user" "$rate" "$idx"
        # Rebuild iptables per-UID mark (idempotent)
        add_iptables_mark_for_user "$uid" "$idx"

        echo -e "  ${GREEN}OK ✓${NC} user='${user}' uid=${uid} rate=${rate}M idx=${idx}"
        count=$((count + 1))
    done < "$BLACKLIST_FILE"

    # Save iptables
    iptables-save > "$IPTABLES_SAVE_FILE"
    echo -e "  ${GREEN}OK ✓${NC} iptables saved (${count} user rebuilt)"

    # Step 3/3: Rebuild dynamic rules dari scan PID + blacklist
    echo -e "${GRAY}[3/3] Rebuild dynamic rules (scan PID + ephemeral port)...${NC}"
    > "$STATE_FILE"   # clear state file terlebih dahulu
    local dyn_count=0
    while IFS=: read -r user rate idx; do
        [ -z "$user" ] && continue

        local pid ephem sport
        pid=$(resolve_pid_for_user "$user")
        if [ -z "$pid" ]; then
            echo -e "  ${GRAY}SKIP${NC} user '${user}' — offline (rule akan di-add cron watcher)"
            continue
        fi

        ephem=$(resolve_ephemeral_port_for_pid "$pid")
        if [ -z "$ephem" ]; then
            echo -e "  ${GRAY}SKIP${NC} user '${user}' — socket tidak established"
            continue
        fi

        for sport in $SSH_TUNNEL_PORTS; do
            if add_dynamic_rule_for_user "$user" "$pid" "$ephem" "$sport" "$idx"; then
                dyn_count=$((dyn_count + 1))
            fi
        done

        echo -e "  ${GREEN}OK ✓${NC} user='${user}' pid=${pid} ephemeral=${ephem}"
    done < "$BLACKLIST_FILE"
    echo -e "  ${GREEN}Total dynamic rules rebuilt: ${dyn_count}${NC}"

    echo
    echo -e "${GREEN}=== INIT COMPLETE (v2.1) ===${NC}"
    echo -e "Total rebuilt (per-UID)   : ${YELLOW}${count}${NC} user"
    echo -e "Total skip                : ${YELLOW}${skip}${NC} user"
    echo -e "Total dynamic rules rebuilt: ${YELLOW}${dyn_count}${NC}"
    echo -e "${GRAY}Per-UID mark: real-time (existing + new socket)${NC}"
    echo -e "${GRAY}Dynamic rule : per-ephemeral-port (auto-manage by cron watcher)${NC}"

    log_msg "INIT — rebuilt per-UID=${count} skip=${skip} dyn_rules=${dyn_count} — OK"
}

# ============================================================
# CMD: RESET (clear ALL — dynamic + iptables + tc + blacklist + state + cron)
# ============================================================

cmd_reset() {
    echo -e "${RED}=== WARNING: RESET ALL BANDWIDTH LIMIT (v2.1) ===${NC}"
    echo -e "${RED}Ini akan menghapus SEMUA: dynamic rules + iptables + tc class + blacklist + state + cron${NC}"
    echo
    read -p "Ketik 'YA' (huruf besar) untuk konfirmasi: " confirm
    if [ "$confirm" != "YA" ]; then
        echo -e "${YELLOW}Dibatalkan${NC}"
        return 0
    fi

    echo
    # Step 1/7: Remove semua dynamic rules + clear state file
    echo -e "${GRAY}[1/7] Remove semua dynamic rules + clear state file...${NC}"
    local total_dyn=0
    if [ -s "$STATE_FILE" ]; then
        local state_copy
        state_copy=$(mktemp)
        cp "$STATE_FILE" "$state_copy"
        local processed_users=""
        while IFS=: read -r st_user _ _ _ _; do
            [ -z "$st_user" ] && continue
            case " $processed_users " in
                *" $st_user "*) continue ;;
            esac
            processed_users="$processed_users $st_user"
            local removed
            removed=$(remove_all_dynamic_rules_for_user "$st_user")
            total_dyn=$((total_dyn + removed))
        done < "$state_copy"
        rm -f "$state_copy"
    fi
    > "$STATE_FILE"
    echo -e "  ${GREEN}OK ✓${NC} ${total_dyn} dynamic rule dihapus, state file dikosongkan"

    # Step 2/7: Remove semua iptables per-UID mark rules
    echo -e "${GRAY}[2/7] Remove semua iptables per-UID mark rules...${NC}"
    iptables -t mangle -S OUTPUT 2>/dev/null | grep -- "--set-mark" | while read -r rule; do
        local del_rule=${rule/-A/-D}
        iptables -t mangle $del_rule 2>/dev/null
    done
    echo -e "  ${GREEN}OK ✓${NC}"

    # Step 3/7: Teardown tc (eth0 + lo)
    echo -e "${GRAY}[3/7] Teardown tc (eth0 + lo)...${NC}"
    teardown_tc_root
    echo -e "  ${GREEN}OK ✓${NC} eth0 restored ke fq, lo cleared"

    # Step 4/7: Clear blacklist
    echo -e "${GRAY}[4/7] Clear blacklist...${NC}"
    ensure_config_dir
    > "$BLACKLIST_FILE"
    echo -e "  ${GREEN}OK ✓${NC} blacklist dikosongkan"

    # Step 5/7: Clear state file (sudah di step 1, pastikan kosong)
    echo -e "${GRAY}[5/7] Clear state file...${NC}"
    > "$STATE_FILE"
    echo -e "  ${GREEN}OK ✓${NC} state file dikosongkan"

    # Step 6/7: Remove cron watcher config
    echo -e "${GRAY}[6/7] Remove cron watcher config...${NC}"
    if [ -f "$CRON_FILE" ]; then
        rm -f "$CRON_FILE"
        echo -e "  ${GREEN}OK ✓${NC} ${CRON_FILE} dihapus"
    else
        echo -e "  ${GRAY}(cron watcher tidak ada — skip)${NC}"
    fi
    rm -f "$FLOCK_FILE" 2>/dev/null

    # Step 7/7: Save iptables
    echo -e "${GRAY}[7/7] Save iptables...${NC}"
    iptables-save > "$IPTABLES_SAVE_FILE"
    echo -e "  ${GREEN}OK ✓${NC}"

    echo
    echo -e "${GREEN}=== RESET COMPLETE (v2.1) ===${NC}"
    echo -e "Semua rule dihapus: dynamic + per-UID + tc + blacklist + state + cron"

    log_msg "RESET — all cleared (dynamic=$total_dyn)"
}

# ============================================================
# CMD: HELP (v2.1 — tambah documentation dynamic rules + cron + state + force reconnect)
# ============================================================

cmd_help() {
    show_header
    cat <<EOF
${CYAN}USAGE:${NC}
  bw-limit [OPTIONS]
  bw-limit --add <user> <rate_mbps>
  bw-limit --remove <user>
  bw-limit --list
  bw-limit --show
  bw-limit --watch                (manual trigger cron watcher logic)
  bw-limit --init
  bw-limit --reset
  bw-limit --install-cron
  bw-limit --help
  bw-limit --version

${CYAN}OPTIONS:${NC}
  --add <user> <mbps>     Add user ke blacklist + apply limit + force reconnect + dynamic rule
  --remove <user>         Remove user + cleanup dynamic + per-UID iptables + tc
  --list                  List blacklist (simple table)
  --show                  Detailed status (dynamic rules + PID + iptables + tc + cron)
  --watch                 Manual trigger: scan PID + auth.log + add/remove dynamic rules
  --init                  Rebuild tc + iptables + dynamic rules dari blacklist (boot time)
  --reset                 Clear ALL (dynamic + iptables + tc + blacklist + state + cron)
  --install-cron          Install cron watcher di /etc/cron.d/bw-limit
  --help                  Tampilkan help ini
  --version               Tampilkan versi

${CYAN}EXAMPLES:${NC}
  bw-limit --add nyunya 5        # Limit nyunya ke 5 Mbps (hard cap + dynamic rule)
  bw-limit --add anti 3          # Limit anti ke 3 Mbps
  bw-limit --list                # Lihat semua user di blacklist
  bw-limit --remove nyunya       # Hapus limit untuk nyunya
  bw-limit --show                # Audit detail status (termasuk dynamic rules)
  bw-limit --watch               # Manual trigger cron watcher
  bw-limit --init                # Rebuild dari blacklist (boot time)
  bw-limit --install-cron        # Install cron watcher manual

${CYAN}DESIGN v2.1 (DYNAMIC RULE LAYER — solve DOWNLOAD shaping):${NC}
  - RETAINED v2.0: iptables MARK per-UID (mangle OUTPUT, -m owner --uid-owner)
    → bekerja untuk UPLOAD path (forwarding socket eth0 UID=user post-Dropbear-upgrade)
    → GAGAL untuk DOWNLOAD path (SSH tunnel socket UID=root by design)
  - NEW v2.1: Dynamic iptables rule per ephemeral port
    → iptables -t mangle OUTPUT -o lo -p tcp --sport 109 --dport <ephemeral> -j MARK
    → mark by --sport + --dport (BUKAN by UID)
    → captures Dropbear→sslh packet direction (DOWNLOAD path)
  - NEW v2.1: cron watcher (*/2 min, flock -n) auto add/remove dynamic rules
  - NEW v2.1: state file tracking dynamic rules terpasang
  - NEW v2.1: force reconnect (PATTERN 38) di cmd_add supaya dynamic rule apply ke socket baru

${CYAN}DESIGN v2.0 (RETAINED — PATH X SUCCESS foundation):${NC}
  - iptables MARK per-UID (mangle OUTPUT, -m owner --uid-owner)
  - tc HTB di eth0 (shape upload) + tc HTB di lo (shape download)
  - tc fw classifier (handle MARK fw flowid CLASS)
  - Hard cap (rate=ceil, no burst)
  - Blacklist manual by admin (P3=C v26 retained)

${CYAN}DYNAMIC RULES MANAGEMENT (NEW v2.1 — PATTERN 46):${NC}
  Kenapa dynamic rule perlu?
  - SSH tunnel socket (lo port 109/143) UID=root by design
    (Dropbear master accept() sebelum fork+setuid, socket created UID=root)
  - iptables -m owner --uid-owner GAGAL match packet ini (UID=root, BUKAN user UID)
  - Solusi: mark by --sport 109 --dport <ephemeral_port> (BUKAN by UID)
  - Capture Dropbear→sslh packet direction (DOWNLOAD path: data internet → user)
  - Empirical PROVEN: 60s YouTube+TikTok+live browsing → rule matched 2,511 pkt / 20 MB
    tc class 2:2 Sent +21.7 MB shaped, overlimits +3,372, backlog 7 packets

${CYAN}CRON WATCHER (NEW v2.1):${NC}
  - Interval: ${CRON_INTERVAL} (PATTERN 34, match VPS 2 core/2GB capacity)
  - flock -n ${FLOCK_FILE} (PATTERN 35, skip silently kalau run sebelumnya masih jalan)
  - Scan auth.log (journalctl --since "${AUTH_LOG_WINDOW}" fallback /var/log/auth.log tail -200)
  - Auto add dynamic rule untuk user blacklist yang online
  - Auto remove dynamic rule untuk user offline atau port berubah (reconnect)
  - Config: ${CRON_FILE}
  - Log: ${WATCHER_LOG_FILE}

${CYAN}STATE FILE (NEW v2.1):${NC}
  Format: <user>:<pid>:<ephemeral_port>:<sport>:<mark>
  Contoh:
    anti:326148:10548:109:1
    nyunya:401181:52252:109:2
  Path: ${STATE_FILE}

${CYAN}FORCE RECONNECT (NEW v2.1, PATTERN 38):${NC}
  - cmd_add mengirim SIGTERM (kill -TERM) ke Dropbear PID existing
  - User reconnect dalam 30 detik → dynamic rule apply ke socket baru
  - SIGTERM graceful (BUKAN SIGKILL) → Dropbear cleanup session properly
  - Skip kalau user offline (dynamic rule akan di-add cron watcher saat user connect)
  - Skip kalau non-interactive mode (stdin bukan TTY)

${CYAN}FILES:${NC}
  /usr/bin/bw-limit                   Script utama
  /etc/bw-limit/blacklist.txt         Blacklist (format: user:rate_mbps:classid_index)
  /etc/bw-limit/iptables-rules.save   Iptables rules save (for restore)
  /etc/bw-limit/ephemeral-rules.save  State file dynamic rules (NEW v2.1)
  /etc/cron.d/bw-limit                Cron watcher config (NEW v2.1)
  /tmp/bw-limit.lock                  flock lockfile (NEW v2.1)
  /etc/systemd/system/bw-limit-init.service  systemd init (rebuild on boot)
  /var/log/bw-limit.log               Event log (cmd_add/remove/init/reset)
  /var/log/bw-limit-watcher.log       Cron watcher log (NEW v2.1)

${CYAN}ETIKA (KOMITMEN USER v21+v24):${NC}
  - Throttle HANYA untuk user blacklist manual by admin
  - BUKAN auto-kick, BUKAN throttle semua user
  - User normal tetap full speed (default class 1Gbit)

${CYAN}LIMITATION:${NC}
  - Hanya bekerja untuk user yang login via Dropbear 2026.94+ (UID=user post-auth)
  - User yang login via SSH direct (port 22) juga work (UID=user via PAM)
  - Dynamic rule (DOWNLOAD path) hanya untuk SSH tunnel via sslh→Dropbear loopback (port 109/143)

${PINK}HAXOR TUNNELING — DEKENG ANE BIAK BELITONG${NC}
EOF
}

# ============================================================
# INTERACTIVE MENU (Pattern 1+3 — re-entrant while-loop)
# v2.1: tambah opsi 05 Watch, renumber 01-08
# ============================================================

show_menu() {
    while true; do
        clear
        show_header
        echo
        echo -e "${YELLOW}MONITORING & TOOLS:${NC}"
        echo -e "  ${CYAN}01${NC}) Add User (limit bandwidth)"
        echo -e "  ${CYAN}02${NC}) Remove User"
        echo -e "  ${CYAN}03${NC}) List Blacklist"
        echo -e "  ${CYAN}04${NC}) Show Detail Status"
        echo -e "  ${CYAN}05${NC}) Watch (manual trigger dynamic rules)"
        echo -e "  ${CYAN}06${NC}) Init (rebuild from blacklist)"
        echo -e "  ${CYAN}07${NC}) Reset (clear ALL)"
        echo -e "  ${CYAN}08${NC}) Help"
        echo
        echo -e "  ${GRAY}[0X] Exit${NC}"
        echo
        echo -e -n "${GRAY}Pilih opsi [01-08 / 0X]: ${NC}"
        read -r choice
        handle_choice "$choice"
    done
}

handle_choice() {
    case "$1" in
        01|1)
            clear
            echo -e "${CYAN}=== ADD USER TO BLACKLIST ===${NC}"
            echo
            echo -e -n "${GRAY}Masukkan username: ${NC}"
            read -r add_user
            echo -e -n "${GRAY}Masukkan rate (Mbps, 1-1000): ${NC}"
            read -r add_rate
            echo
            cmd_add "$add_user" "$add_rate"
            pause
            ;;
        02|2)
            clear
            echo -e "${CYAN}=== REMOVE USER FROM BLACKLIST ===${NC}"
            echo
            cmd_list
            echo
            echo -e -n "${GRAY}Masukkan username yang akan di-remove: ${NC}"
            read -r rem_user
            echo
            cmd_remove "$rem_user"
            pause
            ;;
        03|3)
            clear
            cmd_list
            pause
            ;;
        04|4)
            clear
            cmd_show
            pause
            ;;
        05|5)
            clear
            echo -e "${CYAN}=== WATCH (MANUAL TRIGGER DYNAMIC RULES) ===${NC}"
            echo
            cmd_watch_ephemeral
            pause
            ;;
        06|6)
            clear
            cmd_init
            pause
            ;;
        07|7)
            clear
            cmd_reset
            pause
            ;;
        08|8)
            clear
            cmd_help
            pause
            ;;
        0|00|x|X|0x|0X)
            clear
            echo -e "${GRAY}Exit bw-limit. Balik ke menu utama...${NC}"
            sleep 1
            exit 0
            ;;
        *)
            echo -e "${RED}Opsi tidak dikenal. Pilih: 01-08 atau 0X (exit)${NC}"
            sleep 2
            ;;
    esac
}

# ============================================================
# MAIN
# ============================================================

main() {
    # Root check (iptables + tc butuh CAP_NET_ADMIN)
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}Error: bw-limit harus dijalankan sebagai root${NC}"
        echo -e "${GRAY}(iptables + tc + ss butuh CAP_NET_ADMIN)${NC}"
        exit 1
    fi

    # Validate required commands (Pattern 6)
    local cmds=(iptables tc id grep awk sed ss journalctl ps)
    for cmd in "${cmds[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${RED}Error: command '${cmd}' tidak ditemukan${NC}"
            exit 1
        fi
    done

    # CLI dispatch
    case "${1:-}" in
        --add)
            cmd_add "$2" "$3"
            ;;
        --remove)
            cmd_remove "$2"
            ;;
        --list)
            cmd_list
            ;;
        --show)
            cmd_show
            ;;
        --watch)
            cmd_watch_ephemeral
            ;;
        --init)
            cmd_init
            ;;
        --reset)
            cmd_reset
            ;;
        --install-cron)
            install_cron
            echo -e "${GREEN}Cron watcher installed at ${CRON_FILE}${NC}"
            echo -e "${GRAY}Schedule: ${CRON_INTERVAL} (flock -n ${FLOCK_FILE})${NC}"
            ;;
        --help|-h)
            cmd_help
            ;;
        --version|-v)
            echo "bw-limit v${SCRIPT_VERSION} (Sesi 2.10 - v34)"
            echo "HAXOR TUNNELING — DEKENG ANE BIAK BELITONG"
            echo "iptables MARK per-UID + dynamic per-ephemeral + tc HTB (eth0+lo)"
            ;;
        "")
            # Interactive menu
            show_menu
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Run 'bw-limit --help' for usage"
            exit 1
            ;;
    esac
}

main "$@"
