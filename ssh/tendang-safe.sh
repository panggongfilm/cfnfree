#!/bin/bash
# ============================================================================
# Script  : tendang-safe.sh
# Version : 1.1 (Sesi v14 - Sesi 2.4-A Kick Aman + FIX1 Tendang User)
# Purpose : Tendang koneksi user SSH/Dropbear/WebSocket secara AMAN
#           Mode 1: Targeted per-IP (kernel-level ss -K) - untuk direct conn
#           Mode 2: Kill PID per-User (Dropbear child) - untuk Cloudfront/WS-TLS
#           NO restart service (anti pattern tendang.sh DESTRUCTIVE)
# Source  : Original HAXOR wrapper
#           - Pattern 1 jembatan 13D (ss -K dst <ip>) untuk Mode 1
#           - Pattern 19 v13 (auth.log PID matching) untuk resolve user
# Brand   : HAXOR + Tagline "DEKENG ANE BIAK BELITONG"
# Usage   : tendang-safe                    (interactive menu, recommended)
#           tendang-safe --list             (CLI: list kandidat per-IP)
#           tendang-safe --list-users       (CLI: list user aktif + PID)
#           tendang-safe --kick <IP>        (CLI: tendang IP dgn konfirmasi)
#           tendang-safe --kick-user <USER> (CLI: tendang user (kill PID))
#           tendang-safe --dry-run <IP>     (CLI: simulasi tendang IP)
#           tendang-safe --help             (CLI: tampilkan help)
# ============================================================================

# --- Palette 256-color (ANSI-C quoting $'...' WAJIB - Lesson FIX1 v6) ---
# Pakai ANSI-C quoting supaya byte ESC tersimpan langsung di variabel,
# sehingga warna tampil benar di echo, echo -e, read -p, dan printf.
CYAN=$'\033[38;5;51m'
TEAL=$'\033[38;5;80m'
GREEN=$'\033[38;5;48m'
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
SCRIPT_VERSION="1.1"
LOG_WINDOW="24 hours ago"
TUNNEL_PORTS="22 109 143 443 8880"
CACHE_FILE="/tmp/tendang-safe-candidates.cache"
CACHE_FILE_USERS="/tmp/tendang-safe-users.cache"

# System users yang TIDAK boleh di-tendang (filter dari list)
SYSTEM_USERS_FILTER="root sslh daemon nobody systemd+ sshd www-data message+ syslog usbmux dnsmasq"

# --- Auto-detect VPS IP (untuk safety filter, jangan hardcode) ---
detect_vps_ip() {
    local ip
    ip=$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    [ -z "$ip" ] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$ip" ] && ip="203.194.112.128"  # Fallback hardcode (info dari jembatan 14A)
    echo "$ip"
}
VPS_IP=$(detect_vps_ip)

# --- Helper: cek IP protected (127.0.0.1, VPS IP, private range) ---
is_protected_ip() {
    local ip=$1
    # Cek exact match
    case "$ip" in
        127.0.0.1|0.0.0.0|::1|"") return 0 ;;
        "$VPS_IP") return 0 ;;
    esac
    # Cek private range
    case "$ip" in
        10.*) return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
        192.168.*) return 0 ;;
        169.254.*) return 0 ;;
    esac
    return 1
}

# --- Helper: get service name dari local port ---
get_service_name() {
    local port=$1
    case "$port" in
        22)   echo "SSH-direct" ;;
        109)  echo "Dropbear" ;;
        143)  echo "Dropbear-2" ;;
        443)  echo "WS-TLS" ;;
        8880) echo "WS-NonTLS" ;;
        *)    echo "port:$port" ;;
    esac
}

# --- Helper: resolve user dari PID via Pattern 19 (Hybrid 4-layer resolver) ---
# Adaptasi dari pantau.sh v13 Sesi-2.3-FIX3 (PROVEN for SSH direct + Dropbear via WS)
# Layer 1: loginuid (untuk SSH direct via PAM)
# Layer 2: auth.log PID matching (untuk Dropbear via WebSocket)
# Layer 3: ps -o args= regex (untuk sshd: USER pattern)
# Layer 4: /proc/<pid>/status Uid fallback
resolve_user() {
    local pid=$1
    local user="-"

    [ -z "$pid" ] && { echo "-"; return; }
    [ ! -d "/proc/$pid" ] && { echo "-"; return; }

    # Layer 1: loginuid (untuk SSH direct via PAM)
    if [ -r "/proc/$pid/loginuid" ]; then
        local loginuid
        loginuid=$(cat /proc/$pid/loginuid 2>/dev/null)
        if [ -n "$loginuid" ] && [ "$loginuid" != "4294967295" ] && [ "$loginuid" != "-1" ]; then
            if [ "$loginuid" = "0" ]; then
                echo "root"
                return
            else
                local u
                u=$(getent passwd "$loginuid" 2>/dev/null | cut -d: -f1)
                [ -n "$u" ] && { echo "$u"; return; }
            fi
        fi
    fi

    # Layer 2: auth.log PID matching (untuk Dropbear via WebSocket)
    # Adaptasi dari cekssh.sh cfnfree - Pattern 19 v13
    if command -v journalctl >/dev/null 2>&1; then
        local log_line
        log_line=$(journalctl --since "$LOG_WINDOW" --no-pager -o cat 2>/dev/null | \
                   grep -E "\[$pid\]" | \
                   grep -E "(Password auth succeeded|Accepted password for|Accepted publickey for)" | \
                   tail -1)
        if [ -n "$log_line" ]; then
            # Dropbear: "dropbear[PID]: Password auth succeeded for 'USER' from IP:PORT"
            if [[ $log_line =~ Password\ auth\ succeeded\ for\ \'([^\']+)\' ]]; then
                user="${BASH_REMATCH[1]}"
                [ -n "$user" ] && { echo "$user"; return; }
            fi
            # SSH: "sshd[PID]: Accepted password for USER from IP PORT ssh2"
            if [[ $log_line =~ Accepted\ (password|publickey)\ for\ ([a-zA-Z0-9_.-]+)\ from ]]; then
                user="${BASH_REMATCH[2]}"
                [ -n "$user" ] && { echo "$user"; return; }
            fi
        fi
    fi

    # Layer 3: ps -o args= regex (sshd: USER pattern - Lesson 12 v12)
    local args
    args=$(ps -p "$pid" -o args= 2>/dev/null)
    if [ -n "$args" ]; then
        if [[ $args =~ ^sshd:\ ([a-zA-Z0-9_.-]+) ]]; then
            user="${BASH_REMATCH[1]}"
            [ -n "$user" ] && [ "$user" != "root" ] && { echo "$user"; return; }
        fi
    fi

    # Layer 4: /proc/<pid>/status Uid fallback
    if [ -r "/proc/$pid/status" ]; then
        local uid
        uid=$(grep "^Uid:" /proc/$pid/status 2>/dev/null | awk '{print $2}')
        if [ -n "$uid" ] && [ "$uid" != "0" ] && [ "$uid" != "4294967295" ]; then
            local u
            u=$(getent passwd "$uid" 2>/dev/null | cut -d: -f1)
            [ -n "$u" ] && { echo "$u"; return; }
        fi
    fi

    echo "$user"
}

# --- Helper: list kandidat yang bisa di-tendang ---
# Output (stdout): peer_ip|user|service|pid (per baris)
# Filter: skip 127.0.0.1, VPS IP, private IP, user=root, user="-"
get_candidates() {
    local seen_ips=()

    # ss -tnpH = TCP, numeric, processes, NO header
    # state established = hanya yang sedang connect (bukan listening)
    while IFS= read -r line; do
        [ -z "$line" ] && continue

        # Parse format: "Recv-Q Send-Q Local:Port Peer:Port users:((...))"
        # $1=Recv-Q, $2=Send-Q, $3=Local:Port, $4=Peer:Port, $5=users:((...))
        local local_addr_port peer_addr_port
        local_addr_port=$(echo "$line" | awk '{print $3}')
        peer_addr_port=$(echo "$line" | awk '{print $4}')

        [ -z "$local_addr_port" ] && continue
        [ -z "$peer_addr_port" ] && continue

        # Extract local port + peer IP
        local local_port peer_ip
        local_port="${local_addr_port##*:}"
        peer_ip="${peer_addr_port%%:*}"

        # Strip IPv6 brackets [::1]:port -> ::1
        peer_ip="${peer_ip#\[}"
        peer_ip="${peer_ip%\]}"

        # Filter protected IP (loopback, VPS IP, private range)
        is_protected_ip "$peer_ip" && continue

        # Filter port yang BUKAN tunneling
        local is_tunnel=0
        for tp in $TUNNEL_PORTS; do
            [ "$local_port" = "$tp" ] && { is_tunnel=1; break; }
        done
        [ $is_tunnel -eq 0 ] && continue

        # Extract PID via bash regex (Pattern 16 v12 - pure bash, no awk match 3-arg)
        local pid
        if [[ $line =~ pid=([0-9]+) ]]; then
            pid="${BASH_REMATCH[1]}"
        else
            continue
        fi

        # Resolve user via Pattern 19 (Hybrid 4-layer)
        local user
        user=$(resolve_user "$pid")

        # Filter root (jangan tendang root login)
        [ "$user" = "root" ] && continue
        [ "$user" = "-" ] && continue  # Skip kalau tidak resolve

        # Dedup by peer IP (ambil first occurrence = first PID)
        local found=0
        for s in "${seen_ips[@]}"; do
            [ "$s" = "$peer_ip" ] && { found=1; break; }
        done
        [ $found -eq 1 ] && continue
        seen_ips+=("$peer_ip")

        # Output: peer_ip|user|service|pid
        local service
        service=$(get_service_name "$local_port")
        echo "${peer_ip}|${user}|${service}|${pid}"
    done < <(ss -tnpH state established 2>/dev/null)
}

# --- Helper: pause (skip kalau bukan TTY - untuk CLI automation) ---
pause() {
    [ -t 1 ] || return  # Skip jika stdout bukan TTY
    echo
    read -p "${GRAY}Tekan enter untuk kembali...${NC}" dummy
}

# --- Helper: show header banner ---
show_header() {
    [ -t 1 ] || return  # Skip clear screen jika bukan TTY
    clear
    echo -e "${BG_CYAN}${WHITE}================================================================${NC}"
    echo -e "${BG_CYAN}${WHITE}          TENDANG AMAN - HAXOR PANEL TUNNELING                 ${NC}"
    echo -e "${BG_CYAN}${WHITE}          DEKENG ANE BIAK BELITONG                              ${NC}"
    echo -e "${BG_TEAL}${WHITE}================================================================${NC}"
    echo
}

# --- Command: --list (CLI + interactive) ---
cmd_list() {
    local candidates
    candidates=$(get_candidates)

    if [ -z "$candidates" ]; then
        echo "Tidak ada kandidat yang bisa di-tendang."
        return 1
    fi

    # Save to cache file for later kick reference
    echo "$candidates" > "$CACHE_FILE"

    printf "%-4s %-22s %-22s %-14s %-10s\n" "No." "PEER IP" "USER" "SERVICE" "PID"
    printf "%-4s %-22s %-22s %-14s %-10s\n" "----" "----------------------" "----------------------" "--------------" "----------"

    local idx=0
    while IFS='|' read -r peer_ip user service pid; do
        idx=$((idx+1))
        printf "%-4s %-22s %-22s %-14s %-10s\n" "$idx" "$peer_ip" "$user" "$service" "$pid"
    done <<< "$candidates"

    echo
    echo "Total: $idx kandidat"
}

cmd_list_interactive() {
    show_header
    echo -e "${YELLOW}Kandidat yang bisa di-tendang (targeted per-IP):${NC}"
    echo
    cmd_list
    pause
}

# --- Command: --kick <IP> (CLI + interactive) ---
cmd_kick() {
    local target_ip=$1

    if [ -z "$target_ip" ]; then
        echo "ERROR: IP target harus disertakan."
        echo "Usage: tendang-safe --kick <IP>"
        return 1
    fi

    # Safety: reject protected IP
    if is_protected_ip "$target_ip"; then
        echo "ERROR: IP $target_ip TIDAK boleh di-tendang (protected: loopback/VPS/private)."
        return 1
    fi

    # Check if target is in candidate list (kalau ada cache)
    local found_in_cache=0
    if [ -f "$CACHE_FILE" ]; then
        if grep -q "^${target_ip}|" "$CACHE_FILE"; then
            found_in_cache=1
        fi
    fi

    show_header
    echo -e "${YELLOW}Tendang IP: $target_ip${NC}"
    if [ $found_in_cache -eq 1 ]; then
        echo -e "${GREEN}(IP ditemukan di candidate list)${NC}"
    else
        echo -e "${ORANGE}(PERINGATAN: IP tidak di candidate list - tendang paksa)${NC}"
    fi
    echo

    # Show what will be kicked (preview)
    echo -e "${CYAN}Socket yang akan di-tutup:${NC}"
    local sockets
    sockets=$(ss -tnpH state established 2>/dev/null | grep "$target_ip" | head -10)
    if [ -n "$sockets" ]; then
        echo "$sockets"
    else
        echo -e "${GRAY}(tidak ada socket established dari $target_ip saat ini)${NC}"
    fi
    echo

    # Confirm - HARUS ketik "YA" (huruf besar)
    echo -e "${RED}PERINGATAN: User dari IP ini akan disconnect dalam 3-5 detik.${NC}"
    echo -e "${RED}User bisa reconnect kapan saja (no permanent ban).${NC}"
    echo
    read -p "${YELLOW}Ketik 'YA' (huruf besar) untuk konfirmasi tendang $target_ip: ${NC}" confirm

    if [ "$confirm" != "YA" ]; then
        echo
        echo -e "${GRAY}Dibatalkan.${NC}"
        pause
        return 1
    fi

    # Execute ss -K dst <IP> (Pattern 1 jembatan 13D)
    echo
    echo -e "${CYAN}Menjalankan: ss -K dst $target_ip${NC}"
    local result
    result=$(ss -K dst "$target_ip" 2>&1)

    if [ -n "$result" ]; then
        echo -e "${GREEN}$result${NC}"
    else
        echo -e "${GRAY}(no output - kemungkinan tidak ada socket yang di-tutup)${NC}"
    fi
    echo
    echo -e "${GREEN}Selesai.${NC}"
    echo -e "${GRAY}Socket dari $target_ip telah ditutup.${NC}"
    echo -e "${GRAY}User akan disconnect dalam 3-5 detik, bisa reconnect kembali.${NC}"
    pause
}

# --- Helper: cek apakah user adalah system user (filter dari list) ---
is_system_user() {
    local user=$1
    case "$user" in
        root|sslh|daemon|nobody|sshd|www-data|syslog|dnsmasq|usbmux|message+|systemd+|"-"|"")
            return 0 ;;
    esac
    return 1
}

# --- Helper: list user aktif dengan PID mereka ---
# Output (stdout): user|count|pids (comma-separated) per baris
# Source: ALL tunnel ports (22, 109, 143, 443, 8880) - TERMASUK loopback Cloudfront path
# Filter: skip root + system users + user tidak resolve
get_active_users() {
    declare -A user_pids
    declare -A user_count

    while IFS= read -r line; do
        [ -z "$line" ] && continue

        local local_addr_port peer_addr_port
        local_addr_port=$(echo "$line" | awk '{print $3}')
        peer_addr_port=$(echo "$line" | awk '{print $4}')
        [ -z "$local_addr_port" ] && continue
        [ -z "$peer_addr_port" ] && continue

        local local_port
        local_port="${local_addr_port##*:}"

        # Hanya tunnel ports (INCLUDE 109/143 untuk Cloudfront path via Dropbear child)
        case "$local_port" in
            22|109|143|443|8880) ;;
            *) continue ;;
        esac

        # Extract PID
        local pid
        if [[ $line =~ pid=([0-9]+) ]]; then
            pid="${BASH_REMATCH[1]}"
        else
            continue
        fi

        # Resolve user via Pattern 19
        local user
        user=$(resolve_user "$pid")

        # Filter system users + tidak resolve
        is_system_user "$user" && continue

        # Aggregate by user
        if [ -z "${user_count[$user]}" ]; then
            user_count[$user]=1
            user_pids[$user]="$pid"
        else
            user_count[$user]=$((${user_count[$user]}+1))
            user_pids[$user]="${user_pids[$user]},$pid"
        fi
    done < <(ss -tnpH state established 2>/dev/null)

    # Output: user|count|pids (sorted by user)
    for user in "${!user_count[@]}"; do
        echo "${user}|${user_count[$user]}|${user_pids[$user]}"
    done | sort
}

# --- Helper: get fresh PID list for a specific user (real-time) ---
# Output (stdout): PID per baris
get_user_pids() {
    local target_user=$1
    [ -z "$target_user" ] && return

    while IFS= read -r line; do
        [ -z "$line" ] && continue

        local local_addr_port
        local_addr_port=$(echo "$line" | awk '{print $3}')
        local local_port="${local_addr_port##*:}"

        case "$local_port" in
            22|109|143|443|8880) ;;
            *) continue ;;
        esac

        local pid
        if [[ $line =~ pid=([0-9]+) ]]; then
            pid="${BASH_REMATCH[1]}"
        else
            continue
        fi

        local u
        u=$(resolve_user "$pid")
        if [ "$u" = "$target_user" ]; then
            echo "$pid"
        fi
    done < <(ss -tnpH state established 2>/dev/null)
}

# --- Command: --list-users (CLI + interactive) ---
cmd_list_users() {
    local users
    users=$(get_active_users)

    if [ -z "$users" ]; then
        echo "Tidak ada user aktif yang bisa di-tendang."
        return 1
    fi

    # Save to cache for later kick-user reference
    echo "$users" > "$CACHE_FILE_USERS"

    printf "%-4s %-22s %-8s %-50s\n" "No." "USERNAME" "JML" "PID LIST"
    printf "%-4s %-22s %-8s %-50s\n" "----" "----------------------" "--------" "--------------------------------------------------"

    local idx=0
    while IFS='|' read -r user count pids; do
        idx=$((idx+1))
        printf "%-4s %-22s %-8s %-50s\n" "$idx" "$user" "$count" "$pids"
    done <<< "$users"

    echo
    echo "Total: $idx user"
}

cmd_list_users_interactive() {
    show_header
    echo -e "${YELLOW}User aktif yang bisa di-tendang (kill PID per-user):${NC}"
    echo
    cmd_list_users
    pause
}

# --- Command: --kick-user <USER> (CLI + interactive) ---
# Mode 2: Kill Dropbear child PID per-user (untuk Cloudfront/WS-TLS path)
cmd_kick_user() {
    local target_user=$1

    # Interactive: list + ask (kalau tanpa argumen)
    if [ -z "$target_user" ]; then
        show_header
        local users
        users=$(get_active_users)

        if [ -z "$users" ]; then
            echo -e "${GRAY}Tidak ada user aktif yang bisa di-tendang.${NC}"
            pause
            return 1
        fi

        # Save to cache
        echo "$users" > "$CACHE_FILE_USERS"

        echo -e "${YELLOW}User aktif yang bisa di-tendang:${NC}"
        echo
        printf "%-4s %-22s %-8s %-50s\n" "No." "USERNAME" "JML" "PID LIST"
        printf "%-4s %-22s %-8s %-50s\n" "----" "----------------------" "--------" "--------------------------------------------------"

        local idx=0
        declare -a user_map
        while IFS='|' read -r user count pids; do
            idx=$((idx+1))
            user_map[$idx]="$user"
            printf "%-4s %-22s %-8s %-50s\n" "$idx" "$user" "$count" "$pids"
        done <<< "$users"

        echo
        echo -e "${YELLOW}Total: $idx user${NC}"
        echo
        read -p "${GRAY}Masukkan nomor user (atau ketik username, atau 0 untuk batal): ${NC}" input

        if [ "$input" = "0" ] || [ -z "$input" ]; then
            return 1
        fi

        # Resolve input ke username (nomor atau langsung username)
        if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] 2>/dev/null && [ "$input" -le "$idx" ] 2>/dev/null; then
            target_user="${user_map[$input]}"
        else
            target_user="$input"  # Assume user type username langsung
        fi
    fi

    # Safety: reject system users
    if is_system_user "$target_user"; then
        echo
        echo -e "${RED}ERROR: User '$target_user' TIDAK boleh di-tendang (system user / protected).${NC}"
        pause
        return 1
    fi

    # Get FRESH PID list (real-time, kalau-kalau list cache sudah berubah)
    local fresh_pids=()
    while IFS= read -r pid; do
        [ -n "$pid" ] && fresh_pids+=("$pid")
    done < <(get_user_pids "$target_user")

    if [ ${#fresh_pids[@]} -eq 0 ]; then
        echo
        echo -e "${RED}ERROR: Tidak ada PID aktif untuk user '$target_user'.${NC}"
        echo -e "${GRAY}(User mungkin sudah disconnect, atau username salah)${NC}"
        pause
        return 1
    fi

    # Show preview
    show_header
    echo -e "${YELLOW}Tendang User: $target_user${NC}"
    echo
    echo -e "${CYAN}PID yang akan di-kill (${#fresh_pids[@]} PID):${NC}"
    for p in "${fresh_pids[@]}"; do
        local args
        args=$(ps -p "$p" -o args= 2>/dev/null)
        echo "  ${GREEN}PID $p${NC}: $args"
    done
    echo

    # Confirm - HARUS ketik "YA" (huruf besar)
    echo -e "${RED}PERINGATAN: User '$target_user' akan disconnect dari SEMUA perangkat.${NC}"
    echo -e "${RED}User bisa reconnect kapan saja (Dropbear master tetap jalan, NO restart service).${NC}"
    echo
    read -p "${YELLOW}Ketik 'YA' (huruf besar) untuk konfirmasi tendang user '$target_user': ${NC}" confirm

    if [ "$confirm" != "YA" ]; then
        echo
        echo -e "${GRAY}Dibatalkan.${NC}"
        pause
        return 1
    fi

    # Execute kill -TERM for each PID (SIGTERM = graceful, lebih aman dari SIGKILL)
    echo
    echo -e "${CYAN}Menjalankan kill -TERM untuk ${#fresh_pids[@]} PID...${NC}"
    local killed=0
    local failed=0
    for p in "${fresh_pids[@]}"; do
        if kill -TERM "$p" 2>/dev/null; then
            echo -e "  ${GREEN}✓ PID $p di-kill${NC}"
            killed=$((killed+1))
        else
            echo -e "  ${RED}✗ PID $p gagal di-kill (mungkin sudah exit)${NC}"
            failed=$((failed+1))
        fi
    done

    echo
    echo -e "${GREEN}Selesai.${NC}"
    echo -e "  ${GREEN}Killed: $killed PID${NC}"
    [ $failed -gt 0 ] && echo -e "  ${ORANGE}Failed: $failed PID${NC}"
    echo
    echo -e "${GRAY}User '$target_user' akan disconnect dalam 1-3 detik.${NC}"
    echo -e "${GRAY}Dropbear master tetap listening, user bisa reconnect kapan saja.${NC}"
    pause
}

# --- Command: --dry-run <IP> (CLI + interactive) ---
cmd_dry_run() {
    local target_ip=$1

    if [ -z "$target_ip" ]; then
        echo "ERROR: IP target harus disertakan."
        echo "Usage: tendang-safe --dry-run <IP>"
        return 1
    fi

    show_header
    echo -e "${YELLOW}DRY-RUN: Simulasi tendang IP $target_ip${NC}"
    echo

    if is_protected_ip "$target_ip"; then
        echo -e "${RED}ERROR: IP $target_ip TIDAK boleh di-tendang (protected).${NC}"
        pause
        return 1
    fi

    echo -e "${CYAN}Socket yang akan di-tutup:${NC}"
    local sockets
    sockets=$(ss -tnpH state established 2>/dev/null | grep "$target_ip" | head -10)
    if [ -n "$sockets" ]; then
        echo "$sockets"
    else
        echo -e "${GRAY}(tidak ada socket established dari $target_ip saat ini)${NC}"
    fi
    echo
    echo -e "${GRAY}Command yang akan dijalankan:${NC}"
    echo -e "  ${CYAN}ss -K dst $target_ip${NC}"
    echo
    echo -e "${GRAY}(Tidak ada perubahan dilakukan - dry-run mode)${NC}"
    pause
}

# --- Command: --help (CLI + interactive) ---
cmd_help() {
    show_header
    echo -e "${CYAN}tendang-safe v$SCRIPT_VERSION${NC}"
    echo
    echo -e "${CYAN}Usage:${NC}"
    echo "  tendang-safe                       Interactive menu (recommended)"
    echo "  tendang-safe --list                List kandidat per-IP (direct connection)"
    echo "  tendang-safe --list-users          List user aktif + PID mereka"
    echo "  tendang-safe --kick <IP>           Tendang IP (Mode 1: ss -K, untuk direct conn)"
    echo "  tendang-safe --kick-user <USER>    Tendang user (Mode 2: kill PID, untuk Cloudfront)"
    echo "  tendang-safe --dry-run <IP>        Simulasi tendang IP (no execute)"
    echo "  tendang-safe --help                Tampilkan help ini"
    echo "  tendang-safe --version             Tampilkan versi"
    echo
    echo -e "${CYAN}Mode 1 (per-IP, ss -K dst <IP>):${NC}"
    echo "  Efektif untuk: SSH direct (port 22), WS-NonTLS (port 8880)"
    echo "  Limitation: TIDAK efektif untuk Cloudfront/WS-TLS (port 443 via sslh)"
    echo "  Karena IP yang terlihat = IP Cloudfront, BUKAN IP user asli"
    echo
    echo -e "${CYAN}Mode 2 (per-User, kill PID):${NC}"
    echo "  Efektif untuk: SEMUA jenis koneksi (direct + Cloudfront/WS-TLS)"
    echo "  Kill Dropbear child PID spesifik milik user (NO restart service)"
    echo "  User disconnect 1-3 detik, bisa reconnect kapan saja"
    echo
    echo -e "${CYAN}Safety:${NC}"
    echo "  - 127.0.0.1, IP VPS sendiri ($VPS_IP), IP private TIDAK boleh di-tendang"
    echo "  - User 'root' + system users (sslh, daemon, dll) TIDAK di-list (filter)"
    echo "  - Konfirmasi 'YA' (huruf besar) WAJIB sebelum execute"
    echo
    echo -e "${CYAN}Method:${NC}"
    echo "  Mode 1: ss -K dst <IP>  (kernel-level, targeted per-IP)"
    echo "  Mode 2: kill -TERM <PID>  (Dropbear child, graceful)"
    echo "  Pattern 1 jembatan 13D - anti tendang.sh DESTRUCTIVE (NO restart service)"
    echo
    echo -e "${CYAN}Source:${NC}"
    echo "  Original HAXOR wrapper - Pattern 1 jembatan 13D (ss -K dst <ip>)"
    echo "  Adaptasi resolve_user dari pantau.sh v13 (Pattern 19: auth.log PID matching)"
    echo
}

# --- Interactive menu (re-entrant while-loop - Pattern 3 v9) ---
show_menu() {
    while true; do
        show_header
        echo -e "${CYAN}Pilih opsi:${NC}"
        echo
        echo -e "  ${YELLOW}01${NC}) List Kandidat Tendang (per-IP)"
        echo -e "  ${YELLOW}02${NC}) Tendang IP (Mode 1: ss -K, direct conn)"
        echo -e "  ${YELLOW}03${NC}) Dry-Run Tendang IP (simulasi Mode 1)"
        echo -e "  ${YELLOW}04${NC}) List User Aktif (per-User)"
        echo -e "  ${YELLOW}05${NC}) Tendang User (Mode 2: kill PID, Cloudfront OK)"
        echo -e "  ${YELLOW}06${NC}) Help"
        echo
        echo -e "  ${ORANGE}0X${NC}) Kembali / Exit"
        echo
        read -p "${GRAY}Pilih opsi [01-06 / 0X]: ${NC}" choice

        case "$choice" in
            01|1)
                cmd_list_interactive
                ;;
            02|2)
                show_menu_kick
                ;;
            03|3)
                show_header
                read -p "${GRAY}Masukkan IP untuk dry-run: ${NC}" target_ip
                cmd_dry_run "$target_ip"
                ;;
            04|4)
                cmd_list_users_interactive
                ;;
            05|5)
                cmd_kick_user
                ;;
            06|6)
                cmd_help
                pause
                ;;
            0|00|x|X|0x|0X)
                clear
                break
                ;;
            *)
                echo
                echo -e "${RED}Opsi tidak dikenal: $choice${NC}"
                sleep 2
                ;;
        esac
    done
}

# --- Sub-menu: kick interactive (list + pilih nomor / input IP) ---
show_menu_kick() {
    show_header
    local candidates
    candidates=$(get_candidates)

    if [ -z "$candidates" ]; then
        echo -e "${GRAY}Tidak ada kandidat yang bisa di-tendang.${NC}"
        pause
        return 1
    fi

    # Save to cache
    echo "$candidates" > "$CACHE_FILE"

    echo -e "${YELLOW}Kandidat yang bisa di-tendang:${NC}"
    echo
    printf "%-4s %-22s %-22s %-14s %-10s\n" "No." "PEER IP" "USER" "SERVICE" "PID"
    printf "%-4s %-22s %-22s %-14s %-10s\n" "----" "----------------------" "----------------------" "--------------" "----------"

    local idx=0
    declare -a ip_map
    while IFS='|' read -r peer_ip user service pid; do
        idx=$((idx+1))
        ip_map[$idx]="$peer_ip"
        printf "%-4s %-22s %-22s %-14s %-10s\n" "$idx" "$peer_ip" "$user" "$service" "$pid"
    done <<< "$candidates"

    echo
    echo -e "${YELLOW}Total: $idx kandidat${NC}"
    echo
    read -p "${GRAY}Masukkan nomor kandidat (atau IP langsung, atau 0 untuk batal): ${NC}" input

    if [ "$input" = "0" ] || [ -z "$input" ]; then
        return 1
    fi

    # Resolve input ke IP (nomor atau langsung IP)
    local target_ip
    if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] 2>/dev/null && [ "$input" -le "$idx" ] 2>/dev/null; then
        target_ip="${ip_map[$input]}"
    else
        target_ip="$input"  # Assume user type IP langsung
    fi

    cmd_kick "$target_ip"
}

# --- Main: dispatch CLI args atau interactive menu ---
main() {
    # Validasi command -v (Pattern 6)
    local missing=0
    for cmd in ss journalctl ps grep awk getent; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "ERROR: command '$cmd' tidak ditemukan. Install dulu."
            missing=1
        fi
    done
    [ $missing -eq 1 ] && exit 1

    # Cek root (ss -K butuh CAP_NET_ADMIN)
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: tendang-safe butuh root access (untuk ss -K)."
        echo "Coba: sudo tendang-safe"
        exit 1
    fi

    # Dispatch CLI args atau interactive menu
    case "${1:-}" in
        --list)
            cmd_list
            ;;
        --list-users)
            cmd_list_users
            ;;
        --kick)
            cmd_kick "$2"
            ;;
        --kick-user)
            cmd_kick_user "$2"
            ;;
        --dry-run)
            cmd_dry_run "$2"
            ;;
        --help|-h)
            cmd_help
            ;;
        --version|-V)
            echo "tendang-safe v$SCRIPT_VERSION (HAXOR Panel Tunneling - Sesi v14 Sesi 2.4-A)"
            echo "Mode 1: Pattern 1 jembatan 13D (ss -K dst <ip>)"
            echo "Mode 2: Kill PID per-User (Pattern 19 v13 + Dropbear child)"
            ;;
        "")
            show_menu
            ;;
        *)
            echo "Unknown command: $1"
            echo "Usage: tendang-safe --list|--list-users|--kick <IP>|--kick-user <USER>|--dry-run <IP>|--help|--version"
            echo "       atau 'tendang-safe' (interactive mode)"
            exit 1
            ;;
    esac
}

main "$@"
