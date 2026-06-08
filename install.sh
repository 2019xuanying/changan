#!/bin/bash

# ==========================================
# UNI-V 多租户双端口监控系统 - GitHub 远程部署脚本
# 架构: Flask(5000公开端口 + 5001管理端口)
# ==========================================

set -e

if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 sudo 运行此脚本 (例如: sudo bash install.sh)"
  exit 1
fi

APP_DIR="/opt/univ-monitor"
REPO_URL="https://raw.githubusercontent.com/2019xuanying/changan/main"

echo "▶ 1/5 更新系统源并安装依赖环境..."
apt-get update -y
apt-get install -y python3 python3-pip python3-venv curl

echo "▶ 2/5 创建项目目录结构: $APP_DIR"
mkdir -p "$APP_DIR/templates"
cd "$APP_DIR"

echo "▶ 3/5 从 GitHub 拉取核心代码与面板..."
curl -sSLo app.py "$REPO_URL/app.py"
curl -sSLo templates/index.html "$REPO_URL/templates/index.html"
curl -sSLo templates/admin.html "$REPO_URL/templates/admin.html"

echo "▶ 4/5 配置 Python 虚拟环境..."
python3 -m venv venv
./venv/bin/pip install flask requests werkzeug

echo "▶ 5/5 部署 Systemd 服务常驻运行..."
cat << EOF_SYSTEMD > /etc/systemd/system/univ-monitor.service
[Unit]
Description=UNI-V Dual-Port Monitor Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/venv/bin/python app.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_SYSTEMD

systemctl daemon-reload
systemctl enable univ-monitor.service
systemctl restart univ-monitor.service

echo ""
echo "=========================================================="
echo "✅ 部署完成！双端口隔离架构已启动！"
echo ""
echo "👤 [用户入口] 公开监控页 (无后台代码，防爆破):"
echo "🌐 端口: http://<你的IP>:5000"
echo ""
echo "👑 [管理入口] 内部管理中心 (请在防火墙严格限制访问IP):"
echo "🌐 端口: http://<你的IP>:5001"
echo "🔑 初始密码: admin123"
echo "=========================================================="
