#!/bin/bash
#
# ============================================================
# Script   : menu.sh
# Version  : 3.0 (Sesi 2.6 — v18: Integrate pantau + tendang-safe + bw-user)
# Repo     : panggongfilm/cfnfree
# Path     : /update/menu.sh (di repo) → /usr/bin/menu (di VPS)
# Brand    : HAXOR PANEL TUNNELING
# Tagline  : DEKENG ANE BIAK BELITONG
# Source   : Redesign dari menu.sh v2.0-FIX2 (panggongfilm/cfnfree)
# ============================================================
#
# Deskripsi:
#   Menu utama HAXOR Panel — 14 item layout 2-kolom
#   (SSH MANAGEMENT 6 item | MONITORING & TOOLS 8 item).
#   Re-entrant via while-loop. Integrate:
#     - 6 SSH management (maddssh, sslh-fix-reboot, mbackup, msetting,
#       start-menu, reboot_vps dengan confirmation)
#     - 3 utility Fase 1 (bw, speedtest-haxor, clearlog, clearcache)
#     - 3 script Fase 2 (pantau, tendang-safe, bw-user)
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
#   - Layout 2-kolom 6+8 (BUKAN 3-kolom) — anti susah dibaca di HP
#     (keputusan user v18)
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
GRAY=$'\033[38;5;245m'     # Light gray - subtle
DGRAY=$'\033[38;5;240m'    # Dark gray - border
NC=$'\033[0m'              # Reset
BG_CYAN=$'\033[48;5;30m'   # Dark cyan bg - header box
BG_TEAL=$'\033[48;5;23m'   # Dark teal bg - secondary

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

        # ─── Body: 2-kolom (SSH MANAGEMENT 6 | MONITORING & TOOLS 8) ───
        # printf %-Ns untuk auto-padding (ANSI codes TIDAK mempengaruhi width — Lesson v6 FIX1)
        # Kolom kiri = 6 item (01-06), kolom kanan = 8 item (07-14)
        # Baris 7-8: kolom kiri kosong (placeholder whitespace) supaya border konsisten
        echo -e "${DGRAY}┌─${NC} ${CYAN}SSH MANAGEMENT${NC} ${DGRAY}────────────────┬─${NC} ${TEAL}MONITORING & TOOLS${NC} ${DGRAY}──────────┐${NC}"
        printf "${DGRAY}│${NC}  ${YELLOW}[%s]${NC} %-22s ${DGRAY}│${NC}  ${YELLOW}[%s]${NC} %-22s ${DGRAY}│${NC}\n" "01" "SSH Account Menu"     "07" "Cek RAM/CPU (htop)"
        printf "${DGRAY}│${NC}  ${YELLOW}[%s]${NC} %-22s ${DGRAY}│${NC}  ${YELLOW}[%s]${NC} %-22s ${DGRAY}│${NC}\n" "02" "Restart Service"      "08" "Bandwidth VPS (bw)"
        printf "${DGRAY}│${NC}  ${YELLOW}[%s]${NC} %-22s ${DGRAY}│${NC}  ${YELLOW}[%s]${NC} %-22s ${DGRAY}│${NC}\n" "03" "Backup & Restore"     "09" "Speedtest VPS"
        printf "${DGRAY}│${NC}  ${YELLOW}[%s]${NC} %-22s ${DGRAY}│${NC}  ${YELLOW}[%s]${NC} %-22s ${DGRAY}│${NC}\n" "04" "Settings"             "10" "Bandwidth Per-User"
        printf "${DGRAY}│${NC}  ${YELLOW}[%s]${NC} %-22s ${DGRAY}│${NC}  ${YELLOW}[%s]${NC} %-22s ${DGRAY}│${NC}\n" "05" "Cek Service"          "11" "Pantau User"
        printf "${DGRAY}│${NC}  ${YELLOW}[%s]${NC} %-22s ${DGRAY}│${NC}  ${YELLOW}[%s]${NC} %-22s ${DGRAY}│${NC}\n" "06" "Reboot VPS"           "12" "Tendang Aman"
        printf "${DGRAY}│${NC}  ${YELLOW}%-2s${NC}  %-22s ${DGRAY}│${NC}  ${YELLOW}[%s]${NC} %-22s ${DGRAY}│${NC}\n" "  " ""                     "13" "Clear Log"
        printf "${DGRAY}│${NC}  ${YELLOW}%-2s${NC}  %-22s ${DGRAY}│${NC}  ${YELLOW}[%s]${NC} %-22s ${DGRAY}│${NC}\n" "  " ""                     "14" "Clear Cache"
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
        read -p "${YELLOW}  Pilih opsi [01-14 / 0X untuk keluar]: ${NC}" opt
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
            htop
            ;;
        08|8)
            bw
            ;;
        09|9)
            speedtest-haxor
            ;;
        10)
            bw-user
            ;;
        11)
            clear
            pantau
            echo
            read -p "${GRAY}  Tekan enter untuk kembali ke menu utama...${NC}" dummy
            ;;
        12)
            clear
            tendang-safe
            echo
            read -p "${GRAY}  Tekan enter untuk kembali ke menu utama...${NC}" dummy
            ;;
        13)
            clearlog
            ;;
        14)
            clearcache
            ;;
        0|00|x|X|0x|0X)
            exit_script
            ;;
        *)
            echo
            echo -e "  ${RED}[ERROR]${NC} ${WHITE}Opsi tidak dikenal: '${YELLOW}${choice}${NC}${WHITE}'.${NC}"
            echo -e "  ${GRAY}Silakan pilih 01-14 atau 0X untuk keluar.${NC}"
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
