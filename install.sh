#!/bin/bash

# Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Outline VPN Panel Installer by Gemini ===${NC}"

# 1. Check Root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root${NC}"
  exit
fi

# 2. Update System & Install Dependencies
echo -e "${YELLOW}Updating System...${NC}"
apt update && apt upgrade -y
apt install -y curl wget gnupg2 ca-certificates lsb-release nginx git

# 3. Install Node.js 18
echo -e "${YELLOW}Installing Node.js...${NC}"
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt install -y nodejs

# 4. Setup Directory Structure
echo -e "${YELLOW}Setting up directories...${NC}"
mkdir -p /root/outline-bot
rm -rf /var/www/html/*

# 5. Create backend files (bot.js)
echo -e "${YELLOW}Creating Backend Files...${NC}"
cat << 'EOF' > /root/outline-bot/bot.js
const express = require('express');
const cors = require('cors');
const bodyParser = require('body-parser');
const TelegramBot = require('node-telegram-bot-api');
const axios = require('axios');
const https = require('https');
const fs = require('fs');
const moment = require('moment-timezone');
const { exec } = require('child_process');

const app = express();
app.use(cors());
app.use(bodyParser.json());

const CONFIG_FILE = 'config.json';
const CLAIM_FILE = 'claimed_users.json';
const BLOCKED_FILE = 'blocked_registry.json';
const RESELLER_FILE = 'resellers.json';

let config = {};
let bot = null;
let claimedUsers = [];
let blockedRegistry = {}; 
let userStates = {};
let resellers = [];
let resellerSessions = {}; 

const agent = new https.Agent({ rejectUnauthorized: false });
const axiosClient = axios.create({ httpsAgent: agent, timeout: 10000, headers: { 'Content-Type': 'application/json' } });

function loadConfig() {
    try { if(fs.existsSync(CONFIG_FILE)) config = JSON.parse(fs.readFileSync(CONFIG_FILE)); } catch (e) {}
    try { if(fs.existsSync(CLAIM_FILE)) claimedUsers = JSON.parse(fs.readFileSync(CLAIM_FILE)); } catch(e) {}
    try { if(fs.existsSync(BLOCKED_FILE)) blockedRegistry = JSON.parse(fs.readFileSync(BLOCKED_FILE)); } catch(e) {}
    try { if(fs.existsSync(RESELLER_FILE)) resellers = JSON.parse(fs.readFileSync(RESELLER_FILE)); } catch(e) {}
}
loadConfig();

// --- SERVER HELPER FUNCTIONS ---
function getServers() {
    if (!config.api_urls) return [];
    return config.api_urls.map(s => {
        if (typeof s === 'string') return { name: "Server", url: s };
        return s;
    });
}

function getServerKeyboard(callbackPrefix) {
    const servers = getServers();
    let keyboard = [];
    let row = [];
    servers.forEach((srv, index) => {
        let sName = srv.name || `Server ${index + 1}`;
        row.push({ text: `🖥️ ${sName}`, callback_data: `${callbackPrefix}_${index}` });
        if (row.length === 2) {
            keyboard.push(row);
            row = [];
        }
    });
    if (row.length > 0) keyboard.push(row);
    return keyboard;
}

async function findKeyInAllServers(keyIdOrName, isName = false) {
    const servers = getServers();
    for (const srv of servers) {
        try {
            const serverUrl = srv.url;
            const [kRes, mRes] = await Promise.all([
                axiosClient.get(`${serverUrl}/access-keys`),
                axiosClient.get(`${serverUrl}/metrics/transfer`)
            ]);
            let key;
            if (isName) {
                key = kRes.data.accessKeys.find(k => k.name.includes(keyIdOrName));
            } else {
                key = kRes.data.accessKeys.find(k => String(k.id) === String(keyIdOrName));
            }
            if (key) {
                return { key, metrics: mRes.data, serverUrl, serverName: srv.name };
            }
        } catch (e) { console.error(`Error checking server ${srv.url}:`, e.message); }
    }
    return null;
}

async function getAllKeysFromAllServers(filter = null) {
    const servers = getServers();
    let allKeys = [];
    for (const srv of servers) {
        try {
            const res = await axiosClient.get(`${srv.url}/access-keys`);
            let keys = res.data.accessKeys;
            if(filter) keys = keys.filter(filter);
            keys = keys.map(k => ({ ...k, _serverUrl: srv.url, _serverName: srv.name }));
            allKeys = allKeys.concat(keys);
        } catch (e) {}
    }
    return allKeys;
}

async function getKeysFromSpecificServer(index) {
    const servers = getServers();
    if (!servers[index]) return [];
    const srv = servers[index];
    try {
        const res = await axiosClient.get(`${srv.url}/access-keys`);
        return res.data.accessKeys.map(k => ({ ...k, _serverUrl: srv.url, _serverName: srv.name }));
    } catch (e) { return []; }
}

async function createKeyOnServer(serverIndex, name, limitBytes) {
    const servers = getServers();
    if (!servers[serverIndex]) throw new Error("Invalid Server Index");
    const targetServer = servers[serverIndex];
    const res = await axiosClient.post(`${targetServer.url}/access-keys`);
    await axiosClient.put(`${targetServer.url}/access-keys/${res.data.id}/name`, { name: name });
    await axiosClient.put(`${targetServer.url}/access-keys/${res.data.id}/data-limit`, { limit: { bytes: limitBytes } });
    return { ...res.data, _serverUrl: targetServer.url, _serverName: targetServer.name };
}

// --- API ROUTES ---
app.get('/api/config', (req, res) => { loadConfig(); res.json({ ...config, resellers }); });

app.post('/api/update-config', (req, res) => {
    try {
        const { resellers: newResellers, ...newConfig } = req.body;
        config = { ...config, ...newConfig };
        fs.writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 4));
        if(newResellers) { resellers = newResellers; fs.writeFileSync(RESELLER_FILE, JSON.stringify(resellers, null, 4)); }
        res.json({ success: true, config: config });
        setTimeout(() => { loadConfig(); startBot(); }, 1000);
    } catch (error) { res.status(500).json({ success: false }); }
});

app.post('/api/change-port', (req, res) => {
    const newPort = req.body.port;
    if(!newPort || isNaN(newPort)) return res.status(400).json({error: "Invalid Port"});
    const nginxConfig = `server { listen ${newPort}; server_name _; root /var/www/html; index index.html; location / { try_files $uri $uri/ =404; } }`;
    try { fs.writeFileSync('/etc/nginx/sites-available/default', nginxConfig); config.panel_port = parseInt(newPort); fs.writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 4)); exec('systemctl reload nginx', (error) => { if (error) { return res.status(500).json({error: "Failed to reload Nginx"}); } res.json({ success: true, message: `Port changed to ${newPort}` }); }); } catch (err) { res.status(500).json({ error: "Failed to write config" }); }
});
app.listen(3000, () => console.log('✅ Sync Server running on Port 3000'));

if (config.bot_token && config.api_urls && config.api_urls.length > 0) startBot();

function startBot() {
    if(bot) { try { bot.stopPolling(); } catch(e){} }
    if(!config.bot_token) return;

    console.log("🚀 Starting Bot...");
    bot = new TelegramBot(config.bot_token, { polling: true });
    
    const ADMIN_IDS = config.admin_id ? config.admin_id.split(',').map(id => id.trim()) : [];
    const WELCOME_MSG = config.welcome_msg || "👋 Welcome to VPN Shop!\nမင်္ဂလာပါ VPN Shop မှ ကြိုဆိုပါတယ်။";
    const TRIAL_ENABLED = config.trial_enabled !== false;
    const TRIAL_DAYS = parseInt(config.trial_days) || 1;
    const TRIAL_GB = parseFloat(config.trial_gb) || 1;
    
    const BTN = {
        trial: (config.buttons && config.buttons.trial) ? config.buttons.trial : "🆓 Free Trial (အစမ်းသုံးရန်)",
        buy: (config.buttons && config.buttons.buy) ? config.buttons.buy : "🛒 Buy Key (ဝယ်ယူရန်)",
        mykey: (config.buttons && config.buttons.mykey) ? config.buttons.mykey : "🔑 My Key (မိမိ Key ရယူရန်)",
        info: (config.buttons && config.buttons.info) ? config.buttons.info : "👤 Account Info (အကောင့်စစ်ရန်)",
        support: (config.buttons && config.buttons.support) ? config.buttons.support : "🆘 Support (ဆက်သွယ်ရန်)",
        reseller: (config.buttons && config.buttons.reseller) ? config.buttons.reseller : "🤝 Reseller Login",
        resell_buy: (config.buttons && config.buttons.resell_buy) ? config.buttons.resell_buy : "🛒 Buy Stock",
        resell_create: (config.buttons && config.buttons.resell_create) ? config.buttons.resell_create : "📦 Create User Key",
        resell_users: (config.buttons && config.buttons.resell_users) ? config.buttons.resell_users : "👥 My Users",
        resell_extend: (config.buttons && config.buttons.resell_extend) ? config.buttons.resell_extend : "⏳ Extend User",
        resell_logout: (config.buttons && config.buttons.resell_logout) ? config.buttons.resell_logout : "🔙 Logout Reseller"
    };

    function formatAccessUrl(url, serverUrl) {
        if (!url) return url;
        try {
            const urlObj = new URL(url);
            const originalIp = urlObj.hostname;
            if (config.domain_map && config.domain_map.length > 0) {
                const mapping = config.domain_map.find(m => m.ip === originalIp);
                if (mapping && mapping.domain) return url.replace(originalIp, mapping.domain);
            }
            if (config.domain) return url.replace(originalIp, config.domain);
            return url;
        } catch (e) { return url; }
    }
    
    function isAdmin(chatId) { return ADMIN_IDS.includes(String(chatId)); }
    function formatBytes(bytes) { if (!bytes || bytes === 0) return '0 B'; const i = Math.floor(Math.log(bytes) / Math.log(1024)); return (bytes / Math.pow(1024, i)).toFixed(2) + ' ' + ['B', 'KB', 'MB', 'GB', 'TB'][i]; }
    function getMyanmarDate(offsetDays = 0) { return moment().tz("Asia/Yangon").add(offsetDays, 'days').format('YYYY-MM-DD'); }
    function isExpired(dateString) { if (!/^\d{4}-\d{2}-\d{2}$/.test(dateString)) return false; const today = moment().tz("Asia/Yangon").startOf('day'); const expire = moment.tz(dateString, "YYYY-MM-DD", "Asia/Yangon").startOf('day'); return expire.isBefore(today); }
    function getDaysRemaining(dateString) { if (!/^\d{4}-\d{2}-\d{2}$/.test(dateString)) return "Unknown"; const today = moment().tz("Asia/Yangon").startOf('day'); const expire = moment.tz(dateString, "YYYY-MM-DD", "Asia/Yangon").startOf('day'); const diff = expire.diff(today, 'days'); return diff >= 0 ? `${diff} Days` : "Expired"; }
    function sanitizeText(text) { if (!text) return ''; return text.replace(/([_*\[\]()~`>#+\-=|{}.!])/g, '\\$1'); }

    function getMainMenu(userId) {
        let kb = []; let row1 = [];
        if (TRIAL_ENABLED) row1.push({ text: BTN.trial });
        row1.push({ text: BTN.buy }); kb.push(row1);
        kb.push([{ text: BTN.mykey }, { text: BTN.info }]); 
        kb.push([{ text: BTN.reseller }, { text: BTN.support }]);
        if (isAdmin(userId)) kb.unshift([{ text: "👮‍♂️ Admin Panel" }]);
        return kb;
    }

    function getResellerMenu(username, balance) {
        return [
            [{ text: `${BTN.resell_buy} (${balance} Ks)` }],
            [{ text: BTN.resell_create }, { text: BTN.resell_extend }],
            [{ text: BTN.resell_users }, { text: BTN.resell_logout }]
        ];
    }

    bot.onText(/\/start/, (msg) => { 
        const userId = msg.chat.id; 
        delete userStates[userId];
        delete resellerSessions[userId];
        bot.sendMessage(userId, WELCOME_MSG, { reply_markup: { keyboard: getMainMenu(userId), resize_keyboard: true } }); 
    });

    bot.on('message', async (msg) => {
        const chatId = msg.chat.id;
        const text = msg.text;
        
        if (!text) return; 

        if (userStates[chatId]) {
            const state = userStates[chatId];
            if (state.status === 'RESELLER_LOGIN_USER') {
                userStates[chatId].username = text.trim();
                userStates[chatId].status = 'RESELLER_LOGIN_PASS';
                return bot.sendMessage(chatId, "🔑 Enter **Password**:", { parse_mode: 'Markdown' });
            }
            if (state.status === 'RESELLER_LOGIN_PASS') {
                const username = userStates[chatId].username;
                const password = text.trim();
                const reseller = resellers.find(r => r.username === username && r.password === password);
                if(reseller) {
                    resellerSessions[chatId] = reseller.username;
                    delete userStates[chatId];
                    bot.sendMessage(chatId, `✅ **Login Success!**\n👤 Owner: ${reseller.username}\n💰 Balance: ${reseller.balance} Ks`, { parse_mode: 'Markdown', reply_markup: { keyboard: getResellerMenu(reseller.username, reseller.balance), resize_keyboard: true } });
                } else {
                    delete userStates[chatId];
                    bot.sendMessage(chatId, "❌ **Login Failed!**", { reply_markup: { keyboard: getMainMenu(chatId), resize_keyboard: true } });
                }
                return;
            }
            
            if (state.status === 'RESELLER_ENTER_NAME') {
                 const { plan, reseller: rUsername, serverIndex } = userStates[chatId];
                 const customerName = text.trim().replace(/\|/g, '');
                 
                 bot.sendMessage(chatId, "⏳ Generating Key...");
                 try {
                    const rIndex = resellers.findIndex(r => r.username === rUsername);
                    if(rIndex === -1 || resellers[rIndex].balance < plan.price) {
                         bot.sendMessage(chatId, "❌ Insufficient Balance or Error.", { reply_markup: { keyboard: getResellerMenu(rUsername, resellers[rIndex] ? resellers[rIndex].balance : 0), resize_keyboard: true } });
                    } else {
                        resellers[rIndex].balance -= parseInt(plan.price);
                        fs.writeFileSync(RESELLER_FILE, JSON.stringify(resellers, null, 4));
                        
                        const expireDate = getMyanmarDate(plan.days);
                        const limitBytes = Math.floor(plan.gb * 1024 * 1024 * 1024);
                        const finalName = `${customerName} (R-${rUsername}) | ${expireDate}`;
                        
                        const data = await createKeyOnServer(serverIndex, finalName, limitBytes);
                        
                        let finalUrl = formatAccessUrl(data.accessUrl, data._serverUrl); finalUrl += `#${encodeURIComponent(customerName)}`;
                        
                        bot.sendMessage(chatId, `✅ **Key Created!**\n\n👤 Customer: ${customerName}\n🖥️ Server: ${data._serverName}\n💰 Cost: ${plan.price} Ks\n💰 Remaining: ${resellers[rIndex].balance} Ks\n\n🔗 **Key:**\n<code>${finalUrl}</code>`, { 
                            parse_mode: 'HTML',
                            reply_markup: { keyboard: getResellerMenu(rUsername, resellers[rIndex].balance), resize_keyboard: true }
                        });
                    }
                 } catch(e) { 
                     bot.sendMessage(chatId, "❌ Error connecting to servers.", { reply_markup: { keyboard: getResellerMenu(rUsername, resellers.find(r=>r.username===rUsername).balance), resize_keyboard: true } }); 
                 }
                 
                 delete userStates[chatId];
                 return;
            }

            if (state.status === 'ADMIN_TOPUP_AMOUNT') {
                if(!isAdmin(chatId)) return;
                const amount = parseInt(text.trim());
                if(isNaN(amount)) return bot.sendMessage(chatId, "❌ Invalid Amount. Enter number only.");
                
                const targetReseller = state.targetReseller;
                const rIndex = resellers.findIndex(r => r.username === targetReseller);
                
                if(rIndex !== -1) {
                    resellers[rIndex].balance = parseInt(resellers[rIndex].balance) + amount;
                    fs.writeFileSync(RESELLER_FILE, JSON.stringify(resellers, null, 4));
                    bot.sendMessage(chatId, `✅ **Topup Success!**\n👤 Reseller: ${targetReseller}\n💰 Added: ${amount} Ks\n💰 New Balance: ${resellers[rIndex].balance} Ks`, { 
                        parse_mode: 'Markdown',
                        reply_markup: { keyboard: getMainMenu(chatId), resize_keyboard: true }
                    });
                } else {
                    bot.sendMessage(chatId, "❌ Reseller not found.", { reply_markup: { keyboard: getMainMenu(chatId), resize_keyboard: true } });
                }
                delete userStates[chatId];
                return;
            }

            return; 
        }

        if (resellerSessions[chatId]) {
            const rUser = resellerSessions[chatId];
            const reseller = resellers.find(r => r.username === rUser);
            
            if (text === BTN.resell_logout) {
                delete resellerSessions[chatId];
                return bot.sendMessage(chatId, "👋 Logged out.", { reply_markup: { keyboard: getMainMenu(chatId), resize_keyboard: true } });
            }
            if (text.startsWith(BTN.resell_buy.split('(')[0].trim())) {
                 return bot.sendMessage(chatId, `💰 **Your Balance:** ${reseller.balance} Ks\n\nTo topup, contact Admin.`, { parse_mode: 'Markdown' });
            }
            if (text === BTN.resell_create) {
                const plansToUse = (config.reseller_plans && config.reseller_plans.length > 0) ? config.reseller_plans : config.plans;
                if(!plansToUse || plansToUse.length === 0) return bot.sendMessage(chatId, "❌ No reseller plans available.");
                const keyboard = plansToUse.map((p, i) => [{ text: `${p.days} Days - ${p.gb}GB - ${p.price}Ks`, callback_data: `resell_buy_${i}` }]); 
                return bot.sendMessage(chatId, "📅 **Choose Reseller Plan:**", { parse_mode: 'Markdown', reply_markup: { inline_keyboard: keyboard } });
            }
            
            if (text === BTN.resell_extend) {
                bot.sendMessage(chatId, "🔎 Loading your users from all servers...");
                try {
                    const myKeys = await getAllKeysFromAllServers(k => k.name.includes(`(R-${rUser})`));
                    if(myKeys.length === 0) return bot.sendMessage(chatId, "❌ You have no users.");
                    
                    let keyboard = [];
                    myKeys.forEach(k => {
                        let cleanName = k.name.split('|')[0].replace(`(R-${rUser})`, '').trim();
                        keyboard.push([{ text: `👤 ${cleanName} (${k._serverName || 'Srv'})`, callback_data: `rchk_${k.id}` }]);
                    });
                    
                    if(keyboard.length > 10) {
                         bot.sendMessage(chatId, `⚠️ Showing first 10 users of ${myKeys.length}.\nSelect user to manage:`, { reply_markup: { inline_keyboard: keyboard.slice(0, 10) } });
                    } else {
                         bot.sendMessage(chatId, "⚙️ **User Management**\nSelect a user to Extend or Delete:", { parse_mode: 'Markdown', reply_markup: { inline_keyboard: keyboard } });
                    }
                } catch(e) { bot.sendMessage(chatId, "⚠️ Server Error"); }
                return;
            }

            if (text === BTN.resell_users) {
                bot.sendMessage(chatId, "🔎 Checking your users...");
                try {
                    const myKeys = await getAllKeysFromAllServers(k => k.name.includes(`(R-${rUser})`));
                    if(myKeys.length === 0) return bot.sendMessage(chatId, "❌ You haven't created any keys yet.");
                    let txt = `👥 **User List (${myKeys.length})**\n\n`;
                    myKeys.forEach(k => {
                        let cleanName = k.name.split('|')[0].replace(`(R-${rUser})`, '').trim();
                        let expireDate = k.name.split('|').pop().trim();
                        txt += `👤 ${cleanName} @ ${k._serverName || 'Server'}\n📅 Exp: ${expireDate}\n🔗 <code>${formatAccessUrl(k.accessUrl, k._serverUrl)}#${encodeURIComponent(cleanName)}</code>\n\n`;
                    });
                    if(txt.length > 4000) txt = txt.substring(0, 4000) + "...";
                    bot.sendMessage(chatId, txt, { parse_mode: 'HTML' });
                } catch(e) { bot.sendMessage(chatId, "⚠️ Error fetching users."); }
                return;
            }
            return;
        }

        if (text === BTN.reseller) {
            userStates[chatId] = { status: 'RESELLER_LOGIN_USER' };
            return bot.sendMessage(chatId, "🔐 **Reseller Login**\n\nPlease enter your **Username**:", { parse_mode: 'Markdown', reply_markup: { remove_keyboard: true } });
        }

        if (text === BTN.trial) {
            if (!TRIAL_ENABLED) return bot.sendMessage(chatId, "⚠️ Free Trial is currently disabled.");
            if (claimedUsers.includes(chatId)) return bot.sendMessage(chatId, "⚠️ You have already claimed a trial key.");
            bot.sendMessage(chatId, "🖥️ **Select Server for Trial:**", {
                parse_mode: 'Markdown',
                reply_markup: { inline_keyboard: getServerKeyboard('trial_srv') }
            });
            return;
        }

        if (text === BTN.buy) {
            if(!config.plans || config.plans.length === 0) return bot.sendMessage(chatId, "❌ No plans available.");
            const keyboard = config.plans.map((p, i) => [{ text: `${p.days} Days - ${p.gb}GB - ${p.price}Ks`, callback_data: `buy_${i}` }]); 
            bot.sendMessage(chatId, "📅 **Choose Plan:**", { parse_mode: 'Markdown', reply_markup: { inline_keyboard: keyboard } });
            return;
        }

        if (text === BTN.mykey) {
            const userFullName = `${msg.from.first_name}`.trim(); 
            bot.sendMessage(chatId, "🔎 Searching all servers..."); 
            try { 
                const result = await findKeyInAllServers(userFullName, true);
                if (!result) return bot.sendMessage(chatId, "❌ **Key Not Found!**"); 
                const { key, serverUrl, serverName } = result;
                let cleanName = key.name.split('|')[0].trim();
                let finalUrl = formatAccessUrl(key.accessUrl, serverUrl);
                finalUrl += `#${encodeURIComponent(cleanName)}`;
                bot.sendMessage(chatId, `🔑 <b>My Key (${serverName}):</b>\n<code>${finalUrl}</code>`, { parse_mode: 'HTML' }); 
            } catch (e) { bot.sendMessage(chatId, "⚠️ Server Error"); }
            return;
        }

        if (text === BTN.info) {
            const userFullName = `${msg.from.first_name}`.trim(); 
            bot.sendMessage(chatId, "🔎 Checking Status..."); 
            try { 
                const result = await findKeyInAllServers(userFullName, true);
                if (!result) return bot.sendMessage(chatId, "❌ **Account Not Found**"); 
                const { key, metrics, serverName } = result;
                const used = metrics.bytesTransferredByUserId[key.id] || 0; 
                const limit = key.dataLimit ? key.dataLimit.bytes : 0; 
                const remaining = limit > 0 ? limit - used : 0; 
                let cleanName = key.name; 
                let expireDate = "Unknown"; 
                if (key.name.includes('|')) { const parts = key.name.split('|'); cleanName = parts[0].trim(); expireDate = parts[parts.length-1].trim(); } 
                
                // --- STATUS & BLOCK LOGIC ---
                let statusIcon = "🟢"; let statusText = "Active"; 
                
                // Check if Blocked (Limit 0 or Name starts with 🔴)
                if (limit === 0 || cleanName.startsWith("🔴")) { 
                    statusIcon = "🔴"; statusText = "Blocked/Switch OFF"; 
                } 
                else if (isExpired(expireDate)) { 
                    statusIcon = "🔴"; statusText = "Expired"; 
                }
                else if (limit > 0 && remaining <= 0) { 
                    statusIcon = "🔴"; statusText = "Data Depleted"; 
                }
                
                let percent = limit > 0 ? Math.min((used / limit) * 100, 100) : 0; 
                const barLength = 10; const fill = Math.round((percent / 100) * barLength); 
                const bar = "█".repeat(fill) + "░".repeat(barLength - fill); 
                const msgTxt = `👤 **Name:** ${sanitizeText(cleanName)}\n🖥️ **Server:** ${serverName}\n📡 **Status:** ${statusIcon} ${statusText}\n⏳ **Day:** ${getDaysRemaining(expireDate)}\n⬇️ **Used:** ${formatBytes(used)}\n🎁 **Free:** ${formatBytes(remaining > 0 ? remaining : 0)}\n📅 **Exp:** ${expireDate}\n\n[${bar}] ${percent.toFixed(1)}%`; 
                bot.sendMessage(chatId, msgTxt, { parse_mode: 'Markdown' }); 
            } catch (e) { bot.sendMessage(chatId, "⚠️ Server Error"); }
            return;
        }

        if (text === BTN.support) {
            const adminUsers = config.admin_username ? config.admin_username.split(',') : []; 
            const keyboard = []; 
            adminUsers.forEach(u => { let cleanUser = u.trim().replace('@', ''); if (cleanUser) keyboard.push([{ text: `💬 Chat with ${cleanUser}`, url: `https://t.me/${cleanUser}` }]); }); 
            if (keyboard.length > 0) bot.sendMessage(chatId, "🆘 **Select an Admin:**", { parse_mode: 'Markdown', reply_markup: { inline_keyboard: keyboard } }); 
            else bot.sendMessage(chatId, "⚠️ Contact not configured.");
            return;
        }

        // --- ADMIN PANEL ---
        if (text === "👮‍♂️ Admin Panel" && isAdmin(chatId)) {
            const servers = getServers();
            
            let keyboard = [
                [{ text: "📊 DATABASE (Total Stats)", callback_data: "admin_db" }],
                [{ text: "📂 ALL SERVERS (Show Keys)", callback_data: "admin_all" }],
                [{ text: "👥 Reseller Users", callback_data: "admin_resellers" }],
                [{ text: "💰 Reseller Topup", callback_data: "admin_topup" }]
            ];
            
            servers.forEach((s, idx) => {
                let sName = s.name || `Server ${idx + 1}`;
                keyboard.push([{ text: `🖥️ ${sName}`, callback_data: `admin_srv_${idx}` }]);
            });

            bot.sendMessage(chatId, "🎛 **Admin Control Panel**\n\nSelect an option to manage:", { parse_mode: 'Markdown', reply_markup: { inline_keyboard: keyboard } });
            return;
        }
    });

    bot.on('callback_query', async (q) => { 
        const chatId = q.message.chat.id; 
        const data = q.data; 
        const userFullName = `${q.from.first_name}`.trim();
        const adminName = q.from.first_name; 

        // --- TRIAL SERVER SELECTOR CALLBACK ---
        if (data.startsWith('trial_srv_')) {
            if (!TRIAL_ENABLED) return bot.sendMessage(chatId, "Trial Disabled.");
            if (claimedUsers.includes(chatId)) return bot.sendMessage(chatId, "Already claimed.");
            
            const serverIndex = parseInt(data.split('_')[2]);
            bot.sendMessage(chatId, "⏳ Creating Test Key...");
            try {
                const expireDate = getMyanmarDate(TRIAL_DAYS);
                const userFullName = `${q.from.first_name}`.trim(); 
                const username = q.from.username ? `#${q.from.username}` : '';
                const name = `TEST_${userFullName.replace(/\|/g, '').trim()} ${username} | ${expireDate}`; 
                const limitBytes = Math.floor(TRIAL_GB * 1024 * 1024 * 1024);
                
                const data = await createKeyOnServer(serverIndex, name, limitBytes);
                
                claimedUsers.push(chatId); fs.writeFileSync(CLAIM_FILE, JSON.stringify(claimedUsers));
                let finalUrl = formatAccessUrl(data.accessUrl, data._serverUrl); finalUrl += `#${encodeURIComponent(name.split('|')[0].trim())}`;
                
                bot.deleteMessage(chatId, q.message.message_id);
                bot.sendMessage(chatId, `🎉 <b>Free Trial Created!</b>\n\n👤 Name: ${userFullName}\n🖥️ Server: ${data._serverName}\n📅 Duration: ${TRIAL_DAYS} Days\n📦 Data: ${TRIAL_GB} GB\n📅 Expire: ${expireDate}\n\n🔗 <b>Key:</b>\n<code>${finalUrl}</code>`, { parse_mode: 'HTML' }); 
            } catch (e) { bot.sendMessage(chatId, "❌ Error creating test key."); }
            return;
        }

        // --- RESELLER FLOW ---
        if (data.startsWith('resell_buy_')) {
            const rUser = resellerSessions[chatId];
            if (!rUser) return bot.answerCallbackQuery(q.id, { text: "Session Expired. Login again.", show_alert: true });
            const planIdx = parseInt(data.split('_')[2]);
            const plansToUse = (config.reseller_plans && config.reseller_plans.length > 0) ? config.reseller_plans : config.plans;
            const p = plansToUse[planIdx];
            const reseller = resellers.find(r => r.username === rUser);
            if(parseInt(reseller.balance) < parseInt(p.price)) {
                return bot.answerCallbackQuery(q.id, { text: `⚠️ Insufficient Balance!\nNeed: ${p.price} Ks`, show_alert: true });
            }
            userStates[chatId] = { status: 'RESELLER_SELECT_SERVER', plan: p, reseller: rUser };
            bot.sendMessage(chatId, "🖥️ **Select Server:**", {
                parse_mode: 'Markdown',
                reply_markup: { inline_keyboard: getServerKeyboard('rsrv') }
            });
            return;
        }

        if (data.startsWith('rsrv_')) {
            const rUser = resellerSessions[chatId];
            if (!rUser) return bot.sendMessage(chatId, "❌ Session Expired.");
            
            const serverIndex = parseInt(data.split('_')[1]);
            if (!userStates[chatId] || userStates[chatId].status !== 'RESELLER_SELECT_SERVER') {
                 return bot.sendMessage(chatId, "❌ Flow Error. Please start over.");
            }
            userStates[chatId].serverIndex = serverIndex;
            userStates[chatId].status = 'RESELLER_ENTER_NAME';
            const p = userStates[chatId].plan;
            
            bot.deleteMessage(chatId, q.message.message_id);
            bot.sendMessage(chatId, `👤 **Enter Customer Name:**\n(Plan: ${p.days} Days / ${p.gb} GB)\n(Server Selected)`, { parse_mode: 'Markdown', reply_markup: { force_reply: true } });
            return;
        }

        // --- BUY PLAN FLOW ---
        if (data.startsWith('buy_') && !data.startsWith('buy_srv_')) { 
            const planIdx = parseInt(data.split('_')[1]);
            bot.sendMessage(chatId, "🖥️ **Select Server:**", {
                parse_mode: 'Markdown',
                reply_markup: { inline_keyboard: getServerKeyboard(`buy_srv_${planIdx}`) }
            });
            return;
        } 

        if (data.startsWith('buy_srv_')) {
            const parts = data.split('_');
            const planIdx = parseInt(parts[2]);
            const serverIdx = parseInt(parts[3]);
            const p = config.plans[planIdx];
            const servers = getServers();
            const sName = servers[serverIdx].name || "Server";

            let payTxt = ""; 
            if(config.payments) config.payments.forEach(pay => payTxt += `▪️ ${pay.name}: \`${pay.num}\` (${pay.owner})\n`); 
            
            userStates[chatId] = { 
                status: 'WAITING_SLIP', 
                plan: p, 
                name: userFullName, 
                type: 'NEW', 
                username: q.from.username,
                targetServerIndex: serverIdx,
                targetServerName: sName
            }; 
            
            bot.deleteMessage(chatId, q.message.message_id);
            bot.sendMessage(chatId, `✅ **Plan:** ${p.days} Days (${p.gb}GB)\n🖥️ **Server:** ${sName}\n💰 **Price:** ${p.price} Ks\n\n💸 **Payments:**\n${payTxt}\n⚠️ ငွေလွှဲပြီးပါက ပြေစာ (Screenshot) ပို့ပေးပါ။`, {parse_mode: 'Markdown'}); 
            return;
        }

        // --- ADMIN CALLBACKS ---
        if (isAdmin(chatId)) {
            if (data === 'admin_topup') {
                 if (!resellers || resellers.length === 0) return bot.sendMessage(chatId, "❌ No resellers found.");
                 let keyboard = [];
                 resellers.forEach(r => {
                    keyboard.push([{ text: `💰 ${r.username} (Bal: ${r.balance})`, callback_data: `rtop_${r.username}` }]);
                 });
                 bot.sendMessage(chatId, "💰 **Select Reseller to Topup:**", { parse_mode: 'Markdown', reply_markup: { inline_keyboard: keyboard } });
                 return;
            }

            if (data.startsWith('rtop_')) {
                const targetReseller = data.split('_')[1];
                userStates[chatId] = { status: 'ADMIN_TOPUP_AMOUNT', targetReseller: targetReseller };
                bot.sendMessage(chatId, `💰 **Enter Topup Amount for ${targetReseller}:**\n(Enter negative amount to deduct, e.g., -1000)`, { parse_mode: 'Markdown', reply_markup: { force_reply: true } });
                return;
            }

            if (data === 'admin_resellers') {
                if (!resellers || resellers.length === 0) return bot.sendMessage(chatId, "❌ No resellers registered.");
                let keyboard = [];
                resellers.forEach(r => {
                    keyboard.push([{ text: `👤 ${r.username} (${r.balance} Ks)`, callback_data: `admin_rlist_${r.username}` }]);
                });
                bot.sendMessage(chatId, "👥 **Select a Reseller:**", { parse_mode: 'Markdown', reply_markup: { inline_keyboard: keyboard } });
                return;
            }

            if (data.startsWith('admin_rlist_')) {
                const targetReseller = data.split('_')[2];
                bot.sendMessage(chatId, `🔎 Finding users for **${targetReseller}**...`, { parse_mode: 'Markdown' });
                try {
                    const keys = await getAllKeysFromAllServers(k => k.name.includes(`(R-${targetReseller})`));
                    keys.sort((a,b) => parseInt(a.id) - parseInt(b.id)); 
                    if (keys.length === 0) return bot.sendMessage(chatId, "❌ No users found for this reseller.");
                    let txt = `👤 **${targetReseller}'s Users (${keys.length})**\n\n`;
                    let kb = [];
                    keys.forEach(k => {
                        let name = k.name || "No Name";
                        let sName = k._serverName || "Srv";
                        txt += `🆔 ${k.id} (${sName}) : ${sanitizeText(name)}\n`;
                        let btnName = `[${sName}] ${name}`;
                        if(btnName.length > 25) btnName = btnName.substring(0,25)+"..";
                        kb.push([{ text: btnName, callback_data: `chk_${k.id}` }]);
                    });
                    bot.sendMessage(chatId, txt.substring(0, 4000), { parse_mode: 'Markdown', reply_markup: { inline_keyboard: kb.slice(0, 50) } });
                } catch(e) { bot.sendMessage(chatId, "Error fetching reseller keys."); }
                return;
            }

            if (data === 'admin_db') {
                bot.answerCallbackQuery(q.id, { text: "Calculating Stats..." });
                const servers = getServers();
                let totalKeys = 0;
                let totalBytes = 0;
                try {
                    const promises = servers.map(async (srv) => {
                        try {
                            const [kRes, mRes] = await Promise.all([
                                axiosClient.get(`${srv.url}/access-keys`),
                                axiosClient.get(`${srv.url}/metrics/transfer`)
                            ]);
                            return { keys: kRes.data.accessKeys.length, metrics: mRes.data.bytesTransferredByUserId };
                        } catch(e) { return { keys: 0, metrics: {} }; }
                    });
                    const results = await Promise.all(promises);
                    results.forEach(res => {
                        totalKeys += res.keys;
                        Object.values(res.metrics).forEach(bytes => totalBytes += bytes);
                    });
                    bot.sendMessage(chatId, `📊 **DATABASE STATISTICS**\n\n💾 **Total Servers:** ${servers.length}\n🔑 **Total Keys:** ${totalKeys}\n📡 **Total Traffic:** ${formatBytes(totalBytes)}`, { parse_mode: 'Markdown' });
                } catch(e) { bot.sendMessage(chatId, "❌ Error fetching stats."); }
                return;
            }

            if (data === 'admin_all') {
                bot.sendMessage(chatId, "⌛ Loading ALL Users..."); 
                try { 
                    const keys = await getAllKeysFromAllServers();
                    keys.sort((a,b) => parseInt(a.id) - parseInt(b.id)); 
                    let txt = `👥 **ALL USERS (${keys.length})**\n\n`; 
                    let kb = []; 
                    keys.forEach(k => { 
                        let name = k.name || "No Name"; 
                        txt += `🆔 ${k.id} : ${sanitizeText(name)}\n`; 
                        let btnName = `[${k._serverName}] ${name}`; 
                        if(btnName.length > 25) btnName = btnName.substring(0,25)+".."; 
                        kb.push([{ text: btnName, callback_data: `chk_${k.id}` }]); 
                    }); 
                    bot.sendMessage(chatId, txt.substring(0, 4000), { parse_mode: 'Markdown', reply_markup: { inline_keyboard: kb.slice(0, 50) } }); 
                } catch(e) { bot.sendMessage(chatId, "Error fetching list"); }
                return;
            }

            if (data.startsWith('admin_srv_')) {
                const srvIdx = parseInt(data.split('_')[2]);
                const servers = getServers();
                const targetSrv = servers[srvIdx];
                if (!targetSrv) return bot.sendMessage(chatId, "Server not found.");
                bot.sendMessage(chatId, `⌛ Loading users from **${targetSrv.name || 'Server'}**...`, { parse_mode: 'Markdown' });
                try {
                    const keys = await getKeysFromSpecificServer(srvIdx);
                    keys.sort((a,b) => parseInt(a.id) - parseInt(b.id));
                    let txt = `🖥️ **${targetSrv.name} (${keys.length})**\n\n`;
                    let kb = [];
                    keys.forEach(k => {
                        let name = k.name || "No Name"; 
                        txt += `🆔 ${k.id} : ${sanitizeText(name)}\n`; 
                        let btnName = `[${k.id}] ${name}`; 
                        if(btnName.length > 20) btnName = btnName.substring(0,20)+".."; 
                        kb.push([{ text: btnName, callback_data: `chk_${k.id}` }]); 
                    }); 
                    bot.sendMessage(chatId, txt.substring(0, 4000), { parse_mode: 'Markdown', reply_markup: { inline_keyboard: kb.slice(0, 50) } });
                } catch(e) { bot.sendMessage(chatId, "Error fetching keys from server."); }
                return;
            }

             if (data.startsWith('chk_')) { 
                const kid = data.split('_')[1]; 
                try { 
                    const result = await findKeyInAllServers(kid);
                    if(!result) return bot.sendMessage(chatId, "Key not found"); 
                    const { key, metrics, serverName } = result;
                    const usage = metrics.bytesTransferredByUserId[key.id] || 0; 
                    const limit = key.dataLimit ? key.dataLimit.bytes : 0; const remaining = limit > 0 ? limit - usage : 0; 
                    let cleanName = key.name; let expireDate = "N/A"; 
                    if (key.name.includes('|')) { const parts = key.name.split('|'); cleanName = parts[0].trim(); expireDate = parts[parts.length-1].trim(); } 
                    
                    // --- STATUS & BLOCK LOGIC (ADMIN VIEW) ---
                    let statusIcon = "🟢"; let statusText = "Active"; 
                    // Check if Blocked (Limit 0 or Name starts with 🔴)
                    if (limit === 0 || cleanName.startsWith("🔴")) { 
                        statusIcon = "🔴"; statusText = "Blocked/OFF"; 
                    } 
                    else if (isExpired(expireDate)) { statusIcon = "🔴"; statusText = "Expired"; } 
                    
                    let percent = limit > 0 ? Math.min((usage / limit) * 100, 100) : 0; const barLength = 10; const fill = Math.round((percent / 100) * barLength); const bar = "░".repeat(barLength).split('').map((c, i) => i < fill ? "█" : c).join(''); 
                    const msg = `👮 User Management\n---------------------\n👤 Name: ${cleanName}\n🖥️ Server: ${serverName}\n📡 Status: ${statusIcon} ${statusText}\n⏳ Remaining: ${getDaysRemaining(expireDate)}\n⬇️ Used: ${formatBytes(usage)}\n🎁 Free: ${limit ? formatBytes(remaining) : 'Unl'}\n📅 Expire: ${expireDate}\n\n${bar} ${percent.toFixed(1)}%`; 
                    bot.sendMessage(chatId, msg, { reply_markup: { inline_keyboard: [[{ text: "⏳ RENEW / EXTEND", callback_data: `adm_ext_${key.id}` }], [{ text: "🗑️ DELETE", callback_data: `del_${key.id}` }]] } }); 
                } catch(e) {} 
            } 
            if (data.startsWith('adm_ext_')) {
                const kid = data.split('_')[2];
                if (!config.plans || config.plans.length === 0) return bot.sendMessage(chatId, "❌ No public plans configured.");
                const keyboard = config.plans.map((p, i) => [{ text: `+${p.days} Days (${p.gb}GB)`, callback_data: `adm_renew_${kid}_${i}` }]);
                bot.sendMessage(chatId, "👮‍♂️ **Admin Renew: Select Plan**", { parse_mode: 'Markdown', reply_markup: { inline_keyboard: keyboard } });
            }
            if (data.startsWith('adm_renew_')) {
                const parts = data.split('_'); const keyId = parts[2]; const planIdx = parseInt(parts[3]); const p = config.plans[planIdx];
                try {
                    const result = await findKeyInAllServers(keyId);
                    if(!result) return bot.sendMessage(chatId, "Key not found");
                    const { key, serverUrl } = result;
                    let oldDateStr = key.name.split('|').pop().trim();
                    let newDate = isExpired(oldDateStr) ? getMyanmarDate(p.days) : moment(oldDateStr, "YYYY-MM-DD").add(p.days, 'days').format('YYYY-MM-DD');
                    const limitBytes = Math.floor(p.gb * 1024 * 1024 * 1024);
                    let cleanName = key.name.split('|')[0].trim();
                    
                    // Remove 🔴 prefix if renewing
                    cleanName = cleanName.replace(/^🔴\s*\[BLOCKED\]\s*/, '').replace(/^🔴\s*/, '');

                    await axiosClient.put(`${serverUrl}/access-keys/${keyId}/name`, { name: `${cleanName} | ${newDate}` });
                    await axiosClient.put(`${serverUrl}/access-keys/${keyId}/data-limit`, { limit: { bytes: limitBytes } });
                    bot.deleteMessage(chatId, q.message.message_id);
                    bot.sendMessage(chatId, `✅ **Admin Renew Success!**\n\n👤 User: ${cleanName}\n📅 New Expire: ${newDate}\n📦 Data: ${p.gb} GB`, { parse_mode: 'Markdown' });
                } catch(e) { bot.sendMessage(chatId, "❌ Error extending key."); }
            }
            if (data.startsWith('del_')) { 
                try {
                    const result = await findKeyInAllServers(data.split('_')[1]);
                    if(result) {
                        await axiosClient.delete(`${result.serverUrl}/access-keys/${result.key.id}`); 
                        bot.sendMessage(chatId, "✅ User Deleted."); 
                        bot.deleteMessage(chatId, q.message.message_id); 
                    } else { bot.sendMessage(chatId, "Key not found"); }
                } catch(e){}
            } 
            if (data.startsWith('approve_')) { 
                const buyerId = data.split('_')[1]; 
                if (!userStates[buyerId]) return bot.answerCallbackQuery(q.id, { text: "⚠️ Processed!", show_alert: true });
                const { plan, name, username, targetServerIndex } = userStates[buyerId]; 
                bot.editMessageCaption(`✅ Approved by ${adminName}`, { chat_id: chatId, message_id: q.message.message_id }); 
                ADMIN_IDS.forEach(aid => { if (String(aid) !== String(chatId)) bot.sendMessage(aid, `🔔 **ORDER APPROVED**\n\n👤 Customer: ${name}\n📦 Plan: ${plan.days}D / ${plan.gb}GB\n👮‍♂️ Action: **${adminName}**`, { parse_mode: 'Markdown' }); });
                try { 
                    const expireDate = getMyanmarDate(plan.days); 
                    const limit = plan.gb * 1024 * 1024 * 1024; 
                    let finalName = `${name.replace(/\|/g,'').trim()} #${username || ''} | ${expireDate}`; 
                    
                    const data = await createKeyOnServer(targetServerIndex, finalName, limit);
                    
                    let finalUrl = formatAccessUrl(data.accessUrl, data._serverUrl); finalUrl += `#${encodeURIComponent(finalName.split('|')[0].trim())}`;
                    bot.sendMessage(buyerId, `🎉 <b>Purchase Success!</b>\n\n👤 Name: ${name}\n🖥️ Server: ${data._serverName}\n📅 Expire: ${expireDate}\n\n🔗 <b>Key:</b>\n<code>${finalUrl}</code>`, { parse_mode: 'HTML' }); 
                    delete userStates[buyerId]; 
                } catch(e) { bot.sendMessage(ADMIN_IDS[0], "❌ Error creating key on selected server."); } 
            } 
            if (data.startsWith('reject_')) { 
                const buyerId = data.split('_')[1]; 
                if (!userStates[buyerId]) return bot.answerCallbackQuery(q.id, { text: "⚠️ Processed!", show_alert: true });
                const { name, plan } = userStates[buyerId];
                bot.sendMessage(buyerId, "❌ Your order was rejected."); 
                bot.editMessageCaption(`❌ Rejected by ${adminName}`, { chat_id: chatId, message_id: q.message.message_id }); 
                ADMIN_IDS.forEach(aid => { if (String(aid) !== String(chatId)) bot.sendMessage(aid, `🚫 **ORDER REJECTED**\n\n👤 Customer: ${name}\n📦 Plan: ${plan.days} Days\n👮‍♂️ Action: **${adminName}**`, { parse_mode: 'Markdown' }); });
                delete userStates[buyerId];
            } 
        } 

        // --- RESELLER ACTIONS ---
        if (data.startsWith('rchk_')) {
            const rUser = resellerSessions[chatId];
            if (!rUser) return bot.answerCallbackQuery(q.id, { text: "Session Expired.", show_alert: true });
            const keyId = data.split('_')[1];
            try { 
                const result = await findKeyInAllServers(keyId);
                if(!result) return bot.sendMessage(chatId, "⚠️ Key not found.");
                
                const { key, metrics, serverName } = result;
                if(!key.name.includes(`(R-${rUser})`)) return bot.sendMessage(chatId, "⚠️ Access Denied. Not your user.");

                const usage = metrics.bytesTransferredByUserId[key.id] || 0; 
                const limit = key.dataLimit ? key.dataLimit.bytes : 0; 
                let cleanName = key.name; let expireDate = "N/A"; 
                if (key.name.includes('|')) { const parts = key.name.split('|'); cleanName = parts[0].replace(`(R-${rUser})`,'').trim(); expireDate = parts[parts.length-1].trim(); } 
                
                let statusIcon = "🟢"; let statusText = "Active"; 
                if (limit === 0 || cleanName.startsWith("🔴")) { statusIcon = "🔴"; statusText = "Blocked/OFF"; } 
                else if (isExpired(expireDate)) { statusIcon = "🔴"; statusText = "Expired"; } 
                
                let percent = limit > 0 ? Math.min((usage / limit) * 100, 100) : 0; 
                const barLength = 10; const fill = Math.round((percent / 100) * barLength); 
                const bar = "█".repeat(fill) + "░".repeat(barLength - fill); 
                
                const msg = `⚙️ **User Management System**\n--------------------------------\n👤 **Name:** ${cleanName}\n🖥️ **Server:** ${serverName}\n📡 **Status:** ${statusIcon} ${statusText}\n⏳ **Remaining:** ${getDaysRemaining(expireDate)}\n⬇️ **Used:** ${formatBytes(usage)}\n🎁 **Limit:** ${limit ? formatBytes(limit) : 'Unlimited'}\n📅 **Expire:** ${expireDate}\n\n[${bar}] ${percent.toFixed(1)}%`;
                
                bot.sendMessage(chatId, msg, { parse_mode: 'Markdown', reply_markup: { inline_keyboard: [
                    [{ text: "⏳ Extend / Renew", callback_data: `rext_${key.id}` }], 
                    [{ text: "🗑️ Delete User", callback_data: `rdel_${key.id}` }]
                ] } }); 
            } catch(e) { bot.sendMessage(chatId, "Error fetching details"); }
        }

        if (data.startsWith('rdel_')) {
            const rUser = resellerSessions[chatId];
            if (!rUser) return bot.answerCallbackQuery(q.id, { text: "Session Expired.", show_alert: true });
            const keyId = data.split('_')[1];
            try {
                const result = await findKeyInAllServers(keyId);
                if(!result) return bot.sendMessage(chatId, "Key not found");
                const { key, serverUrl } = result;
                if(!key.name.includes(`(R-${rUser})`)) return bot.sendMessage(chatId, "Access Denied");
                await axiosClient.delete(`${serverUrl}/access-keys/${keyId}`); 
                bot.deleteMessage(chatId, q.message.message_id); 
                bot.sendMessage(chatId, "✅ User Deleted."); 
            } catch(e) { bot.sendMessage(chatId, "Delete Failed."); }
        }

        if (data.startsWith('rext_')) {
            const rUser = resellerSessions[chatId];
            if (!rUser) return bot.answerCallbackQuery(q.id, { text: "Session Expired.", show_alert: true });
            const keyId = data.split('_')[1];
            const plansToUse = (config.reseller_plans && config.reseller_plans.length > 0) ? config.reseller_plans : config.plans;
            const keyboard = plansToUse.map((p, i) => [{ text: `+${p.days} Days (${p.gb}GB) - ${p.price}Ks`, callback_data: `rxp_${keyId}_${i}` }]);
            bot.sendMessage(chatId, "📅 **Choose Extension Plan:**", { parse_mode: 'Markdown', reply_markup: { inline_keyboard: keyboard } });
        }

        if (data.startsWith('rxp_')) {
            const rUser = resellerSessions[chatId];
            if (!rUser) return bot.answerCallbackQuery(q.id, { text: "Session Expired.", show_alert: true });
            const parts = data.split('_'); const keyId = parts[1]; const planIdx = parseInt(parts[2]);
            const plansToUse = (config.reseller_plans && config.reseller_plans.length > 0) ? config.reseller_plans : config.plans;
            const p = plansToUse[planIdx];
            const resellerIdx = resellers.findIndex(r => r.username === rUser);
            if(resellers[resellerIdx].balance < parseInt(p.price)) return bot.answerCallbackQuery(q.id, { text: "⚠️ Insufficient Balance!", show_alert: true });
            try {
                const result = await findKeyInAllServers(keyId);
                if(!result) return bot.sendMessage(chatId, "Key not found");
                const { key, serverUrl } = result;
                let oldDateStr = key.name.split('|').pop().trim();
                let newDate = isExpired(oldDateStr) ? getMyanmarDate(p.days) : moment(oldDateStr, "YYYY-MM-DD").add(p.days, 'days').format('YYYY-MM-DD');
                resellers[resellerIdx].balance -= parseInt(p.price);
                fs.writeFileSync(RESELLER_FILE, JSON.stringify(resellers, null, 4));
                const limitBytes = Math.floor(p.gb * 1024 * 1024 * 1024);
                let cleanName = key.name.split('|')[0].trim();
                
                // Remove Blocked Prefix
                cleanName = cleanName.replace(/^🔴\s*\[BLOCKED\]\s*/, '').replace(/^🔴\s*/, '');

                await axiosClient.put(`${serverUrl}/access-keys/${keyId}/name`, { name: `${cleanName} | ${newDate}` });
                await axiosClient.put(`${serverUrl}/access-keys/${keyId}/data-limit`, { limit: { bytes: limitBytes } });
                bot.deleteMessage(chatId, q.message.message_id);
                bot.sendMessage(chatId, `✅ **Extension Successful!**\n\n👤 User: ${cleanName}\n📅 New Expire: ${newDate}\n📦 Data: ${p.gb} GB`, { parse_mode: 'Markdown' });
            } catch(e) { bot.sendMessage(chatId, "❌ Error extending key."); }
        }
    });

    bot.on('photo', (msg) => { 
        const chatId = msg.chat.id; 
        if (userStates[chatId] && userStates[chatId].status === 'WAITING_SLIP') { 
            const { plan, name, type, targetServerName } = userStates[chatId]; 
            bot.sendMessage(chatId, "📩 Slip Received. Please wait."); 
            ADMIN_IDS.forEach(adminId => { 
                bot.sendPhoto(adminId, msg.photo[msg.photo.length - 1].file_id, { 
                    caption: `💰 Order: ${name}\n📦 ${plan.days}D / ${plan.gb}GB\n🖥️ Server: ${targetServerName}\nType: ${type}`, 
                    reply_markup: { inline_keyboard: [[{ text: "✅ Approve", callback_data: `approve_${chatId}` }, { text: "❌ Reject", callback_data: `reject_${chatId}` }]] } 
                }).catch(e => {}); 
            }); 
        } 
    });

    // --- UPDATED GUARDIAN: STRICT EXPIRY + RENAME BLOCKING ---
    async function runGuardian() { 
        try { 
            const keys = await getAllKeysFromAllServers();
            const now = Date.now(); 
            const today = moment().tz("Asia/Yangon").startOf('day');

            for (const key of keys) { 
                const serverUrl = key._serverUrl; 
                const mRes = await axiosClient.get(`${serverUrl}/metrics/transfer`);
                const usage = mRes.data.bytesTransferredByUserId[key.id] || 0; 

                // Get Current Limit (If unlimited, limit is 0 or undefined)
                const limit = key.dataLimit ? key.dataLimit.bytes : 0; 
                
                let expireDateStr = null; 
                if (key.name.includes('|')) expireDateStr = key.name.split('|').pop().trim(); 
                
                const isTrial = key.name.startsWith("TEST_"); 
                const expiredStatus = isExpired(expireDateStr); 
                
                // If ALREADY BLOCKED (Name starts with 🔴 or Limit is 0 AND user is not Unlimited plan), skip logic
                // But we must enforce 0 limit if name is blocked
                if (key.name.startsWith("🔴") && limit !== 0) {
                     await axiosClient.put(`${serverUrl}/access-keys/${key.id}/data-limit`, { limit: { bytes: 0 } });
                     continue; 
                }
                if (key.name.startsWith("🔴") && limit === 0) continue; // Already handled

                // --- 1. TRIAL LOGIC ---
                // Trial expired or limit reached = DELETE
                if (isTrial && (expiredStatus || (limit > 0 && usage >= limit))) { 
                    await axiosClient.delete(`${serverUrl}/access-keys/${key.id}`); 
                    const reason = expiredStatus ? "Trial Expired" : "Trial Data Limit"; 
                    ADMIN_IDS.forEach(aid => bot.sendMessage(aid, `🗑️ **TRIAL DELETED**\n\n👤 Name: ${sanitizeText(key.name)}\n⚠️ Reason: ${reason}`, {parse_mode: 'Markdown'})); 
                    continue; 
                } 

                // --- 2. REGULAR USER LOGIC ---
                if (!isTrial) {
                    // === EXPIRED LOGIC (STRICT) ===
                    if (expiredStatus) {
                        const expireMoment = moment.tz(expireDateStr, "YYYY-MM-DD", "Asia/Yangon").startOf('day');
                        const daysPast = today.diff(expireMoment, 'days');

                        // If Expired > 20 Days -> Delete
                        if (daysPast >= 20) {
                            await axiosClient.delete(`${serverUrl}/access-keys/${key.id}`);
                            ADMIN_IDS.forEach(aid => bot.sendMessage(aid, `🗑️ **AUTO DELETED (>20 Days)**\n\n👤 Name: ${sanitizeText(key.name)}\n📅 Expired: ${expireDateStr}`, {parse_mode: 'Markdown'}));
                            continue;
                        } 
                        
                        // If Expired -> BLOCK (Rename + Limit 0)
                        if (!key.name.startsWith("🔴")) {
                            const newName = `🔴 [BLOCKED] ${key.name}`;
                            await axiosClient.put(`${serverUrl}/access-keys/${key.id}/name`, { name: newName });
                            await axiosClient.put(`${serverUrl}/access-keys/${key.id}/data-limit`, { limit: { bytes: 0 } });
                            ADMIN_IDS.forEach(aid => bot.sendMessage(aid, `🚫 **AUTO BLOCKED (Expired)**\n\n👤 Name: ${sanitizeText(key.name)}\n📉 Limit: 0 Bytes`, {parse_mode: 'Markdown'}));
                        }
                        continue;
                    }

                    // === DATA LIMIT LOGIC (Not Expired yet) ===
                    // If limit reached (and not unlimited), block logic
                    if (limit > 5000 && usage >= limit) { 
                        if (!key.name.startsWith("🔴")) {
                            const newName = `🔴 [BLOCKED] ${key.name}`;
                            await axiosClient.put(`${serverUrl}/access-keys/${key.id}/name`, { name: newName });
                            await axiosClient.put(`${serverUrl}/access-keys/${key.id}/data-limit`, { limit: { bytes: 0 } });
                            
                            if (!blockedRegistry[key.id]) { 
                                blockedRegistry[key.id] = now; 
                                fs.writeFileSync(BLOCKED_FILE, JSON.stringify(blockedRegistry)); 
                                const msg = `🚫 **AUTO BLOCKED (Data Full)**\n\n👤 Name: ${sanitizeText(key.name)}\n⬇️ Used: ${formatBytes(usage)}`; 
                                ADMIN_IDS.forEach(aid => bot.sendMessage(aid, msg, {parse_mode: 'Markdown'})); 
                            } 
                        }
                    } 
                }
            } 
        } catch (e) { console.log("Guardian Error", e.message); } 
    }
    // Set Interval to 5 Seconds (5000 ms)
    setInterval(runGuardian, 5000); 
}
EOF

# 6. Create frontend files (index.html)
echo -e "${YELLOW}Creating Frontend Files...${NC}"
cat << 'EOF' > /var/www/html/index.html
<!DOCTYPE html>
<html lang="my">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Outline Manager Pro</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://unpkg.com/lucide@latest"></script>
    <style>
        @import url('https://fonts.googleapis.com/css2?family=Inter:wght@300;400;600;700&display=swap');
        body { font-family: 'Inter', sans-serif; }
        .modal { transition: opacity 0.25s ease; }
        ::-webkit-scrollbar { width: 6px; height: 6px; }
        ::-webkit-scrollbar-track { background: #f1f5f9; }
        ::-webkit-scrollbar-thumb { background: #cbd5e1; border-radius: 3px; }
        .tab-btn.active { background-color: #4f46e5; color: white; box-shadow: 0 4px 6px -1px rgba(79, 70, 229, 0.2); }
        .tab-btn:not(.active) { color: #64748b; background-color: transparent; }
        .tab-btn:not(.active):hover { color: #334155; background-color: #f1f5f9; }
    </style>
</head>
<body class="bg-slate-100 min-h-screen text-slate-800">

    <nav class="bg-slate-900 text-white shadow-lg sticky top-0 z-40">
        <div class="max-w-7xl mx-auto px-4 py-4 flex justify-between items-center">
            <div class="flex items-center space-x-3">
                <div class="bg-indigo-600 p-2 rounded-lg shadow-lg shadow-indigo-900/50">
                    <i data-lucide="shield-check" class="w-6 h-6 text-white"></i>
                </div>
                <div>
                    <h1 class="text-xl font-bold tracking-tight">Outline Manager</h1>
                    <p class="text-[10px] text-slate-400 uppercase tracking-widest font-semibold">Multi-Server Edition</p>
                </div>
            </div>
            <div id="nav-status" class="hidden flex items-center space-x-3">
                <button onclick="openSettingsModal()" class="p-2 text-slate-300 hover:text-white hover:bg-slate-800 rounded-lg transition border border-slate-700" title="Settings">
                    <i data-lucide="settings" class="w-5 h-5"></i>
                </button>
                <button onclick="disconnect()" class="p-2 text-red-400 hover:text-red-300 hover:bg-red-900/30 rounded-lg transition border border-slate-700" title="Logout">
                    <i data-lucide="log-out" class="w-5 h-5"></i>
                </button>
            </div>
        </div>
    </nav>

    <main class="max-w-7xl mx-auto px-4 py-8">
        <div id="login-section" class="max-w-lg mx-auto mt-16">
            <div class="bg-white rounded-2xl shadow-xl p-8 border border-slate-200">
                <div class="text-center mb-8">
                    <div class="w-16 h-16 bg-slate-50 rounded-full flex items-center justify-center mx-auto mb-4 border border-slate-100">
                        <i data-lucide="server" class="w-8 h-8 text-indigo-600"></i>
                    </div>
                    <h2 class="text-2xl font-bold text-slate-800">Panel Login</h2>
                    <p class="text-slate-500 mt-2 text-sm">Enter one of your API URLs to authenticate</p>
                </div>
                <form onsubmit="connectServer(event)" class="space-y-4">
                    <div>
                        <label class="block text-xs font-bold text-slate-500 uppercase mb-1 ml-1">Any API URL</label>
                        <input type="password" id="login-api-url" class="w-full p-3 border border-slate-300 rounded-xl focus:ring-2 focus:ring-indigo-500 outline-none transition font-mono text-sm" placeholder="https://1.2.3.4:xxxxx/SecretKey..." required>
                    </div>
                    <button type="submit" id="connect-btn" class="w-full bg-indigo-600 hover:bg-indigo-700 text-white py-3.5 rounded-xl font-bold shadow-lg shadow-indigo-200 transition flex justify-center items-center">
                        Connect
                    </button>
                </form>
            </div>
        </div>

        <div id="dashboard" class="hidden space-y-8">
            <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
                <div class="bg-white p-5 rounded-2xl shadow-sm border border-slate-200">
                    <div class="flex items-center justify-between mb-2">
                        <div><p class="text-slate-500 text-xs font-bold uppercase tracking-wider">Total Keys</p><h3 class="text-3xl font-bold text-slate-800 mt-1" id="total-keys">0</h3></div>
                        <div class="p-3 bg-indigo-50 text-indigo-600 rounded-xl"><i data-lucide="users" class="w-6 h-6"></i></div>
                    </div>
                    <div id="server-breakdown" class="pt-3 border-t border-slate-100 space-y-1">
                        <div class="text-center text-xs text-slate-400">Loading Stats...</div>
                    </div>
                </div>
                
                <div class="bg-white p-6 rounded-2xl shadow-sm border border-slate-200 flex items-center justify-between">
                    <div><p class="text-slate-500 text-xs font-bold uppercase tracking-wider">Total Traffic</p><h3 class="text-3xl font-bold text-slate-800 mt-1" id="total-usage">0 GB</h3></div>
                    <div class="p-3 bg-emerald-50 text-emerald-600 rounded-xl"><i data-lucide="activity" class="w-6 h-6"></i></div>
                </div>
                <button onclick="openCreateModal()" class="bg-slate-900 p-6 rounded-2xl shadow-lg shadow-slate-300 flex items-center justify-center space-x-3 hover:bg-indigo-700 transition transform hover:-translate-y-1">
                    <div class="p-2 bg-white/10 rounded-lg"><i data-lucide="plus" class="w-6 h-6 text-white"></i></div>
                    <span class="text-white font-bold text-lg">Create New Key</span>
                </button>
            </div>

            <div>
                <div class="flex items-center justify-between mb-6">
                    <div class="flex items-center gap-4">
                        <h3 class="text-lg font-bold text-slate-800 flex items-center"><i data-lucide="list-filter" class="w-5 h-5 mr-2 text-slate-400"></i> Active Keys</h3>
                        <select id="server-filter" onchange="applyFilter()" class="bg-white border border-slate-300 text-slate-700 text-sm rounded-lg focus:ring-indigo-500 focus:border-indigo-500 block p-2 outline-none">
                            <option value="all">All Servers</option>
                        </select>
                    </div>
                    <span id="server-count-badge" class="text-xs bg-slate-200 px-2 py-1 rounded text-slate-600 font-bold">0 Servers</span>
                </div>
                <div id="keys-list" class="grid grid-cols-1 lg:grid-cols-2 gap-6"></div>
            </div>
        </div>
    </main>

    <div id="settings-overlay" class="fixed inset-0 bg-slate-900/60 hidden z-[60] flex items-center justify-center backdrop-blur-sm opacity-0 modal">
        <div class="bg-white rounded-2xl shadow-2xl w-full max-w-2xl transform transition-all scale-95 flex flex-col max-h-[90vh]" id="settings-content">
            <div class="p-5 border-b border-slate-100 flex justify-between items-center bg-slate-50 rounded-t-2xl">
                <h3 class="text-lg font-bold text-slate-800 flex items-center"><i data-lucide="sliders" class="w-5 h-5 mr-2 text-indigo-600"></i> System Settings</h3>
                <button onclick="closeSettingsModal()" class="p-1 text-slate-400 hover:text-slate-600 hover:bg-slate-200 rounded-lg transition"><i data-lucide="x" class="w-5 h-5"></i></button>
            </div>
            <div class="p-6 overflow-y-auto bg-slate-50/30 flex-1">
                <div id="settings-loader" class="text-center py-10 hidden"><span class="animate-pulse font-bold text-indigo-600">Loading Config from VPS...</span></div>
                
                <div id="settings-body" class="hidden">
                    <div class="flex space-x-1 mb-6 bg-slate-100 p-1 rounded-xl overflow-x-auto shadow-inner">
                        <button onclick="switchTab('server')" id="tab-btn-server" class="tab-btn flex-1 py-2 px-3 rounded-lg text-sm font-bold transition flex items-center justify-center whitespace-nowrap"><i data-lucide="server" class="w-4 h-4 mr-2"></i> Server</button>
                        <button onclick="switchTab('bot')" id="tab-btn-bot" class="tab-btn flex-1 py-2 px-3 rounded-lg text-sm font-bold transition flex items-center justify-center whitespace-nowrap"><i data-lucide="message-circle" class="w-4 h-4 mr-2"></i> Bot Config</button>
                        <button onclick="switchTab('reseller')" id="tab-btn-reseller" class="tab-btn flex-1 py-2 px-3 rounded-lg text-sm font-bold transition flex items-center justify-center whitespace-nowrap"><i data-lucide="briefcase" class="w-4 h-4 mr-2"></i> Reseller</button>
                        <button onclick="switchTab('plans')" id="tab-btn-plans" class="tab-btn flex-1 py-2 px-3 rounded-lg text-sm font-bold transition flex items-center justify-center whitespace-nowrap"><i data-lucide="shopping-cart" class="w-4 h-4 mr-2"></i> Shop & Plans</button>
                    </div>

                    <div id="tab-content-server" class="tab-content space-y-6">
                        <div class="bg-white p-5 rounded-xl border border-slate-200 shadow-sm space-y-4">
                            <h4 class="text-xs font-bold text-indigo-600 uppercase tracking-wider flex items-center"><i data-lucide="network" class="w-4 h-4 mr-2"></i> Outline API Configuration</h4>
                            <div class="flex flex-col gap-3 mb-3 bg-indigo-50/50 p-3 rounded-lg border border-indigo-100">
                                <input type="text" id="new-server-name" class="w-full p-2 border border-indigo-200 rounded-lg text-sm outline-none" placeholder="Server Name (e.g. SG1)">
                                <input type="password" id="new-server-url" class="w-full p-2 border border-indigo-200 rounded-lg text-sm outline-none font-mono" placeholder="API URL (https://...)">
                                <button onclick="addServer()" class="w-full bg-indigo-600 text-white px-3 py-2 rounded-lg text-sm font-bold shadow-md hover:bg-indigo-700">Add Server</button>
                            </div>
                            <div id="server-list-container" class="space-y-2"></div>
                             <div class="mt-4 bg-yellow-50 p-3 rounded-lg border border-yellow-200">
                                <label class="block text-xs font-bold text-yellow-700 uppercase mb-1">Web Panel Port</label>
                                <input type="number" id="conf-panel-port" class="w-full p-2 border border-yellow-300 rounded-lg text-sm font-mono" placeholder="80">
                            </div>
                        </div>

                        <div class="bg-white p-5 rounded-xl border border-slate-200 shadow-sm space-y-4">
                            <h4 class="text-xs font-bold text-slate-500 uppercase flex items-center"><i data-lucide="globe" class="w-4 h-4 mr-2"></i> Domain Mappings</h4>
                            <div class="flex flex-col md:flex-row gap-2 mb-3">
                                <input type="text" id="map-ip" class="flex-1 p-2 border border-slate-300 rounded-lg text-sm font-mono" placeholder="IP Address">
                                <input type="text" id="map-domain" class="flex-1 p-2 border border-slate-300 rounded-lg text-sm font-mono" placeholder="Domain">
                                <button onclick="addDomainMap()" class="bg-indigo-600 text-white px-4 py-2 rounded-lg text-sm font-bold">Add</button>
                            </div>
                            <div id="domain-map-list" class="space-y-2"></div>
                        </div>
                    </div>

                    <div id="tab-content-bot" class="tab-content hidden space-y-6">
                         <div class="bg-white p-5 rounded-xl border border-slate-200 shadow-sm space-y-4">
                            <h4 class="text-xs font-bold text-indigo-600 uppercase tracking-wider"><i data-lucide="settings" class="w-4 h-4 mr-2 inline"></i> Core Settings</h4>
                            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                                <div><label class="block text-xs font-bold text-slate-500 uppercase mb-1">Bot Token</label><input type="text" id="conf-bot-token" class="w-full p-2 border border-slate-300 rounded-lg text-sm font-mono"></div>
                                <div><label class="block text-xs font-bold text-slate-500 uppercase mb-1">Admin ID</label><input type="text" id="conf-tg-id" class="w-full p-2 border border-slate-300 rounded-lg text-sm font-mono"></div>
                                <div class="md:col-span-2"><label class="block text-xs font-bold text-slate-500 uppercase mb-1">Admin Usernames</label><input type="text" id="conf-admin-user" class="w-full p-2 border border-slate-300 rounded-lg text-sm font-mono" placeholder="user1, user2"></div>
                            </div>
                             <div>
                                <label class="block text-xs font-bold text-slate-500 uppercase mb-1">Welcome Message</label>
                                <textarea id="conf-welcome" class="w-full p-2 border border-slate-300 rounded-lg text-sm font-mono" rows="3"></textarea>
                            </div>
                        </div>
                        
                         <div class="bg-white p-5 rounded-xl border border-slate-200 shadow-sm space-y-4">
                             <h4 class="text-xs font-bold text-slate-500 uppercase mb-2">Bot Buttons</h4>
                             <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
                                <input type="text" id="btn-trial" class="p-2 border border-slate-300 rounded-lg text-sm" placeholder="Trial Btn">
                                <input type="text" id="btn-buy" class="p-2 border border-slate-300 rounded-lg text-sm" placeholder="Buy Btn">
                                <input type="text" id="btn-mykey" class="p-2 border border-slate-300 rounded-lg text-sm" placeholder="My Key Btn">
                                <input type="text" id="btn-info" class="p-2 border border-slate-300 rounded-lg text-sm" placeholder="Info Btn">
                                <input type="text" id="btn-support" class="p-2 border border-slate-300 rounded-lg text-sm" placeholder="Support Btn">
                                <input type="text" id="btn-reseller" class="p-2 border border-slate-300 rounded-lg text-sm" placeholder="Reseller Btn">
                            </div>
                            <h5 class="text-xs font-bold text-purple-600 uppercase mt-4 mb-2">Reseller Buttons</h5>
                            <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
                                <input type="text" id="btn-resell-buy" class="p-2 border border-purple-200 rounded-lg text-sm bg-purple-50" placeholder="Buy Stock Btn">
                                <input type="text" id="btn-resell-create" class="p-2 border border-purple-200 rounded-lg text-sm bg-purple-50" placeholder="Create User Btn">
                                <input type="text" id="btn-resell-users" class="p-2 border border-purple-200 rounded-lg text-sm bg-purple-50" placeholder="My Users Btn">
                                <input type="text" id="btn-resell-extend" class="p-2 border border-purple-200 rounded-lg text-sm bg-purple-50" placeholder="Extend User Btn">
                                <input type="text" id="btn-resell-logout" class="p-2 border border-purple-200 rounded-lg text-sm bg-purple-50" placeholder="Logout Btn">
                            </div>
                         </div>
                    </div>

                    <div id="tab-content-reseller" class="tab-content hidden space-y-6">
                        <div class="bg-white p-5 rounded-xl border-l-4 border-purple-500 shadow-sm">
                            <div class="flex items-center justify-between mb-4">
                                 <h4 class="text-xs font-bold text-purple-600 uppercase tracking-wider flex items-center"><i data-lucide="users" class="w-4 h-4 mr-2"></i> Manage Resellers</h4>
                            </div>
                            <div class="flex flex-col md:flex-row gap-2 mb-4 bg-purple-50/50 p-3 rounded-lg border border-purple-100">
                                <input type="text" id="resell-user" class="flex-1 p-2 border border-purple-200 rounded-lg text-sm outline-none" placeholder="Username">
                                <input type="text" id="resell-pass" class="flex-1 p-2 border border-purple-200 rounded-lg text-sm outline-none" placeholder="Password">
                                <input type="number" id="resell-bal" class="flex-1 p-2 border border-purple-200 rounded-lg text-sm outline-none" placeholder="Balance (Ks)">
                                <button onclick="addReseller()" id="btn-add-reseller" class="bg-purple-600 hover:bg-purple-700 text-white px-4 py-2 rounded-lg text-sm font-bold shadow-md transition w-24">Add</button>
                            </div>
                            <div id="reseller-list" class="space-y-2"></div>
                        </div>

                         <div class="bg-white p-5 rounded-xl border border-slate-200 shadow-sm">
                             <h4 class="text-xs font-bold text-purple-600 uppercase tracking-wider mb-4"><i data-lucide="tag" class="w-4 h-4 mr-2 inline"></i> Reseller Plans</h4>
                             <div class="flex gap-2 mb-4 bg-white p-2 rounded-lg border border-purple-200">
                                <div class="w-1/4"><input type="number" id="rplan-days" class="w-full p-2 border border-purple-100 rounded-lg text-sm text-center outline-none" placeholder="Days"></div>
                                <div class="w-1/4"><input type="text" id="rplan-gb" class="w-full p-2 border border-purple-100 rounded-lg text-sm text-center outline-none" placeholder="GB"></div>
                                <div class="flex-1"><input type="number" id="rplan-price" class="w-full p-2 border border-purple-100 rounded-lg text-sm text-center outline-none" placeholder="Reseller Price"></div>
                                <button onclick="addResellerPlan()" class="bg-purple-600 hover:bg-purple-700 text-white px-4 py-2 rounded-lg text-sm font-bold shadow-md transition">Add</button>
                            </div>
                            <div id="rplan-list" class="grid grid-cols-1 gap-2"></div>
                        </div>
                    </div>

                    <div id="tab-content-plans" class="tab-content hidden space-y-6">
                        <div class="bg-white p-5 rounded-xl border border-slate-200 shadow-sm">
                            <h4 class="text-xs font-bold text-blue-600 uppercase tracking-wider mb-4 flex items-center"><i data-lucide="package" class="w-4 h-4 mr-2"></i> User VPN Plans</h4>
                            <div class="flex gap-2 mb-4 bg-blue-50/50 p-3 rounded-lg border border-blue-100">
                                <div class="w-1/4"><input type="number" id="plan-days" class="w-full p-2 border border-blue-200 rounded-lg text-sm text-center outline-none" placeholder="Days"></div>
                                <div class="w-1/4"><input type="text" id="plan-gb" class="w-full p-2 border border-blue-200 rounded-lg text-sm text-center outline-none" placeholder="GB"></div>
                                <div class="flex-1"><input type="number" id="plan-price" class="w-full p-2 border border-blue-200 rounded-lg text-sm text-center outline-none" placeholder="Price"></div>
                                <button onclick="addPlan()" class="bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-lg text-sm font-bold shadow-md transition">Add</button>
                            </div>
                            <div id="plan-list" class="grid grid-cols-1 gap-2"></div>
                        </div>

                         <div class="bg-white p-5 rounded-xl border border-slate-200 shadow-sm">
                            <h4 class="text-xs font-bold text-emerald-600 uppercase tracking-wider mb-4 flex items-center"><i data-lucide="credit-card" class="w-4 h-4 mr-2"></i> Payment Methods</h4>
                            <div class="flex flex-col md:flex-row gap-2 mb-4 bg-emerald-50/50 p-3 rounded-lg border border-emerald-100">
                                <input type="text" id="pay-name" class="flex-1 p-2 border border-emerald-200 rounded-lg text-sm outline-none" placeholder="Wallet">
                                <input type="text" id="pay-num" class="flex-1 p-2 border border-emerald-200 rounded-lg text-sm outline-none" placeholder="Number">
                                <input type="text" id="pay-owner" class="flex-1 p-2 border border-emerald-200 rounded-lg text-sm outline-none" placeholder="Owner">
                                <button onclick="addPayment()" class="bg-emerald-600 hover:bg-emerald-700 text-white px-4 py-2 rounded-lg text-sm font-bold shadow-md transition">Add</button>
                            </div>
                            <div id="payment-list" class="space-y-2"></div>
                        </div>

                        <div class="border border-slate-200 p-3 rounded-lg bg-indigo-50/50">
                            <div class="flex items-center justify-between mb-3">
                                <div class="flex items-center">
                                    <div class="bg-indigo-100 p-2 rounded-lg mr-3 text-indigo-600"><i data-lucide="gift" class="w-5 h-5"></i></div>
                                    <div><p class="text-sm font-bold text-slate-800">Free Trial Settings</p></div>
                                </div>
                                <input type="checkbox" id="conf-trial" class="w-5 h-5 text-indigo-600 rounded focus:ring-indigo-500 border-gray-300">
                            </div>
                            <div class="grid grid-cols-2 gap-4">
                                 <div><label class="block text-xs font-bold text-slate-500 uppercase mb-1">Trial Days</label><input type="number" id="conf-trial-days" class="w-full p-2 border border-slate-300 rounded-lg text-sm" placeholder="1"></div>
                                 <div><label class="block text-xs font-bold text-slate-500 uppercase mb-1">Trial GB</label><input type="number" id="conf-trial-gb" class="w-full p-2 border border-slate-300 rounded-lg text-sm" placeholder="1" step="0.1"></div>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
            <div class="p-5 border-t border-slate-100 bg-slate-50 rounded-b-2xl flex justify-between items-center">
                 <button onclick="copyPaymentInfo()" class="flex items-center text-sm font-bold text-slate-600 hover:text-indigo-600 px-3 py-2 rounded-lg hover:bg-indigo-50 transition"><i data-lucide="copy" class="w-4 h-4 mr-2"></i> Copy Info</button>
                <button onclick="saveGlobalSettings()" class="bg-slate-900 hover:bg-slate-800 text-white px-6 py-2.5 rounded-xl font-bold shadow-lg transition">Save & Restart</button>
            </div>
        </div>
    </div>

    <div id="modal-overlay" class="fixed inset-0 bg-slate-900/60 hidden z-50 flex items-center justify-center backdrop-blur-sm opacity-0 modal">
        <div class="bg-white rounded-2xl shadow-2xl w-full max-w-md transform transition-all scale-95" id="modal-content">
            <div class="p-6 border-b border-slate-100 flex justify-between items-center bg-slate-50/50 rounded-t-2xl">
                <h3 class="text-lg font-bold text-slate-800 flex items-center"><i data-lucide="key" class="w-5 h-5 mr-2 text-indigo-600"></i> Manage Key</h3>
                <button onclick="closeModal()" class="p-1 text-slate-400 hover:text-slate-600 hover:bg-slate-100 rounded-lg transition"><i data-lucide="x" class="w-5 h-5"></i></button>
            </div>
            <form id="key-form" class="p-6 space-y-5">
                <input type="hidden" id="key-id">
                <input type="hidden" id="key-server-url"> 
                <div>
                     <label class="block text-xs font-bold text-slate-500 uppercase mb-1 ml-1">Server (Create Only)</label>
                     <select id="server-select" class="w-full p-3 border border-slate-300 rounded-xl outline-none text-sm bg-slate-50">
                         </select>
                </div>

                <div><label class="block text-xs font-bold text-slate-500 uppercase mb-1 ml-1">Name</label><input type="text" id="key-name" class="w-full p-3 border border-slate-300 rounded-xl focus:ring-2 focus:ring-indigo-500 outline-none transition" placeholder="Username" required></div>
                <div id="topup-container" class="hidden">
                    <div class="bg-indigo-50 p-3 rounded-xl border border-indigo-100 flex items-center">
                        <input type="checkbox" id="topup-mode" class="w-5 h-5 text-indigo-600 rounded focus:ring-indigo-500 border-gray-300">
                        <label for="topup-mode" class="ml-3 block text-sm font-bold text-indigo-900">Reset & Top Up</label>
                    </div>
                </div>
                <div class="grid grid-cols-2 gap-4">
                    <div>
                        <label class="block text-xs font-bold text-slate-500 uppercase mb-1">Limit</label>
                        <div class="flex shadow-sm rounded-xl overflow-hidden border border-slate-300 focus-within:ring-2 focus-within:ring-indigo-500">
                            <input type="number" id="key-limit" class="w-full p-3 outline-none" placeholder="Unl" min="0.1" step="0.1">
                            <select id="key-unit" class="bg-slate-50 border-l border-slate-300 px-3 text-sm font-bold text-slate-600 outline-none"><option value="GB">GB</option><option value="MB">MB</option></select>
                        </div>
                    </div>
                    <div><label class="block text-xs font-bold text-slate-500 uppercase mb-1 ml-1">Expiry Date</label><input type="date" id="key-expire" class="w-full p-3 border border-slate-300 rounded-xl focus:ring-2 focus:ring-indigo-500 outline-none text-sm text-slate-600"></div>
                </div>
                <div class="pt-2"><button type="submit" id="save-btn" class="w-full bg-slate-900 hover:bg-indigo-700 text-white py-3.5 rounded-xl font-bold shadow-lg transition flex justify-center items-center">Save Key</button></div>
            </form>
        </div>
    </div>

    <div id="toast" class="fixed bottom-5 right-5 bg-slate-800 text-white px-6 py-4 rounded-xl shadow-2xl transform translate-y-24 transition-transform duration-300 flex items-center z-[70] max-w-sm border border-slate-700/50">
        <div id="toast-icon" class="mr-3 text-emerald-400"></div>
        <div><h4 class="font-bold text-sm" id="toast-title">Success</h4><p class="text-xs text-slate-300 mt-0.5" id="toast-msg">Completed.</p></div>
    </div>

    <script>
        let serverList = []; 
        let globalAllKeys = []; 
        let globalUsageMap = {};
        let refreshInterval;
        let payments = [], plans = [], resellerPlans = [], resellers = [], domainMap = [];
        let botToken = '', currentPort = 80;
        let editingResellerIndex = -1;

        const nodeApi = `${window.location.protocol}//${window.location.hostname}:3000/api`;

        document.addEventListener('DOMContentLoaded', () => {
            lucide.createIcons();
            if(localStorage.getItem('outline_connected') === 'true') {
                 document.getElementById('login-section').classList.add('hidden'); 
                 document.getElementById('dashboard').classList.remove('hidden'); 
                 document.getElementById('nav-status').classList.remove('hidden'); document.getElementById('nav-status').classList.add('flex');
                 fetchServerConfig().then(() => { startAutoRefresh(); });
            }
        });

        function switchTab(tabId) {
            document.querySelectorAll('.tab-content').forEach(el => el.classList.add('hidden'));
            document.querySelectorAll('.tab-btn.active').forEach(el => el.classList.remove('active'));
            document.getElementById('tab-content-' + tabId).classList.remove('hidden');
            document.getElementById('tab-btn-' + tabId).classList.add('active');
        }

        function showToast(title, msg, type = 'success') {
            const toast = document.getElementById('toast');
            const iconDiv = document.getElementById('toast-icon');
            document.getElementById('toast-title').textContent = title;
            document.getElementById('toast-msg').textContent = msg;
            let icon = 'check-circle'; let color = 'text-emerald-400';
            if(type === 'error') { icon = 'alert-circle'; color = 'text-red-400'; }
            else if (type === 'warn') { icon = 'shield-alert'; color = 'text-orange-400'; }
            iconDiv.innerHTML = `<i data-lucide="${icon}" class="w-5 h-5"></i>`;
            iconDiv.className = `mr-3 ${color}`;
            lucide.createIcons();
            toast.classList.remove('translate-y-24');
            setTimeout(() => toast.classList.add('translate-y-24'), 3000);
        }

        function formatAccessUrl(url, serverUrl) {
            if (!url) return url;
            try {
                const urlObj = new URL(url);
                const originalIp = urlObj.hostname;
                if (domainMap && domainMap.length > 0) {
                    const mapping = domainMap.find(m => m.ip === originalIp);
                    if (mapping && mapping.domain) return url.replace(originalIp, mapping.domain);
                }
                return url;
            } catch(e) { return url; }
        }

        async function fetchServerConfig() {
            try {
                const res = await fetch(`${nodeApi}/config`);
                if(!res.ok) throw new Error("Failed");
                const config = await res.json();
                
                let rawUrls = config.api_urls || [];
                serverList = [];
                rawUrls.forEach(item => {
                    if(typeof item === 'string') {
                        serverList.push({ name: "Server", url: item });
                    } else {
                        serverList.push(item);
                    }
                });
                renderServerList();
                updateFilterOptions(); 

                payments = config.payments || [];
                plans = config.plans || [];
                resellerPlans = config.reseller_plans || [];
                resellers = config.resellers || [];
                domainMap = config.domain_map || [];
                botToken = config.bot_token || '';
                currentPort = config.panel_port || 80;

                document.getElementById('conf-bot-token').value = config.bot_token || '';
                document.getElementById('conf-tg-id').value = config.admin_id || '';
                document.getElementById('conf-admin-user').value = config.admin_username || '';
                document.getElementById('conf-welcome').value = config.welcome_msg || '';
                document.getElementById('conf-panel-port').value = currentPort;
                document.getElementById('conf-trial').checked = config.trial_enabled !== false; 
                document.getElementById('conf-trial-days').value = config.trial_days || 1;
                document.getElementById('conf-trial-gb').value = config.trial_gb || 1;

                const btns = config.buttons || {};
                document.getElementById('btn-trial').value = btns.trial || "🆓 Free Trial (အစမ်းသုံးရန်)";
                document.getElementById('btn-buy').value = btns.buy || "🛒 Buy Key (ဝယ်ယူရန်)";
                document.getElementById('btn-mykey').value = btns.mykey || "🔑 My Key (မိမိ Key ရယူရန်)";
                document.getElementById('btn-info').value = btns.info || "👤 Account Info (အကောင့်စစ်ရန်)";
                document.getElementById('btn-support').value = btns.support || "🆘 Support (ဆက်သွယ်ရန်)";
                document.getElementById('btn-reseller').value = btns.reseller || "🤝 Reseller Login";
                
                // --- NEW RESELLER BUTTONS ---
                document.getElementById('btn-resell-buy').value = btns.resell_buy || "🛒 Buy Stock";
                document.getElementById('btn-resell-create').value = btns.resell_create || "📦 Create User Key";
                document.getElementById('btn-resell-users').value = btns.resell_users || "👥 My Users";
                document.getElementById('btn-resell-extend').value = btns.resell_extend || "⏳ Extend User";
                document.getElementById('btn-resell-logout').value = btns.resell_logout || "🔙 Logout Reseller";
                
                renderPayments(); renderPlans(); renderResellerPlans(); renderResellers(); renderDomainMap();
                
                document.getElementById('server-count-badge').innerText = `${serverList.length} Servers`;
                return true;
            } catch(e) { 
                showToast("Error", "Could not load config from VPS", "error"); 
                return false;
            }
        }

        function updateFilterOptions() {
            const select = document.getElementById('server-filter');
            select.innerHTML = '<option value="all">All Servers</option>';
            serverList.forEach(s => {
                const opt = document.createElement('option');
                opt.value = s.url;
                opt.text = s.name || "Server";
                select.appendChild(opt);
            });
        }

        function applyFilter() {
            const filterVal = document.getElementById('server-filter').value;
            let filteredKeys = [];
            let totalBytes = 0;

            if (filterVal === 'all') {
                filteredKeys = globalAllKeys;
            } else {
                filteredKeys = globalAllKeys.filter(k => k._serverUrl === filterVal);
            }

            filteredKeys.forEach(k => {
                const used = globalUsageMap[k.id] || 0; 
                totalBytes += used;
            });

            document.getElementById('total-keys').textContent = filteredKeys.length;
            document.getElementById('total-usage').textContent = formatBytes(totalBytes);
            
            renderDashboard(filteredKeys, globalUsageMap);
        }

        function disconnect() { localStorage.removeItem('outline_connected'); if(refreshInterval) clearInterval(refreshInterval); location.reload(); }
        
        async function connectServer(e) { 
            e.preventDefault(); 
            const inputUrl = document.getElementById('login-api-url').value.trim();
            const btn = document.getElementById('connect-btn'); const originalContent = btn.innerHTML; btn.innerHTML = `Connecting...`; btn.disabled = true;
            try {
                await fetch(`${inputUrl}/server`, { method: 'GET' }); 
                localStorage.setItem('outline_connected', 'true');
                document.getElementById('login-section').classList.add('hidden'); document.getElementById('dashboard').classList.remove('hidden'); document.getElementById('nav-status').classList.remove('hidden'); document.getElementById('nav-status').classList.add('flex');
                await fetchServerConfig();
                startAutoRefresh();
            } catch (error) { 
                showToast("Connection Failed", "Check URL & SSL. Ensure CORS is enabled if testing locally.", "error"); 
                btn.innerHTML = originalContent; btn.disabled = false; 
            }
        }
        
        function startAutoRefresh() { refreshData(); refreshInterval = setInterval(refreshData, 5000); }

        async function refreshData() {
            if(serverList.length === 0) return;
            let allKeys = [];
            
            const promises = serverList.map(async (srv) => {
                 try {
                     const url = srv.url;
                     const [keysRes, metricsRes] = await Promise.all([ fetch(`${url}/access-keys`), fetch(`${url}/metrics/transfer`) ]);
                     const keysData = await keysRes.json();
                     const metricsData = await metricsRes.json();
                     const keys = keysData.accessKeys.map(k => ({ ...k, _serverUrl: url }));
                     return { keys, metrics: metricsData.bytesTransferredByUserId };
                 } catch(e) { return null; }
            });

            const results = await Promise.all(promises);
            globalUsageMap = {}; 
            
            const breakdown = document.getElementById('server-breakdown');
            breakdown.innerHTML = '';

            results.forEach((res, idx) => {
                const srvName = serverList[idx].name || "Server " + (idx+1);
                
                if(res) {
                    allKeys = allKeys.concat(res.keys);
                    Object.entries(res.metrics).forEach(([k, v]) => { globalUsageMap[k] = v; });
                    
                    const count = res.keys.length;
                    breakdown.innerHTML += `
                        <div class="flex justify-between items-center text-xs">
                            <span class="font-medium text-slate-600 truncate max-w-[120px]" title="${srvName}">${srvName}</span>
                            <span class="font-bold bg-slate-100 px-2 py-0.5 rounded text-slate-700">${count}</span>
                        </div>
                    `;
                } else {
                    breakdown.innerHTML += `
                        <div class="flex justify-between items-center text-xs">
                            <span class="font-medium text-red-400 truncate max-w-[120px]" title="${srvName}">${srvName}</span>
                            <span class="font-bold bg-red-50 text-red-400 px-2 py-0.5 rounded">OFF</span>
                        </div>
                    `;
                }
            });
            
            globalAllKeys = allKeys; 
            applyFilter(); 
        }

        function formatBytes(bytes) { if (!bytes || bytes === 0) return '0 B'; const i = parseInt(Math.floor(Math.log(bytes) / Math.log(1024))); return (bytes / Math.pow(1024, i)).toFixed(2) + ' ' + ['B', 'KB', 'MB', 'GB', 'TB'][i]; }

        async function renderDashboard(keys, usageMap) {
            const list = document.getElementById('keys-list'); list.innerHTML = '';
            keys.sort((a,b) => parseInt(a.id) - parseInt(b.id));
            const today = new Date().toISOString().split('T')[0];

            for (const key of keys) {
                const serverUrl = key._serverUrl; 
                const usageOffset = parseInt(localStorage.getItem(`offset_${key.id}`) || '0');
                const rawLimit = key.dataLimit ? key.dataLimit.bytes : 0; 
                const rawUsage = usageMap[key.id] || 0;
                
                let displayUsed = Math.max(0, rawUsage - usageOffset); let displayLimit = 0; if (rawLimit > 0) displayLimit = Math.max(0, rawLimit - usageOffset);
                let displayName = key.name || 'No Name'; let rawName = displayName; let expireDate = null;
                if (displayName.includes('|')) { const parts = displayName.split('|'); rawName = parts[0].trim(); const potentialDate = parts[parts.length - 1].trim(); if (/^\d{4}-\d{2}-\d{2}$/.test(potentialDate)) expireDate = potentialDate; }
                const isBlocked = rawLimit > 0 && rawLimit <= 5000; let isExpired = expireDate && expireDate < today; let isDataExhausted = (rawLimit > 5000 && rawUsage >= rawLimit);
                
                let statusBadge, cardClass, progressBarColor, percentage = 0, switchState = true;
                if (isBlocked) { switchState = false; percentage = 100; progressBarColor = 'bg-slate-300'; cardClass = 'border-slate-200 bg-slate-50 opacity-90'; statusBadge = isExpired ? `<span class="text-xs font-bold text-slate-500">Expired</span>` : (isDataExhausted ? `<span class="text-xs font-bold text-red-500">Data Full</span>` : `<span class="text-xs font-bold text-slate-500">Disabled</span>`); }
                else { cardClass = 'border-slate-200 bg-white'; percentage = displayLimit > 0 ? Math.min((displayUsed / displayLimit) * 100, 100) : 5; progressBarColor = percentage > 90 ? 'bg-orange-500' : (displayLimit > 0 ? 'bg-indigo-500' : 'bg-emerald-500'); statusBadge = `<span class="text-xs font-bold text-emerald-600">Active</span>`; }

                let finalAccessUrl = formatAccessUrl(key.accessUrl, serverUrl); 
                if(key.name) finalAccessUrl = `${finalAccessUrl.split('#')[0]}#${encodeURIComponent(displayName)}`;
                let limitText = displayLimit > 0 ? formatBytes(displayLimit) : 'Unlimited';
                const serverUrlEnc = encodeURIComponent(serverUrl);

                const card = document.createElement('div');
                card.className = `rounded-2xl shadow-sm border p-5 hover:shadow-md transition-all ${cardClass}`;
                card.innerHTML = `
                    <div class="flex justify-between items-start mb-4">
                        <div class="flex items-center">
                            <div class="w-12 h-12 rounded-2xl ${isBlocked ? 'bg-slate-200 text-slate-500' : 'bg-indigo-50 text-indigo-600'} font-bold flex items-center justify-center mr-4 text-sm border border-black/5">${key.id}</div>
                            <div><h4 class="font-bold text-slate-800 text-lg leading-tight line-clamp-1">${rawName}</h4><div class="flex items-center gap-3 mt-1">${statusBadge} ${expireDate ? `<span class="text-xs text-slate-400 font-medium">${expireDate}</span>` : ''}</div></div>
                        </div>
                        <button onclick="toggleKey('${key.id}', ${isBlocked}, '${serverUrlEnc}')" class="relative w-12 h-7 rounded-full transition-colors focus:outline-none ${switchState ? 'bg-emerald-500' : 'bg-slate-300'}"><span class="inline-block w-5 h-5 transform rounded-full bg-white shadow transition-transform mt-1 ${switchState ? 'translate-x-6' : 'translate-x-1'}"></span></button>
                    </div>
                    <div class="mb-5"><div class="flex justify-between text-xs mb-1.5 font-bold text-slate-500 uppercase tracking-wider"><span>${formatBytes(displayUsed)}</span><span>${limitText}</span></div><div class="w-full bg-slate-100 rounded-full h-3 overflow-hidden"><div class="${progressBarColor} h-3 rounded-full transition-all duration-700" style="width: ${percentage}%"></div></div></div>
                    <div class="flex justify-between items-center pt-4 border-t border-slate-100">
                        <div class="flex space-x-2">
                            <button onclick="editKey('${key.id}', '${rawName.replace(/'/g, "\\'")}', '${expireDate || ''}', ${displayLimit}, '${serverUrlEnc}')" class="p-2 text-slate-400 hover:text-indigo-600 hover:bg-indigo-50 rounded-lg transition"><i data-lucide="settings-2" class="w-4 h-4"></i></button>
                            <button onclick="deleteKey('${key.id}', '${serverUrlEnc}')" class="p-2 text-slate-400 hover:text-red-600 hover:bg-red-50 rounded-lg transition"><i data-lucide="trash-2" class="w-4 h-4"></i></button>
                        </div>
                        <div class="flex space-x-2">
                             <button onclick="copyKey('${finalAccessUrl}')" class="flex items-center px-4 py-2 bg-slate-50 hover:bg-indigo-50 text-slate-600 hover:text-indigo-700 rounded-lg text-xs font-bold transition"><i data-lucide="copy" class="w-3 h-3 mr-2"></i> Copy</button>
                        </div>
                    </div>`;
                list.appendChild(card);
            }
            lucide.createIcons();
        }

        async function toggleKey(id, isBlocked, serverUrlEnc) { const url = decodeURIComponent(serverUrlEnc); try { if(isBlocked) await fetch(`${url}/access-keys/${id}/data-limit`, { method: 'DELETE' }); else await fetch(`${url}/access-keys/${id}/data-limit`, { method: 'PUT', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({ limit: { bytes: 1 } }) }); showToast(isBlocked ? "Enabled" : "Disabled", isBlocked ? "Key activated" : "Key blocked"); refreshData(); } catch(e) { showToast("Error", "Action failed", 'error'); } }
        async function deleteKey(id, serverUrlEnc) { const url = decodeURIComponent(serverUrlEnc); if(!confirm("Delete this key?")) return; try { await fetch(`${url}/access-keys/${id}`, { method: 'DELETE' }); localStorage.removeItem(`offset_${id}`); showToast("Deleted", "Key removed"); refreshData(); } catch(e) { showToast("Error", "Delete failed", 'error'); } }

        function addPayment() { const name = document.getElementById('pay-name').value.trim(); const num = document.getElementById('pay-num').value.trim(); const owner = document.getElementById('pay-owner').value.trim(); if(!name || !num) return showToast("Info Missing", "Name and Number required", "warn"); payments.push({ name, num, owner }); renderPayments(); document.getElementById('pay-name').value = ''; document.getElementById('pay-num').value = ''; document.getElementById('pay-owner').value = ''; }
        function removePayment(index) { payments.splice(index, 1); renderPayments(); }
        function renderPayments() { const list = document.getElementById('payment-list'); list.innerHTML = ''; if(payments.length === 0) list.innerHTML = '<div class="text-center text-slate-400 text-xs py-2">No payment methods added.</div>'; payments.forEach((p, idx) => { const item = document.createElement('div'); item.className = 'flex justify-between items-center bg-white p-3 rounded-lg border border-slate-100 shadow-sm'; item.innerHTML = `<div class="flex items-center space-x-3"><div class="bg-emerald-100 text-emerald-600 p-2 rounded-full"><i data-lucide="wallet" class="w-4 h-4"></i></div><div><p class="text-sm font-bold text-slate-800">${p.name}</p><p class="text-xs text-slate-500 font-mono">${p.num} ${p.owner ? `(${p.owner})` : ''}</p></div></div><button onclick="removePayment(${idx})" class="text-slate-300 hover:text-red-500"><i data-lucide="trash" class="w-4 h-4"></i></button>`; list.appendChild(item); }); lucide.createIcons(); }
        
        function addPlan() { const days = document.getElementById('plan-days').value; const gb = document.getElementById('plan-gb').value; const price = document.getElementById('plan-price').value; if(!days || !gb || !price) return showToast("Info Missing", "Fill all plan details", "warn"); plans.push({ days, gb, price }); renderPlans(); document.getElementById('plan-days').value = ''; document.getElementById('plan-gb').value = ''; document.getElementById('plan-price').value = ''; }
        function removePlan(index) { plans.splice(index, 1); renderPlans(); }
        function renderPlans() { const list = document.getElementById('plan-list'); list.innerHTML = ''; if(plans.length === 0) list.innerHTML = '<div class="text-center text-slate-400 text-xs py-2">No plans added.</div>'; plans.forEach((p, idx) => { const item = document.createElement('div'); item.className = 'flex justify-between items-center bg-white p-3 rounded-lg border border-slate-100 shadow-sm'; item.innerHTML = `<div class="flex items-center space-x-3 w-full"><div class="bg-blue-100 text-blue-600 p-2 rounded-full flex-shrink-0"><i data-lucide="zap" class="w-4 h-4"></i></div><div class="flex justify-between w-full pr-4"><div class="text-sm font-bold text-slate-800 w-1/3">${p.days} Days</div><div class="text-sm font-bold text-slate-600 w-1/3 text-center">${p.gb}</div><div class="text-sm font-bold text-emerald-600 w-1/3 text-right">${p.price} Ks</div></div></div><button onclick="removePlan(${idx})" class="text-slate-300 hover:text-red-500 flex-shrink-0"><i data-lucide="trash" class="w-4 h-4"></i></button>`; list.appendChild(item); }); lucide.createIcons(); }
        
        function addServer() {
            const name = document.getElementById('new-server-name').value.trim();
            const url = document.getElementById('new-server-url').value.trim();
            if(!url) return showToast("Missing", "API URL is required", "warn");
            serverList.push({ name: name || "Server", url: url });
            renderServerList();
            document.getElementById('new-server-name').value = '';
            document.getElementById('new-server-url').value = '';
        }
        function removeServer(index) { serverList.splice(index, 1); renderServerList(); }
        function renderServerList() {
            const list = document.getElementById('server-list-container'); list.innerHTML = '';
            if(serverList.length === 0) list.innerHTML = '<div class="text-center text-slate-400 text-xs py-2">No servers configured.</div>';
            serverList.forEach((s, idx) => {
                const item = document.createElement('div');
                item.className = 'flex justify-between items-center bg-white p-2 rounded-lg border border-slate-200 text-sm';
                let displayName = s.name || "Server";
                let displayUrl = s.url.substring(0, 25) + "...";
                item.innerHTML = `<div class="flex items-center gap-2 overflow-hidden"><span class="bg-indigo-100 text-indigo-700 px-2 py-0.5 rounded text-xs font-bold whitespace-nowrap">${displayName}</span><span class="font-mono text-slate-500 text-xs truncate" title="${s.url}">${displayUrl}</span></div><button onclick="removeServer(${idx})" class="text-red-400 hover:text-red-600 ml-2"><i data-lucide="trash" class="w-4 h-4"></i></button>`;
                list.appendChild(item);
            });
            lucide.createIcons();
        }

        function addDomainMap() {
            const ip = document.getElementById('map-ip').value.trim();
            const domain = document.getElementById('map-domain').value.trim();
            if(!ip || !domain) return showToast("Missing", "IP and Domain required", "warn");
            domainMap.push({ ip, domain });
            renderDomainMap();
            document.getElementById('map-ip').value = '';
            document.getElementById('map-domain').value = '';
        }
        function removeDomainMap(index) { domainMap.splice(index, 1); renderDomainMap(); }
        function renderDomainMap() {
             const list = document.getElementById('domain-map-list'); list.innerHTML = '';
             if(domainMap.length === 0) list.innerHTML = '<div class="text-center text-slate-400 text-xs py-2">No mappings added.</div>';
             domainMap.forEach((m, idx) => {
                 const item = document.createElement('div');
                 item.className = 'flex justify-between items-center bg-white p-2 rounded-lg border border-slate-200 text-sm';
                 item.innerHTML = `<div class="font-mono text-xs"><span class="text-indigo-600 font-bold">${m.ip}</span> <span class="text-slate-400">➜</span> <span class="font-bold text-slate-700">${m.domain}</span></div><button onclick="removeDomainMap(${idx})" class="text-red-400 hover:text-red-600"><i data-lucide="trash" class="w-4 h-4"></i></button>`;
                 list.appendChild(item);
             });
             lucide.createIcons();
        }

        function addResellerPlan() { const days = document.getElementById('rplan-days').value; const gb = document.getElementById('rplan-gb').value; const price = document.getElementById('rplan-price').value; if(!days || !gb || !price) return showToast("Info Missing", "Fill all plan details", "warn"); resellerPlans.push({ days, gb, price }); renderResellerPlans(); document.getElementById('rplan-days').value = ''; document.getElementById('rplan-gb').value = ''; document.getElementById('rplan-price').value = ''; }
        function removeResellerPlan(index) { resellerPlans.splice(index, 1); renderResellerPlans(); }
        function renderResellerPlans() { const list = document.getElementById('rplan-list'); list.innerHTML = ''; if(resellerPlans.length === 0) list.innerHTML = '<div class="text-center text-slate-400 text-xs py-2">No reseller plans added.</div>'; resellerPlans.forEach((p, idx) => { const item = document.createElement('div'); item.className = 'flex justify-between items-center bg-purple-50 p-3 rounded-lg border border-purple-100 shadow-sm'; item.innerHTML = `<div class="flex items-center space-x-3 w-full"><div class="bg-purple-100 text-purple-600 p-2 rounded-full flex-shrink-0"><i data-lucide="tag" class="w-4 h-4"></i></div><div class="flex justify-between w-full pr-4"><div class="text-sm font-bold text-slate-800 w-1/3">${p.days} Days</div><div class="text-sm font-bold text-slate-600 w-1/3 text-center">${p.gb}</div><div class="text-sm font-bold text-purple-600 w-1/3 text-right">${p.price} Ks</div></div></div><button onclick="removeResellerPlan(${idx})" class="text-slate-300 hover:text-red-500 flex-shrink-0"><i data-lucide="trash" class="w-4 h-4"></i></button>`; list.appendChild(item); }); lucide.createIcons(); }
        function addReseller() { const u = document.getElementById('resell-user').value.trim(); const p = document.getElementById('resell-pass').value.trim(); const b = document.getElementById('resell-bal').value.trim(); if(!u || !p || !b) return showToast("Missing", "All fields required", "warn"); if (editingResellerIndex > -1) { resellers[editingResellerIndex] = { username: u, password: p, balance: parseInt(b) }; editingResellerIndex = -1; document.getElementById('btn-add-reseller').innerText = "Add"; showToast("Updated", "Reseller updated successfully"); } else { resellers.push({ username: u, password: p, balance: parseInt(b) }); showToast("Added", "Reseller added"); } renderResellers(); document.getElementById('resell-user').value = ''; document.getElementById('resell-pass').value = ''; document.getElementById('resell-bal').value = ''; }
        function editReseller(index) { const r = resellers[index]; document.getElementById('resell-user').value = r.username; document.getElementById('resell-pass').value = r.password; document.getElementById('resell-bal').value = r.balance; editingResellerIndex = index; document.getElementById('btn-add-reseller').innerText = "Update"; }
        function removeReseller(index) { if(!confirm("Delete this reseller?")) return; resellers.splice(index, 1); renderResellers(); if(index === editingResellerIndex) { editingResellerIndex = -1; document.getElementById('btn-add-reseller').innerText = "Add"; document.getElementById('resell-user').value = ''; document.getElementById('resell-pass').value = ''; document.getElementById('resell-bal').value = ''; } }
        function renderResellers() { const list = document.getElementById('reseller-list'); list.innerHTML = ''; if(resellers.length === 0) list.innerHTML = '<div class="text-center text-slate-400 text-xs py-2">No resellers added.</div>'; resellers.forEach((r, idx) => { const item = document.createElement('div'); item.className = 'flex justify-between items-center bg-white p-3 rounded-lg border border-slate-100 shadow-sm'; item.innerHTML = `<div class="flex items-center space-x-3"><div class="bg-purple-100 text-purple-600 p-2 rounded-full"><i data-lucide="user-check" class="w-4 h-4"></i></div><div><p class="text-sm font-bold text-slate-800">${r.username}</p><p class="text-xs text-slate-500 font-mono">Pass: ${r.password} | Bal: <span class="text-emerald-600 font-bold">${r.balance} Ks</span></p></div></div><div class="flex space-x-1"><button onclick="editReseller(${idx})" class="p-2 text-slate-400 hover:text-indigo-600 hover:bg-indigo-50 rounded-lg transition" title="Edit/Topup"><i data-lucide="pencil" class="w-4 h-4"></i></button><button onclick="removeReseller(${idx})" class="p-2 text-slate-400 hover:text-red-500 hover:bg-red-50 rounded-lg transition" title="Delete"><i data-lucide="trash" class="w-4 h-4"></i></button></div>`; list.appendChild(item); }); lucide.createIcons(); }

        const settingsOverlay = document.getElementById('settings-overlay'); const settingsContent = document.getElementById('settings-content');
        
        async function openSettingsModal() { 
            settingsOverlay.classList.remove('hidden'); 
            setTimeout(() => { settingsOverlay.classList.remove('opacity-0'); settingsContent.classList.remove('scale-95'); }, 10);
            document.getElementById('settings-loader').classList.remove('hidden');
            document.getElementById('settings-body').classList.add('hidden');
            await fetchServerConfig();
            document.getElementById('settings-loader').classList.add('hidden');
            document.getElementById('settings-body').classList.remove('hidden');
            switchTab('server'); // Default Tab
        }
        function closeSettingsModal() { settingsOverlay.classList.add('opacity-0'); settingsContent.classList.add('scale-95'); setTimeout(() => settingsOverlay.classList.add('hidden'), 200); }
        
        async function saveGlobalSettings() {
            const btn = document.querySelector('button[onclick="saveGlobalSettings()"]'); const originalText = btn.innerText; btn.innerText = "Saving to VPS..."; btn.disabled = true;

            const newPort = document.getElementById('conf-panel-port').value;
            if(newPort && newPort != currentPort) {
                try { await fetch(`${nodeApi}/change-port`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ port: newPort }) }); showToast("Port Changed", `Server moved to port ${newPort}. Reloading...`); } catch(e) { showToast("Error", "Failed to change port", "error"); btn.innerText = originalText; btn.disabled = false; return; }
            }

            const payload = {
                api_urls: serverList, 
                bot_token: document.getElementById('conf-bot-token').value,
                admin_id: document.getElementById('conf-tg-id').value,
                admin_username: document.getElementById('conf-admin-user').value,
                domain_map: domainMap, 
                welcome_msg: document.getElementById('conf-welcome').value,
                trial_enabled: document.getElementById('conf-trial').checked,
                trial_days: parseInt(document.getElementById('conf-trial-days').value) || 1,
                trial_gb: parseFloat(document.getElementById('conf-trial-gb').value) || 1,
                buttons: {
                    trial: document.getElementById('btn-trial').value,
                    buy: document.getElementById('btn-buy').value,
                    mykey: document.getElementById('btn-mykey').value,
                    info: document.getElementById('btn-info').value,
                    support: document.getElementById('btn-support').value,
                    reseller: document.getElementById('btn-reseller').value,
                    
                    // --- SAVE NEW BUTTONS ---
                    resell_buy: document.getElementById('btn-resell-buy').value,
                    resell_create: document.getElementById('btn-resell-create').value,
                    resell_users: document.getElementById('btn-resell-users').value,
                    resell_extend: document.getElementById('btn-resell-extend').value,
                    resell_logout: document.getElementById('btn-resell-logout').value
                },
                payments: payments, plans: plans, reseller_plans: resellerPlans, resellers: resellers
            };

            try {
                const res = await fetch(`${nodeApi}/update-config`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
                if(res.ok) { 
                    showToast("Success", "Settings Saved"); 
                    if(newPort && newPort != currentPort) { setTimeout(() => { window.location.port = newPort; }, 2000); } 
                    else { 
                        setTimeout(() => {
                             fetchServerConfig(); 
                             closeSettingsModal();
                             btn.innerText = originalText; btn.disabled = false;
                        }, 2000); 
                    } 
                } else { throw new Error("API Error"); }
            } catch (error) { 
                showToast("Error", "Could not connect to VPS Backend", "error"); 
                btn.innerText = originalText; btn.disabled = false;
            }
        }

        function copyPaymentInfo() { let text = "➖➖ Payment Methods ➖➖\n"; payments.forEach(p => { text += `✅ ${p.name}: ${p.num} ${p.owner ? '('+p.owner+')' : ''}\n`; }); text += "\n➖➖ Available Plans ➖➖\n"; plans.forEach(p => { text += `💎 ${p.days} Days - ${p.gb} - ${p.price} Ks\n`; }); const temp = document.createElement('textarea'); temp.value = text; document.body.appendChild(temp); temp.select(); document.execCommand('copy'); document.body.removeChild(temp); showToast("Copied", "Info copied"); }

        const modal = document.getElementById('modal-overlay'); const modalContent = document.getElementById('modal-content');
        
        function openCreateModal() { 
            document.getElementById('key-form').reset(); document.getElementById('key-id').value = ''; document.getElementById('key-unit').value = 'GB'; document.getElementById('topup-container').classList.add('hidden'); 
            const d = new Date(); d.setDate(d.getDate() + 30); document.getElementById('key-expire').value = d.toISOString().split('T')[0]; 
            document.getElementById('key-server-url').value = ''; 
            
            const sel = document.getElementById('server-select');
            sel.innerHTML = '';
            if(serverList.length === 0) sel.innerHTML = '<option>No Servers Configured</option>';
            else {
                serverList.forEach(s => {
                    const opt = document.createElement('option');
                    opt.value = s.url;
                    opt.text = s.name || s.url; 
                    sel.appendChild(opt);
                });
            }
            sel.parentElement.classList.remove('hidden');

            modal.classList.remove('hidden'); setTimeout(() => { modal.classList.remove('opacity-0'); modalContent.classList.remove('scale-95'); }, 10); lucide.createIcons(); 
        }
        function closeModal() { modal.classList.add('opacity-0'); modalContent.classList.add('scale-95'); setTimeout(() => modal.classList.add('hidden'), 200); }
        
        function editKey(id, name, date, displayBytes, serverUrlEnc) { 
            const url = decodeURIComponent(serverUrlEnc);
            document.getElementById('key-id').value = id; 
            document.getElementById('key-server-url').value = url; 
            document.getElementById('server-select').parentElement.classList.add('hidden');
            
            document.getElementById('key-name').value = name; document.getElementById('key-expire').value = date; document.getElementById('topup-container').classList.remove('hidden'); document.getElementById('topup-mode').checked = false; if(displayBytes > 0) { if (displayBytes >= 1073741824) { document.getElementById('key-limit').value = (displayBytes / 1073741824).toFixed(2); document.getElementById('key-unit').value = 'GB'; } else { document.getElementById('key-limit').value = (displayBytes / 1048576).toFixed(2); document.getElementById('key-unit').value = 'MB'; } } else { document.getElementById('key-limit').value = ''; } modal.classList.remove('hidden'); setTimeout(() => { modal.classList.remove('opacity-0'); modalContent.classList.remove('scale-95'); }, 10); lucide.createIcons(); 
        }
        
        document.getElementById('key-form').addEventListener('submit', async (e) => { 
            e.preventDefault(); 
            const btn = document.getElementById('save-btn'); btn.innerHTML = 'Saving...'; btn.disabled = true; 
            const id = document.getElementById('key-id').value; 
            let name = document.getElementById('key-name').value.trim(); 
            const date = document.getElementById('key-expire').value; 
            const inputVal = parseFloat(document.getElementById('key-limit').value); 
            const unit = document.getElementById('key-unit').value; 
            const isTopUp = document.getElementById('topup-mode').checked; 
            
            let targetUrl = document.getElementById('key-server-url').value;
            if(!targetUrl && !id) {
                targetUrl = document.getElementById('server-select').value;
            }
            if(!targetUrl) { showToast("Error", "No server selected", 'error'); btn.innerHTML = 'Save Key'; btn.disabled = false; return; }

            if (date) name = `${name} | ${date}`; 
            try { 
                let targetId = id; 
                if(!targetId) { 
                    const res = await fetch(`${targetUrl}/access-keys`, { method: 'POST' }); 
                    const data = await res.json(); 
                    targetId = data.id; 
                    localStorage.setItem(`offset_${targetId}`, '0'); 
                } 
                await fetch(`${targetUrl}/access-keys/${targetId}/name`, { method: 'PUT', headers: {'Content-Type': 'application/x-www-form-urlencoded'}, body: `name=${encodeURIComponent(name)}` }); 
                if(inputVal > 0) { 
                    let newQuota = (unit === 'GB') ? Math.floor(inputVal * 1024 * 1024 * 1024) : Math.floor(inputVal * 1024 * 1024); 
                    let finalLimit = newQuota; 
                    if (targetId && isTopUp) { 
                        const curRaw = globalUsageMap[targetId] || 0; 
                        localStorage.setItem(`offset_${targetId}`, curRaw); 
                        finalLimit = curRaw + newQuota; 
                    } else if (targetId) { 
                        const oldOff= parseInt(localStorage.getItem(`offset_${targetId}`) || '0'); 
                        finalLimit = oldOff + newQuota; 
                    } 
                    await fetch(`${targetUrl}/access-keys/${targetId}/data-limit`, { method: 'PUT', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({ limit: { bytes: finalLimit } }) }); 
                } else { 
                    await fetch(`${targetUrl}/access-keys/${targetId}/data-limit`, { method: 'DELETE' }); 
                } 
                closeModal(); refreshData(); showToast("Saved", "Success"); 
            } catch(e) { showToast("Error", "Failed", 'error'); } finally { btn.innerHTML = 'Save Key'; btn.disabled = false; } 
        });
        function copyKey(text) { const temp = document.createElement('textarea'); temp.value = text; document.body.appendChild(temp); temp.select(); document.execCommand('copy'); document.body.removeChild(temp); showToast("Copied", "Link copied"); }
    </script>
</body>
</html>
EOF

# 7. Install Node Modules
echo -e "${YELLOW}Installing Node Modules...${NC}"
cd /root/outline-bot
# Create package.json
cat << 'PKG' > package.json
{
  "name": "outline-bot",
  "version": "1.0.0",
  "description": "Outline Telegram Bot & Panel",
  "main": "bot.js",
  "scripts": {
    "start": "node bot.js"
  },
  "dependencies": {
    "axios": "^1.6.0",
    "body-parser": "^1.20.2",
    "cors": "^2.8.5",
    "express": "^4.18.2",
    "moment-timezone": "^0.5.43",
    "node-telegram-bot-api": "^0.63.0"
  }
}
PKG
npm install

# 8. Setup Nginx
echo -e "${YELLOW}Configuring Nginx...${NC}"
cat << 'NGINX' > /etc/nginx/sites-available/default
server {
    listen 80;
    server_name _;
    root /var/www/html;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }
}
NGINX
systemctl reload nginx

# 9. Setup Firewall (UFW) if active
if ufw status | grep -q "Status: active"; then
    echo -e "${YELLOW}Configuring Firewall...${NC}"
    ufw allow 80/tcp
    ufw allow 3000/tcp
fi

# 10. Start Bot with PM2
echo -e "${YELLOW}Starting Bot Process...${NC}"
npm install -g pm2
pm2 start bot.js --name "outline-bot"
pm2 startup
pm2 save

echo -e "${GREEN}==========================================${NC}"
echo -e "${GREEN} INSTALLATION COMPLETE! ${NC}"
echo -e "${GREEN}==========================================${NC}"
echo -e "Web Panel URL: ${YELLOW}http://$(curl -s ifconfig.me)${NC}"
echo -e "Web Panel Port: ${YELLOW}80${NC}"
echo -e "Backend Port: ${YELLOW}3000${NC}"
echo -e "\nPlease visit the URL and configure your Bot Token/Admin ID."
