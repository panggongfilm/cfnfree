#!/bin/bash
# ============================================================================
# Script  : banner-manager.sh
# Version : 1.0 (Sesi 2.8 — v41: DRAFT banner-manager.sh)
# Project : HAXOR cfnfree (panggongfilm/cfnfree fork)
# Branding: HAXOR PANEL TUNNELING
# Tagline : DEKENG ANE BIAK BELITONG
# Source  : Original HAXOR wrapper — Pattern 2 run-once + Pattern 5 palette
#           ANSI-C + 3 layer safety pattern (adaptasi dari upgrade-dropbear.sh v1.0)
# Lokasi  : /usr/bin/banner-manager (lokasi BELITONG #13 NEW v41)
# Function: Interactive banner manager untuk /etc/issue.net
#           4 opsi: tampilkan + edit + template + reset
#           Banner langsung aktif untuk koneksi baru (NO restart service —
#           /etc/issue.net dibaca Dropbear saat client connect)
# Safety  : 3 Layer Safety
#           Layer 1: preview + confirmation y/n sebelum apply edit
#           Layer 2: backup /etc/issue.net ke .bak-YYYYMMDD-HHMMSS sebelum
#                    setiap perubahan
#           Layer 3: validate input (no null bytes, max 4096 chars, escape
#                    shell metacharacters)
# Called  : menu.sh v3.1 case [07] Banner Manager
# ============================================================================

# === Constants ===
SCRIPT_VERSION="1.0"
BANNER_FILE="/etc/issue.net"
BACKUP_PREFIX="/etc/issue.net.bak-"
DEFAULT_BANNER_FILE="/etc/issue.net.default"
MAX_BANNER_LENGTH=4096

# === Palette 256-color (ANSI-C quoting $'...' — LESSON v6 FIX1) ===
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
DGRAY=$'\033[38;5;240m'
NC=$'\033[0m'
BG_CYAN=$'\033[48;5;24m'
BG_TEAL=$'\033[48;5;30m'

# === Functions ===

show_header() {
    clear
    echo -e "${BG_CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BG_TEAL}        BANNER MANAGER v${SCRIPT_VERSION} — HAXOR TUNNELING         ${NC}"
    echo -e "${BG_CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}            DEKENG ANE BIAK BELITONG${NC}"
    echo -e "${DGRAY}        Banner langsung aktif untuk koneksi baru${NC}"
    echo -e "${DGRAY}        NO restart service — Dropbear baca saat connect${NC}"
    echo ""
}

pause() {
    echo ""
    echo -e "${GRAY}Tekan enter untuk kembali ke menu Banner Manager...${NC}"
    read -r dummy
}

log_msg() {
    # ISO-8601 timestamp log
    local msg="$1"
    echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] ${msg}"
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}ERROR: Script ini butuh akses root.${NC}"
        echo -e "${YELLOW}Jalankan dengan: sudo banner-manager${NC}"
        exit 1
    fi
}

check_command() {
    # Pattern 6 — validasi command tersedia
    local missing=0
    for cmd in cat cp mv rm date mkdir ls wc grep printf; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${RED}ERROR: Command '${cmd}' tidak tersedia.${NC}"
            missing=1
        fi
    done
    return $missing
}

backup_banner() {
    # Layer 2 safety — backup sebelum setiap perubahan
    local ts
    ts=$(date '+%Y%m%d-%H%M%S')
    local backup="${BACKUP_PREFIX}${ts}"
    if [ -f "$BANNER_FILE" ]; then
        cp -p "$BANNER_FILE" "$backup"
        echo -e "${GREEN}Backup dibuat: ${backup}${NC}"
        log_msg "BACKUP: ${BANNER_FILE} -> ${backup}"
    else
        echo -e "${YELLOW}Banner file belum ada, skip backup${NC}"
    fi
}

validate_input() {
    # Layer 3 safety — validate input string
    # Returns 0 if valid, 1 if invalid
    local input="$1"
    # Check empty
    if [ -z "$input" ]; then
        echo -e "${RED}ERROR: Input kosong — DITOLAK${NC}"
        return 1
    fi
    # Check null bytes (LC_ALL=C untuk hindari locale issue)
    if printf '%s' "$input" | LC_ALL=C grep -qP '\x00'; then
        echo -e "${RED}ERROR: Input mengandung null bytes — DITOLAK${NC}"
        return 1
    fi
    # Check length
    local len=${#input}
    if [ "$len" -gt "$MAX_BANNER_LENGTH" ]; then
        echo -e "${RED}ERROR: Input terlalu panjang (${len} > ${MAX_BANNER_LENGTH} chars) — DITOLAK${NC}"
        return 1
    fi
    return 0
}

show_banner_current() {
    # Opsi 1 — read-only display
    show_header
    echo -e "${CYAN}━━━ BANNER SAAT INI (/etc/issue.net) ━━━${NC}"
    echo ""
    if [ -f "$BANNER_FILE" ]; then
        local size lines
        size=$(wc -c < "$BANNER_FILE")
        lines=$(wc -l < "$BANNER_FILE")
        echo -e "${GRAY}File: ${BANNER_FILE} | Size: ${size} bytes | Lines: ${lines}${NC}"
        echo -e "${DGRAY}────────────────────────────────────────${NC}"
        echo ""
        cat "$BANNER_FILE"
        echo ""
        echo -e "${DGRAY}────────────────────────────────────────${NC}"
        log_msg "VIEW: Admin view banner saat ini (${size} bytes)"
    else
        echo -e "${YELLOW}Banner file TIDAK ADA di ${BANNER_FILE}${NC}"
        echo -e "${GRAY}User yang connect tidak akan melihat banner apapun${NC}"
        log_msg "VIEW: Banner file tidak ada"
    fi
    pause
}

edit_banner_interactive() {
    # Opsi 2 — edit banner via read multiline
    show_header
    echo -e "${CYAN}━━━ EDIT BANNER ━━━${NC}"
    echo ""
    echo -e "${GRAY}Ketik banner baru baris per baris.${NC}"
    echo -e "${GRAY}Selesai: ketik ${YELLOW}.EOF${GRAY} di baris baru, lalu enter${NC}"
    echo -e "${GRAY}Batal: ketik ${YELLOW}.CANCEL${GRAY} di baris baru${NC}"
    echo -e "${GRAY}Max: ${MAX_BANNER_LENGTH} karakter total${NC}"
    echo ""
    echo -e "${DGRAY}────────────────────────────────────────${NC}"

    local new_banner=""
    local line
    local line_count=0
    while IFS= read -r line; do
        case "$line" in
            .EOF)
                echo -e "${DGRAY}────────────────────────────────────────${NC}"
                echo ""
                break
                ;;
            .CANCEL)
                echo -e "${YELLOW}Edit dibatalkan oleh admin.${NC}"
                log_msg "EDIT: Cancelled by admin"
                pause
                return 0
                ;;
            *)
                line_count=$((line_count + 1))
                if [ $line_count -eq 1 ]; then
                    new_banner="$line"
                else
                    new_banner="${new_banner}"$'\n'"${line}"
                fi
                ;;
        esac
    done

    # Layer 3 — validate input
    if ! validate_input "$new_banner"; then
        pause
        return 1
    fi

    # Layer 1 — preview + confirmation
    show_header
    echo -e "${CYAN}━━━ PREVIEW BANNER BARU ━━━${NC}"
    echo ""
    echo -e "${GRAY}Size: ${#new_banner} bytes | Lines: ${line_count}${NC}"
    echo -e "${DGRAY}────────────────────────────────────────${NC}"
    echo ""
    printf '%s\n' "$new_banner"
    echo ""
    echo -e "${DGRAY}────────────────────────────────────────${NC}"
    echo ""
    echo -e "${YELLOW}Yakin ingin apply banner ini? (y/n): ${NC}"
    read -r confirm
    case "$confirm" in
        y|Y)
            # Layer 2 — backup
            backup_banner
            # Apply
            printf '%s\n' "$new_banner" > "$BANNER_FILE"
            echo -e "${GREEN}Banner baru DITERAPKAN ke ${BANNER_FILE}${NC}"
            echo -e "${GRAY}Banner aktif untuk koneksi baru (NO restart service)${NC}"
            log_msg "EDIT: Banner updated (${#new_banner} bytes, ${line_count} lines)"
            ;;
        *)
            echo -e "${YELLOW}Edit dibatalkan.${NC}"
            log_msg "EDIT: Cancelled at confirmation"
            ;;
    esac
    pause
}

get_template() {
    # Return template content berdasarkan name
    local tpl="$1"
    case "$tpl" in
        default)
            cat <<'BANNER_EOF'
╔════════════════════════════════════════════╗
║        HAXOR PANEL TUNNELING — SSH         ║
║         DEKENG ANE BIAK BELITONG           ║
╚════════════════════════════════════════════╝
   Unauthorized access is strictly prohibited.
        By using this service you agree
     to all terms and conditions set forth.
BANNER_EOF
            ;;
        welcome)
            cat <<'BANNER_EOF'
╔════════════════════════════════════════════╗
║      SELAMAT DATANG DI HAXOR TUNNELING     ║
║         DEKENG ANE BIAK BELITONG           ║
╚════════════════════════════════════════════╝
   Silakan login dengan akun yang terdaftar.
        Hubungi admin untuk bantuan.
BANNER_EOF
            ;;
        maintenance)
            cat <<'BANNER_EOF'
╔════════════════════════════════════════════╗
║      HAXOR TUNNELING — MAINTENANCE MODE    ║
║         DEKENG ANE BIAK BELITONG           ║
╚════════════════════════════════════════════╝
   Server sedang dalam pemeliharaan.
      Silakan coba lagi nanti.
        Estimasi selesai: 30 menit
BANNER_EOF
            ;;
        warn_scan)
            cat <<'BANNER_EOF'
╔════════════════════════════════════════════╗
║     HAXOR TUNNELING — ANTI BRUTE FORCE     ║
║         DEKENG ANE BIAK BELITONG           ║
╚════════════════════════════════════════════╝
  PERINGATAN: Semua aktivitas login di-log.
   Brute force / scanning = BAN otomatis.
      Gunakan akun Anda sendiri saja.
BANNER_EOF
            ;;
        blank)
            # Empty banner
            printf ''
            ;;
        *)
            return 1
            ;;
    esac
}

show_template_menu() {
    # Opsi 3 — template preset submenu
    show_header
    echo -e "${CYAN}━━━ TEMPLATE BANNER ━━━${NC}"
    echo ""
    echo -e "${YELLOW}[1]${NC} Default HAXOR + BELITONG"
    echo -e "${YELLOW}[2]${NC} Welcome message"
    echo -e "${YELLOW}[3]${NC} Maintenance mode"
    echo -e "${YELLOW}[4]${NC} Warn scanner (peringatan anti-brute-force)"
    echo -e "${YELLOW}[5]${NC} Blank (kosongkan banner)"
    echo ""
    echo -e "${YELLOW}[0X]${NC} Kembali ke menu Banner Manager"
    echo ""
    echo -e "${GRAY}Pilih template: ${NC}"
    read -r choice
    case "$choice" in
        1) apply_template "default" ;;
        2) apply_template "welcome" ;;
        3) apply_template "maintenance" ;;
        4) apply_template "warn_scan" ;;
        5) apply_template "blank" ;;
        0|00|x|X|0x|0X)
            return 0
            ;;
        *)
            echo -e "${RED}Pilihan tidak dikenal: ${choice}${NC}"
            sleep 1
            return 0
            ;;
    esac
}

apply_template() {
    local tpl="$1"
    local content
    content=$(get_template "$tpl")
    if [ -z "$content" ] && [ "$tpl" != "blank" ]; then
        echo -e "${RED}ERROR: Template '${tpl}' tidak dikenal${NC}"
        pause
        return 1
    fi

    # Layer 1 — preview + confirmation
    show_header
    echo -e "${CYAN}━━━ PREVIEW TEMPLATE: ${tpl} ━━━${NC}"
    echo ""
    if [ "$tpl" = "blank" ]; then
        echo -e "${YELLOW}(banner kosong — user tidak akan melihat apapun)${NC}"
    else
        echo -e "${GRAY}Size: ${#content} bytes${NC}"
        echo -e "${DGRAY}────────────────────────────────────────${NC}"
        echo ""
        printf '%s\n' "$content"
        echo ""
        echo -e "${DGRAY}────────────────────────────────────────${NC}"
    fi
    echo ""
    echo -e "${YELLOW}Yakin ingin apply template '${tpl}'? (y/n): ${NC}"
    read -r confirm
    case "$confirm" in
        y|Y)
            # Layer 2 — backup
            backup_banner
            # Apply
            if [ "$tpl" = "blank" ]; then
                printf '' > "$BANNER_FILE"
            else
                printf '%s\n' "$content" > "$BANNER_FILE"
            fi
            echo -e "${GREEN}Template '${tpl}' DITERAPKAN ke ${BANNER_FILE}${NC}"
            echo -e "${GRAY}Banner aktif untuk koneksi baru (NO restart service)${NC}"
            log_msg "TEMPLATE: Applied template '${tpl}' (${#content} bytes)"
            ;;
        *)
            echo -e "${YELLOW}Apply template dibatalkan.${NC}"
            log_msg "TEMPLATE: Cancelled at confirmation ('${tpl}')"
            ;;
    esac
    pause
}

reset_banner() {
    # Opsi 4 — reset ke default
    show_header
    echo -e "${CYAN}━━━ RESET BANNER KE DEFAULT ━━━${NC}"
    echo ""
    if [ -f "$DEFAULT_BANNER_FILE" ]; then
        echo -e "${GRAY}Default banner akan di-restore dari: ${DEFAULT_BANNER_FILE}${NC}"
        echo ""
        echo -e "${DGRAY}────────────────────────────────────────${NC}"
        cat "$DEFAULT_BANNER_FILE"
        echo -e "${DGRAY}────────────────────────────────────────${NC}"
    else
        echo -e "${YELLOW}Default banner file TIDAK ADA (${DEFAULT_BANNER_FILE})${NC}"
        echo -e "${GRAY}Reset akan pakai template 'default' HAXOR + BELITONG${NC}"
        echo ""
        echo -e "${DGRAY}────────────────────────────────────────${NC}"
        get_template "default"
        echo -e "${DGRAY}────────────────────────────────────────${NC}"
    fi
    echo ""
    echo -e "${YELLOW}Yakin ingin reset banner ke default? (y/n): ${NC}"
    read -r confirm
    case "$confirm" in
        y|Y)
            # Layer 2 — backup
            backup_banner
            # Apply
            if [ -f "$DEFAULT_BANNER_FILE" ]; then
                cp -p "$DEFAULT_BANNER_FILE" "$BANNER_FILE"
                echo -e "${GREEN}Banner di-restore dari ${DEFAULT_BANNER_FILE}${NC}"
                log_msg "RESET: Restored from ${DEFAULT_BANNER_FILE}"
            else
                # Fallback pakai template default
                local content
                content=$(get_template "default")
                printf '%s\n' "$content" > "$BANNER_FILE"
                echo -e "${GREEN}Banner di-reset ke template default HAXOR${NC}"
                log_msg "RESET: Restored from template default (fallback)"
            fi
            echo -e "${GRAY}Banner aktif untuk koneksi baru (NO restart service)${NC}"
            ;;
        *)
            echo -e "${YELLOW}Reset dibatalkan.${NC}"
            log_msg "RESET: Cancelled at confirmation"
            ;;
    esac
    pause
}

cmd_help() {
    show_header
    echo -e "${CYAN}━━━ BANTUAN — BANNER MANAGER v${SCRIPT_VERSION} ━━━${NC}"
    echo ""
    echo -e "${YELLOW}DESKRIPSI:${NC}"
    echo -e "  Interactive banner manager untuk /etc/issue.net"
    echo -e "  Banner langsung aktif untuk koneksi baru — NO restart service"
    echo ""
    echo -e "${YELLOW}OPSI MENU:${NC}"
    echo -e "  ${GREEN}[1]${NC} Tampilkan banner saat ini (read-only)"
    echo -e "  ${GREEN}[2]${NC} Edit banner (input multiline)"
    echo -e "  ${GREEN}[3]${NC} Template banner (5 preset)"
    echo -e "  ${GREEN}[4]${NC} Reset ke default"
    echo -e "  ${GREEN}[5]${NC} Bantuan"
    echo -e "  ${GREEN}[0X]${NC} Exit ke menu utama"
    echo ""
    echo -e "${YELLOW}TEMPLATE PRESET:${NC}"
    echo -e "  [1] Default HAXOR + BELITONG"
    echo -e "  [2] Welcome message"
    echo -e "  [3] Maintenance mode"
    echo -e "  [4] Warn scanner (anti-brute-force)"
    echo -e "  [5] Blank (kosongkan banner)"
    echo ""
    echo -e "${YELLOW}3 LAYER SAFETY:${NC}"
    echo -e "  Layer 1: Preview + confirmation y/n sebelum apply"
    echo -e "  Layer 2: Backup otomatis ke .bak-YYYYMMDD-HHMMSS"
    echo -e "  Layer 3: Validate input (no null bytes, max ${MAX_BANNER_LENGTH} chars)"
    echo ""
    echo -e "${YELLOW}FILES:${NC}"
    echo -e "  ${BANNER_FILE}              — banner aktif"
    echo -e "  ${BACKUP_PREFIX}YYYYMMDD-HHMMSS — backup otomatis"
    echo -e "  ${DEFAULT_BANNER_FILE}        — default banner (kalau ada)"
    echo ""
    echo -e "${YELLOW}CARA KERJA:${NC}"
    echo -e "  1. Dropbear baca /etc/issue.net saat client connect"
    echo -e "  2. Banner ditampilkan ke client sebelum auth"
    echo -e "  3. Perubahan langsung aktif untuk koneksi BARU"
    echo -e "  4. User yang sedang connect tetap lihat banner lama"
    echo ""
    pause
}

show_menu() {
    show_header
    echo -e "${CYAN}━━━ MENU BANNER MANAGER ━━━${NC}"
    echo ""
    echo -e "  ${YELLOW}[1]${NC} Tampilkan banner saat ini"
    echo -e "  ${YELLOW}[2]${NC} Edit banner"
    echo -e "  ${YELLOW}[3]${NC} Template banner"
    echo -e "  ${YELLOW}[4]${NC} Reset ke default"
    echo -e "  ${YELLOW}[5]${NC} Bantuan"
    echo ""
    echo -e "  ${YELLOW}[0X]${NC} Exit ke menu utama"
    echo ""
}

handle_choice() {
    local choice="$1"
    case "$choice" in
        1|01) show_banner_current ;;
        2|02) edit_banner_interactive ;;
        3|03) show_template_menu ;;
        4|04) reset_banner ;;
        5|05) cmd_help ;;
        0|00|x|X|0x|0X)
            echo -e "${GRAY}Kembali ke menu utama HAXOR...${NC}"
            sleep 1
            clear
            menu
            exit 0
            ;;
        *)
            echo -e "${RED}Pilihan tidak dikenal: ${choice}${NC}"
            echo -e "${GRAY}Pilihan valid: [01-05] atau [0X] untuk exit${NC}"
            sleep 2
            ;;
    esac
}

main() {
    check_root
    if ! check_command; then
        echo -e "${RED}Prasyarat command tidak terpenuhi. Install dulu.${NC}"
        exit 1
    fi

    # CLI dispatch
    case "${1:-}" in
        --help|-h)
            cmd_help
            exit 0
            ;;
        --version|-v)
            echo "banner-manager v${SCRIPT_VERSION} (HAXOR — DEKENG ANE BIAK BELITONG)"
            exit 0
            ;;
        --show)
            show_banner_current
            exit 0
            ;;
        "")
            # Interactive mode
            ;;
        *)
            echo "Usage: banner-manager [--help|--version|--show]"
            echo "Atau jalankan tanpa argumen untuk interactive mode"
            exit 1
            ;;
    esac

    # Re-entrant while-loop (Pattern 3 v9 — anti stack overflow)
    while true; do
        show_menu
        echo -e "${YELLOW}Pilih opsi [01-05 / 0X untuk keluar]: ${NC}"
        read -r choice
        handle_choice "$choice"
    done
}

main "$@"
