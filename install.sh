#!/bin/bash
# 自动部署脚本：适用于 GitHub 远程一键安装

# 1. 环境检查与安装依赖
if [ "$EUID" -ne 0 ]; then echo "请使用 sudo 运行此脚本"; exit; fi

echo "检查依赖..."
apt-get update && apt-get install -y git python3-pip

# 2. 定义变量
INSTALL_DIR="/opt/univ-monitor"
REPO_URL="https://github.com/2019xuanying/changan.git"
TEMP_DIR="/tmp/changan-deploy"

# 3. 清理旧数据并克隆仓库
echo "正在从 GitHub 下载最新代码..."
rm -rf $TEMP_DIR
git clone $REPO_URL $TEMP_DIR

# 4. 创建部署目录并迁移文件
echo "正在安装到 $INSTALL_DIR ..."
mkdir -p $INSTALL_DIR/templates

# 迁移后端文件
cp $TEMP_DIR/backend/* $INSTALL_DIR/
# 迁移前端文件
cp $TEMP_DIR/frontend/index.html $INSTALL_DIR/templates/

# 5. 安装 Python 依赖
echo "正在安装 Python 依赖..."
pip3 install -r $INSTALL_DIR/requirements.txt

# 6. 初始化数据库 (如果不存在)
if [ ! -f "$INSTALL_DIR/monitor.db" ]; then
    echo "初始化数据库..."
    python3 $INSTALL_DIR/database.py
fi

# 7. 配置 Systemd 服务
echo "配置后台服务..."
cat << EOF > /etc/systemd/system/univ-monitor.service
[Unit]
Description=UNI-V Monitor Service
After=network.target

[Service]
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/python3 $INSTALL_DIR/app.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

# 8. 启动服务
systemctl daemon-reload
systemctl enable univ-monitor
systemctl restart univ-monitor

# 9. 清理
rm -rf $TEMP_DIR

echo "--------------------------------------"
echo "部署完成！"
echo "服务地址: http://<你的IP>:5000"
echo "如需更新代码，请在 /opt/univ-monitor 下执行 git pull 并重启服务"
echo "--------------------------------------"
