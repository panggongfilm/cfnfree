#!/bin/bash
#
# ============================================================
# Script   : speedtest-haxor.sh
# Version  : 1.0 (Sesi 1.2 - Speedtest Wrapper)
# Repo     : panggongfilm/cfnfree
# Path     : /ssh/speedtest-haxor.sh
# Brand    : HAXOR PANEL TUNNELING
# Tagline  : DEKENG ANE BIAK BELITONG
# Source   : Original HAXOR wrapper untuk Ookla speedtest CLI
# ============================================================
#
# Deskripsi:
#   Wrapper menu untuk Ookla Speedtest CLI (command `speedtest`).
#   Memberi branding HAXOR + 7 opsi speedtest yang sering dipakai.
#
# Prasyarat:
#   - Paket `speedtest` (Ookla official CLI) sudah terinstall di VPS.
#     Cek: command -v speedtest
#     Install: https://www.speedtest.net/apps/cli
#
# Pemasangan:
#   wget -O /usr/bin/speedtest-haxor <RAW_URL>
#   chmod +x /usr/bin/speedtest-haxor
#
# ============================================================

# ---------- Palette 256-color modern HAXOR ----------
CYAN='\033[38;5;51m'      # Bright cyan - primary
TEAL='\033[38;5;38m'      # Teal - secondary
GREEN='\033[38;5;48m'     # Mint green - status OK
YELLOW='\033[38;5;227m'   # Soft yellow - menu numbers
ORANGE='\033[38;5;215m'   # Soft orange - warning
RED='\033[38;5;203m'      # Soft red - error
PINK='\033[38;5;213m'     # Soft pink - accent
WHITE='\033[38;5;255m'    # Off-white - text normal
GRAY='\033[38;5;245m'     # Light gray - subtle
DGRAY='\033[38;5;240m'    # Dark gray - border
NC='\033[0m'              # Reset
BG_CYAN='\e[48;5;30m'     # Dark cyan bg - header box
BG_TEAL='\e[48;5;23m'     # Dark teal bg - secondary

# ---------- Function: show_menu (re-entrant) ----------
show_menu() {
    clear
    echo
    echo -e "${BG_CYAN}${WHITE}================================================================${NC}"
    echo -e "${BG_CYAN}${WHITE}           SPEEDTEST MONITOR - HAXOR                            ${NC}"
    echo -e "${BG_CYAN}${WHITE}           DEKENG ANE BIAK BELITONG                               ${NC}"
    echo -e "${BG_CYAN}${WHITE}================================================================${NC}"
    echo -e "${DGRAY}----------------------------------------------------------------${NC}"
    echo -e "${YELLOW}  01${NC} ${WHITE}Speedtest Default         ${GRAY}(auto server)${NC}"
    echo -e "${YELLOW}  02${NC} ${WHITE}List Server Terdekat     ${GRAY}(speedtest -L)${NC}"
    echo -e "${YELLOW}  03${NC} ${WHITE}Speedtest Pilih Server   ${GRAY}(by server ID)${NC}"
    echo -e "${YELLOW}  04${NC} ${WHITE}Speedtest No Progress    ${GRAY}(-p no, utk log)${NC}"
    echo -e "${YELLOW}  05${NC} ${WHITE}Speedtest Verbose        ${GRAY}(-v, detail)${NC}"
    echo -e "${YELLOW}  06${NC} ${WHITE}Speedtest Help           ${GRAY}(-h)${NC}"
    echo -e "${YELLOW}  07${NC} ${WHITE}Speedtest Version        ${GRAY}(-V)${NC}"
    echo -e "${DGRAY}----------------------------------------------------------------${NC}"
    echo -e "${PINK}  0X${NC} ${WHITE}Kembali ke Menu Utama${NC}"
    echo -e "${DGRAY}----------------------------------------------------------------${NC}"
    echo
}

# ---------- Function: pause ----------
pause() {
    echo
    read -p "${GRAY}Press [Enter] to continue...${NC}"
}

# ---------- Function: run_speedtest ----------
# Arg 1: argumen tambahan untuk speedtest
# Arg 2 (opsional): label opsi yang sedang dijalankan
run_speedtest() {
    local args="$1"
    local label="${2:-Speedtest}"
    clear
    echo -e "${CYAN}[INFO]${NC} ${WHITE}Menjalankan ${label}...${NC}"
    echo -e "${DGRAY}----------------------------------------------------------------${NC}"
    echo
    # shellcheck disable=SC2086
    speedtest $args
    echo
    pause
    show_menu
    read -p "${GRAY}Pilih opsi [01-07 / 0X]: ${NC}" choice
    handle_choice "$choice"
}

# ---------- Function: handle_choice ----------
handle_choice() {
    local choice="$1"
    case "$choice" in
        01|1)
            run_speedtest "" "Speedtest Default"
            ;;
        02|2)
            run_speedtest "-L" "List Server Terdekat"
            ;;
        03|3)
            clear
            echo -e "${CYAN}[INFO]${NC} ${WHITE}Speedtest dengan Server ID${NC}"
            echo -e "${DGRAY}----------------------------------------------------------------${NC}"
            echo
            read -p "${YELLOW}Masukkan Server ID${NC} ${GRAY}(lihat dari opsi 02)${NC}: " server_id
            if [[ -z "$server_id" ]]; then
                echo
                echo -e "${RED}[ERROR]${NC} ${WHITE}Server ID tidak boleh kosong.${NC}"
                pause
                show_menu
                read -p "${GRAY}Pilih opsi [01-07 / 0X]: ${NC}" choice
                handle_choice "$choice"
                return
            fi
            echo
            echo -e "${CYAN}[INFO]${NC} ${WHITE}Menjalankan Speedtest ke Server ID: ${YELLOW}${server_id}${NC}"
            echo -e "${DGRAY}----------------------------------------------------------------${NC}"
            echo
            speedtest -s "$server_id"
            echo
            pause
            show_menu
            read -p "${GRAY}Pilih opsi [01-07 / 0X]: ${NC}" choice
            handle_choice "$choice"
            ;;
        04|4)
            run_speedtest "-p no" "Speedtest No Progress Bar"
            ;;
        05|5)
            run_speedtest "-v" "Speedtest Verbose"
            ;;
        06|6)
            run_speedtest "-h" "Speedtest Help"
            ;;
        07|7)
            run_speedtest "-V" "Speedtest Version"
            ;;
        0|00|x|X|0x|0X)
            clear
            menu
            ;;
        *)
            clear
            echo
            echo -e "${RED}[ERROR]${NC} ${WHITE}Opsi tidak dikenal: '${YELLOW}${choice}${NC}${WHITE}'.${NC}"
            echo -e "${GRAY}Silakan pilih 01-07 atau 0X untuk kembali.${NC}"
            pause
            show_menu
            read -p "${GRAY}Pilih opsi [01-07 / 0X]: ${NC}" choice
            handle_choice "$choice"
            ;;
    esac
}

# ---------- Main ----------
main() {
    # Validasi: cek command speedtest sudah terinstall
    if ! command -v speedtest &> /dev/null; then
        clear
        echo
        echo -e "${BG_CYAN}${WHITE}================================================================${NC}"
        echo -e "${BG_CYAN}${WHITE}           SPEEDTEST MONITOR - HAXOR                            ${NC}"
        echo -e "${BG_CYAN}${WHITE}           DEKENG ANE BIAK BELITONG                               ${NC}"
        echo -e "${BG_CYAN}${WHITE}================================================================${NC}"
        echo
        echo -e "${RED}[ERROR]${NC} ${WHITE}Command 'speedtest' tidak ditemukan!${NC}"
        echo
        echo -e "${GRAY}Ookla Speedtest CLI belum terinstall di VPS ini.${NC}"
        echo -e "${GRAY}Silakan install terlebih dahulu:${NC}"
        echo
        echo -e "${TEAL}  Panduan resmi:${NC} ${WHITE}https://www.speedtest.net/apps/cli${NC}"
        echo
        echo -e "${GRAY}Ubuntu/Debian cara cepat:${NC}"
        echo -e "${TEAL}  curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash${NC}"
        echo -e "${TEAL}  apt install speedtest${NC}"
        echo
        read -p "${GRAY}Press [Enter] to return to menu...${NC}"
        menu
        return
    fi

    # Tampilkan menu + baca input pertama
    show_menu
    read -p "${GRAY}Pilih opsi [01-07 / 0X]: ${NC}" choice
    handle_choice "$choice"
}

# ---------- Entry point ----------
main
