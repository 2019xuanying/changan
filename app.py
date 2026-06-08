import threading, json, os, time, requests
from flask import Flask, jsonify, request, send_from_directory

public_app = Flask("public_app")
admin_app = Flask("admin_app")

DB_FILE = "db.json"
ADMIN_PASSWORD = "admin123"

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

def safe_fetch(method, url, **kwargs):
    try:
        res = requests.request(method, url, **kwargs)
        if res.status_code == 200:
            return res.json()
    except Exception as e:
        print(f"    [警告] 接口请求异常: {url.split('?')[0]} -> {str(e)}")
    return {}

def fetch_worker():
    while True:
        has_active_tasks = False
        for vid, cfg in list(vehicle_configs.items()):
            token, carId = cfg.get('token'), cfg.get('carId')
            if not token or not carId: continue
            has_active_tasks = True
            
            if vid not in update_queue and vid in vehicle_cache and (time.time() - vehicle_cache[vid].get('ts', 0) < 900):
                continue

            print(f"[*] 正在获取车辆数据: {vid} (ID:{carId})")
            
            headers = {
                "Host": "m.iov.changan.com.cn",
                "User-Agent": "TestApp/2.2.3 (com.changan.uni; build:223036; iOS 16.7.15) Alamofire/5.11.0",
                "vcs-app-id": "inCall",
                "Accept-Language": "zh-Hans-MY;q=1.0, ms-MY;q=0.9, en-MY;q=0.8",
                "X-VCS-User-Token": token
            }
            
            cached_data = {
                "status": {}, "location": {}, "traffic": {"left": "--", "unit": "", "expireDate": "--"}, 
                "report": {}, "report_yesterday": {}, "messages": []
            }
            
            # 1. 基础车况
            post_headers = {**headers, "Content-Type": "application/x-www-form-urlencoded; charset=utf-8"}
            payload = {"carId": str(carId), "keys": "*", "token": token}
            res_status = safe_fetch("POST", "https://m.iov.changan.com.cn/app2/api/car/data", headers=post_headers, data=payload, timeout=10)
            if res_status.get("success"): cached_data["status"] = res_status.get("data", {})
            time.sleep(1) # 防风控延迟

            # 2. 定位
            res_loc = safe_fetch("GET", f"https://m.iov.changan.com.cn/app2/api/car/location?carId={carId}&mapType=GCJ02&token={token}", headers=headers, timeout=5)
            if res_loc.get("success"): cached_data["location"] = res_loc.get("data", {})
            time.sleep(1)

            # 3. 流量
            res_tra = safe_fetch("GET", f"https://m.iov.changan.com.cn/app2/api/mall/digital/balance/app?carId={carId}&token={token}", headers=headers, timeout=5)
            if res_tra.get("success") and res_tra.get("data"): 
                traffic_info = res_tra.get("data", [{}])[0].get("balances", [{}])[0]
                cached_data["traffic"] = {"left": traffic_info.get("left", "0"), "unit": traffic_info.get("unit", "MB"), "expireDate": traffic_info.get("expirationTime", "").split(" ")[0]}
            time.sleep(1)

            # 4. 行程
            today = time.strftime('%Y%m%d')
            yesterday = time.strftime('%Y%m%d', time.localtime(time.time() - 86400))
            for q_day, key in [(today, "report"), (yesterday, "report_yesterday")]:
                res_rep = safe_fetch("GET", f"https://m.iov.changan.com.cn/app2/api/car-report/car-report-day?carId={carId}&queryDay={q_day}&token={token}", headers=headers, timeout=5)
                if res_rep.get("success"): cached_data[key] = res_rep.get("data", {})
                time.sleep(1)

            # 5. 消息
            start_time = time.strftime('%Y-%m-%d', time.localtime(time.time() - 2592000)) + "+00:00:00"
            end_time = time.strftime('%Y-%m-%d') + "+23:59:59"
            res_msg = safe_fetch("GET", f"https://m.iov.changan.com.cn/appserver/api/information/getAllLatestInfo?actionType=1&startTime={start_time}&endTime={end_time}&token={token}", headers=headers, timeout=5)
            if res_msg.get("success"): cached_data["messages"] = res_msg.get("data", [])[:5]

            # 缓存更新
            if cached_data["status"]:
                cached_data["last_update"] = time.strftime("%H:%M:%S")
                vehicle_cache[vid] = {"data": cached_data, "ts": time.time()}
                print(f"[+] 车辆 {vid} 更新成功，基础数据已送达面板！")
            else:
                print(f"[-] 车辆 {vid} 更新失败: 车况接口返回为空或 Token 失效。")
            
            if vid in update_queue: update_queue.remove(vid)
            time.sleep(2) # 多车切换延迟
        
        sync_event.wait(timeout=10 if has_active_tasks else 30)
        sync_event.clear()

threading.Thread(target=fetch_worker, daemon=True).start()

@public_app.route('/')
def index(): return send_from_directory('templates', 'index.html')

@public_app.route('/api/status/<vid>')
def get_status(vid):
    if vid not in vehicle_configs: return jsonify({"code": 404, "msg": "无效的车辆标识"})
    cache = vehicle_cache.get(vid)
    if not cache: return jsonify({"code": 202, "msg": "初始化抓取中，请等待..."})
    return jsonify({"code": 200, "data": cache["data"]})

@public_app.route('/api/force-sync', methods=['POST'])
def force_sync():
    vid = request.json.get('vid')
    if vid in vehicle_configs:
        update_queue.add(vid)
        sync_event.set()
        return jsonify({"code": 200, "msg": "正在同步..."})
    return jsonify({"code": 400})

@admin_app.route('/')
def admin_index(): return send_from_directory('templates', 'admin.html')

@admin_app.route('/api/vehicles', methods=['GET', 'POST', 'DELETE'])
def manage_vehicles():
    if request.headers.get('X-Admin-Pass') != ADMIN_PASSWORD: return jsonify({"code": 403}), 403
    if request.method == 'GET': return jsonify(vehicle_configs)
    if request.method == 'POST':
        data = request.json
        vid = data.get('vid') or f"car-{int(time.time())}"
        vehicle_configs[vid] = {"name": data.get("name", "未命名"), "carId": data.get("carId"), "token": data.get("token")}
        save_db()
        return jsonify({"code": 200, "vid": vid})
    if request.method == 'DELETE':
        vid = request.args.get('vid')
        if vid in vehicle_configs:
            del vehicle_configs[vid]
            if vid in vehicle_cache: del vehicle_cache[vid]
        save_db()
        return jsonify({"code": 200})

def run_public(): public_app.run(host='0.0.0.0', port=5000, use_reloader=False)
def run_admin(): admin_app.run(host='0.0.0.0', port=5001, use_reloader=False)

if __name__ == '__main__':
    threading.Thread(target=run_public, daemon=True).start()
    threading.Thread(target=run_admin, daemon=True).start()
    while True: time.sleep(1)
