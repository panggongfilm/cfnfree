#!/bin/bash
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Script    : clearcache.sh
# Versi     : v1.0
# Lokasi    : /ssh/clearcache.sh (repo) → /usr/bin/clearcache (VPS)
# Fungsi    : Clear kernel cache (pagecache + dentries + inodes) + apt cache
# Pattern   : Run-once dengan confirmation prompt (1 aksi)
# Branding  : HAXOR Panel Tunneling + tagline "DEKENG ANE BIAK BELITONG"
# Source    : Adaptasi dari script open-source (Ceceppurwana)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ─── PALETTE 256-COLOR (FINAL v6-FIX) ──────────────────────────
# WAJIB pakai ANSI-C quoting $'...' supaya byte ESC tersimpan langsung di
# variabel — sehingga warna tampil benar di echo, echo -e, read -p, dan printf.
# (Pelajaran dari bug FIX1 Sesi 1.2: single-quote '\033[...]' hanya simpan literal)
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

# ─── HEADER BOX ────────────────────────────────────────────────
show_header() {
    clear
    echo -e "${DGRAY}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${DGRAY}║${BG_CYAN}${WHITE}  CLEAR CACHE UTILITY - HAXOR                                       ${NC}${DGRAY}║${NC}"
    echo -e "${DGRAY}║${BG_TEAL}${YELLOW}  DEKENG ANE BIAK BELITONG                                          ${NC}${DGRAY}║${NC}"
    echo -e "${DGRAY}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ─── PAUSE HELPER ──────────────────────────────────────────────
pause() {
    echo ""
    echo -e "${GRAY}Tekan enter untuk kembali ke menu utama...${NC}"
    read -r dummy
    menu
}

# ─── MEMORY INFO HELPERS ───────────────────────────────────────
# Parse /proc/meminfo untuk dapatkan nilai dalam KB
get_mem_kb() {
    # $1 = key dengan colon (e.g. "Cached:", "Buffers:", "MemFree:")
    awk -v key="$1" '$1==key {print $2; exit}' /proc/meminfo 2>/dev/null
}

# Format KB → human-readable (MB / GB)
format_kb() {
    local kb="${1:-0}"
    if [ "$kb" -ge 1048576 ] 2>/dev/null; then
        awk -v k="$kb" 'BEGIN{printf "%.2f GB", k/1048576}'
    elif [ "$kb" -ge 1024 ] 2>/dev/null; then
        awk -v k="$kb" 'BEGIN{printf "%.2f MB", k/1024}'
    else
        echo "${kb} KB"
    fi
}

# ─── MAIN ──────────────────────────────────────────────────────
main() {
    show_header

    # Validasi 1: cek root (drop_caches butuh root)
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[ERROR]${NC} ${WHITE}Script ini harus dijalankan sebagai root!${NC}"
        echo -e "${GRAY}Coba: sudo clearcache  atau  login sebagai root dulu.${NC}"
        pause
        return 1
    fi

    # Validasi 2: cek /proc/sys/vm/drop_caches tersedia (Linux only)
    if [ ! -w /proc/sys/vm/drop_caches ]; then
        echo -e "${RED}[ERROR]${NC} ${WHITE}/proc/sys/vm/drop_caches tidak tersedia atau tidak writable.${NC}"
        echo -e "${GRAY}Script ini hanya jalan di Linux kernel (sebagai root).${NC}"
        pause
        return 1
    fi

    # Validasi 3: cek command apt (untuk apt clean step)
    local apt_available="yes"
    if ! command -v apt >/dev/null 2>&1; then
        apt_available="no"
        echo -e "${ORANGE}[WARNING]${NC} ${WHITE}Command 'apt' tidak ditemukan.${NC}"
        echo -e "${GRAY}Kernel cache tetap akan di-clear, apt cache di-skip.${NC}"
        echo ""
    fi

    # Info ringkas
    echo -e "${CYAN}[*]${NC} ${WHITE}Fungsi:${NC} ${GRAY}Clear kernel cache + apt cache${NC}"
    echo -e "${CYAN}[*]${NC} ${WHITE}Target:${NC} ${GRAY}pagecache + dentries + inodes + apt archives${NC}"
    echo ""

    # Preview memory sebelum clear
    local cached_before=$(get_mem_kb "Cached:")
    local buffers_before=$(get_mem_kb "Buffers:")
    local memfree_before=$(get_mem_kb "MemFree:")

    echo -e "${TEAL}[i]${NC} ${WHITE}Status memory sebelum clear:${NC}"
    echo -e "    ${GRAY}Cached  : ${YELLOW}$(format_kb "$cached_before")${NC}"
    echo -e "    ${GRAY}Buffers : ${YELLOW}$(format_kb "$buffers_before")${NC}"
    echo -e "    ${GRAY}MemFree : ${YELLOW}$(format_kb "$memfree_before")${NC}"
    echo ""

    # Warning + confirmation
    echo -e "${ORANGE}[!]${NC} ${YELLOW}PERINGATAN:${NC} ${WHITE}Tindakan ini akan:${NC}"
    echo -e "    ${GRAY}1. Sync filesystem (flush dirty pages ke disk)${NC}"
    echo -e "    ${GRAY}2. Drop kernel caches (level 3: pagecache + dentries + inodes)${NC}"
    echo -e "    ${GRAY}3. Clean apt cache (/var/cache/apt/archives/)${NC}"
    echo -e "${GRAY}Sistem akan rebuild cache otomatis saat dibutuhkan.${NC}"
    echo -e "${GRAY}Tindakan AMAN — tidak menghapus data user.${NC}"
    echo ""

    # Confirmation prompt (P9 test point #1)
    read -p "${YELLOW}Yakin ingin clear cache? (y/n): ${NC}" confirm
    echo ""

    case "$confirm" in
        y|Y|ya|YA|yes|YES|Yes)
            # Lanjut clear
            ;;
        *)
            echo -e "${RED}✗${NC} ${WHITE}Operasi dibatalkan.${NC}"
            echo -e "${GRAY}Tidak ada cache yang di-clear.${NC}"
            pause
            return 0
            ;;
    esac

    echo -e "${CYAN}[*]${NC} ${WHITE}Memulai clear cache...${NC}"
    echo ""

    # Step 1: sync filesystem (best practice sebelum drop_caches,
    # supaya dirty pages ditulis ke disk dulu — rekomendasi resmi Linux docs)
    echo -e "${TEAL}--- [1/3] sync filesystem ---${NC}"
    if sync 2>/dev/null; then
        echo -e "${GREEN}✓${NC} ${GRAY}sync done — dirty pages flushed to disk${NC}"
    else
        echo -e "${ORANGE}!${NC} ${GRAY}sync failed (non-fatal, lanjut ke drop_caches)${NC}"
    fi
    echo ""

    # Step 2: drop kernel caches (level 3 = pagecache + dentries + inodes,
    # paling komprehensif — original pakai echo 1 yang hanya pagecache)
    echo -e "${TEAL}--- [2/3] drop kernel caches (level 3) ---${NC}"
    if echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; then
        echo -e "${GREEN}✓${NC} ${GRAY}/proc/sys/vm/drop_caches = 3 (pagecache + dentries + inodes cleared)${NC}"
    else
        echo -e "${ORANGE}!${NC} ${GRAY}drop_caches failed (permission denied?)${NC}"
    fi
    echo ""

    # Step 3: apt clean (clear /var/cache/apt/archives/)
    echo -e "${TEAL}--- [3/3] apt clean ---${NC}"
    if [ "$apt_available" = "yes" ]; then
        if apt clean 2>/dev/null; then
            echo -e "${GREEN}✓${NC} ${GRAY}apt clean done — /var/cache/apt/archives/ dikosongkan${NC}"
        else
            echo -e "${ORANGE}!${NC} ${GRAY}apt clean failed${NC}"
        fi
    else
        echo -e "${GRAY}-${NC} ${GRAY}apt tidak tersedia, skip apt clean${NC}"
    fi
    echo ""

    # Show memory after clear
    local cached_after=$(get_mem_kb "Cached:")
    local buffers_after=$(get_mem_kb "Buffers:")
    local memfree_after=$(get_mem_kb "MemFree:")

    echo -e "${CYAN}[*]${NC} ${WHITE}Status memory setelah clear:${NC}"
    echo -e "    ${GRAY}Cached  : ${GREEN}$(format_kb "$cached_after")${NC}"
    echo -e "    ${GRAY}Buffers : ${GREEN}$(format_kb "$buffers_after")${NC}"
    echo -e "    ${GRAY}MemFree : ${GREEN}$(format_kb "$memfree_after")${NC}"
    echo ""

    # Hitung selisih MemFree (indikator cache yang di-free)
    local delta=$((memfree_after - memfree_before))
    if [ "$delta" -gt 0 ] 2>/dev/null; then
        echo -e "${GREEN}✓${NC} ${WHITE}Clear cache selesai.${NC} ${GRAY}MemFree naik ${YELLOW}+$(format_kb "$delta")${NC}"
    elif [ "$delta" -lt 0 ] 2>/dev/null; then
        echo -e "${GREEN}✓${NC} ${WHITE}Clear cache selesai.${NC} ${GRAY}MemFree turun ${ORANGE}$(format_kb "${delta#-}")${NC} ${GRAY}(cache rebuild cepat, normal)${NC}"
    else
        echo -e "${GREEN}✓${NC} ${WHITE}Clear cache selesai.${NC} ${GRAY}MemFree tetap (cache sudah kecil)${NC}"
    fi
    echo -e "${GRAY}Catatan: cache akan rebuild otomatis saat sistem butuh.${NC}"

    pause
}

main
