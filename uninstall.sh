#!/bin/bash

# Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${RED}=== Outline Panel Uninstaller (Files Only) ===${NC}"

# 1. Check Root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root${NC}"
  exit
fi

# 2. Stop & Delete Bot Process from PM2
echo -e "${YELLOW}Stopping Bot Process...${NC}"
if command -v pm2 &> /dev/null; then
    pm2 stop outline-bot &> /dev/null
    pm2 delete outline-bot &> /dev/null
    pm2 save &> /dev/null
    echo -e "${GREEN}Bot process stopped and removed from PM2.${NC}"
else
    echo -e "${RED}PM2 not found. Skipping process cleanup.${NC}"
fi

# 3. Remove Backend Files (bot.js and folder)
echo -e "${YELLOW}Removing Backend Files (bot.js)...${NC}"
if [ -d "/root/outline-bot" ]; then
    rm -rf /root/outline-bot
    echo -e "${GREEN}Deleted /root/outline-bot directory.${NC}"
else
    echo -e "${RED}Backend directory not found.${NC}"
fi

# 4. Remove Frontend File (index.html)
echo -e "${YELLOW}Removing Frontend File (index.html)...${NC}"
if [ -f "/var/www/html/index.html" ]; then
    rm -f /var/www/html/index.html
    echo -e "${GREEN}Deleted /var/www/html/index.html${NC}"
else
    echo -e "${RED}index.html not found.${NC}"
fi

echo -e "${GREEN}==========================================${NC}"
echo -e "${GREEN} UNINSTALL COMPLETE ${NC}"
echo -e "${GREEN}==========================================${NC}"
echo -e "Bot.js and index.html have been removed."
echo -e "Node.js, Nginx, and other packages are NOT removed."
