#!/bin/bash

# =========================================================
#   VPN SHOP ULTIMATE (AUTO BLOCK & 20-DAY RETENTION)
# =========================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check Root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root (sudo su)${NC}"
  exit
fi

clear
echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN}   VPN SHOP INSTALLER (UPDATED LOGIC)         ${NC}"
echo -e "${GREEN}==============================================${NC}"

# --- 1. SYSTEM PREPARATION ---
echo -e "\n${YELLOW}[1/4] Installing System Dependencies...${NC}"
apt-get update -y > /dev/null 2>&1
apt-get install curl nginx git -y > /dev/null 2>&1

# Install Node.js 18+
if ! command -v node &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash - > /dev/null 2>&1
    apt-get install -y nodejs > /dev/null 2>&1
fi

# --- 2. SETUP BOT SERVER ---
echo -e "${YELLOW}[2/4] Setting up Bot Engine...${NC}"
rm -rf /root/vpn-shop
mkdir -p /root/vpn-shop
cd /root/vpn-shop

# Initialize Node Project
npm init -y > /dev/null 2>&1
npm install express cors body-parser node-telegram-bot-api axios pm2 moment-timezone > /dev/null 2>&1

# Create Config (If not exists)
if [ ! -f config.json ]; then
cat > config.json <<'EOF'
{
    "api_url": "",
    "bot_token": "",
    "admin_id": "",
    "admin_username": "",
    "domain": "",
    "welcome_msg": "👋 Welcome to VPN Shop!\nမင်္ဂလာပါ VPN Shop မှ ကြိုဆိုပါတယ်။",
    "trial_enabled": true,
    "trial_days": 1,
    "trial_gb": 1,
    "panel_port": 80,
    "buttons": {
        "trial": "🆓 Free Trial (အစမ်းသုံးရန်)",
        "buy": "🛒 Buy Key (ဝယ်ယူရန်)",
        "mykey": "🔑 My Key (မိမိ Key ရယူရန်)",
        "info": "👤 Account Info (အကောင့်စစ်ရန်)",
        "support": "🆘 Support (ဆက်သွယ်ရန်)"
    },
    "payments": [],
    "plans": []
}
EOF
fi

# --- CREATE BOT LOGIC (UPDATED WITH 5S GUARD & 20 DAY RETENTION) ---
cat > bot.js <<'END_OF_FILE'
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

let config = {};
let bot = null;
let claimedUsers = [];
let userStates = {};

function loadConfig() {
    try { if(fs.existsSync(CONFIG_FILE)) config = JSON.parse(fs.readFileSync(CONFIG_FILE)); } catch (e) {}
    try { if(fs.existsSync(CLAIM_FILE)) claimedUsers = JSON.parse(fs.readFileSync(CLAIM_FILE)); } catch(e) {}
}
loadConfig();

// --- API ROUTES ---
app.get('/api/config', (req, res) => { loadConfig(); res.json(config); });
app.post('/api/update-config', (req, res) => {
    try {
        const newConfig = { ...config, ...req.body };
        fs.writeFileSync(CONFIG_FILE, JSON.stringify(newConfig, null, 4));
        res.json({ success: true, config: newConfig });
        loadConfig(); startBot();
    } catch (error) { res.status(500).json({ success: false }); }
});
app.post('/api/change-port', (req, res) => {
    const newPort = req.body.port;
    if(!newPort || isNaN(newPort)) return res.status(400).json({error: "Invalid Port"});
    const nginxConfig = `server { listen ${newPort}; server_name _; root /var/www/html; index index.html; location / { try_files $uri $uri/ =404; } }`;
    try {
        fs.writeFileSync('/etc/nginx/sites-available/default', nginxConfig);
        config.panel_port = parseInt(newPort);
        fs.writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 4));
        exec('systemctl reload nginx', (err) => {
            if (err) return res.status(500).json({error: "Reload Failed"});
            res.json({ success: true });
        });
    } catch (err) { res.status(500).json({ error: "Write Failed" }); }
});
app.listen(3000, () => console.log('✅ Sync Server running on Port 3000'));

if (config.bot_token && config.api_url) startBot();

function startBot() {
    if(bot) { try { bot.stopPolling(); } catch(e){} }
    if(!config.bot_token) return;

    console.log("🚀 Starting Bot...");
    bot = new TelegramBot(config.bot_token, { polling: true });
    
    const agent = new https.Agent({ rejectUnauthorized: false });
    const client = axios.create({ httpsAgent: agent, timeout: 30000, headers: { 'Content-Type': 'application/json' } });
    const ADMIN_IDS = config.admin_id ? config.admin_id.split(',').map(id => id.trim()) : [];
    const API_URL = config.api_url;
    const CUSTOM_DOMAIN = config.domain || ""; 
    const WELCOME_MSG = config.welcome_msg || "👋 Welcome to VPN Shop!";
    const TRIAL_ENABLED = config.trial_enabled !== false;
    const TRIAL_DAYS = parseInt(config.trial_days) || 1;
    const TRIAL_GB = parseFloat(config.trial_gb) || 1;
    
    const BTN = {
        trial: config.buttons?.trial || "🆓 Free Trial",
        buy: config.buttons?.buy || "🛒 Buy Key",
        mykey: config.buttons?.mykey || "🔑 My Key",
        info: config.buttons?.info || "👤 Account Info",
        support: config.buttons?.support || "🆘 Support"
    };

    function escapeRegExp(string) { return string.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }
    function formatAccessUrl(url) { if (!CUSTOM_DOMAIN || !url) return url; try { const apiObj = new URL(API_URL); return url.replace(apiObj.hostname, CUSTOM_DOMAIN); } catch (e) { return url; } }
    function isAdmin(chatId) { return ADMIN_IDS.includes(String(chatId)); }
    function formatBytes(bytes) { if (!bytes || bytes === 0) return '0 B'; const i = Math.floor(Math.log(bytes) / Math.log(1024)); return (bytes / Math.pow(1024, i)).toFixed(2) + ' ' + ['B', 'KB', 'MB', 'GB', 'TB'][i]; }
    function getMyanmarDate(offsetDays = 0) { return moment().tz("Asia/Yangon").add(offsetDays, 'days').format('YYYY-MM-DD'); }
    function sanitizeText(text) { if (!text) return ''; return text.replace(/([_*\[\]()~`>#+\-=|{}.!])/g, '\\$1'); }

    // --- MAIN MENU ---
    function getMainMenu(userId) {
        let kb = []; let row1 = [];
        if (TRIAL_ENABLED) row1.push({ text: BTN.trial });
        row1.push({ text: BTN.buy }); kb.push(row1);
        kb.push([{ text: BTN.mykey }, { text: BTN.info }]); kb.push([{ text: BTN.support }]);
        if (isAdmin(userId)) kb.unshift([{ text: "👮‍♂️ Admin Panel" }]);
        return kb;
    }

    bot.onText(/\/start/, (msg) => { bot.sendMessage(msg.chat.id, WELCOME_MSG, { reply_markup: { keyboard: getMainMenu(msg.chat.id), resize_keyboard: true } }); });
    
    // --- TRIAL KEY ---
    const regexTrial = new RegExp(escapeRegExp(BTN.trial));
    bot.onText(regexTrial, async (msg) => {
        const chatId = msg.chat.id;
        if (!TRIAL_ENABLED) return bot.sendMessage(chatId, "⚠️ Free Trial is currently disabled.");
        if (claimedUsers.includes(chatId)) return bot.sendMessage(chatId, "⚠️ You have already claimed a trial key.");
        bot.sendMessage(chatId, "⏳ Creating Test Key...");
        try {
            const expireDate = getMyanmarDate(TRIAL_DAYS);
            const userFullName = `${msg.from.first_name}`.trim(); const username = msg.from.username ? `#${msg.from.username}` : '';
            const name = `TEST_${userFullName.replace(/\|/g, '').trim()} ${username} | ${expireDate}`; 
            const limitBytes = Math.floor(TRIAL_GB * 1024 * 1024 * 1024);
            const res = await client.post(`${API_URL}/access-keys`);
            await client.put(`${API_URL}/access-keys/${res.data.id}/name`, { name });
            await client.put(`${API_URL}/access-keys/${res.data.id}/data-limit`, { limit: { bytes: limitBytes } });
            claimedUsers.push(chatId); fs.writeFileSync(CLAIM_FILE, JSON.stringify(claimedUsers));
            
            let finalUrl = formatAccessUrl(res.data.accessUrl) + `#${encodeURIComponent(name.split('|')[0].trim())}`;
            bot.sendMessage(chatId, `🎉 <b>Free Trial Created!</b>\n\n👤 Name: ${userFullName}\n📅 Duration: ${TRIAL_DAYS} Days\n📦 Data: ${TRIAL_GB} GB\n📅 Expire: ${expireDate}\n\n🔗 <b>Key:</b>\n<code>${finalUrl}</code>`, { parse_mode: 'HTML' }); 
        } catch (e) { bot.sendMessage(chatId, "❌ Error creating test key."); }
    });

    // --- BUY ---
    const regexBuy = new RegExp(escapeRegExp(BTN.buy));
    bot.onText(regexBuy, (msg) => { if(!config.plans || config.plans.length === 0) return bot.sendMessage(msg.chat.id, "❌ No plans available."); const keyboard = config.plans.map((p, i) => [{ text: `${p.days} Days - ${p.gb}GB - ${p.price}Ks`, callback_data: `buy_${i}` }]); bot.sendMessage(msg.chat.id, "📅 **Choose Plan:**", { parse_mode: 'Markdown', reply_markup: { inline_keyboard: keyboard } }); });

    // --- MY KEY & INFO ---
    async function findUserKey(name) {
        const kRes = await client.get(`${API_URL}/access-keys`);
        return kRes.data.accessKeys.find(k => k.name.includes(name) && !k.name.startsWith('[BLOCKED]')); 
        // Note: Users can't check their key if it's blocked/renamed unless we fuzzy match. 
        // For now, allow exact name match only, or if name is inside.
    }

    const regexMyKey = new RegExp(escapeRegExp(BTN.mykey));
    bot.onText(regexMyKey, async (msg) => { 
        const userFullName = `${msg.from.first_name}`.trim(); 
        bot.sendMessage(msg.chat.id, "🔎 Retrieving Key..."); 
        try { 
            const kRes = await client.get(`${API_URL}/access-keys`); 
            // Try to find even if blocked
            const myKey = kRes.data.accessKeys.find(k => k.name.includes(userFullName)); 
            if (!myKey) return bot.sendMessage(msg.chat.id, "❌ **Key Not Found!**"); 
            let cleanName = myKey.name.replace('[BLOCKED] ', '');
            if (cleanName.includes('|')) cleanName = cleanName.split('|')[0].trim();
            let finalUrl = formatAccessUrl(myKey.accessUrl) + `#${encodeURIComponent(cleanName)}`;
            bot.sendMessage(msg.chat.id, `🔑 <b>My Key:</b>\n<code>${finalUrl}</code>`, { parse_mode: 'HTML' }); 
        } catch (e) { bot.sendMessage(msg.chat.id, "⚠️ Server Error"); } 
    });

    const regexInfo = new RegExp(escapeRegExp(BTN.info));
    bot.onText(regexInfo, async (msg) => { 
        const userFullName = `${msg.from.first_name}`.trim(); 
        bot.sendMessage(msg.chat.id, "🔎 Checking..."); 
        try { 
            const [kRes, mRes] = await Promise.all([client.get(`${API_URL}/access-keys`), client.get(`${API_URL}/metrics/transfer`)]); 
            const myKey = kRes.data.accessKeys.find(k => k.name.includes(userFullName)); 
            if (!myKey) return bot.sendMessage(msg.chat.id, "❌ **Account Not Found**"); 
            
            const used = mRes.data.bytesTransferredByUserId[myKey.id] || 0; 
            const limit = myKey.dataLimit ? myKey.dataLimit.bytes : 0; 
            const remaining = limit > 0 ? limit - used : 0; 
            
            let displayName = myKey.name.replace('[BLOCKED]', '').trim();
            let expireDate = "Unknown"; 
            if (displayName.includes('|')) { const parts = displayName.split('|'); displayName = parts[0].trim(); expireDate = parts[parts.length-1].trim(); } 
            
            let status = "🟢 Active";
            if (myKey.name.startsWith('[BLOCKED]')) status = "🔴 Blocked/Expired";
            
            const msgTxt = `👤 **Name:** ${sanitizeText(displayName)}\n📡 **Status:** ${status}\n⬇️ **Used:** ${formatBytes(used)}\n🎁 **Limit:** ${limit > 0 ? formatBytes(limit) : 'Unlimited'}\n📅 **Exp:** ${expireDate}`; 
            bot.sendMessage(msg.chat.id, msgTxt, { parse_mode: 'Markdown' }); 
        } catch (e) { bot.sendMessage(msg.chat.id, "⚠️ Server Error"); } 
    });

    // --- SUPPORT ---
    const regexSupport = new RegExp(escapeRegExp(BTN.support));
    bot.onText(regexSupport, (msg) => { const keyboard = (config.admin_username || '').split(',').map(u => [{ text: `💬 Chat with ${u.trim()}`, url: `https://t.me/${u.trim().replace('@', '')}` }]); bot.sendMessage(msg.chat.id, "🆘 **Select an Admin:**", { parse_mode: 'Markdown', reply_markup: { inline_keyboard: keyboard } }); });

    // --- ADMIN & CALLBACKS ---
    bot.onText(/Admin Panel/, (msg) => { if(isAdmin(msg.chat.id)) bot.sendMessage(msg.chat.id, "Admin Mode", {reply_markup:{inline_keyboard:[[{text:"Open Web Panel", url:`http://${config.domain || 'YOUR_IP'}`}]]}}); });

    bot.on('callback_query', async (q) => { 
        const chatId = q.message.chat.id; const data = q.data; const userFullName = `${q.from.first_name}`.trim();
        
        if (data.startsWith('buy_')) { 
            const p = config.plans[data.split('_')[1]]; 
            let payTxt = (config.payments || []).map(py => `▪️ ${py.name}: \`${py.num}\``).join('\n');
            userStates[chatId] = { status: 'WAITING_SLIP', plan: p, name: userFullName, username: q.from.username }; 
            bot.sendMessage(chatId, `✅ **Plan:** ${p.days} Days\n💰 **Price:** ${p.price} Ks\n\n💸 **Payments:**\n${payTxt}\n⚠️ ငွေလွှဲပြေစာ (Screenshot) ပို့ပေးပါ။`, {parse_mode: 'Markdown'}); 
        }
        
        if (isAdmin(chatId)) {
            if (data.startsWith('approve_')) { 
                const buyerId = data.split('_')[1]; 
                if (!userStates[buyerId]) return bot.answerCallbackQuery(q.id, {text: "Expired Order"});
                const { plan, name, username } = userStates[buyerId];
                bot.editMessageCaption(`✅ Approved by ${q.from.first_name}`, { chat_id: chatId, message_id: q.message.message_id });
                try {
                    const expireDate = getMyanmarDate(plan.days);
                    const limit = plan.gb * 1024 * 1024 * 1024;
                    const finalName = `${name.replace(/\|/g,'').trim()} #${username||''} | ${expireDate}`;
                    const res = await client.post(`${API_URL}/access-keys`);
                    await client.put(`${API_URL}/access-keys/${res.data.id}/name`, { name: finalName });
                    await client.put(`${API_URL}/access-keys/${res.data.id}/data-limit`, { limit: { bytes: limit } });
                    
                    let finalUrl = formatAccessUrl(res.data.accessUrl) + `#${encodeURIComponent(finalName.split('|')[0].trim())}`;
                    bot.sendMessage(buyerId, `🎉 <b>Purchase Success!</b>\n\n👤 Name: ${name}\n📅 Expire: ${expireDate}\n\n🔗 <b>Key:</b>\n<code>${finalUrl}</code>`, { parse_mode: 'HTML' }); 
                    delete userStates[buyerId];
                } catch(e) {}
            }
            if (data.startsWith('reject_')) {
                const buyerId = data.split('_')[1];
                if(userStates[buyerId]) { bot.sendMessage(buyerId, "❌ Order Rejected."); delete userStates[buyerId]; }
                bot.editMessageCaption(`❌ Rejected by ${q.from.first_name}`, { chat_id: chatId, message_id: q.message.message_id });
            }
        }
    });

    bot.on('photo', (msg) => { 
        if (userStates[msg.chat.id]?.status === 'WAITING_SLIP') { 
            const u = userStates[msg.chat.id];
            bot.sendMessage(msg.chat.id, "📩 Checking slip...");
            ADMIN_IDS.forEach(aid => bot.sendPhoto(aid, msg.photo[msg.photo.length-1].file_id, { caption: `💰 New Order: ${u.name}\n📦 ${u.plan.days}D / ${u.plan.gb}GB`, reply_markup: { inline_keyboard: [[{text:"✅ Approve", callback_data:`approve_${msg.chat.id}`},{text:"❌ Reject", callback_data:`reject_${msg.chat.id}`}]] } }));
        } 
    });

    // ==========================================================
    //   THE GUARDIAN (VPS SIDE - 5 SEC INTERVAL)
    // ==========================================================
    async function runGuardian() {
        try {
            const [kRes, mRes] = await Promise.all([client.get(`${API_URL}/access-keys`), client.get(`${API_URL}/metrics/transfer`)]);
            const keys = kRes.data.accessKeys;
            const usage = mRes.data.bytesTransferredByUserId;
            
            const now = moment().tz("Asia/Yangon");
            const todayStr = now.format('YYYY-MM-DD');

            for (const key of keys) {
                const used = usage[key.id] || 0;
                const limit = key.dataLimit ? key.dataLimit.bytes : 0;
                
                // Parse Name and Date
                let cleanName = key.name;
                const isAlreadyBlocked = cleanName.startsWith('[BLOCKED]');
                if (isAlreadyBlocked) cleanName = cleanName.replace('[BLOCKED]', '').trim();
                
                let expireDateStr = null;
                if (cleanName.includes('|')) expireDateStr = cleanName.split('|').pop().trim();
                
                // Checks
                const isValidDate = /^\d{4}-\d{2}-\d{2}$/.test(expireDateStr);
                const isExpired = isValidDate && moment(expireDateStr).isBefore(todayStr);
                const isLimitReached = (limit > 0 && limit <= 5000) ? true : (limit > 0 && used >= limit); // If limit is tiny (blocked) or used >= limit

                // --- 1. BLOCKING LOGIC ---
                // Block if (Expired OR Over Limit) AND (Not yet marked as [BLOCKED])
                if ((isExpired || (isLimitReached && limit > 5000)) && !isAlreadyBlocked) {
                    console.log(`Blocking User: ${key.id} - ${cleanName}`);
                    
                    // Rename to [BLOCKED] ...
                    const newName = `[BLOCKED] ${cleanName}`;
                    await client.put(`${API_URL}/access-keys/${key.id}/name`, { name: newName });
                    
                    // Set Data Limit to 0 (effectively blocks traffic)
                    await client.put(`${API_URL}/access-keys/${key.id}/data-limit`, { limit: { bytes: 0 } });

                    // Notify Admins
                    const reason = isExpired ? "Expired" : "Data Limit Reached";
                    const msg = `🚫 **AUTO BLOCKED**\n\n👤 Name: ${sanitizeText(cleanName)}\n🆔 ID: ${key.id}\n⚠️ Reason: ${reason}`;
                    ADMIN_IDS.forEach(aid => bot.sendMessage(aid, msg, {parse_mode: 'Markdown'}));
                }

                // --- 2. DELETION LOGIC (20 DAYS GRACE) ---
                // Only check keys that are already Expired
                if (isValidDate && isExpired) {
                    const expireMoment = moment(expireDateStr, "YYYY-MM-DD");
                    const diffDays = now.diff(expireMoment, 'days');

                    // If more than 20 days past expiry
                    if (diffDays >= 20) {
                        console.log(`Deleting User (20+ Days Old): ${key.id}`);
                        await client.delete(`${API_URL}/access-keys/${key.id}`);
                        
                        const msg = `🗑️ **AUTO DELETED (20 Days Rule)**\n\n👤 Name: ${sanitizeText(cleanName)}\n🆔 ID: ${key.id}\n📅 Expired: ${expireDateStr}`;
                        ADMIN_IDS.forEach(aid => bot.sendMessage(aid, msg, {parse_mode: 'Markdown'}));
                    }
                }
            }
        } catch (e) {
            // console.error("Guardian Error:", e.message);
        }
    }

    // Run every 5 seconds (5000 ms)
    setInterval(runGuardian, 5000);
}
END_OF_FILE

# --- 3. WEB PANEL SETUP (NO AUTO GUARD IN FRONTEND) ---
echo -e "${YELLOW}[3/4] Deploying Web Panel...${NC}"

# Setup Nginx
cat > /etc/nginx/sites-available/default <<'EOF'
server {
    listen 80;
    server_name _;
    root /var/www/html;
    index index.html;
    location / {
        try_files $uri $uri/ =404;
    }
}
EOF

if ! command -v nginx &> /dev/null; then
    apt-get install nginx -y > /dev/null 2>&1
    systemctl enable nginx
    systemctl start nginx
fi

rm /var/www/html/index.nginx-debian.html 2>/dev/null
rm /var/www/html/index.html 2>/dev/null

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
                    <p class="text-[10px] text-slate-400 uppercase tracking-widest font-semibold">VPS Config Edition</p>
                </div>
            </div>
            <div id="nav-status" class="hidden flex items-center space-x-3">
                <button onclick="openSettingsModal()" class="p-2 text-slate-300 hover:text-white hover:bg-slate-800 rounded-lg transition border border-slate-700" title="Settings"><i data-lucide="settings" class="w-5 h-5"></i></button>
                <button onclick="disconnect()" class="p-2 text-red-400 hover:text-red-300 hover:bg-red-900/30 rounded-lg transition border border-slate-700" title="Logout"><i data-lucide="log-out" class="w-5 h-5"></i></button>
            </div>
        </div>
    </nav>

    <main class="max-w-7xl mx-auto px-4 py-8">
        <div id="login-section" class="max-w-lg mx-auto mt-16">
            <div class="bg-white rounded-2xl shadow-xl p-8 border border-slate-200">
                <div class="text-center mb-8">
                    <div class="w-16 h-16 bg-slate-50 rounded-full flex items-center justify-center mx-auto mb-4 border border-slate-100">
                        <i data-lucide="link" class="w-8 h-8 text-indigo-600"></i>
                    </div>
                    <h2 class="text-2xl font-bold text-slate-800">Server Connection</h2>
                    <p class="text-slate-500 mt-2 text-sm">Please enter your Management API URL</p>
                </div>
                <form onsubmit="connectServer(event)" class="space-y-4">
                    <div>
                        <label class="block text-xs font-bold text-slate-500 uppercase mb-1 ml-1">API URL</label>
                        <input type="password" id="login-api-url" class="w-full p-3 border border-slate-300 rounded-xl focus:ring-2 focus:ring-indigo-500 outline-none transition font-mono text-sm" placeholder="https://1.2.3.4:xxxxx/SecretKey..." required>
                    </div>
                    <button type="submit" id="connect-btn" class="w-full bg-indigo-600 hover:bg-indigo-700 text-white py-3.5 rounded-xl font-bold shadow-lg shadow-indigo-200 transition flex justify-center items-center">
                        Connect Server
                    </button>
                </form>
            </div>
        </div>

        <div id="dashboard" class="hidden space-y-8">
            <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
                <div class="bg-white p-6 rounded-2xl shadow-sm border border-slate-200 flex items-center justify-between">
                    <div><p class="text-slate-500 text-xs font-bold uppercase tracking-wider">Total Keys</p><h3 class="text-3xl font-bold text-slate-800 mt-1" id="total-keys">0</h3></div>
                    <div class="p-3 bg-indigo-50 text-indigo-600 rounded-xl"><i data-lucide="users" class="w-6 h-6"></i></div>
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
                    <h3 class="text-lg font-bold text-slate-800 flex items-center"><i data-lucide="list-filter" class="w-5 h-5 mr-2 text-slate-400"></i> Access Keys</h3>
                </div>
                <div id="keys-list" class="grid grid-cols-1 lg:grid-cols-2 gap-6"></div>
            </div>
        </div>
    </main>

    <div id="settings-overlay" class="fixed inset-0 bg-slate-900/60 hidden z-[60] flex items-center justify-center backdrop-blur-sm opacity-0 modal">
        <div class="bg-white rounded-2xl shadow-2xl w-full max-w-2xl transform transition-all scale-95 flex flex-col max-h-[90vh]" id="settings-content">
            <div class="p-5 border-b border-slate-100 flex justify-between items-center bg-slate-50 rounded-t-2xl">
                <h3 class="text-lg font-bold text-slate-800 flex items-center"><i data-lucide="sliders" class="w-5 h-5 mr-2 text-indigo-600"></i> Server Settings</h3>
                <button onclick="closeSettingsModal()" class="p-1 text-slate-400 hover:text-slate-600 hover:bg-slate-200 rounded-lg transition"><i data-lucide="x" class="w-5 h-5"></i></button>
            </div>
            <div class="p-6 overflow-y-auto space-y-8 bg-slate-50/30">
                <div id="settings-loader" class="text-center py-10 hidden"><span class="animate-pulse font-bold text-indigo-600">Loading Config from VPS...</span></div>
                <div id="settings-body">
                    <div class="bg-white p-5 rounded-xl border border-slate-200 shadow-sm space-y-4">
                        <h4 class="text-xs font-bold text-indigo-600 uppercase tracking-wider flex items-center"><i data-lucide="bot" class="w-4 h-4 mr-2"></i> Telegram Config</h4>
                        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                            <div><label class="block text-xs font-bold text-slate-500 uppercase mb-1">Bot Token</label><input type="text" id="conf-bot-token" class="w-full p-2 border border-slate-300 rounded-lg text-sm font-mono" placeholder="1234:ABC..."></div>
                            <div><label class="block text-xs font-bold text-slate-500 uppercase mb-1">Admin ID (Comma Separated)</label><input type="text" id="conf-tg-id" class="w-full p-2 border border-slate-300 rounded-lg text-sm font-mono" placeholder="123456, 789012"></div>
                            <div class="md:col-span-2"><label class="block text-xs font-bold text-slate-500 uppercase mb-1">Admin Usernames</label><input type="text" id="conf-admin-user" class="w-full p-2 border border-slate-300 rounded-lg text-sm font-mono" placeholder="user1, user2"></div>
                            <div class="md:col-span-2 mt-4 bg-yellow-50 p-3 rounded-lg border border-yellow-200"><label class="block text-xs font-bold text-yellow-700 uppercase mb-1">Web Panel Port</label><input type="number" id="conf-panel-port" class="w-full p-2 border border-yellow-300 rounded-lg text-sm font-mono" placeholder="80"></div>
                            <div class="md:col-span-2 mt-2 border border-slate-200 p-3 rounded-lg bg-indigo-50/50">
                                <div class="flex items-center justify-between mb-3"><div class="flex items-center"><div class="bg-indigo-100 p-2 rounded-lg mr-3 text-indigo-600"><i data-lucide="gift" class="w-5 h-5"></i></div><div><p class="text-sm font-bold text-slate-800">Free Trial Settings</p></div></div><input type="checkbox" id="conf-trial" class="w-5 h-5 text-indigo-600 rounded focus:ring-indigo-500 border-gray-300"></div>
                                <div class="grid grid-cols-2 gap-4"><div><label class="block text-xs font-bold text-slate-500 uppercase mb-1">Trial Days</label><input type="number" id="conf-trial-days" class="w-full p-2 border border-slate-300 rounded-lg text-sm" placeholder="1"></div><div><label class="block text-xs font-bold text-slate-500 uppercase mb-1">Trial GB</label><input type="number" id="conf-trial-gb" class="w-full p-2 border border-slate-300 rounded-lg text-sm" placeholder="1" step="0.1"></div></div>
                            </div>
                            <div class="md:col-span-2 mt-4 border-t pt-4"><label class="block text-xs font-bold text-slate-500 uppercase mb-1">Custom Domain</label><input type="text" id="conf-domain" class="w-full p-2 border border-slate-300 rounded-lg text-sm font-mono" placeholder="vpn.example.com"></div>
                            <div class="md:col-span-2 mt-4 border-t pt-4"><label class="block text-xs font-bold text-slate-500 uppercase mb-1">Welcome Message</label><textarea id="conf-welcome" class="w-full p-2 border border-slate-300 rounded-lg text-sm font-mono" rows="3"></textarea></div>
                        </div>
                    </div>
                    <div class="bg-white p-5 rounded-xl border border-slate-200 shadow-sm">
                        <h4 class="text-xs font-bold text-emerald-600 uppercase tracking-wider mb-4 flex items-center"><i data-lucide="credit-card" class="w-4 h-4 mr-2"></i> Payment Methods</h4>
                        <div class="flex flex-col md:flex-row gap-2 mb-4 bg-emerald-50/50 p-3 rounded-lg border border-emerald-100"><input type="text" id="pay-name" class="flex-1 p-2 border border-emerald-200 rounded-lg text-sm" placeholder="Wallet"><input type="text" id="pay-num" class="flex-1 p-2 border border-emerald-200 rounded-lg text-sm" placeholder="Number"><input type="text" id="pay-owner" class="flex-1 p-2 border border-emerald-200 rounded-lg text-sm" placeholder="Owner"><button onclick="addPayment()" class="bg-emerald-600 hover:bg-emerald-700 text-white px-4 py-2 rounded-lg text-sm font-bold">Add</button></div>
                        <div id="payment-list" class="space-y-2"></div>
                    </div>
                    <div class="bg-white p-5 rounded-xl border border-slate-200 shadow-sm">
                        <h4 class="text-xs font-bold text-blue-600 uppercase tracking-wider mb-4 flex items-center"><i data-lucide="package" class="w-4 h-4 mr-2"></i> VPN Plans</h4>
                        <div class="flex gap-2 mb-4 bg-blue-50/50 p-3 rounded-lg border border-blue-100"><div class="w-1/4"><input type="number" id="plan-days" class="w-full p-2 border border-blue-200 rounded-lg text-sm" placeholder="Days"></div><div class="w-1/4"><input type="text" id="plan-gb" class="w-full p-2 border border-blue-200 rounded-lg text-sm" placeholder="GB"></div><div class="flex-1"><input type="number" id="plan-price" class="w-full p-2 border border-blue-200 rounded-lg text-sm" placeholder="Price"></div><button onclick="addPlan()" class="bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-lg text-sm font-bold">Add</button></div>
                        <div id="plan-list" class="grid grid-cols-1 gap-2"></div>
                    </div>
                </div>
            </div>
            <div class="p-5 border-t border-slate-100 bg-slate-50 rounded-b-2xl flex justify-between items-center"><button onclick="copyPaymentInfo()" class="flex items-center text-sm font-bold text-slate-600 hover:text-indigo-600 px-3 py-2 rounded-lg hover:bg-indigo-50 transition"><i data-lucide="copy" class="w-4 h-4 mr-2"></i> Copy Info</button><button onclick="saveGlobalSettings()" class="bg-slate-900 hover:bg-slate-800 text-white px-6 py-2.5 rounded-xl font-bold shadow-lg transition">Save Config and Start Bot</button></div>
        </div>
    </div>

    <div id="modal-overlay" class="fixed inset-0 bg-slate-900/60 hidden z-50 flex items-center justify-center backdrop-blur-sm opacity-0 modal"><div class="bg-white rounded-2xl shadow-2xl w-full max-w-md transform transition-all scale-95" id="modal-content"><div class="p-6 border-b border-slate-100 flex justify-between items-center bg-slate-50/50 rounded-t-2xl"><h3 class="text-lg font-bold text-slate-800 flex items-center"><i data-lucide="key" class="w-5 h-5 mr-2 text-indigo-600"></i> Manage Key</h3><button onclick="closeModal()" class="p-1 text-slate-400 hover:text-slate-600 hover:bg-slate-100 rounded-lg transition"><i data-lucide="x" class="w-5 h-5"></i></button></div><form id="key-form" class="p-6 space-y-5"><input type="hidden" id="key-id"><div><label class="block text-xs font-bold text-slate-500 uppercase mb-1 ml-1">Name</label><input type="text" id="key-name" class="w-full p-3 border border-slate-300 rounded-xl focus:ring-2 focus:ring-indigo-500 outline-none transition" required></div><div id="topup-container" class="hidden"><div class="bg-indigo-50 p-3 rounded-xl border border-indigo-100 flex items-center"><input type="checkbox" id="topup-mode" class="w-5 h-5 text-indigo-600 rounded border-gray-300"><label for="topup-mode" class="ml-3 block text-sm font-bold text-indigo-900">Reset & Top Up</label></div></div><div class="grid grid-cols-2 gap-4"><div><label class="block text-xs font-bold text-slate-500 uppercase mb-1 ml-1">Limit</label><div class="flex shadow-sm rounded-xl overflow-hidden border border-slate-300 focus-within:ring-2 focus-within:ring-indigo-500"><input type="number" id="key-limit" class="w-full p-3 outline-none" placeholder="Unl" min="0.1" step="0.1"><select id="key-unit" class="bg-slate-50 border-l border-slate-300 px-3 text-sm font-bold text-slate-600 outline-none"><option value="GB">GB</option><option value="MB">MB</option></select></div></div><div><label class="block text-xs font-bold text-slate-500 uppercase mb-1 ml-1">Expiry Date</label><input type="date" id="key-expire" class="w-full p-3 border border-slate-300 rounded-xl focus:ring-2 focus:ring-indigo-500 outline-none text-sm text-slate-600"></div></div><div class="pt-2"><button type="submit" id="save-btn" class="w-full bg-slate-900 hover:bg-indigo-700 text-white py-3.5 rounded-xl font-bold shadow-lg transition flex justify-center items-center">Save Key</button></div></form></div></div>
    
    <div id="toast" class="fixed bottom-5 right-5 bg-slate-800 text-white px-6 py-4 rounded-xl shadow-2xl transform translate-y-24 transition-transform duration-300 flex items-center z-[70] max-w-sm border border-slate-700/50"><div id="toast-icon" class="mr-3 text-emerald-400"></div><div><h4 class="font-bold text-sm" id="toast-title">Success</h4><p class="text-xs text-slate-300 mt-0.5" id="toast-msg">Completed.</p></div></div>

    <script>
        let apiUrl = localStorage.getItem('outline_api_url') || '';
        let globalUsageMap = {};
        let refreshInterval;
        let payments = []; let plans = []; let currentPort = 80;
        const nodeApi = `${window.location.protocol}//${window.location.hostname}:3000/api`;

        document.addEventListener('DOMContentLoaded', () => { lucide.createIcons(); if(apiUrl) { document.getElementById('login-api-url').value = apiUrl; startConnectionProcess(); } });
        function showToast(title, msg, type = 'success') { const toast = document.getElementById('toast'); const iconDiv = document.getElementById('toast-icon'); document.getElementById('toast-title').textContent = title; document.getElementById('toast-msg').textContent = msg; let icon = 'check-circle'; let color = 'text-emerald-400'; if(type === 'error') { icon = 'alert-circle'; color = 'text-red-400'; } else if (type === 'warn') { icon = 'shield-alert'; color = 'text-orange-400'; } iconDiv.innerHTML = `<i data-lucide="${icon}" class="w-5 h-5"></i>`; iconDiv.className = `mr-3 ${color}`; lucide.createIcons(); toast.classList.remove('translate-y-24'); setTimeout(() => toast.classList.add('translate-y-24'), 3000); }
        function formatAccessUrl(url) { if (!config.domain || !url) return url; try { const apiObj = new URL(apiUrl); return url.replace(apiObj.hostname, config.domain); } catch(e) { return url; } }
        let config = {};
        async function fetchServerConfig() { try { const res = await fetch(`${nodeApi}/config`); if(!res.ok) throw new Error("Failed"); config = await res.json(); payments = config.payments || []; plans = config.plans || []; currentPort = config.panel_port || 80; document.getElementById('conf-bot-token').value = config.bot_token || ''; document.getElementById('conf-tg-id').value = config.admin_id || ''; document.getElementById('conf-admin-user').value = config.admin_username || ''; document.getElementById('conf-domain').value = config.domain || ''; document.getElementById('conf-welcome').value = config.welcome_msg || ''; document.getElementById('conf-panel-port').value = currentPort; document.getElementById('conf-trial').checked = config.trial_enabled !== false; document.getElementById('conf-trial-days').value = config.trial_days || 1; document.getElementById('conf-trial-gb').value = config.trial_gb || 1; renderPayments(); renderPlans(); return true; } catch(e) { showToast("Error", "Could not load config", "error"); return false; } }
        function disconnect() { localStorage.removeItem('outline_api_url'); if(refreshInterval) clearInterval(refreshInterval); location.reload(); }
        function connectServer(e) { e.preventDefault(); let cleanUrl = document.getElementById('login-api-url').value.trim(); if(cleanUrl.startsWith('{')) { try { cleanUrl = JSON.parse(cleanUrl).apiUrl; } catch(e){} } if(cleanUrl.endsWith('/')) cleanUrl = cleanUrl.slice(0, -1); document.getElementById('login-api-url').value = cleanUrl; apiUrl = cleanUrl; startConnectionProcess(); }
        async function startConnectionProcess() { const btn = document.getElementById('connect-btn'); btn.innerHTML = `Connecting...`; btn.disabled = true; try { const res = await fetch(`${apiUrl}/server`); if(!res.ok) throw new Error("API Unreachable"); localStorage.setItem('outline_api_url', apiUrl); document.getElementById('login-section').classList.add('hidden'); document.getElementById('dashboard').classList.remove('hidden'); document.getElementById('nav-status').classList.remove('hidden'); document.getElementById('nav-status').classList.add('flex'); fetchServerConfig(); await refreshData(); refreshInterval = setInterval(refreshData, 5000); } catch (error) { showToast("Connection Failed", "Check API URL & SSL", "error"); btn.innerHTML = 'Connect Server'; btn.disabled = false; } }
        async function refreshData() { try { const [keysRes, metricsRes] = await Promise.all([ fetch(`${apiUrl}/access-keys`), fetch(`${apiUrl}/metrics/transfer`) ]); const keysData = await keysRes.json(); const metricsData = await metricsRes.json(); globalUsageMap = metricsData.bytesTransferredByUserId; renderDashboard(keysData.accessKeys, globalUsageMap); } catch(e) {} }
        function formatBytes(bytes) { if (!bytes || bytes === 0) return '0 B'; const i = parseInt(Math.floor(Math.log(bytes) / Math.log(1024))); return (bytes / Math.pow(1024, i)).toFixed(2) + ' ' + ['B', 'KB', 'MB', 'GB', 'TB'][i]; }

        // --- DASHBOARD RENDER (REMOVED AUTO GUARD) ---
        async function renderDashboard(keys, usageMap) {
            const list = document.getElementById('keys-list'); list.innerHTML = '';
            document.getElementById('total-keys').textContent = keys.length;
            let totalNetworkBytes = 0; Object.values(usageMap).forEach(b => totalNetworkBytes += b);
            document.getElementById('total-usage').textContent = formatBytes(totalNetworkBytes);
            keys.sort((a,b) => parseInt(a.id) - parseInt(b.id));
            const today = new Date().toISOString().split('T')[0];

            for (const key of keys) {
                const usageOffset = parseInt(localStorage.getItem(`offset_${key.id}`) || '0');
                const rawLimit = key.dataLimit ? key.dataLimit.bytes : 0; const rawUsage = usageMap[key.id] || 0;
                let displayUsed = Math.max(0, rawUsage - usageOffset); let displayLimit = 0; if (rawLimit > 0) displayLimit = Math.max(0, rawLimit - usageOffset);
                let displayName = key.name || 'No Name'; let rawName = displayName; let expireDate = null;
                
                // Detect [BLOCKED] prefix set by VPS
                let isSystemBlocked = displayName.startsWith('[BLOCKED]');
                if (isSystemBlocked) rawName = displayName.replace('[BLOCKED]', '').trim();

                if (rawName.includes('|')) { const parts = rawName.split('|'); rawName = parts[0].trim(); const potentialDate = parts[parts.length - 1].trim(); if (/^\d{4}-\d{2}-\d{2}$/.test(potentialDate)) expireDate = potentialDate; }
                
                // Purely Visual checks (No auto-blocking here)
                let isExpired = expireDate && expireDate < today; 
                let isDataExhausted = (rawLimit > 5000 && rawUsage >= rawLimit);

                let cardClass, progressBarColor, percentage = 0, switchState = true;
                let avatarHtml = `<div class="w-12 h-12 rounded-2xl bg-indigo-50 text-indigo-600 font-bold flex items-center justify-center mr-4 text-sm border border-black/5">${key.id}</div>`;
                let nameHtml = rawName;
                let subStatusHtml = `<span class="text-xs font-bold text-emerald-600">Active</span>`;
                let expireHtml = expireDate ? `<span class="text-xs text-slate-400 font-medium">${expireDate}</span>` : '';

                // If VPS has renamed it to [BLOCKED] OR if limit is set to 0 manually
                if (isSystemBlocked || (rawLimit > 0 && rawLimit <= 5000)) { 
                    switchState = false; 
                    percentage = 100; 
                    progressBarColor = 'bg-slate-300'; 
                    cardClass = 'bg-slate-50 opacity-90 border-slate-200';
                    avatarHtml = `<div class="w-12 h-12 rounded-2xl bg-red-100 text-red-600 font-bold flex items-center justify-center mr-4 border border-red-200"><div class="w-4 h-4 bg-red-500 rounded-full"></div></div>`;
                    nameHtml = `<span class="text-red-600 font-bold">[BLOCKED]</span> ${rawName}`;
                    subStatusHtml = `<span class="text-xs font-bold text-slate-400">Suspended</span>`;
                } else { 
                    cardClass = 'border-slate-200 bg-white hover:shadow-md'; 
                    percentage = displayLimit > 0 ? Math.min((displayUsed / displayLimit) * 100, 100) : 5; 
                    progressBarColor = percentage > 90 ? 'bg-orange-500' : (displayLimit > 0 ? 'bg-indigo-500' : 'bg-emerald-500'); 
                }

                let finalAccessUrl = formatAccessUrl(key.accessUrl) + `#${encodeURIComponent(rawName)}`;
                let limitText = displayLimit > 0 ? formatBytes(displayLimit) : 'Unlimited';

                const card = document.createElement('div');
                card.className = `rounded-2xl shadow-sm border p-5 transition-all ${cardClass}`;
                card.innerHTML = `
                    <div class="flex justify-between items-start mb-4">
                        <div class="flex items-center">
                            ${avatarHtml}
                            <div>
                                <h4 class="font-bold text-slate-800 text-lg leading-tight line-clamp-1">${nameHtml}</h4>
                                <div class="flex items-center gap-3 mt-1">${subStatusHtml} ${expireHtml}</div>
                            </div>
                        </div>
                        <button onclick="toggleKey('${key.id}', ${!switchState}, '${rawName.replace(/'/g, "\\'")}')" class="relative w-12 h-7 rounded-full transition-colors focus:outline-none ${switchState ? 'bg-emerald-500' : 'bg-slate-300'}"><span class="inline-block w-5 h-5 transform rounded-full bg-white shadow transition-transform mt-1 ${switchState ? 'translate-x-6' : 'translate-x-1'}"></span></button>
                    </div>
                    <div class="mb-5"><div class="flex justify-between text-xs mb-1.5 font-bold text-slate-500 uppercase tracking-wider"><span>${formatBytes(displayUsed)}</span><span>${limitText}</span></div><div class="w-full bg-slate-100 rounded-full h-3 overflow-hidden"><div class="${progressBarColor} h-3 rounded-full transition-all duration-700" style="width: ${percentage}%"></div></div></div>
                    <div class="flex justify-between items-center pt-4 border-t border-slate-100">
                        <div class="flex space-x-2">
                            <button onclick="editKey('${key.id}', '${rawName.replace(/'/g, "\\'")}', '${expireDate || ''}', ${displayLimit})" class="p-2 text-slate-400 hover:text-indigo-600 hover:bg-indigo-50 rounded-lg transition"><i data-lucide="settings-2" class="w-4 h-4"></i></button>
                            <button onclick="deleteKey('${key.id}')" class="p-2 text-slate-400 hover:text-red-600 hover:bg-red-50 rounded-lg transition"><i data-lucide="trash-2" class="w-4 h-4"></i></button>
                        </div>
                        <button onclick="copyKey('${finalAccessUrl}')" class="flex items-center px-4 py-2 bg-slate-50 hover:bg-indigo-50 text-slate-600 hover:text-indigo-700 rounded-lg text-xs font-bold transition"><i data-lucide="copy" class="w-3 h-3 mr-2"></i> Copy</button>
                    </div>`;
                list.appendChild(card);
            }
            lucide.createIcons();
        }

        async function toggleKey(id, isCurrentlyBlocked, rawName) { 
            try { 
                if(isCurrentlyBlocked) { 
                    // Unblock: Remove [BLOCKED] and Remove Limit
                    await fetch(`${apiUrl}/access-keys/${id}/name`, { method: 'PUT', headers: {'Content-Type': 'application/x-www-form-urlencoded'}, body: `name=${encodeURIComponent(rawName)}` });
                    await fetch(`${apiUrl}/access-keys/${id}/data-limit`, { method: 'DELETE' }); 
                } else { 
                    // Block Manually: Add [BLOCKED] and Set Limit 0
                    await fetch(`${apiUrl}/access-keys/${id}/name`, { method: 'PUT', headers: {'Content-Type': 'application/x-www-form-urlencoded'}, body: `name=${encodeURIComponent('[BLOCKED] '+rawName)}` });
                    await fetch(`${apiUrl}/access-keys/${id}/data-limit`, { method: 'PUT', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({ limit: { bytes: 0 } }) }); 
                } 
                showToast(isCurrentlyBlocked ? "Enabled" : "Disabled", "Status updated"); refreshData(); 
            } catch(e) { showToast("Error", "Action failed", 'error'); } 
        }
        async function deleteKey(id) { if(!confirm("Delete this key?")) return; try { await fetch(`${apiUrl}/access-keys/${id}`, { method: 'DELETE' }); localStorage.removeItem(`offset_${id}`); showToast("Deleted", "Key removed"); refreshData(); } catch(e) { showToast("Error", "Delete failed", 'error'); } }
        
        // Settings & Payment Logic (Compressed for brevity but functional)
        function addPayment() { const name = document.getElementById('pay-name').value.trim(); const num = document.getElementById('pay-num').value.trim(); const owner = document.getElementById('pay-owner').value.trim(); if(!name || !num) return showToast("Info Missing", "Name and Number required", "warn"); payments.push({ name, num, owner }); renderPayments(); document.getElementById('pay-name').value = ''; document.getElementById('pay-num').value = ''; document.getElementById('pay-owner').value = ''; }
        function removePayment(index) { payments.splice(index, 1); renderPayments(); }
        function renderPayments() { const list = document.getElementById('payment-list'); list.innerHTML = ''; if(payments.length === 0) list.innerHTML = '<div class="text-center text-slate-400 text-xs py-2">No payment methods added.</div>'; payments.forEach((p, idx) => { const item = document.createElement('div'); item.className = 'flex justify-between items-center bg-white p-3 rounded-lg border border-slate-100 shadow-sm'; item.innerHTML = `<div class="flex items-center space-x-3"><div class="bg-emerald-100 text-emerald-600 p-2 rounded-full"><i data-lucide="wallet" class="w-4 h-4"></i></div><div><p class="text-sm font-bold text-slate-800">${p.name}</p><p class="text-xs text-slate-500 font-mono">${p.num} ${p.owner ? `(${p.owner})` : ''}</p></div></div><button onclick="removePayment(${idx})" class="text-slate-300 hover:text-red-500"><i data-lucide="trash" class="w-4 h-4"></i></button>`; list.appendChild(item); }); lucide.createIcons(); }
        function addPlan() { const days = document.getElementById('plan-days').value; const gb = document.getElementById('plan-gb').value; const price = document.getElementById('plan-price').value; if(!days || !gb || !price) return showToast("Info Missing", "Fill all plan details", "warn"); plans.push({ days, gb, price }); renderPlans(); document.getElementById('plan-days').value = ''; document.getElementById('plan-gb').value = ''; document.getElementById('plan-price').value = ''; }
        function removePlan(index) { plans.splice(index, 1); renderPlans(); }
        function renderPlans() { const list = document.getElementById('plan-list'); list.innerHTML = ''; if(plans.length === 0) list.innerHTML = '<div class="text-center text-slate-400 text-xs py-2">No plans added.</div>'; plans.forEach((p, idx) => { const item = document.createElement('div'); item.className = 'flex justify-between items-center bg-white p-3 rounded-lg border border-slate-100 shadow-sm'; item.innerHTML = `<div class="flex items-center space-x-3 w-full"><div class="bg-blue-100 text-blue-600 p-2 rounded-full flex-shrink-0"><i data-lucide="zap" class="w-4 h-4"></i></div><div class="flex justify-between w-full pr-4"><div class="text-sm font-bold text-slate-800 w-1/3">${p.days} Days</div><div class="text-sm font-bold text-slate-600 w-1/3 text-center">${p.gb}</div><div class="text-sm font-bold text-emerald-600 w-1/3 text-right">${p.price} Ks</div></div></div><button onclick="removePlan(${idx})" class="text-slate-300 hover:text-red-500 flex-shrink-0"><i data-lucide="trash" class="w-4 h-4"></i></button>`; list.appendChild(item); }); lucide.createIcons(); }
        
        const settingsOverlay = document.getElementById('settings-overlay'); const settingsContent = document.getElementById('settings-content');
        async function openSettingsModal() { settingsOverlay.classList.remove('hidden'); setTimeout(() => { settingsOverlay.classList.remove('opacity-0'); settingsContent.classList.remove('scale-95'); }, 10); document.getElementById('settings-loader').classList.remove('hidden'); document.getElementById('settings-body').classList.add('hidden'); await fetchServerConfig(); document.getElementById('settings-loader').classList.add('hidden'); document.getElementById('settings-body').classList.remove('hidden'); }
        function closeSettingsModal() { settingsOverlay.classList.add('opacity-0'); settingsContent.classList.add('scale-95'); setTimeout(() => settingsOverlay.classList.add('hidden'), 200); }
        async function saveGlobalSettings() { const btn = document.querySelector('button[onclick="saveGlobalSettings()"]'); const originalText = btn.innerText; btn.innerText = "Saving..."; btn.disabled = true; const newPort = document.getElementById('conf-panel-port').value; if(newPort && newPort != currentPort) { try { await fetch(`${nodeApi}/change-port`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ port: newPort }) }); showToast("Port Changed", `Server moved to port ${newPort}`); } catch(e) { btn.disabled = false; return; } } const payload = { api_url: apiUrl, bot_token: document.getElementById('conf-bot-token').value, admin_id: document.getElementById('conf-tg-id').value, admin_username: document.getElementById('conf-admin-user').value, domain: document.getElementById('conf-domain').value, welcome_msg: document.getElementById('conf-welcome').value, trial_enabled: document.getElementById('conf-trial').checked, trial_days: parseInt(document.getElementById('conf-trial-days').value) || 1, trial_gb: parseFloat(document.getElementById('conf-trial-gb').value) || 1, buttons: config.buttons, payments: payments, plans: plans }; try { await fetch(`${nodeApi}/update-config`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) }); showToast("Success", "Settings Saved"); if(newPort && newPort != currentPort) setTimeout(() => window.location.port = newPort, 2000); else { fetchServerConfig(); closeSettingsModal(); } } catch (error) { showToast("Error", "Could not connect to VPS", "error"); } btn.innerText = originalText; btn.disabled = false; }
        function copyPaymentInfo() { let text = "➖➖ Payment Methods ➖➖\n"; payments.forEach(p => { text += `✅ ${p.name}: ${p.num} ${p.owner ? '('+p.owner+')' : ''}\n`; }); text += "\n➖➖ Available Plans ➖➖\n"; plans.forEach(p => { text += `💎 ${p.days} Days - ${p.gb} - ${p.price} Ks\n`; }); const temp = document.createElement('textarea'); temp.value = text; document.body.appendChild(temp); temp.select(); document.execCommand('copy'); document.body.removeChild(temp); showToast("Copied", "Info copied"); }

        const modal = document.getElementById('modal-overlay'); const modalContent = document.getElementById('modal-content');
        function openCreateModal() { document.getElementById('key-form').reset(); document.getElementById('key-id').value = ''; document.getElementById('key-unit').value = 'GB'; document.getElementById('topup-container').classList.add('hidden'); const d = new Date(); d.setDate(d.getDate() + 30); document.getElementById('key-expire').value = d.toISOString().split('T')[0]; modal.classList.remove('hidden'); setTimeout(() => { modal.classList.remove('opacity-0'); modalContent.classList.remove('scale-95'); }, 10); lucide.createIcons(); }
        function closeModal() { modal.classList.add('opacity-0'); modalContent.classList.add('scale-95'); setTimeout(() => modal.classList.add('hidden'), 200); }
        function editKey(id, name, date, displayBytes) { document.getElementById('key-id').value = id; document.getElementById('key-name').value = name; document.getElementById('key-expire').value = date; document.getElementById('topup-container').classList.remove('hidden'); document.getElementById('topup-mode').checked = false; if(displayBytes > 0) { if (displayBytes >= 1073741824) { document.getElementById('key-limit').value = (displayBytes / 1073741824).toFixed(2); document.getElementById('key-unit').value = 'GB'; } else { document.getElementById('key-limit').value = (displayBytes / 1048576).toFixed(2); document.getElementById('key-unit').value = 'MB'; } } else { document.getElementById('key-limit').value = ''; } modal.classList.remove('hidden'); setTimeout(() => { modal.classList.remove('opacity-0'); modalContent.classList.remove('scale-95'); }, 10); lucide.createIcons(); }
        document.getElementById('key-form').addEventListener('submit', async (e) => { e.preventDefault(); const btn = document.getElementById('save-btn'); btn.innerHTML = 'Saving...'; btn.disabled = true; const id = document.getElementById('key-id').value; let name = document.getElementById('key-name').value.trim(); const date = document.getElementById('key-expire').value; const inputVal = parseFloat(document.getElementById('key-limit').value); const unit = document.getElementById('key-unit').value; const isTopUp = document.getElementById('topup-mode').checked; if (date) name = `${name} | ${date}`; try { let targetId = id; if(!targetId) { const res = await fetch(`${apiUrl}/access-keys`, { method: 'POST' }); const data = await res.json(); targetId = data.id; localStorage.setItem(`offset_${targetId}`, '0'); } await fetch(`${apiUrl}/access-keys/${targetId}/name`, { method: 'PUT', headers: {'Content-Type': 'application/x-www-form-urlencoded'}, body: `name=${encodeURIComponent(name)}` }); if(inputVal > 0) { let newQuota = (unit === 'GB') ? Math.floor(inputVal * 1024 * 1024 * 1024) : Math.floor(inputVal * 1024 * 1024); let finalLimit = newQuota; if (targetId && isTopUp) { const curRaw = globalUsageMap[targetId] || 0; localStorage.setItem(`offset_${targetId}`, curRaw); finalLimit = curRaw + newQuota; } else if (targetId) { const oldOff = parseInt(localStorage.getItem(`offset_${targetId}`) || '0'); finalLimit = oldOff + newQuota; } await fetch(`${apiUrl}/access-keys/${targetId}/data-limit`, { method: 'PUT', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({ limit: { bytes: finalLimit } }) }); } else { await fetch(`${apiUrl}/access-keys/${targetId}/data-limit`, { method: 'DELETE' }); } closeModal(); refreshData(); showToast("Saved", "Success"); } catch(e) { showToast("Error", "Failed", 'error'); } finally { btn.innerHTML = 'Save Key'; btn.disabled = false; } });
        function copyKey(text) { const temp = document.createElement('textarea'); temp.value = text; document.body.appendChild(temp); temp.select(); document.execCommand('copy'); document.body.removeChild(temp); showToast("Copied", "Link copied"); }
    </script>
</body>
</html>
EOF

# --- 4. START SERVICES ---
echo -e "${YELLOW}[4/4] Starting Services...${NC}"

# Nginx
systemctl restart nginx

# Bot Server
pm2 delete vpn-shop > /dev/null 2>&1
pm2 start bot.js --name "vpn-shop" > /dev/null 2>&1
pm2 save > /dev/null 2>&1
pm2 startup > /dev/null 2>&1

# Final Message
IP=$(curl -s ifconfig.me)
echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN} INSTALLATION COMPLETE! ${NC}"
echo -e "${GREEN}==============================================${NC}"
echo -e "Open your panel here: ${YELLOW}http://$IP${NC}"
echo -e ""
echo -e "NOTE: Auto-Guard is now running on VPS (Backend) every 5 seconds."
echo -e "Expired keys will be renamed to [BLOCKED] and deleted after 20 days."
