#!/bin/bash

# 配置文件路径
CONFIG_FILE="/etc/cf_ddds.conf"
SCRIPT_FILE="/usr/local/bin/cf_ddds_run.sh"

# 安装 jq，如果没有安装
install_jq() {
  if ! command -v jq &> /dev/null; then
    echo "jq 没有安装，正在安装..."
    if [ -f /etc/debian_version ]; then
      sudo apt-get update && sudo apt-get install -y jq
    elif [ -f /etc/redhat-release ]; then
      sudo yum install -y jq
    else
      echo "不支持的操作系统，请手动安装 jq。"
      exit 1
    fi
  else
    echo "jq 已经安装。"
  fi
}

# 安装功能
install_script() {
  echo "开始安装脚本..."

  # 检查是否存在配置文件和脚本，如果不存在则创建
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "配置文件不存在，创建配置文件..."
    touch "$CONFIG_FILE"
  fi

  if [ ! -f "$SCRIPT_FILE" ]; then
    echo "脚本文件不存在，创建脚本文件..."
    cat > "$SCRIPT_FILE" <<'EOF'
#!/bin/bash

# 读取配置文件中的信息
source /etc/cf_ddds.conf

# 获取当前公网 IP
CURRENT_IP=$(curl -s 'https://api.ipify.org')

# 获取当前时间
CURRENT_TIME=$(date "+%Y-%m-%d %H:%M:%S")

# 获取 Cloudflare API 响应并更新 DNS 记录
RESPONSE=$(curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$DNS_RECORD_ID" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{"type": "A", "name": "'$DOMAIN_NAME'", "content": "'$CURRENT_IP'", "ttl": 1, "proxied": false}')

# 检查更新是否成功
if echo "$RESPONSE" | grep -q '"success":true'; then
  # 更新成功，发送 Telegram 通知
  MESSAGE="*🔧 DNS 记录更新成功!*%0A
*域名:* \`$DOMAIN_NAME\`%0A
*IP地址:* \`$CURRENT_IP\`%0A
*更新时间:* \`$CURRENT_TIME\`%0A
%0A
*🎉 成功更新！*%0A
您可以访问 [Cloudflare 仪表板](https://dash.cloudflare.com) 来检查 DNS 设置。"

  curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
    -d "chat_id=$TG_CHAT_ID&text=$MESSAGE&parse_mode=Markdown"

  echo "DNS 记录更新成功，Telegram 通知已发送。"
else
  echo "DNS 记录更新失败。返回内容: $RESPONSE"
fi
EOF
    chmod +x "$SCRIPT_FILE"
  fi

  # 获取 Cloudflare Zone ID 和 DNS 记录 ID
  echo "请输入 Cloudflare API Token:"
  read CF_API_TOKEN
  echo "请输入 Cloudflare Zone ID:"
  read ZONE_ID
  echo "请输入域名 (例如：yx.fixbugs.dpdns.org):"
  read DOMAIN_NAME
  echo "请输入 Telegram Bot Token:"
  read TG_BOT_TOKEN
  echo "请输入 Telegram Chat ID:"
  read TG_CHAT_ID
  
  # 自动获取 DNS 记录 ID
  DNS_RECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$DOMAIN_NAME" \
    -H "Authorization: Bearer $CF_API_TOKEN" | jq -r '.result[0].id')

  # 如果获取失败，提示用户并退出
  if [ -z "$DNS_RECORD_ID" ]; then
    echo "获取 DNS 记录 ID 失败，请检查配置。"
    exit 1
  fi

  # 将配置信息写入配置文件
  echo "CF_API_TOKEN=\"$CF_API_TOKEN\"" > "$CONFIG_FILE"
  echo "ZONE_ID=\"$ZONE_ID\"" >> "$CONFIG_FILE"
  echo "DNS_RECORD_ID=\"$DNS_RECORD_ID\"" >> "$CONFIG_FILE"
  echo "DOMAIN_NAME=\"$DOMAIN_NAME\"" >> "$CONFIG_FILE"
  echo "TG_BOT_TOKEN=\"$TG_BOT_TOKEN\"" >> "$CONFIG_FILE"
  echo "TG_CHAT_ID=\"$TG_CHAT_ID\"" >> "$CONFIG_FILE"

  # 添加定时任务
  (crontab -l 2>/dev/null; echo "0 * * * * $SCRIPT_FILE") | crontab -

  echo "安装完成，定时任务已设置，每小时执行一次。"
}

# 卸载功能
uninstall_script() {
  echo "开始卸载脚本..."

  # 删除脚本和配置文件
  rm -f "$SCRIPT_FILE"
  rm -f "$CONFIG_FILE"

  # 删除定时任务
  crontab -l | grep -v "$SCRIPT_FILE" | crontab -

  echo "卸载完成。"
}

# 主菜单
echo "请选择操作:"
echo "1. 安装脚本"
echo "2. 卸载脚本"
read -p "请输入选择 (1 或 2): " choice

case $choice in
  1)
    install_jq  # 安装 jq
    install_script
    ;;
  2)
    uninstall_script
    ;;
  *)
    echo "无效选择，请输入 1 或 2。"
    ;;
esac
