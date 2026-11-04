#!/bin/bash
# ==========================================
# HAXOR PANEL TUNNELING — Auto Update Script (v15)
# Tagline: DEKENG ANE BIAK BELITONG
# Source : Adaptasi dari script open-source (lizsvr/cfnfree)
# ==========================================
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
# Download update (6 menu files + 8 utility Fase 1+2 HAXOR)
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
#change direct
cd /root
# clear
clear
echo -e "Succes Update Menu"

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

sleep 3
