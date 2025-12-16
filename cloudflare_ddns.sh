export default {
    async fetch(req, env) {
        return new Response(await runDDNS(env), {
            headers: { "Content-Type": "text/plain; charset=utf-8" }
        });
    },
    async scheduled(event, env, ctx) {
        ctx.waitUntil(runDDNS(env));
    }
};

// ================= 主流程 =================
async function runDDNS(env) {
    try {
        // ===== 0 点尝试发送日报 =====
        await trySendDailyReport(env);

        // ===== 获取 IPv4 =====
        const ipResult = await getIPv4FromSource();
        if (!ipResult.ok) {
            await sendTG(env, ipResult.error, null, "ip_error");
            return "IP 获取失败";
        }
        const ipv4 = ipResult.ip;

        // ===== IP 信息 =====
        const ipinfo = await getIPInfo(ipv4);

        // ===== IP 未变化 =====
        const lastIP = await env.KV.get("ddns_last_ip") || "";
        if (lastIP === ipv4) return "IP 未变化";

        // ===== 更新 DNS =====
        const result = await updateARecord(env, env.ZONE_ID, env.DOMAIN, ipv4);
        if (!result.ok) {
            await sendTG(env, result.error, null, "error");
            return "DNS 更新失败";
        }

        // ===== 更新成功 =====
        await env.KV.put("ddns_last_ip", ipv4);

        // ---------- 6 小时统计 ----------
        const countKey = "ddns_success_count";
        const historyKey = "ddns_ip_history";

        const count = Number(await env.KV.get(countKey) || 0) + 1;
        await env.KV.put(countKey, String(count));

        let history = JSON.parse(await env.KV.get(historyKey) || "[]");
        history.push({ ip: ipv4, time: getBeijingTime() });
        if (history.length > 20) history = history.slice(-20);
        await env.KV.put(historyKey, JSON.stringify(history));

        // ---------- 固定 6 小时槽位提醒 ----------
        const currentSlot = get6HourSlotKey();
        const lastSlot = await env.KV.get("ddns_6h_slot");

        if (currentSlot !== lastSlot) {
            await sendTG(env, ipv4, ipinfo, "success", {
                hours: 6,
                count,
                history
            });

            await env.KV.put("ddns_6h_slot", currentSlot);
            await env.KV.put(countKey, "0");
            await env.KV.put(historyKey, "[]");
        }

        // ---------- 日报统计 ----------
        await recordDaily(env, ipv4);

        return "更新完成";

    } catch (e) {
        await sendTG(env, e.message, null, "error");
        return "Worker 异常";
    }
}

// ================= IPv4 获取 =================
async function getIPv4FromSource() {
    try {
        const res = await fetch("https://ip.164746.xyz/ipTop.html");
        if (!res.ok) return { ok: false, error: `HTTP ${res.status}` };

        const html = await res.text();
        const match = html.match(/\b(?:\d{1,3}\.){3}\d{1,3}\b/);
        if (!match) return { ok: false, error: "未解析到 IPv4" };

        return { ok: true, ip: match[0] };
    } catch (e) {
        return { ok: false, error: e.message };
    }
}

// ================= IP 信息 =================
async function getIPInfo(ip) {
    try {
        const r = await fetch(`https://api.vore.top/api/IPdata?ip=${ip}`);
        const d = await r.json();
        if (d.code === 200) {
            return {
                country: d.ipdata.info1,
                region: d.ipdata.info2,
                city: d.ipdata.info3,
                isp: d.ipdata.isp
            };
        }
    } catch {}

    try {
        const r = await fetch(`http://ip-api.com/json/${ip}?lang=zh-CN`);
        const d = await r.json();
        if (d.status === "success") {
            return {
                country: d.country,
                region: d.regionName,
                city: d.city,
                isp: d.isp
            };
        }
    } catch {}

    return {};
}

// ================= Cloudflare 更新 =================
async function updateARecord(env, zoneId, domain, ipv4) {
    try {
        const list = await fetch(
            `https://api.cloudflare.com/client/v4/zones/${zoneId}/dns_records?type=A&name=${domain}`,
            { headers: { Authorization: `Bearer ${env.CF_API}` } }
        ).then(r => r.json());

        const record = list.result?.[0];
        if (!record) return { ok: false, error: "未找到 A 记录" };

        const res = await fetch(
            `https://api.cloudflare.com/client/v4/zones/${zoneId}/dns_records/${record.id}`,
            {
                method: "PUT",
                headers: {
                    Authorization: `Bearer ${env.CF_API}`,
                    "Content-Type": "application/json"
                },
                body: JSON.stringify({
                    type: "A",
                    name: domain,
                    content: ipv4,
                    ttl: 120
                })
            }
        ).then(r => r.json());

        return res.success ? { ok: true } : { ok: false, error: JSON.stringify(res.errors) };
    } catch (e) {
        return { ok: false, error: e.message };
    }
}

// ================= 日报 =================
async function recordDaily(env, ipv4) {
    const today = getBeijingDate();
    const key = "ddns_daily_date";

    const stored = await env.KV.get(key);
    if (stored !== today) {
        await env.KV.put(key, today);
        await env.KV.put("ddns_daily_history", "[]");
        await env.KV.put("ddns_daily_count", "0");
    }

    let history = JSON.parse(await env.KV.get("ddns_daily_history") || "[]");
    history.push({ ip: ipv4, time: getBeijingTime() });
    await env.KV.put("ddns_daily_history", JSON.stringify(history));

    const count = Number(await env.KV.get("ddns_daily_count") || 0) + 1;
    await env.KV.put("ddns_daily_count", String(count));
}

async function trySendDailyReport(env) {
    if (getBeijingHour() !== 0) return;

    const today = getBeijingDate();
    const sent = await env.KV.get("ddns_daily_date");
    if (sent === `${today}_sent`) return;

    const history = JSON.parse(await env.KV.get("ddns_daily_history") || "[]");
    const count = Number(await env.KV.get("ddns_daily_count") || 0);
    const lastIP = await env.KV.get("ddns_last_ip") || "未知";
    const ipinfo = lastIP !== "未知" ? await getIPInfo(lastIP) : {};

    await sendTG(env, lastIP, ipinfo, "daily", {
        date: today,
        count,
        history
    });

    await env.KV.put("ddns_daily_date", `${today}_sent`);
}

// ================= Telegram =================
async function sendTG(env, info, ipinfo, type, stats = {}) {
    if (!env.TG_BOT_TOKEN || !env.TG_CHAT_ID) return;

    const time = getBeijingTime();
    let msg = "";

    // ---------- 优化 IP 历史显示 ----------
    let historyText = "无";
    if (stats.history && stats.history.length) {
        historyText = stats.history
            .map((h, i) => `${i + 1}. <code>${h.ip}</code>    <i>${h.time}</i>`)
            .join("\n");
    }

    if (type === "success") {
        msg = `
<b>🕒 Cloudflare DDNS 6 小时汇总</b>

<b>${env.DOMAIN}</b>
<b>更新次数：</b>${stats.count}

<b>IP 变化历史：</b>
${historyText}

<b>当前 IP：</b>${info}
<b>运营商：</b>${ipinfo?.isp || "未知"}
<b>时间：</b>${time}
`;
    } else if (type === "daily") {
        msg = `
<b>📅 Cloudflare DDNS 日报</b>

<b>${env.DOMAIN}</b>
<b>日期：</b>${stats.date}
<b>更新次数：</b>${stats.count}

<b>IP 变化记录：</b>
${historyText}

<b>当前 IP：</b>${info}
<b>运营商：</b>${ipinfo?.isp || "未知"}
<b>时间：</b>${time}
`;
    } else if (type === "ip_error") {
        msg = `
<b>🚨 DDNS IP 获取失败</b>

来源：ip.164746.xyz
错误：${info}
时间：${time}
`;
    } else {
        msg = `
<b>❌ Cloudflare DDNS 错误</b>

域名：${env.DOMAIN}
信息：${info}
时间：${time}
`;
    }

    await fetch(`https://api.telegram.org/bot${env.TG_BOT_TOKEN}/sendMessage`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
            chat_id: env.TG_CHAT_ID,
            text: msg,
            parse_mode: "HTML"
        })
    });
}

// ================= 时间工具 =================
function getBeijingTime() {
    return new Date(Date.now() + 8 * 3600 * 1000)
        .toISOString()
        .replace("T", " ")
        .split(".")[0];
}

function getBeijingDate() {
    return new Date(Date.now() + 8 * 3600 * 1000).toISOString().slice(0, 10);
}

function getBeijingHour() {
    return new Date(Date.now() + 8 * 3600 * 1000).getUTCHours();
}

function get6HourSlotKey() {
    const h = getBeijingHour();
    const slot =
        h < 6 ? "00-06" :
        h < 12 ? "06-12" :
        h < 18 ? "12-18" : "18-24";
    return `${getBeijingDate()}_${slot}`;
}
