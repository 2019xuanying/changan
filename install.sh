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
from flask import Flask, jsonify, request

app = Flask(__name__)
CONFIG_FILE = "config.json"

# 全局状态字典，新增了 traffic 字段用于存放流量数据
cached_data = {
    "status": {}, 
    "location": {}, 
    "traffic": {"left": "0", "unit": "MB", "expireDate": "--"},
    "last_update": "尚未获取"
}
current_config = {"carId": "", "token": "", "fetch_interval": 900}

# ================= 加载与保存配置 =================
def load_config():
    global current_config
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE, 'r', encoding='utf-8') as f:
            current_config.update(json.load(f))

def save_config(config_data):
    with open(CONFIG_FILE, 'w', encoding='utf-8') as f:
        json.dump(config_data, f, ensure_ascii=False, indent=4)

load_config()

# ================= 后台抓取线程 =================
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
                
                # 1. 获取车况核心数据 (注意 keys=%2A 已经修复)
                post_headers = headers.copy()
                post_headers["Content-Type"] = "application/x-www-form-urlencoded; charset=utf-8"
                payload = f"carId={current_config['carId']}&keys=%2A&token={current_config['token']}"
                
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

                # 2. 获取实时定位
                loc_url = f"https://m.iov.changan.com.cn/app2/api/car/location?carId={current_config['carId']}&mapType=GCJ02&token={current_config['token']}"
                res_loc = requests.get(loc_url, headers=headers, timeout=10).json()
                if res_loc.get("success"):
                    loc = res_loc["data"]
                    cached_data["location"] = {
                        "city": loc.get("city", ""), 
                        "address": loc.get("address", ""),
                        "lat": loc.get("lat", 0), 
                        "lng": loc.get("lng", 0)
                    }

                # 3. 获取车机娱乐流量
                traffic_url = f"https://m.iov.changan.com.cn/app2/api/mall/digital/balance/app?carId={current_config['carId']}&token={current_config['token']}"
                res_traffic = requests.get(traffic_url, headers=headers, timeout=10).json()
                if res_traffic.get("success") and res_traffic["data"]:
                    traffic_info = res_traffic["data"][0]["balances"][0]
                    cached_data["traffic"] = {
                        "left": traffic_info.get("left", "0"),
                        "unit": traffic_info.get("unit", "MB"),
                        "expireDate": traffic_info.get("expirationTime", "").split(" ")[0] # 截取年月日
                    }

                cached_data["last_update"] = time.strftime("%Y-%m-%d %H:%M:%S")
                print(f"[成功] 数据已更新: {cached_data['last_update']}")
                
            except Exception as e:
                print(f"[错误] 数据拉取失败: {e}")
        
        # 如果还没配置 Token，每 10 秒检查一次；如果已配置，按设定间隔 (15分钟) 休眠防风控
        sleep_time = current_config.get("fetch_interval", 900) if current_config.get("token") else 10
        time.sleep(sleep_time)

# 启动后台独立线程，不阻塞主程序
threading.Thread(target=fetch_changan_data, daemon=True).start()

# ================= Flask 路由接口 =================

@app.route('/')
def index():
    # 绕过 Jinja2 模板渲染引擎，直接读取 HTML 文件返回，彻底解决 500 报错
    try:
        with open('templates/index.html', 'r', encoding='utf-8') as f:
            return f.read()
    except FileNotFoundError:
        return "找不到前端模板文件，请确保 templates/index.html 存在。", 404

@app.route('/api/car-status', methods=['GET'])
def get_car_status():
    """提供给前端拉取数据的核心接口"""
    return jsonify({
        "code": 200, 
        "data": cached_data, 
        "has_config": bool(current_config.get("token"))
    })

@app.route('/api/config', methods=['GET', 'POST'])
def handle_config():
    """处理前端提交的 Token 保存请求"""
    global current_config
    if request.method == 'POST':
        data = request.json
        current_config["carId"] = data.get("carId", "").strip()
        current_config["token"] = data.get("token", "").strip()
        save_config(current_config)
        
        # 强制唤醒或重启获取逻辑（简单的状态重置）
        return jsonify({"code": 200, "message": "配置已保存，系统将在后台重新获取数据"})
        
    return jsonify({
        "code": 200, 
        "data": {
            "carId": current_config.get("carId"), 
            "token": current_config.get("token")
        }
    })

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
    <title>UNI-V 车况实时看板</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://unpkg.com/vue@3/dist/vue.global.js"></script>
</head>
<body class="bg-slate-900 text-white min-h-screen p-4 md:p-6 font-sans selection:bg-emerald-500 selection:text-white">
    <div id="app" class="max-w-4xl mx-auto">
        
        <header class="flex flex-col md:flex-row justify-between md:items-end border-b border-slate-700 pb-4 mb-6 gap-4">
            <div>
                <h1 class="text-3xl font-bold text-emerald-400 tracking-wider">UNI-V <span class="text-slate-500 text-xl font-normal">| 实时终端</span></h1>
                <p class="text-slate-400 text-sm mt-1">Changan Telematics Dashboard</p>
            </div>
            <div class="flex items-center gap-4 self-end md:self-auto">
                <div class="text-right">
                    <p class="text-xs text-slate-400 uppercase tracking-wider">Last Sync</p>
                    <p class="text-lg font-mono text-emerald-300">{{ lastUpdate }}</p>
                </div>
                <button @click="showSettings = true" class="p-2.5 bg-slate-800 rounded-lg border border-slate-600 hover:bg-slate-700 hover:border-emerald-500 transition-all group">
                    <svg class="w-5 h-5 text-slate-300 group-hover:text-emerald-400 transition-colors" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"></path><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"></path></svg>
                </button>
            </div>
        </header>

        <div v-if="showSettings" class="fixed inset-0 bg-black/70 backdrop-blur-sm flex items-center justify-center z-50 p-4">
            <div class="bg-slate-800 p-6 rounded-2xl border border-slate-600 w-full max-w-md shadow-2xl">
                <div class="flex justify-between items-center mb-5">
                    <h2 class="text-xl font-bold text-slate-100">系统配置</h2>
                    <button @click="showSettings = false" class="text-slate-400 hover:text-white">✕</button>
                </div>
                <div class="space-y-4 text-left">
                    <div>
                        <label class="block text-sm text-slate-400 mb-1.5">车辆 ID (CarId)</label>
                        <input v-model="configForm.carId" type="text" placeholder="输入 32 位 CarId" class="w-full bg-slate-900 border border-slate-600 rounded-lg px-3 py-2.5 text-sm focus:outline-none focus:border-emerald-500 focus:ring-1 focus:ring-emerald-500 transition-all text-slate-200">
                    </div>
                    <div>
                        <label class="block text-sm text-slate-400 mb-1.5">访问令牌 (Token)</label>
                        <textarea v-model="configForm.token" rows="3" placeholder="粘贴抓包获取的 Token" class="w-full bg-slate-900 border border-slate-600 rounded-lg px-3 py-2.5 text-sm font-mono focus:outline-none focus:border-emerald-500 focus:ring-1 focus:ring-emerald-500 transition-all text-slate-200 break-all"></textarea>
                    </div>
                </div>
                <div class="mt-8 flex justify-end gap-3">
                    <button @click="showSettings = false" class="px-5 py-2.5 rounded-lg text-sm text-slate-300 hover:bg-slate-700 transition-colors">取消</button>
                    <button @click="saveConfig" class="px-5 py-2.5 bg-emerald-600 hover:bg-emerald-500 rounded-lg text-sm font-medium transition-colors text-white shadow-lg shadow-emerald-900/50">保存并重启同步</button>
                </div>
            </div>
        </div>

        <div v-if="!hasConfig" class="text-center py-24 bg-slate-800/50 rounded-2xl border border-slate-700/50 border-dashed">
            <svg class="w-16 h-16 mx-auto text-slate-600 mb-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"></path></svg>
            <p class="text-slate-300 text-lg font-medium">系统尚未配置认证信息</p>
            <p class="text-slate-500 mt-2 text-sm">请点击右上角设置按钮，填入抓包获取的 CarId 与 Token</p>
            <button @click="showSettings = true" class="mt-6 px-6 py-2 bg-slate-700 hover:bg-slate-600 rounded-lg text-sm transition-colors text-white">立即配置</button>
        </div>

        <div v-else class="grid grid-cols-1 md:grid-cols-2 gap-5 md:gap-6">
            
            <div class="bg-slate-800 rounded-2xl p-5 shadow-xl border border-slate-700/80 relative overflow-hidden">
                <div class="absolute top-0 right-0 w-24 h-24 bg-emerald-500/10 rounded-bl-full -z-10"></div>
                <h2 class="text-lg font-semibold mb-5 text-slate-200 flex items-center gap-2">
                    <span class="w-1.5 h-5 bg-emerald-500 rounded-full inline-block"></span>动力与能耗
                </h2>
                <div class="space-y-4">
                    <div class="flex justify-between items-center">
                        <span class="text-slate-400 text-sm">表显总里程</span>
                        <span class="font-mono text-lg tracking-tight">{{ status.totalOdometer || 0 }} <span class="text-xs text-slate-500 ml-0.5">km</span></span>
                    </div>
                    <div class="flex justify-between items-center">
                        <span class="text-slate-400 text-sm">剩余油量</span>
                        <span class="font-mono text-lg text-amber-400 tracking-tight">{{ status.fuelLeftover || 0 }} <span class="text-xs text-amber-600/70 ml-0.5">L</span></span>
                    </div>
                    <div class="flex justify-between items-center">
                        <span class="text-slate-400 text-sm">预估续航</span>
                        <span class="font-mono text-lg text-emerald-400 tracking-tight">{{ status.remainedOilMile || 0 }} <span class="text-xs text-emerald-600/70 ml-0.5">km</span></span>
                    </div>
                </div>

                <div class="mt-5 pt-4 border-t border-slate-700/60 flex justify-between items-center">
                    <div>
                        <span class="text-slate-400 text-sm flex items-center gap-1.5">
                            <svg class="w-4 h-4 text-blue-400" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8.111 16.404a5.5 5.5 0 017.778 0M12 20h.01m-7.08-7.071c3.904-3.905 10.236-3.905 14.141 0M1.394 9.393c5.857-5.857 15.355-5.857 21.213 0"></path></svg>
                            车机流量
                        </span>
                        <p class="text-[11px] text-slate-500 mt-1">到期: {{ traffic.expireDate || '--' }}</p>
                    </div>
                    <div class="text-right">
                        <span class="font-mono text-xl text-blue-400">{{ traffic.left || 0 }}</span>
                        <span class="text-xs text-blue-500 ml-1">{{ traffic.unit || 'MB' }}</span>
                    </div>
                </div>
            </div>

            <div class="bg-slate-800 rounded-2xl p-5 shadow-xl border border-slate-700/80 relative overflow-hidden">
                <div class="absolute top-0 right-0 w-24 h-24 bg-purple-500/10 rounded-bl-full -z-10"></div>
                <h2 class="text-lg font-semibold mb-5 text-slate-200 flex items-center gap-2">
                    <span class="w-1.5 h-5 bg-purple-500 rounded-full inline-block"></span>车身状态
                </h2>
                <div class="grid grid-cols-2 gap-y-5 gap-x-6">
                    <div>
                        <p class="text-slate-500 text-xs mb-1">发动机状态</p>
                        <p class="font-medium" :class="status.engineStatus === 2 ? 'text-slate-300' : 'text-emerald-400 animate-pulse'">
                            {{ status.engineStatus === 2 ? '已熄火' : '运行中' }}
                        </p>
                    </div>
                    <div>
                        <p class="text-slate-500 text-xs mb-1">车外环境温度</p>
                        <p class="font-mono text-slate-200">{{ status.environmentalTemp || '--' }}<span class="text-xs text-slate-500 ml-1">°C</span></p>
                    </div>
                    <div>
                        <p class="text-slate-500 text-xs mb-1">主驾车门锁</p>
                        <p class="font-medium flex items-center gap-1" :class="status.leftFrontDoorLock === 0 ? 'text-emerald-400' : 'text-red-400'">
                            <span v-if="status.leftFrontDoorLock === 0" class="w-2 h-2 rounded-full bg-emerald-400"></span>
                            <span v-else class="w-2 h-2 rounded-full bg-red-400 animate-ping"></span>
                            {{ status.leftFrontDoorLock === 0 ? '已落锁' : '未落锁' }}
                        </p>
                    </div>
                    <div>
                        <p class="text-slate-500 text-xs mb-1">后备箱状态</p>
                        <p class="font-medium" :class="status.trunk === 0 ? 'text-emerald-400' : 'text-amber-400'">
                            {{ status.trunk === 0 ? '已关闭' : '开启中' }}
                        </p>
                    </div>
                </div>
                <div class="mt-5 pt-4 border-t border-slate-700/60 grid grid-cols-4 text-center">
                    <div><p class="text-[10px] text-slate-500 mb-0.5">左前</p><p class="text-sm font-mono" :class="status.lfTyrePressure < 200 ? 'text-red-400' : 'text-slate-300'">{{ status.lfTyrePressure || '--' }}</p></div>
                    <div><p class="text-[10px] text-slate-500 mb-0.5">右前</p><p class="text-sm font-mono" :class="status.rfTyrePressure < 200 ? 'text-red-400' : 'text-slate-300'">{{ status.rfTyrePressure || '--' }}</p></div>
                    <div><p class="text-[10px] text-slate-500 mb-0.5">左后</p><p class="text-sm font-mono" :class="status.lrTyrePressure < 200 ? 'text-red-400' : 'text-slate-300'">{{ status.lrTyrePressure || '--' }}</p></div>
                    <div><p class="text-[10px] text-slate-500 mb-0.5">右后</p><p class="text-sm font-mono" :class="status.rrTyrePressure < 200 ? 'text-red-400' : 'text-slate-300'">{{ status.rrTyrePressure || '--' }}</p></div>
                </div>
            </div>

            <div class="bg-slate-800 rounded-2xl p-5 shadow-xl border border-slate-700/80 md:col-span-2 relative overflow-hidden">
                <div class="absolute top-0 right-0 w-32 h-32 bg-rose-500/5 rounded-bl-full -z-10"></div>
                <h2 class="text-lg font-semibold mb-4 text-slate-200 flex items-center gap-2">
                    <span class="w-1.5 h-5 bg-rose-500 rounded-full inline-block"></span>末次上报位置
                </h2>
                <div class="flex flex-col md:flex-row justify-between items-start md:items-center gap-4">
                    <div class="flex items-start gap-3">
                        <div class="mt-1 p-2 bg-slate-900 rounded-lg border border-slate-700">
                            <svg class="w-5 h-5 text-rose-400" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17.657 16.657L13.414 20.9a1.998 1.998 0 01-2.827 0l-4.244-4.243a8 8 0 1111.314 0z"></path><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 11a3 3 0 11-6 0 3 3 0 016 0z"></path></svg>
                        </div>
                        <div>
                            <p class="text-lg font-medium text-slate-100">{{ location.city || '未知城市' }}</p>
                            <p class="text-sm text-slate-400 mt-0.5">{{ location.address || '等待卫星定位解析...' }}</p>
                        </div>
                    </div>
                    <div class="flex gap-6 bg-slate-900/50 px-4 py-2.5 rounded-lg border border-slate-700/50 w-full md:w-auto">
                        <div>
                            <p class="text-[10px] text-slate-500 uppercase tracking-widest mb-0.5">Longitude</p>
                            <p class="font-mono text-sm text-slate-300">{{ location.lng || '0.000000' }}</p>
                        </div>
                        <div>
                            <p class="text-[10px] text-slate-500 uppercase tracking-widest mb-0.5">Latitude</p>
                            <p class="font-mono text-sm text-slate-300">{{ location.lat || '0.000000' }}</p>
                        </div>
                    </div>
                </div>
            </div>
        </div>
    </div>

    <script>
        const { createApp, ref, onMounted } = Vue

        createApp({
            setup() {
                // 响应式数据
                const status = ref({}); 
                const location = ref({}); 
                const traffic = ref({}); // 新增流量对象
                const lastUpdate = ref("--");
                
                const hasConfig = ref(true); 
                const showSettings = ref(false);
                const configForm = ref({ carId: '', token: '' });

                // 从后端拉取最新数据
                const fetchData = async () => {
                    try {
                        const res = await fetch('/api/car-status');
                        const json = await res.json();
                        hasConfig.value = json.has_config;
                        
                        if (json.code === 200 && json.data) {
                            status.value = json.data.status || {};
                            location.value = json.data.location || {};
                            traffic.value = json.data.traffic || {}; // 赋值流量数据
                            lastUpdate.value = json.data.last_update || "--";
                        }
                    } catch (e) {
                        console.error("拉取数据失败", e);
                    }
                };

                // 从后端拉取当前配置（用于回显到设置面板）
                const fetchConfig = async () => {
                    try {
                        const res = await fetch('/api/config');
                        const json = await res.json();
                        if(json.data) {
                            configForm.value.carId = json.data.carId || '';
                            configForm.value.token = json.data.token || '';
                            if(!json.data.token) hasConfig.value = false;
                        }
                    } catch (e) { console.error(e); }
                };

                // 保存配置到后端
                const saveConfig = async () => {
                    if (!configForm.value.carId || !configForm.value.token) {
                        alert("CarId 和 Token 不能为空！");
                        return;
                    }
                    try {
                        await fetch('/api/config', {
                            method: 'POST',
                            headers: { 'Content-Type': 'application/json' },
                            body: JSON.stringify(configForm.value)
                        });
                        showSettings.value = false;
                        hasConfig.value = true;
                        lastUpdate.value = "正在重新同步...";
                        
                        // 稍微延迟一下，给后端脚本去长安服务器拿数据的时间
                        setTimeout(fetchData, 2000); 
                    } catch (e) { 
                        alert("保存配置失败，请检查网络"); 
                    }
                };

                onMounted(() => {
                    fetchConfig();
                    fetchData();
                    // 前端每 10 秒去自己服务器读一次缓存数据（不耗费长安服务器资源）
                    setInterval(fetchData, 10000); 
                });

                return { 
                    status, location, traffic, lastUpdate, 
                    hasConfig, showSettings, configForm, 
                    saveConfig 
                }
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
