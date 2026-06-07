import time
import threading
import sqlite3
import requests
import os
from flask import Flask, jsonify, request

app = Flask(__name__)

# 配置目录
BASE_DIR = "/opt/univ-monitor"
DB_NAME = os.path.join(BASE_DIR, "monitor.db")
TEMPLATE_PATH = os.path.join(BASE_DIR, "templates", "index.html")

# 全局同步信号与缓存
sync_event = threading.Event()
cached_data = {}  # 格式: { 'slug': { 'status': {}, 'location': {}, ... } }

def get_db():
    conn = sqlite3.connect(DB_NAME)
    conn.row_factory = sqlite3.Row
    return conn

def fetch_car_data(car):
    """单车数据抓取逻辑"""
    car_id = car['car_id']
    token = car['token']
    slug = car['unique_slug']
    
    headers = {
        "Host": "m.iov.changan.com.cn",
        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_7_15 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
        "vcs-app-id": "inCall",
        "X-VCS-User-Token": token
    }
    
    try:
        # 1. 基础车况
        payload = f"carId={car_id}&keys=%2A&token={token}"
        res = requests.post("https://m.iov.changan.com.cn/app2/api/car/data", 
                            headers={**headers, "Content-Type": "application/x-www-form-urlencoded; charset=utf-8"}, 
                            data=payload, timeout=10).json()
        
        # 2. 定位
        loc = requests.get(f"https://m.iov.changan.com.cn/app2/api/car/location?carId={car_id}&mapType=GCJ02&token={token}", headers=headers, timeout=10).json()
        
        # 3. 流量
        tra = requests.get(f"https://m.iov.changan.com.cn/app2/api/mall/digital/balance/app?carId={car_id}&token={token}", headers=headers, timeout=10).json()
        traffic_data = {"left": "--", "unit": "", "expireDate": "--"}
        if tra.get("success") and tra.get("data"):
            b = tra["data"][0]["balances"][0]
            traffic_data = {"left": b.get("left", "0"), "unit": b.get("unit", "MB"), "expireDate": b.get("expirationTime", "").split(" ")[0]}

        # 4. 简要行程 (今日/昨日)
        today = time.strftime('%Y%m%d')
        rep = requests.get(f"https://m.iov.changan.com.cn/app2/api/car-report/car-report-day?carId={car_id}&queryDay={today}&token={token}", headers=headers, timeout=10).json()
        
        # 5. 消息
        msg = requests.get(f"https://m.iov.changan.com.cn/appserver/api/information/getAllLatestInfo?actionType=1&token={token}", headers=headers, timeout=10).json()

        # 更新缓存
        cached_data[slug] = {
            "status": res.get("data", {}) if res.get("success") else {},
            "location": loc.get("data", {}) if loc.get("success") else {},
            "traffic": traffic_data,
            "report": rep.get("data", {}) if rep.get("success") else {},
            "messages": msg.get("data", [])[:5] if msg.get("success") else [],
            "last_update": time.strftime("%H:%M:%S")
        }
    except Exception as e:
        print(f"[{slug}] 同步失败: {e}")

def fetch_worker():
    """后台工作线程"""
    while True:
        try:
            conn = get_db()
            cars = conn.execute("SELECT * FROM cars").fetchall()
            conn.close()
            for car in cars:
                fetch_car_data(car)
        except Exception as e:
            print(f"后台线程错误: {e}")
        
        # 定时等待，或被手动触发唤醒
        sync_event.wait(timeout=900) 
        sync_event.clear()

threading.Thread(target=fetch_worker, daemon=True).start()

# --- 路由 ---

@app.route('/')
def index():
    # 默认重定向或直接加载某个默认页面，或者根据逻辑处理
    return "监控系统后台运行中，请访问 /view/<你的slug>"

@app.route('/view/<slug>')
def view(slug):
    if not os.path.exists(TEMPLATE_PATH): return "模板文件不存在", 404
    with open(TEMPLATE_PATH, 'r', encoding='utf-8') as f: return f.read()

@app.route('/api/status/<slug>')
def status(slug):
    return jsonify({"code": 200, "data": cached_data.get(slug, {})})

@app.route('/api/force-sync', methods=['POST'])
def force_sync():
    # 触发强制同步
    sync_event.set()
    return jsonify({"code": 200, "msg": "正在强制刷新数据..."})

if __name__ == '__main__':
    # 确保数据库存在
    if not os.path.exists(DB_NAME):
        from database import init_db
        init_db()
    app.run(host='0.0.0.0', port=5000)
