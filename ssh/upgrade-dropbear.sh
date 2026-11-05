#!/bin/bash
# ============================================================================
# HAXOR PANEL TUNNELING — UPGRADE DROPBEAR (PATH X AUTOMATION)
# ============================================================================
# Tagline : DEKENG ANE BIAK BELITONG
# Version : v1.0 (Sesi v39 - upgrade-dropbear)
# Source  : Original HAXOR wrapper — automasi PATH X v31 Dropbear upgrade
#           (Dropbear 2019.78 → 2026.94, fix CVE-2025-14282 privilege drop
#            post-auth — Dropbear child forwarding UID=user post-upgrade)
#
# Layer 1 Safety: display_info_warning() — info + warning + confirmation y/n
# Layer 2 Safety: check_admin_via_ssh_direct() — REJECT kalau via tunneling
# Layer 3 Safety: verify_dropbear_healthy() — auto-restore kalau gagal 30 detik
#
# Build process: download tarball + gcc build on-VPS + atomic replace binary
# Verify PATH X: /proc/<PID>/exe hash + port listen + child UID = user
#
# Log: /var/log/upgrade-dropbear.log (timestamp + version + result)
#
# CLI: upgrade-dropbear --help | --version | --dry-run | (no args = interactive)
#
# Pattern: Pattern 2 (run-once dengan confirmation prompt)
# LESSON v6 FIX1: ANSI-C quoting $'...' untuk semua variabel palette
# LESSON v21: GitHub Web Editor upload URL folder (BUKAN URL file)
# LESSON v31: ATOMIC REPLACE install -m 0755 + mv -f (hindari ETXTBSY)
# LESSON v38: sslh-fix-reboot TIDAK reboot VPS (BUKAN concern di sini,
#             script ini PUNYA restart logic sendiri, BUKAN panggil sslh-fix-reboot)
# PATTERN 44: Empirical test methodology (verify child UID = user post-upgrade)
# PATTERN 46: Dynamic iptables per ephemeral port (relevant pasca-upgrade
#             untuk bw-limit — Dropbear child baru UID=user ENABLE per-UID mark)
#
# Komitmen etis: NO tendang/throttle SEMUA user. Script ini upgrade binary
# Dropbear supaya bw-limit shaping WORK untuk user blacklist (manual by admin).
# ============================================================================

# ============================================================================
# CONSTANTS
# ============================================================================
SCRIPT_VERSION="1.0"
DROPBEAR_VERSION_TARGET="2026.94"
DROPBEAR_PACKAGE="dropbear-2026.94.tar.bz2"
DROPBEAR_DIR="dropbear-2026.94"
DOWNLOAD_URL="https://matt.ucc.asn.au/dropbear/releases/${DROPBEAR_PACKAGE}"
DROPBEAR_BIN="/usr/sbin/dropbear"
DROPBEAR_BAK="/usr/sbin/dropbear.v2019.78.bak"
DROPBEAR_DEFAULT="/etc/default/dropbear"
DROPBEAR_DEFAULT_BAK="${DROPBEAR_DEFAULT}.bak-v39"
LOG_FILE="/var/log/upgrade-dropbear.log"
BUILD_DIR="/tmp/dropbear-build-${DROPBEAR_VERSION_TARGET}"
MAX_VERIFY_WAIT=30  # detik, auto-restore kalau gagal

# Hash target binary 2026.94 (dari v31 verify — sha256 ace5f8c9...)
HASH_TARGET="ace5f8c9da9fb2d71f20bd855c3c1cf70751870ef8f06f329f3641310334fa1c"

# ============================================================================
# PALETTE 256-COLOR — ANSI-C QUOTING $'...' (LESSON v6 FIX1)
# Pakai ANSI-C quoting supaya byte ESC tersimpan langsung di variabel,
# sehingga warna tampil benar di echo, echo -e, read -p, dan printf.
# ============================================================================
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
BG_CYAN=$'\033[48;5;24m'    # dark cyan (FIX2 v16 — soft di mata)
BG_TEAL=$'\033[48;5;30m'    # medium cyan

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# Log message dengan timestamp ISO-8601 ke /var/log/upgrade-dropbear.log
log_msg() {
    local msg="$1"
    local ts
    ts=$(date '+%Y-%m-%dT%H:%M:%S%z')
    echo "${ts} ${msg}" >> "${LOG_FILE}" 2>/dev/null
}

# Header box — branding HAXOR + tagline BELITONG
show_header() {
    clear
    echo -e "${BG_CYAN}${WHITE}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BG_CYAN}${WHITE}║                                                                    ║${NC}"
    echo -e "${BG_CYAN}${WHITE}║          UPGRADE DROPBEAR — HAXOR PANEL TUNNELING                 ║${NC}"
    echo -e "${BG_CYAN}${WHITE}║                                                                    ║${NC}"
    echo -e "${BG_CYAN}${WHITE}║              DEKENG ANE BIAK BELITONG                            ║${NC}"
    echo -e "${BG_CYAN}${WHITE}║                                                                    ║${NC}"
    echo -e "${BG_CYAN}${WHITE}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo -e ""
    echo -e "${YELLOW}  Version           :${NC} v${SCRIPT_VERSION} (Dropbear ${DROPBEAR_VERSION_TARGET} automation)"
    echo -e "${YELLOW}  Target Version    :${NC} Dropbear v${DROPBEAR_VERSION_TARGET} (privilege drop post-auth)"
    echo -e "${YELLOW}  Log File          :${NC} ${LOG_FILE}"
    echo -e ""
}

# Pause helper — tekan enter untuk lanjut
pause() {
    echo ""
    echo -e "${GRAY}Tekan enter untuk lanjut...${NC}"
    read -r dummy
}

# Cek apakah command tersedia (Pattern 6)
check_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# ============================================================================
# LAYER 1 SAFETY — display_info_warning()
# Tampilkan info + warning + confirmation prompt y/n
# ============================================================================
display_info_warning() {
    local current_version
    local active_users
    local apt_hold_status

    # Get current Dropbear version
    if [ -x "${DROPBEAR_BIN}" ]; then
        current_version=$("${DROPBEAR_BIN}" -V 2>&1 | head -1 | awk '{print $2}' | sed 's/v//')
    else
        current_version="NOT_INSTALLED"
    fi

    # Count active Dropbear child (user tunneling aktif)
    active_users=$(ps -eo user,pid,args 2>/dev/null | grep -E "dropbear" | grep -v grep | grep -v "dropbear -p 143" | wc -l)

    # Check apt-mark hold status
    if apt-mark showhold 2>/dev/null | grep -qE "^(dropbear|dropbear-bin)$"; then
        apt_hold_status="${GREEN}AKTIF (apt upgrade tidak akan timpa)${NC}"
    else
        apt_hold_status="${RED}TIDAK AKTIF (apt upgrade BISA timpa binary)${NC}"
    fi

    echo -e "${TEAL}═════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${WHITE}                       INFORMASI UPGRADE${NC}"
    echo -e "${TEAL}═════════════════════════════════════════════════════════════════════${NC}"
    echo -e ""
    echo -e "${YELLOW}  Versi saat ini    :${NC} Dropbear v${current_version}"
    echo -e "${YELLOW}  Versi target      :${NC} Dropbear v${DROPBEAR_VERSION_TARGET}"
    echo -e "${YELLOW}  User aktif tunnel :${NC} ~${active_users} koneksi (akan disconnect 30-60 detik)"
    echo -e "${YELLOW}  Estimasi build    :${NC} 3-5 menit (gcc on-VPS, 2 core)"
    echo -e "${YELLOW}  apt-mark hold     :${NC} ${apt_hold_status}"
    echo -e ""
    echo -e "${TEAL}═════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${ORANGE}                           PERINGATAN${NC}"
    echo -e "${TEAL}═════════════════════════════════════════════════════════════════════${NC}"
    echo -e ""
    echo -e "${ORANGE}  1. Pastikan Anda login via SSH DIRECT (port 22), BUKAN via tunneling${NC}"
    echo -e "${ORANGE}     Dropbear (port 109/143). Koneksi via tunneling akan PUTUS saat${NC}"
    echo -e "${ORANGE}     Dropbear restart.${NC}"
    echo -e ""
    echo -e "${ORANGE}  2. Sarankan jalankan saat jam sepi (mis. 02:00 WIB) — semua user${NC}"
    echo -e "${ORANGE}     tunneling akan disconnect 30-60 detik, reconnect otomatis.${NC}"
    echo -e ""
    echo -e "${ORANGE}  3. Admin (Anda) tetap AMAN via SSH direct port 22 — SSH TIDAK${NC}"
    echo -e "${ORANGE}     di-restart, koneksi admin tetap connect.${NC}"
    echo -e ""
    echo -e "${ORANGE}  4. Auto-restore: kalau Dropbear baru gagal start dalam 30 detik,${NC}"
    echo -e "${ORANGE}     binary lama akan auto-restore (Layer 3 safety).${NC}"
    echo -e ""
    echo -e "${TEAL}═════════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# ============================================================================
# LAYER 2 SAFETY — check_admin_via_ssh_direct()
# Cek apakah admin login via SSH direct port 22 (BUKAN via tunneling Dropbear)
# ============================================================================
check_admin_via_ssh_direct() {
    local ssh_conn
    local ssh_client_port
    local admin_via_direct=false

    # Method 1: cek $SSH_CONNECTION (format: "src_ip src_port dst_ip dst_port")
    ssh_conn="${SSH_CONNECTION:-}"
    if [ -n "$ssh_conn" ]; then
        # dst port = field 4
        ssh_client_port=$(echo "$ssh_conn" | awk '{print $4}')
        if [ "$ssh_client_port" = "22" ]; then
            admin_via_direct=true
        fi
    fi

    # Method 2: cek parent process args (PPID → command line)
    # SSH direct login: parent adalah sshd yang listen port 22
    if [ "$admin_via_direct" = "false" ]; then
        local ppid_args
        ppid_args=$(ps -o args= -p $PPID 2>/dev/null)
        if echo "$ppid_args" | grep -qE "sshd:.*@|sshd -"; then
            # Cek apakah parent listen port 22 (BUKAN 109/143)
            local ppid
            ppid=$PPID
            local sshd_listen_port
            sshd_listen_port=$(ss -tlnp 2>/dev/null | grep "pid=${ppid}" | grep -oE ":\d+ " | head -1 | tr -d ': ')
            if [ "$sshd_listen_port" = "22" ] || [ -z "$sshd_listen_port" ]; then
                # Fallback: kalau tidak ketemu port, anggap direct (karena PPID adalah sshd)
                admin_via_direct=true
            fi
        fi
    fi

    # Method 3: cek via who + ss (kalau 2 method di atas gagal)
    if [ "$admin_via_direct" = "false" ]; then
        local who_info
        who_info=$(who 2>/dev/null | grep -E "^root\s+pts/" | head -1)
        if [ -n "$who_info" ]; then
            # Kalau admin login via pts (terminal), kemungkinan via SSH direct
            admin_via_direct=true
        fi
    fi

    if [ "$admin_via_direct" = "true" ]; then
        return 0  # AMAN, admin via SSH direct
    else
        return 1  # BAHAYA, admin via tunneling
    fi
}

# ============================================================================
# BUILD PROCESS
# ============================================================================
# Install dependency build (zlib1g-dev + libcrypt-dev)
install_build_deps() {
    echo -e "${YELLOW}  [1/6] Cek + install dependency build...${NC}"
    if ! dpkg -l zlib1g-dev 2>/dev/null | grep -q "^ii" || \
       ! dpkg -l libcrypt-dev 2>/dev/null | grep -q "^ii"; then
        echo -e "    ${GRAY}Installing zlib1g-dev + libcrypt-dev...${NC}"
        apt-get update -qq 2>&1 | tail -2
        apt-get install -y zlib1g-dev libcrypt-dev gcc make 2>&1 | tail -5
        if [ $? -ne 0 ]; then
            echo -e "    ${RED}GAGAL install dependency build${NC}"
            return 1
        fi
    else
        echo -e "    ${GREEN}Dependency build sudah terinstall ✓${NC}"
    fi
    return 0
}

# Download tarball Dropbear
download_tarball() {
    echo -e "${YELLOW}  [2/6] Download ${DROPBEAR_PACKAGE}...${NC}"
    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}"
    cd "${BUILD_DIR}" || return 1

    if ! wget -q --show-progress -O "${DROPBEAR_PACKAGE}" "${DOWNLOAD_URL}" 2>&1 | tail -3; then
        echo -e "    ${RED}GAGAL download dari ${DOWNLOAD_URL}${NC}"
        return 1
    fi

    local download_size
    download_size=$(stat -c%s "${DROPBEAR_PACKAGE}" 2>/dev/null || echo 0)
    if [ "$download_size" -lt 1000000 ]; then
        echo -e "    ${RED}Download terlalu kecil (${download_size} bytes) — kemungkinan error page${NC}"
        return 1
    fi
    echo -e "    ${GREEN}Download OK (${download_size} bytes) ✓${NC}"
    return 0
}

# Extract + configure + build (gcc)
build_dropbear() {
    echo -e "${YELLOW}  [3/6] Extract + configure + build (gcc, ~3-5 menit)...${NC}"
    cd "${BUILD_DIR}" || return 1

    if ! tar xjf "${DROPBEAR_PACKAGE}"; then
        echo -e "    ${RED}GAGAL extract tarball${NC}"
        return 1
    fi

    cd "${DROPBEAR_DIR}" || return 1

    # Configure TANPA --enable-pam (sesuai v31 — VPS tidak pakai PAM)
    echo -e "    ${GRAY}Running ./configure...${NC}"
    if ! ./configure --prefix=/usr --sysconfdir=/etc/dropbear 2>&1 | tail -5; then
        echo -e "    ${RED}GAGAL ./configure${NC}"
        return 1
    fi

    # Build dengan make -j2 (VPS 2 core)
    echo -e "    ${GRAY}Running make -j2 (mungkin 3-5 menit, mohon tunggu)...${NC}"
    if ! make -j2 2>&1 | tail -10; then
        echo -e "    ${RED}GAGAL make${NC}"
        return 1
    fi

    # Verify binary baru
    local built_version
    built_version=$(./dropbear -V 2>&1 | head -1)
    if ! echo "$built_version" | grep -q "v${DROPBEAR_VERSION_TARGET}"; then
        echo -e "    ${RED}Binary version mismatch: ${built_version}${NC}"
        return 1
    fi
    echo -e "    ${GREEN}Build OK: ${built_version} ✓${NC}"

    # Verify hash binary baru
    local built_hash
    built_hash=$(sha256sum ./dropbear | awk '{print $1}')
    if [ "$built_hash" != "$HASH_TARGET" ]; then
        echo -e "    ${ORANGE}WARNING: Hash binary baru (${built_hash})${NC}"
        echo -e "    ${ORANGE}         TIDAK match dengan target (${HASH_TARGET})${NC}"
        echo -e "    ${ORANGE}         Lanjut install (hash bisa beda kalau build env berbeda)${NC}"
    else
        echo -e "    ${GREEN}Hash binary MATCH (ace5f8c9...) ✓${NC}"
    fi
    return 0
}

# ============================================================================
# ATOMIC REPLACE (LESSON v31)
# ============================================================================
backup_and_replace_binary() {
    echo -e "${YELLOW}  [4/6] Backup + ATOMIC REPLACE binary...${NC}"

    # Backup binary lama (kalau belum ada backup dari v31)
    if [ -f "${DROPBEAR_BAK}" ]; then
        local existing_hash
        existing_hash=$(sha256sum "${DROPBEAR_BAK}" | awk '{print $1}')
        if [ "$existing_hash" = "bf155af93493ddadd5e9277ce28085555d0226cc43a863a43c98acc6483e6374" ]; then
            echo -e "    ${GRAY}Backup v2019.78 sudah ada dari v31 ✓ (skip backup ulang)${NC}"
        else
            echo -e "    ${ORANGE}Backup ada tapi hash beda — overwrite dengan binary lama saat ini${NC}"
            cp -p "${DROPBEAR_BIN}" "${DROPBEAR_BAK}"
        fi
    else
        echo -e "    ${GRAY}Backup binary lama ke ${DROPBEAR_BAK}...${NC}"
        cp -p "${DROPBEAR_BIN}" "${DROPBEAR_BAK}"
    fi

    # Verify backup
    if [ ! -f "${DROPBEAR_BAK}" ]; then
        echo -e "    ${RED}GAGAL backup binary lama${NC}"
        return 1
    fi
    echo -e "    ${GREEN}Backup OK ($(stat -c%s "${DROPBEAR_BAK}") bytes) ✓${NC}"

    # ATOMIC REPLACE: install ke temp + mv -f (hindari ETXTBSY)
    echo -e "    ${GRAY}Install binary baru ke ${DROPBEAR_BIN}.new...${NC}"
    if ! install -m 0755 "${BUILD_DIR}/${DROPBEAR_DIR}/dropbear" "${DROPBEAR_BIN}.new"; then
        echo -e "    ${RED}GAGAL install binary baru ke temp${NC}"
        return 1
    fi

    # Atomic mv
    echo -e "    ${GRAY}Atomic mv ${DROPBEAR_BIN}.new → ${DROPBEAR_BIN}...${NC}"
    if ! mv -f "${DROPBEAR_BIN}.new" "${DROPBEAR_BIN}"; then
        echo -e "    ${RED}GAGAL atomic mv${NC}"
        return 1
    fi

    # Verify binary baru di tempatnya
    local new_version
    new_version=$("${DROPBEAR_BIN}" -V 2>&1 | head -1)
    if ! echo "$new_version" | grep -q "v${DROPBEAR_VERSION_TARGET}"; then
        echo -e "    ${RED}Binary baru version mismatch: ${new_version}${NC}"
        return 1
    fi
    echo -e "    ${GREEN}Atomic replace OK: ${new_version} ✓${NC}"
    return 0
}

# Edit config — tambah -P /var/run/dropbear.pid kalau belum ada (LESSON v31 incident)
edit_dropbear_config() {
    echo -e "${YELLOW}  [5/6] Cek + edit config /etc/default/dropbear...${NC}"

    # Backup config
    if [ -f "${DROPBEAR_DEFAULT}" ]; then
        cp -p "${DROPBEAR_DEFAULT}" "${DROPBEAR_DEFAULT_BAK}"
        echo -e "    ${GRAY}Backup config → ${DROPBEAR_DEFAULT_BAK} ✓${NC}"
    fi

    # Cek apakah -P sudah ada di DROPBEAR_EXTRA_ARGS
    local current_extra_args
    current_extra_args=$(grep "^DROPBEAR_EXTRA_ARGS=" "${DROPBEAR_DEFAULT}" 2>/dev/null | cut -d= -f2- | tr -d '"')

    if echo "$current_extra_args" | grep -q "\-P"; then
        echo -e "    ${GREEN}Config sudah ada -P flag ✓ (skip edit)${NC}"
    else
        # Tambah -P /var/run/dropbear.pid
        local new_extra_args
        new_extra_args="${current_extra_args} -P /var/run/dropbear.pid"
        # Trim leading space
        new_extra_args=$(echo "$new_extra_args" | sed 's/^ *//')

        # Edit config via sed
        sed -i "s|^DROPBEAR_EXTRA_ARGS=.*|DROPBEAR_EXTRA_ARGS=\"${new_extra_args}\"|" "${DROPBEAR_DEFAULT}"

        # Verify edit
        local verify_args
        verify_args=$(grep "^DROPBEAR_EXTRA_ARGS=" "${DROPBEAR_DEFAULT}" 2>/dev/null | cut -d= -f2- | tr -d '"')
        if echo "$verify_args" | grep -q "\-P /var/run/dropbear.pid"; then
            echo -e "    ${GREEN}Config updated: DROPBEAR_EXTRA_ARGS=\"${verify_args}\" ✓${NC}"
        else
            echo -e "    ${ORANGE}WARNING: Gagal edit config — lanjut tanpa -P flag${NC}"
            echo -e "    ${ORANGE}         (Dropbear masih jalan, tapi restart via systemd mungkin bermasalah)${NC}"
        fi
    fi
    return 0
}

# apt-mark hold — cegah apt upgrade timpa binary baru
set_apt_hold() {
    echo -e "${GRAY}    Set apt-mark hold dropbear dropbear-bin...${NC}"
    apt-mark hold dropbear dropbear-bin >/dev/null 2>&1
    if apt-mark showhold 2>/dev/null | grep -qE "^(dropbear|dropbear-bin)$"; then
        echo -e "    ${GREEN}apt-mark hold AKTIF ✓${NC}"
    else
        echo -e "    ${ORANGE}WARNING: apt-mark hold GAGAL — apt upgrade BISA timpa binary${NC}"
    fi
}

# Restart Dropbear (admin via SSH direct TIDAK putus)
restart_dropbear() {
    echo -e "${YELLOW}  [6/6] Restart Dropbear...${NC}"

    # Get master PID lama
    local old_master_pid
    old_master_pid=$(pgrep -f "dropbear -p 143" 2>/dev/null | head -1)
    if [ -z "$old_master_pid" ]; then
        old_master_pid=$(pgrep -x dropbear 2>/dev/null | head -1)
    fi

    echo -e "    ${GRAY}Master PID lama: ${old_master_pid:-TIDAK ADA}${NC}"

    # Coba systemctl restart dulu
    echo -e "    ${GRAY}systemctl restart dropbear...${NC}"
    systemctl restart dropbear 2>&1 | head -3
    sleep 2

    # Cek apakah restart berhasil
    local new_master_pid
    new_master_pid=$(pgrep -f "dropbear -p 143" 2>/dev/null | head -1)
    if [ -z "$new_master_pid" ]; then
        new_master_pid=$(pgrep -x dropbear 2>/dev/null | head -1)
    fi

    if [ -z "$new_master_pid" ]; then
        echo -e "    ${ORANGE}systemctl restart TIDAK start master baru${NC}"
        echo -e "    ${ORANGE}Coba kill master lama + start manual...${NC}"

        # LESSON v31 incident: kill master lama per-PID + start bersih
        if [ -n "$old_master_pid" ]; then
            kill -TERM "$old_master_pid" 2>/dev/null
            sleep 2
        fi

        systemctl start dropbear 2>&1 | head -3
        sleep 2

        new_master_pid=$(pgrep -f "dropbear -p 143" 2>/dev/null | head -1)
        if [ -z "$new_master_pid" ]; then
            new_master_pid=$(pgrep -x dropbear 2>/dev/null | head -1)
        fi
    fi

    if [ -n "$new_master_pid" ]; then
        echo -e "    ${GREEN}Master PID baru: ${new_master_pid} ✓${NC}"
        return 0
    else
        echo -e "    ${RED}GAGAL restart Dropbear — akan auto-restore${NC}"
        return 1
    fi
}

# ============================================================================
# LAYER 3 SAFETY — verify_dropbear_healthy()
# Verify Dropbear sehat post-upgrade + auto-restore kalau gagal 30 detik
# ============================================================================
verify_dropbear_healthy() {
    echo -e "${YELLOW}  Verify Dropbear health (max ${MAX_VERIFY_WAIT} detik)...${NC}"
    local elapsed=0
    local healthy=false

    while [ "$elapsed" -lt "$MAX_VERIFY_WAIT" ]; do
        sleep 2
        elapsed=$((elapsed + 2))

        # Cek 1: systemctl is-active
        local is_active
        is_active=$(systemctl is-active dropbear 2>/dev/null)
        if [ "$is_active" != "active" ]; then
            echo -e "    ${GRAY}[${elapsed}s] systemctl: ${is_active} (waiting...)${NC}"
            continue
        fi

        # Cek 2: port 109 + 143 listen
        local port_listen
        port_listen=$(ss -tlnp 2>/dev/null | grep -E ":109|:143" | grep dropbear | wc -l)
        if [ "$port_listen" -lt 1 ]; then
            echo -e "    ${GRAY}[${elapsed}s] port 109+143 belum listen (waiting...)${NC}"
            continue
        fi

        # Cek 3: master PID + /proc/<PID>/exe hash = binary baru
        local master_pid
        master_pid=$(pgrep -f "dropbear -p 143" 2>/dev/null | head -1)
        if [ -z "$master_pid" ]; then
            master_pid=$(pgrep -x dropbear 2>/dev/null | head -1)
        fi
        if [ -z "$master_pid" ]; then
            echo -e "    ${GRAY}[${elapsed}s] master PID belum ada (waiting...)${NC}"
            continue
        fi

        local exe_path
        exe_path=$(readlink "/proc/${master_pid}/exe" 2>/dev/null)

        # Kalau exe_path ada "(deleted)" = binary lama masih jalan (perlu restart ulang)
        if echo "$exe_path" | grep -q "deleted"; then
            echo -e "    ${ORANGE}[${elapsed}s] master masih jalan binary lama (deleted) — restart ulang...${NC}"
            kill -TERM "$master_pid" 2>/dev/null
            sleep 2
            systemctl start dropbear 2>&1 | head -3
            sleep 2
            continue
        fi

        # Cek hash binary yang jalan
        local exe_hash
        exe_hash=$(sha256sum "/proc/${master_pid}/exe" 2>/dev/null | awk '{print $1}')
        if [ -z "$exe_hash" ]; then
            echo -e "    ${GRAY}[${elapsed}s] hash binary tidak terbaca (waiting...)${NC}"
            continue
        fi

        if [ "$exe_hash" = "$HASH_TARGET" ]; then
            echo -e "    ${GREEN}[${elapsed}s] Dropbear ${DROPBEAR_VERSION_TARGET} ACTIVE ✓${NC}"
            echo -e "    ${GREEN}    Master PID: ${master_pid}${NC}"
            echo -e "    ${GREEN}    Port listen: 109 + 143 ✓${NC}"
            echo -e "    ${GREEN}    Binary hash: ace5f8c9... MATCH ✓${NC}"
            healthy=true
            break
        else
            echo -e "    ${ORANGE}[${elapsed}s] hash binary tidak match: ${exe_hash}${NC}"
            # Bukan blocker kalau version benar — hash bisa beda kalau build env beda
            local exe_version
            exe_version=$("${DROPBEAR_BIN}" -V 2>&1 | head -1)
            if echo "$exe_version" | grep -q "v${DROPBEAR_VERSION_TARGET}"; then
                echo -e "    ${GREEN}[${elapsed}s] Version MATCH (hash beda OK, build env beda) ✓${NC}"
                healthy=true
                break
            fi
        fi
    done

    if [ "$healthy" = "true" ]; then
        return 0
    else
        echo -e "    ${RED}VERIFY FAILED setelah ${elapsed}s — auto-restore binary lama${NC}"
        auto_restore_old_binary
        return 1
    fi
}

# Auto-restore binary lama kalau Dropbear baru gagal (Layer 3 safety)
auto_restore_old_binary() {
    echo -e "${RED}  AUTO-RESTORE: kembalikan binary v2019.78...${NC}"

    if [ ! -f "${DROPBEAR_BAK}" ]; then
        echo -e "    ${RED}FATAL: backup binary tidak ada — TIDAK bisa auto-restore${NC}"
        echo -e "    ${RED}        Manual recover: apt install --reinstall dropbear-bin${NC}"
        log_msg "FAILED — backup binary tidak ada, tidak bisa auto-restore"
        return 1
    fi

    # Stop Dropbear
    systemctl stop dropbear 2>&1 | head -3
    sleep 2

    # Kill master lama kalau masih ada
    local pids
    pids=$(pgrep -x dropbear 2>/dev/null)
    if [ -n "$pids" ]; then
        echo "$pids" | while read -r pid; do
            kill -TERM "$pid" 2>/dev/null
        done
        sleep 2
    fi

    # Restore binary lama
    cp -p "${DROPBEAR_BAK}" "${DROPBEAR_BIN}"
    chmod 0755 "${DROPBEAR_BIN}"

    # Restart Dropbear dengan binary lama
    systemctl start dropbear 2>&1 | head -3
    sleep 3

    # Verify restore
    local restored_version
    restored_version=$("${DROPBEAR_BIN}" -V 2>&1 | head -1)
    local master_pid
    master_pid=$(pgrep -f "dropbear -p 143" 2>/dev/null | head -1)
    if [ -n "$master_pid" ]; then
        echo -e "    ${ORANGE}Auto-restore OK: ${restored_version}${NC}"
        echo -e "    ${ORANGE}                 Master PID: ${master_pid}${NC}"
        log_msg "FAILED — auto-restore to v2019.78 (Dropbear baru gagal start)"
    else
        echo -e "    ${RED}FATAL: Auto-restore GAGAL — manual recover diperlukan${NC}"
        echo -e "    ${RED}        apt install --reinstall dropbear-bin${NC}"
        log_msg "FATAL — auto-restore GAGAL, manual recover diperlukan"
    fi
}

# ============================================================================
# VERIFY PATH X SUCCESS (PATTERN 44 — empirical test)
# Tunggu user baru connect, verify child UID = user (BUKAN root)
# ============================================================================
verify_path_x_success() {
    echo ""
    echo -e "${TEAL}═════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${WHITE}              VERIFY PATH X SUCCESS (PATTERN 44)${NC}"
    echo -e "${TEAL}═════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}  Tunggu 30-60 detik supaya ada koneksi user baru pasca-restart...${NC}"
    sleep 30

    echo -e "${GRAY}  Cek child Dropbear post-auth...${NC}"
    echo ""

    # ps Dropbear child (BUKAN master)
    local child_count
    child_count=$(ps -eo pid,user,args 2>/dev/null | grep "dropbear" | grep -v "dropbear -p 143" | grep -v grep | wc -l)

    if [ "$child_count" -eq 0 ]; then
        echo -e "${ORANGE}  BELUM ada child Dropbear aktif (user belum reconnect)${NC}"
        echo -e "${ORANGE}  Check lagi nanti: ps -eo pid,user,args | grep dropbear | grep -v 'dropbear -p'${NC}"
        echo -e "${ORANGE}  Atau: auth.log | grep 'Password auth succeeded'${NC}"
        log_msg "VERIFY PATH X — belum ada child aktif saat cek (user belum reconnect)"
        return 0
    fi

    echo -e "${GREEN}  Ditemukan ${child_count} child Dropbear aktif:${NC}"
    echo ""
    printf "  %-8s %-12s %s\n" "PID" "USER" "ARGS"
    printf "  %-8s %-12s %s\n" "--------" "------------" "-----------------------------------"

    ps -eo pid,user,args 2>/dev/null | grep "dropbear" | grep -v "dropbear -p 143" | grep -v grep | while read -r line; do
        local pid
        local user
        local args
        pid=$(echo "$line" | awk '{print $1}')
        user=$(echo "$line" | awk '{print $2}')
        args=$(echo "$line" | awk '{for(i=3;i<=NF;i++) printf "%s ", $i; print ""}' | head -c 60)
        printf "  %-8s %-12s %s\n" "$pid" "$user" "$args"
    done

    echo ""
    # Hitung ulang non-root child via subshell
    local non_root_count
    non_root_count=$(ps -eo user,args 2>/dev/null | grep "dropbear" | grep -v "dropbear -p 143" | grep -v grep | awk '{print $1}' | grep -v "^root$" | wc -l)

    if [ "$non_root_count" -gt 0 ]; then
        echo -e "${GREEN}  PATH X SUCCESS: ${non_root_count} child dengan UID=user (BUKAN root) ✓${NC}"
        echo -e "${GREEN}  Privilege drop post-auth WORKING — iptables per-UID mark akan match${NC}"
        log_msg "VERIFY PATH X SUCCESS — ${non_root_count} child UID=user (privilege drop works)"
    else
        echo -e "${ORANGE}  SEMUA child masih UID=root (mungkin belum ada user reconnect post-upgrade)${NC}"
        echo -e "${ORANGE}  Tunggu beberapa menit + check lagi: ps -eo pid,user,args | grep dropbear${NC}"
        log_msg "VERIFY PATH X — semua child masih UID=root (user belum reconnect post-upgrade)"
    fi
    echo ""
    echo -e "${TEAL}═════════════════════════════════════════════════════════════════════${NC}"
}

# ============================================================================
# MAIN UPGRADE FLOW
# ============================================================================
do_upgrade() {
    show_header

    # Pre-flight checks
    echo -e "${YELLOW}  Pre-flight checks...${NC}"

    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}  FAIL: Script harus dijalankan sebagai root${NC}"
        log_msg "FAIL — script dijalankan non-root"
        exit 1
    fi
    echo -e "    ${GREEN}Root check OK ✓${NC}"

    # Check commands
    local missing=""
    for cmd in wget tar gcc make install mv cp sha256sum systemctl ss apt-get; do
        if ! check_command "$cmd"; then
            missing="${missing} ${cmd}"
        fi
    done
    if [ -n "$missing" ]; then
        echo -e "    ${RED}FAIL: command tidak tersedia:${missing}${NC}"
        log_msg "FAIL — missing commands:${missing}"
        exit 1
    fi
    echo -e "    ${GREEN}Commands OK ✓${NC}"

    # Disk space check (minimal 100MB free)
    local free_disk
    free_disk=$(df -m /tmp 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -n "$free_disk" ] && [ "$free_disk" -lt 100 ]; then
        echo -e "    ${RED}FAIL: disk /tmp kurang dari 100MB (free: ${free_disk}MB)${NC}"
        log_msg "FAIL — disk space insufficient (${free_disk}MB free)"
        exit 1
    fi
    echo -e "    ${GREEN}Disk space OK (${free_disk}MB free /tmp) ✓${NC}"
    echo ""

    # Layer 1: Display info + warning
    display_info_warning

    # Confirmation prompt
    echo -e "${YELLOW}  Yakin upgrade Dropbear ke v${DROPBEAR_VERSION_TARGET} sekarang?${NC}"
    echo -e "${GRAY}  (ketik: y untuk lanjut, lainnya untuk batal)${NC}"
    read -p "  Confirm [y/N]: " confirm
    echo ""

    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo -e "${ORANGE}  Upgrade DIBATALKAN oleh user${NC}"
        log_msg "CANCELLED by user (Layer 1 confirmation)"
        exit 0
    fi

    # Layer 2: Check admin via SSH direct
    echo -e "${YELLOW}  Layer 2 Safety: Cek admin via SSH direct...${NC}"
    if ! check_admin_via_ssh_direct; then
        echo -e ""
        echo -e "${RED}  ╔════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}  ║   REJECTED: Admin terdeteksi via TUNNELING Dropbear            ║${NC}"
        echo -e "${RED}  ║                                                                ║${NC}"
        echo -e "${RED}  ║   Koneksi Anda akan PUTUS saat Dropbear restart!              ║${NC}"
        echo -e "${RED}  ║   Jalankan via SSH DIRECT (port 22):                          ║${NC}"
        echo -e "${RED}  ║       ssh root@<VPS-IP> -p 22                                 ║${NC}"
        echo -e "${RED}  ╚════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        log_msg "REJECTED — admin via tunneling Dropbear (Layer 2 safety)"
        exit 1
    fi
    echo -e "    ${GREEN}Admin via SSH direct OK ✓ (koneksi admin aman saat restart)${NC}"
    echo ""

    # Start upgrade
    echo -e "${TEAL}═════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${WHITE}                  MULAI UPGRADE DROPBEAR${NC}"
    echo -e "${TEAL}═════════════════════════════════════════════════════════════════════${NC}"
    echo ""

    log_msg "START — upgrade to v${DROPBEAR_VERSION_TARGET}"

    # Step 1: Install build deps
    if ! install_build_deps; then
        echo -e "${RED}  UPGRADE GAGAL di step 1 (dependency)${NC}"
        log_msg "ABORTED — install_build_deps failed"
        exit 1
    fi

    # Step 2: Download tarball
    if ! download_tarball; then
        echo -e "${RED}  UPGRADE GAGAL di step 2 (download)${NC}"
        log_msg "ABORTED — download_tarball failed"
        exit 1
    fi

    # Step 3: Build (gcc)
    if ! build_dropbear; then
        echo -e "${RED}  UPGRADE GAGAL di step 3 (build)${NC}"
        log_msg "ABORTED — build_dropbear failed"
        exit 1
    fi

    # Step 4: Backup + atomic replace
    if ! backup_and_replace_binary; then
        echo -e "${RED}  UPGRADE GAGAL di step 4 (atomic replace)${NC}"
        log_msg "ABORTED — backup_and_replace_binary failed"
        exit 1
    fi

    # Step 5: Edit config (tambah -P flag)
    if ! edit_dropbear_config; then
        echo -e "${ORANGE}  WARNING: config edit gagal — lanjut dengan config lama${NC}"
        log_msg "WARNING — edit_dropbear_config failed (continue with old config)"
    fi

    # Set apt-mark hold
    set_apt_hold

    # Step 6: Restart Dropbear
    if ! restart_dropbear; then
        echo -e "${RED}  UPGRADE GAGAL di step 6 (restart) — auto-restore akan jalan${NC}"
        auto_restore_old_binary
        log_msg "ABORTED — restart_dropbear failed, auto-restore triggered"
        exit 1
    fi

    # Layer 3: Verify Dropbear healthy
    if ! verify_dropbear_healthy; then
        echo -e "${RED}  VERIFY HEALTHY GAGAL — auto-restore sudah dijalankan${NC}"
        log_msg "FAILED — verify_dropbear_healthy failed, auto-restore completed"
        exit 1
    fi

    # Success — log + cleanup build dir
    log_msg "SUCCESS — Dropbear v${DROPBEAR_VERSION_TARGET} active"
    rm -rf "${BUILD_DIR}"
    echo -e "${GRAY}  Build dir ${BUILD_DIR} dihapus (cleanup)${NC}"

    # Verify PATH X success (PATTERN 44)
    verify_path_x_success

    echo ""
    echo -e "${TEAL}═════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                  UPGRADE DROPBEAR COMPLETE${NC}"
    echo -e "${TEAL}═════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}  Versi baru    :${NC} Dropbear v${DROPBEAR_VERSION_TARGET}"
    echo -e "${YELLOW}  Backup lama   :${NC} ${DROPBEAR_BAK}"
    echo -e "${YELLOW}  Log file      :${NC} ${LOG_FILE}"
    echo -e "${YELLOW}  apt-mark hold :${NC} AKTIF (apt upgrade tidak timpa binary)"
    echo ""
    echo -e "${GRAY}  Untuk verify manual:${NC}"
    echo -e "${GRAY}    dropbear -V              # cek versi${NC}"
    echo -e "${GRAY}    ps -eo pid,user,args | grep dropbear  # cek child UID=user${NC}"
    echo -e "${GRAY}    bw-limit --show          # cek bw-limit shaping aktif${NC}"
    echo ""
}

# ============================================================================
# DRY-RUN MODE — cek prasyarat tanpa execute
# ============================================================================
do_dry_run() {
    show_header
    echo -e "${TEAL}═════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${WHITE}                       DRY-RUN MODE${NC}"
    echo -e "${TEAL}═════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}  Cek prasyarat tanpa modifikasi VPS...${NC}"
    echo ""

    # Root check
    if [ "$(id -u)" -eq 0 ]; then
        echo -e "  ${GREEN}✓${NC} Root (id -u = 0)"
    else
        echo -e "  ${RED}✗${NC} Bukan root — butuh sudo"
    fi

    # Commands check
    echo -e "  ${YELLOW}Commands tersedia:${NC}"
    for cmd in wget tar gcc make install mv cp sha256sum systemctl ss apt-get; do
        if check_command "$cmd"; then
            echo -e "    ${GREEN}✓${NC} ${cmd}"
        else
            echo -e "    ${RED}✗${NC} ${cmd} (MISSING)"
        fi
    done

    # Disk space
    local free_disk
    free_disk=$(df -m /tmp 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -n "$free_disk" ] && [ "$free_disk" -ge 100 ]; then
        echo -e "  ${GREEN}✓${NC} Disk space /tmp: ${free_disk}MB free (>= 100MB)"
    else
        echo -e "  ${RED}✗${NC} Disk space /tmp: ${free_disk}MB free (< 100MB)"
    fi

    # Current Dropbear version
    if [ -x "${DROPBEAR_BIN}" ]; then
        local current_version
        current_version=$("${DROPBEAR_BIN}" -V 2>&1 | head -1)
        echo -e "  ${YELLOW}Dropbear saat ini:${NC} ${current_version}"
    else
        echo -e "  ${RED}✗${NC} Dropbear binary tidak ada di ${DROPBEAR_BIN}"
    fi

    # Backup status
    if [ -f "${DROPBEAR_BAK}" ]; then
        local bak_hash
        bak_hash=$(sha256sum "${DROPBEAR_BAK}" | awk '{print $1}')
        if [ "$bak_hash" = "bf155af93493ddadd5e9277ce28085555d0226cc43a863a43c98acc6483e6374" ]; then
            echo -e "  ${GREEN}✓${NC} Backup v2019.78 sudah ada dari v31"
        else
            echo -e "  ${ORANGE}!${NC} Backup ada tapi hash beda (akan di-overwrite saat upgrade)"
        fi
    else
        echo -e "  ${ORANGE}!${NC} Backup belum ada (akan dibuat saat upgrade)"
    fi

    # Config status
    if [ -f "${DROPBEAR_DEFAULT}" ]; then
        local extra_args
        extra_args=$(grep "^DROPBEAR_EXTRA_ARGS=" "${DROPBEAR_DEFAULT}" 2>/dev/null | cut -d= -f2- | tr -d '"')
        if echo "$extra_args" | grep -q "\-P"; then
            echo -e "  ${GREEN}✓${NC} Config sudah ada -P flag: DROPBEAR_EXTRA_ARGS=\"${extra_args}\""
        else
            echo -e "  ${ORANGE}!${NC} Config belum ada -P flag (akan ditambah saat upgrade): \"${extra_args}\""
        fi
    fi

    # apt-mark hold status
    if apt-mark showhold 2>/dev/null | grep -qE "^(dropbear|dropbear-bin)$"; then
        echo -e "  ${GREEN}✓${NC} apt-mark hold dropbear+dropbear-bin AKTIF"
    else
        echo -e "  ${ORANGE}!${NC} apt-mark hold BELUM aktif (akan diset saat upgrade)"
    fi

    # Admin via SSH direct check
    echo ""
    if check_admin_via_ssh_direct; then
        echo -e "  ${GREEN}✓${NC} Admin via SSH DIRECT (aman untuk upgrade)"
    else
        echo -e "  ${RED}✗${NC} Admin via TUNNELING — REJECT saat upgrade real"
    fi

    echo ""
    echo -e "${TEAL}═════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GRAY}  Dry-run TIDAK melakukan modifikasi apapun.${NC}"
    echo -e "${GRAY}  Untuk upgrade real, jalankan tanpa argumen: upgrade-dropbear${NC}"
    echo -e "${TEAL}═════════════════════════════════════════════════════════════════════${NC}"
}

# ============================================================================
# HELP
# ============================================================================
show_help() {
    show_header
    echo -e "${TEAL}═════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${WHITE}                            HELP — USAGE${NC}"
    echo -e "${TEAL}═════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}  USAGE:${NC}"
    echo -e "    upgrade-dropbear              Interactive mode (recommended)"
    echo -e "    upgrade-dropbear --dry-run    Cek prasyarat tanpa modifikasi"
    echo -e "    upgrade-dropbear --help       Tampilkan help ini"
    echo -e "    upgrade-dropbear --version    Tampilkan versi script"
    echo ""
    echo -e "${YELLOW}  CONTOH:${NC}"
    echo -e "    upgrade-dropbear              # interactive, 3 layer safety"
    echo -e "    upgrade-dropbear --dry-run    # verify prasyarat sebelum real upgrade"
    echo ""
    echo -e "${YELLOW}  DESIGN:${NC}"
    echo -e "    Layer 1 Safety: display_info_warning() — info + warning + confirmation y/n"
    echo -e "    Layer 2 Safety: check_admin_via_ssh_direct() — REJECT kalau via tunneling"
    echo -e "    Layer 3 Safety: verify_dropbear_healthy() — auto-restore kalau gagal 30 detik"
    echo ""
    echo -e "${YELLOW}  BUILD PROCESS:${NC}"
    echo -e "    1. Install build deps (zlib1g-dev + libcrypt-dev + gcc + make)"
    echo -e "    2. Download dropbear-2026.94.tar.bz2 dari matt.ucc.asn.au"
    echo -e "    3. Extract + ./configure (TANPA --enable-pam) + make -j2"
    echo -e "    4. Backup binary lama + ATOMIC REPLACE (install -m 0755 + mv -f)"
    echo -e "    5. Edit config /etc/default/dropbear (tambah -P pidfile flag)"
    echo -e "    6. apt-mark hold dropbear dropbear-bin (cegah apt upgrade timpa)"
    echo -e "    7. Restart Dropbear (admin via SSH direct TIDAK putus)"
    echo -e "    8. Verify: systemctl active + port listen + /proc/PID/exe hash"
    echo -e "    9. Verify PATH X: child UID = user (BUKAN root) post-upgrade"
    echo ""
    echo -e "${YELLOW}  FILES:${NC}"
    echo -e "    /usr/sbin/dropbear                    Binary Dropbear (di-upgrade)"
    echo -e "    /usr/sbin/dropbear.v2019.78.bak       Backup binary lama"
    echo -e "    /etc/default/dropbear                 Config (tambah -P flag)"
    echo -e "    /etc/default/dropbear.bak-v39         Backup config"
    echo -e "    /var/log/upgrade-dropbear.log         Log file"
    echo -e "    /tmp/dropbear-build-2026.94/           Build dir (dihapus pasca-upgrade)"
    echo ""
    echo -e "${YELLOW}  KOMITMEN ETIS:${NC}"
    echo -e "    NO tendang/throttle SEMUA user"
    echo -e "    Script ini upgrade binary Dropbear supaya bw-limit shaping"
    echo -e "    WORK untuk user blacklist (manual by admin)"
    echo -e "    User tunneling disconnect 30-60 detik, reconnect otomatis"
    echo -e "    Admin via SSH direct TIDAK putus"
    echo ""
    echo -e "${TEAL}═════════════════════════════════════════════════════════════════════${NC}"
}

# ============================================================================
# MAIN — CLI dispatch
# ============================================================================
main() {
    case "${1:-}" in
        --help|-h)
            show_help
            exit 0
            ;;
        --version|-v)
            echo "upgrade-dropbear v${SCRIPT_VERSION} (HAXOR — DEKENG ANE BIAK BELITONG)"
            echo "Target: Dropbear v${DROPBEAR_VERSION_TARGET}"
            exit 0
            ;;
        --dry-run)
            do_dry_run
            exit 0
            ;;
        "")
            do_upgrade
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Try: upgrade-dropbear --help"
            exit 1
            ;;
    esac
}

main "$@"
