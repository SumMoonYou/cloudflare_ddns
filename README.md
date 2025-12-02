# Cloudflare DDNS 自动更新脚本

一个纯 Bash 脚本，用于自动更新 **Cloudflare** 上的 **A 记录**，实现动态 DNS (DDNS) 功能。该脚本定时获取外部 IP 地址，并将其更新到指定的 Cloudflare 域名解析中，支持 Telegram 通知，帮助你实时监控 IP 地址变化。

## 功能特点

- **自动检测 IP 变化**：仅在 IP 发生变化时更新 Cloudflare 记录，避免频繁请求。
- **Cloudflare DNS 自动更新**：通过 Cloudflare API 自动更新 DNS 记录。
- **Telegram 通知**：当 DNS 记录更新时，推送 Telegram 消息，实时通知。
- **定时任务管理**：支持每小时自动运行，定时更新。
- **日志记录**：所有 IP 更新或未变化的信息都会记录在本地日志，便于追溯。
- **简单易用**：只需要简单配置，就可以自动运行。

## 安装与配置

### 1. 安装

首先，下载 `cloudflare_ddns.sh` 脚本文件

```
bash -c "$(curl -L https://raw.githubusercontent.com/SumMoonYou/cloudflare_ddns/refs/heads/main/cloudflare_ddns.sh)" @ install
```

### 2. 配置

运行脚本并进行配置。配置项包括 Cloudflare 的 **API Token**、**Zone ID**、**DNS Record ID** 和 **Telegram 配置**（可选）。

脚本会提示输入：

- **Cloudflare API Token**：用于验证访问 Cloudflare API。
- **Zone ID**：Cloudflare 账户中域名的 Zone ID。
- **DNS Record ID**：需要更新的 DNS 记录的 ID。
- **域名**：需要更新解析的域名（如：`ddns.example.com`）。
- **是否启用 Telegram 通知**：选择是否使用 Telegram Bot 发送更新通知。

### 3. 定时任务

脚本会自动为你创建一个 **每小时** 执行一次的定时任务，检测 IP 是否变化，并进行 DNS 更新。系统会避免重复添加定时任务

## 脚本结构

- **cloudflare_ddns.sh**：主脚本文件，执行 DDNS 更新任务。
- **/etc/cf_ddds.conf**：配置文件，存储 API Token、Zone ID、DNS Record ID 和 Telegram 配置。
- **/var/lib/cf_last_ip.txt**：存储上次更新的 IP 地址，用于检测 IP 是否变化。
- **/var/log/cf_ddds.log**：日志文件，记录每次更新的详细信息。

## Telegram 通知格式

当 DNS 记录更新时，Telegram 会发送如下格式的消息：

```
🚀 DNS 记录已成功更新！

🌐 域 名 : `ddns.example.com`
━━━━━━━━━━━━━━
🆕 新 IP : `104.16.205.12`
📍 归属地 : 美国 — Cloudflare
━━━━━━━━━━━━━━
🕒 更 新 时 间 : `2025-12-01 14:52:33`

🔎 IP快速查询
• [ip.sb](https://ip.sb/ip/104.16.205.12)
• [ip-api](http://ip-api.com/json/104.16.205.12)

💡 已完成同步，无需手动处理。🥳

```

