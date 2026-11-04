#!/bin/bash
# ============================================================
# Script  : bw-limit.sh
# Version : v2.0 (Sesi 2.9-A - v32) — IPTABLES MARK per-UID + tc HTB
# Path    : /ssh/bw-limit.sh
# Brand   : HAXOR TUNNELING
# Tagline : DEKENG ANE BIAK BELITONG
# Source  : Original HAXOR wrapper - v2.0 rewrite (replace v1.1 cgroup approach)
# ============================================================
# DESIGN v2.0 (PATH X SUCCESS foundation, Dropbear 2026.94):
#   - iptables -t mangle OUTPUT -m owner --uid-owner <UID> -j MARK --set-mark <idx>
#   - tc HTB root di eth0 (shape upload) + tc HTB root di lo (shape download)
#   - tc fw classifier: handle <idx> fw flowid <MAJOR>:<idx>
#   - Blacklist manual by admin (P3=C v26 retained)
#   - Hard cap (P2=B v26 retained): rate=ceil, no burst
#   - NO cgroup (chicken-and-egg v29 SOLVED by iptables real-time mark)
#   - NO cron watcher (iptables rules persistent, mark works on existing socket)
#   - NO Force Reconnect (mark works on existing socket real-time, unlike cgroup sk_classid)
# ============================================================
# KOMITMEN ETIS USER v21+v24 (WAJIB dipertahankan):
#   - Throttle HANYA untuk user blacklist manual by admin
#   - BUKAN auto-kick, BUKAN throttle semua user
#   - User normal tetap full speed (default class 1Gbit)
# ============================================================

# ============================================================
# CONSTANTS
# ============================================================
SCRIPT_VERSION="2.0"
CONFIG_DIR="/etc/bw-limit"
BLACKLIST_FILE="${CONFIG_DIR}/blacklist.txt"
IPTABLES_SAVE_FILE="${CONFIG_DIR}/iptables-rules.save"
LOG_FILE="/var/log/bw-limit.log"
TC_ETH0_MAJOR=1
TC_LO_MAJOR=2
TC_DEFAULT_CLASS_MINOR=9999
ETH0_IFACE="eth0"
LO_IFACE="lo"

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
    echo -e "${BG_CYAN}${WHITE}║          BANDWIDTH LIMIT v2.0 - HAXOR TUNNELING              ║${NC}"
    echo -e "${BG_CYAN}${WHITE}║              DEKENG ANE BIAK BELITONG                        ║${NC}"
    echo -e "${BG_TEAL}${WHITE}║  iptables MARK per-UID + tc HTB (eth0+lo) — no cgroup       ║${NC}"
    echo -e "${BG_TEAL}${WHITE}╚══════════════════════════════════════════════════════════════╝${NC}"
}

pause() {
    [ -t 0 ] || return 0
    echo
    echo -e "${GRAY}Tekan enter untuk kembali ke menu...${NC}"
    read -r _
}

log_msg() {
    local msg="$1"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
    echo "$(date '+%Y-%m-%d %H:%M:%S') [bw-limit v${SCRIPT_VERSION}] ${msg}" >> "$LOG_FILE"
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
# Pattern 49 v32 NEW: real-time packet marking per-UID
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
# CMD: ADD USER TO BLACKLIST + APPLY RULES
# NO Force Reconnect needed (iptables mark works on existing socket real-time)
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

    echo -e "${CYAN}=== ADD USER TO BLACKLIST + APPLY LIMIT ===${NC}"
    echo -e "User      : ${YELLOW}${user}${NC}"
    echo -e "UID       : ${YELLOW}${uid}${NC}"
    echo -e "Rate      : ${YELLOW}${rate} Mbps${NC} (hard cap, P2=B v26 retained)"
    echo -e "Class ID  : ${YELLOW}${idx}${NC} (eth0=${TC_ETH0_MAJOR}:${idx}, lo=${TC_LO_MAJOR}:${idx})"
    echo -e "Mark      : ${YELLOW}${idx}${NC} (iptables -m owner --uid-owner ${uid} -j MARK --set-mark ${idx})"
    echo

    # Step 1/4: Setup tc root
    echo -e "${GRAY}[1/4] Setup tc HTB root (eth0 + lo)...${NC}"
    if setup_tc_root; then
        echo -e "  ${GREEN}OK ✓${NC} eth0=${TC_ETH0_MAJOR}: htb, lo=${TC_LO_MAJOR}: htb, default ${TC_DEFAULT_CLASS_MINOR} (1Gbit)"
    else
        echo -e "  ${RED}FAIL${NC} — periksa tc binary + permission"
        return 1
    fi

    # Step 2/4: Add tc class + filter (eth0 + lo)
    echo -e "${GRAY}[2/4] Add tc class + fw filter (eth0 + lo)...${NC}"
    if add_tc_class_for_user "$user" "$rate" "$idx"; then
        echo -e "  ${GREEN}OK ✓${NC} class ${TC_ETH0_MAJOR}:${idx} (${rate}Mbit) + ${TC_LO_MAJOR}:${idx} (${rate}Mbit) + fw filter handle ${idx}"
    else
        echo -e "  ${RED}FAIL${NC}"
        return 1
    fi

    # Step 3/4: Add iptables mark rule
    echo -e "${GRAY}[3/4] Add iptables mangle OUTPUT mark rule...${NC}"
    if add_iptables_mark_for_user "$uid" "$idx"; then
        echo -e "  ${GREEN}OK ✓${NC} -m owner --uid-owner ${uid} -j MARK --set-mark ${idx}"
    else
        echo -e "  ${RED}FAIL${NC} — periksa iptables + CAP_NET_ADMIN"
        remove_tc_class_for_user "$idx"
        return 1
    fi

    # Step 4/4: Update blacklist + save iptables
    echo -e "${GRAY}[4/4] Update blacklist + save iptables...${NC}"
    add_user_to_blacklist "$user" "$rate" "$idx"
    iptables-save > "$IPTABLES_SAVE_FILE"
    echo -e "  ${GREEN}OK ✓${NC} blacklist updated: ${user}:${rate}:${idx}"
    echo -e "  ${GREEN}OK ✓${NC} iptables saved to ${IPTABLES_SAVE_FILE}"

    echo
    echo -e "${GREEN}=== SETUP COMPLETE ===${NC}"
    echo -e "User ${YELLOW}${user}${NC} (UID ${uid}) sekarang di-limit ${YELLOW}${rate} Mbps${NC} hard cap"
    echo -e "${GRAY}Limit bekerja REAL-TIME untuk SEMUA socket (existing + new)${NC}"
    echo -e "${GRAY}NO Force Reconnect needed (mark bekerja saat packet egress, BUKAN socket creation)${NC}"
    echo -e "${GRAY}Limit aktif di eth0 (upload) + lo (download)${NC}"

    log_msg "ADD user=$user uid=$uid rate=$rate idx=$idx — OK"
}

# ============================================================
# CMD: REMOVE USER FROM BLACKLIST + CLEANUP RULES
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

    echo -e "${CYAN}=== REMOVE USER FROM BLACKLIST + CLEANUP ===${NC}"
    echo -e "User      : ${YELLOW}${user}${NC}"
    echo -e "UID       : ${YELLOW}${uid}${NC}"
    echo -e "Old Rate  : ${YELLOW}${old_rate} Mbps${NC}"
    echo -e "Old Index : ${YELLOW}${old_idx}${NC}"
    echo

    # Step 1/3: Remove iptables mark rule
    echo -e "${GRAY}[1/3] Remove iptables mangle mark rule...${NC}"
    remove_iptables_mark_for_user "$uid" "$old_idx"
    echo -e "  ${GREEN}OK ✓${NC} iptables mark rule untuk UID ${uid} idx ${old_idx} dihapus"

    # Step 2/3: Remove tc class + filter
    echo -e "${GRAY}[2/3] Remove tc class + fw filter (eth0 + lo)...${NC}"
    remove_tc_class_for_user "$old_idx"
    echo -e "  ${GREEN}OK ✓${NC} class ${TC_ETH0_MAJOR}:${old_idx} + ${TC_LO_MAJOR}:${old_idx} + filter dihapus"

    # Step 3/3: Remove from blacklist + save iptables
    echo -e "${GRAY}[3/3] Remove from blacklist + save iptables...${NC}"
    remove_user_from_blacklist "$user"
    iptables-save > "$IPTABLES_SAVE_FILE"
    echo -e "  ${GREEN}OK ✓${NC} blacklist entry dihapus"
    echo -e "  ${GREEN}OK ✓${NC} iptables saved"

    echo
    echo -e "${GREEN}=== REMOVE COMPLETE ===${NC}"
    echo -e "User ${YELLOW}${user}${NC} tidak lagi di-limit"
    echo -e "${GRAY}Socket existing sekarang full speed (mark dihapus, packet ke default class)${NC}"

    log_msg "REMOVE user=$user uid=$uid old_rate=$old_rate old_idx=$old_idx — OK"
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
# CMD: SHOW DETAILED STATUS
# ============================================================

cmd_show() {
    echo -e "${CYAN}=== BANDWIDTH LIMIT DETAILED STATUS ===${NC}"
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
    echo -e "${YELLOW}--- IPTABLES MANGLE OUTPUT ---${NC}"
    iptables -t mangle -L OUTPUT -n -v --line-numbers 2>&1 | head -30
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

    # systemd service status
    echo -e "${YELLOW}--- SYSTEMD INIT SERVICE ---${NC}"
    systemctl is-active bw-limit-init.service 2>&1 || echo "(not installed)"
    systemctl is-enabled bw-limit-init.service 2>&1 || echo "(not installed)"
    echo

    # Cron watcher status
    echo -e "${YELLOW}--- CRON WATCHER ---${NC}"
    echo -e "${GRAY}(v2.0 TIDAK pakai cron watcher — iptables mark bekerja real-time, no PID tracking)${NC}"
}

# ============================================================
# CMD: INIT (rebuild tc + iptables from blacklist — for systemd boot)
# ============================================================

cmd_init() {
    echo -e "${CYAN}=== INIT: REBUILD TC + IPTABLES FROM BLACKLIST ===${NC}"
    echo

    ensure_config_dir

    if [ ! -s "$BLACKLIST_FILE" ]; then
        echo -e "${YELLOW}Blacklist kosong — setup tc root only${NC}"
        setup_tc_root
        echo -e "${GREEN}TC root setup OK (eth0 + lo)${NC}"
        log_msg "INIT — blacklist empty, tc root only — OK"
        return 0
    fi

    # Step 1/2: Setup tc root
    echo -e "${GRAY}[1/2] Setup tc HTB root (eth0 + lo)...${NC}"
    setup_tc_root
    echo -e "  ${GREEN}OK ✓${NC}"

    # Step 2/2: Rebuild per user
    echo -e "${GRAY}[2/2] Rebuild user entries from blacklist...${NC}"
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
        # Rebuild iptables mark (idempotent)
        add_iptables_mark_for_user "$uid" "$idx"

        echo -e "  ${GREEN}OK ✓${NC} user='${user}' uid=${uid} rate=${rate}M idx=${idx}"
        count=$((count + 1))
    done < "$BLACKLIST_FILE"

    # Save iptables
    iptables-save > "$IPTABLES_SAVE_FILE"

    echo
    echo -e "${GREEN}=== INIT COMPLETE ===${NC}"
    echo -e "Total rebuilt : ${YELLOW}${count}${NC} user"
    echo -e "Total skip    : ${YELLOW}${skip}${NC} user"
    echo -e "${GRAY}PID assignment TIDAK diperlukan (iptables mark bekerja real-time)${NC}"

    log_msg "INIT — rebuilt ${count} user, skip ${skip} — OK"
}

# ============================================================
# CMD: RESET (clear ALL tc + iptables, clear blacklist)
# ============================================================

cmd_reset() {
    echo -e "${RED}=== WARNING: RESET ALL BANDWIDTH LIMIT ===${NC}"
    echo -e "${RED}Ini akan menghapus SEMUA rule iptables mangle + tc class + blacklist${NC}"
    echo
    echo -e -n "${YELLOW}Ketik 'YA' (huruf besar) untuk konfirmasi: ${NC}"
    read -r confirm
    if [ "$confirm" != "YA" ]; then
        echo -e "${YELLOW}Dibatalkan${NC}"
        return 0
    fi

    echo
    echo -e "${GRAY}[1/4] Remove semua iptables mark rules...${NC}"
    # Parse mangle OUTPUT rules and delete MARK ones
    iptables -t mangle -S OUTPUT 2>/dev/null | grep "MARK" | while read -r rule; do
        local del_rule=${rule/-A/-D}
        iptables -t mangle $del_rule 2>/dev/null
    done
    echo -e "  ${GREEN}OK ✓${NC}"

    echo -e "${GRAY}[2/4] Teardown tc (eth0 + lo)...${NC}"
    teardown_tc_root
    echo -e "  ${GREEN}OK ✓${NC} eth0 restored ke fq, lo cleared"

    echo -e "${GRAY}[3/4] Clear blacklist...${NC}"
    ensure_config_dir
    > "$BLACKLIST_FILE"
    echo -e "  ${GREEN}OK ✓${NC} blacklist dikosongkan"

    echo -e "${GRAY}[4/4] Save iptables...${NC}"
    iptables-save > "$IPTABLES_SAVE_FILE"
    echo -e "  ${GREEN}OK ✓${NC}"

    echo
    echo -e "${GREEN}=== RESET COMPLETE ===${NC}"
    echo -e "Semua rule dihapus, blacklist dikosongkan"

    log_msg "RESET — all cleared"
}

# ============================================================
# CMD: HELP
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
  bw-limit --init
  bw-limit --reset
  bw-limit --help
  bw-limit --version

${CYAN}OPTIONS:${NC}
  --add <user> <mbps>     Add user ke blacklist + apply limit (NO Force Reconnect)
  --remove <user>         Remove user dari blacklist + cleanup rules
  --list                  List blacklist (simple table)
  --show                  Detailed status (iptables + tc + systemd)
  --init                  Rebuild tc + iptables dari blacklist (untuk systemd boot)
  --reset                 Clear ALL (confirmation "YA" required)
  --help                  Tampilkan help ini
  --version               Tampilkan versi

${CYAN}EXAMPLES:${NC}
  bw-limit --add nyunya 5        # Limit nyunya ke 5 Mbps (hard cap)
  bw-limit --add anti 3          # Limit anti ke 3 Mbps
  bw-limit --list                # Lihat semua user di blacklist
  bw-limit --remove nyunya       # Hapus limit untuk nyunya
  bw-limit --show                # Audit detail status
  bw-limit --init                # Rebuild dari blacklist (boot time)

${CYAN}DESIGN v2.0 (PATH X SUCCESS foundation):${NC}
  - iptables MARK per-UID (mangle OUTPUT, -m owner --uid-owner)
  - tc HTB di eth0 (shape upload) + tc HTB di lo (shape download)
  - tc fw classifier (handle MARK fw flowid CLASS)
  - Hard cap (rate=ceil, no burst)
  - Blacklist manual by admin (P3=C v26 retained)
  - NO cgroup (chicken-and-egg v29 SOLVED by iptables real-time mark)
  - NO cron watcher (iptables rules persistent)
  - NO Force Reconnect (mark works on existing socket real-time)

${CYAN}FILES:${NC}
  /usr/bin/bw-limit                 Script utama
  /etc/bw-limit/blacklist.txt       Blacklist (format: user:rate_mbps:classid_index)
  /etc/bw-limit/iptables-rules.save Iptables rules save (for restore)
  /etc/systemd/system/bw-limit-init.service  systemd init (rebuild on boot)
  /var/log/bw-limit.log             Event log

${CYAN}ETIKA (KOMITMEN USER v21+v24):${NC}
  - Throttle HANYA untuk user blacklist manual by admin
  - BUKAN auto-kick, BUKAN throttle semua user
  - User normal tetap full speed (default class 1Gbit)

${CYAN}LIMITATION:${NC}
  - Hanya bekerja untuk user yang login via Dropbear 2026.94+ (UID=user post-auth)
  - User yang login via SSH direct (port 22) juga work (UID=user via PAM)
  - TIDAK bekerja untuk Dropbear 2019.78 (UID=root — chicken-and-egg v29)
EOF
}

# ============================================================
# INTERACTIVE MENU (Pattern 1+3 — re-entrant while-loop)
# ============================================================

show_menu() {
    while true; do
        clear
        show_header
        echo
        echo -e "${YELLOW}MONITORING & TOOLS:${NC}"
        echo -e "  ${CYAN}01${NC}) List Blacklist"
        echo -e "  ${CYAN}02${NC}) Add User (limit bandwidth)"
        echo -e "  ${CYAN}03${NC}) Remove User"
        echo -e "  ${CYAN}04${NC}) Show Detail Status"
        echo -e "  ${CYAN}05${NC}) Init (rebuild from blacklist)"
        echo -e "  ${CYAN}06${NC}) Reset (clear ALL)"
        echo -e "  ${CYAN}07${NC}) Help"
        echo
        echo -e "  ${GRAY}[0X] Exit${NC}"
        echo
        echo -e -n "${GRAY}Pilih opsi [01-07 / 0X]: ${NC}"
        read -r choice
        handle_choice "$choice"
    done
}

handle_choice() {
    case "$1" in
        01|1)
            clear
            cmd_list
            pause
            ;;
        02|2)
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
        03|3)
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
        04|4)
            clear
            cmd_show
            pause
            ;;
        05|5)
            clear
            cmd_init
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
            echo -e "${GRAY}Exit bw-limit. Balik ke menu utama...${NC}"
            sleep 1
            exit 0
            ;;
        *)
            echo -e "${RED}Opsi tidak dikenal. Pilih: 01-07 atau 0X (exit)${NC}"
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
        echo -e "${GRAY}(iptables + tc butuh CAP_NET_ADMIN)${NC}"
        exit 1
    fi

    # Validate required commands (Pattern 6)
    local cmds=(iptables tc id grep awk sed)
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
        --init)
            cmd_init
            ;;
        --reset)
            cmd_reset
            ;;
        --help|-h)
            cmd_help
            ;;
        --version|-v)
            echo "bw-limit v${SCRIPT_VERSION} (Sesi 2.9-A - v32)"
            echo "HAXOR TUNNELING — DEKENG ANE BIAK BELITONG"
            echo "iptables MARK per-UID + tc HTB (eth0+lo)"
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
