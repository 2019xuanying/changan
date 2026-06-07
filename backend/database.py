import sqlite3
import os

DB_NAME = "monitor.db"

def init_db():
    conn = sqlite3.connect(DB_NAME)
    cursor = conn.cursor()
    cursor.execute('''CREATE TABLE IF NOT EXISTS cars (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        car_name TEXT,
                        car_id TEXT,
                        token TEXT,
                        unique_slug TEXT UNIQUE)''')
    conn.commit()
    conn.close()

if __name__ == "__main__":
    init_db()
    print("数据库初始化成功")
