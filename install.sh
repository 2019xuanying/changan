#!/bin/bash

# ==========================================
# UNI-V 实时大屏 - 一键部署脚本
# 适用系统: Ubuntu / Debian
# ==========================================

set -e

# 1. 检查 root 权限
if [ "$EUID" -ne 0 ]; then
  echo "请使用 sudo 运行此脚本 (例如: sudo bash install.sh)"
  exit 1
fi

echo "▶ 1/5 更新系统源并安装依赖..."
apt-get update -y
apt-get install -y python3 python3-pip python3-venv

APP_DIR="/opt/univ-monitor"
echo "▶ 2/5 创建项目目录结构: $APP_DIR"
mkdir -p "$APP_DIR/templates"
cd "$APP_DIR"

# ==========================================
# 写入后端 Python 代码
# ==========================================
echo "▶ 3/5 写入后端服务核心代码..."
cat << 'EOF_PYTHON' > app.py
import time
import threading
import json
import os
import requests
from flask import Flask, jsonify, request, render_template

app = Flask(__name__)
CONFIG_FILE = "config.json"

# 全局状态
cached_data = {"status": {}, "location": {}, "last_update": "未获取"}
current_config = {"carId": "", "token": "", "fetch_interval": 900}

# 加载配置
def load_config():
    global current_config
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE, 'r', encoding='utf-8') as f:
            current_config.update(json.load(f))

def save_config(config_data):
    with open(CONFIG_FILE, 'w', encoding='utf-8') as f:
        json.dump(config_data, f, ensure_ascii=False, indent=4)

load_config()

def fetch_changan_data():
    global cached_data
    while True:
        if current_config.get("token") and current_config.get("carId"):
            try:
                headers = {
                    "Host": "m.iov.changan.com.cn",
                    "User-Agent": "TestApp/2.2.3 (com.changan.uni; build:223036; iOS 16.7.15) Alamofire/5.11.0",
                    "vcs-app-id": "inCall"
                }
                
                # 获取车况
                post_headers = headers.copy()
                post_headers["Content-Type"] = "application/x-www-form-urlencoded; charset=utf-8"
                payload = f"carId={current_config['carId']}&keys=*&token={current_config['token']}"
                res_data = requests.post("https://m.iov.changan.com.cn/app2/api/car/data", headers=post_headers, data=payload, timeout=10).json()
                
                if res_data.get("success"):
                    car = res_data["data"]
                    cached_data["status"] = {
                        "gpsTime": car.get("gpsTime", "未知"),
                        "totalOdometer": car.get("totalOdometer", 0),
                        "fuelLeftover": car.get("fuelLeftover", 0),
                        "remainedOilMile": car.get("remainedOilMile", 0),
                        "batteryVoltage": car.get("batteryVoltage", 0),
                        "lfTyrePressure": car.get("lfTyrePressure", 0),
                        "rfTyrePressure": car.get("rfTyrePressure", 0),
                        "lrTyrePressure": car.get("lrTyrePressure", 0),
                        "rrTyrePressure": car.get("rrTyrePressure", 0),
                        "engineStatus": car.get("engineStatus", 2),
                        "leftFrontDoorLock": car.get("leftFrontDoorLock", 0),
                        "trunk": car.get("trunk", 0),
                        "hood": car.get("hood", 0),
                        "airConditioningSetTemperature": car.get("airConditioningSetTemperature", 0),
                        "environmentalTemp": car.get("environmentalTemp", 0)
                    }

                # 获取定位
                loc_url = f"https://m.iov.changan.com.cn/app2/api/car/location?carId={current_config['carId']}&mapType=GCJ02&token={current_config['token']}"
                res_loc = requests.get(loc_url, headers=headers, timeout=10).json()
                if res_loc.get("success"):
                    loc = res_loc["data"]
                    cached_data["location"] = {
                        "city": loc.get("city", ""), "address": loc.get("address", ""),
                        "lat": loc.get("lat", 0), "lng": loc.get("lng", 0)
                    }

                cached_data["last_update"] = time.strftime("%Y-%m-%d %H:%M:%S")
            except Exception as e:
                print(f"数据拉取失败: {e}")
        
        # 休眠，如果没配置则缩短检查时间
        sleep_time = current_config.get("fetch_interval", 900) if current_config.get("token") else 10
        time.sleep(sleep_time)

# 启动抓取线程
threading.Thread(target=fetch_changan_data, daemon=True).start()

@app.route('/')
def index():
    # 让 Flask 直接渲染静态 HTML
    return render_template('index.html')

@app.route('/api/car-status', methods=['GET'])
def get_car_status():
    return jsonify({"code": 200, "data": cached_data, "has_config": bool(current_config.get("token"))})

@app.route('/api/config', methods=['GET', 'POST'])
def handle_config():
    global current_config
    if request.method == 'POST':
        data = request.json
        current_config["carId"] = data.get("carId", "").strip()
        current_config["token"] = data.get("token", "").strip()
        save_config(current_config)
        return jsonify({"code": 200, "message": "配置已保存，系统将在后台重新获取数据"})
    return jsonify({"code": 200, "data": {"carId": current_config.get("carId"), "token": current_config.get("token")}})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
EOF_PYTHON

# ==========================================
# 写入前端 HTML 代码 (带设置面板)
# ==========================================
echo "▶ 4/5 写入前端看板与设置界面..."
cat << 'EOF_HTML' > templates/index.html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>UNI-V 车况看板</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://unpkg.com/vue@3/dist/vue.global.js"></script>
</head>
<body class="bg-slate-900 text-white min-h-screen p-6 font-sans">
    <div id="app" class="max-w-4xl mx-auto">
        <header class="flex justify-between items-end border-b border-slate-700 pb-4 mb-6">
            <div>
                <h1 class="text-3xl font-bold text-emerald-400">UNI-V (浙G2Z32D)</h1>
                <p class="text-slate-400 text-sm mt-1">车况实时大屏</p>
            </div>
            <div class="text-right flex items-center gap-4">
                <div>
                    <p class="text-sm text-slate-300">最后更新</p>
                    <p class="text-lg font-mono text-emerald-300">{{ lastUpdate }}</p>
                </div>
                <button @click="showSettings = true" class="p-2 bg-slate-800 rounded-lg border border-slate-600 hover:bg-slate-700 transition">
                    <svg class="w-6 h-6 text-slate-300" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"></path><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"></path></svg>
                </button>
            </div>
        </header>

        <div v-if="showSettings" class="fixed inset-0 bg-black/60 flex items-center justify-center z-50">
            <div class="bg-slate-800 p-6 rounded-xl border border-slate-600 w-full max-w-md shadow-2xl">
                <h2 class="text-xl font-bold mb-4">系统配置</h2>
                <div class="space-y-4">
                    <div>
                        <label class="block text-sm text-slate-400 mb-1">车辆 ID (CarId)</label>
                        <input v-model="configForm.carId" type="text" class="w-full bg-slate-900 border border-slate-600 rounded px-3 py-2 text-sm focus:outline-none focus:border-emerald-500">
                    </div>
                    <div>
                        <label class="block text-sm text-slate-400 mb-1">访问令牌 (Token)</label>
                        <textarea v-model="configForm.token" rows="3" class="w-full bg-slate-900 border border-slate-600 rounded px-3 py-2 text-sm font-mono focus:outline-none focus:border-emerald-500"></textarea>
                    </div>
                </div>
                <div class="mt-6 flex justify-end gap-3">
                    <button @click="showSettings = false" class="px-4 py-2 rounded text-slate-300 hover:bg-slate-700 transition">取消</button>
                    <button @click="saveConfig" class="px-4 py-2 bg-emerald-600 hover:bg-emerald-500 rounded font-medium transition text-white">保存配置</button>
                </div>
            </div>
        </div>

        <div v-if="!hasConfig" class="text-center py-20">
            <p class="text-slate-400 text-lg">系统尚未配置 Token，请点击右上角设置按钮配置参数。</p>
        </div>

        <div v-else class="grid grid-cols-1 md:grid-cols-2 gap-6">
            <div class="bg-slate-800 rounded-xl p-5 shadow-lg border border-slate-700">
                <h2 class="text-xl font-semibold mb-4 text-slate-200 border-l-4 border-emerald-500 pl-2">行驶与能耗</h2>
                <div class="space-y-3">
                    <div class="flex justify-between"><span class="text-slate-400">总里程</span><span class="font-mono text-lg">{{ status.totalOdometer || 0 }} km</span></div>
                    <div class="flex justify-between"><span class="text-slate-400">剩余油量</span><span class="font-mono text-lg text-amber-400">{{ status.fuelLeftover || 0 }} L</span></div>
                    <div class="flex justify-between"><span class="text-slate-400">预估续航</span><span class="font-mono text-lg text-emerald-400">{{ status.remainedOilMile || 0 }} km</span></div>
                </div>
            </div>

            <div class="bg-slate-800 rounded-xl p-5 shadow-lg border border-slate-700">
                <h2 class="text-xl font-semibold mb-4 text-slate-200 border-l-4 border-purple-500 pl-2">车身状态</h2>
                <div class="grid grid-cols-2 gap-y-3 gap-x-6">
                    <div class="flex justify-between"><span class="text-slate-400">发动机</span><span :class="status.engineStatus === 2 ? 'text-red-400' : 'text-emerald-400'">{{ status.engineStatus === 2 ? '熄火' : '运行' }}</span></div>
                    <div class="flex justify-between"><span class="text-slate-400">左前门锁</span><span :class="status.leftFrontDoorLock === 0 ? 'text-emerald-400' : 'text-red-400'">{{ status.leftFrontDoorLock === 0 ? '已落锁' : '未锁' }}</span></div>
                    <div class="flex justify-between"><span class="text-slate-400">后备箱</span><span :class="status.trunk === 0 ? 'text-emerald-400' : 'text-amber-400'">{{ status.trunk === 0 ? '关闭' : '开启' }}</span></div>
                    <div class="flex justify-between"><span class="text-slate-400">车外温度</span><span class="font-mono">{{ status.environmentalTemp || '--' }}°C</span></div>
                </div>
            </div>

            <div class="bg-slate-800 rounded-xl p-5 shadow-lg border border-slate-700 md:col-span-2">
                <h2 class="text-xl font-semibold mb-4 text-slate-200 border-l-4 border-rose-500 pl-2">实时定位</h2>
                <div class="flex flex-col md:flex-row justify-between">
                    <div>
                        <p class="text-slate-400 mb-1">当前位置</p>
                        <p class="text-lg font-medium text-slate-200">{{ location.city }} {{ location.address }}</p>
                    </div>
                    <div class="mt-4 md:mt-0 flex gap-6 text-right">
                        <div><p class="text-slate-500 text-sm">经度</p><p class="font-mono text-sm text-slate-300">{{ location.lng }}</p></div>
                        <div><p class="text-slate-500 text-sm">纬度</p><p class="font-mono text-sm text-slate-300">{{ location.lat }}</p></div>
                    </div>
                </div>
            </div>
        </div>
    </div>

    <script>
        const { createApp, ref, onMounted } = Vue
        createApp({
            setup() {
                const status = ref({}); const location = ref({}); const lastUpdate = ref("加载中...");
                const hasConfig = ref(false); const showSettings = ref(false);
                const configForm = ref({ carId: '', token: '' });

                const fetchData = async () => {
                    try {
                        const res = await fetch('/api/car-status');
                        const json = await res.json();
                        hasConfig.value = json.has_config;
                        if (json.code === 200 && json.data.status) {
                            status.value = json.data.status;
                            location.value = json.data.location;
                            lastUpdate.value = json.data.last_update;
                        }
                    } catch (e) { console.error(e); }
                };

                const fetchConfig = async () => {
                    try {
                        const res = await fetch('/api/config');
                        const json = await res.json();
                        configForm.value.carId = json.data.carId || '';
                        configForm.value.token = json.data.token || '';
                    } catch (e) { console.error(e); }
                };

                const saveConfig = async () => {
                    try {
                        await fetch('/api/config', {
                            method: 'POST',
                            headers: { 'Content-Type': 'application/json' },
                            body: JSON.stringify(configForm.value)
                        });
                        showSettings.value = false;
                        hasConfig.value = true;
                        setTimeout(fetchData, 2000); // 保存后稍微等一下让后端抓取
                        alert("配置保存成功！");
                    } catch (e) { alert("保存失败"); }
                };

                onMounted(() => {
                    fetchData();
                    fetchConfig();
                    setInterval(fetchData, 10000);
                });

                return { status, location, lastUpdate, hasConfig, showSettings, configForm, saveConfig }
            }
        }).mount('#app')
    </script>
</body>
</html>
EOF_HTML

# ==========================================
# 设置虚拟环境并配置 Systemd 守护进程
# ==========================================
echo "▶ 5/5 配置虚拟环境与 systemd 服务..."

# 创建并激活虚拟环境
python3 -m venv venv
./venv/bin/pip install flask requests

# 创建 systemd 服务文件
cat << EOF_SYSTEMD > /etc/systemd/system/univ-monitor.service
[Unit]
Description=UNI-V Monitor Web Service
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

# 启动服务
systemctl daemon-reload
systemctl enable univ-monitor.service
systemctl restart univ-monitor.service

echo ""
echo "=========================================================="
echo "✅ 部署完成！服务已在后台常驻运行。"
echo "🌐 请在浏览器访问: http://<你的服务器公网IP>:5000"
echo "⚙️  首次访问后，请点击右上角【设置】按钮输入你的 CarId 和 Token。"
echo "=========================================================="
