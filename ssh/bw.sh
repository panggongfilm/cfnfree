#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# Script  : bw.sh - Bandwidth Monitor Submenu
# Brand   : HAXOR PANEL TUNNELING
# Tagline : DEKENG ANE BIAK BELITONG
# Source  : Adaptasi dari script open-source (Ceceppurwana)
# Repo    : panggongfilm/cfnfree
# Path    : /ssh/bw.sh  →  diinstall ke /usr/bin/bw
# License : FREE (no IP license check)
# ═══════════════════════════════════════════════════════════════

# ─── MODERN COLOR PALETTE (256-color) ───
CYAN='\033[38;5;51m'      # Bright cyan - primary accent
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

# ─── FUNCTION: Tampilkan menu utama bw ───
show_menu() {
    clear
    echo -e ""
    echo -e " ${DGRAY}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
    echo -e " ${DGRAY}┃${BG_CYAN}${WHITE}           » BANDWIDTH MONITOR - HAXOR «            ${NC}${DGRAY}┃${NC}"
    echo -e " ${DGRAY}┃${TEAL}            DEKENG ANE BIAK BELITONG              ${NC}${DGRAY}┃${NC}"
    echo -e " ${DGRAY}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
    echo -e " ${DGRAY}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
    echo -e " ${DGRAY}┃${NC}   ${GRAY}[${YELLOW}01${GRAY}]${WHITE} Total Bandwidth Server Tersisa         ${DGRAY}┃${NC}"
    echo -e " ${DGRAY}┃${NC}   ${GRAY}[${YELLOW}02${GRAY}]${WHITE} Tabel Penggunaan Setiap 5 Menit         ${DGRAY}┃${NC}"
    echo -e " ${DGRAY}┃${NC}   ${GRAY}[${YELLOW}03${GRAY}]${WHITE} Tabel Penggunaan Setiap Jam             ${DGRAY}┃${NC}"
    echo -e " ${DGRAY}┃${NC}   ${GRAY}[${YELLOW}04${GRAY}]${WHITE} Tabel Penggunaan Setiap Hari             ${DGRAY}┃${NC}"
    echo -e " ${DGRAY}┃${NC}   ${GRAY}[${YELLOW}05${GRAY}]${WHITE} Tabel Penggunaan Setiap Bulan            ${DGRAY}┃${NC}"
    echo -e " ${DGRAY}┃${NC}   ${GRAY}[${YELLOW}06${GRAY}]${WHITE} Tabel Penggunaan Setiap Tahun            ${DGRAY}┃${NC}"
    echo -e " ${DGRAY}┃${NC}   ${GRAY}[${YELLOW}07${GRAY}]${WHITE} Tabel Penggunaan Tertinggi (Top 10)      ${DGRAY}┃${NC}"
    echo -e " ${DGRAY}┃${NC}   ${GRAY}[${YELLOW}08${GRAY}]${WHITE} Statistik Penggunaan Setiap Jam (Grafik) ${DGRAY}┃${NC}"
    echo -e " ${DGRAY}┃${NC}   ${GRAY}[${YELLOW}09${GRAY}]${WHITE} Live Bandwidth Saat Ini                 ${DGRAY}┃${NC}"
    echo -e " ${DGRAY}┃${NC}   ${GRAY}[${YELLOW}10${GRAY}]${WHITE} Live Trafik Rate [5 detik sample]       ${DGRAY}┃${NC}"
    echo -e " ${DGRAY}┃${NC}   ${GRAY}[${RED}0X${GRAY}]${ORANGE} Kembali ke Menu Utama                  ${DGRAY}┃${NC}"
    echo -e " ${DGRAY}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
    echo -e ""
    read -p "  Pilih opsi [ 1-10 / 0X ] » " opt

    case $opt in
        1)
            clear
            echo -e "${DGRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${BG_TEAL}${WHITE}  » TOTAL BANDWIDTH SERVER TERSISA «        ${NC}"
            echo -e "${DGRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e ""
            vnstat
            echo -e ""
            echo -e "${DGRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e ""
            read -p "Tekan enter untuk kembali ke menu bw"
            show_menu
            ;;
        2)
            clear
            echo -e "${DGRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${BG_TEAL}${WHITE}  » BANDWIDTH SETIAP 5 MENIT «              ${NC}"
            echo -e "${DGRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e ""
            vnstat -5
            echo -e ""
            echo -e "${DGRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e ""
            read -p "Tekan enter untuk kembali ke menu bw"
            show_menu
            ;;
        3)
            clear
            echo -e "${DGRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${BG_TEAL}${WHITE}  » BANDWIDTH SETIAP JAM «                  ${NC}"
            echo -e "${DGRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e ""
            vnstat -h
            echo -e ""
            echo -e "${DGRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e ""
            read -p "Tekan enter untuk kembali ke menu bw"
            show_menu
            ;;
        4)
            clear
            echo -e "${DGRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${BG_TEAL}${WHITE}  » BANDWIDTH SETIAP HARI «                 ${NC}"
            echo -e "${DGRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e ""
            vnstat -d
            echo -e ""
            echo -e "${DGRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e ""
            read -p "Tekan enter untuk kembali ke menu bw"
            show_menu
            ;;
        5)
            clear
            echo -e "${DGRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${BG_TEAL}${WHITE}  » BANDWIDTH SETIAP BULAN «                ${NC}"
            echo -e "${DGRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e ""
            vnstat -m
            echo -e ""
            echo -e "${DGRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e ""
            read -p "Tekan enter untuk kembali ke menu bw"
            show_menu
            ;;
        6)
            clear
            echo -e "${DGRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${BG_TEAL}${WHITE}  » BANDWIDTH SETIAP TAHUN «                ${NC}"
            echo -e "${DGRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e ""
            vnstat -y
            echo -e ""
            echo -e "${DGRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e ""
            read -p "Tekan enter untuk kembali ke menu bw"
            show_menu
            ;;
        7)
            clear
            echo -e "${DGRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${BG_TEAL}${WHITE}  » TOP 10 BANDWIDTH TERTINGGI «            ${NC}"
            echo -e "${DGRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e ""
            vnstat -t
            echo -e ""
            echo -e "${DGRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e ""
            read -p "Tekan enter untuk kembali ke menu bw"
            show_menu
            ;;
        8)
            clear
            echo -e "${DGRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${BG_TEAL}${WHITE}  » STATISTIK BANDWIDTH PER JAM (GRAFIK) «  ${NC}"
            echo -e "${DGRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e ""
            vnstat -hg
            echo -e ""
            echo -e "${DGRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e ""
            read -p "Tekan enter untuk kembali ke menu bw"
            show_menu
            ;;
        9)
            clear
            echo -e "${DGRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${BG_TEAL}${WHITE}  » LIVE BANDWIDTH SAAT INI «               ${NC}"
            echo -e "${DGRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${YELLOW}Tekan [ Ctrl+C ] untuk keluar${NC}"
            echo -e ""
            vnstat -l
            echo -e ""
            echo -e "${DGRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e ""
            read -p "Tekan enter untuk kembali ke menu bw"
            show_menu
            ;;
        10)
            clear
            echo -e "${DGRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${BG_TEAL}${WHITE}  » LIVE TRAFIK RATE [5 DETIK SAMPLE] «     ${NC}"
            echo -e "${DGRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e ""
            vnstat -tr
            echo -e ""
            echo -e "${DGRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e ""
            read -p "Tekan enter untuk kembali ke menu bw"
            show_menu
            ;;
        0 | 00 | x | X | 0x | 0X)
            clear
            menu
            ;;
        *)
            echo -e ""
            echo -e "  ${RED}Input tidak dikenal!${NC} ${YELLOW}Coba lagi...${NC}"
            sleep 1
            show_menu
            ;;
    esac
}

# ─── ENTRY POINT ───
# Cek apakah vnstat terpasang
if ! command -v vnstat &> /dev/null; then
    echo -e "${RED}[ERROR]${NC} vnstat belum terinstall."
    echo -e "${YELLOW}Install dengan:${NC} apt -y install vnstat"
    echo -e ""
    read -p "Tekan enter untuk kembali ke menu"
    menu
    exit 1
fi

show_menu
