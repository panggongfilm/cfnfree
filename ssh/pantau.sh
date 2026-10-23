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
# Format output: PID|PEER_IP|LOCAL_PORT|SERVICE
#
# FIX1 (v12-Sesi-2.3): Rewrite pure bash + regex, BUKAN awk.
# Alasan: awk match() 3-arg (gawk extension) TIDAK support di mawk
# (Ubuntu default). Field position awk juga rentan off-by-one
# kalau ss output punya format berbeda (State column, dsb).
# Pure bash + regex robust terhadap semua variasi.
# ==========================================
get_active_connections() {
    # -H = no header line (skip NR>1 logic)
    # state established = filter TCP established only
    ss -tnpH state established 2>/dev/null | while IFS= read -r line; do
        [ -z "$line" ] && continue

        # Extract PID via bash regex (BASH_REMATCH)
        local pid="?"
        if [[ $line =~ pid=([0-9]+) ]]; then
            pid="${BASH_REMATCH[1]}"
        fi

        # Extract all tokens containing ':' but NOT starting with 'users:' or 'pid='
        # Tokens valid: '203.194.112.128:22' (IPv4), '[::ffff:203.194.112.128]:22' (IPv6)
        # Tokens invalid: 'users:((', 'pid=12345'
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

        # Extract local port (segment after last colon)
        local local_port="${local_addr##*:}"
        # Strip trailing junk (just in case)
        local_port="${local_port%%[^0-9]*}"

        # Extract peer IP (everything before last colon)
        local peer_ip="${peer_addr%:*}"
        # Strip IPv6 brackets if any
        peer_ip="${peer_ip#[}"
        peer_ip="${peer_ip%]}"

        # Determine service based on local port
        local service=""
        case "$local_port" in
            "$SSH_PORT") service="SSH" ;;
            109|143)    service="Dropbear" ;;
        esac

        if [ -n "$service" ] && [ -n "$peer_ip" ]; then
            printf '%s|%s|%s|%s\n' "$pid" "$peer_ip" "$local_port" "$service"
        fi
    done
}

# ==========================================
# Function resolve_user_from_pid()
# Dapatkan username LOGIN yang sebenarnya dari PID koneksi SSH/Dropbear.
#
# FIX3 (v13-Sesi-2.3-FIX3): Prioritaskan /proc/<pid>/loginuid sebagai resolver utama
# Alasan: loginuid = UID user yang LOGIN (BUKAN process owner).
#   - Linux kernel native, robust untuk SEMUA pattern args (sshd [priv], sshd@notty,
#     sshd@pts/X, dropbear master, dropbear child, sshd -D master, dll)
#   - Tidak dependen pada format args ps -o args= (yang bisa bervariasi)
#   - Handle race condition: cek /proc/<pid>/ exists sebelum ps (process mungkin exit)
#
# Pelajaran FIX3-A (v13): PID 19739 (SSH external connection) masih return '-'
#   karena args format bukan pattern `sshd: USER [priv]` atau `sshd: USER@notty`
#   (kemungkinan `sshd: USER@pts/X` ATAU process sudah exit sebelum ps jalan).
#   loginuid approach resolve issue ini tanpa tergantung args format.
#
# PATTERN 18 (NEW v13): /proc/<pid>/loginuid untuk resolve user (lebih robust dari ps args)
#   loginuid di-set oleh PAM saat user login (SSH/interactive).
#   - Untuk user biasa: loginuid = UID user (e.g., 1001)
#   - Untuk root login: loginuid = 0
#   - Untuk master/system process: loginuid = -1 (uint 4294967295) — TIDAK punya login context
#
# FIX2 (v12-Sesi-2.3): Pertahankan ps -o args= + proc status sebagai fallback
#   untuk edge cases (Dropbear tanpa PAM, container tanpa /proc/loginuid, dll).
# ==========================================
resolve_user_from_pid() {
    local pid="$1"
    if [ "$pid" = "?" ] || [ -z "$pid" ]; then
        echo "?"
        return
    fi

    # FIX3-A: Handle race condition — cek /proc/<pid>/ exists SEBELUM ps
    # Process mungkin exit antara ss -tnp (capture PID) dan ps -p (resolve user)
    if [ ! -d "/proc/$pid" ]; then
        echo "-"
        return
    fi

    # STEP 1 (FIX3-A, PATTERN 18): Cek /proc/<pid>/loginuid — paling robust
    # loginuid = UID user yang LOGIN, BUKAN process owner.
    # -1 atau 4294967295 = process tidak punya login context (master/system)
    if [ -r "/proc/$pid/loginuid" ]; then
        local login_uid
        login_uid=$(cat "/proc/$pid/loginuid" 2>/dev/null)
        # loginuid -1 (int) atau 4294967295 (uint) = unset login context
        if [ -n "$login_uid" ] && [ "$login_uid" != "-1" ] && [ "$login_uid" != "4294967295" ]; then
            local login_user
            login_user=$(getent passwd "$login_uid" 2>/dev/null | cut -d: -f1)
            if [ -n "$login_user" ]; then
                echo "$login_user"
                return
            fi
        fi
    fi

    # STEP 2: Fallback ke ps -o args= (untuk edge cases: Dropbear tanpa PAM, container, dll)
    local args user=""
    args=$(ps -p "$pid" -o args= 2>/dev/null | head -1)

    # Jika args kosong = process sudah exit (race condition caught di step 0)
    if [ -n "$args" ]; then
        # Pattern 2a: SSH "sshd: USER [priv]" atau "sshd: USER@..."
        if [[ $args =~ ^sshd:\ ([a-zA-Z0-9_.-]+) ]]; then
            user="${BASH_REMATCH[1]}"
            # Filter out system process patterns (sshd: root atau sshd: system)
            if [ "$user" != "root" ] && [ "$user" != "system" ]; then
                echo "$user"
                return
            fi
        fi

        # Pattern 2b: Dropbear — user tidak ada di args, pakai ps -o user=
        # Dropbear process owner biasanya = user yang login (child process)
        # Untuk master listener: proc_owner = root → di-filter → return '-' (expected)
        local proc_owner
        proc_owner=$(ps -p "$pid" -o user= 2>/dev/null | head -1)
        if [ -n "$proc_owner" ] && [ "$proc_owner" != "root" ] && [ "$proc_owner" != "sshd" ] && [ "$proc_owner" != "nobody" ] && [ "$proc_owner" != "system" ]; then
            echo "$proc_owner"
            return
        fi
    fi

    # STEP 3: Fallback ke /proc/<pid>/status (Uid line — process real UID)
    # Uid = process real UID (BUKAN loginuid). Untuk sshd [priv]: Uid=0 (root).
    # Hanya pakai kalau Uid != 0 (root) — exclude system process.
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
    printf "%-20s %-18s %-12s %-8s\n" "USERNAME" "EXPIRY DATE" "STATUS" "UID"
    printf "%-20s %-18s %-12s %-8s\n" "--------" "-----------" "------" "---"

    local user_count=0
    while IFS=: read -r username _ uid _ _ _ shell _; do
        # Filter: UID >= 1000, exclude nobody
        if [ "$uid" -ge 1000 ] 2>/dev/null && [ "$username" != "nobody" ]; then
            local exp status_raw status_text
            exp=$(chage -l "$username" 2>/dev/null | grep "Account expires" | awk -F": " '{print $2}')
            [ -z "$exp" ] && exp="never"
            status_raw=$(passwd -S "$username" 2>/dev/null | awk '{print $2}')
            # FIX2: Pakai plain text untuk STATUS column (no ANSI escape codes)
            # supaya printf width calculation benar (TIDAK menghitung escape codes)
            # Lesson v6 FIX2 dipertahankan: hindari over-fix
            if [ "$status_raw" = "L" ]; then
                status_text="LOCKED"
            elif [ "$status_raw" = "P" ]; then
                status_text="ACTIVE"
            else
                status_text="$status_raw"
            fi
            printf "%-20s %-18s %-12s %-8s\n" "$username" "$exp" "$status_text" "$uid"
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
    # FIX2 (v12-Sesi-2.3): Rewrite awk menggunakan sprintf("%c", 39) untuk single quote.
    # Alasan: Pattern '"'"' quoting kompleks rentan syntax error di mawk version beda.
    # sprintf("%c", 39) = single quote character, menghindari shell quoting hell.
    local events
    events=$(journalctl --since "1 hour ago" --no-pager -o short-iso 2>/dev/null | \
        grep -E "Accepted password|Password auth succeeded" | \
        awk '
        BEGIN { sq = sprintf("%c", 39) }
        {
            # FIX3-D (v13): journalctl short-iso format = $1 berisi ISO datetime lengkap
            # (e.g., "2026-10-23T18:16:33+0700"), $2 = hostname (BUKAN time).
            # Sebelumnya: timestamp = $1 " " $2 → hostname ikut ke timestamp column.
            # Fix: timestamp = $1 saja.
            timestamp = $1
            if (index($0, "Accepted password for") > 0) {
                n = split($0, a, "for ")
                rest = a[2]
                m = split(rest, b, " ")
                if (b[1] == "invalid" && b[2] == "user") {
                    user = b[3]
                    ip = b[5]
                } else {
                    user = b[1]
                    ip = b[3]
                }
                # FIX3-C (v13): Filter root login events (sesuai user request v13).
                # Root login biasanya internal SSH dari VPS sendiri (IP = VPS own IP).
                # User ingin HIDE ini dari history ( hanya tampilkan user biasa).
                # Untuk show root events: comment baris `next` di bawah.
                if (user == "root") next
                if (index($0, "sshd") > 0) service = "SSH"
                else if (index($0, "dropbear") > 0) service = "Dropbear"
                else service = "?"
                printf "%s|%s|%s|%s\n", timestamp, user, ip, service
            }
            else if (index($0, "Password auth succeeded for " sq) > 0) {
                n = split($0, a, "for " sq)
                rest = a[2]
                m = split(rest, b, sq " from ")
                user = b[1]
                ip = b[2]
                sub(/:[0-9]+$/, "", ip)
                # FIX3-C (v13): Filter root login events (Dropbear auth)
                if (user == "root") next
                printf "%s|%s|%s|%s\n", timestamp, user, ip, "Dropbear"
            }
        }')

    # FIX2: gunakan wc -l (BUKAN grep -c | || echo 0)
    # Alasan: grep -c returns '0' + exit 1, lalu || echo 0 fires,
    # hasil '0\n0' multiline → error [ "$count" -eq 0 ] integer expression expected.
    # wc -l selalu return single integer (0 untuk empty input).
    local event_count
    event_count=$(printf "%s\n" "$events" | grep "|" | wc -l)
    [ -z "$events" ] && event_count=0

    if [ "$event_count" -eq 0 ]; then
        echo -e "${YELLOW}[i] Tidak ada event login SSH/Dropbear dalam 1 jam terakhir.${NC}"
        echo -e "${GRAY}    Atau journalctl tidak menyimpan log auth.${NC}"
        echo ""
        echo -e "${CYAN}[i] Mencoba fallback ke /var/log/auth.log...${NC}"
        # Fallback ke auth.log
        # FIX2 (v12-Sesi-2.3): Rewrite awk pakai sprintf("%c", 39) untuk single quote.
        if [ -f /var/log/auth.log ]; then
            events=$(awk '
            BEGIN { sq = sprintf("%c", 39) }
            {
                # /var/log/auth.log format: $1=month $2=day $3=time
                month = $1
                day = $2
                time = $3
                if (index($0, "Accepted password for") > 0) {
                    n = split($0, a, "for ")
                    rest = a[2]
                    m = split(rest, b, " ")
                    if (b[1] == "invalid" && b[2] == "user") {
                        user = b[3]
                        ip = b[5]
                    } else {
                        user = b[1]
                        ip = b[3]
                    }
                    # FIX3-C (v13): Filter root login events (auth.log path juga)
                    if (user == "root") next
                    if (index($0, "sshd") > 0) service = "SSH"
                    else if (index($0, "dropbear") > 0) service = "Dropbear"
                    else service = "?"
                    printf "%s %s %s|%s|%s|%s\n", month, day, time, user, ip, service
                }
                else if (index($0, "Password auth succeeded for " sq) > 0) {
                    n = split($0, a, "for " sq)
                    rest = a[2]
                    m = split(rest, b, sq " from ")
                    user = b[1]
                    ip = b[2]
                    sub(/:[0-9]+$/, "", ip)
                    # FIX3-C (v13): Filter root login events (auth.log path Dropbear)
                    if (user == "root") next
                    printf "%s %s %s|%s|%s|%s\n", month, day, time, user, ip, "Dropbear"
                }
            }' /var/log/auth.log 2>/dev/null)
            event_count=$(printf "%s\n" "$events" | grep "|" | wc -l)
            [ -z "$events" ] && event_count=0
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
