#!/bin/bash
# ==========================================
# HAXOR PANEL TUNNELING — Auto Update Script
# Tagline: DEKENG ANE BIAK BELITONG
# Source : Adaptasi dari script open-source (lizsvr/cfnfree)
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
# Download update (6 menu files + 4 utility Fase 1 HAXOR)
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
#change direct
cd /root
# clear
clear
echo -e "Succes Update Menu"
sleep 3
