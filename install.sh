#!/bin/bash
if [ "$EUID" -ne 0 ]; then echo "请使用 sudo 运行"; exit; fi

TARGET_DIR="/opt/univ-monitor"
mkdir -p $TARGET_DIR/templates

# 复制文件
cp ./backend/app.py $TARGET_DIR/
cp ./backend/database.py $TARGET_DIR/
cp ./frontend/index.html $TARGET_DIR/templates/

# 安装依赖
pip3 install -r ./backend/requirements.txt

# 初始化数据库
python3 $TARGET_DIR/database.py

# 创建服务
cat << EOF > /etc/systemd/system/univ-monitor.service
[Unit]
Description=UNI-V Monitor
After=network.target

[Service]
WorkingDirectory=$TARGET_DIR
ExecStart=/usr/bin/python3 $TARGET_DIR/app.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable univ-monitor
systemctl restart univ-monitor
echo "部署成功！"
