import telegram
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import ApplicationBuilder, CommandHandler, ContextTypes, CallbackQueryHandler, MessageHandler, filters
import asyncio
import subprocess
import json
from datetime import datetime
import shlex
import logging
import shutil
import os
from typing import Optional, List, Dict, Any
import threading
import time
import sqlite3
import random
import requests
import secrets
import string
import re

# Load environment variables
TELEGRAM_BOT_TOKEN = os.getenv('TELEGRAM_BOT_TOKEN', '')
BOT_NAME = os.getenv('BOT_NAME', 'FaiLive2 Cloud')
YOUR_SERVER_IP = os.getenv('YOUR_SERVER_IP', '127.0.0.1')
DEFAULT_STORAGE_POOL = os.getenv('DEFAULT_STORAGE_POOL', 'default')

# ---- Public IP detection ----
_cached_public_ip = None

def get_public_ip() -> str:
    global _cached_public_ip
    if _cached_public_ip: return _cached_public_ip
    try:
        resp = requests.get("https://ifconfig.me/ip", timeout=5)
        ip = resp.text.strip()
        if ip: _cached_public_ip = ip; return ip
    except Exception as e:
        logger.warning(f"Failed to fetch public IP: {e}")
    return YOUR_SERVER_IP

_raw_main_admin_ids = os.getenv('MAIN_ADMIN_ID', '1405866008127864852')
MAIN_ADMIN_IDS_ENV = [uid.strip() for uid in _raw_main_admin_ids.split(',') if uid.strip()]
MAIN_ADMIN_ID = int(MAIN_ADMIN_IDS_ENV[0]) if MAIN_ADMIN_IDS_ENV else 0
BOT_VERSION = os.getenv('BOT_VERSION', '9.0-PRO')
BOT_DEVELOPER = os.getenv('BOT_DEVELOPER', 'FaiLive2')

OS_OPTIONS = [
    {"label": "Ubuntu 20.04 LTS", "value": "ubuntu:20.04"},
    {"label": "Ubuntu 22.04 LTS", "value": "ubuntu:22.04"},
    {"label": "Ubuntu 24.04 LTS", "value": "ubuntu:24.04"},
    {"label": "Debian 10 (Buster)", "value": "images:debian/10"},
    {"label": "Debian 11 (Bullseye)", "value": "images:debian/11"},
    {"label": "Debian 12 (Bookworm)", "value": "images:debian/12"},
    {"label": "Debian 13 (Trixie)", "value": "images:debian/13"},
]

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s', handlers=[logging.FileHandler('bot.log'), logging.StreamHandler()])
logger = logging.getLogger(f'{BOT_NAME.lower()}_vps_bot')

# ------------------- Database -------------------
def get_db():
    conn = sqlite3.connect('vps.db'); conn.execute("PRAGMA journal_mode=WAL"); conn.row_factory = sqlite3.Row; return conn

def init_db():
    conn = get_db(); cur = conn.cursor()
    cur.execute('''CREATE TABLE IF NOT EXISTS admins (user_id TEXT PRIMARY KEY)''')
    cur.execute('''CREATE TABLE IF NOT EXISTS main_admins (user_id TEXT PRIMARY KEY)''')
    for uid in MAIN_ADMIN_IDS_ENV: cur.execute('INSERT OR IGNORE INTO main_admins (user_id) VALUES (?)', (uid,))
    cur.execute('''CREATE TABLE IF NOT EXISTS nodes (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE NOT NULL, location TEXT, total_vps INTEGER, tags TEXT DEFAULT '[]', api_key TEXT, url TEXT, is_local INTEGER DEFAULT 0)''')
    cur.execute('SELECT COUNT(*) FROM nodes WHERE is_local = 1')
    if cur.fetchone()[0] == 0: cur.execute('INSERT INTO nodes (name, location, total_vps, tags, api_key, url, is_local) VALUES (?, ?, ?, ?, ?, ?, ?)', (' Node', 'Local', 100, '[]', None, None, 1))
    cur.execute('''CREATE TABLE IF NOT EXISTS vps (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT NOT NULL, node_id INTEGER NOT NULL DEFAULT 1, container_name TEXT UNIQUE NOT NULL, ram TEXT NOT NULL, cpu TEXT NOT NULL, storage TEXT NOT NULL, config TEXT NOT NULL, os_version TEXT DEFAULT 'ubuntu:22.04', status TEXT DEFAULT 'stopped', suspended INTEGER DEFAULT 0, whitelisted INTEGER DEFAULT 0, created_at TEXT NOT NULL, shared_with TEXT DEFAULT '[]', suspension_history TEXT DEFAULT '[]', root_password TEXT DEFAULT '')''')
    cur.execute('PRAGMA table_info(vps)'); columns = [col[1] for col in cur.fetchall()]
    if 'os_version' not in columns: cur.execute("ALTER TABLE vps ADD COLUMN os_version TEXT DEFAULT 'ubuntu:22.04'")
    if 'node_id' not in columns: cur.execute("ALTER TABLE vps ADD COLUMN node_id INTEGER DEFAULT 1")
    if 'root_password' not in columns: cur.execute("ALTER TABLE vps ADD COLUMN root_password TEXT DEFAULT ''")
    cur.execute('''CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)''')
    cur.execute('INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)', ('cpu_threshold', '90'))
    cur.execute('INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)', ('ram_threshold', '90'))
    cur.execute('''CREATE TABLE IF NOT EXISTS port_allocations (user_id TEXT PRIMARY KEY, allocated_ports INTEGER DEFAULT 0)''')
    cur.execute('''CREATE TABLE IF NOT EXISTS port_forwards (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT NOT NULL, vps_container TEXT NOT NULL, vps_port INTEGER NOT NULL, host_port INTEGER NOT NULL, created_at TEXT NOT NULL)''')
    conn.commit(); conn.close()

def get_setting(key: str, default: Any = None):
    conn = get_db(); cur = conn.cursor(); cur.execute('SELECT value FROM settings WHERE key = ?', (key,)); row = cur.fetchone(); conn.close(); return row[0] if row else default

def set_setting(key: str, value: str):
    conn = get_db(); cur = conn.cursor(); cur.execute('INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)', (key, value)); conn.commit(); conn.close()

def get_nodes() -> List[Dict]:
    conn = get_db(); cur = conn.cursor(); cur.execute('SELECT * FROM nodes'); rows = cur.fetchall(); conn.close()
    nodes = [dict(row) for row in rows]
    for node in nodes: node['tags'] = json.loads(node['tags'])
    return nodes

def get_node(node_id: int) -> Optional[Dict]:
    conn = get_db(); cur = conn.cursor(); cur.execute('SELECT * FROM nodes WHERE id = ?', (node_id,)); row = cur.fetchone(); conn.close()
    if row: node = dict(row); node['tags'] = json.loads(node['tags']); return node
    return None

def get_current_vps_count(node_id: int) -> int:
    conn = get_db(); cur = conn.cursor(); cur.execute('SELECT COUNT(*) FROM vps WHERE node_id = ?', (node_id,)); count = cur.fetchone()[0]; conn.close(); return count

def get_vps_data() -> Dict[str, List[Dict[str, Any]]]:
    conn = get_db(); cur = conn.cursor(); cur.execute('SELECT * FROM vps'); rows = cur.fetchall(); conn.close()
    data = {}
    for row in rows:
        user_id = row['user_id']
        if user_id not in data: data[user_id] = []
        vps = dict(row)
        vps['shared_with'] = json.loads(vps['shared_with']); vps['suspension_history'] = json.loads(vps['suspension_history'])
        vps['suspended'] = bool(vps['suspended']); vps['whitelisted'] = bool(vps['whitelisted']); vps['os_version'] = vps.get('os_version', 'ubuntu:22.04')
        data[user_id].append(vps)
    return data

def get_admins() -> List[str]:
    conn = get_db(); cur = conn.cursor(); cur.execute('SELECT user_id FROM admins'); rows = cur.fetchall(); conn.close(); return [row['user_id'] for row in rows]

def get_main_admins() -> List[str]:
    conn = get_db(); cur = conn.cursor(); cur.execute('SELECT user_id FROM main_admins'); rows = cur.fetchall(); conn.close(); ids = [row['user_id'] for row in rows]; return ids if ids else [str(MAIN_ADMIN_ID)]

def save_main_admins():
    conn = get_db(); cur = conn.cursor(); cur.execute('DELETE FROM main_admins')
    for uid in main_admin_ids: cur.execute('INSERT INTO main_admins (user_id) VALUES (?)', (uid,))
    conn.commit(); conn.close()

def save_vps_data():
    conn = get_db(); cur = conn.cursor()
    for user_id, vps_list in vps_data.items():
        for vps in vps_list:
            shared_json = json.dumps(vps['shared_with']); history_json = json.dumps(vps['suspension_history'])
            suspended_int = 1 if vps['suspended'] else 0; whitelisted_int = 1 if vps.get('whitelisted', False) else 0
            os_ver = vps.get('os_version', 'ubuntu:22.04'); created_at = vps.get('created_at', datetime.now().isoformat())
            node_id = vps.get('node_id', 1); root_password = vps.get('root_password', '')
            if 'id' not in vps or vps['id'] is None:
                cur.execute('''INSERT INTO vps (user_id, node_id, container_name, ram, cpu, storage, config, os_version, status, suspended, whitelisted, created_at, shared_with, suspension_history, root_password) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
                            (user_id, node_id, vps['container_name'], vps['ram'], vps['cpu'], vps['storage'], vps['config'], os_ver, vps['status'], suspended_int, whitelisted_int, created_at, shared_json, history_json, root_password))
                vps['id'] = cur.lastrowid
            else:
                cur.execute('''UPDATE vps SET user_id = ?, node_id = ?, container_name = ?, ram = ?, cpu = ?, storage = ?, config = ?, os_version = ?, status = ?, suspended = ?, whitelisted = ?, shared_with = ?, suspension_history = ?, root_password = ? WHERE id = ?''',
                            (user_id, node_id, vps['container_name'], vps['ram'], vps['cpu'], vps['storage'], vps['config'], os_ver, vps['status'], suspended_int, whitelisted_int, shared_json, history_json, root_password, vps['id']))
    conn.commit(); conn.close()

def save_admin_data():
    conn = get_db(); cur = conn.cursor(); cur.execute('DELETE FROM admins')
    for admin_id in admin_data['admins']: cur.execute('INSERT INTO admins (user_id) VALUES (?)', (admin_id,))
    conn.commit(); conn.close()

# Port forwarding functions
def get_user_allocation(user_id: str) -> int:
    conn = get_db(); cur = conn.cursor(); cur.execute('SELECT allocated_ports FROM port_allocations WHERE user_id = ?', (user_id,)); row = cur.fetchone(); conn.close(); return row[0] if row else 0

def get_user_used_ports(user_id: str) -> int:
    conn = get_db(); cur = conn.cursor(); cur.execute('SELECT COUNT(*) FROM port_forwards WHERE user_id = ?', (user_id,)); row = cur.fetchone(); conn.close(); return row[0]

def allocate_ports(user_id: str, amount: int):
    conn = get_db(); cur = conn.cursor(); cur.execute('INSERT OR REPLACE INTO port_allocations (user_id, allocated_ports) VALUES (?, COALESCE((SELECT allocated_ports FROM port_allocations WHERE user_id = ?), 0) + ?)', (user_id, user_id, amount)); conn.commit(); conn.close()

def deallocate_ports(user_id: str, amount: int):
    conn = get_db(); cur = conn.cursor(); cur.execute('UPDATE port_allocations SET allocated_ports = GREATEST(0, allocated_ports - ?) WHERE user_id = ?', (amount, user_id)); conn.commit(); conn.close()

def get_available_host_port(node_id: int) -> Optional[int]:
    conn = get_db(); cur = conn.cursor(); cur.execute('SELECT host_port FROM port_forwards WHERE vps_container IN (SELECT container_name FROM vps WHERE node_id = ?)', (node_id,)); used_ports = set(row[0] for row in cur.fetchall()); conn.close()
    for _ in range(100):
        port = random.randint(20000, 50000)
        if port not in used_ports: return port
    return None

async def create_port_forward(user_id: str, container: str, vps_port: int, node_id: int) -> Optional[int]:
    host_port = get_available_host_port(node_id)
    if not host_port: return None
    try:
        await execute_lxc(container, f"config device add {container} tcp_proxy_{host_port} proxy listen=tcp:0.0.0.0:{host_port} connect=tcp:127.0.0.1:{vps_port}", node_id=node_id)
        await execute_lxc(container, f"config device add {container} udp_proxy_{host_port} proxy listen=udp:0.0.0.0:{host_port} connect=udp:127.0.0.1:{vps_port}", node_id=node_id)
        conn = get_db(); cur = conn.cursor(); cur.execute('INSERT INTO port_forwards (user_id, vps_container, vps_port, host_port, created_at) VALUES (?, ?, ?, ?, ?)', (user_id, container, vps_port, host_port, datetime.now().isoformat())); conn.commit(); conn.close()
        return host_port
    except Exception as e:
        logger.error(f"Failed to create port forward: {e}"); return None

async def remove_port_forward(forward_id: int, is_admin: bool = False) -> tuple[bool, Optional[str]]:
    conn = get_db(); cur = conn.cursor(); cur.execute('SELECT user_id, vps_container, host_port FROM port_forwards WHERE id = ?', (forward_id,)); row = cur.fetchone()
    if not row: conn.close(); return False, None
    user_id, container, host_port = row; node_id = find_node_id_for_container(container)
    try:
        await execute_lxc(container, f"config device remove {container} tcp_proxy_{host_port}", node_id=node_id)
        await execute_lxc(container, f"config device remove {container} udp_proxy_{host_port}", node_id=node_id)
        cur.execute('DELETE FROM port_forwards WHERE id = ?', (forward_id,)); conn.commit(); conn.close(); return True, user_id
    except Exception as e:
        logger.error(f"Failed to remove port forward {forward_id}: {e}"); conn.close(); return False, None

def get_user_forwards(user_id: str) -> List[Dict]:
    conn = get_db(); cur = conn.cursor(); cur.execute('SELECT * FROM port_forwards WHERE user_id = ? ORDER BY created_at DESC', (user_id,)); rows = cur.fetchall(); conn.close(); return [dict(row) for row in rows]

async def recreate_port_forwards(container_name: str) -> int:
    node_id = find_node_id_for_container(container_name); readded_count = 0
    conn = get_db(); cur = conn.cursor(); cur.execute('SELECT vps_port, host_port FROM port_forwards WHERE vps_container = ?', (container_name,)); rows = cur.fetchall()
    for row in rows:
        vps_port = row['vps_port']; host_port = row['host_port']
        try:
            await execute_lxc(container_name, f"config device add {container_name} tcp_proxy_{host_port} proxy listen=tcp:0.0.0.0:{host_port} connect=tcp:127.0.0.1:{vps_port}", node_id=node_id)
            await execute_lxc(container_name, f"config device add {container_name} udp_proxy_{host_port} proxy listen=udp:0.0.0.0:{host_port} connect=udp:127.0.0.1:{vps_port}", node_id=node_id)
            readded_count += 1
        except Exception as e: logger.error(f"Failed to re-add port forward {host_port}->{vps_port}: {e}")
    conn.close(); return readded_count

def find_node_id_for_container(container_name: str) -> int:
    conn = get_db(); cur = conn.cursor(); cur.execute('SELECT node_id FROM vps WHERE container_name = ?', (container_name,)); row = cur.fetchone(); conn.close(); return row[0] if row else 1

# Initialize database
init_db()
vps_data = get_vps_data()
admin_data = {'admins': get_admins()}
main_admin_ids = set(get_main_admins())
CPU_THRESHOLD = int(get_setting('cpu_threshold', 90))
RAM_THRESHOLD = int(get_setting('ram_threshold', 90))

# ------------------- Utilities -------------------
def is_admin(user_id):
    user_id = str(user_id)
    return user_id in main_admin_ids or user_id in admin_data.get("admins", [])

def is_main_admin(user_id):
    return str(user_id) in main_admin_ids

async def execute_lxc(container_name: str, command: str, timeout=120, node_id: Optional[int] = None):
    if node_id is None: node_id = find_node_id_for_container(container_name)
    node = get_node(node_id)
    if not node: raise Exception(f"Node {node_id} not found")
    full_command = f"lxc {command}"
    if node['is_local']:
        try:
            cmd = shlex.split(full_command)
            proc = await asyncio.create_subprocess_exec(*cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
            try: stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
            except asyncio.TimeoutError:
                proc.kill(); await proc.wait(); raise asyncio.TimeoutError(f"Command timed out after {timeout} seconds")
            if proc.returncode != 0:
                error = stderr.decode().strip() if stderr else "Command failed"
                raise Exception(f"Local LXC command failed: {error}")
            return stdout.decode().strip() if stdout else True
        except Exception as e:
            logger.error(f"LXC Error: {full_command} - {str(e)}"); raise
    else:
        url = f"{node['url']}/api/execute"; data = {"command": full_command}; params = {"api_key": node["api_key"]}
        try:
            response = requests.post(url, json=data, params=params, timeout=timeout); response.raise_for_status(); res = response.json()
            if res.get("returncode", 1) != 0:
                stderr = res.get("stderr", "Command failed")
                raise Exception(f"Remote LXC command failed on {node['name']}: {stderr}")
            return res.get("stdout", True)
        except Exception as e: raise Exception(f"Remote execution failed on {node['name']}: {str(e)}")

async def safe_start_container(container_name: str, node_id: int):
    try: await execute_lxc(container_name, f"start {container_name}", node_id=node_id)
    except Exception as e:
        err_text = str(e).lower()
        if "already running" in err_text or "is running" in err_text: pass
        else: raise

async def apply_lxc_config(container_name: str, node_id: int):
    try:
        await execute_lxc(container_name, f"config set {container_name} security.nesting true", node_id=node_id)
        await execute_lxc(container_name, f"config set {container_name} security.privileged true", node_id=node_id)
        await execute_lxc(container_name, f"config set {container_name} security.syscalls.intercept.mknod true", node_id=node_id)
        await execute_lxc(container_name, f"config set {container_name} security.syscalls.intercept.setxattr true", node_id=node_id)
        await execute_lxc(container_name, f"config set {container_name} linux.kernel_modules overlay,loop,nf_nat,ip_tables,ip6_tables,netlink_diag,br_netfilter", node_id=node_id)
        try: await execute_lxc(container_name, f"config device add {container_name} fuse unix-char path=/dev/fuse", node_id=node_id)
        except: pass
        raw_lxc_config = (
            "lxc.apparmor.profile = unconfined\n"
            "lxc.apparmor.allow_nesting = 1\n"
            "lxc.apparmor.allow_incomplete = 1\n"
            "\n"
            "lxc.cap.drop =\n"
            "lxc.cgroup.devices.allow = a\n"
            "lxc.cgroup2.devices.allow = a\n"
            "\n"
            "lxc.mount.auto = proc:rw sys:rw cgroup:rw shmounts:rw\n"
            "\n"
            "lxc.mount.entry = /dev/fuse dev/fuse none bind,create=file 0 0\n"
        )
        await execute_lxc(container_name, f"config set {container_name} raw.lxc '{raw_lxc_config}'", node_id=node_id)
    except Exception as e: logger.error(f"Failed to apply LXC config: {e}")

async def apply_internal_permissions(container_name: str, node_id: int):
    try:
        await asyncio.sleep(8)
        commands = [
            "mkdir -p /etc/sysctl.d/",
            "echo 'net.ipv4.ip_unprivileged_port_start=0' > /etc/sysctl.d/99-custom.conf",
            "echo 'net.ipv4.ping_group_range=0 2147483647' >> /etc/sysctl.d/99-custom.conf",
            "echo 'fs.inotify.max_user_watches=524288' >> /etc/sysctl.d/99-custom.conf",
            "echo 'kernel.unprivileged_userns_clone=1' >> /etc/sysctl.d/99-custom.conf",
            "sysctl -p /etc/sysctl.d/99-custom.conf || true"
        ]
        for cmd in commands:
            try: await execute_lxc(container_name, f"exec {container_name} -- bash -c \"{cmd}\"", node_id=node_id)
            except Exception: pass
    except Exception: pass

def generate_password(length: int = 16) -> str:
    alphabet = string.ascii_letters + string.digits
    return ''.join(secrets.choice(alphabet) for _ in range(length))

async def setup_ssh_access(container_name: str, node_id: int, user_id: str, vps_count: int, config_str: str) -> str:
    password = generate_password()
    
    # Custom Welcome MOTD
    motd_script = f"""#!/bin/bash
clear
echo -e "\\e[1;36m"
echo "  ███████╗ █████╗ ██╗    ██╗     ██╗██╗   ██╗███████╗██████╗ "
echo "  ██╔════╝██╔══██╗██║    ██║     ██║██║   ██║██╔════╝╚════██╗"
echo "  █████╗  ███████║██║    ██║     ██║██║   ██║█████╗   █████╔╝"
echo "  ██╔══╝  ██╔══██║██║    ██║     ██║╚██╗ ██╔╝██╔══╝   ╚═══██╗"
echo "  ██║     ██║  ██║██║    ███████╗██║ ╚████╔╝ ███████╗██████╔╝"
echo "  ╚═╝     ╚═╝  ╚═╝╚═╝    ╚══════╝╚═╝  ╚═══╝  ╚══════╝╚═════╝ "
echo -e "\\e[0m"
echo -e "\\e[1;32mWelcome {{$USER}} to FaiLive2 Cloud!\\e[0m"
echo "------------------------------------------------------------"
echo -e "\\e[1;33mIP Address:\\e[0m $(hostname -I | awk '{{print $1}}')"
echo -e "\\e[1;33mVPS Name:  \\e[0m {container_name}"
echo -e "\\e[1;33mConfig:    \\e[0m {config_str}"
echo -e "\\e[1;33mOS:        \\e[0m $(lsb_release -d | cut -f2)"
echo "------------------------------------------------------------"
echo -e "\\e[1;36m• Root Access: Enabled"
echo -e "• Support: t.me/FaiLive2"
echo -e "• Thank you for choosing FaiLive2 Cloud!\\e[0m"
echo ""
"""
    # Base64 encode the MOTD script to safely pass it via echo without breaking bash strings
    import base64
    b64_motd = base64.b64encode(motd_script.encode()).decode()
    
    commands = [
        "DEBIAN_FRONTEND=noninteractive apt-get update -y",
        "DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server lsb-release",
        f"echo 'root:{password}' | chpasswd",
        "printf 'PermitRootLogin yes\\nPasswordAuthentication yes\\n\\n' | cat - /etc/ssh/sshd_config > /tmp/sshd_config.new && mv /tmp/sshd_config.new /etc/ssh/sshd_config",
        "mkdir -p /run/sshd",
        # Write the welcome MOTD
        f"echo '{b64_motd}' | base64 -d > /etc/profile.d/failive2_welcome.sh",
        "chmod +x /etc/profile.d/failive2_welcome.sh",
        # Change the root prompt to root@FaiLive2-{id}-{count}
        f"echo 'export PS1=\"\\[\\e[1;31m\\]root@FaiLive2-{user_id}-{vps_count}\\[\\e[0m\\]:\\[\\e[1;34m\\]~# \\[\\e[0m\\]\"' >> /root/.bashrc",
        "systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true",
        "systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || service sshd restart 2>/dev/null || true"
    ]
    for cmd in commands:
        try: await execute_lxc(container_name, f"exec {container_name} -- bash -c \"{cmd}\"", node_id=node_id, timeout=180)
        except Exception as e: logger.error(f"SSH setup error: {e}")
    return password

PINGGY_LOG_PATH = "/root/.pinggy_tunnel.log"

def parse_pinggy_address(log_text: str) -> Optional[str]:
    if not log_text: return None
    match = re.search(r'tcp://([\w\.\-]+):(\d+)', log_text, re.IGNORECASE)
    if match: return f"{match.group(1)}:{match.group(2)}"
    return None

async def establish_pinggy_tunnel(container_name: str, node_id: int, retries: int = 4, wait_seconds: int = 5) -> Optional[str]:
    try:
        await execute_lxc(container_name, f"exec {container_name} -- bash -c \"command -v ssh >/dev/null || (DEBIAN_FRONTEND=noninteractive apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-client)\"", node_id=node_id, timeout=180)
    except Exception: pass
    try: await execute_lxc(container_name, f"exec {container_name} -- bash -c \"pkill -f 'free.pinggy.io' >/dev/null 2>&1; rm -f {PINGGY_LOG_PATH}\"", node_id=node_id)
    except Exception: pass
    tunnel_cmd = (
        "setsid nohup ssh -p 443 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
        "-o ServerAliveInterval=30 -R0:localhost:22 qr+tcp@free.pinggy.io "
        f"> {PINGGY_LOG_PATH} 2>&1 < /dev/null & disown"
    )
    try: await execute_lxc(container_name, f"exec {container_name} -- bash -c \"{tunnel_cmd}\"", node_id=node_id)
    except Exception: return None
    for attempt in range(retries):
        await asyncio.sleep(wait_seconds)
        try: log_output = await execute_lxc(container_name, f"exec {container_name} -- cat {PINGGY_LOG_PATH}", node_id=node_id)
        except Exception: log_output = ""
        address = parse_pinggy_address(log_output if isinstance(log_output, str) else "")
        if address: return address
    return None

# Placeholder stats
async def get_container_stats(container_name: str, node_id: Optional[int] = None) -> Dict:
    return {"status": "running", "cpu": 0.0, "ram": {"used": 0, "total": 0, "pct": 0.0}, "disk": "Unknown", "uptime": "Unknown"}

async def get_container_uptime(container_name: str, node_id: Optional[int] = None): return "Unknown"

# ------------------- Telegram Handlers -------------------
async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text(f"🌟 <b>{BOT_NAME} VPS Manager</b>\n\nUse /help to see all commands.\nYour Telegram ID: <code>{update.effective_user.id}</code>", parse_mode="HTML")

async def help_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = str(update.effective_user.id); is_admin_user = is_admin(user_id)
    text = f"<b>🌟 {BOT_NAME} Command List</b>\n\n<b>👤 User Commands</b>\n/start - Start the bot\n/help - Show this menu\n/myvps - List your VPS\n/manage - Open VPS management menu\n"
    if is_admin_user:
        text += "\n<b>🛡️ Admin Commands</b>\n/create &lt;ram&gt; &lt;cpu&gt; &lt;disk&gt; &lt;user_id&gt; - Create VPS\n/list-all - List all VPS\n/userinfo &lt;user_id&gt; - User info\n/delete-vps &lt;user_id&gt; &lt;vps_number&gt; - Delete VPS\n/status - System status\n"
    if is_main_admin(user_id):
        text += "\n<b>👑 Main Admin Commands</b>\n/admin-add &lt;user_id&gt; - Add admin\n/admin-remove &lt;user_id&gt; - Remove admin\n/admin-list - List admins\n"
    await update.message.reply_text(text, parse_mode="HTML")

async def my_vps(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = str(update.effective_user.id); vps_list = vps_data.get(user_id, [])
    if not vps_list:
        await update.message.reply_text(f"❌ You don't have any <b>{BOT_NAME} VPS</b> yet.\nContact an admin.", parse_mode="HTML"); return
    total_vps = len(vps_list); running = suspended = whitelisted = 0
    text = f"<b>🖥️ My VPS Dashboard</b>\n\n"
    for i, vps in enumerate(vps_list, start=1):
        config = vps.get("config", "Custom"); ram = vps.get("ram", "0GB"); cpu = vps.get("cpu", "0"); storage = vps.get("storage", "0GB")
        if vps.get("suspended"): status = "⛔ SUSPENDED"; suspended += 1
        elif vps.get("status") == "running": status = "🟢 RUNNING"; running += 1
        else: status = "🔴 STOPPED"
        if vps.get("whitelisted"): whitelisted += 1
        text += f"<b>{i}.</b> <code>{vps['container_name']}</code>\n{status} • {config}\n⚙️ {ram} RAM • {cpu} CPU • {storage} Disk\n\n"
    text += f"<b>Summary:</b>\n🖥️ {total_vps} Total\n🟢 {running} Running\n⛔ {suspended} Suspended\n✅ {whitelisted} Whitelisted"
    await update.message.reply_text(text, parse_mode="HTML")

async def manage_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = str(update.effective_user.id); vps_list = vps_data.get(user_id, [])
    if not vps_list:
        await update.message.reply_text(f"❌ You don't have any <b>{BOT_NAME} VPS</b> yet.", parse_mode="HTML"); return
    if len(vps_list) == 1: await show_vps_manage_menu(update, context, 0)
    else:
        keyboard = []
        for i, vps in enumerate(vps_list): keyboard.append([InlineKeyboardButton(f"VPS {i+1}: {vps['container_name']} ({vps.get('status', 'unknown').upper()})", callback_data=f"manage_{i}")])
        await update.message.reply_text("Select a VPS to manage:", reply_markup=InlineKeyboardMarkup(keyboard))

async def show_vps_manage_menu(update: Update, context: ContextTypes.DEFAULT_TYPE, index: int, from_callback=False):
    user_id = str(update.effective_user.id); vps_list = vps_data.get(user_id, [])
    if not vps_list or index >= len(vps_list): return
    vps = vps_list[index]; container_name = vps['container_name']
    status = vps.get('status', 'unknown').upper(); suspended = vps.get('suspended', False)
    config = vps.get('config', 'Custom'); ram = vps.get('ram', '0GB'); cpu = vps.get('cpu', '0'); storage = vps.get('storage', '0GB')
    status_text = f"{status}"
    if suspended: status_text += " (SUSPENDED)"
    text = f"<b>🖥️ Managing VPS {index+1}</b>\n\n<b>Container:</b> <code>{container_name}</code>\n<b>Status:</b> {status_text}\n<b>Config:</b> {config}\n<b>RAM:</b> {ram} | <b>CPU:</b> {cpu} | <b>Disk:</b> {storage}\n"
    keyboard = [
        [InlineKeyboardButton("▶ Start", callback_data=f"start_{index}"), InlineKeyboardButton("⏸ Stop", callback_data=f"stop_{index}")],
        [InlineKeyboardButton("🔄 Reinstall", callback_data=f"reinstall_{index}"), InlineKeyboardButton("📊 Stats", callback_data=f"stats_{index}")],
        [InlineKeyboardButton("🔑 SSH", callback_data=f"ssh_{index}"), InlineKeyboardButton("🔐 Change Pass", callback_data=f"pass_{index}")],
        [InlineKeyboardButton("🔌 Reconnect Tunnel", callback_data=f"reconnect_{index}")],
        [InlineKeyboardButton("🗑️ Delete VPS", callback_data=f"delete_{index}")],
        [InlineKeyboardButton("🔙 Back to List", callback_data="back_to_list")]
    ]
    reply_markup = InlineKeyboardMarkup(keyboard)
    if from_callback: await update.callback_query.edit_message_text(text, reply_markup=reply_markup, parse_mode="HTML")
    else: await update.message.reply_text(text, reply_markup=reply_markup, parse_mode="HTML")

async def create_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = str(update.effective_user.id)
    if not is_admin(user_id): await update.message.reply_text("❌ Admin only."); return
    try:
        args = context.args
        if len(args) < 4: await update.message.reply_text("Usage: /create <ram_gb> <cpu_cores> <disk_gb> <user_id>"); return
        ram = int(args[0]); cpu = int(args[1]); disk = int(args[2]); target_user = str(args[3])
    except ValueError: await update.message.reply_text("❌ Invalid arguments."); return
    nodes = get_nodes(); keyboard = []
    for n in nodes:
        current_count = get_current_vps_count(n['id'])
        if current_count < n['total_vps']: keyboard.append([InlineKeyboardButton(f"{n['name']} ({n['location']}) - {n['total_vps'] - current_count} free", callback_data=f"node_{n['id']}_{ram}_{cpu}_{disk}_{target_user}")])
    if not keyboard: await update.message.reply_text("❌ No available nodes."); return
    await update.message.reply_text(f"Creating VPS for user `{target_user}` with {ram}GB RAM, {cpu} CPU, {disk}GB Disk.\nSelect node:", reply_markup=InlineKeyboardMarkup(keyboard), parse_mode="Markdown")

async def handle_callback(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query; await query.answer(); data = query.data; user_id = str(query.from_user.id)
    if data == "back_to_list": await manage_command(update, context); return
    if data.startswith("manage_"): index = int(data.split("_")[1]); await show_vps_manage_menu(update, context, index, from_callback=True); return
    if data.startswith("node_"):
        parts = data.split("_"); node_id = int(parts[1]); ram = int(parts[2]); cpu = int(parts[3]); disk = int(parts[4]); target_user = parts[5]
        keyboard = []
        for os_opt in OS_OPTIONS: keyboard.append([InlineKeyboardButton(os_opt['label'], callback_data=f"os_{node_id}_{ram}_{cpu}_{disk}_{target_user}_{os_opt['value']}")])
        await query.edit_message_text("Select OS:", reply_markup=InlineKeyboardMarkup(keyboard)); return
    if data.startswith("os_"):
        parts = data.split("_"); node_id = int(parts[1]); ram = int(parts[2]); cpu = int(parts[3]); disk = int(parts[4]); target_user = parts[5]; os_version = "_".join(parts[6:])
        await query.edit_message_text("⏳ Creating VPS, please wait...")
        if target_user not in vps_data: vps_data[target_user] = []
        vps_count = len(vps_data[target_user]) + 1; container_name = f"{BOT_NAME.lower()}-vps-{target_user}-{vps_count}"; ram_mb = ram * 1024
        config_str = f"{ram}GB RAM / {cpu} CPU / {disk}GB Disk"
        try:
            await execute_lxc(container_name, f"init {os_version} {container_name} -s {DEFAULT_STORAGE_POOL}", node_id=node_id)
            await execute_lxc(container_name, f"config set {container_name} limits.memory {ram_mb}MB", node_id=node_id)
            await execute_lxc(container_name, f"config set {container_name} limits.cpu {cpu}", node_id=node_id)
            await execute_lxc(container_name, f"config device set {container_name} root size={disk}GB", node_id=node_id)
            await apply_lxc_config(container_name, node_id); await safe_start_container(container_name, node_id)
            await apply_internal_permissions(container_name, node_id)
            
            # Pass user_id and vps_count to customize the prompt
            root_password = await setup_ssh_access(container_name, node_id, target_user, vps_count, config_str)
            pinggy_address = await establish_pinggy_tunnel(container_name, node_id)
            
            vps_info = {
                "container_name": container_name, "node_id": node_id, "ram": f"{ram}GB", "cpu": str(cpu), "storage": f"{disk}GB",
                "config": config_str, "os_version": os_version, "status": "running", "suspended": False, "whitelisted": False,
                "suspension_history": [], "created_at": datetime.now().isoformat(), "shared_with": [], "root_password": root_password,
                "pinggy_address": pinggy_address, "id": None
            }
            vps_data[target_user].append(vps_info); save_vps_data()
            
            # Group Message
            text = f"✅ VPS Created Successfully!\n\n<b>VPS:</b> <code>{container_name}</code>\n<b>Config:</b> {config_str}\n<b>OS:</b> {os_version}\n<b>Password:</b> <code>{root_password}</code>\n"
            if pinggy_address: tunnel_host, tunnel_port = pinggy_address.split(":"); text += f"<b>SSH:</b> <code>ssh root@{tunnel_host} -p {tunnel_port}</code>\n"
            await query.edit_message_text(text, parse_mode="HTML")
            
            # DM Message
            try:
                user_msg = f"🎉 <b>VPS Created!</b>\n\nYour VPS has been successfully deployed by an admin!\n\n<b>VPS ID:</b> #{vps_count}\n<b>Container:</b> <code>{container_name}</code>\n<b>Configuration:</b> {config_str}\n<b>Status:</b> Running\n<b>OS:</b> {os_version}\n\n"
                if pinggy_address:
                    tunnel_host, tunnel_port = pinggy_address.split(":")
                    user_msg += f"🔑 <b>SSH Login:</b>\nHost: <code>{tunnel_host}</code>\nPort: <code>{tunnel_port}</code>\nUser: <code>root</code>\nPassword: <code>{root_password}</code>\n\n<code>ssh root@{tunnel_host} -p {tunnel_port}</code>\n"
                else: user_msg += f"🔑 <b>Root Password:</b> <code>{root_password}</code>\n⚠️ SSH tunnel setup failed — use /manage → 🔌 Reconnect Tunnel to try again.\n"
                user_msg += f"\n<b>Management:</b> Use /manage to start/stop/reinstall your VPS\n\n<b>Important Notes:</b>\n• Full root access via SSH\n• Docker-ready\n• Change your root password after first login"
                await context.bot.send_message(chat_id=int(target_user), text=user_msg, parse_mode="HTML")
            except Exception as e: logger.warning(f"Failed to DM user {target_user}: {e}")
        except Exception as e: await query.edit_message_text(f"❌ Creation Failed: {str(e)}")
        return
    if data.startswith(("start_", "stop_", "reinstall_", "stats_", "ssh_", "pass_", "delete_", "reconnect_", "confirm_delete_", "cancel_delete")):
        parts = data.split("_"); action = parts[0]
        if action == "confirm": action = "confirm_delete"; index = int(parts[2])
        elif action == "cancel": action = "cancel_delete"; index = 0
        else: index = int(parts[1])
        vps_list = vps_data.get(user_id, [])
        if not vps_list or (action not in ["cancel_delete"] and index >= len(vps_list)): await query.edit_message_text("❌ VPS not found."); return
        vps = vps_list[index] if action != "cancel_delete" else None
        if vps: container_name = vps['container_name']; node_id = vps['node_id']
        if action == "start":
            try: await safe_start_container(container_name, node_id); vps['status'] = 'running'; save_vps_data(); await query.edit_message_text(f"✅ VPS <code>{container_name}</code> started.", parse_mode="HTML")
            except Exception as e: await query.edit_message_text(f"❌ Start failed: {str(e)}")
        elif action == "stop":
            try: await execute_lxc(container_name, f"stop {container_name}", node_id=node_id); vps['status'] = 'stopped'; save_vps_data(); await query.edit_message_text(f"✅ VPS <code>{container_name}</code> stopped.", parse_mode="HTML")
            except Exception as e: await query.edit_message_text(f"❌ Stop failed: {str(e)}")
        elif action == "reinstall":
            keyboard = []
            for os_opt in OS_OPTIONS: keyboard.append([InlineKeyboardButton(os_opt['label'], callback_data=f"reinstall_os_{index}_{os_opt['value']}")])
            await query.edit_message_text("Select new OS for reinstallation (WARNING: This will erase all data):", reply_markup=InlineKeyboardMarkup(keyboard))
        elif action == "reinstall_os":
            os_version = parts[3] if len(parts) > 3 else parts[-1]
            await query.edit_message_text(f"⏳ Reinstalling VPS with {os_version}...")
            try:
                await execute_lxc(container_name, f"delete {container_name} --force", node_id=node_id)
                ram = int(vps['ram'].replace('GB', '')); cpu = int(vps['cpu']); disk = int(vps['storage'].replace('GB', '')); ram_mb = ram * 1024
                await execute_lxc(container_name, f"init {os_version} {container_name} -s {DEFAULT_STORAGE_POOL}", node_id=node_id)
                await execute_lxc(container_name, f"config set {container_name} limits.memory {ram_mb}MB", node_id=node_id)
                await execute_lxc(container_name, f"config set {container_name} limits.cpu {cpu}", node_id=node_id)
                await execute_lxc(container_name, f"config device set {container_name} root size={disk}GB", node_id=node_id)
                await apply_lxc_config(container_name, node_id); await safe_start_container(container_name, node_id)
                await apply_internal_permissions(container_name, node_id)
                
                config_str = f"{ram}GB RAM / {cpu} CPU / {disk}GB Disk"
                root_password = await setup_ssh_access(container_name, node_id, user_id, index+1, config_str)
                pinggy_address = await establish_pinggy_tunnel(container_name, node_id)
                vps['status'] = 'running'; vps['os_version'] = os_version; vps['root_password'] = root_password; vps['pinggy_address'] = pinggy_address
                save_vps_data()
                await query.edit_message_text(f"✅ VPS <code>{container_name}</code> reinstalled with {os_version}.", parse_mode="HTML")
            except Exception as e: await query.edit_message_text(f"❌ Reinstall failed: {str(e)}")
        elif action == "stats":
            await query.edit_message_text(f"📊 <b>Stats for {container_name}</b>\n\nCPU: 0.0%\nRAM: 0/0 MB\nDisk: Unknown\nUptime: Unknown", parse_mode="HTML")
        elif action == "ssh":
            try:
                if vps.get('pinggy_address'):
                    tunnel_host, tunnel_port = vps['pinggy_address'].split(":")
                    ssh_text = f"🔑 <b>SSH Login for {container_name}</b>\n\nHost: <code>{tunnel_host}</code>\nPort: <code>{tunnel_port}</code>\nUser: <code>root</code>\nPassword: <code>{vps.get('root_password', 'Unknown')}</code>\n\n<code>ssh root@{tunnel_host} -p {tunnel_port}</code>"
                else: ssh_text = f"🔑 <b>Root Password for {container_name}</b>\n\n<code>{vps.get('root_password', 'Unknown')}</code>\n\n⚠️ No SSH tunnel address available. Use Reconnect Tunnel."
                await context.bot.send_message(chat_id=int(user_id), text=ssh_text, parse_mode="HTML"); await query.edit_message_text("✅ SSH info sent to your DMs.")
            except Exception as e: await query.edit_message_text(f"❌ Could not send SSH info: {str(e)}")
        elif action == "pass":
            try:
                new_password = generate_password()
                await execute_lxc(container_name, f"exec {container_name} -- bash -c \"echo 'root:{new_password}' | chpasswd\"", node_id=node_id, timeout=60)
                vps['root_password'] = new_password; save_vps_data()
                try:
                    await context.bot.send_message(chat_id=int(user_id), text=f"🔐 <b>Root Password Changed</b>\n\nVPS: <code>{container_name}</code>\nNew Password: <code>{new_password}</code>\n\nKeep this private.", parse_mode="HTML")
                    await query.edit_message_text("✅ New password sent to your DMs.")
                except Exception as e: await query.edit_message_text(f"✅ Password changed: <code>{new_password}</code>", parse_mode="HTML")
            except Exception as e: await query.edit_message_text(f"❌ Password change failed: {str(e)}")
        elif action == "reconnect":
            await query.edit_message_text("⏳ Reconnecting SSH tunnel...")
            try:
                new_address = await establish_pinggy_tunnel(container_name, node_id); vps['pinggy_address'] = new_address; save_vps_data()
                if new_address:
                    tunnel_host, tunnel_port = new_address.split(":")
                    try:
                        await context.bot.send_message(chat_id=int(user_id), text=f"🔌 <b>SSH Tunnel Reconnected</b>\n\nHost: <code>{tunnel_host}</code>\nPort: <code>{tunnel_port}</code>\n\n<code>ssh root@{tunnel_host} -p {tunnel_port}</code>", parse_mode="HTML")
                        await query.edit_message_text("✅ Tunnel reconnected. Check your DMs.")
                    except Exception: await query.edit_message_text(f"✅ Tunnel: <code>{tunnel_host}:{tunnel_port}</code>", parse_mode="HTML")
                else: await query.edit_message_text("❌ Tunnel could not be reconnected.")
            except Exception as e: await query.edit_message_text(f"❌ Reconnect failed: {str(e)}")
        elif action == "delete":
            keyboard = [[InlineKeyboardButton("✅ Confirm Delete", callback_data=f"confirm_delete_{index}")], [InlineKeyboardButton("❌ Cancel", callback_data="cancel_delete")]]
            await query.edit_message_text(f"⚠️ Are you sure you want to delete <code>{container_name}</code>?\nThis cannot be undone!", reply_markup=InlineKeyboardMarkup(keyboard), parse_mode="HTML")
        elif action == "confirm_delete":
            try: await execute_lxc(container_name, f"delete {container_name} --force", node_id=node_id)
            except: pass
            conn = get_db(); cur = conn.cursor(); cur.execute("DELETE FROM vps WHERE container_name = ?", (container_name,)); cur.execute("DELETE FROM port_forwards WHERE vps_container = ?", (container_name,)); conn.commit(); conn.close()
            del vps_data[user_id][index]; save_vps_data(); await query.edit_message_text(f"✅ VPS <code>{container_name}</code> deleted.", parse_mode="HTML")
        elif action == "cancel_delete": await show_vps_manage_menu(update, context, index, from_callback=True)
        return

async def list_all_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = str(update.effective_user.id)
    if not is_admin(user_id): await update.message.reply_text("❌ Admin only."); return
    total_vps = sum(len(v) for v in vps_data.values()); text = f"<b>📊 All VPS</b>\n\nTotal: {total_vps}\n\n"
    for uid, vps_list in vps_data.items():
        text += f"<b>User <code>{uid}</code>:</b>\n"
        for i, vps in enumerate(vps_list): text += f"  {i+1}. <code>{vps['container_name']}</code> - {vps.get('status', 'unknown')}\n"
        text += "\n"
    if len(text) > 4000: text = text[:4000] + "\n...truncated"
    await update.message.reply_text(text, parse_mode="HTML")

async def userinfo_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = str(update.effective_user.id)
    if not is_admin(user_id): await update.message.reply_text("❌ Admin only."); return
    if not context.args: await update.message.reply_text("Usage: /userinfo <user_id>"); return
    target_id = str(context.args[0]); vps_list = vps_data.get(target_id, [])
    text = f"<b>👤 User Info</b>\n\n<b>User ID:</b> <code>{target_id}</code>\n<b>Admin:</b> {'✅ Yes' if is_admin(target_id) else '❌ No'}\n<b>VPS Count:</b> {len(vps_list)}\n\n"
    for i, vps in enumerate(vps_list): text += f"{i+1}. <code>{vps['container_name']}</code> - {vps.get('status', 'unknown')}\n"
    await update.message.reply_text(text, parse_mode="HTML")

async def status_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = str(update.effective_user.id)
    if not is_admin(user_id): await update.message.reply_text("❌ Admin only."); return
    total_users = len(vps_data); total_vps = sum(len(v) for v in vps_data.values())
    running = sum(1 for v in vps_data.values() for vps in v if vps.get('status') == 'running' and not vps.get('suspended'))
    suspended = sum(1 for v in vps_data.values() for vps in v if vps.get('suspended'))
    text = f"<b>📊 System Status</b>\n\n<b>Users:</b> {total_users}\n<b>Total VPS:</b> {total_vps}\n<b>Running:</b> {running}\n<b>Suspended:</b> {suspended}\n<b>Version:</b> {BOT_VERSION}\n<b>Developer:</b> {BOT_DEVELOPER}"
    await update.message.reply_text(text, parse_mode="HTML")

async def delete_vps_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = str(update.effective_user.id)
    if not is_admin(user_id): await update.message.reply_text("❌ Admin only."); return
    if len(context.args) < 2: await update.message.reply_text("Usage: /delete-vps <user_id> <vps_number>"); return
    target_id = str(context.args[0])
    try: vps_number = int(context.args[1])
    except ValueError: await update.message.reply_text("❌ Invalid VPS number."); return
    if target_id not in vps_data or vps_number < 1 or vps_number > len(vps_data[target_id]): await update.message.reply_text("❌ VPS not found."); return
    vps = vps_data[target_id][vps_number - 1]; container_name = vps['container_name']; node_id = vps['node_id']
    try: await execute_lxc(container_name, f"delete {container_name} --force", node_id=node_id)
    except: pass
    conn = get_db(); cur = conn.cursor(); cur.execute("DELETE FROM vps WHERE container_name = ?", (container_name,)); cur.execute("DELETE FROM port_forwards WHERE vps_container = ?", (container_name,)); conn.commit(); conn.close()
    del vps_data[target_id][vps_number - 1]
    if not vps_data[target_id]: del vps_data[target_id]
    save_vps_data(); await update.message.reply_text(f"✅ VPS <code>{container_name}</code> deleted.", parse_mode="HTML")

async def admin_add_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = str(update.effective_user.id)
    if not is_main_admin(user_id): await update.message.reply_text("❌ Main admin only."); return
    if not context.args: await update.message.reply_text("Usage: /admin-add <user_id>"); return
    target_id = str(context.args[0])
    if target_id in admin_data["admins"]: await update.message.reply_text("Already an admin."); return
    admin_data["admins"].append(target_id); save_admin_data(); await update.message.reply_text(f"✅ <code>{target_id}</code> added as admin.", parse_mode="HTML")

async def admin_remove_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = str(update.effective_user.id)
    if not is_main_admin(user_id): await update.message.reply_text("❌ Main admin only."); return
    if not context.args: await update.message.reply_text("Usage: /admin-remove <user_id>"); return
    target_id = str(context.args[0])
    if target_id not in admin_data["admins"]: await update.message.reply_text("Not an admin."); return
    admin_data["admins"].remove(target_id); save_admin_data(); await update.message.reply_text(f"✅ <code>{target_id}</code> removed from admins.", parse_mode="HTML")

async def admin_list_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = str(update.effective_user.id)
    if not is_main_admin(user_id): await update.message.reply_text("❌ Main admin only."); return
    text = "<b>👑 Admins</b>\n\n<b>Main Admins:</b>\n"
    for mid in main_admin_ids: text += f"  <code>{mid}</code>\n"
    text += "\n<b>Admins:</b>\n"
    for aid in admin_data.get("admins", []): text += f"  <code>{aid}</code>\n"
    await update.message.reply_text(text, parse_mode="HTML")

# ------------------- Main -------------------
def main():
    if not TELEGRAM_BOT_TOKEN: logger.error("No Telegram bot token found!"); return
    application = ApplicationBuilder().token(TELEGRAM_BOT_TOKEN).build()
    application.add_handler(CommandHandler("start", start))
    application.add_handler(CommandHandler("help", help_command))
    application.add_handler(CommandHandler("myvps", my_vps))
    application.add_handler(CommandHandler("manage", manage_command))
    application.add_handler(CommandHandler("create", create_command))
    application.add_handler(CommandHandler("list-all", list_all_command))
    application.add_handler(CommandHandler("userinfo", userinfo_command))
    application.add_handler(CommandHandler("status", status_command))
    application.add_handler(CommandHandler("delete-vps", delete_vps_command))
    application.add_handler(CommandHandler("admin-add", admin_add_command))
    application.add_handler(CommandHandler("admin-remove", admin_remove_command))
    application.add_handler(CommandHandler("admin-list", admin_list_command))
    application.add_handler(CallbackQueryHandler(handle_callback))
    logger.info(f"{BOT_NAME} Telegram Bot is starting...")
    application.run_polling()

if __name__ == "__main__": main()
