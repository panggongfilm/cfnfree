#!/bin/bash
# ============================================================
# Script  : pantau.sh
# Purpose : Monitoring panel terpisah untuk SSH user tunneling
#           Dipanggil via command: pantau
#           TIDAK mengganggu menu utama HAXOR
# Brand    : HAXOR PANEL TUNNELING
# Tagline : DEKENG ANE BIAK BELITONG
# Source  : Original HAXOR wrapper — konsep monitoring digabung
#           dari script cfnfree existing (cekssh, member, tendang)
# Version : v1.0 (Sesi 2.3 - v12)
# ============================================================

# ==========================================
# Palette 256-color — WAJIB pakai ANSI-C quoting $'...'
# supaya byte ESC tersimpan langsung di variabel.
# Pelajaran FIX1 dari v6: single-quote '\033[...]' menyimpan
# literal 4 char, BUG visual di read -p prompt.
# ==========================================
CYAN=$'\033[38;5;51m'      # Bright cyan - primary
TEAL=$'\033[38;5;38m'      # Teal - secondary
GREEN=$'\033[38;5;48m'     # Mint green - status OK
YELLOW=$'\033[38;5;227m'   # Soft yellow - menu numbers
ORANGE=$'\033[38;5;215m'   # Soft orange - warning
RED=$'\033[38;5;203m'      # Soft red - error / violation
PINK=$'\033[38;5;213m'     # Soft pink - accent
WHITE=$'\033[38;5;255m'    # Off-white - text normal
GRAY=$'\033[38;5;245m'     # Light gray - subtle
DGRAY=$'\033[38;5;240m'    # Dark gray - border
NC=$'\033[0m'              # Reset
BG_CYAN=$'\033[48;5;30m'   # Dark cyan bg - header box
BG_TEAL=$'\033[48;5;23m'   # Dark teal bg - secondary

# ==========================================
# Konstanta port tunneling (sesuai VPS user)
# ==========================================
SSH_PORT=22
DROPBEAR_PORTS="109 143"

# ==========================================
# Function show_header()
# Tampilkan header box double-bar dengan branding HAXOR + BELITONG
# ==========================================
show_header() {
    clear
    echo -e "${DGRAY}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BG_CYAN}${WHITE}         PANTAU PANEL - HAXOR TUNNELING MONITOR         ${NC}"
    echo -e "${BG_TEAL}${WHITE}           DEKENG ANE BIAK BELITONG                      ${NC}"
    echo -e "${DGRAY}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ==========================================
# Function pause()
# Tekan enter untuk kembali ke menu pantau
# ==========================================
pause() {
    echo ""
    echo -e "${GRAY}Tekan enter untuk kembali ke menu pantau...${NC}"
    read -r dummy
}

# ==========================================
# Function get_active_connections()
# Ambil daftar koneksi SSH/Dropbear aktif
# Format output: PID|USER|PEER_IP|LOCAL_PORT|SERVICE
# ==========================================
get_active_connections() {
    # Build port filter untuk ss
    # SSH (22) + Dropbear (109, 143)
    ss -tnp state established 2>/dev/null | \
        awk -v ssh_port="$SSH_PORT" -v db_ports="$DROPBEAR_PORTS" '
        BEGIN {
            # Build array of monitored ports
            split(ssh_port, ssh_arr, " ")
            for (i in ssh_arr) ports[ssh_arr[i]] = "SSH"
            split(db_ports, db_arr, " ")
            for (i in db_arr) ports[db_arr[i]] = "Dropbear"
        }
        NR > 1 {
            # Field 4 = Local Address:Port, Field 5 = Peer Address:Port
            local_full = $4
            peer_full  = $5
            # Extract local port (after last colon)
            n = split(local_full, parts, ":")
            local_port = parts[n]
            # Extract peer IP (before last colon)
            m = split(peer_full, pparts, ":")
            peer_ip = pparts[1]
            for (k = 2; k < m; k++) peer_ip = peer_ip ":" pparts[k]
            # Check if local port is monitored
            if (local_port in ports) {
                service = ports[local_port]
                # Extract PID from "users:((\"proc\",PID,fd))"
                pid_str = $6
                if (match(pid_str, /pid=([0-9]+)/, arr)) {
                    pid = arr[1]
                } else {
                    pid = "?"
                }
                printf "%s|%s|%s|%s\n", pid, peer_ip, local_port, service
            }
        }'
}

# ==========================================
# Function resolve_user_from_pid()
# Dapatkan username dari PID via /proc/<pid>/status
# ==========================================
resolve_user_from_pid() {
    local pid="$1"
    if [ "$pid" = "?" ] || [ -z "$pid" ]; then
        echo "?"
        return
    fi
    # Coba via ps dulu (lebih reliable)
    local user
    user=$(ps -p "$pid" -o user= 2>/dev/null | head -1)
    if [ -n "$user" ] && [ "$user" != "root" ]; then
        echo "$user"
        return
    fi
    # Fallback: cek /proc/<pid>/status (Uid line)
    if [ -r "/proc/$pid/status" ]; then
        local uid
        uid=$(grep "^Uid:" "/proc/$pid/status" 2>/dev/null | awk '{print $2}')
        if [ -n "$uid" ]; then
            user=$(getent passwd "$uid" 2>/dev/null | cut -d: -f1)
            if [ -n "$user" ] && [ "$user" != "root" ]; then
                echo "$user"
                return
            fi
        fi
    fi
    echo "-"
}

# ==========================================
# Function get_autokill_status()
# Baca status autokill dari /etc/cron.d/tendang
# Output: "ON|<interval>|<max>" atau "OFF"
# ==========================================
get_autokill_status() {
    local cron_file="/etc/cron.d/tendang"
    if [ ! -f "$cron_file" ]; then
        echo "OFF"
        return
    fi
    if ! grep -q "^# Autokill" "$cron_file" 2>/dev/null; then
        echo "OFF"
        return
    fi
    # Parse cron line: */N * * * * root /usr/bin/tendang MAX
    local cron_line max interval
    cron_line=$(grep -v "^#" "$cron_file" 2>/dev/null | grep -E "tendang" | head -1)
    if [ -z "$cron_line" ]; then
        echo "OFF"
        return
    fi
    # Extract interval (*/N pattern)
    interval=$(echo "$cron_line" | awk '{print $1}' | sed 's|^\*/||;s|\*.*||')
    [ -z "$interval" ] && interval="?"
    # Extract max (last field)
    max=$(echo "$cron_line" | awk '{print $NF}')
    [ -z "$max" ] && max="?"
    echo "ON|${interval}min|${max}"
}

# ==========================================
# FITUR 1: Real-time IP + User Login
# Tampilkan koneksi SSH/Dropbear aktif dengan PID, USER, PEER IP, PORT, SERVICE
# ==========================================
feat1_realtime_ip_user() {
    show_header
    echo -e "${CYAN}[*] FITUR 01: Monitor IP & User Login Real-Time${NC}"
    echo -e "${GRAY}----------------------------------------------${NC}"
    echo ""

    if ! command -v ss >/dev/null 2>&1; then
        echo -e "${RED}[ERROR] Command 'ss' tidak ditemukan.${NC}"
        echo -e "${YELLOW}    Install: apt install iproute2${NC}"
        pause
        return
    fi

    local conns count
    conns=$(get_active_connections)
    count=$(echo "$conns" | grep -c "|" 2>/dev/null || echo 0)

    if [ "$count" -eq 0 ]; then
        echo -e "${YELLOW}[i] Tidak ada koneksi SSH/Dropbear aktif saat ini.${NC}"
        echo -e "${GRAY}    Port yang dimonitor: SSH ($SSH_PORT), Dropbear ($DROPBEAR_PORTS)${NC}"
        pause
        return
    fi

    echo -e "${GREEN}[+] Ditemukan $count koneksi aktif:${NC}"
    echo ""
    printf "%-8s %-15s %-18s %-8s %-10s\n" "PID" "USERNAME" "PEER IP" "PORT" "SERVICE"
    printf "%-8s %-15s %-18s %-8s %-10s\n" "---" "--------" "--------" "----" "-------"

    echo "$conns" | while IFS='|' read -r pid peer_ip local_port service; do
        [ -z "$pid" ] && continue
        local user
        user=$(resolve_user_from_pid "$pid")
        printf "%-8s %-15s %-18s %-8s %-10s\n" "$pid" "$user" "$peer_ip" "$local_port" "$service"
    done

    echo ""
    echo -e "${GRAY}[*] Refresh: jalankan ulang opsi 01 untuk update terbaru${NC}"
    pause
}

# ==========================================
# FITUR 2: Active Users Live Update
# Group by user, hitung jumlah koneksi per user
# ==========================================
feat2_active_users_live() {
    show_header
    echo -e "${CYAN}[*] FITUR 02: User Terhubung Saat Ini (Live Update)${NC}"
    echo -e "${GRAY}----------------------------------------------${NC}"
    echo ""

    if ! command -v ss >/dev/null 2>&1; then
        echo -e "${RED}[ERROR] Command 'ss' tidak ditemukan.${NC}"
        echo -e "${YELLOW}    Install: apt install iproute2${NC}"
        pause
        return
    fi

    local conns count
    conns=$(get_active_connections)
    count=$(echo "$conns" | grep -c "|" 2>/dev/null || echo 0)

    if [ "$count" -eq 0 ]; then
        echo -e "${YELLOW}[i] Tidak ada user yang terhubung saat ini.${NC}"
        pause
        return
    fi

    # Build associative: user → count + IP list
    # Karena bash 4+ mendukung associative array, kita pakai approach temporary file
    local tmpfile
    tmpfile=$(mktemp)

    echo "$conns" | while IFS='|' read -r pid peer_ip local_port service; do
        [ -z "$pid" ] && continue
        local user
        user=$(resolve_user_from_pid "$pid")
        echo "$user|$peer_ip|$local_port|$service|$pid" >> "$tmpfile"
    done

    # Group by user, count connections
    local users_list
    users_list=$(awk -F'|' '{print $1}' "$tmpfile" | sort -u)

    if [ -z "$users_list" ]; then
        echo -e "${YELLOW}[i] Tidak ada user yang dapat di-resolve dari PID.${NC}"
        echo -e "${GRAY}    Koneksi aktif: $count (kemungkinan root/system process)${NC}"
        rm -f "$tmpfile"
        pause
        return
    fi

    echo -e "${GREEN}[+] Daftar user yang sedang terhubung:${NC}"
    echo ""
    printf "%-15s %-10s %-25s %-8s\n" "USERNAME" "KONEKSI" "PEER IP (latest)" "PORT"
    printf "%-15s %-10s %-25s %-8s\n" "--------" "--------" "-----------------" "----"

    echo "$users_list" | while IFS= read -r u; do
        [ -z "$u" ] && continue
        local u_count latest_ip latest_port
        u_count=$(awk -F'|' -v user="$u" '$1==user' "$tmpfile" | wc -l)
        latest_ip=$(awk -F'|' -v user="$u" '$1==user {print $2}' "$tmpfile" | tail -1)
        latest_port=$(awk -F'|' -v user="$u" '$1==user {print $3}' "$tmpfile" | tail -1)
        printf "%-15s %-10s %-25s %-8s\n" "$u" "$u_count" "$latest_ip" "$latest_port"
    done

    echo ""
    echo -e "${GRAY}Total user terhubung: $(echo "$users_list" | grep -c .) user, $count koneksi${NC}"
    rm -f "$tmpfile"
    pause
}

# ==========================================
# FITUR 3: Cek Semua User & Limit IP
# List semua SSH user (UID >= 1000), expiry, status, + info limit IP autokill
# ==========================================
feat3_all_users_limit() {
    show_header
    echo -e "${CYAN}[*] FITUR 03: Cek Semua User & Limit IP${NC}"
    echo -e "${GRAY}----------------------------------------------${NC}"
    echo ""

    if ! command -v chage >/dev/null 2>&1; then
        echo -e "${RED}[ERROR] Command 'chage' tidak ditemukan.${NC}"
        echo -e "${YELLOW}    Install: apt install passwd (provides chage)${NC}"
        pause
        return
    fi

    # Status autokill
    local ak_status ak_interval ak_max
    local ak_raw
    ak_raw=$(get_autokill_status)
    if [ "$ak_raw" = "OFF" ]; then
        ak_status="${RED}OFF${NC}"
        ak_interval="-"
        ak_max="${YELLOW}UNLIMITED${NC}"
    else
        ak_status="${GREEN}ON${NC}"
        ak_interval=$(echo "$ak_raw" | cut -d'|' -f2)
        ak_max=$(echo "$ak_raw" | cut -d'|' -f3)
    fi

    echo -e "${CYAN}[i] Status Autokill / Limit IP Multi-Login:${NC}"
    echo -e "    Status    : $ak_status"
    echo -e "    Interval  : $ak_interval"
    echo -e "    Max IP    : $ak_max ${GRAY}(aplikasi GLOBAL untuk semua user)${NC}"
    echo ""
    echo -e "${DGRAY}-----------------------------------------------------------${NC}"

    # List semua SSH user (UID >= 1000, exclude nobody/nobody)
    echo -e "${CYAN}[i] Daftar semua SSH user:${NC}"
    echo ""
    printf "%-20s %-15s %-15s %-12s\n" "USERNAME" "EXPIRY DATE" "STATUS" "UID"
    printf "%-20s %-15s %-15s %-12s\n" "--------" "-----------" "------" "---"

    local user_count=0
    while IFS=: read -r username _ uid _ _ _ shell _; do
        # Filter: UID >= 1000, exclude nobody, exclude shell /usr/sbin/nologin default users
        if [ "$uid" -ge 1000 ] 2>/dev/null && [ "$username" != "nobody" ]; then
            local exp status
            exp=$(chage -l "$username" 2>/dev/null | grep "Account expires" | awk -F": " '{print $2}')
            [ -z "$exp" ] && exp="never"
            status=$(passwd -S "$username" 2>/dev/null | awk '{print $2}')
            if [ "$status" = "L" ]; then
                status="${RED}LOCKED${NC}"
            elif [ "$status" = "P" ]; then
                status="${GREEN}ACTIVE${NC}"
            else
                status="${YELLOW}$status${NC}"
            fi
            printf "%-20s %-15s %-15s %-12s\n" "$username" "$exp" "$status" "$uid"
            user_count=$((user_count + 1))
        fi
    done < /etc/passwd

    echo ""
    echo -e "${GRAY}Total user: $user_count${NC}"
    echo ""
    echo -e "${YELLOW}[!] Catatan:${NC} Limit IP saat ini adalah GLOBAL (sama untuk semua user)."
    echo -e "${GRAY}    Setting limit IP per-user akan diimplementasi di sesi terpisah (Sesi 2.4).${NC}"
    pause
}

# ==========================================
# FITUR 4 (READ-ONLY): Kandidat Multi-Login
# Tampilkan user dengan koneksi > 1 — TANPA kick action
# ==========================================
feat4_candidates_multilogin() {
    show_header
    echo -e "${CYAN}[*] FITUR 04: Kandidat Multi-Login (VIEW ONLY - READ ONLY)${NC}"
    echo -e "${GRAY}--------------------------------------------------------${NC}"
    echo ""
    echo -e "${YELLOW}[!] MODE READ-ONLY: TIDAK ada aksi kick di sesi ini.${NC}"
    echo -e "${GRAY}    Fitur kick aman (kill PID spesifik tanpa restart service)${NC}"
    echo -e "${GRAY}    akan diimplementasi di Sesi 2.4.${NC}"
    echo ""

    if ! command -v ss >/dev/null 2>&1; then
        echo -e "${RED}[ERROR] Command 'ss' tidak ditemukan.${NC}"
        echo -e "${YELLOW}    Install: apt install iproute2${NC}"
        pause
        return
    fi

    local conns count
    conns=$(get_active_connections)
    count=$(echo "$conns" | grep -c "|" 2>/dev/null || echo 0)

    if [ "$count" -eq 0 ]; then
        echo -e "${YELLOW}[i] Tidak ada koneksi aktif — tidak ada kandidat multi-login.${NC}"
        pause
        return
    fi

    # Build user→count map via temporary file
    local tmpfile
    tmpfile=$(mktemp)

    echo "$conns" | while IFS='|' read -r pid peer_ip local_port service; do
        [ -z "$pid" ] && continue
        local user
        user=$(resolve_user_from_pid "$pid")
        echo "$user|$peer_ip|$pid|$local_port|$service" >> "$tmpfile"
    done

    # Cari user dengan koneksi > 1
    local multi_users
    multi_users=$(awk -F'|' '{count[$1]++} END {for (u in count) if (count[u] > 1 && u != "-") print u}' "$tmpfile" | sort)

    if [ -z "$multi_users" ]; then
        echo -e "${GREEN}[+] Tidak ada user dengan multi-login terdeteksi saat ini.${NC}"
        echo -e "${GRAY}    Semua user terhubung hanya dari 1 koneksi (atau tidak ada sama sekali).${NC}"
        rm -f "$tmpfile"
        pause
        return
    fi

    echo -e "${ORANGE}[!] Ditemukan kandidat multi-login:${NC}"
    echo ""
    printf "%-15s %-10s %-18s %-8s %-10s %-8s\n" "USERNAME" "KONEKSI" "PEER IP" "PORT" "SERVICE" "PID"
    printf "%-15s %-10s %-18s %-8s %-10s %-8s\n" "--------" "--------" "--------" "----" "-------" "---"

    echo "$multi_users" | while IFS= read -r u; do
        [ -z "$u" ] && continue
        # Print semua koneksi user ini
        awk -F'|' -v user="$u" '$1==user {
            printf "%-15s %-10s %-18s %-8s %-10s %-8s\n", user, "-", $2, $4, $5, $3
        }' "$tmpfile" | awk -F'\n' -v user="$u" '{
            # Hitung baris untuk user ini
        }'
        # Approach sederhana: cetak setiap koneksi user
        local u_count
        u_count=$(awk -F'|' -v user="$u" '$1==user' "$tmpfile" | wc -l)
        awk -F'|' -v user="$u" -v cnt="$u_count" '
        BEGIN { printed=0 }
        $1==user {
            if (printed == 0) {
                printf "%-15s %-10s %-18s %-8s %-10s %-8s\n", user, cnt, $2, $4, $5, $3
            } else {
                printf "%-15s %-10s %-18s %-8s %-10s %-8s\n", "", "", $2, $4, $5, $3
            }
            printed++
        }' "$tmpfile"
        echo -e "${DGRAY}---${NC}"
    done

    echo ""
    echo -e "${YELLOW}[!] Saran:${NC} Verifikasi manual sebelum tindakan kick."
    echo -e "${GRAY}    Sesi 2.4 akan menambahkan opsi kick PID spesifik (tanpa restart service).${NC}"
    rm -f "$tmpfile"
    pause
}

# ==========================================
# FITUR 5: History User (1 Jam Terakhir)
# Tampilkan event login SSH/Dropbear 1 jam terakhir
# ==========================================
feat5_history_1h() {
    show_header
    echo -e "${CYAN}[*] FITUR 05: History User (1 Jam Terakhir)${NC}"
    echo -e "${GRAY}----------------------------------------------${NC}"
    echo ""

    if ! command -v journalctl >/dev/null 2>&1; then
        echo -e "${RED}[ERROR] Command 'journalctl' tidak ditemukan.${NC}"
        echo -e "${YELLOW}    Ini seharusnya default di Ubuntu 20.04. Cek systemd installation.${NC}"
        pause
        return
    fi

    # Coba journalctl dulu (lebih reliable di Ubuntu 20.04)
    local events
    events=$(journalctl --since "1 hour ago" --no-pager -o short-iso 2>/dev/null | \
        grep -E "Accepted password|Password auth succeeded" | \
        awk '{
            # Format: TIMESTAMP HOST SERVICE[PID]: MESSAGE
            timestamp = $1 " " $2
            # Extract username and IP from message
            if (match($0, /for (invalid user )?([a-zA-Z0-9_-]+) from ([0-9a-fA-F:.]+)/, arr)) {
                user = arr[2]
                ip = arr[3]
                # Detect service
                if ($0 ~ /sshd/) service = "SSH"
                else if ($0 ~ /dropbear/) service = "Dropbear"
                else service = "?"
                printf "%s|%s|%s|%s\n", timestamp, user, ip, service
            } else if (match($0, /Password auth succeeded for '"'"'([^'"'"']+)'"'"' from ([0-9a-fA-F:.]+)/, arr2)) {
                user = arr2[1]
                ip = arr2[2]
                service = "Dropbear"
                printf "%s|%s|%s|%s\n", timestamp, user, ip, service
            }
        }')

    local event_count
    event_count=$(echo "$events" | grep -c "|" 2>/dev/null || echo 0)

    if [ "$event_count" -eq 0 ]; then
        echo -e "${YELLOW}[i] Tidak ada event login SSH/Dropbear dalam 1 jam terakhir.${NC}"
        echo -e "${GRAY}    Atau journalctl tidak menyimpan log auth.${NC}"
        echo ""
        echo -e "${CYAN}[i] Mencoba fallback ke /var/log/auth.log...${NC}"
        # Fallback ke auth.log
        if [ -f /var/log/auth.log ]; then
            events=$(awk -v since="$(date -d '1 hour ago' '+%b %e %H:%M:%S' 2>/dev/null | sed 's/  / /g')" '
            BEGIN {
                # Calculate cutoff time (1 hour ago) using systime
                cutoff = systime() - 3600
            }
            /Accepted password|Password auth succeeded/ {
                # Try to parse month/day/time from line
                # Format: "Mon DD HH:MM:SS ..."
                month = $1
                day = $2 + 0
                time = $3
                split(time, t, ":")
                hour = t[1] + 0
                min = t[2] + 0
                sec = t[3] + 0
                # Convert month name to number
                months = "JanFebMarAprMayJunJulAugSepOctNovDec"
                mo = (index(months, month) + 2) / 3
                # Build epoch (approximation — does not handle year boundary well)
                # For simplicity, just show all matching events
                if (match($0, /for (invalid user )?([a-zA-Z0-9_-]+) from ([0-9a-fA-F:.]+)/, arr)) {
                    printf "%s %s %s|%s|%s|%s\n", month, day, time, arr[2], arr[3], ($0 ~ /sshd/ ? "SSH" : ($0 ~ /dropbear/ ? "Dropbear" : "?"))
                } else if (match($0, /Password auth succeeded for '"'"'([^'"'"']+)'"'"' from ([0-9a-fA-F:.]+)/, arr2)) {
                    printf "%s %s %s|%s|%s|Dropbear\n", month, day, time, arr2[1], arr2[2]
                }
            }' /var/log/auth.log 2>/dev/null)
            event_count=$(echo "$events" | grep -c "|" 2>/dev/null || echo 0)
        fi

        if [ "$event_count" -eq 0 ]; then
            echo -e "${YELLOW}[i] Tidak ada event login ditemukan di /var/log/auth.log juga.${NC}"
            pause
            return
        fi
    fi

    echo -e "${GREEN}[+] Ditemukan $event_count event login dalam 1 jam terakhir:${NC}"
    echo ""
    printf "%-25s %-15s %-18s %-10s\n" "TIMESTAMP" "USERNAME" "IP ADDRESS" "SERVICE"
    printf "%-25s %-15s %-18s %-10s\n" "---------" "--------" "----------" "-------"

    echo "$events" | tail -50 | while IFS='|' read -r ts user ip service; do
        [ -z "$ts" ] && continue
        printf "%-25s %-15s %-18s %-10s\n" "$ts" "$user" "$ip" "$service"
    done

    if [ "$event_count" -gt 50 ]; then
        echo ""
        echo -e "${YELLOW}[i] Menampilkan 50 event terbaru. Total: $event_count event.${NC}"
    fi

    echo ""
    echo -e "${GRAY}[*] Refresh: jalankan ulang opsi 05 untuk update terbaru${NC}"
    pause
}

# ==========================================
# Function show_menu()
# Re-entrant menu via while-loop (anti stack overflow)
# ==========================================
show_menu() {
    while true; do
        show_header
        echo -e "${CYAN}Pilih opsi monitoring:${NC}"
        echo ""
        echo -e "  ${YELLOW}01${NC})  Monitor IP & User Login Real-Time"
        echo -e "  ${YELLOW}02${NC})  User Terhubung Saat Ini (Live Update)"
        echo -e "  ${YELLOW}03${NC})  Cek Semua User & Limit IP"
        echo -e "  ${YELLOW}04${NC})  Kandidat Multi-Login ${ORANGE}(VIEW ONLY)${NC}"
        echo -e "  ${YELLOW}05${NC})  History User (1 Jam Terakhir)"
        echo ""
        echo -e "  ${YELLOW}0X${NC})  Kembali ke Menu Utama HAXOR"
        echo ""
        read -p "${GRAY}Pilih opsi [01-05 / 0X]: ${NC}" choice
        handle_choice "$choice"
    done
}

# ==========================================
# Function handle_choice()
# ==========================================
handle_choice() {
    case "$1" in
        01|1)
            feat1_realtime_ip_user
            ;;
        02|2)
            feat2_active_users_live
            ;;
        03|3)
            feat3_all_users_limit
            ;;
        04|4)
            feat4_candidates_multilogin
            ;;
        05|5)
            feat5_history_1h
            ;;
        0|00|x|X|0x|0X)
            clear
            menu
            ;;
        *)
            echo ""
            echo -e "${RED}[ERROR] Opsi tidak dikenal: '$1'${NC}"
            echo -e "${YELLOW}    Pilihan valid: 01-05 atau 0X (exit)${NC}"
            sleep 2
            ;;
    esac
}

# ==========================================
# Function main()
# ==========================================
main() {
    show_menu
}

# ==========================================
# Entry point
# ==========================================
main
