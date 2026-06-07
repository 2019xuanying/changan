#!/bin/bash

# ==========================================
# UNI-V 多车监控管理系统 - 一键部署脚本
# 架构: Flask(后端) + Vue3(前端) + JSON(数据引擎)
# 适用系统: Ubuntu / Debian
# ==========================================

set -e

# 1. 检查 root 权限
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
# 写入后端 Python 代码
# ==========================================
echo "▶ 3/5 写入后端核心引擎代码 (支持多租户并发)..."
cat << 'EOF_PYTHON' > app.py
import threading, json, os, time, requests
from flask import Flask, jsonify, request, send_from_directory

app = Flask(__name__)
DB_FILE = "db.json"

# ==========================================
# ⚠️ 安全警告：请务必在生产环境修改此管理密码
# ==========================================
ADMIN_PASSWORD = "admin123" 

# 初始化数据库
if not os.path.exists(DB_FILE):
    with open(DB_FILE, 'w', encoding='utf-8') as f: 
        json.dump({}, f)

vehicle_configs = {}
vehicle_cache = {} 
update_queue = set()

def load_db():
    global vehicle_configs
    with open(DB_FILE, 'r', encoding='utf-8') as f: 
        vehicle_configs = json.load(f)

def save_db():
    with open(DB_FILE, 'w', encoding='utf-8') as f: 
        json.dump(vehicle_configs, f, ensure_ascii=False, indent=4)

load_db()

# 后台异步抓取线程
def fetch_worker():
    while True:
        for vid, cfg in list(vehicle_configs.items()):
            token = cfg.get('token')
            carId = cfg.get('carId')
            if not token or not carId: continue
            
            # 调度逻辑：如果在强制更新队列中，立刻刷新；否则遵循 15 分钟 (900秒) 间隔
            if vid not in update_queue and vid in vehicle_cache and (time.time() - vehicle_cache[vid].get('ts', 0) < 900):
                continue

            try:
                headers = {
                    "Host": "m.iov.changan.com.cn",
                    "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_7_15 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
                    "vcs-app-id": "inCall",
                    "X-VCS-User-Token": token
                }
                
                # 初始化该车辆的缓存结构
                if vid not in vehicle_cache:
                    vehicle_cache[vid] = {"data": {"status": {}, "location": {}, "traffic": {"left": "--", "unit": "", "expireDate": "--"}, "report": {}, "report_yesterday": {}, "messages": []}}
                
                cached_data = vehicle_cache[vid]["data"]
                
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
                vehicle_cache[vid]["ts"] = time.time()
                print(f"[+] 车辆 {vid} 数据更新成功")

            except Exception as e: 
                print(f"[-] 车辆 {vid} 抓取失败: {e}")
            
            # 清除强制更新标记
            if vid in update_queue: update_queue.remove(vid)
            
        time.sleep(10) # 每次循环结束后稍微挂起，避免 CPU 占用过高

threading.Thread(target=fetch_worker, daemon=True).start()

# --- 管理面板 API ---
@app.route('/api/vehicles', methods=['GET', 'POST', 'DELETE'])
def manage_vehicles():
    if request.headers.get('X-Admin-Pass') != ADMIN_PASSWORD: 
        return jsonify({"code": 403, "msg": "密码错误或未授权"}), 403
        
    if request.method == 'GET': 
        # 返回时不暴露 token 给前端，只返回基本信息
        safe_configs = {k: {"name": v.get("name", "未命名车辆"), "carId": v.get("carId")} for k, v in vehicle_configs.items()}
        return jsonify(safe_configs)
        
    if request.method == 'POST':
        data = request.json
        # 如果前端没有传 vid，生成一个新的唯一 ID
        vid = data.get('vid')
        if not vid: vid = f"car-{int(time.time())}"
        
        vehicle_configs[vid] = {
            "name": data.get("name", "新车辆"),
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

# --- 看板数据 API ---
@app.route('/api/status/<vid>')
def get_status(vid):
    if vid not in vehicle_configs:
        return jsonify({"code": 404, "msg": "车辆未找到"})
        
    cache = vehicle_cache.get(vid)
    if not cache:
        return jsonify({"code": 202, "msg": "系统首次启动抓取中，请等待..."})
        
    return jsonify({"code": 200, "data": cache["data"]})

@app.route('/api/sync', methods=['POST'])
def force_sync():
    vid = request.json.get('vid')
    if vid in vehicle_configs:
        update_queue.add(vid)
    return jsonify({"code": 200, "msg": "同步指令已下发"})

@app.route('/')
def index(): 
    return send_from_directory('templates', 'index.html')

if __name__ == '__main__': 
    app.run(host='0.0.0.0', port=5000)
EOF_PYTHON

# ==========================================
# 写入前端 HTML 代码
# ==========================================
echo "▶ 4/5 写入前端看版与管理面板代码..."
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
                <div v-if="currentVid && systemStatus === 200" class="text-right mr-2">
                    <p class="text-[11px] text-slate-500 tracking-widest">最后同步</p>
                    <p class="text-base font-mono text-emerald-300">{{ lastUpdate }}</p>
                </div>
                
                <button v-if="currentVid" @click="doForceSync" class="px-4 py-2 bg-indigo-600/80 hover:bg-indigo-500 rounded-lg text-sm text-white font-medium transition-all border border-indigo-500/50 shadow-[0_0_15px_rgba(79,70,229,0.3)]">
                    立即同步
                </button>

                <button v-if="currentVid && systemStatus === 200" @click="showDiagnostics = true" class="p-2.5 bg-slate-800 rounded-lg border border-slate-600 hover:bg-slate-700 transition-all text-slate-300 shadow-lg">
                    <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 7v10c0 2.21 3.582 4 8 4s8-1.79 8-4V7M4 7c0 2.21 3.582 4 8 4s8-1.79 8-4M4 7c0-2.21 3.582-4 8-4s8 1.79 8 4m0 5c0 2.21-3.582 4-8 4s-8-1.79-8-4"></path></svg>
                </button>

                <button @click="showAdmin = true" class="p-2.5 bg-slate-800 rounded-lg border border-slate-600 hover:bg-slate-700 transition-all text-slate-300">
                    <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"></path><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"></path></svg>
                </button>
            </div>
        </header>

        <div v-if="!currentVid" class="text-center py-20 bg-slate-800/30 border border-slate-700 border-dashed rounded-xl">
            <p class="text-slate-300 text-lg">请通过指定的车辆链接访问</p>
            <p class="text-slate-500 text-sm mt-2">或点击右上角齿轮进入管理员后台创建车辆分配链接</p>
        </div>

        <div v-else-if="systemStatus !== 200" class="text-center py-20">
            <div class="inline-block animate-spin rounded-full h-8 w-8 border-t-2 border-b-2 border-emerald-500 mb-4"></div>
            <p class="text-slate-400">{{ systemMsg }}</p>
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
                        <div class="flex justify-between items-center"><span class="text-slate-400 text-sm">本次耗油量</span><span class="font-mono text-amber-400">{{ status.igniteCumulativeOil || 0 }} L</span></div>
                        <div class="flex justify-between items-center"><span class="text-slate-400 text-sm">距离保养剩余</span><span class="font-mono text-emerald-400">{{ status.maintainMileageRemaind || '--' }} km</span></div>
                    </div>
                </div>

                <div class="space-y-6">
                    <div class="bg-slate-800 p-6 rounded-xl border border-slate-700 shadow-lg">
                        <h2 class="text-sm font-bold text-purple-400 border-l-2 border-purple-500 pl-2 mb-4 uppercase">全车门窗与气候</h2>
                        <div class="grid grid-cols-2 gap-x-4 gap-y-3 text-sm">
                            <div class="col-span-2 flex justify-between border-b border-slate-700/50 pb-2 mb-1"><span class="text-slate-400">全车落锁</span><span :class="status.leftFrontDoorLock === 0 ? 'text-emerald-400' : 'text-amber-400'">{{ status.leftFrontDoorLock === 0 ? '已落锁' : '存在未锁' }}</span></div>
                            <div class="flex justify-between pr-2"><span class="text-slate-400">主驾车窗</span><span :class="status.diverWindow === 0 ? 'text-emerald-400' : 'text-amber-400'">{{ status.diverWindow === 0 ? '已关' : '开启' }}</span></div>
                            <div class="flex justify-between pl-2"><span class="text-slate-400">副驾车窗</span><span :class="status.passengerWindow === 0 ? 'text-emerald-400' : 'text-amber-400'">{{ status.passengerWindow === 0 ? '已关' : '开启' }}</span></div>
                            <div class="col-span-2 flex justify-between border-t border-slate-700/50 pt-2"><span class="text-slate-400">车内外实温</span><span class="font-mono text-slate-200">{{ status.air ? status.air.temperature : '--' }}°C / {{ status.environmentalTemp || '--' }}°C</span></div>
                            <div class="col-span-2 flex justify-between"><span class="text-slate-400">剩余流量</span><span class="font-mono text-indigo-400 font-bold">{{ traffic.left || '--' }} {{ traffic.unit || '' }} <span class="text-xs text-slate-500 font-normal">({{ traffic.expireDate }})</span></span></div>
                        </div>
                    </div>
                </div>

                <div class="space-y-6">
                    <div class="bg-slate-800 p-5 rounded-xl border border-slate-700 shadow-lg">
                        <h2 class="text-sm font-bold text-rose-400 border-l-2 border-rose-500 pl-2 mb-3 uppercase">高精卫星定位</h2>
                        <p class="text-slate-200 font-medium mb-1">{{ location.city || '刷新中...' }}</p>
                        <p class="text-slate-500 text-xs mb-3 truncate">{{ location.address || '暂无详细道路数据' }}</p>
                        <div class="grid grid-cols-2 gap-y-3 pt-3 border-t border-slate-700/50">
                            <div><p class="text-slate-500 text-[10px] mb-1">搜星数量</p><p class="font-mono text-sm text-slate-200">{{ status.satNum || 0 }} <span class="text-xs text-slate-500">颗</span></p></div>
                            <div><p class="text-slate-500 text-[10px] mb-1">定位时间</p><p class="font-mono text-sm text-slate-200">{{ (status.gpsTime || '').split(' ')[1] || '--' }}</p></div>
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
                    <div class="bg-slate-900/80 py-4 rounded-lg border border-slate-700/50"><p class="text-xs text-slate-400 mb-2">左前轮</p><p class="text-2xl font-bold font-mono" :class="(status.lfPressureWarning||0)>0?'text-red-500':'text-emerald-400'">{{ status.lfTyrePressure || '--' }}</p></div>
                    <div class="bg-slate-900/80 py-4 rounded-lg border border-slate-700/50"><p class="text-xs text-slate-400 mb-2">右前轮</p><p class="text-2xl font-bold font-mono" :class="(status.rfPressureWarning||0)>0?'text-red-500':'text-emerald-400'">{{ status.rfTyrePressure || '--' }}</p></div>
                    <div class="bg-slate-900/80 py-4 rounded-lg border border-slate-700/50"><p class="text-xs text-slate-400 mb-2">左后轮</p><p class="text-2xl font-bold font-mono" :class="(status.lrPressureWarning||0)>0?'text-red-500':'text-emerald-400'">{{ status.lrTyrePressure || '--' }}</p></div>
                    <div class="bg-slate-900/80 py-4 rounded-lg border border-slate-700/50"><p class="text-xs text-slate-400 mb-2">右后轮</p><p class="text-2xl font-bold font-mono" :class="(status.rrPressureWarning||0)>0?'text-red-500':'text-emerald-400'">{{ status.rrTyrePressure || '--' }}</p></div>
                </div>
            </div>
        </div>

        <div v-if="showDiagnostics" class="fixed inset-0 bg-slate-950/95 backdrop-blur-md z-[100] flex flex-col transition-all">
            <div class="p-5 md:p-6 border-b border-slate-800 flex justify-between items-center bg-slate-900">
                <h2 class="text-xl font-bold text-blue-400 font-mono flex items-center gap-3">CAN 总线原始数据流诊断</h2>
                <button @click="showDiagnostics = false" class="text-slate-400 hover:text-white p-2 bg-slate-800 rounded border border-slate-700"><svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"></path></svg></button>
            </div>
            <div class="flex-1 overflow-y-auto p-4 md:p-6">
                <div class="diagnostic-grid">
                    <div v-for="item in rawDiagnostics" :key="item.key" class="bg-slate-900/80 p-3.5 rounded-lg border border-slate-800">
                        <div class="text-[10px] text-slate-600 font-mono mb-1 break-all">{{ item.key }}</div>
                        <div class="font-mono text-sm break-all text-emerald-400">{{ item.value }}</div>
                    </div>
                </div>
            </div>
        </div>

        <div v-if="showAdmin" class="fixed inset-0 bg-black/80 z-[200] p-4 flex items-center justify-center">
            <div class="bg-slate-800 border border-slate-700 p-6 rounded-lg w-full max-w-2xl shadow-2xl">
                <div class="flex justify-between items-center mb-6">
                    <h2 class="text-lg font-bold text-white">多车租户管理后台</h2>
                    <button @click="showAdmin = false" class="text-slate-400 hover:text-white"><svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"></path></svg></button>
                </div>
                
                <div v-if="!isAdmin" class="space-y-4">
                    <input v-model="adminPass" type="password" placeholder="请输入管理员密码" class="w-full bg-slate-900 border border-slate-700 p-3 rounded text-white focus:outline-none focus:border-emerald-500">
                    <button @click="loginAdmin" class="w-full bg-emerald-600 hover:bg-emerald-500 transition-colors text-white font-bold p-3 rounded">验证身份</button>
                    <p v-if="adminError" class="text-red-400 text-sm text-center">{{ adminError }}</p>
                </div>
                
                <div v-else>
                    <div class="mb-6 max-h-60 overflow-y-auto pr-2 space-y-2">
                        <div v-for="(car, vid) in vehicleList" :key="vid" class="flex justify-between items-center p-3 bg-slate-900 border border-slate-700 rounded group">
                            <div>
                                <p class="text-sm font-bold text-slate-200">{{ car.name }}</p>
                                <p class="text-[10px] text-slate-500 font-mono">ID: {{ car.carId }} | VID: {{ vid }}</p>
                            </div>
                            <div class="flex gap-2">
                                <a :href="'/?vid='+vid" target="_blank" class="px-3 py-1 bg-blue-600/20 text-blue-400 rounded text-xs hover:bg-blue-600 hover:text-white transition">进入面板</a>
                                <button @click="deleteCar(vid)" class="px-3 py-1 bg-red-600/20 text-red-400 rounded text-xs hover:bg-red-600 hover:text-white transition">移除</button>
                            </div>
                        </div>
                        <div v-if="Object.keys(vehicleList).length === 0" class="text-center py-4 text-slate-500 text-sm">暂无绑定的车辆</div>
                    </div>
                    
                    <div class="border-t border-slate-700 pt-4 space-y-3">
                        <h3 class="text-sm font-bold text-slate-400">接入新车辆</h3>
                        <div class="grid grid-cols-2 gap-3">
                            <input v-model="newCar.name" placeholder="设置一个备注名 (如: 老婆的车)" class="col-span-2 bg-slate-900 border border-slate-700 p-2 rounded text-sm text-white">
                            <input v-model="newCar.carId" placeholder="车辆 ID (carId)" class="col-span-2 bg-slate-900 border border-slate-700 p-2 rounded text-sm text-white font-mono">
                            <textarea v-model="newCar.token" placeholder="授权 Token" class="col-span-2 bg-slate-900 border border-slate-700 p-2 rounded text-sm text-white font-mono h-20"></textarea>
                        </div>
                        <button @click="addCar" class="w-full bg-emerald-600 hover:bg-emerald-500 text-white font-bold py-2 rounded text-sm transition">分配独立监控空间</button>
                    </div>
                </div>
            </div>
        </div>

    </div>

    <script>
        const { createApp, ref, onMounted, computed } = Vue

        createApp({
            setup() {
                // Core States
                const currentVid = ref(new URLSearchParams(window.location.search).get('vid'));
                const systemStatus = ref(0);
                const systemMsg = ref('');
                
                // Data States
                const status = ref({}); const location = ref({}); const traffic = ref({}); const report = ref({}); const report_yesterday = ref({}); const messages = ref([]);
                const lastUpdate = ref("--");
                
                // UI States
                const showDiagnostics = ref(false);
                const showAdmin = ref(false);
                const isAdmin = ref(false);
                const adminPass = ref('');
                const adminError = ref('');
                
                // Admin States
                const vehicleList = ref({});
                const newCar = ref({ name: '', carId: '', token: '' });

                // Computed
                const rawDiagnostics = computed(() => {
                    if(!status.value) return [];
                    return Object.keys(status.value).sort().map(k => ({
                        key: k,
                        value: status.value[k] === null || status.value[k] === undefined ? 'null' : typeof status.value[k] === 'object' ? JSON.stringify(status.value[k]) : String(status.value[k])
                    }));
                });

                // Methods
                const fetchData = async () => {
                    if(!currentVid.value) return;
                    try {
                        const res = await (await fetch('/api/status/' + currentVid.value)).json();
                        systemStatus.value = res.code;
                        systemMsg.value = res.msg || '';
                        
                        if (res.code === 200 && res.data) {
                            status.value = res.data.status || {};
                            location.value = res.data.location || {};
                            traffic.value = res.data.traffic || {};
                            report.value = res.data.report || {};
                            report_yesterday.value = res.data.report_yesterday || {};
                            messages.value = res.data.messages || [];
                            lastUpdate.value = res.data.last_update || "未知";
                        }
                    } catch (e) {
                        systemStatus.value = 500;
                        systemMsg.value = "无法连接到服务器";
                    }
                };

                const doForceSync = async () => {
                    try {
                        await fetch('/api/sync', { 
                            method: 'POST', 
                            headers: {'Content-Type': 'application/json'},
                            body: JSON.stringify({ vid: currentVid.value }) 
                        });
                        // 强制拉取前短暂提示
                        systemStatus.value = 202;
                        systemMsg.value = "云端下发同步指令，拉取数据中...";
                        setTimeout(fetchData, 3000); // 3秒后尝试拉取最新数据
                    } catch(e) { alert("同步请求失败"); }
                };

                // Admin Methods
                const loginAdmin = async () => {
                    adminError.value = '';
                    const res = await fetch('/api/vehicles', { headers: { 'X-Admin-Pass': adminPass.value } });
                    if(res.status === 200) {
                        isAdmin.value = true;
                        vehicleList.value = await res.json();
                    } else {
                        adminError.value = '密码错误，请重试';
                    }
                };

                const addCar = async () => {
                    if(!newCar.value.carId || !newCar.value.token) return alert("请填写完整信息");
                    await fetch('/api/vehicles', { 
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json', 'X-Admin-Pass': adminPass.value },
                        body: JSON.stringify(newCar.value)
                    });
                    newCar.value = { name: '', carId: '', token: '' };
                    await loginAdmin(); // 刷新列表
                };

                const deleteCar = async (vid) => {
                    if(confirm("确定要移除该车辆的监控空间吗？")) {
                        await fetch('/api/vehicles?vid=' + vid, { method: 'DELETE', headers: { 'X-Admin-Pass': adminPass.value } });
                        await loginAdmin(); // 刷新列表
                    }
                };

                onMounted(() => { 
                    fetchData(); 
                    if(currentVid.value) setInterval(fetchData, 10000); 
                });
                
                return { 
                    currentVid, systemStatus, systemMsg,
                    status, location, traffic, report, report_yesterday, messages, lastUpdate, 
                    showDiagnostics, rawDiagnostics, doForceSync,
                    showAdmin, isAdmin, adminPass, adminError, vehicleList, newCar, loginAdmin, addCar, deleteCar
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
echo "▶ 5/5 配置虚拟环境与 systemd 守护进程..."

python3 -m venv venv
./venv/bin/pip install flask requests

cat << EOF_SYSTEMD > /etc/systemd/system/univ-monitor.service
[Unit]
Description=UNI-V Multi-Tenant Monitor Service
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
echo "✅ 多车租户监控系统部署完成！服务已在后台常驻运行。"
echo "🌐 访问地址: http://<你的服务器公网IP>:5000"
echo "⚙️  请点击页面右上角齿轮图标进入管理员后台。"
echo "🔑 默认管理员密码: admin123 (建议尽早在 /opt/univ-monitor/app.py 中修改)"
echo "=========================================================="
