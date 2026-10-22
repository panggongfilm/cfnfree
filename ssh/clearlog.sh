#!/bin/bash
# ============================================================================
#  Script   : clearlog.sh
#  Source   : Adaptasi dari script open-source (lizsvr/cfnfree)
#  Function : Bersihkan semua file log di /var/log/ (clear log system)
#  Branding : HAXOR Panel Tunneling
#  Tagline  : DEKENG ANE BIAK BELITONG
# ============================================================================
#  Pola: run-once dengan confirmation prompt + pause di akhir.
#        Tidak pakai show_menu() karena hanya 1 aksi (clear logs).
#  Validasi: cek command dasar (find, echo) sebelum eksekusi.
# ============================================================================

# --- Palette warna modern 256-color ---
# Pakai ANSI-C quoting $'...' supaya byte ESC tersimpan langsung di variabel,
# sehingga warna tampil benar di echo, echo -e, read -p, dan printf.
CYAN=$'\033[38;5;51m'      # Bright cyan - primary
TEAL=$'\033[38;5;38m'      # Teal - secondary
GREEN=$'\033[38;5;48m'     # Mint green - status OK
YELLOW=$'\033[38;5;227m'   # Soft yellow - menu numbers
ORANGE=$'\033[38;5;215m'   # Soft orange - warning
RED=$'\033[38;5;203m'      # Soft red - error
PINK=$'\033[38;5;213m'     # Soft pink - accent
WHITE=$'\033[38;5;255m'    # Off-white - text normal
GRAY=$'\033[38;5;245m'     # Light gray - subtle
DGRAY=$'\033[38;5;240m'    # Dark gray - border
NC=$'\033[0m'              # Reset
BG_CYAN=$'\033[48;5;30m'   # Dark cyan bg - header box
BG_TEAL=$'\033[48;5;23m'   # Dark teal bg - secondary

# --- Helper: header box ---
show_header() {
    clear
    echo -e "${DGRAY}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${DGRAY}║${BG_CYAN}${WHITE}  CLEAR LOG MONITOR - HAXOR                                         ${NC}${DGRAY}║${NC}"
    echo -e "${DGRAY}║${BG_TEAL}${YELLOW}  DEKENG ANE BIAK BELITONG                                          ${NC}${DGRAY}║${NC}"
    echo -e "${DGRAY}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# --- Helper: pause di akhir, kembali ke menu utama ---
pause() {
    echo ""
    echo -e "${GRAY}Tekan enter untuk kembali ke menu utama...${NC}"
    read -r dummy
    menu
}

# --- Helper: clear satu file log dengan pretty output ---
clear_log_file() {
    local file="$1"
    if [ -f "$file" ]; then
        echo > "$file" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo -e "  ${GREEN}✓${NC} ${WHITE}$file${NC} ${GRAY}cleared${NC}"
        else
            echo -e "  ${ORANGE}!${NC} ${WHITE}$file${NC} ${GRAY}(skip, no write access)${NC}"
        fi
    fi
}

# --- Main ---
main() {
    show_header

    # Validasi command dasar
    if ! command -v find >/dev/null 2>&1; then
        echo -e "${RED}ERROR:${NC} ${WHITE}Command 'find' tidak ditemukan.${NC}"
        echo -e "${GRAY}Install dengan: apt install -y findutils${NC}"
        pause
        return 1
    fi

    # Info ringkas
    echo -e "${CYAN}[*]${NC} ${WHITE}Fungsi:${NC} ${GRAY}Bersihkan semua file log di /var/log/${NC}"
    echo -e "${CYAN}[*]${NC} ${WHITE}Target:${NC} ${GRAY}*.log, *.err, mail.*, syslog, btmp, messages, debug${NC}"
    echo ""

    # Hitung estimasi file yang akan di-clear (preview)
    local count_log=$(find /var/log/ -name "*.log" 2>/dev/null | wc -l)
    local count_err=$(find /var/log/ -name "*.err" 2>/dev/null | wc -l)
    local count_mail=$(find /var/log/ -name "mail.*" 2>/dev/null | wc -l)
    local total_files=$((count_log + count_err + count_mail + 4))

    echo -e "${TEAL}[i]${NC} ${WHITE}Estimasi file yang akan di-clear:${NC} ${YELLOW}${total_files}${NC} ${GRAY}file${NC}"
    echo -e "    ${GRAY}- *.log     : ${count_log} file${NC}"
    echo -e "    ${GRAY}- *.err     : ${count_err} file${NC}"
    echo -e "    ${GRAY}- mail.*     : ${count_mail} file${NC}"
    echo -e "    ${GRAY}- file statis: 4 (syslog, btmp, messages, debug)${NC}"
    echo ""
    echo -e "${ORANGE}[!]${NC} ${YELLOW}PERINGATAN:${NC} ${WHITE}Semua isi log akan dihapus permanen.${NC}"
    echo -e "${GRAY}    Tindakan ini tidak bisa di-undo. Pastikan tidak sedang debugging issue.${NC}"
    echo ""

    # Confirmation prompt (P9 test point #1)
    read -p "${YELLOW}Yakin ingin clear semua log? (y/n): ${NC}" confirm
    echo ""

    case "$confirm" in
        y|Y|ya|ya|YA|yes|YES|Yes)
            # Lanjut clear
            ;;
        *)
            echo -e "${RED}✗${NC} ${WHITE}Operasi dibatalkan.${NC}"
            echo -e "${GRAY}Tidak ada file yang dihapus.${NC}"
            pause
            return 0
            ;;
    esac

    echo -e "${CYAN}[*]${NC} ${WHITE}Memulai pembersihan log...${NC}"
    echo ""

    # Clear semua *.log
    echo -e "${TEAL}--- *.log files ---${NC}"
    for log in $(find /var/log/ -name "*.log" 2>/dev/null); do
        clear_log_file "$log"
    done

    # Clear semua *.err
    echo -e "${TEAL}--- *.err files ---${NC}"
    for log in $(find /var/log/ -name "*.err" 2>/dev/null); do
        clear_log_file "$log"
    done

    # Clear mail.*
    echo -e "${TEAL}--- mail.* files ---${NC}"
    for log in $(find /var/log/ -name "mail.*" 2>/dev/null); do
        clear_log_file "$log"
    done

    # Clear file statis
    echo -e "${TEAL}--- static files ---${NC}"
    clear_log_file "/var/log/syslog"
    clear_log_file "/var/log/btmp"
    clear_log_file "/var/log/messages"
    clear_log_file "/var/log/debug"

    echo ""
    echo -e "${GREEN}✓${NC} ${WHITE}Pembersihan log selesai.${NC}"
    echo -e "${GRAY}Semua file log di /var/log/ sudah dikosongkan.${NC}"

    # Pause prompt (P9 test point #2)
    pause
}

# --- Entrypoint ---
main
