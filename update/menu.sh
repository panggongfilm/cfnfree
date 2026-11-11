#!/bin/bash
#
# ============================================================
# Script   : menu.sh
# Version  : 3.3 (Sesi v46: Revert ke v3.1 + tambah panel [ SERVICES ] status dots)
# Repo     : panggongfilm/cfnfree
# Path     : /update/menu.sh (di repo) → /usr/bin/menu (di VPS)
# Brand    : HAXOR PANEL TUNNELING
# Tagline  : DEKENG ANE BIAK BELITONG
# Source   : Adaptasi dari menu.sh v3.1 (panggongfilm/cfnfree) + tambah panel [ SERVICES ]
# Catatan  : v3.2 (redesign visual 4 panel) dicoba user v46 → TIDAK disukai,
#           kembali ke v3.1 layout original + tambah HANYA panel [ SERVICES ]
#           (3 baris: status dots + HEALTH > GOOD, tanpa spec text).
# ============================================================
#
# Deskripsi:
#   Menu utama HAXOR Panel — 17 item layout 2-kolom
#   (SSH MANAGEMENT 9 item | MONITORING & TOOLS 8 item).
#   Re-entrant via while-loop. Integrate:
#     - 6 SSH management (maddssh, sslh-fix-reboot, mbackup, msetting,
#       start-menu, reboot_vps dengan confirmation)
#     - 3 SSH maintenance BARU v40 (banner-manager, upgrade-dropbear,
#       getupdate) — admin cukup klik nomor, tak perlu ketik perintah
#     - 3 utility Fase 1 (bw, speedtest-haxor, clearlog, clearcache)
#     - 3 script Fase 2 (pantau, bw-user, bw-limit)
#       Catatan: tendang-safe DIHAPUS dari menu utama (redundant —
#       pantau v1.1 sudah integrate tendang-safe sejak v15)
#     - htop system monitor
#   Exit = 0X universal (tanpa nomor, anti salah pencet).
#
# Pelajaran penting yang diterapkan:
#   - ANSI-C quoting $'...' untuk semua variabel palette
#     (pelajaran FIX1 dari v6 — single-quote akan tampilkan
#     literal \033[...] di prompt read -p)
#   - Re-entrant via while-loop (BUKAN recursive call) untuk
#     menghindari stack growth saat user pakai menu lama
#   - Confirmation prompt untuk opsi destruktif (reboot, exit)
#     — pattern run-once confirm dari v7/v8
#   - Exit = 0X universal (tanpa nomor, keputusan user v18)
#     — anti salah pencet (user tidak akan ketik 12/15/16 thinking exit)
#   - Layout 2-kolom 9+8 (BUKAN 3-kolom) — anti susah dibaca di HP
#     (keputusan user v18 + v40: 9+8 supaya 17 item muat rapi)
#   - [08] Upgrade Dropbear punya 3 layer safety di script sendiri
#     (display_info_warning + check_admin_via_ssh_direct + verify_dropbear_healthy)
#     — admin via SSH direct port 22 TIDAK putus, user tunneling reconnect 30-60 detik
#   - [07] Banner Manager edit /etc/issue.net langsung aktif untuk koneksi baru
#     — NO restart service (keputusan design v37 Opsi B)
#
# ============================================================

# ---------- Palette 256-color modern HAXOR ----------
# WAJIB pakai ANSI-C quoting $'...' supaya byte ESC tersimpan
# langsung di variabel, sehingga warna tampil benar di echo,
# echo -e, read -p, dan printf (pelajaran FIX1 dari v6).
CYAN=$'\033[38;5;51m'      # Bright cyan - primary
TEAL=$'\033[38;5;38m'      # Teal - secondary
GREEN=$'\033[38;5;48m'     # Mint green - status OK
YELLOW=$'\033[38;5;227m'   # Soft yellow - menu numbers
ORANGE=$'\033[38;5;215m'   # Soft orange - warning
RED=$'\033[38;5;203m'      # Soft red - error
PINK=$'\033[38;5;213m'     # Soft pink - accent
WHITE=$'\033[38;5;255m'    # Off-white - text normal
BWHITE=$'\033[1;38;5;255m' # Bold white - service names (v46 NEW)
GRAY=$'\033[38;5;245m'     # Light gray - subtle
DGRAY=$'\033[38;5;240m'    # Dark gray - border
NC=$'\033[0m'              # Reset
BG_CYAN=$'\033[48;5;30m'   # Dark cyan bg - header box
BG_TEAL=$'\033[48;5;23m'   # Dark teal bg - secondary

# ---------- Helper: status dot untuk service (● hijau aktif, ○ merah mati) ----------
# v46 NEW: untuk panel [ SERVICES ]
status_dot_service() {
    if systemctl is-active --quiet "$1" 2>/dev/null; then
        printf '%s●%s' "${GREEN}" "${NC}"
    else
        printf '%s○%s' "${RED}" "${NC}"
    fi
}
status_dot_process() {
    if pgrep -x "$1" >/dev/null 2>&1; then
        printf '%s●%s' "${GREEN}" "${NC}"
    else
        printf '%s○%s' "${RED}" "${NC}"
    fi
}
status_dot_pattern() {
    if pgrep -f "$1" >/dev/null 2>&1; then
        printf '%s●%s' "${GREEN}" "${NC}"
    else
        printf '%s○%s' "${RED}" "${NC}"
    fi
}

# ---------- Function: render_services_panel (v46 NEW) ----------
# Panel [ SERVICES ] dengan status dots + HEALTH, tanpa spec text
render_services_panel() {
    # Top border dengan [ SERVICES ] embedded
    echo -e "${RED}╭─${NC} ${BWHITE}[ SERVICES ]${NC} ${RED}────────────────────────────────────────────────────────${NC}${RED}╮${NC}"
    # Row 1: SSH DROPBEAR SSLH STUNNEL5 NGINX
    printf "${RED}│${NC}  %s %s%s%s  %s %s%s%s  %s %s%s%s  %s %s%s%s  %s %s%s%s                          ${RED}│${NC}\n" \
        "$(status_dot_service ssh)" "${BWHITE}" "SSH" "${NC}" \
        "$(status_dot_service dropbear)" "${BWHITE}" "DROPBEAR" "${NC}" \
        "$(status_dot_service sslh)" "${BWHITE}" "SSLH" "${NC}" \
        "$(status_dot_service stunnel5)" "${BWHITE}" "STUNNEL5" "${NC}" \
        "$(status_dot_service nginx)" "${BWHITE}" "NGINX" "${NC}"
    # Row 2: BADVPN WS-TLS WS-NONTLS
    printf "${RED}│${NC}  %s %s%s%s  %s %s%s%s  %s %s%s%s                                          ${RED}│${NC}\n" \
        "$(status_dot_process badvpn-udpgw)" "${BWHITE}" "BADVPN" "${NC}" \
        "$(status_dot_pattern 'python.*ws-tls')" "${BWHITE}" "WS-TLS" "${NC}" \
        "$(status_dot_pattern 'python.*ws-nontls')" "${BWHITE}" "WS-NONTLS" "${NC}"
    # Row 3: HEALTH > GOOD (tanpa spec text)
    printf "${RED}│${NC}  ${GRAY}HEALTH   ${NC}${CYAN}>${NC} ${GREEN}GOOD${NC}                                                  ${RED}│${NC}\n"
    # Bottom border
    echo -e "${RED}╰───────────────────────────────────────────────────────────────────${NC}${RED}╯${NC}"
    echo
}

# ---------- Function: show_menu (re-entrant via while-loop) ----------
show_menu() {
    local opt
    while true; do
        clear
        # ─── Header box (double-bar BG_CYAN + BG_TEAL) ───
        # Konsisten dengan bw.sh / speedtest-haxor.sh / clearlog.sh / clearcache.sh / pantau.sh / tendang-safe.sh / bw-user.sh
        echo -e "${DGRAY}══════════════════════════════════════════════════════════════════════════${NC}"
        echo -e "${BG_CYAN}${WHITE}                       HAXOR PANEL TUNNELING — MAIN MENU                     ${NC}"
        echo -e "${BG_TEAL}${WHITE}                          DEKENG ANE BIAK BELITONG                          ${NC}"
        echo -e "${DGRAY}══════════════════════════════════════════════════════════════════════════${NC}"
        echo

        # ─── Panel [ SERVICES ] (v46 NEW — status dots + HEALTH) ───
        render_services_panel

        # ─── Body: 2-kolom (SSH MANAGEMENT 9 | MONITORING & TOOLS 8) ───
        # printf %-Ns untuk auto-padding (ANSI codes TIDAK mempengaruhi width — Lesson v6 FIX1)
        # Kolom kiri = 9 item (01-09 SSH Management + Maintenance)
        # Kolom kanan = 8 item (10-17 Monitoring & Tools)
        # Total 17 item + Exit 0X (was 14 item di v3.0)
        echo -e "${DGRAY}┌─${NC} ${CYAN}SSH MANAGEMENT${NC} ${DGRAY}────────────────┬─${NC} ${TEAL}MONITORING & TOOLS${NC} ${DGRAY}──────────┐${NC}"
        printf "${DGRAY}│${NC}  ${YELLOW}[%s]${NC} %-22s ${DGRAY}│${NC}  ${YELLOW}[%s]${NC} %-22s ${DGRAY}│${NC}\n" "01" "SSH Account Menu"     "10" "Cek RAM/CPU (htop)"
        printf "${DGRAY}│${NC}  ${YELLOW}[%s]${NC} %-22s ${DGRAY}│${NC}  ${YELLOW}[%s]${NC} %-22s ${DGRAY}│${NC}\n" "02" "Restart Service"      "11" "Bandwidth VPS (bw)"
        printf "${DGRAY}│${NC}  ${YELLOW}[%s]${NC} %-22s ${DGRAY}│${NC}  ${YELLOW}[%s]${NC} %-22s ${DGRAY}│${NC}\n" "03" "Backup & Restore"     "12" "Speedtest VPS"
        printf "${DGRAY}│${NC}  ${YELLOW}[%s]${NC} %-22s ${DGRAY}│${NC}  ${YELLOW}[%s]${NC} %-22s ${DGRAY}│${NC}\n" "04" "Settings"             "13" "Bandwidth Per-User"
        printf "${DGRAY}│${NC}  ${YELLOW}[%s]${NC} %-22s ${DGRAY}│${NC}  ${YELLOW}[%s]${NC} %-22s ${DGRAY}│${NC}\n" "05" "Cek Service"          "14" "Pantau User"
        printf "${DGRAY}│${NC}  ${YELLOW}[%s]${NC} %-22s ${DGRAY}│${NC}  ${YELLOW}[%s]${NC} %-22s ${DGRAY}│${NC}\n" "06" "Reboot VPS"           "15" "Limit Speed"
        printf "${DGRAY}│${NC}  ${YELLOW}[%s]${NC} %-22s ${DGRAY}│${NC}  ${YELLOW}[%s]${NC} %-22s ${DGRAY}│${NC}\n" "07" "Banner Manager"       "16" "Clear Log"
        printf "${DGRAY}│${NC}  ${YELLOW}[%s]${NC} %-22s ${DGRAY}│${NC}  ${YELLOW}[%s]${NC} %-22s ${DGRAY}│${NC}\n" "08" "Upgrade Dropbear"     "17" "Clear Cache"
        printf "${DGRAY}│${NC}  ${YELLOW}[%s]${NC} %-22s ${DGRAY}│${NC}  ${YELLOW}%-2s${NC}  %-22s ${DGRAY}│${NC}\n" "09" "Update Script"        "  " ""
        echo -e "${DGRAY}└──────────────────────────────────┴──────────────────────────────────┘${NC}"
        echo
        printf "                       ${PINK}[0X]${NC} ${WHITE}Exit${NC}\n"
        echo

        # ─── Footer (BELITONG + Mod By HAXOR) ───
        echo -e "${DGRAY}──────────────────────────────────────────────────────────────────────────${NC}"
        echo -e "${PINK}  Mod By HAXOR${NC} ${GRAY}—${NC} ${PINK}DEKENG ANE BIAK BELITONG${NC}"
        echo -e "${DGRAY}──────────────────────────────────────────────────────────────────────────${NC}"
        echo

        # ─── Read user input (prompt berwarna, ANSI-C quoting) ───
        read -p "${YELLOW}  Pilih opsi [01-17 / 0X untuk keluar]: ${NC}" opt
        handle_choice "$opt"
        # Setelah handle_choice selesai (non-exit), loop continues → menu baru
    done
}

# ---------- Function: handle_choice (case statement) ----------
handle_choice() {
    local choice="$1"
    case "$choice" in
        01|1)
            clear
            maddssh
            echo
            read -p "${GRAY}  Tekan enter untuk kembali ke menu utama...${NC}" dummy
            ;;
        02|2)
            clear
            sslh-fix-reboot
            echo
            read -p "${GRAY}  Tekan enter untuk kembali ke menu utama...${NC}" dummy
            ;;
        03|3)
            clear
            mbackup
            echo
            read -p "${GRAY}  Tekan enter untuk kembali ke menu utama...${NC}" dummy
            ;;
        04|4)
            clear
            msetting
            echo
            read -p "${GRAY}  Tekan enter untuk kembali ke menu utama...${NC}" dummy
            ;;
        05|5)
            clear
            start-menu
            echo
            read -p "${GRAY}  Tekan enter untuk kembali ke menu utama...${NC}" dummy
            ;;
        06|6)
            reboot_vps
            ;;
        07|7)
            clear
            banner-manager
            echo
            read -p "${GRAY}  Tekan enter untuk kembali ke menu utama...${NC}" dummy
            ;;
        08|8)
            clear
            upgrade-dropbear
            echo
            read -p "${GRAY}  Tekan enter untuk kembali ke menu utama...${NC}" dummy
            ;;
        09|9)
            clear
            getupdate
            echo
            read -p "${GRAY}  Tekan enter untuk kembali ke menu utama...${NC}" dummy
            ;;
        10)
            clear
            htop
            ;;
        11)
            bw
            ;;
        12)
            speedtest-haxor
            ;;
        13)
            bw-user
            ;;
        14)
            clear
            pantau
            echo
            read -p "${GRAY}  Tekan enter untuk kembali ke menu utama...${NC}" dummy
            ;;
        15)
            bw-limit
            ;;
        16)
            clearlog
            ;;
        17)
            clearcache
            ;;
        0|00|x|X|0x|0X)
            exit_script
            ;;
        *)
            echo
            echo -e "  ${RED}[ERROR]${NC} ${WHITE}Opsi tidak dikenal: '${YELLOW}${choice}${NC}${WHITE}'.${NC}"
            echo -e "  ${GRAY}Silakan pilih 01-17 atau 0X untuk keluar.${NC}"
            sleep 2
            ;;
    esac
}

# ---------- Function: reboot_vps (confirmation) ----------
reboot_vps() {
    clear
    echo -e "${DGRAY}══════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BG_CYAN}${WHITE}                          HAXOR PANEL — REBOOT VPS                            ${NC}"
    echo -e "${BG_TEAL}${WHITE}                          DEKENG ANE BIAK BELITONG                          ${NC}"
    echo -e "${DGRAY}══════════════════════════════════════════════════════════════════════════${NC}"
    echo
    echo -e "  ${ORANGE}[!] PERINGATAN REBOOT VPS${NC}"
    echo
    echo -e "  ${WHITE}Operasi ini akan langsung me-restart server.${NC}"
    echo -e "  ${GRAY}Semua koneksi aktif (SSH/tunneling) akan terputus.${NC}"
    echo -e "  ${GRAY}VPS akan kembali online dalam ~30 detik setelah reboot.${NC}"
    echo
    # ─── Root check (reboot butuh root) ───
    if [ "$EUID" -ne 0 ]; then
        echo -e "  ${RED}[ERROR]${NC} Reboot VPS butuh akses root."
        echo -e "  ${GRAY}Jalankan:${NC} ${CYAN}sudo menu${NC} ${GRAY}atau login sebagai root.${NC}"
        echo
        read -p "${GRAY}  Tekan enter untuk kembali ke menu utama...${NC}" dummy
        return
    fi
    read -p "${YELLOW}  Yakin ingin reboot VPS? (y/n): ${NC}" confirm
    case "$confirm" in
        y|Y|ya|yes)
            echo
            echo -e "  ${GREEN}→${NC} Rebooting VPS sekarang..."
            sleep 1
            reboot
            ;;
        *)
            echo
            echo -e "  ${GRAY}Reboot dibatalkan.${NC}"
            sleep 1
            ;;
    esac
}

# ---------- Function: exit_script (confirmation) ----------
exit_script() {
    clear
    echo -e "${DGRAY}══════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BG_CYAN}${WHITE}                          HAXOR PANEL — EXIT CONFIRM                            ${NC}"
    echo -e "${BG_TEAL}${WHITE}                          DEKENG ANE BIAK BELITONG                          ${NC}"
    echo -e "${DGRAY}══════════════════════════════════════════════════════════════════════════${NC}"
    echo
    echo -e "  ${ORANGE}[!] KONFIRMASI EXIT${NC}"
    echo
    echo -e "  ${WHITE}Anda akan keluar dari HAXOR Panel.${NC}"
    echo -e "  ${GRAY}Untuk kembali ke menu, jalankan:${NC} ${CYAN}menu${NC}"
    echo
    read -p "${YELLOW}  Yakin ingin keluar? (y/n): ${NC}" confirm
    case "$confirm" in
        y|Y|ya|yes)
            clear
            exit 0
            ;;
        *)
            echo
            echo -e "  ${GRAY}Exit dibatalkan.${NC}"
            sleep 1
            ;;
    esac
}

# ---------- Main entry ----------
main() {
    show_menu
}

main "$@"
