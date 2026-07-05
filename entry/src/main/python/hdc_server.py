import json
import subprocess
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
import os
import argparse
import errno
import time
import threading
import socket
import sys
import re
import shlex
from concurrent.futures import ThreadPoolExecutor, as_completed

try:
    import harmony_agent
except Exception as ex:
    harmony_agent = None
    print(f">> [警告] 无法导入 harmony_agent workflow bridge 能力: {ex}")

try:
    from wechat_collect import service as wechat_collect_service
except Exception as ex:
    wechat_collect_service = None
    print(f">> [警告] 无法导入微信 UI dump 采集模块: {ex}")

NO_REASON_MODE = False
LEGACY_LOOP_ENABLED = True
AUTO_DISCOVERY_ENABLED = False
HDC_HEALTH_CACHE_TTL = float(os.environ.get("HDC_HEALTH_CACHE_TTL", "15"))
HDC_COMMAND_TIMEOUT = float(os.environ.get("HDC_COMMAND_TIMEOUT", "20"))
HDC_ACTION_TIMEOUT = float(os.environ.get("HDC_ACTION_TIMEOUT", "6"))
HDC_LIST_TARGETS_TIMEOUT = float(os.environ.get("HDC_LIST_TARGETS_TIMEOUT", "3"))
HDC_STALE_TARGET_GRACE = float(os.environ.get("HDC_STALE_TARGET_GRACE", "30"))
HDC_WORKFLOW_USE_DRIVER_ACTIONS = os.environ.get(
    "HDC_WORKFLOW_USE_DRIVER_ACTIONS", "0"
).strip().lower() in ("1", "true", "yes", "on")
HDC_WORKFLOW_USE_DRIVER_INPUT = os.environ.get(
    "HDC_WORKFLOW_USE_DRIVER_INPUT", "1"
).strip().lower() in ("1", "true", "yes", "on")
SERVER_PORT = 9124
APP_AGENT_PORT = 9126
APP_REVERSE_HDC_PORT = 19124
APP_REVERSE_HDC_URL = f"http://127.0.0.1:{APP_REVERSE_HDC_PORT}"
HDC_REVERSE_LISTEN_CHECK_TIMEOUT = 3.0
HDC_REVERSE_LISTEN_CHECK_INTERVAL = 0.3
HDC_TARGET_OVERRIDE = os.environ.get("HDC_TARGET", "").strip()
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", ".."))
AUTO_DISCOVERY_CACHE_FILE = os.environ.get(
    "HDC_AUTO_CACHE",
    os.path.join(REPO_ROOT, ".hdc-auto-cache", "targets.json")
)
AUTO_DISCOVERY_CONNECT_TIMEOUT = float(os.environ.get("HDC_AUTO_CONNECT_TIMEOUT", "0.25"))
AUTO_DISCOVERY_TCONN_TIMEOUT = float(os.environ.get("HDC_AUTO_TCONN_TIMEOUT", "6"))
AUTO_DISCOVERY_DISCOVER_TIMEOUT = float(os.environ.get("HDC_AUTO_DISCOVER_TIMEOUT", "5"))
AUTO_DISCOVERY_SCAN_BUDGET = float(os.environ.get("HDC_AUTO_SCAN_BUDGET", "12"))
AUTO_DISCOVERY_MAX_WORKERS = max(8, int(os.environ.get("HDC_AUTO_MAX_WORKERS", "128")))
AUTO_DISCOVERY_COOLDOWN = float(os.environ.get("HDC_AUTO_COOLDOWN", "30"))
AUTO_DISCOVERY_EXTRA_TARGETS = os.environ.get("HDC_AUTO_TARGETS", "")
AUTO_DISCOVERY_HISTORY_SCAN_LIMIT = max(1, int(os.environ.get("HDC_AUTO_HISTORY_SCAN_LIMIT", "5")))
AUTO_DISCOVERY_LOCAL_SUBNET_LIMIT = max(1, int(os.environ.get("HDC_AUTO_LOCAL_SUBNET_LIMIT", "4")))

def hdc_manual_config_message():
    return (
        "未检测到 HDC 设备连接。请先手动配置 HDC：USB 连接后执行 `hdc list targets` "
        "确认设备在线；无线调试请先执行 `hdc tconn <设备IP:端口>`；如果有多个设备或固定无线目标，"
        "请设置环境变量 `HDC_TARGET=<target>` 后重启服务。"
    )

def print_hdc_manual_config_hint():
    print(f">> [HDC] {hdc_manual_config_message()}")

def make_hdc_tunnel_status(status, message, target="", tunnel_ready=False, fport_ready=False,
                           rport_ready=False, rport_listening=None,
                           rport_listen_check_supported=False):
    return {
        "status": status,
        "message": message,
        "target": target,
        "tunnel_ready": tunnel_ready,
        "fport_ready": fport_ready,
        "rport_ready": rport_ready,
        "rport_listening": rport_listening,
        "rport_listen_check_supported": rport_listen_check_supported,
    }

_hdc_health_checked_at = 0.0
_hdc_health_last_ok_at = 0.0
_hdc_health_connected = False
_hdc_health_target = ""
_hdc_tunnel_checked_at = 0.0
_hdc_tunnel_status = make_hdc_tunnel_status("unknown", "HDC tunnel has not been checked")
_auto_discovery_last_attempt = 0.0
_auto_discovery_running = False
auto_discovery_lock = threading.RLock()

CLIENT_DISCONNECT_ERRNOS = {errno.EPIPE, errno.ECONNRESET, errno.ECONNABORTED}
CLIENT_DISCONNECT_WINERRORS = {10053, 10054, 10058}

def is_client_disconnect_error(exc):
    if isinstance(exc, (BrokenPipeError, ConnectionAbortedError, ConnectionResetError)):
        return True
    if isinstance(exc, OSError):
        err_no = getattr(exc, "errno", None)
        win_error = getattr(exc, "winerror", None)
        return err_no in CLIENT_DISCONNECT_ERRNOS or win_error in CLIENT_DISCONNECT_WINERRORS
    return False

def log_client_disconnect(handler, status_code):
    print(
        f">> [HTTP] client disconnected before {status_code} response: "
        f"{handler.command} {handler.path} from {handler.client_address}"
    )

# PC 侧 HTTP 控制服务：手机 App 通过 /api/run_cmd 触发 HDC 命令，
# workflow bridge 直接通过 /api/workflow 执行动作；9126 轮询 Agent 默认启动，
# 供 App 端本地/云端智能体按钮取任务使用，可用 --workflow_only 关闭。
class HDCServerHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/api/health':
            self.handle_health_request()
            return
        self.send_response(404)
        self.end_headers()
        self.wfile.write(b"Not Found")

    def do_POST(self):
        if self.path == '/api/workflow':
            self.handle_workflow_request()
        elif self.path == '/api/agent_loop/ensure':
            self.handle_agent_loop_ensure()
        elif self.path == '/api/hdc/connect':
            self.handle_hdc_connect()
        elif self.path == '/api/run_cmd':
            content_length = int(self.headers.get('Content-Length', 0))
            post_data = self.rfile.read(content_length)
            try:
                data = json.loads(post_data)
                cmd = data.get('cmd', '')
                if cmd:
                    print(f">> 正在执行远程指令: {cmd}")
                    # App 端只发送受控调试命令；这里保留 shell=True 以兼容 hdc/tconn 等复合命令。
                    result = run_remote_command(cmd)
                    
                    # 确保 9126 轮询 Agent 处于运行状态；workflow bridge 不依赖它。
                    if LEGACY_LOOP_ENABLED and is_hdc_connected(force=True):
                        ensure_hdc_tunnels(force=True, reset_reverse=True)
                        start_harmony_agent()

                    # 将 stdout 和 stderr 合并返回给手机 App，便于用户在 App 内直接诊断连接问题。
                    output = f"【标准输出】\n{result.stdout}\n【标准错误】\n{result.stderr}"
                    
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/plain; charset=utf-8')
                    self.send_header('Access-Control-Allow-Origin', '*')
                    self.end_headers()
                    self.wfile.write(output.encode('utf-8'))
                else:
                    self.send_response(400)
                    self.end_headers()
                    self.wfile.write(b"No cmd provided")
            except Exception as e:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(f"Error: {str(e)}".encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"Not Found")

    def write_json(self, status_code, payload):
        try:
            self.send_response(status_code)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps(payload, ensure_ascii=False).encode('utf-8'))
            return True
        except Exception as exc:
            if is_client_disconnect_error(exc):
                log_client_disconnect(self, status_code)
                return False
            raise

    def handle_workflow_request(self):
        content_length = int(self.headers.get('Content-Length', 0))
        post_data = self.rfile.read(content_length)
        try:
            request = json.loads(post_data or b'{}')
            action = request.get('action', '')
            payload = request.get('payload', {}) or {}
            result = handle_workflow_action(action, payload)
            self.write_json(200, result)
        except Exception as e:
            print(f">> [WorkflowBridge错误] {e}")
            self.write_json(500, {
                'status': 'error',
                'message': str(e)
            })

    def handle_health_request(self):
        try:
            result = hdc_health_payload(force=False)
            self.write_json(200, result)
        except Exception as e:
            print(f">> [HdcHealthError] {e}")
            self.write_json(500, {
                'status': 'error',
                'message': str(e),
                'hdc_connected': False,
                'tunnel_ready': False,
                'fport_ready': False,
                'rport_ready': False,
                'rport_listening': None,
                'rport_listen_check_supported': False,
                'app_server_url': APP_REVERSE_HDC_URL
            })

    def handle_hdc_connect(self):
        content_length = int(self.headers.get('Content-Length', 0))
        post_data = self.rfile.read(content_length)
        try:
            request = json.loads(post_data or b'{}')
            target = str(request.get('target', '')).strip()
            kill_others = bool(request.get('kill_others', True))
            prefer_wired = bool(request.get('prefer_wired', True))
            result = connect_hdc_target(target, kill_others=kill_others, prefer_wired=prefer_wired)
            status_code = 200 if result.get('status') == 'ok' else 500
            self.write_json(status_code, result)
        except Exception as e:
            print(f">> [HdcConnectError] {e}")
            self.write_json(500, {
                'status': 'error',
                'message': str(e),
                'hdc_connected': False,
                'tunnel_ready': False,
                'fport_ready': False,
                'rport_ready': False,
                'rport_listening': None,
                'rport_listen_check_supported': False,
                'app_server_url': APP_REVERSE_HDC_URL
            })

    def handle_agent_loop_ensure(self):
        try:
            result = ensure_agent_loop_ready()
            status_code = 200 if result.get('status') == 'ok' else 500
            self.write_json(status_code, result)
        except Exception as e:
            print(f">> [AgentLoopEnsure错误] {e}")
            self.write_json(500, {
                'status': 'error',
                'message': str(e)
            })

agent_thread = None
agent_stop_event = threading.Event()
hdc_control_lock = threading.RLock()

def run_process(args, check=False, timeout=HDC_COMMAND_TIMEOUT):
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as ex:
        stderr = f"command timed out after {timeout}s: {' '.join(args)}"
        result = subprocess.CompletedProcess(args, 124, ex.stdout or "", stderr)
    if check and result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip() or f"command failed: {' '.join(args)}"
        raise RuntimeError(message)
    return result

def hdc_args(target=""):
    args = ["hdc"]
    if target:
        args.extend(["-t", target])
    return args

def is_wireless_hdc_target(target):
    return ":" in target

def parse_hdc_targets(output):
    targets = []
    for line in output.splitlines():
        text = line.strip()
        if not text or "[Empty]" in text:
            continue
        lower = text.lower()
        if "not found" in lower or "list targets" in lower:
            continue
        target = text.split()[0].strip()
        if target and target not in targets:
            targets.append(target)
    return targets

def list_hdc_targets():
    result = run_process(["hdc", "list", "targets"], timeout=HDC_LIST_TARGETS_TIMEOUT)
    if result.returncode != 0:
        return [], result.stderr.strip() or result.stdout.strip()
    return parse_hdc_targets(result.stdout), ""

def choose_hdc_target(targets, preferred_target=""):
    if not targets:
        return ""
    if HDC_TARGET_OVERRIDE:
        if HDC_TARGET_OVERRIDE in targets:
            return HDC_TARGET_OVERRIDE
        print(f">> [HDC] HDC_TARGET is set but not connected: {HDC_TARGET_OVERRIDE}")
        return ""
    wired_targets = [target for target in targets if not is_wireless_hdc_target(target)]
    if wired_targets:
        return wired_targets[0]
    if preferred_target and preferred_target in targets:
        return preferred_target
    wireless_targets = [target for target in targets if is_wireless_hdc_target(target)]
    if wireless_targets:
        return wireless_targets[0]
    return targets[0]

def set_harmony_agent_target(target, mark_ok=True):
    global _hdc_health_target
    _hdc_health_target = target.strip() if isinstance(target, str) else ""
    if harmony_agent is not None:
        if hasattr(harmony_agent, "set_hdc_target"):
            try:
                checked_at = time.monotonic() if _hdc_health_target else 0.0
                harmony_agent.set_hdc_target(
                    _hdc_health_target,
                    checked_at=checked_at,
                    mark_ok=bool(_hdc_health_target and mark_ok)
                )
            except TypeError:
                harmony_agent.set_hdc_target(_hdc_health_target)
        else:
            harmony_agent.HDC_TARGET = _hdc_health_target

def parse_wireless_target(target):
    text = str(target or "").strip()
    if not is_wireless_hdc_target(text):
        return None
    host, port_text = text.rsplit(":", 1)
    host = host.strip()
    port_text = port_text.strip()
    if not port_text.isdigit():
        return None
    parts = host.split(".")
    if len(parts) != 4:
        return None
    octets = []
    for part in parts:
        if not part.isdigit():
            return None
        value = int(part)
        if value < 0 or value > 255:
            return None
        octets.append(value)
    port = int(port_text)
    if port <= 0 or port > 65535:
        return None
    return {
        "target": f"{host}:{port}",
        "host": host,
        "port": port,
        "octets": octets,
        "prefix2": f"{octets[0]}.{octets[1]}",
        "prefix3": f"{octets[0]}.{octets[1]}.{octets[2]}",
        "third_octet": octets[2],
        "host_octet": octets[3],
    }

def load_auto_discovery_cache():
    try:
        with open(AUTO_DISCOVERY_CACHE_FILE, "r", encoding="utf-8") as file:
            data = json.load(file)
        if isinstance(data, dict):
            targets = data.get("targets")
            if not isinstance(targets, list):
                data["targets"] = []
            return data
    except FileNotFoundError:
        pass
    except Exception as ex:
        print(f">> [HDC Auto] 读取缓存失败，将忽略缓存: {ex}")
    return {"version": 1, "last_target": "", "targets": []}

def save_auto_discovery_cache(cache):
    try:
        cache_dir = os.path.dirname(AUTO_DISCOVERY_CACHE_FILE)
        if cache_dir:
            os.makedirs(cache_dir, exist_ok=True)
        with open(AUTO_DISCOVERY_CACHE_FILE, "w", encoding="utf-8") as file:
            json.dump(cache, file, ensure_ascii=False, indent=2)
    except Exception as ex:
        print(f">> [HDC Auto] 写入缓存失败: {ex}")

def cache_wireless_hdc_target(target, source=""):
    parsed = parse_wireless_target(target)
    if not parsed:
        return
    cache = load_auto_discovery_cache()
    now = time.time()
    entry = {
        "target": parsed["target"],
        "host": parsed["host"],
        "port": parsed["port"],
        "prefix2": parsed["prefix2"],
        "prefix3": parsed["prefix3"],
        "third_octet": parsed["third_octet"],
        "host_octet": parsed["host_octet"],
        "last_success_at": now,
        "source": source or "hdc",
    }
    targets = cache.get("targets", [])
    if not isinstance(targets, list):
        targets = []
    deduped = [item for item in targets if isinstance(item, dict) and item.get("target") != parsed["target"]]
    deduped.insert(0, entry)
    cache["version"] = 1
    cache["last_target"] = parsed["target"]
    cache["targets"] = deduped[:20]
    save_auto_discovery_cache(cache)

def add_unique_value(values, value):
    if value and value not in values:
        values.append(value)

def default_endpoint_config_path():
    return os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "ets", "config", "DefaultEndpointConfig.ets"))

def read_default_wireless_targets():
    config_path = default_endpoint_config_path()
    try:
        with open(config_path, "r", encoding="utf-8") as file:
            text = file.read()
    except Exception:
        return []
    targets = []
    blocks = []
    single = re.search(r"wirelessHdcTarget\s*:\s*['\"]([^'\"]+)['\"]", text)
    if single:
        blocks.append(single.group(1))
    array = re.search(r"wirelessHdcTargets\s*:\s*\[(.*?)\]", text, flags=re.DOTALL)
    if array:
        blocks.append(array.group(1))
    for block in blocks:
        for match in re.findall(r"\b\d{1,3}(?:\.\d{1,3}){3}:\d{1,5}\b", block):
            parsed = parse_wireless_target(match)
            if parsed:
                add_unique_value(targets, parsed["target"])
    return targets

def split_csv_values(raw):
    values = []
    for part in str(raw or "").replace(";", ",").split(","):
        value = part.strip()
        if value:
            values.append(value)
    return values

def seed_entry_from_target(target, source):
    parsed = parse_wireless_target(target)
    if not parsed:
        return None
    return {
        "target": parsed["target"],
        "host": parsed["host"],
        "port": parsed["port"],
        "prefix2": parsed["prefix2"],
        "prefix3": parsed["prefix3"],
        "third_octet": parsed["third_octet"],
        "host_octet": parsed["host_octet"],
        "source": source,
    }

def build_auto_discovery_seeds():
    seeds = []
    seen_targets = set()

    def add_seed(target, source):
        entry = seed_entry_from_target(target, source)
        if not entry or entry["target"] in seen_targets:
            return
        seen_targets.add(entry["target"])
        seeds.append(entry)

    cache = load_auto_discovery_cache()
    last_target = cache.get("last_target", "")
    add_seed(last_target, "cache-last")
    # Keep the cache list for diagnostics, but do not try older successful IPs directly.

    if HDC_TARGET_OVERRIDE:
        add_seed(HDC_TARGET_OVERRIDE, "HDC_TARGET")

    for target in split_csv_values(AUTO_DISCOVERY_EXTRA_TARGETS):
        add_seed(target, "HDC_AUTO_TARGETS")

    for target in read_default_wireless_targets():
        add_seed(target, "default-config")
    return seeds

def recent_history_scan_seeds(limit=AUTO_DISCOVERY_HISTORY_SCAN_LIMIT):
    cache = load_auto_discovery_cache()
    seeds = []
    seen_targets = set()

    def add_history_seed(target, source):
        if len(seeds) >= limit:
            return
        entry = seed_entry_from_target(target, source)
        if not entry or entry["target"] in seen_targets:
            return
        seen_targets.add(entry["target"])
        seeds.append(entry)

    add_history_seed(cache.get("last_target", ""), "cache-last")
    targets = cache.get("targets", [])
    if not isinstance(targets, list):
        return seeds
    for item in targets:
        if len(seeds) >= limit:
            break
        if not isinstance(item, dict):
            continue
        target = str(item.get("target", "")).strip()
        if not target and item.get("host") and item.get("port"):
            target = f"{item.get('host')}:{item.get('port')}"
        add_history_seed(target, "cache-history")
    return seeds

def get_local_ipv4_addresses():
    addresses = []

    def add_address(value):
        parsed = parse_wireless_target(f"{value}:1")
        if not parsed:
            return
        if value.startswith("127.") or value.startswith("169.254.") or value == "0.0.0.0":
            return
        add_unique_value(addresses, value)

    try:
        hostname = socket.gethostname()
        for info in socket.getaddrinfo(hostname, None, socket.AF_INET):
            add_address(info[4][0])
    except Exception:
        pass

    for probe_host in ("8.8.8.8", "1.1.1.1", "223.5.5.5"):
        sock = None
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.settimeout(0.2)
            sock.connect((probe_host, 80))
            add_address(sock.getsockname()[0])
        except Exception:
            pass
        finally:
            if sock:
                sock.close()
    private_addresses = [address for address in addresses if is_private_lan_ipv4(address)]
    return private_addresses or addresses

def get_pc_hdc_server_urls():
    urls = []
    for address in get_local_ipv4_addresses():
        add_unique_value(urls, f"http://{address}:{SERVER_PORT}")
    return urls

def is_private_lan_ipv4(address):
    parsed = parse_wireless_target(f"{address}:1")
    if not parsed:
        return False
    octets = parsed["octets"]
    if octets[0] == 10:
        return True
    if octets[0] == 192 and octets[1] == 168:
        return True
    return octets[0] == 172 and 16 <= octets[1] <= 31

def build_host_octet_order(prefix2, third_octet, seeds):
    order = []
    for seed in seeds:
        if seed.get("prefix2") == prefix2 and int(seed.get("third_octet", -1)) == third_octet:
            host_octet = int(seed.get("host_octet", -1))
            if 1 <= host_octet <= 254:
                add_unique_value(order, host_octet)
    for host_octet in range(1, 255):
        add_unique_value(order, host_octet)
    return order

def build_auto_discovery_scan_plans(history_seeds):
    plans = []
    seen = set()

    def add_plan(prefix2, third_octet, port, source):
        if not prefix2 or third_octet < 0 or third_octet > 255 or port <= 0 or port > 65535:
            return
        key = (prefix2, third_octet, port)
        if key in seen:
            return
        seen.add(key)
        plan_seeds = [
            seed for seed in history_seeds
            if seed.get("prefix2") == prefix2
            and int(seed.get("third_octet", -1)) == third_octet
            and int(seed.get("port", 0) or 0) == port
        ]
        plans.append({
            "prefix2": prefix2,
            "third_octet": third_octet,
            "prefix3": f"{prefix2}.{third_octet}",
            "port": port,
            "source": source,
            "seeds": plan_seeds,
        })

    if not history_seeds:
        return plans

    latest_port = int(history_seeds[0].get("port", 0) or 0)
    local_addresses = get_local_ipv4_addresses()[:AUTO_DISCOVERY_LOCAL_SUBNET_LIMIT]
    for address in local_addresses:
        parsed = parse_wireless_target(f"{address}:{latest_port}")
        if not parsed:
            continue
        add_plan(parsed["prefix2"], int(parsed["third_octet"]), latest_port, f"local-subnet:{address}")

    for seed in history_seeds[:AUTO_DISCOVERY_HISTORY_SCAN_LIMIT]:
        add_plan(
            str(seed.get("prefix2", "")),
            int(seed.get("third_octet", -1)),
            int(seed.get("port", 0) or 0),
            str(seed.get("source", "")) or "cache-history",
        )
    return plans

def tcp_port_open(host, port, timeout):
    sock = None
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        return sock.connect_ex((host, port)) == 0
    except Exception:
        return False
    finally:
        if sock:
            try:
                sock.close()
            except Exception:
                pass

def scan_subnet_for_hdc_port(prefix3, port, host_order, deadline):
    if time.monotonic() >= deadline:
        return []
    found = []
    if not host_order:
        return found
    max_workers = min(AUTO_DISCOVERY_MAX_WORKERS, len(host_order))
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        future_map = {}
        for host_octet in host_order:
            if time.monotonic() >= deadline:
                break
            host = f"{prefix3}.{host_octet}"
            future = executor.submit(tcp_port_open, host, port, AUTO_DISCOVERY_CONNECT_TIMEOUT)
            future_map[future] = host
        for future in as_completed(future_map):
            host = future_map[future]
            try:
                if future.result():
                    found.append(f"{host}:{port}")
            except Exception:
                pass
            if time.monotonic() >= deadline:
                break
    return found

def probe_hdc_device_info(target):
    info = {}
    probes = [
        ("manufacturer", ["shell", "param", "get", "const.product.manufacturer"]),
        ("brand", ["shell", "param", "get", "const.product.brand"]),
        ("model", ["shell", "param", "get", "const.product.model"]),
        ("device_type", ["shell", "param", "get", "const.build.characteristics"]),
    ]
    for key, suffix in probes:
        result = run_process(hdc_args(target) + suffix, timeout=4)
        if result.returncode == 0:
            value = (result.stdout or "").strip()
            if value:
                info[key] = value
    return info

def build_hdc_candidate(target, source, probe=True):
    candidate = {
        "target": target,
        "source": source,
    }
    parsed = parse_wireless_target(target)
    if parsed:
        candidate.update({
            "host": parsed["host"],
            "port": parsed["port"],
            "prefix2": parsed["prefix2"],
        })
    if probe:
        try:
            candidate.update(probe_hdc_device_info(target))
        except Exception:
            pass
    return candidate

def parse_wireless_targets_from_text(text, default_port=0):
    targets = []
    pattern = re.compile(r"\b((?:\d{1,3}\.){3}\d{1,3})(?::(\d{1,5}))?\b")
    for match in pattern.finditer(str(text or "")):
        host = match.group(1)
        port_text = match.group(2)
        if not port_text and default_port:
            port_text = str(default_port)
        if not port_text:
            continue
        parsed = parse_wireless_target(f"{host}:{port_text}")
        if parsed:
            add_unique_value(targets, parsed["target"])
    return targets

def discover_hdc_candidates_from_hdc():
    result = run_process(["hdc", "discover"], timeout=AUTO_DISCOVERY_DISCOVER_TIMEOUT)
    output = "\n".join([result.stdout or "", result.stderr or ""])
    targets = parse_wireless_targets_from_text(output)
    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip() or "hdc discover failed"
        print(f">> [HDC Auto] hdc discover failed: {message}")
    elif targets:
        print(f">> [HDC Auto] hdc discover found: {', '.join(targets)}")
    else:
        brief = " ".join(line.strip() for line in output.splitlines() if line.strip())
        if brief:
            print(f">> [HDC Auto] hdc discover found no target: {brief}")
    return [build_hdc_candidate(target, "hdc-discover", probe=False) for target in targets]

def try_hdc_tconn_target(target, source, precheck=False):
    parsed = parse_wireless_target(target)
    if not parsed:
        return None
    if precheck and not tcp_port_open(parsed["host"], parsed["port"], AUTO_DISCOVERY_CONNECT_TIMEOUT):
        print(f">> [HDC Auto] 跳过未开放端口的历史目标: {parsed['target']} ({source})")
        return None
    print(f">> [HDC Auto] 尝试连接候选设备: {parsed['target']} ({source})")
    result = run_process(["hdc", "tconn", parsed["target"]], timeout=AUTO_DISCOVERY_TCONN_TIMEOUT)
    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip() or "hdc tconn failed"
        print(f">> [HDC Auto] tconn 失败: {parsed['target']} - {message}")
        return None
    targets, _ = list_hdc_targets()
    if parsed["target"] not in targets:
        print(f">> [HDC Auto] tconn 返回成功但目标未出现在 hdc list targets: {parsed['target']}")
        return None
    cache_wireless_hdc_target(parsed["target"], source=source)
    return build_hdc_candidate(parsed["target"], source)

def unique_candidates(candidates):
    result = []
    seen = set()
    for candidate in candidates:
        target = str(candidate.get("target", ""))
        if not target or target in seen:
            continue
        seen.add(target)
        result.append(candidate)
    return result

def print_hdc_candidates(candidates, title):
    print(title)
    for idx, candidate in enumerate(candidates, start=1):
        details = []
        for key in ("manufacturer", "brand", "model", "device_type", "source"):
            value = str(candidate.get(key, "")).strip()
            if value:
                details.append(f"{key}={value}")
        suffix = " | " + ", ".join(details) if details else ""
        print(f"  [{idx}] {candidate.get('target', '')}{suffix}")

def select_hdc_candidate(candidates, prompt_user):
    candidates = unique_candidates(candidates)
    if not candidates:
        return ""
    if len(candidates) == 1:
        return str(candidates[0].get("target", ""))

    print_hdc_candidates(candidates, ">> [HDC Auto] 发现多个 HDC 目标，请选择要控制的手机:")
    if not prompt_user or not sys.stdin or not sys.stdin.isatty():
        print(">> [HDC Auto] 当前不是交互式终端，无法自动选择。请设置 HDC_TARGET 或只保留一个设备后重试。")
        return ""

    while True:
        try:
            raw = input("请选择设备序号（直接回车取消自动连接）: ").strip()
        except (EOFError, KeyboardInterrupt):
            print("")
            return ""
        if raw == "":
            return ""
        if raw.isdigit():
            index = int(raw)
            if 1 <= index <= len(candidates):
                return str(candidates[index - 1].get("target", ""))
        for candidate in candidates:
            target = str(candidate.get("target", ""))
            if raw == target:
                return target
        print("输入无效，请输入列表中的序号或完整 target。")

def mark_active_hdc_target(target, source=""):
    global _hdc_health_checked_at, _hdc_health_last_ok_at, _hdc_health_connected
    if not target:
        return ""
    set_harmony_agent_target(target)
    checked_at = time.monotonic()
    _hdc_health_checked_at = checked_at
    _hdc_health_last_ok_at = checked_at
    _hdc_health_connected = True
    if is_wireless_hdc_target(target) and source != "hdc-list":
        cache_wireless_hdc_target(target, source=source)
    return target

def candidate_source_for_target(candidates, target):
    for candidate in candidates:
        if str(candidate.get("target", "")) == target:
            return str(candidate.get("source", "")) or "auto-discovery"
    return "auto-discovery"

def discover_hdc_candidates():
    seeds = build_auto_discovery_seeds()
    candidates = []

    if seeds:
        print(
            ">> [HDC Auto] 尝试历史/配置中的无线 HDC 目标: " +
            ", ".join(seed["target"] for seed in seeds)
        )
    for seed in seeds:
        parsed = parse_wireless_target(seed.get("target", ""))
        if not parsed:
            continue
        source = str(seed.get("source", "")) or "cache"
        trusted = source in ("cache-last", "cache", "HDC_TARGET", "HDC_AUTO_TARGETS")
        candidate = try_hdc_tconn_target(parsed["target"], source, precheck=not trusted)
        if candidate:
            return [candidate]
    candidates = unique_candidates(candidates)
    if candidates:
        return candidates

    hdc_discovered = discover_hdc_candidates_from_hdc()
    for candidate in hdc_discovered:
        target = str(candidate.get("target", ""))
        source = str(candidate.get("source", "")) or "hdc-discover"
        connected_candidate = try_hdc_tconn_target(target, source, precheck=False)
        if connected_candidate:
            return [connected_candidate]
    candidates = unique_candidates(candidates)
    if candidates:
        return candidates

    history_scan_seeds = recent_history_scan_seeds()
    if not history_scan_seeds:
        print(">> [HDC Auto] No recent history target is available for bounded LAN scan.")
        return []

    scan_plans = build_auto_discovery_scan_plans(history_scan_seeds)
    if not scan_plans:
        print(">> [HDC Auto] No valid subnet is available for bounded LAN scan.")
        return []

    deadline = time.monotonic() + AUTO_DISCOVERY_SCAN_BUDGET
    print(
        f">> [HDC Auto] LAN scan will check {len(scan_plans)} subnet plan(s), "
        f"history_limit={AUTO_DISCOVERY_HISTORY_SCAN_LIMIT}, budget={AUTO_DISCOVERY_SCAN_BUDGET}s"
    )
    for index, plan in enumerate(scan_plans, start=1):
        if time.monotonic() >= deadline:
            print(">> [HDC Auto] LAN scan budget exhausted.")
            return unique_candidates(candidates)
        prefix2 = str(plan.get("prefix2", ""))
        third = int(plan.get("third_octet", -1))
        prefix3 = str(plan.get("prefix3", "")) or f"{prefix2}.{third}"
        port = int(plan.get("port", 0) or 0)
        source = str(plan.get("source", "")) or "lan-scan"
        plan_seeds = plan.get("seeds", [])
        if not isinstance(plan_seeds, list):
            plan_seeds = []
        host_order = build_host_octet_order(prefix2, third, plan_seeds)
        print(
            f">> [HDC Auto] LAN scan starts: subnet={prefix3}.0/24, port={port}, "
            f"source={source}, plan={index}/{len(scan_plans)}, "
            f"timeout={AUTO_DISCOVERY_CONNECT_TIMEOUT}s, budget={AUTO_DISCOVERY_SCAN_BUDGET}s"
        )
        open_targets = scan_subnet_for_hdc_port(prefix3, port, host_order, deadline)
        if time.monotonic() >= deadline:
            print(">> [HDC Auto] LAN scan budget exhausted.")
            return unique_candidates(candidates)
        if open_targets:
            print(f">> [HDC Auto] {prefix3}.0/24 has {len(open_targets)} open tcp:{port} candidate(s).")
        for target in open_targets:
            candidate = try_hdc_tconn_target(target, f"lan-scan:{source}", precheck=False)
            if candidate:
                return [candidate]
    return unique_candidates(candidates)

def ensure_auto_hdc_connected(force=False, prompt_user=False, reason=""):
    global _auto_discovery_last_attempt, _auto_discovery_running
    if not AUTO_DISCOVERY_ENABLED:
        return {"status": "disabled", "message": "HDC auto discovery is disabled"}

    with auto_discovery_lock:
        now = time.monotonic()
        if _auto_discovery_running:
            return {"status": "running", "message": "HDC auto discovery is already running"}
        if not force and _auto_discovery_last_attempt > 0 and now - _auto_discovery_last_attempt < AUTO_DISCOVERY_COOLDOWN:
            return {"status": "skipped", "message": "HDC auto discovery cooldown is active"}
        _auto_discovery_running = True
        _auto_discovery_last_attempt = now

    try:
        if reason:
            print(f">> [HDC Auto] {reason}")
        targets, error = list_hdc_targets()
        if error:
            print(f">> [HDC Auto] hdc list targets failed before discovery: {error}")
        if HDC_TARGET_OVERRIDE:
            existing_candidates = [build_hdc_candidate(target, "already-connected", probe=False) for target in targets]
            if HDC_TARGET_OVERRIDE in targets:
                mark_active_hdc_target(HDC_TARGET_OVERRIDE, source="HDC_TARGET")
                return {
                    "status": "ok",
                    "message": "Using HDC_TARGET override",
                    "target": HDC_TARGET_OVERRIDE,
                    "candidates": existing_candidates,
                }

            print(f">> [HDC Auto] HDC_TARGET is set but not connected: {HDC_TARGET_OVERRIDE}")
            connected_candidate = try_hdc_tconn_target(HDC_TARGET_OVERRIDE, "HDC_TARGET", precheck=False)
            if connected_candidate:
                mark_active_hdc_target(HDC_TARGET_OVERRIDE, source="HDC_TARGET")
                candidates = unique_candidates([connected_candidate] + existing_candidates)
                return {
                    "status": "ok",
                    "message": "Connected HDC_TARGET override",
                    "target": HDC_TARGET_OVERRIDE,
                    "candidates": candidates,
                }

            return {
                "status": "error",
                "message": f"HDC_TARGET is set but target is not connected: {HDC_TARGET_OVERRIDE}",
                "target": HDC_TARGET_OVERRIDE,
                "candidates": existing_candidates,
            }
        if targets:
            candidates = [build_hdc_candidate(target, "already-connected") for target in targets]
            selected = select_hdc_candidate(candidates, prompt_user=prompt_user)
            if selected:
                mark_active_hdc_target(selected, source="already-connected")
                if is_wireless_hdc_target(selected) and not HDC_TARGET_OVERRIDE:
                    cleanup_other_wireless_targets(selected)
                return {
                    "status": "ok",
                    "message": "Using existing HDC target",
                    "target": selected,
                    "candidates": candidates,
                }
            return {
                "status": "multiple",
                "message": "Multiple HDC targets are connected; selection is required",
                "candidates": candidates,
            }

        candidates = discover_hdc_candidates()
        selected = select_hdc_candidate(candidates, prompt_user=prompt_user)
        if selected:
            source = candidate_source_for_target(candidates, selected)
            connected_targets, _ = list_hdc_targets()
            if selected in connected_targets:
                connected_candidate = build_hdc_candidate(selected, source)
            else:
                connected_candidate = try_hdc_tconn_target(selected, source, precheck=False)
            if not connected_candidate:
                return {
                    "status": "error",
                    "message": f"Selected HDC target could not be connected: {selected}",
                    "target": selected,
                    "candidates": candidates,
                }
            mark_active_hdc_target(selected, source=source)
            if not HDC_TARGET_OVERRIDE:
                cleanup_other_wireless_targets(selected)
            return {
                "status": "ok",
                "message": "HDC target auto-discovered",
                "target": selected,
                "candidates": candidates,
            }
        if candidates:
            return {
                "status": "multiple",
                "message": "Multiple HDC targets discovered; selection is required",
                "candidates": candidates,
            }
        return {
            "status": "error",
            "message": "No HDC target discovered from HDC discover, cache, or bounded LAN scan",
            "candidates": [],
        }
    finally:
        with auto_discovery_lock:
            _auto_discovery_running = False

def run_with_hdc_control(operation_name, operation):
    if harmony_agent is not None and hasattr(harmony_agent, 'run_with_device_control'):
        return harmony_agent.run_with_device_control(operation_name, operation)
    with hdc_control_lock:
        return operation()

def keep_cached_hdc_target_after_probe_error(error, now):
    global _hdc_health_checked_at, _hdc_health_connected, _hdc_tunnel_checked_at, _hdc_tunnel_status
    if not error or not _hdc_health_target or _hdc_health_last_ok_at <= 0:
        return ""
    age = now - _hdc_health_last_ok_at
    if age > HDC_STALE_TARGET_GRACE:
        return ""
    _hdc_health_checked_at = now
    _hdc_health_connected = True
    set_harmony_agent_target(_hdc_health_target, mark_ok=False)
    remaining = max(0.0, HDC_STALE_TARGET_GRACE - age)
    print(
        f">> [HDC] list targets failed; keeping cached target "
        f"{_hdc_health_target} for {remaining:.1f}s: {error}"
    )
    _hdc_tunnel_status = make_hdc_tunnel_status(
        "warning",
        "HDC probe failed; using cached target without refreshing tunnels",
        target=_hdc_health_target
    )
    _hdc_tunnel_checked_at = now
    return _hdc_health_target

def get_active_hdc_target(force=False):
    global _hdc_health_checked_at, _hdc_health_connected, _hdc_health_target
    now = time.monotonic()
    if (not force and _hdc_health_checked_at > 0 and
            now - _hdc_health_checked_at < HDC_HEALTH_CACHE_TTL):
        return _hdc_health_target if _hdc_health_connected else ""

    targets, error = list_hdc_targets()
    if not targets:
        stale_target = keep_cached_hdc_target_after_probe_error(error, now)
        if stale_target:
            return stale_target
        if AUTO_DISCOVERY_ENABLED:
            auto_result = ensure_auto_hdc_connected(force=force, prompt_user=False,
                                                    reason="No connected HDC target; trying cached LAN discovery.")
            auto_target = str(auto_result.get("target", ""))
            if auto_result.get("status") == "ok" and auto_target:
                return auto_target
        _hdc_health_checked_at = now
        _hdc_health_connected = False
        set_harmony_agent_target("")
        if error:
            print(f">> [HDC] list targets failed: {error}")
        return ""

    target = choose_hdc_target(targets, _hdc_health_target)
    if not target:
        _hdc_health_checked_at = now
        _hdc_health_connected = False
        set_harmony_agent_target("")
        return ""
    return mark_active_hdc_target(target, source="hdc-list")

def reset_hdc_tunnel_cache():
    global _hdc_tunnel_checked_at, _hdc_tunnel_status
    _hdc_tunnel_checked_at = 0.0
    _hdc_tunnel_status = make_hdc_tunnel_status("unknown", "HDC tunnel has not been checked")

def hdc_port_error_is_existing_mapping(message):
    lower = message.lower()
    return "exist" in lower or "already" in lower or "duplicate" in lower or "存在" in message

def device_tcp_port_listen_status(target, port):
    commands = [
        f"netstat -an | grep {port}",
        f"toybox netstat -an | grep {port}",
    ]
    unsupported_markers = (
        "inaccessible or not found",
        "unknown command",
        "not found",
        "not recognized",
    )
    saw_supported_command = False
    for command in commands:
        result = run_process(hdc_args(target) + ["shell", command], timeout=5)
        text = ((result.stdout or "") + "\n" + (result.stderr or "")).strip()
        lower = text.lower()
        if any(marker in lower for marker in unsupported_markers):
            continue
        saw_supported_command = True
        if f":{port}" in text and "LISTEN" in text.upper():
            return True
    return False if saw_supported_command else None

def wait_for_device_tcp_port(target, port):
    deadline = time.monotonic() + HDC_REVERSE_LISTEN_CHECK_TIMEOUT
    last_status = None
    while time.monotonic() <= deadline:
        status = device_tcp_port_listen_status(target, port)
        if status is True:
            return True
        if status is False:
            last_status = False
        time.sleep(HDC_REVERSE_LISTEN_CHECK_INTERVAL)
    return last_status

def ensure_hdc_tunnels(force=False, reset_reverse=False):
    return run_with_hdc_control(
        "ensure_hdc_tunnels",
        lambda: _ensure_hdc_tunnels_impl(force=force, reset_reverse=reset_reverse)
    )

def run_hdc_tunnel_commands(target, reset_reverse=False):
    fport_errors = []
    rport_errors = []
    commands = [
        (hdc_args(target) + ["fport", "rm", f"tcp:{APP_AGENT_PORT}", f"tcp:{APP_AGENT_PORT}"], False),
        (hdc_args(target) + ["fport", f"tcp:{APP_AGENT_PORT}", f"tcp:{APP_AGENT_PORT}"], True),
    ]
    if reset_reverse:
        commands.append((hdc_args(target) + ["rport", "rm", f"tcp:{APP_REVERSE_HDC_PORT}", f"tcp:{SERVER_PORT}"], False))
    commands.append((hdc_args(target) + ["rport", f"tcp:{APP_REVERSE_HDC_PORT}", f"tcp:{SERVER_PORT}"], True))
    for args, required in commands:
        result = run_process(args)
        if required and result.returncode != 0:
            message = result.stderr.strip() or result.stdout.strip() or " ".join(args)
            if hdc_port_error_is_existing_mapping(message):
                continue
            if "rport" in args:
                rport_errors.append(message)
            else:
                fport_errors.append(message)

    rport_listening = None
    rport_listen_check_supported = False
    if not rport_errors:
        listen_status = wait_for_device_tcp_port(target, APP_REVERSE_HDC_PORT)
        rport_listening = listen_status
        rport_listen_check_supported = listen_status is not None
        if listen_status is False:
            run_process(
                hdc_args(target) + ["rport", "rm", f"tcp:{APP_REVERSE_HDC_PORT}", f"tcp:{SERVER_PORT}"],
                timeout=5
            )
            retry = run_process(
                hdc_args(target) + ["rport", f"tcp:{APP_REVERSE_HDC_PORT}", f"tcp:{SERVER_PORT}"],
                timeout=5
            )
            if retry.returncode != 0:
                retry_message = retry.stderr.strip() or retry.stdout.strip() or "HDC rport retry failed"
                if not hdc_port_error_is_existing_mapping(retry_message):
                    rport_errors.append(retry_message)
            retry_listen_status = wait_for_device_tcp_port(target, APP_REVERSE_HDC_PORT)
            rport_listening = retry_listen_status
            rport_listen_check_supported = retry_listen_status is not None
            if retry_listen_status is False:
                rport_errors.append(
                    f"HDC rport tcp:{APP_REVERSE_HDC_PORT}->tcp:{SERVER_PORT} was created, "
                    "but the device-side port is not listening"
                )

    errors = fport_errors + rport_errors
    fport_ready = len(fport_errors) == 0
    rport_ready = len(rport_errors) == 0 and rport_listening is not False
    if errors:
        return make_hdc_tunnel_status(
            "error", "; ".join(errors), target=target,
            tunnel_ready=fport_ready and rport_ready,
            fport_ready=fport_ready, rport_ready=rport_ready,
            rport_listening=rport_listening,
            rport_listen_check_supported=rport_listen_check_supported
        )
    if rport_listening is True:
        rport_message = f"device tcp:{APP_REVERSE_HDC_PORT} is listening"
    elif rport_listening is None:
        rport_message = "device reverse port listen check is unavailable"
    else:
        rport_message = f"device tcp:{APP_REVERSE_HDC_PORT} is not listening"
    return make_hdc_tunnel_status(
        "ok",
        (
            f"HDC tunnel ready: fport tcp:{APP_AGENT_PORT}->tcp:{APP_AGENT_PORT}, "
            f"rport tcp:{APP_REVERSE_HDC_PORT}->tcp:{SERVER_PORT}; {rport_message}"
        ),
        target=target,
        tunnel_ready=fport_ready and rport_ready,
        fport_ready=fport_ready,
        rport_ready=rport_ready,
        rport_listening=rport_listening,
        rport_listen_check_supported=rport_listen_check_supported
    )

def choose_fallback_hdc_target(failed_target):
    targets, _ = list_hdc_targets()
    candidates = [target for target in targets if target != failed_target]
    return choose_hdc_target(candidates)

def store_hdc_tunnel_status(status):
    global _hdc_tunnel_checked_at, _hdc_tunnel_status
    _hdc_tunnel_checked_at = time.monotonic()
    _hdc_tunnel_status = status
    return dict(_hdc_tunnel_status)

def refresh_hdc_tunnels_for_target(target, reset_reverse=False, allow_fallback=True):
    return run_with_hdc_control(
        "refresh_hdc_tunnels_for_target",
        lambda: _refresh_hdc_tunnels_for_target_impl(target, reset_reverse, allow_fallback)
    )

def _refresh_hdc_tunnels_for_target_impl(target, reset_reverse=False, allow_fallback=True):
    if not target:
        return store_hdc_tunnel_status(
            make_hdc_tunnel_status("error", "HDC target is not connected")
        )

    set_harmony_agent_target(target)
    status = run_hdc_tunnel_commands(target, reset_reverse=reset_reverse)
    if allow_fallback and not status.get("fport_ready"):
        fallback = choose_fallback_hdc_target(target)
        if fallback:
            print(f">> [HDC] target {target} fport failed; retry with {fallback}")
            set_harmony_agent_target(fallback)
            status = run_hdc_tunnel_commands(fallback, reset_reverse=True)
    return store_hdc_tunnel_status(status)

def _ensure_hdc_tunnels_impl(force=False, reset_reverse=False):
    global _hdc_tunnel_checked_at, _hdc_tunnel_status
    now = time.monotonic()
    if (not force and _hdc_tunnel_checked_at > 0 and
            now - _hdc_tunnel_checked_at < HDC_HEALTH_CACHE_TTL):
        return dict(_hdc_tunnel_status)

    target = get_active_hdc_target(force=force)
    if not target:
        return store_hdc_tunnel_status(
            make_hdc_tunnel_status("error", "HDC target is not connected")
        )

    return _refresh_hdc_tunnels_for_target_impl(target, reset_reverse=reset_reverse, allow_fallback=True)

def build_hdc_health_payload(target, tunnel):
    active_target = str(tunnel.get("target", "")) or target
    hdc_connected = bool(active_target)
    tunnel_ready = bool(tunnel.get("tunnel_ready"))
    fport_ready = bool(tunnel.get("fport_ready"))
    rport_ready = bool(tunnel.get("rport_ready"))
    rport_listening = tunnel.get("rport_listening")
    rport_listen_check_supported = bool(tunnel.get("rport_listen_check_supported"))
    pc_server_urls = get_pc_hdc_server_urls()
    app_server_urls = [APP_REVERSE_HDC_URL]
    for url in pc_server_urls:
        if url not in app_server_urls:
            app_server_urls.append(url)
    control_ready = hdc_connected and (fport_ready or rport_ready)
    return {
        "status": "ok" if control_ready else "error",
        "message": tunnel.get("message", ""),
        "hdc_connected": hdc_connected,
        "target": active_target,
        "tunnel_ready": tunnel_ready,
        "fport_ready": fport_ready,
        "rport_ready": rport_ready,
        "rport_listening": rport_listening,
        "rport_listen_check_supported": rport_listen_check_supported,
        "app_server_url": APP_REVERSE_HDC_URL,
        "app_server_urls": app_server_urls,
        "pc_server_urls": pc_server_urls,
        "server_port": SERVER_PORT,
        "agent_router_port": APP_AGENT_PORT,
        "reverse_server_port": APP_REVERSE_HDC_PORT,
        "loop_enabled": LEGACY_LOOP_ENABLED,
        "loop_alive": agent_thread is not None and agent_thread.is_alive(),
    }

def cached_hdc_tunnel_for_target(target):
    if _hdc_tunnel_checked_at <= 0:
        return None
    cached_target = str(_hdc_tunnel_status.get("target", ""))
    if not cached_target or cached_target != target:
        return None
    return dict(_hdc_tunnel_status)

def hdc_health_payload(force=False, repair=False):
    target = get_active_hdc_target(force=force)
    if not target:
        tunnel = make_hdc_tunnel_status("error", "HDC target is not connected")
        return build_hdc_health_payload(target, tunnel)

    tunnel = None if repair else cached_hdc_tunnel_for_target(target)
    if tunnel is None:
        tunnel = ensure_hdc_tunnels(force=repair)
    return build_hdc_health_payload(target, tunnel)

def health_payload_after_target_selected(selected_target, message_prefix="", requested_target=""):
    if is_wireless_hdc_target(selected_target):
        cache_wireless_hdc_target(selected_target, source="selected")
    tunnel = refresh_hdc_tunnels_for_target(selected_target, reset_reverse=True, allow_fallback=True)
    tunnel_target = str(tunnel.get("target", ""))
    if is_wireless_hdc_target(tunnel_target):
        cache_wireless_hdc_target(tunnel_target, source="tunnel")
    if LEGACY_LOOP_ENABLED and tunnel.get("fport_ready"):
        start_harmony_agent()
    payload = build_hdc_health_payload(str(tunnel.get("target", "")) or selected_target, tunnel)
    if payload.get("hdc_connected") and payload.get("fport_ready"):
        payload["status"] = "ok"
        if not payload.get("tunnel_ready"):
            payload["message"] = (
                "HDC target connected and fport ready; reverse rport is unavailable, "
                "so keep using the manual PC HDC Server URL."
            )
    if message_prefix:
        payload["message"] = message_prefix + " " + str(payload.get("message", "")).strip()
    if requested_target:
        payload["requested_target"] = requested_target
    return payload

def first_wired_target(targets):
    wired_targets = [target for target in targets if not is_wireless_hdc_target(target)]
    return wired_targets[0] if wired_targets else ""

def cleanup_other_wireless_targets(active_target):
    targets, _ = list_hdc_targets()
    for old_target in targets:
        if old_target != active_target and is_wireless_hdc_target(old_target):
            run_process(["hdc", "kill", old_target])

def connect_hdc_target(target, kill_others=True, prefer_wired=True):
    if not target:
        if AUTO_DISCOVERY_ENABLED:
            auto_result = ensure_auto_hdc_connected(force=True, prompt_user=True,
                                                    reason="/api/hdc/connect target is empty; trying auto discovery.")
            selected = str(auto_result.get("target", ""))
            if selected:
                return health_payload_after_target_selected(selected, requested_target="auto")
            return {
                "status": "error",
                "message": auto_result.get("message", "auto discovery failed"),
                "hdc_connected": False,
                "target": "",
                "candidates": auto_result.get("candidates", []),
                "tunnel_ready": False,
                "fport_ready": False,
                "rport_ready": False,
                "rport_listening": None,
                "rport_listen_check_supported": False,
                "app_server_url": APP_REVERSE_HDC_URL,
            }
        return {
            "status": "error",
            "message": "target is required, for example 192.168.x.x:port",
            "hdc_connected": False,
            "tunnel_ready": False,
            "fport_ready": False,
            "rport_ready": False,
            "rport_listening": None,
            "rport_listen_check_supported": False,
            "app_server_url": APP_REVERSE_HDC_URL,
        }

    targets, _ = list_hdc_targets()
    wired_target = first_wired_target(targets)
    if prefer_wired and wired_target and not HDC_TARGET_OVERRIDE:
        invalidate_hdc_health_cache()
        set_harmony_agent_target(wired_target)
        reset_hdc_tunnel_cache()
        return health_payload_after_target_selected(
            wired_target,
            "Using wired HDC target; wireless tconn skipped.",
            requested_target=target
        )

    if target in targets:
        result = subprocess.CompletedProcess(["hdc", "tconn", target], 0, "", "")
    else:
        result = run_process(["hdc", "tconn", target])
    invalidate_hdc_health_cache()
    reset_hdc_tunnel_cache()
    if result.returncode != 0:
        fallback = choose_hdc_target(targets)
        if fallback and fallback != target:
            set_harmony_agent_target(fallback)
            return health_payload_after_target_selected(
                fallback,
                "Wireless tconn failed; using existing HDC target.",
                requested_target=target
            )
        return {
            "status": "error",
            "message": result.stderr.strip() or result.stdout.strip() or f"hdc tconn failed: {target}",
            "hdc_connected": False,
            "target": target,
            "tunnel_ready": False,
            "fport_ready": False,
            "rport_ready": False,
            "rport_listening": None,
            "rport_listen_check_supported": False,
            "app_server_url": APP_REVERSE_HDC_URL,
        }

    set_harmony_agent_target(target)
    cache_wireless_hdc_target(target, source="manual-connect")
    if kill_others:
        cleanup_other_wireless_targets(target)
    return health_payload_after_target_selected(target, requested_target=target)

def ensure_workflow_agent_ready():
    if harmony_agent is None:
        raise RuntimeError('harmony_agent.py is unavailable')
    if not is_hdc_connected():
        raise RuntimeError('HDC target is not connected')

def ensure_wechat_collect_service_ready():
    if wechat_collect_service is None:
        raise RuntimeError("wechat_collect module is unavailable")

def ensure_workflow_hdc_ready():
    if not is_hdc_connected():
        raise RuntimeError('HDC target is not connected')

def ensure_wechat_collect_ready(require_agent=False):
    ensure_wechat_collect_service_ready()
    ensure_workflow_hdc_ready()
    if require_agent:
        if harmony_agent is None:
            raise RuntimeError('harmony_agent.py is unavailable')
        if not hasattr(harmony_agent, 'run_gui_task'):
            raise RuntimeError('harmony_agent.run_gui_task is unavailable')

def wechat_collect_requires_gui_search(payload):
    if not isinstance(payload, dict):
        return False
    return str(payload.get("mode", "recent_contacts")).strip() == "target_contact"

def run_wechat_gui_search(contact_name):
    if harmony_agent is None:
        print(">> [WeChatCollect] harmony_agent 不可用，跳过 GUI Agent 搜索兜底")
        return {"status": "error", "message": "harmony_agent.py is unavailable"}
    if not hasattr(harmony_agent, 'run_gui_task'):
        print(">> [WeChatCollect] harmony_agent.run_gui_task 不可用，跳过 GUI Agent 搜索兜底")
        return {"status": "error", "message": "harmony_agent.run_gui_task is unavailable"}
    return harmony_agent.run_gui_task(f"搜索{contact_name}，进入聊天界面")

def wechat_collect_driver_call():
    if harmony_agent is None or not hasattr(harmony_agent, 'run_driver_call'):
        return None
    ensure_driver = getattr(harmony_agent, 'ensure_driver_available', None)
    if callable(ensure_driver):
        try:
            if not ensure_driver():
                return None
        except Exception as ex:
            print(f">> [WeChatCollect] hmdriver2 初始化失败，将回退 HDC: {ex}")
            return None
    return harmony_agent.run_driver_call

def bring_llm_app_back_after_wechat_collect():
    if harmony_agent is None or not hasattr(harmony_agent, 'bring_llm_app_to_foreground'):
        return
    try:
        harmony_agent.bring_llm_app_to_foreground()
    except Exception as ex:
        print(f">> [WeChatCollect] 回到 MNN LLM Chat 失败: {ex}")

def workflow_uidump_action(payload):
    ensure_wechat_collect_ready()
    return run_with_hdc_control(
        "workflow_uidump",
        lambda: wechat_collect_service.uidump_action(payload or {}, hdc_prefix())
    )

def workflow_wechat_collect_action(payload):
    request_payload = payload or {}
    ensure_wechat_collect_ready()
    def collect_and_return_app():
        try:
            return wechat_collect_service.collect_action(
                request_payload,
                hdc_prefix(),
                gui_search=run_wechat_gui_search,
                driver_call=wechat_collect_driver_call(),
            )
        finally:
            bring_llm_app_back_after_wechat_collect()

    return run_with_hdc_control(
        "workflow_wechat_collect",
        collect_and_return_app
    )

def run_remote_command(cmd):
    def execute():
        try:
            result = subprocess.run(
                cmd,
                shell=True,
                capture_output=True,
                text=True,
                timeout=HDC_COMMAND_TIMEOUT
            )
        except subprocess.TimeoutExpired as ex:
            result = subprocess.CompletedProcess(
                cmd,
                124,
                ex.stdout or "",
                ex.stderr or f"command timed out after {HDC_COMMAND_TIMEOUT}s: {cmd}"
            )
        if harmony_agent is not None and 'hdc' in cmd.lower():
            invalidate_hdc_health_cache()
        return result

    if harmony_agent is not None and hasattr(harmony_agent, 'run_with_device_control'):
        return harmony_agent.run_with_device_control('run_cmd', execute)
    return execute()

def run_hdc_command(cmd, timeout=HDC_ACTION_TIMEOUT):
    try:
        result = subprocess.run(
            cmd,
            shell=True,
            capture_output=True,
            text=True,
            timeout=timeout
        )
    except subprocess.TimeoutExpired as ex:
        result = subprocess.CompletedProcess(
            cmd,
            124,
            ex.stdout or "",
            ex.stderr or f"command timed out after {timeout}s: {cmd}"
        )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f'command failed: {cmd}')
    return result.stdout.strip()


FOREGROUND_PACKAGE_PATTERNS = (
    re.compile(r"(?im)\bbundle(?:\s*name|name)?\b\s*[:=]\s*['\"]?([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+)"),
    re.compile(r"(?im)\bmission\s+name\b[^A-Za-z0-9_#-]*#*\s*([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+)"),
    re.compile(r"(?im)\bmain\s+window\b.*?\bbundle(?:\s*name)?\b\s*[:=]\s*['\"]?([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+)"),
    re.compile(r"(?im)\bability\b.*?\bbundle(?:\s*name)?\b\s*[:=]\s*['\"]?([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+)"),
)


def extract_foreground_package_name(text):
    raw = str(text or "")
    for pattern in FOREGROUND_PACKAGE_PATTERNS:
        match = pattern.search(raw)
        if match:
            return match.group(1).strip()
    return ""


def run_hdc_command_capture(cmd, timeout=None):
    limit = HDC_ACTION_TIMEOUT if timeout is None else timeout
    try:
        return subprocess.run(
            cmd,
            shell=True,
            capture_output=True,
            text=True,
            timeout=limit
        )
    except subprocess.TimeoutExpired as ex:
        return subprocess.CompletedProcess(
            cmd,
            124,
            ex.stdout or "",
            ex.stderr or f"command timed out after {limit}s: {cmd}"
        )


def detect_current_foreground_package_name():
    commands = (
        f"{hdc_prefix()} shell aa dump --mission-list",
        f"{hdc_prefix()} shell aa dump -l",
        f"{hdc_prefix()} shell hidumper -s AbilityManagerService",
    )
    for command in commands:
        result = run_hdc_command_capture(command, timeout=min(HDC_ACTION_TIMEOUT, 5))
        package_name = extract_foreground_package_name((result.stdout or "") + "\n" + (result.stderr or ""))
        if package_name:
            return package_name
    return ""


def build_app_start_result(app_name, package_name, reset_first):
    target = app_name or package_name
    if not target:
        raise RuntimeError('app_start requires app_name or package_name')
    ok = harmony_agent.launch_app(target, reset_first=reset_first)
    if not ok and package_name and package_name != target:
        ok = harmony_agent.launch_app(package_name, reset_first=reset_first)
    if not ok:
        return {
            'status': 'error',
            'message': f'app_start failed: {target}',
            'package_name': package_name
        }
    current_package_name = ''
    if package_name:
        current_package_name = detect_current_foreground_package_name()
        if current_package_name and current_package_name != package_name:
            return {
                'status': 'error',
                'message': f'app_identity_mismatch: expected {package_name}, current {current_package_name}',
                'package_name': package_name,
                'current_package_name': current_package_name
            }
    result = {
        'status': 'ok',
        'message': f'app_start {target}',
        'package_name': package_name
    }
    if current_package_name:
        result['current_package_name'] = current_package_name
    return result

def hdc_prefix():
    target = get_active_hdc_target(force=False)
    if target:
        return "hdc -t " + target
    return "hdc"

def hdc_input_text_command(text):
    return f"{hdc_prefix()} shell uitest uiInput text {shlex.quote(str(text.strip() or ''))}"

def driver_shell_text_command(text):
    escaped_text = "'" + str(text or '').replace("'", "'\\''") + "'"
    return f"uitest uiInput text {escaped_text}"

def workflow_driver_for_action(action):
    if harmony_agent is None:
        return None
    should_use_driver = HDC_WORKFLOW_USE_DRIVER_ACTIONS or (
        HDC_WORKFLOW_USE_DRIVER_INPUT and action in ('click_input', 'input')
    )
    if not should_use_driver:
        return None
    driver = getattr(harmony_agent, 'd', None)
    if driver is not None:
        return driver
    ensure_driver = getattr(harmony_agent, 'ensure_driver_available', None)
    if not callable(ensure_driver):
        return None
    try:
        if ensure_driver():
            return getattr(harmony_agent, 'd', None)
    except Exception as ex:
        print(f">> [Workflow输入警告] Driver 初始化失败，回退到 HDC inputText: {ex}")
    return None

def payload_bool(payload, key, default):
    value = payload.get(key, default)
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() not in ('false', '0', 'no', 'off')
    return bool(value)

def _compact_action_text(value, limit=80):
    text = str(value or '')
    text = text.replace('\r', '\\r').replace('\n', '\\n')
    if len(text) > limit:
        return text[:limit] + '...'
    return text

def _payload_target_element(payload):
    return _compact_action_text(
        payload.get('target_element') or payload.get('targetElement') or '',
        120
    )

def _format_gui_action(action_name, payload, detail=''):
    target_element = _payload_target_element(payload)
    parts = [action_name]
    if target_element:
        parts.append(f"target_element={target_element}")
    if detail:
        parts.append(detail)
    return ' '.join(parts)

def describe_gui_action(payload):
    action = str(payload.get('action', '')).lower()
    try:
        if action == 'click':
            x = int(payload.get('x', 0))
            y = int(payload.get('y', 0))
            return _format_gui_action('点击', payload, f"坐标={x},{y}")
        if action == 'click_input':
            x = int(payload.get('x', 0))
            y = int(payload.get('y', 0))
            text = _compact_action_text(payload.get('text', ''))
            return _format_gui_action('点击并输入', payload, f"坐标={x},{y} text={text}")
        if action == 'input':
            text = _compact_action_text(payload.get('text', ''))
            return _format_gui_action('输入', payload, f"text={text}")
        if action == 'swipe_with_coords':
            sx = int(payload.get('start_x', 0))
            sy = int(payload.get('start_y', 0))
            ex = int(payload.get('end_x', 0))
            ey = int(payload.get('end_y', 0))
            return _format_gui_action('滑动', payload, f"坐标={sx},{sy}->{ex},{ey}")
        if action == 'swipe':
            return _format_gui_action('滑动', payload, f"direction={str(payload.get('direction', 'up')).lower()}")
        if action == 'keyevent':
            return _format_gui_action('按键', payload, f"key={str(payload.get('key', 'BACK')).upper()}")
        if action == 'sleep':
            return _format_gui_action('等待', payload, f"seconds={float(payload.get('seconds', 1.0))}")
        if action == 'app_start':
            target = str(payload.get('app_name') or payload.get('package_name') or '')
            return _format_gui_action('启动应用', payload, f"target={target}")
        if action == 'app_stop':
            return _format_gui_action('停止应用', payload, f"package={str(payload.get('package_name', ''))}")
    except Exception:
        pass
    return f"{action or 'unknown'}: {payload}"

def log_gui_action(payload):
    print(f">> [HDC操作] {describe_gui_action(payload)}", flush=True)

def workflow_gui_action(payload):
    ensure_workflow_agent_ready()
    return harmony_agent.run_with_device_control(
        'workflow_gui_action',
        lambda: _workflow_gui_action_impl(payload)
    )

def _workflow_gui_action_impl(payload):
    action = str(payload.get('action', '')).lower()
    driver = workflow_driver_for_action(action)
    log_gui_action(payload)

    if action == 'click':
        x = int(payload.get('x', 0))
        y = int(payload.get('y', 0))
        if driver:
            harmony_agent.run_driver_call("Driver.click", lambda d: d.click(x, y))
        else:
            run_hdc_command(f"{hdc_prefix()} shell uitest uiInput click {x} {y}")
        return {'status': 'ok', 'message': f'click {x},{y}'}

    if action == 'click_input':
        x = int(payload.get('x', 0))
        y = int(payload.get('y', 0))
        text = str(payload.get('text', ''))
        if driver:
            harmony_agent.run_driver_call("Driver.click", lambda d: d.click(x, y))
            time.sleep(harmony_agent.DEVICE_WAIT_TIME)
            harmony_agent.run_driver_call("Driver.shell(clear_input)", lambda d: d.shell('uitest uiInput keyEvent 2072 2017'))
            harmony_agent.run_driver_call("Driver.press_key(2071)", lambda d: d.press_key(2071))
            harmony_agent.run_driver_call("Driver.shell(text)", lambda d: d.shell(driver_shell_text_command(text)))
            harmony_agent.press_harmony_key('ENTER', 2054)
        else:
            run_hdc_command(f"{hdc_prefix()} shell uitest uiInput click {x} {y}")
            time.sleep(harmony_agent.DEVICE_WAIT_TIME)
            run_hdc_command(hdc_input_text_command(text))
        return {'status': 'ok', 'message': f'click_input {x},{y}'}

    if action == 'input':
        text = str(payload.get('text', ''))
        if driver:
            harmony_agent.run_driver_call("Driver.shell(clear_input)", lambda d: d.shell('uitest uiInput keyEvent 2072 2017'))
            harmony_agent.run_driver_call("Driver.press_key(2071)", lambda d: d.press_key(2071))
            harmony_agent.run_driver_call("Driver.shell(text)", lambda d: d.shell(driver_shell_text_command(text)))
            harmony_agent.press_harmony_key('ENTER', 2054)
        else:
            run_hdc_command(hdc_input_text_command(text))
        return {'status': 'ok', 'message': 'input'}

    if action == 'swipe_with_coords':
        sx = int(payload.get('start_x', 0))
        sy = int(payload.get('start_y', 0))
        ex = int(payload.get('end_x', 0))
        ey = int(payload.get('end_y', 0))
        # Use hdc absolute-coordinate input for workflow-defined swipes. hmdriver2 swipe
        # can interpret values as normalized ratios on some versions, so pixel coords may
        # become no-ops even though the API call succeeds.
        run_hdc_command(f"{hdc_prefix()} shell uitest uiInput swipe {sx} {sy} {ex} {ey}")
        return {'status': 'ok', 'message': f'swipe {sx},{sy}->{ex},{ey}'}

    if action == 'swipe':
        direction = str(payload.get('direction', 'up')).lower()
        if driver:
            if direction == 'up':
                harmony_agent.run_driver_call("Driver.swipe(up)", lambda d: d.swipe(0.5, harmony_agent.SWIPE_V_END, 0.5, harmony_agent.SWIPE_V_START, speed=1000))
            elif direction == 'down':
                harmony_agent.run_driver_call("Driver.swipe(down)", lambda d: d.swipe(0.5, harmony_agent.SWIPE_V_START, 0.5, harmony_agent.SWIPE_V_END, speed=1000))
            elif direction == 'left':
                harmony_agent.run_driver_call("Driver.swipe(left)", lambda d: d.swipe(harmony_agent.SWIPE_H_END, 0.5, harmony_agent.SWIPE_H_START, 0.5, speed=1000))
            elif direction == 'right':
                harmony_agent.run_driver_call("Driver.swipe(right)", lambda d: d.swipe(harmony_agent.SWIPE_H_START, 0.5, harmony_agent.SWIPE_H_END, 0.5, speed=1000))
            else:
                raise RuntimeError(f'unknown swipe direction: {direction}')
        else:
            width = int(payload.get('width', 1000))
            height = int(payload.get('height', 1000))
            if direction == 'up':
                sx, sy, ex, ey = 0.5 * width, harmony_agent.SWIPE_V_END * height, 0.5 * width, harmony_agent.SWIPE_V_START * height
            elif direction == 'down':
                sx, sy, ex, ey = 0.5 * width, harmony_agent.SWIPE_V_START * height, 0.5 * width, harmony_agent.SWIPE_V_END * height
            elif direction == 'left':
                sx, sy, ex, ey = harmony_agent.SWIPE_H_END * width, 0.5 * height, harmony_agent.SWIPE_H_START * width, 0.5 * height
            elif direction == 'right':
                sx, sy, ex, ey = harmony_agent.SWIPE_H_START * width, 0.5 * height, harmony_agent.SWIPE_H_END * width, 0.5 * height
            else:
                raise RuntimeError(f'unknown swipe direction: {direction}')
            run_hdc_command(f"{hdc_prefix()} shell uitest uiInput swipe {int(sx)} {int(sy)} {int(ex)} {int(ey)}")
        return {'status': 'ok', 'message': f'swipe {direction}'}

    if action == 'keyevent':
        key = str(payload.get('key', 'BACK')).upper()
        if key == 'BACK':
            if driver:
                harmony_agent.press_harmony_key('BACK', 2)
            else:
                run_hdc_command(f"{hdc_prefix()} shell uitest uiInput keyEvent 2")
        elif key == 'HOME':
            if driver:
                harmony_agent.press_harmony_key('HOME', 1)
            else:
                run_hdc_command(f"{hdc_prefix()} shell uitest uiInput keyEvent 1")
        elif key == 'ENTER':
            if driver:
                harmony_agent.press_harmony_key('ENTER', 2054)
            else:
                run_hdc_command(f"{hdc_prefix()} shell uitest uiInput keyEvent 2054")
        else:
            run_hdc_command(f"{hdc_prefix()} shell uitest uiInput keyEvent {key}")
        return {'status': 'ok', 'message': f'keyevent {key}'}

    if action == 'sleep':
        seconds = float(payload.get('seconds', 1.0))
        time.sleep(seconds)
        return {'status': 'ok', 'message': f'sleep {seconds}'}

    if action == 'app_start':
        app_name = str(payload.get('app_name', ''))
        package_name = str(payload.get('package_name', ''))
        reset_first = payload_bool(payload, 'reset_first', True)
        return build_app_start_result(app_name, package_name, reset_first)

    if action == 'app_stop':
        package_name = str(payload.get('package_name', ''))
        if not package_name:
            raise RuntimeError('app_stop requires package_name')
        if driver:
            harmony_agent.run_driver_call("Driver.stop_app", lambda d: d.stop_app(package_name))
        else:
            run_hdc_command(f"{hdc_prefix()} shell aa force-stop {package_name}")
        return {'status': 'ok', 'message': f'app_stop {package_name}', 'package_name': package_name}

    raise RuntimeError(f'Unsupported gui_action: {action}')

def handle_workflow_action(action, payload):
    action = str(action or '')
    payload = payload or {}

    if action == 'health':
        return hdc_health_payload(force=False, repair=False)

    if action == 'repair_health':
        return hdc_health_payload(force=True, repair=True)

    if action == 'agent_config':
        return {
            'status': 'ok',
            'message': 'agent config',
            'no_reason': bool(NO_REASON_MODE),
            'max_steps': int(getattr(harmony_agent, 'MAX_STEPS', 15)) if harmony_agent is not None else 15
        }

    if action == 'prepare_agent_run':
        ensure_workflow_agent_ready()
        harmony_agent.reset_driver()
        return {
            'status': 'ok',
            'message': 'agent device control prepared'
        }

    if action == 'load_prompt_template':
        if harmony_agent is None:
            raise RuntimeError('harmony_agent.py is unavailable')
        prompt_name = os.path.basename(str(payload.get('prompt_name', '')).strip())
        if not prompt_name:
            raise RuntimeError('prompt_name is required')
        template = harmony_agent.load_prompt(prompt_name)
        if not template:
            raise RuntimeError(f'prompt template not found: {prompt_name}')
        return {
            'status': 'ok',
            'message': f'loaded prompt template: {prompt_name}',
            'result': template
        }

    if action == 'screenshot':
        ensure_workflow_agent_ready()
        factor = float(payload.get('factor', 0.5))
        style = str(payload.get('style', 'mobiagent')).lower()
        manage_overlay = payload_bool(payload, 'manage_overlay', False)
        target_width = payload.get('target_width')
        target_height = payload.get('target_height')
        target_width = int(target_width) if target_width else None
        target_height = int(target_height) if target_height else None
        if manage_overlay:
            if style == 'local' or factor <= 0.25:
                image_b64, width, height = harmony_agent.capture_screen(factor, target_width, target_height)
            else:
                image_b64, width, height = harmony_agent.capture_screen_mobiagent_style(factor)
        else:
            if style == 'local' or factor <= 0.25:
                image_b64, width, height = harmony_agent.run_with_device_control(
                    'workflow capture_screen direct',
                    lambda: harmony_agent._capture_screen_impl(factor, target_width, target_height)
                )
            else:
                image_b64, width, height = harmony_agent.run_with_device_control(
                    'workflow capture_screen_mobiagent direct',
                    lambda: harmony_agent._capture_screen_mobiagent_style_impl(factor)
                )
        return {
            'status': 'ok',
            'image_b64': image_b64,
            'width': width,
            'height': height,
            'message': f'screenshot {width}x{height}'
        }

    if action == 'app_start':
        ensure_workflow_agent_ready()
        app_name = str(payload.get('app_name', ''))
        package_name = str(payload.get('package_name', ''))
        reset_first = payload_bool(payload, 'reset_first', True)
        return build_app_start_result(app_name, package_name, reset_first)

    if action == 'execute_decider_action':
        ensure_workflow_agent_ready()
        response = str(payload.get('response', ''))
        width = int(payload.get('width', 1000))
        height = int(payload.get('height', 1000))
        executed_action, params = harmony_agent.execute_action_and_get_details(response, img_size=(width, height))
        return {
            'status': 'ok',
            'message': f'executed {executed_action}',
            'action': executed_action,
            'result': json.dumps(params, ensure_ascii=False)
        }

    if action == 'gui_action':
        return workflow_gui_action(payload)

    if action == 'uidump':
        return workflow_uidump_action(payload)

    if action == 'wechat_collect':
        return workflow_wechat_collect_action(payload)

    raise RuntimeError(f'Unsupported workflow action: {action}')

def invalidate_hdc_health_cache():
    global _hdc_health_checked_at, _hdc_health_connected, _hdc_health_target
    _hdc_health_checked_at = 0.0
    _hdc_health_connected = False
    set_harmony_agent_target("")
    reset_hdc_tunnel_cache()

def is_hdc_connected(force=False):
    return bool(get_active_hdc_target(force=force))

def _run_harmony_agent_thread(stop_event):
    try:
        harmony_agent.set_no_reason_mode(NO_REASON_MODE)
        harmony_agent.run_agent_loop(stop_event)
    except Exception as ex:
        print(f">> [AgentThread错误] harmony_agent loop exited unexpectedly: {ex}")

def start_harmony_agent():
    global agent_thread, agent_stop_event
    if not LEGACY_LOOP_ENABLED:
        return
    if harmony_agent is None:
        print(">> [警告] harmony_agent.py is unavailable; agent loop will not start.")
        return
    if agent_thread is not None and agent_thread.is_alive():
        return

    agent_stop_event = threading.Event()
    harmony_agent.set_no_reason_mode(NO_REASON_MODE)
    print(">> 正在后台启动任务代理线程: harmony_agent.run_agent_loop")
    agent_thread = threading.Thread(
        target=_run_harmony_agent_thread,
        args=(agent_stop_event,),
        name="harmony-agent-loop",
        daemon=True
    )
    agent_thread.start()

def ensure_agent_loop_ready():
    if not LEGACY_LOOP_ENABLED:
        return {
            'status': 'error',
            'message': '9126 polling loop is disabled by --workflow_only'
        }
    if harmony_agent is None:
        return {
            'status': 'error',
            'message': 'harmony_agent.py is unavailable'
        }

    if not is_hdc_connected(force=True):
        return {
            'status': 'error',
            'message': hdc_manual_config_message(),
            'hdc_connected': False,
            'tunnel_ready': False,
            'fport_ready': False,
            'rport_ready': False,
            'rport_listening': None,
            'rport_listen_check_supported': False,
            'app_server_url': APP_REVERSE_HDC_URL
        }

    tunnel = ensure_hdc_tunnels(force=True)
    payload = build_hdc_health_payload(str(tunnel.get("target", "")), tunnel)
    if not tunnel.get("fport_ready"):
        payload['status'] = 'error'
        payload['message'] = tunnel.get("message", "HDC fport refresh failed")
        return payload

    start_harmony_agent()
    message = 'agent loop is running and HDC fport/rport refreshed'
    if not tunnel.get("rport_ready"):
        message = 'agent loop is running and HDC fport refreshed; reverse rport is unavailable'
    payload['status'] = 'ok'
    payload['message'] = message
    payload['loop_alive'] = agent_thread is not None and agent_thread.is_alive()
    return payload

def cleanup():
    global agent_thread
    agent_stop_event.set()
    if harmony_agent is not None and hasattr(harmony_agent, 'stop_agent_loop'):
        harmony_agent.stop_agent_loop()
    if agent_thread is not None and agent_thread.is_alive():
        print("\n>> 正在关闭 harmony_agent 后台线程...")
        agent_thread.join(timeout=5)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument("--no_reason", action="store_true", help="Use prompts without reasoning")
    parser.add_argument("--auto", action="store_true",
                        help="Auto-discover a previously paired HarmonyOS wireless HDC target from LAN")
    parser.add_argument("--legacy_loop", action="store_true",
                        help="Compatibility flag; the 9126 polling harmony_agent loop is enabled by default")
    parser.add_argument("--workflow_only", action="store_true",
                        help="Do not start the 9126 polling harmony_agent loop; only expose /api/workflow")
    args = parser.parse_args()
    
    if args.no_reason:
        NO_REASON_MODE = True
    AUTO_DISCOVERY_ENABLED = args.auto
    LEGACY_LOOP_ENABLED = not args.workflow_only
    if args.legacy_loop:
        LEGACY_LOOP_ENABLED = True

    if AUTO_DISCOVERY_ENABLED:
        print(
            ">> HDC 自动发现已开启：将使用历史无线 HDC target 的端口和 IP 前缀扫描局域网。\n"
            f">> 自动发现缓存: {AUTO_DISCOVERY_CACHE_FILE}"
        )
        auto_start_result = ensure_auto_hdc_connected(force=True, prompt_user=True,
                                                      reason="Server startup auto discovery.")
        if auto_start_result.get("status") == "ok":
            print(f">> [HDC Auto] 已选择目标: {auto_start_result.get('target', '')}")
        else:
            print(f">> [HDC Auto] 启动自动发现未完成: {auto_start_result.get('message', '')}")

    initial_hdc_connected = is_hdc_connected(force=not AUTO_DISCOVERY_ENABLED)

    # 9126 轮询同时服务 App 端“本地/云端智能体执行”按钮；workflow bridge 仍然按请求直接控制设备。
    if LEGACY_LOOP_ENABLED:
        if initial_hdc_connected:
            start_harmony_agent()
        else:
            print_hdc_manual_config_hint()
            print(">> 轮询 Agent loop 暂未启动；完成 HDC 配置后，请在手机 App 重新触发连接或调用 /api/agent_loop/ensure。")
    else:
        print(">> 旧版 harmony_agent 轮询未启用；workflow bridge 将按请求直接控制设备。")
        
    # 监听在独立端口：9123 是模型文件服务，9126 是 App 内 TCP Agent 服务。
    PORT = SERVER_PORT
    server = ThreadingHTTPServer(('0.0.0.0', PORT), HDCServerHandler)
    if initial_hdc_connected:
        tunnel = ensure_hdc_tunnels(force=True, reset_reverse=True)
        print(f">> [HDC] {tunnel.get('message', '')}")
    print(f"HDC 远程控制服务端已启动，监听端口: {PORT}...")
    if initial_hdc_connected:
        print(f"等待手机 App 发送连接指令...")
    else:
        print("未检测到 HDC 设备，暂不等待手机 App 派发任务；请完成手动配置后重新触发连接。")
    
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        cleanup()
        server.server_close()
        print(">> 服务已退出。")
