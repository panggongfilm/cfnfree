#!/bin/bash
# ==========================================
# HAXOR PANEL TUNNELING — Auto Update Script (v18)
# Tagline: DEKENG ANE BIAK BELITONG
# Source : Adaptasi dari script open-source (lizsvr/cfnfree)
# ==========================================
# v18 (v43): added auto-restart auto-install (cron watcher untuk service tunneling down)
# v17 (v41): added banner-manager auto-install (4 opsi interactive + 3 layer safety)
# v16 (v39): added upgrade-dropbear auto-install (Dropbear 2026.94 PATH X)
# v15 (v35): updated note bw-limit post-install steps (3 commands)
# v14 (v28): added bw-limit + pantau + tendang-safe auto-install
# v13 (v18): added bw-user + 4 utility Fase 1
# ==========================================
# My Telegram : https://t.me/Akbar218
# ==========================================
# Color
RED='\033[0;31m'
NC='\033[0m'
GREEN='\033[0;32m'
ORANGE='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
LIGHT='\033[0;37m'
# ==========================================
# Getting
MYIP=$(wget -qO- ipinfo.io/ip);
echo "Checking VPS"
IZIN=$(curl https://raw.githubusercontent.com/panggongfilm/cfnfree/main/ipvps.txt | grep $MYIP | awk '{print $3}')
if [ $MYIP = $MYIP ]; then
echo -e "${NC}${GREEN}Permission Accepted...${NC}"
else
echo -e "${NC}${RED}Permission Denied!${NC}";
echo -e "${NC}${LIGHT}Please Contact Admin!!"
echo -e "${NC}${LIGHT}Telegram : https://t.me/liz_mine"
exit 0
fi
clear
lizupdate="raw.githubusercontent.com/panggongfilm/cfnfree/main/update"
lizssh="raw.githubusercontent.com/panggongfilm/cfnfree/main/ssh"
# change direct
cd /usr/bin
# remove file
rm menu
rm -rf menu
# Download update (6 menu files + 11 utility Fase 1+2+3 HAXOR)
# Note post-install untuk masing-masing utility:
#   - bw-user        : butuh 'sudo bw-user --setup' (cron + dirs)
#   - pantau          : siap pakai (no setup needed)
#   - tendang-safe    : siap pakai (no setup needed)
#   - bw-limit        : butuh 3 post-install steps untuk fresh VPS:
#       1. sudo bw-limit --install-cron      (cron watcher */2 menit + flock)
#       2. sudo bw-limit --init                (rebuild tc + cgroup dari blacklist existing)
#       3. systemd init service (manual — kalau mau survive reboot):
#          cat > /etc/systemd/system/bw-limit-init.service <<EOF
#          [Unit]
#          Description=BW-Limit Init (rebuild tc + cgroup on boot)
#          After=network.target
#          Before=dropbear.service
#          [Service]
#          Type=oneshot
#          ExecStart=/usr/bin/bw-limit --init
#          RemainAfterExit=yes
#          [Install]
#          WantedBy=multi-user.target
#          EOF
#          systemctl daemon-reload
#          systemctl enable --now bw-limit-init.service
#   - upgrade-dropbear : siap pakai (download only). Jalankan 'sudo upgrade-dropbear'
#                        via SSH direct (port 22, BUKAN via tunneling Dropbear) untuk
#                        upgrade binary Dropbear 2019.78 → 2026.94. WAJIB dijalankan
#                        kalau VPS baru BELUM punya Dropbear 2026.94 (tanpa ini,
#                        bw-limit shaping TIDAK akan work — Dropbear child UID=root)
#   - banner-manager    : siap pakai (download only). Interactive banner manager untuk
#                        /etc/issue.net. 4 opsi: tampilkan + edit + template + reset.
#                        Banner langsung aktif untuk koneksi baru (NO restart service).
#                        3 layer safety: preview confirm + backup timestamp + validate input.
#                        Akses via menu utama [07] Banner Manager.
#   - auto-restart      : siap pakai (download only). Cron watcher untuk auto-restart
#                        service tunneling saat down/crash (ssh/dropbear/sslh/stunnel5/nginx
#                        ATAU badvpn-udpgw missing). Schedule */10 menit + flock -n.
#                        Post-install WAJIB: setup cron manual (lihat AUTO-SETUP section di
#                        bawah — auto-restart cron TIDAK otomatis, harus dibuat manual via
#                        crontab ATAU ikuti template di bawah).
# Detail: jalankan 'bw-limit --help' setelah install
wget -O menu "https://${lizupdate}/menu.sh"
wget -O maddssh "https://${lizupdate}/maddssh.sh"
wget -O mbackup "https://${lizupdate}/mbackup.sh"
wget -O maddxray "https://${lizupdate}/maddxray.sh"
wget -O msetting "https://${lizupdate}/msetting.sh"
wget -O start-menu "https://${lizupdate}/start-menu.sh"
# Download utility Fase 1 (HAXOR branding + BELITONG)
wget -O bw "https://${lizssh}/bw.sh"
wget -O speedtest-haxor "https://${lizssh}/speedtest-haxor.sh"
wget -O clearlog "https://${lizssh}/clearlog.sh"
wget -O clearcache "https://${lizssh}/clearcache.sh"
wget -O bw-user "https://${lizssh}/bw-user.sh"
# Download utility Fase 2 (monitoring + tendang aman + bw-limit HAXOR)
wget -O pantau "https://${lizssh}/pantau.sh"
wget -O tendang-safe "https://${lizssh}/tendang-safe.sh"
wget -O bw-limit "https://${lizssh}/bw-limit.sh"
# Download utility Fase 3 (PATH X automation — upgrade Dropbear binary)
wget -O upgrade-dropbear "https://${lizssh}/upgrade-dropbear.sh"
# Download utility Fase 3 (banner-manager — interactive banner manager HAXOR)
wget -O banner-manager "https://${lizssh}/banner-manager.sh"
# Download utility Fase 3 (auto-restart — cron watcher untuk service tunneling down)
wget -O auto-restart "https://${lizssh}/auto-restart"
# change Permission
chmod +x menu
chmod +x maddssh
chmod +x maddxray
chmod +x mbackup
chmod +x msetting
chmod +x start-menu
chmod +x bw
chmod +x speedtest-haxor
chmod +x clearlog
chmod +x clearcache
chmod +x bw-user
chmod +x pantau
chmod +x tendang-safe
chmod +x bw-limit
chmod +x upgrade-dropbear
chmod +x banner-manager
chmod +x auto-restart
#change direct
cd /root
# clear
clear
echo -e "Succes Update Menu + Utility Fase 1+2+3 HAXOR (+ banner-manager v41 + auto-restart v43)"

# === AUTO-SETUP bw-limit (optional, only if bw-limit installed + blacklist existing) ===
# Kalau fresh VPS dengan blacklist existing (dari backup/restore), auto-setup:
# - install cron watcher
# - rebuild tc + cgroup dari blacklist
# - systemd init service (kalau belum ada, buat + enable)
if [ -x /usr/bin/bw-limit ] && [ -f /etc/bw-limit/blacklist.txt ] && [ -s /etc/bw-limit/blacklist.txt ]; then
    echo -e "Setting up bw-limit infrastructure..."
    /usr/bin/bw-limit --install-cron 2>/dev/null && echo -e "  OK: cron watcher installed"
    /usr/bin/bw-limit --init 2>/dev/null && echo -e "  OK: tc + cgroup rebuilt dari blacklist"
    # systemd init service (kalau belum ada, buat + enable)
    if [ ! -f /etc/systemd/system/bw-limit-init.service ]; then
        cat > /etc/systemd/system/bw-limit-init.service <<UNITEOF
[Unit]
Description=BW-Limit Init (rebuild tc + cgroup on boot)
After=network.target
Before=dropbear.service

[Service]
Type=oneshot
ExecStart=/usr/bin/bw-limit --init
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNITEOF
        systemctl daemon-reload
        systemctl enable --now bw-limit-init.service 2>/dev/null
        echo -e "  OK: systemd init service created + enabled"
    else
        systemctl enable --now bw-limit-init.service 2>/dev/null
        echo -e "  OK: systemd init service already exists, ensure enabled"
    fi
    echo -e "bw-limit setup complete. Detail: 'bw-limit --help'"
fi

# === REMINDER: upgrade-dropbear WAJIB dijalankan manual via SSH direct ===
# Script ini HANYA download upgrade-dropbear, TIDAK auto-run (karena restart Dropbear
# = user tunneling disconnect 30-60 detik). Admin HARUS jalankan manual via SSH direct:
#
#   sudo upgrade-dropbear
#
# Layer 2 safety di script akan REJECT kalau dijalankan via tunneling Dropbear.
# Kalau VPS baru BELUM upgrade ke Dropbear 2026.94, bw-limit shaping TIDAK akan work
# (Dropbear child UID=root, dynamic iptables per-ephemeral-port TIDAK match).
# Post-upgrade verify: 'dropbear -V' → harus v2026.94

echo -e "${NC}${YELLOW}REMINDER:${NC} Jalankan 'sudo upgrade-dropbear' via SSH direct untuk aktifkan bw-limit shaping."
sleep 3
