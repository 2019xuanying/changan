#!/bin/bash

# ==========================================
# UNI-V 多租户双端口监控系统 - 一键部署脚本
# 架构: Flask(5000公开端口 + 5001管理端口)
# UI: 完全保留原版界面风格与数据映射
# ==========================================

set -e

if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 sudo 运行此脚本 (例如: sudo bash install.sh)"
  exit 1
fi

APP_DIR="/opt/univ-monitor"
echo "▶ 1/5 更新系统源并安装依赖环境..."
apt-get update -y
apt-get install -y python3 python3-pip python3-venv

echo "▶ 2/5 创建项目目录结构: $APP_DIR"
mkdir -p "$APP_DIR/templates"
cd "$APP_DIR"

# ==========================================
# 写入后端 Python 代码 (双服务架构)
# ==========================================
echo "▶ 3/5 写入双端口后端引擎代码..."
cat << 'EOF_PYTHON' > app.py
import threading, json, os, time, requests
from flask import Flask, jsonify, request, send_from_directory

# 建立两个独立的 Flask 实例
public_app = Flask("public_app")
admin_app = Flask("admin_app")

DB_FILE = "db.json"
ADMIN_PASSWORD = "admin123" # ⚠️ 生产环境建议修改此密码

# 初始化数据库
if not os.path.exists(DB_FILE):
    with open(DB_FILE, 'w', encoding='utf-8') as f: json.dump({}, f)

vehicle_configs = {}
vehicle_cache = {}
sync_event = threading.Event()
update_queue = set()

def load_db():
    global vehicle_configs
    with open(DB_FILE, 'r', encoding='utf-8') as f: 
        vehicle_configs = json.load(f)

def save_db():
    with open(DB_FILE, 'w', encoding='utf-8') as f: 
        json.dump(vehicle_configs, f, ensure_ascii=False, indent=4)

load_db()

# 后台数据抓取守护线程
def fetch_worker():
    while True:
        has_active_tasks = False
        for vid, cfg in list(vehicle_configs.items()):
            token, carId = cfg.get('token'), cfg.get('carId')
            if not token or not carId: continue
            has_active_tasks = True
            
            # 轮询逻辑: 强制更新队列中 or 距离上次超过 15分钟 (900秒)
            if vid not in update_queue and vid in vehicle_cache and (time.time() - vehicle_cache[vid].get('ts', 0) < 900):
                continue

            try:
                headers = {
                    "Host": "m.iov.changan.com.cn",
                    "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_7_15 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
                    "vcs-app-id": "inCall",
                    "X-VCS-User-Token": token
                }
                
                cached_data = {
                    "status": {}, "location": {}, "traffic": {"left": "--", "unit": "", "expireDate": "--"}, 
                    "report": {}, "report_yesterday": {}, "messages": []
                }
                
                # 1. 基础车况
                payload = f"carId={carId}&keys=%2A&token={token}"
                res_status = requests.post("https://m.iov.changan.com.cn/app2/api/car/data", headers={**headers, "Content-Type": "application/x-www-form-urlencoded; charset=utf-8"}, data=payload, timeout=10).json()
                if res_status.get("success"): cached_data["status"] = res_status.get("data", {})

                # 2. 定位
                res_loc = requests.get(f"https://m.iov.changan.com.cn/app2/api/car/location?carId={carId}&mapType=GCJ02&token={token}", headers=headers, timeout=10).json()
                if res_loc.get("success"): cached_data["location"] = res_loc.get("data", {})

                # 3. 流量
                res_tra = requests.get(f"https://m.iov.changan.com.cn/app2/api/mall/digital/balance/app?carId={carId}&token={token}", headers=headers, timeout=10).json()
                if res_tra.get("success") and res_tra.get("data"): 
                    traffic_info = res_tra["data"][0]["balances"][0]
                    cached_data["traffic"] = {"left": traffic_info.get("left", "0"), "unit": traffic_info.get("unit", "MB"), "expireDate": traffic_info.get("expirationTime", "").split(" ")[0]}

                # 4. 行程
                today = time.strftime('%Y%m%d')
                yesterday = time.strftime('%Y%m%d', time.localtime(time.time() - 86400))
                for q_day, key in [(today, "report"), (yesterday, "report_yesterday")]:
                    res_rep = requests.get(f"https://m.iov.changan.com.cn/app2/api/car-report/car-report-day?carId={carId}&queryDay={q_day}&token={token}", headers=headers, timeout=10).json()
                    if res_rep.get("success"): cached_data[key] = res_rep.get("data", {})

                # 5. 消息
                start_time = time.strftime('%Y-%m-%d', time.localtime(time.time() - 2592000)) + "+00:00:00"
                end_time = time.strftime('%Y-%m-%d') + "+23:59:59"
                res_msg = requests.get(f"https://m.iov.changan.com.cn/appserver/api/information/getAllLatestInfo?actionType=1&startTime={start_time}&endTime={end_time}&token={token}", headers=headers, timeout=10).json()
                if res_msg.get("success"): cached_data["messages"] = res_msg.get("data", [])[:5]

                cached_data["last_update"] = time.strftime("%H:%M:%S")
                vehicle_cache[vid] = {"data": cached_data, "ts": time.time()}
                print(f"[+] 车辆 {vid} 更新成功")
            except Exception as e: 
                print(f"[-] 车辆 {vid} 更新异常: {e}")
            
            if vid in update_queue: update_queue.remove(vid)
        
        # 线程休眠，等待唤醒或自然超时
        sync_event.wait(timeout=10 if has_active_tasks else 30)
        sync_event.clear()

threading.Thread(target=fetch_worker, daemon=True).start()

# ==========================================
# 端口 5000: 公开访问层 (仅只读和下发同步指令)
# ==========================================
@public_app.route('/')
def index(): 
    return send_from_directory('templates', 'index.html')

@public_app.route('/api/status/<vid>')
def get_status(vid):
    if vid not in vehicle_configs:
        return jsonify({"code": 404, "msg": "无效的车辆标识"})
    cache = vehicle_cache.get(vid)
    if not cache:
        return jsonify({"code": 202, "msg": "初始化抓取中，请等待..."})
    return jsonify({"code": 200, "data": cache["data"]})

@public_app.route('/api/force-sync', methods=['POST'])
def force_sync():
    vid = request.json.get('vid')
    if vid in vehicle_configs:
        update_queue.add(vid)
        sync_event.set() # 唤醒线程立刻执行
        return jsonify({"code": 200, "msg": "正在同步..."})
    return jsonify({"code": 400})

# ==========================================
# 端口 5001: 管理后台层 (独立隔离)
# ==========================================
@admin_app.route('/')
def admin_index():
    return send_from_directory('templates', 'admin.html')

@admin_app.route('/api/vehicles', methods=['GET', 'POST', 'DELETE'])
def manage_vehicles():
    if request.headers.get('X-Admin-Pass') != ADMIN_PASSWORD:
        return jsonify({"code": 403}), 403
        
    if request.method == 'GET':
        return jsonify(vehicle_configs)
        
    if request.method == 'POST':
        data = request.json
        vid = data.get('vid')
        if not vid: vid = f"car-{int(time.time())}"
        vehicle_configs[vid] = {
            "name": data.get("name", "未命名"),
            "carId": data.get("carId"),
            "token": data.get("token")
        }
        save_db()
        return jsonify({"code": 200, "vid": vid})
        
    if request.method == 'DELETE':
        vid = request.args.get('vid')
        if vid in vehicle_configs:
            del vehicle_configs[vid]
            if vid in vehicle_cache: del vehicle_cache[vid]
        save_db()
        return jsonify({"code": 200})

# 启动双服务进程
def run_public(): public_app.run(host='0.0.0.0', port=5000, use_reloader=False)
def run_admin(): admin_app.run(host='0.0.0.0', port=5001, use_reloader=False)

if __name__ == '__main__':
    threading.Thread(target=run_public, daemon=True).start()
    threading.Thread(target=run_admin, daemon=True).start()
    while True: time.sleep(1) # 保持主进程存活
EOF_PYTHON

# ==========================================
# 写入前端 HTML 代码 - 主页 (保留原汁原味 UI)
# ==========================================
echo "▶ 4/5 写入前端看版 (Port 5000) 与管理面板 (Port 5001)..."
cat << 'EOF_HTML' > templates/index.html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>UNI-V 全景监控舱</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://unpkg.com/vue@3/dist/vue.global.js"></script>
    <style>
        ::-webkit-scrollbar { width: 6px; }
        ::-webkit-scrollbar-track { background: rgba(15, 23, 42, 0.5); }
        ::-webkit-scrollbar-thumb { background: #334155; border-radius: 4px; }
        ::-webkit-scrollbar-thumb:hover { background: #10b981; }
        .diagnostic-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: 1rem; }
    </style>
</head>
<body class="bg-slate-900 text-slate-200 min-h-screen p-4 md:p-6 font-sans">
    <div id="app" class="max-w-7xl mx-auto relative">
        
        <header class="flex flex-col md:flex-row justify-between md:items-end border-b border-slate-700/80 pb-5 mb-6 gap-4">
            <div>
                <h1 class="text-3xl font-bold text-emerald-400 tracking-wide">UNI-V <span class="text-slate-500 text-xl font-normal">| 终极监控舱</span></h1>
            </div>
            <div class="flex items-center gap-4">
                <div v-if="isValidVehicle" class="text-right mr-2">
                    <p class="text-[11px] text-slate-500 tracking-widest">最后同步</p>
                    <p class="text-base font-mono text-emerald-300">{{ lastUpdate }}</p>
                </div>
                
                <button v-if="isValidVehicle" @click="showDiagnostics = true" class="p-2.5 bg-slate-800 rounded-lg border border-slate-600 hover:bg-slate-700 hover:border-blue-500 transition-all text-slate-300 hover:text-blue-400 shadow-lg group relative" title="全部原始数据流">
                    <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 7v10c0 2.21 3.582 4 8 4s8-1.79 8-4V7M4 7c0 2.21 3.582 4 8 4s8-1.79 8-4M4 7c0-2.21 3.582-4 8-4s8 1.79 8 4m0 5c0 2.21-3.582 4-8 4s-8-1.79-8-4"></path></svg>
                </button>

                <button v-if="isValidVehicle" @click="forceSync" class="px-4 py-2 bg-emerald-600/20 rounded-lg border border-emerald-500/50 hover:bg-emerald-600 hover:text-white transition-all text-emerald-400 shadow-lg flex items-center gap-2">
                    <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"></path></svg>
                    <span class="text-sm font-bold tracking-wider">立即同步</span>
                </button>
            </div>
        </header>

        <div v-if="!currentVid" class="text-center py-20 bg-slate-800/30 border border-slate-700 border-dashed rounded-xl">
            <p class="text-slate-300">请使用管理员分配的专属 URL 链接访问监控舱。</p>
        </div>
        <div v-else-if="!isValidVehicle" class="text-center py-20 bg-slate-800/30 border border-slate-700 border-dashed rounded-xl">
            <p class="text-amber-400">{{ fetchMsg }}</p>
        </div>

        <div v-else>
            <div class="grid grid-cols-2 lg:grid-cols-4 gap-4 mb-6">
                <div class="bg-slate-800 p-4 rounded-xl border border-slate-700 flex items-center gap-4 shadow-lg">
                    <div class="bg-blue-500/10 p-3 rounded-xl text-blue-400"><svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 20l-5.447-2.724A1 1 0 013 16.382V5.618a1 1 0 011.447-.894L9 7m0 13l6-3m-6 3V7m6 10l4.553 2.276A1 1 0 0021 18.382V7.618a1 1 0 00-.553-.894L15 4m0 13V4m0 0L9 7"></path></svg></div>
                    <div><p class="text-xs text-slate-400 mb-0.5">总里程</p><p class="font-bold text-xl">{{ status.totalOdometer || 0 }} <span class="text-xs font-normal text-slate-500">km</span></p></div>
                </div>
                <div class="bg-slate-800 p-4 rounded-xl border border-slate-700 flex items-center gap-4 shadow-lg">
                    <div class="bg-rose-500/10 p-3 rounded-xl text-rose-400"><svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17.657 16.657L13.414 20.9a1.998 1.998 0 01-2.827 0l-4.244-4.243a8 8 0 1111.314 0z"></path></svg></div>
                    <div><p class="text-xs text-slate-400 mb-0.5">{{ status.igniteCumulativeMileage > 0 ? '本次里程' : '昨日里程' }}</p><p class="font-bold text-xl">{{ status.igniteCumulativeMileage > 0 ? status.igniteCumulativeMileage : (report_yesterday.todayMileage || 0) }} <span class="text-xs font-normal text-slate-500">km</span></p></div>
                </div>
                <div class="bg-slate-800 p-4 rounded-xl border border-slate-700 flex items-center gap-4 shadow-lg">
                    <div class="bg-amber-500/10 p-3 rounded-xl text-amber-400"><svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z"></path></svg></div>
                    <div><p class="text-xs text-slate-400 mb-0.5">平均油耗</p><p class="font-bold text-xl">{{ status.fuelConsumption100km || 0 }} <span class="text-xs font-normal text-slate-500">L/100km</span></p></div>
                </div>
                <div class="bg-slate-800 p-4 rounded-xl border border-slate-700 flex items-center gap-4 shadow-lg">
                    <div class="p-3 rounded-xl" :class="status.engineStatus === 2 ? 'bg-slate-700 text-slate-400' : 'bg-emerald-500/10 text-emerald-400'"><svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"></path></svg></div>
                    <div><p class="text-xs text-slate-400 mb-0.5">引擎状态</p><p class="font-bold text-lg" :class="status.engineStatus === 2 ? 'text-slate-400' : 'text-emerald-400'">{{ status.engineStatus === 2 ? '已熄火' : '运行中' }}</p></div>
                </div>
            </div>

            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
                <div class="space-y-6">
                    <div class="bg-slate-800 p-6 rounded-xl border border-slate-700 shadow-lg space-y-3.5 relative overflow-hidden">
                        <div class="absolute -right-4 -top-4 w-24 h-24 bg-blue-500/10 rounded-full blur-xl"></div>
                        <h2 class="text-sm font-bold text-blue-400 border-l-2 border-blue-500 pl-2 mb-4 uppercase">动力与行程系统</h2>
                        <div class="flex justify-between items-center"><span class="text-slate-400 text-sm">剩余油量</span><span class="font-mono text-slate-200">{{ status.fuelLeftover || 0 }} L</span></div>
                        <div class="flex justify-between items-center"><span class="text-slate-400 text-sm">油量百分比</span><span class="font-mono text-slate-200">{{ status.remainingFuel || 0 }} %</span></div>
                        <div class="flex justify-between items-center"><span class="text-slate-400 text-sm">预计续航</span><span class="font-mono text-slate-200">{{ status.remainedOilMile || 0 }} km</span></div>
                        <div class="flex justify-between items-center"><span class="text-slate-400 text-sm">电瓶电压</span><span class="font-mono text-slate-200">{{ status.batteryVoltage || '--' }} V</span></div>
                        <div class="my-3 border-t border-slate-700/50"></div>
                        <div class="flex justify-between items-center"><span class="text-slate-400 text-sm">当前车速 (表显)</span><span class="font-mono text-slate-200">{{ status.vehicleSpeed || 0 }} km/h</span></div>
                        <div class="flex justify-between items-center"><span class="text-slate-400 text-sm">发动机转速</span><span class="font-mono text-slate-200">{{ status.engineSpeed || '--' }} rpm</span></div>
                        <div class="flex justify-between items-center"><span class="text-slate-400 text-sm">发动机水温</span><span class="font-mono text-slate-200">{{ status.engineWaterTemp || '--' }} °C</span></div>
                        <div class="flex justify-between items-center"><span class="text-slate-400 text-sm">机油压力</span><span :class="status.lowOilPressureFlag === 0 ? 'text-emerald-400' : 'text-red-400'">{{ status.lowOilPressureFlag === 0 ? '正常' : '异常' }}</span></div>
                        <div class="my-3 border-t border-slate-700/50 pt-2 border-dashed"></div>
                        <div class="flex justify-between items-center"><span class="text-slate-400 text-sm">本次点火时间</span><span class="font-mono text-slate-300 text-xs mt-0.5">{{ (status.ignitionTime || '').split(' ')[1] || '--:--:--' }}</span></div>
                        <div class="flex justify-between items-center"><span class="text-slate-400 text-sm">本次耗油量</span><span class="font-mono text-amber-400">{{ status.igniteCumulativeOil || 0 }} L</span></div>
                        <div class="flex justify-between items-center"><span class="text-slate-400 text-sm">GPS真实车速</span><span class="font-mono text-emerald-400">{{ status.speed || 0 }} km/h</span></div>
                    </div>
                    
                    <div class="bg-slate-800 p-6 rounded-xl border border-slate-700 shadow-lg space-y-3.5">
                        <h2 class="text-sm font-bold text-emerald-400 border-l-2 border-emerald-500 pl-2 mb-4 uppercase">车辆健康与底盘自检</h2>
                        <div class="flex justify-between items-center"><span class="text-slate-400 text-sm">距离保养剩余</span><span class="font-mono text-emerald-400">{{ status.maintainMileageRemaind || '--' }} km</span></div>
                        <div class="flex justify-between items-center"><span class="text-slate-400 text-sm">ABS 防抱死</span><span :class="status.absStatus === 0 ? 'text-emerald-400' : 'text-red-400'">{{ status.absStatus === 0 ? '正常' : '报警' }}</span></div>
                        <div class="flex justify-between items-center"><span class="text-slate-400 text-sm">ESP 稳定系统</span><span :class="status.vehicleStabilityControlSystemStatus === 0 ? 'text-emerald-400' : 'text-red-400'">{{ status.vehicleStabilityControlSystemStatus === 0 ? '正常' : '异常' }}</span></div>
                        <div class="flex justify-between items-center"><span class="text-slate-400 text-sm">EPS 助力转向</span><span :class="status.assistantSteeringStatus === 0 ? 'text-emerald-400' : 'text-red-400'">{{ status.assistantSteeringStatus === 0 ? '正常' : '异常' }}</span></div>
                        <div class="flex justify-between items-center"><span class="text-slate-400 text-sm">变速箱状态</span><span :class="status.transmissionSystemStatus === 0 ? 'text-emerald-400' : 'text-red-400'">{{ status.transmissionSystemStatus === 0 ? '正常' : '异常' }}</span></div>
                        <div class="flex justify-between items-center"><span class="text-slate-400 text-sm">安全气囊</span><span :class="status.airbagSystemStatus === 0 ? 'text-emerald-400' : 'text-red-400'">{{ status.airbagSystemStatus === 0 ? '正常' : '异常' }}</span></div>
                        <div class="flex justify-between items-center"><span class="text-slate-400 text-sm">冷却液温度</span><span :class="status.engineCoolantStatus === 0 ? 'text-emerald-400' : 'text-red-400'">{{ status.engineCoolantStatus === 0 ? '正常' : '高温报警' }}</span></div>
                        <div class="flex justify-between items-center"><span class="text-slate-400 text-sm">钥匙电量</span><span :class="status.keyLowPower === 0 ? 'text-emerald-400' : 'text-amber-400'">{{ status.keyLowPower === 0 ? '正常' : '电量低' }}</span></div>
                    </div>
                </div>

                <div class="space-y-6">
                    <div class="bg-slate-800 p-6 rounded-xl border border-slate-700 shadow-lg">
                        <h2 class="text-sm font-bold text-purple-400 border-l-2 border-purple-500 pl-2 mb-4 uppercase">全车门窗监控</h2>
                        <div class="grid grid-cols-2 gap-x-4 gap-y-3 text-sm">
                            <div class="col-span-2 flex justify-between border-b border-slate-700/50 pb-2 mb-1"><span class="text-slate-400">全车车门落锁</span><span :class="status.leftFrontDoorLock === 0 ? 'text-emerald-400' : 'text-amber-400'">{{ status.leftFrontDoorLock === 0 ? '已落锁' : '存在未锁' }}</span></div>
                            <div class="flex justify-between pr-2"><span class="text-slate-400">主驾车窗</span><span :class="status.diverWindow === 0 ? 'text-emerald-400' : 'text-amber-400'">{{ status.diverWindow === 0 ? '已关' : '开启' }}</span></div>
                            <div class="flex justify-between pl-2"><span class="text-slate-400">副驾车窗</span><span :class="status.passengerWindow === 0 ? 'text-emerald-400' : 'text-amber-400'">{{ status.passengerWindow === 0 ? '已关' : '开启' }}</span></div>
                            <div class="flex justify-between pr-2 border-t border-slate-700/50 pt-2"><span class="text-slate-400">左后车窗</span><span :class="status.leftRearWindow === 0 ? 'text-emerald-400' : 'text-amber-400'">{{ status.leftRearWindow === 0 ? '已关' : '开启' }}</span></div>
                            <div class="flex justify-between pl-2 border-t border-slate-700/50 pt-2"><span class="text-slate-400">右后车窗</span><span :class="status.rightRearWindow === 0 ? 'text-emerald-400' : 'text-amber-400'">{{ status.rightRearWindow === 0 ? '已关' : '开启' }}</span></div>
                            <div class="flex justify-between pr-2 border-t border-slate-700/50 pt-2"><span class="text-slate-400">天窗</span><span :class="status.sunroof === 0 ? 'text-emerald-400' : 'text-amber-400'">{{ status.sunroof === 0 ? '已关' : '开启' }}</span></div>
                            <div class="flex justify-between pl-2 border-t border-slate-700/50 pt-2"><span class="text-slate-400">引擎盖</span><span :class="status.hood === 0 ? 'text-emerald-400' : 'text-red-400'">{{ status.hood === 0 ? '已关' : '开启' }}</span></div>
                            <div class="col-span-2 flex justify-between border-t border-slate-700/50 pt-2"><span class="text-slate-400">后备箱</span><span :class="status.trunk === 0 ? 'text-emerald-400' : 'text-amber-400'">{{ status.trunk === 0 ? '已关' : '开启' }}</span></div>
                        </div>
                    </div>

                    <div class="bg-slate-800 p-6 rounded-xl border border-slate-700 shadow-lg space-y-3.5">
                        <h2 class="text-sm font-bold text-sky-400 border-l-2 border-sky-500 pl-2 mb-4 uppercase">座舱微气候与舒适</h2>
                        <div class="flex justify-between items-center"><span class="text-slate-400 text-sm">空调设定</span><span class="font-mono text-slate-200">{{ status.airConditioningSetTemperature || '--' }} °C</span></div>
                        <div class="flex justify-between items-center"><span class="text-slate-400 text-sm">车内/外实温</span><span class="font-mono text-slate-200">{{ status.air ? status.air.temperature : '--' }}°C / {{ status.environmentalTemp || '--' }}°C</span></div>
                        <div class="flex justify-between items-center"><span class="text-slate-400 text-sm">内外循环状态</span><span class="text-slate-200 text-sm">{{ status.airRecycleStatus === 2 ? '外循环' : (status.airRecycleStatus === 1 ? '内循环' : '关闭') }}</span></div>
                        <div class="flex justify-between items-center"><span class="text-slate-400 text-sm">车内 PM2.5</span><span class="font-mono text-emerald-400">{{ status.pm25 !== undefined ? status.pm25 : '--' }} <span class="text-xs text-slate-500 ml-1">(LV:{{ status.airQualityInCarLevel || 0 }})</span></span></div>
                        <div class="flex justify-between items-center"><span class="text-slate-400 text-sm">净化器状态</span><span :class="status.airPurifierStatus === 1 ? 'text-emerald-400' : 'text-slate-400'">{{ status.airPurifierStatus === 1 ? '运行中' : '关闭' }}</span></div>
                        
                        <div class="grid grid-cols-2 gap-2 mt-3 pt-3 border-t border-slate-700/50">
                            <div class="bg-slate-900/50 py-1.5 rounded flex flex-col items-center justify-center">
                                <span class="text-[10px] text-slate-500 mb-0.5">主驾 加热/通风</span>
                                <span class="text-xs text-slate-300"><span class="text-amber-400">{{ status.driverSeatHeatStatus === 6 ? '关' : status.driverSeatHeatStatus+'档' }}</span> <span class="mx-1 text-slate-600">|</span> <span class="text-sky-400">{{ status.driverSeatAirStatus === 6 ? '关' : status.driverSeatAirStatus+'档' }}</span></span>
                            </div>
                            <div class="bg-slate-900/50 py-1.5 rounded flex flex-col items-center justify-center">
                                <span class="text-[10px] text-slate-500 mb-0.5">副驾 加热/通风</span>
                                <span class="text-xs text-slate-300"><span class="text-amber-400">{{ status.passengerSeatHeatStatus === 6 ? '关' : status.passengerSeatHeatStatus+'档' }}</span> <span class="mx-1 text-slate-600">|</span> <span class="text-sky-400">{{ status.passengerSeatAirStatus === 6 ? '关' : status.passengerSeatAirStatus+'档' }}</span></span>
                            </div>
                        </div>
                    </div>

                    <div class="bg-slate-800 p-6 rounded-xl border border-slate-700 shadow-lg space-y-3.5">
                        <h2 class="text-sm font-bold text-indigo-400 border-l-2 border-indigo-500 pl-2 mb-4 uppercase">网络 & 流量</h2>
                        <div class="flex justify-between items-center"><span class="text-slate-400 text-sm">信号强度</span><span class="font-mono text-slate-200">{{ status.signaIntensity || '--' }} %</span></div>
                        <div class="flex justify-between items-center"><span class="text-slate-400 text-sm">剩余流量</span><span class="font-mono text-indigo-400 font-bold">{{ traffic.left || '--' }} {{ traffic.unit || '' }}</span></div>
                        <div class="flex justify-between items-center"><span class="text-slate-400 text-sm">流量到期日</span><span class="font-mono text-slate-500 text-xs mt-0.5">{{ traffic.expireDate || '--' }}</span></div>
                    </div>
                </div>

                <div class="space-y-6">
                    <div class="bg-slate-800 p-5 rounded-xl border border-slate-700 shadow-lg relative overflow-hidden">
                        <h2 class="text-sm font-bold text-rose-400 border-l-2 border-rose-500 pl-2 mb-3 uppercase">高精卫星定位</h2>
                        <p class="text-slate-200 font-medium mb-1">{{ location.city || '刷新中...' }}</p>
                        <p class="text-slate-500 text-xs mb-3 truncate">{{ location.address || '暂无详细道路数据' }}</p>
                        <div class="grid grid-cols-2 gap-y-3 pt-3 border-t border-slate-700/50 mt-4">
                            <div><p class="text-slate-500 text-[10px] mb-1">搜星数量</p><p class="font-mono text-sm text-slate-200">{{ status.satNum || 0 }} <span class="text-xs text-slate-500">颗</span></p></div>
                            <div><p class="text-slate-500 text-[10px] mb-1">当前海拔</p><p class="font-mono text-sm text-slate-200">{{ status.alti || '--' }} <span class="text-xs text-slate-500">m</span></p></div>
                            <div><p class="text-slate-500 text-[10px] mb-1">车头航向角</p><p class="font-mono text-sm text-slate-200">{{ status.heading || '--' }} <span class="text-xs text-slate-500">°</span></p></div>
                            <div><p class="text-slate-500 text-[10px] mb-1">定位时间</p><p class="font-mono text-sm text-slate-200">{{ (status.gpsTime || '').split(' ')[1] || '--' }}</p></div>
                        </div>
                    </div>
                    
                    <div class="bg-slate-800 p-5 rounded-xl border border-slate-700 shadow-lg">
                        <h2 class="text-sm font-bold text-amber-400 border-l-2 border-amber-500 pl-2 mb-4 uppercase">全车灯光系统</h2>
                        <div class="grid grid-cols-2 gap-y-3 text-sm">
                            <div class="flex justify-between pr-3"><span class="text-slate-400">近光灯</span><span :class="status.lowBeam === 1 ? 'text-amber-400' : 'text-slate-500'">{{ status.lowBeam === 1 ? '开启' : '关闭' }}</span></div>
                            <div class="flex justify-between pl-3 border-l border-slate-700"><span class="text-slate-400">远光灯</span><span :class="status.highBeam === 1 ? 'text-blue-400' : 'text-slate-500'">{{ status.highBeam === 1 ? '开启' : '关闭' }}</span></div>
                            <div class="flex justify-between pr-3"><span class="text-slate-400">前雾灯</span><span :class="status.frontFogLight === 1 ? 'text-amber-400' : 'text-slate-500'">{{ status.frontFogLight === 1 ? '开启' : '关闭' }}</span></div>
                            <div class="flex justify-between pl-3 border-l border-slate-700"><span class="text-slate-400">后雾灯</span><span :class="status.rearFogLight === 1 ? 'text-red-400' : 'text-slate-500'">{{ status.rearFogLight === 1 ? '开启' : '关闭' }}</span></div>
                            <div class="col-span-2 flex justify-between pt-2 border-t border-slate-700/50"><span class="text-slate-400">日行/示宽灯</span><span :class="status.positionLight === 1 ? 'text-emerald-400' : 'text-slate-500'">{{ status.positionLight === 1 ? '开启' : '关闭' }}</span></div>
                        </div>
                    </div>

                    <div class="bg-slate-800 p-5 rounded-xl border border-slate-700 shadow-lg">
                        <h2 class="text-sm font-bold text-slate-300 border-l-2 border-slate-400 pl-2 mb-3 uppercase">云端消息下发</h2>
                        <div class="space-y-2 h-24 overflow-y-auto pr-2">
                            <div v-for="msg in messages" class="border-b border-slate-700/50 pb-1.5">
                                <p class="text-slate-300 text-xs leading-relaxed">{{ msg.title }}</p>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
            
            <div class="mt-6 bg-slate-800 p-6 rounded-xl border border-slate-700 shadow-lg text-center relative overflow-hidden">
                <div class="flex justify-center items-center gap-2 mb-6">
                    <h2 class="text-sm font-bold text-slate-300">四轮动态胎压 (kPa)</h2>
                    <span class="text-xs px-2 py-0.5 rounded-full" :class="(status.lfPressureWarning||0)+(status.rfPressureWarning||0)+(status.lrPressureWarning||0)+(status.rrPressureWarning||0) === 0 ? 'bg-emerald-500/10 text-emerald-400' : 'bg-red-500/20 text-red-400 animate-pulse'">
                        {{ (status.lfPressureWarning||0)+(status.rfPressureWarning||0)+(status.lrPressureWarning||0)+(status.rrPressureWarning||0) === 0 ? '气压正常' : '气压异常报警！' }}
                    </span>
                </div>
                <div class="grid grid-cols-2 md:grid-cols-4 gap-6 relative z-10">
                    <div class="bg-slate-900/80 py-4 rounded-lg border border-slate-700/50 hover:border-emerald-500/50 transition"><p class="text-xs text-slate-400 mb-2">左前轮</p><p class="text-2xl font-bold font-mono" :class="(status.lfPressureWarning||0)>0?'text-red-500 animate-pulse':'text-emerald-400'">{{ status.lfTyrePressure || '--' }}</p></div>
                    <div class="bg-slate-900/80 py-4 rounded-lg border border-slate-700/50 hover:border-emerald-500/50 transition"><p class="text-xs text-slate-400 mb-2">右前轮</p><p class="text-2xl font-bold font-mono" :class="(status.rfPressureWarning||0)>0?'text-red-500 animate-pulse':'text-emerald-400'">{{ status.rfTyrePressure || '--' }}</p></div>
                    <div class="bg-slate-900/80 py-4 rounded-lg border border-slate-700/50 hover:border-emerald-500/50 transition"><p class="text-xs text-slate-400 mb-2">左后轮</p><p class="text-2xl font-bold font-mono" :class="(status.lrPressureWarning||0)>0?'text-red-500 animate-pulse':'text-emerald-400'">{{ status.lrTyrePressure || '--' }}</p></div>
                    <div class="bg-slate-900/80 py-4 rounded-lg border border-slate-700/50 hover:border-emerald-500/50 transition"><p class="text-xs text-slate-400 mb-2">右后轮</p><p class="text-2xl font-bold font-mono" :class="(status.rrPressureWarning||0)>0?'text-red-500 animate-pulse':'text-emerald-400'">{{ status.rrTyrePressure || '--' }}</p></div>
                </div>
            </div>
        </div>

        <div v-if="showDiagnostics" class="fixed inset-0 bg-slate-950/95 backdrop-blur-md z-[100] flex flex-col transition-all">
            <div class="p-5 md:p-6 border-b border-slate-800 flex justify-between items-center bg-slate-900 shadow-xl">
                <div>
                    <h2 class="text-xl md:text-2xl font-bold text-blue-400 font-mono tracking-widest flex items-center gap-3">
                        <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 20l4-16m4 4l4 4-4 4M6 16l-4-4 4-4"></path></svg>
                        CAN 总线原始数据流诊断
                    </h2>
                    <p class="text-slate-500 text-xs mt-1 uppercase tracking-widest">包含 120+ 传感器节点 (已中文映射)</p>
                </div>
                <button @click="showDiagnostics = false" class="text-slate-400 hover:text-white p-2 bg-slate-800 rounded border border-slate-700 hover:border-slate-500 transition">
                    <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"></path></svg>
                </button>
            </div>
            <div class="flex-1 overflow-y-auto p-4 md:p-6 bg-[radial-gradient(ellipse_at_top,_var(--tw-gradient-stops))] from-slate-900 via-slate-950 to-black">
                <div class="diagnostic-grid">
                    <div v-for="item in rawDiagnostics" :key="item.key" class="bg-slate-900/80 p-3.5 rounded-lg border border-slate-800 hover:border-blue-500/50 hover:bg-slate-800 transition-all group">
                        <div class="text-sm font-bold text-slate-300 mb-0.5 group-hover:text-blue-400 transition">{{ item.cnName }}</div>
                        <div class="text-[10px] text-slate-600 font-mono mb-2 break-all">{{ item.key }}</div>
                        <div class="font-mono text-base break-all" :class="item.value === 'null' ? 'text-slate-600' : 'text-emerald-400'">
                            {{ item.value }}
                        </div>
                    </div>
                </div>
            </div>
        </div>
    </div>

    <script>
        const { createApp, ref, onMounted, computed } = Vue

        const DICTIONARY = {
            'totalOdometer': '车辆总里程', 'fuelLeftover': '剩余油量(L)', 'remainedOilMile': '预估剩余续航(km)',
            'batteryVoltage': '蓄电池电压(V)', 'lfTyrePressure': '左前胎压(kPa)', 'rfTyrePressure': '右前胎压(kPa)',
            'lrTyrePressure': '左后胎压(kPa)', 'rrTyrePressure': '右后胎压(kPa)', 'engineStatus': '发动机状态',
            'leftFrontDoorLock': '左前门落锁', 'trunk': '后备箱状态', 'hood': '引擎盖状态',
            'airConditioningSetTemperature': '空调设定温度', 'environmentalTemp': '车外环境温度', 'vehicleSpeed': '仪表盘车速',
            'engineSpeed': '发动机转速(rpm)', 'engineWaterTemp': '发动机水温(°C)', 'remainingFuel': '油量百分比(%)',
            'lowOilPressureFlag': '机油压力告警', 'maintainMileageRemaind': '距离保养剩余', 'absStatus': 'ABS防抱死状态',
            'airbagSystemStatus': '安全气囊状态', 'transmissionSystemStatus': '变速箱状态', 'keyLowPower': '智能钥匙电量',
            'diverWindow': '主驾车窗状态', 'passengerWindow': '副驾车窗状态', 'leftRearWindow': '左后车窗状态',
            'rightRearWindow': '右后车窗状态', 'sunroof': '天窗状态', 'pm25': '车内PM2.5指数',
            'airPurifierStatus': '空气净化器状态', 'signaIntensity': '网络信号强度(%)', 'satNum': 'GPS搜星数量',
            'alti': '当前海拔高度(m)', 'heading': '车头偏航角(度)', 'gpsTime': '卫星定位时间',
            'lowBeam': '近光灯状态', 'highBeam': '远光灯状态', 'frontFogLight': '前雾灯状态',
            'rearFogLight': '后雾灯状态', 'positionLight': '示宽灯/日行灯', 'driverSeatHeatStatus': '主驾座椅加热档位',
            'passengerSeatHeatStatus': '副驾座椅加热档位', 'driverSeatAirStatus': '主驾座椅通风档位', 'passengerSeatAirStatus': '副驾座椅通风档位',
            'airQualityInCarLevel': '车内空气质量等级', 'airRecycleStatus': '空调内外循环', 'lfPressureWarning': '左前胎压报警器',
            'rfPressureWarning': '右前胎压报警器', 'lrPressureWarning': '左后胎压报警器', 'rrPressureWarning': '右后胎压报警器',
            'vehicleStabilityControlSystemStatus': 'ESP车身稳定系统', 'assistantSteeringStatus': 'EPS电子助力转向', 'engineCoolantStatus': '冷却液高温报警',
            'ignitionTime': '本次点火时间', 'igniteCumulativeOil': '本次行驶耗油量(L)', 'speed': 'GPS真实测绘车速',
            'vin': '车辆识别码(VIN)', 'carConfCode': '车型配置代码', 'igniteCumulativeMileage': '本次行驶里程',
            'fuelConsumption100km': '表显平均油耗', 'trackFuelConsumption100km': '长期平均油耗', 'networkType': '车机网络类型',
            'validGps': 'GPS定位是否有效', 'leftFrontDoor': '左前门开闭', 'rightFrontDoor': '右前门开闭',
            'leftRearDoor': '左后门开闭', 'rightRearDoor': '右后门开闭', 'driverDoorLock': '主驾落锁',
            'passengerDoorLock': '副驾落锁', 'leftRearDoorLock': '左后落锁', 'rightRearDoorLock': '右后落锁'
        };

        createApp({
            setup() {
                const currentVid = ref(new URLSearchParams(window.location.search).get('vid'));
                const isValidVehicle = ref(false);
                const fetchMsg = ref('加载中...');
                
                const status = ref({}); const location = ref({}); const traffic = ref({}); const report = ref({}); const report_yesterday = ref({}); const messages = ref([]);
                const lastUpdate = ref("--"); 
                const showDiagnostics = ref(false);

                const rawDiagnostics = computed(() => {
                    if(!status.value) return [];
                    return Object.keys(status.value).sort().map(k => ({
                        key: k, cnName: DICTIONARY[k] || '未定义扩展参数',
                        value: status.value[k] === null || status.value[k] === undefined ? 'null' : typeof status.value[k] === 'object' ? JSON.stringify(status.value[k]) : String(status.value[k])
                    }));
                });

                const fetchData = async () => {
                    if(!currentVid.value) return;
                    try {
                        const response = await fetch('/api/status/' + currentVid.value);
                        const res = await response.json();
                        if (res.code === 200) {
                            isValidVehicle.value = true;
                            if (res.data) {
                                status.value = res.data.status || {}; location.value = res.data.location || {};
                                traffic.value = res.data.traffic || {}; report.value = res.data.report || {};
                                report_yesterday.value = res.data.report_yesterday || {}; messages.value = res.data.messages || [];
                                lastUpdate.value = res.data.last_update || "未知";
                            }
                        } else {
                            isValidVehicle.value = false;
                            fetchMsg.value = res.msg;
                        }
                    } catch (e) {
                        isValidVehicle.value = false;
                        fetchMsg.value = "无法连接到服务器，请检查网络。";
                    }
                };

                const forceSync = async () => {
                    try {
                        const res = await (await fetch('/api/force-sync', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ vid: currentVid.value }) })).json();
                        alert(res.msg || "云端同步请求已发送，请等待数秒数据刷新。");
                        setTimeout(fetchData, 3000); // 3秒后尝试拉取
                    } catch(e) { alert("同步失败！"); }
                };

                onMounted(() => { 
                    fetchData(); 
                    if(currentVid.value) setInterval(fetchData, 10000); 
                });
                
                return { 
                    currentVid, isValidVehicle, fetchMsg,
                    status, location, traffic, report, report_yesterday, messages, lastUpdate, 
                    showDiagnostics, rawDiagnostics, forceSync
                }
            }
        }).mount('#app')
    </script>
</body>
</html>
EOF_HTML

# ==========================================
# 写入独立管理后台代码 (Port 5001)
# ==========================================
cat << 'EOF_ADMIN' > templates/admin.html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <title>系统管理后台 - UNI-V</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script src="https://unpkg.com/vue@3/dist/vue.global.js"></script>
</head>
<body class="bg-slate-900 text-slate-200 p-6 min-h-screen">
    <div id="admin" class="max-w-4xl mx-auto">
        <h1 class="text-2xl font-bold text-emerald-400 mb-6 flex items-center gap-2">
            <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"></path><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"></path></svg>
            车队安全管理中心
        </h1>
        
        <div v-if="!isAuth" class="bg-slate-800 p-8 rounded-xl max-w-sm border border-slate-700 shadow-2xl">
            <h2 class="mb-4 text-lg font-bold">验证管理员身份</h2>
            <input v-model="pass" type="password" placeholder="请输入超级密码" class="w-full p-3 rounded bg-slate-900 border border-slate-700 mb-4 focus:outline-none focus:border-emerald-500">
            <button @click="login" class="w-full bg-emerald-600 hover:bg-emerald-500 text-white font-bold py-3 rounded transition">安全登录</button>
        </div>

        <div v-else class="grid grid-cols-1 md:grid-cols-2 gap-6">
            <div class="bg-slate-800 p-6 rounded-xl border border-slate-700">
                <h2 class="text-lg font-bold mb-4 border-b border-slate-700 pb-2">已分配车辆 ({{ Object.keys(list).length }})</h2>
                <div class="space-y-3">
                    <div v-for="(car, vid) in list" :key="vid" class="p-3 bg-slate-900 rounded border border-slate-700">
                        <div class="flex justify-between items-start mb-2">
                            <div>
                                <p class="font-bold text-emerald-400">{{ car.name }}</p>
                                <p class="text-[10px] text-slate-500 font-mono mt-1">CarID: {{ car.carId }}</p>
                            </div>
                            <button @click="remove(vid)" class="text-red-400 hover:text-red-300 text-xs">删除</button>
                        </div>
                        <div class="mt-2 pt-2 border-t border-slate-800">
                            <p class="text-xs text-slate-400 mb-1">监控专属链接 (请复制发给车主):</p>
                            <div class="flex">
                                <input readonly :value="publicIP + '/?vid=' + vid" class="flex-1 bg-black/50 text-[11px] text-blue-400 p-1.5 rounded-l border border-slate-700 focus:outline-none">
                                <a :href="publicIP + '/?vid=' + vid" target="_blank" class="bg-blue-600 hover:bg-blue-500 text-white px-3 py-1.5 rounded-r text-xs flex items-center">访问</a>
                            </div>
                        </div>
                    </div>
                </div>
            </div>

            <div class="bg-slate-800 p-6 rounded-xl border border-slate-700 h-fit">
                <h2 class="text-lg font-bold mb-4 border-b border-slate-700 pb-2">接入新车辆</h2>
                <div class="space-y-3">
                    <input v-model="form.name" placeholder="车辆备注名称" class="w-full p-2.5 rounded bg-slate-900 border border-slate-700 text-sm focus:border-emerald-500">
                    <input v-model="form.carId" placeholder="车机 ID (carId)" class="w-full p-2.5 rounded bg-slate-900 border border-slate-700 text-sm font-mono focus:border-emerald-500">
                    <textarea v-model="form.token" placeholder="抓包 Token" class="w-full p-2.5 rounded bg-slate-900 border border-slate-700 text-sm font-mono h-24 focus:border-emerald-500"></textarea>
                    <button @click="add" class="w-full bg-indigo-600 hover:bg-indigo-500 text-white font-bold py-2.5 rounded transition">分配并生效</button>
                </div>
            </div>
        </div>
    </div>
    <script>
        const { createApp, ref, computed } = Vue;
        createApp({
            setup() {
                const isAuth = ref(false);
                const pass = ref('');
                const list = ref({});
                const form = ref({name:'', carId:'', token:''});
                
                // 动态获取当前访问的公网IP，将端口改为 5000 供拼接链接
                const publicIP = computed(() => {
                    const l = window.location;
                    return l.protocol + '//' + l.hostname + ':5000';
                });

                const req = async (method, body=null, query='') => {
                    return fetch('/api/vehicles' + query, { 
                        method, 
                        headers: {'X-Admin-Pass': pass.value, 'Content-Type': 'application/json'},
                        body: body ? JSON.stringify(body) : null
                    });
                };

                const login = async () => {
                    const r = await req('GET');
                    if(r.ok) { isAuth.value = true; list.value = await r.json(); }
                    else alert("管理密码错误");
                };

                const add = async () => {
                    if(!form.value.carId || !form.value.token) return alert("信息不全");
                    await req('POST', form.value);
                    form.value = {name:'', carId:'', token:''};
                    login();
                };

                const remove = async (vid) => {
                    if(confirm("确定要删除此车辆及监控页面吗？")) {
                        await req('DELETE', null, '?vid='+vid);
                        login();
                    }
                };

                return { isAuth, pass, list, form, login, add, remove, publicIP }
            }
        }).mount('#admin')
    </script>
</body>
</html>
EOF_ADMIN

# ==========================================
# 设置 Systemd 守护进程
# ==========================================
echo "▶ 5/5 部署 Systemd 服务常驻运行..."

python3 -m venv venv
./venv/bin/pip install flask requests werkzeug

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
