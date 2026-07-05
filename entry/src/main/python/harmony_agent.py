import os
import time
import json
import base64
import socket
import subprocess
from PIL import Image
import io
import re
import sys
import logging
import argparse
import threading
import uuid
import inspect
import shlex

# PC 侧视觉自动化 Agent：
# 1. 轮询 App 内 9126 TCP 服务获取任务；
# 2. Planner 选择目标 App 并通过 HDC/hmdriver2 拉起；
# 3. 循环截图、发送给本地/云端模型 Decider、解析动作 JSON；
# 4. 执行点击/输入/滑动，并把动作历史带入下一轮。
class TaskCompletedConnectionClosed(Exception):
    pass

try:
    from hmdriver2.driver import Driver
    d = None
except ImportError:
    print(">> [警告] 无法导入 hmdriver2，请确保它已经安装。")
    d = None

PORT = 9126
HOST = '127.0.0.1'
PROMPTS_DIR = os.path.join(os.path.dirname(__file__), "prompts")
NULL_DEVICE = "NUL" if os.name == "nt" else "/dev/null"
HDC_TARGET = os.environ.get("HDC_TARGET", "").strip()
HDC_TARGET_OVERRIDE = HDC_TARGET
HDC_TARGET_CHECKED_AT = 0.0
HDC_TARGET_LAST_OK_AT = 0.0
HDC_TARGET_CACHE_TTL = float(os.environ.get("HDC_TARGET_CACHE_TTL", "15"))
HDC_LIST_TARGETS_TIMEOUT = float(os.environ.get("HDC_LIST_TARGETS_TIMEOUT", "3"))
HDC_TARGET_STALE_GRACE = float(os.environ.get("HDC_TARGET_STALE_GRACE", "30"))
HDC_COMMAND_TIMEOUT = float(os.environ.get("HDC_COMMAND_TIMEOUT", "10"))
HDC_ACTION_TIMEOUT = float(os.environ.get("HDC_ACTION_TIMEOUT", "6"))
HDC_CLEANUP_TIMEOUT = float(os.environ.get("HDC_CLEANUP_TIMEOUT", "3"))
LAST_TASK_COMPLETED = False
DEVICE_CONTROL_LOCK = threading.RLock()
AGENT_LOOP_STOP_EVENT = threading.Event()
POLL_FPORT_REFRESH_INTERVAL = 15.0
LAST_POLL_FPORT_REFRESH = 0.0
HDC_MANUAL_CONFIG_NOTICE_INTERVAL = 60.0
HDC_MANUAL_CONFIG_LAST_NOTICE_AT = 0.0

# Agent mode toggle: True = prefix KV cache reuse, False = original chat-based flow
USE_AGENT_MODE = True
NO_REASON_MODE = False

# 常数定义
MAX_STEPS = 15
MAX_RETRIES = 5
TEMP_INCREMENT = 0.1
INITIAL_TEMP = 0.0
API_TIMEOUT = 30
DECIDER_MAX_TOKENS = 256
GROUNDER_MAX_TOKENS = 128
DEVICE_WAIT_TIME = 0.5
APP_LAUNCH_WAIT_TIME = 0.8
APP_STOP_WAIT = 3
APP_FRESH_START_WAIT_TIME = 0.8

# 滑动坐标缩放比例
SWIPE_V_START = 0.3
SWIPE_V_END = 0.7
SWIPE_H_START = 0.3
SWIPE_H_END = 0.7

# LLM Agent 包名
LLM_APP_BUNDLE = "com.example.mnnllmchat"
LLM_APP_ABILITY = "EntryAbility"

def quiet_system(cmd):
    try:
        result = subprocess.run(
            cmd,
            shell=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=HDC_COMMAND_TIMEOUT
        )
        return result.returncode
    except subprocess.TimeoutExpired:
        print(f">> [HDC timeout] command exceeded {HDC_COMMAND_TIMEOUT}s: {cmd}")
        return 124

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

def list_hdc_targets(return_error=False):
    targets = []
    error = ""
    try:
        result = subprocess.run(
            ["hdc", "list", "targets"],
            capture_output=True,
            text=True,
            timeout=HDC_LIST_TARGETS_TIMEOUT
        )
        if result.returncode != 0:
            error = result.stderr.strip() or result.stdout.strip()
        else:
            targets = parse_hdc_targets(result.stdout)
    except subprocess.TimeoutExpired:
        error = f"command timed out after {HDC_LIST_TARGETS_TIMEOUT}s: hdc list targets"
    except Exception as ex:
        error = str(ex)
    if error:
        print(f">> [HDC warning] list targets failed: {error}")
    if return_error:
        return targets, error
    return targets

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

def set_hdc_target(target, checked_at=0.0, mark_ok=False):
    global HDC_TARGET, HDC_TARGET_CHECKED_AT, HDC_TARGET_LAST_OK_AT
    HDC_TARGET = target.strip() if isinstance(target, str) else ""
    HDC_TARGET_CHECKED_AT = checked_at
    if mark_ok and HDC_TARGET and checked_at > 0:
        HDC_TARGET_LAST_OK_AT = checked_at
    # hmdriver2 may read HDC_TARGET during import; keep runtime selection visible without
    # treating it as the startup override used by choose_hdc_target().
    if HDC_TARGET:
        os.environ["HDC_TARGET"] = HDC_TARGET
    elif not HDC_TARGET_OVERRIDE:
        os.environ.pop("HDC_TARGET", None)

def clear_hdc_target_cache():
    if HDC_TARGET_OVERRIDE:
        return
    set_hdc_target("")

def hdc_manual_config_message():
    return (
        "未检测到 HDC 设备连接。请先手动配置 HDC：USB 连接后执行 `hdc list targets` "
        "确认设备在线；无线调试请先执行 `hdc tconn <设备IP:端口>`；如果有多个设备或固定无线目标，"
        "请设置环境变量 `HDC_TARGET=<target>` 后重启服务。"
    )

def print_hdc_manual_config_hint(force=False):
    global HDC_MANUAL_CONFIG_LAST_NOTICE_AT
    now = time.monotonic()
    if (not force and HDC_MANUAL_CONFIG_LAST_NOTICE_AT > 0 and
            now - HDC_MANUAL_CONFIG_LAST_NOTICE_AT < HDC_MANUAL_CONFIG_NOTICE_INTERVAL):
        return
    HDC_MANUAL_CONFIG_LAST_NOTICE_AT = now
    print(f">> [HDC] {hdc_manual_config_message()}")

def keep_cached_hdc_target_after_probe_error(error, now):
    global HDC_TARGET_CHECKED_AT
    if not error or not HDC_TARGET or HDC_TARGET_LAST_OK_AT <= 0:
        return ""
    age = now - HDC_TARGET_LAST_OK_AT
    if age > HDC_TARGET_STALE_GRACE:
        return ""
    HDC_TARGET_CHECKED_AT = now
    remaining = max(0.0, HDC_TARGET_STALE_GRACE - age)
    print(
        f">> [HDC] list targets failed; keeping cached target "
        f"{HDC_TARGET} for {remaining:.1f}s: {error}"
    )
    return HDC_TARGET

def get_hdc_target(force=False):
    global HDC_TARGET, HDC_TARGET_CHECKED_AT
    now = time.monotonic()
    if (not force and HDC_TARGET and HDC_TARGET_CHECKED_AT > 0 and
            now - HDC_TARGET_CHECKED_AT < HDC_TARGET_CACHE_TTL):
        return HDC_TARGET

    targets, error = list_hdc_targets(return_error=True)
    target = choose_hdc_target(targets, HDC_TARGET)
    if not target:
        stale_target = keep_cached_hdc_target_after_probe_error(error, now)
        if stale_target:
            return stale_target
        if HDC_TARGET:
            print(f">> [HDC] 目标设备已失效，清理缓存: {HDC_TARGET}")
        set_hdc_target("", checked_at=now)
        return ""
    if target != HDC_TARGET:
        print(f">> [HDC] 使用目标设备: {target}")
    set_hdc_target(target, checked_at=now, mark_ok=True)
    return HDC_TARGET

def hdc_prefix(force=False):
    # 所有 hdc 命令统一走这里，保证多设备场景下始终带 -t target。
    target = get_hdc_target(force=force)
    if target:
        return f"hdc -t {target}"
    return "hdc"

def hdc_prefix_for_target(target):
    if target:
        return f"hdc -t {target}"
    return "hdc"

def refresh_hdc_forwarding(verbose=False):
    return run_with_device_control(
        "refresh_hdc_forwarding",
        lambda: _refresh_hdc_forwarding_impl(verbose)
    )

def _refresh_hdc_forwarding_for_target(target, verbose=False):
    prefix = hdc_prefix_for_target(target)
    quiet_system(f"{prefix} fport rm tcp:{PORT} tcp:{PORT}")
    if verbose:
        try:
            return subprocess.run(
                f"{prefix} fport tcp:{PORT} tcp:{PORT}",
                shell=True,
                timeout=HDC_COMMAND_TIMEOUT
            ).returncode
        except subprocess.TimeoutExpired:
            print(f">> [HDC timeout] fport exceeded {HDC_COMMAND_TIMEOUT}s")
            return 124
    return quiet_system(f"{prefix} fport tcp:{PORT} tcp:{PORT}")

def _refresh_hdc_forwarding_impl(verbose=False):
    # PC 通过 tcp:9126 转发到手机 App 内 TCP server；每次任务前刷新，避免旧映射残留。
    target = get_hdc_target(force=True)
    if not target:
        print_hdc_manual_config_hint(force=verbose)
        return 1

    result = _refresh_hdc_forwarding_for_target(target, verbose)
    if result == 0 or HDC_TARGET_OVERRIDE:
        return result

    candidates = [candidate for candidate in list_hdc_targets() if candidate != target]
    fallback = choose_hdc_target(candidates)
    if not fallback:
        return result
    print(f">> [HDC] target {target} fport failed; retry with {fallback}")
    set_hdc_target(fallback)
    return _refresh_hdc_forwarding_for_target(fallback, verbose)

def normalize_hmdriver_loggers():
    # hmdriver2 多次重载后可能重复挂 handler，导致日志重复；这里去重并关闭向上传播。
    logger_names = (
        "hmdriver2",
        "hmdriver2.driver",
        "hmdriver2.hdc",
        "hmdriver2._client",
        "_client",
        "driver",
        "hdc",
    )
    for logger_name in logger_names:
        logger = logging.getLogger(logger_name)
        if not logger.handlers:
            continue

        unique_handlers = []
        seen = set()
        for handler in logger.handlers:
            key = (
                type(handler),
                getattr(handler, "baseFilename", None),
                id(getattr(handler, "stream", None)),
                handler.level,
            )
            if key in seen:
                continue
            seen.add(key)
            unique_handlers.append(handler)

        logger.handlers = unique_handlers
        logger.propagate = False

def set_no_reason_mode(enabled):
    global NO_REASON_MODE
    NO_REASON_MODE = bool(enabled)

def stop_agent_loop():
    AGENT_LOOP_STOP_EVENT.set()

def reset_agent_loop_stop():
    AGENT_LOOP_STOP_EVENT.clear()

def is_driver_connection_error(ex):
    msg = str(ex)
    lower = msg.lower()
    return (
        isinstance(ex, (ConnectionResetError, ConnectionAbortedError, BrokenPipeError, OSError, json.JSONDecodeError)) or
        (
            "10053" in msg or
            "10054" in msg or
            "broken pipe" in lower or
            "connection reset" in lower or
            "connection aborted" in lower or
            "forcibly closed" in lower or
            "unable to write data" in lower or
            "software caused connection abort" in lower or
            "你的主机中的软件中止了一个已建立的连接" in msg or
            "远程主机强迫关闭" in msg
        )
    )

def run_with_device_control(operation_name, operation):
    with DEVICE_CONTROL_LOCK:
        return operation()

def run_driver_call(operation_name, operation):
    global d
    if not d:
        return None
    try:
        return operation(d)
    except Exception as ex:
        if is_driver_connection_error(ex):
            print(f">> [DriverManager] {operation_name} connection lost: {ex}; reset Driver and retry once.")
            reset_driver()
            if d:
                return operation(d)
            raise RuntimeError(f"Driver unavailable after reset during {operation_name}") from ex
        raise

def ensure_driver_available():
    global d
    if d:
        return True
    print(">> [DriverManager] Driver 未初始化，正在按需初始化以启动 App...")
    reset_driver()
    return d is not None

def get_main_ability_for_bundle(bundle):
    if not ensure_driver_available():
        return ""
    try:
        ability = run_driver_call(
            "Driver.get_app_main_ability",
            lambda driver: driver.get_app_main_ability(bundle)
        )
        if isinstance(ability, dict):
            name = ability.get("name", "")
            return name if isinstance(name, str) else ""
    except Exception as ex:
        print(f">> [启动警告] 查询 {bundle} 主 Ability 失败: {ex}")
    return ""

def start_app_with_explicit_ability(bundle, ability_name):
    if not ability_name:
        return False
    cmd = f"{hdc_prefix()} shell aa start -a {ability_name} -b {bundle}"
    try:
        print(f">> 执行启动命令 (hdc explicit): {cmd}")
        _run_timed_command("launch_app explicit aa start", cmd)
        time.sleep(APP_LAUNCH_WAIT_TIME)
        return True
    except Exception as ex:
        print(f">> [启动警告] 显式 Ability 启动失败，准备回退: {ex}")
        return False

def stop_app_before_launch(bundle):
    if not bundle:
        return
    print(f">> [Planner] Stop target App before launch for a clean start: {bundle}")
    stopped = False
    if ensure_driver_available():
        try:
            run_driver_call("Driver.stop_app", lambda driver: driver.stop_app(bundle))
            stopped = True
        except Exception as ex:
            print(f">> [launch warning] Driver.stop_app failed; fallback to HDC force-stop: {ex}")
    if not stopped:
        cmd = f"{hdc_prefix()} shell aa force-stop {bundle}"
        try:
            print(f">> Run stop command (hdc force-stop): {cmd}")
            _run_timed_command("launch_app force-stop", cmd)
        except Exception as ex:
            print(f">> [launch warning] HDC force-stop failed; continue launching {bundle}: {ex}")
    time.sleep(APP_FRESH_START_WAIT_TIME)

def bring_llm_app_to_foreground():
    return run_with_device_control(
        "bring_llm_app_to_foreground",
        _bring_llm_app_to_foreground_impl
    )

def _bring_llm_app_to_foreground_impl():
    # 任务结束或异常时回到本 App，方便用户查看日志、截图和错误原因。
    print(">> 任务结束/出错，正在自动跳回 MNN LLM Chat App...")
    try:
        _run_timed_command(
            "bring_llm_app_to_foreground",
            f"{hdc_prefix()} shell aa start -b {LLM_APP_BUNDLE} -a {LLM_APP_ABILITY}",
            timeout=HDC_ACTION_TIMEOUT
        )
    except Exception as ex:
        print(f">> [HDC warning] bring app to foreground failed: {ex}")
    time.sleep(1)
APP_MAPPING = {
    # Planner 输出中文 App 名或包名均可；中文名先映射为 HarmonyOS bundleName。
    "携程": "com.ctrip.harmonynext",
    "飞猪": "com.fliggy.hmos",
    "IntelliOS": "ohos.hongmeng.intellios",
    "同城": "com.tongcheng.hmos",
    "携程旅行": "com.ctrip.harmonynext",
    "饿了么": "me.ele.eleme",
    "知乎": "com.zhihu.hmos",
    "哔哩哔哩": "yylx.danmaku.bili",
    "微信": "com.tencent.wechat",
    "小红书": "com.xingin.xhs_hos",
    "QQ音乐": "com.tencent.hm.qqmusic",
    "高德地图": "com.amap.hmapp",
    "淘宝": "com.taobao.taobao4hmos",
    "微博": "com.sina.weibo.stage",
    "京东": "com.jd.hm.mall",
    "飞猪旅行": "com.fliggy.hmos",
    "天气": "com.huawei.hmsapp.totemweather",
    "什么值得买": "com.smzdm.client.hmos",
    "闲鱼": "com.taobao.idlefish4ohos",
    "慧通差旅": "com.smartcom.itravelhm",
    "PowerAgent": "com.example.osagent",
    "航旅纵横": "com.umetrip.hm.app",
    "滴滴出行": "com.sdu.didi.hmos.psnger",
    "电子邮件": "com.huawei.hmos.email",
    "图库": "com.huawei.hmos.photos",
    "日历": "com.huawei.hmos.calendar",
    "心声社区": "com.huawei.it.hmxinsheng",
    "信息": "com.ohos.mms",
    "文件管理": "com.huawei.hmos.files",
    "运动健康": "com.huawei.hmos.health",
    "智慧生活": "com.huawei.hmos.ailife",
    "豆包": "com.larus.nova.hm",
    "WeLink": "com.huawei.it.welink",
    "设置": "com.huawei.hmos.settings",
    "懂车帝": "com.ss.dcar.auto",
    "美团外卖": "com.meituan.takeaway",
    "大众点评": "com.sankuai.dianping",
    "美团": "com.sankuai.hmeituan",
    "浏览器": "com.huawei.hmos.browser",
    "拼多多": "com.xunmeng.pinduoduo.hos",
    "支付宝": "com.alipay.mobile.client"
}

def load_prompt(filename):
    # Prompt 模板集中放在 prompts/，不同模式通过文件名切换。
    path = os.path.join(PROMPTS_DIR, filename)
    if not os.path.exists(path):
        print(f">> [警告] 找不到 Prompt 模板文件: {path}")
        return ""
    with open(path, 'r', encoding='utf-8') as f:
        return f.read()

def run_cmd(cmd):
    return subprocess.check_output(cmd, shell=True, text=True, timeout=HDC_COMMAND_TIMEOUT)

def _run_timed_command(label, cmd, capture_output=True, timeout=HDC_COMMAND_TIMEOUT):
    started = time.perf_counter()
    try:
        result = subprocess.run(
            cmd,
            shell=True,
            capture_output=capture_output,
            text=True,
            timeout=timeout
        )
    except subprocess.TimeoutExpired as ex:
        elapsed = time.perf_counter() - started
        print(f">> [HDC Timing] {label}: {elapsed:.3f}s (timeout)")
        output = ""
        if capture_output:
            output = (ex.stderr or ex.stdout or "")
            if isinstance(output, bytes):
                output = output.decode("utf-8", errors="replace")
            output = str(output).strip()
        raise RuntimeError(output or f"{label} timed out after {timeout}s")
    elapsed = time.perf_counter() - started
    print(f">> [HDC Timing] {label}: {elapsed:.3f}s")
    if result.returncode != 0:
        output = ''
        if capture_output:
            output = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(output or f"{label} failed: returncode={result.returncode}")
    return result

def run_hdc_action_command(label, cmd):
    return _run_timed_command(label, cmd, timeout=HDC_ACTION_TIMEOUT)

def hdc_input_text_command(text):
    return f"{hdc_prefix()} shell uitest uiInput inputText {shlex.quote(str(text or ''))}"

def _cleanup_device_file_async(prefix, device_path):
    def cleanup():
        started = time.perf_counter()
        try:
            subprocess.run(
                f"{prefix} shell rm \"{device_path}\"",
                shell=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=HDC_CLEANUP_TIMEOUT
            )
            elapsed = time.perf_counter() - started
            print(f">> [HDC Timing] async rm screenshot temp: {elapsed:.3f}s")
        except subprocess.TimeoutExpired:
            elapsed = time.perf_counter() - started
            print(f">> [HDC Timing] async rm screenshot temp: {elapsed:.3f}s (timeout)")

    threading.Thread(
        target=cleanup,
        name="hdc-screenshot-cleanup",
        daemon=True
    ).start()

def _encode_resized_screenshot(local_path, factor, target_width=None, target_height=None):
    with Image.open(local_path) as img:
        w, h = img.size
        if target_width and target_height:
            new_w, new_h = int(target_width), int(target_height)
        else:
            new_w, new_h = int(w * factor), int(h * factor)
        img = img.resize((new_w, new_h), Image.Resampling.LANCZOS)
        buffered = io.BytesIO()
        img.save(buffered, format="JPEG")
    b64 = base64.b64encode(buffered.getvalue()).decode("utf-8")
    return b64, new_w, new_h

def _capture_screen_file(local_path, factor, label, target_width=None, target_height=None):
    prefix = hdc_prefix()
    device_path = f"/data/local/tmp/_tmp_{uuid.uuid4().hex}.jpeg"
    snapshot_created = False
    if os.path.exists(local_path):
        os.remove(local_path)

    try:
        _run_timed_command(
            f"{label} snapshot_display",
            f"{prefix} shell \"snapshot_display -f {device_path}\""
        )
        snapshot_created = True
        _run_timed_command(
            f"{label} file recv",
            f"{prefix} file recv {device_path} \"{local_path}\""
        )

        if not os.path.exists(local_path):
            raise FileNotFoundError(f"local screenshot not found after recv: {local_path}; device path: {device_path}")

        started = time.perf_counter()
        result = _encode_resized_screenshot(local_path, factor, target_width, target_height)
        print(f">> [HDC Timing] {label} resize+base64: {time.perf_counter() - started:.3f}s")
        return result
    finally:
        if snapshot_created:
            _cleanup_device_file_async(prefix, device_path)

def _capture_overlay_hide_best_effort():
    try:
        res = send_request({"type": "capture_overlay_hide"})
        if isinstance(res, str):
            parsed = json.loads(res)
            if isinstance(parsed, dict):
                return bool(parsed.get("hidden", False))
        if isinstance(res, dict):
            return bool(res.get("hidden", False))
    except Exception as exc:
        print(f">> [Capture Overlay] hide skipped: {exc}")
    return False

def _capture_overlay_restore_best_effort(hidden):
    try:
        send_request_best_effort(
            {"type": "capture_overlay_restore", "hidden": bool(hidden)},
            "Capture overlay restore"
        )
    except Exception as exc:
        print(f">> [Capture Overlay] restore skipped: {exc}")

def capture_screen(factor=0.25, target_width=None, target_height=None):
    hidden = _capture_overlay_hide_best_effort()
    try:
        if hidden:
            # 等待 HarmonyOS 浮窗销毁提交到合成层，避免截图仍捕获上一帧的控制面板。
            time.sleep(0.12)
        return run_with_device_control(
            "capture_screen",
            lambda: _capture_screen_impl(factor, target_width, target_height)
        )
    finally:
        _capture_overlay_restore_best_effort(hidden)

def _capture_screen_impl(factor=0.25, target_width=None, target_height=None):
    # 使用 hdc snapshot_display 截图并拉回 PC，再压缩为 base64 发送给 App/云端模型。
    print(">> Capturing screen via hdc...")
    local_path = os.path.join(os.path.dirname(__file__), "screen.jpeg")
    return _capture_screen_file(local_path, factor, "screenshot", target_width, target_height)

def capture_screen_mobiagent_style(factor=0.5, manage_overlay=True):
    hidden = _capture_overlay_hide_best_effort() if manage_overlay else False
    try:
        if hidden:
            # 云端 Agent 截图同样经过系统截图命令，需要给浮窗隐藏留出一帧以上的缓冲。
            time.sleep(0.12)
        return run_with_device_control(
            "capture_screen_mobiagent_style",
            lambda: _capture_screen_mobiagent_style_impl(factor)
        )
    finally:
        if manage_overlay:
            _capture_overlay_restore_best_effort(hidden)

def _capture_screen_mobiagent_style_impl(factor=0.5):
    """Cloud Agent only: match mobiagent HarmonyDevice.screenshot + PIL resize path."""
    # Avoid hmdriver2 Driver.screenshot here: it performs snapshot, recv, and rm
    # synchronously. The direct HDC path keeps the same screenshot size while making
    # cleanup non-blocking and exposing per-stage timing.
    print(">> [Cloud Screenshot] Capturing screen via direct HDC snapshot_display...")
    screenshot_path = "screenshot-Harmony.jpg"
    return _capture_screen_file(screenshot_path, factor, "cloud screenshot")

def send_request(req):
    # 与 LlmServer.ets 保持同一套 JSON + <<EOF>> framing；一次连接只发送一条请求。
    payload = json.dumps(req) + "<<EOF>>"
    req_type = req.get("type", "")
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    if req_type == "poll":
        s.settimeout(2.0)
    connected = False
    try:
        s.connect((HOST, PORT))
        connected = True
        s.sendall(payload.encode('utf-8'))

        buffer = b""
        while True:
            data = s.recv(4096)
            if not data:
                break
            buffer += data
            if b"<<EOF>>" in buffer:
                break

        res = buffer.split(b"<<EOF>>", 1)[0].decode('utf-8')
        try:
            parsed_res = json.loads(res)
            if isinstance(parsed_res, dict) and "__cloud_debug_prompt" in parsed_res and "response" in parsed_res:
                # 云端模式会把 Decider 实际输入 prompt 打回 PC，便于核查图文消息组织方式。
                print("\n========== Cloud Decider Input Prompt ==========")
                print(parsed_res["__cloud_debug_prompt"])
                print("========== End Cloud Decider Input Prompt ==========\n")
                return parsed_res["response"]
        except Exception:
            pass
        return res
    except Exception as e:
        # 当轮询（poll）未连上时保持静默，只有其他核心请求断开时才打印错误，防止刷屏。
        if req.get("type") != "poll":
            if connected:
                print(">> 【错误】手机 App端响应读取/解码失败:\n" + str(e))
            else:
                print(">> 【错误】无法连接到手机 App端，请检查: \n1. 是否在手机App上点击了'启动 PC 控制后端(HDC)'\n2. HDC 是否正常工作\n" + str(e))
        raise e
    finally:
        try:
            s.close()
        except Exception:
            pass

def send_request_best_effort(req, context="request"):
    # 收尾/清理类请求不应让主循环退出；连接已关闭时打印提示后继续等待下一任务。
    try:
        return send_request(req)
    except (ConnectionResetError, ConnectionAbortedError, BrokenPipeError, OSError) as ex:
        print(f">> [提示] {context} 未完成，连接已关闭：{ex}")
        return ""

def send_request_retry_empty(req, context="request", max_attempts=3):
    last_response = ""
    for attempt in range(1, max_attempts + 1):
        response = send_request(req)
        if isinstance(response, str) and response.strip():
            return response
        if response and not isinstance(response, str):
            return response

        last_response = "" if response is None else str(response)
        print(f">> [提示] {context} 返回空响应，正在重试 ({attempt}/{max_attempts})...")
        if attempt < max_attempts:
            time.sleep(0.3)

    return last_response

def is_cancelled_status_response(response_text):
    if not response_text:
        return False
    try:
        parsed = json.loads(response_text)
    except Exception:
        return False
    return isinstance(parsed, dict) and parsed.get("status") == "cancelled"

def is_connection_closed_error(err_msg):
    lower = err_msg.lower()
    return (
        "10053" in err_msg or
        "10054" in err_msg or
        "connection aborted" in lower or
        "forcibly closed" in lower or
        "connection reset" in lower or
        "你的主机中的软件中止了一个已建立的连接" in err_msg or
        "远程主机强迫关闭" in err_msg
    )

def create_driver_for_target(driver_cls, target):
    if target:
        try:
            params = inspect.signature(driver_cls).parameters
            for name in ("serial", "target", "device", "connect_key"):
                if name in params:
                    return driver_cls(**{name: target})
        except Exception as ex:
            print(f">> [DriverManager] Inspect Driver signature failed, fallback to default Driver(): {ex}")
    return driver_cls()

def reset_driver():
    """触发式重置：清理并重新初始化 Driver，丢弃无用的轮询阈值逻辑"""
    global d
    with DEVICE_CONTROL_LOCK:
        try:
            import sys
            normalize_hmdriver_loggers()
            target = get_hdc_target(force=True)
            # 强制把 hmdriver2 相关的模块从缓存中剔除，打破单例
            modules_to_remove = [m for m in list(sys.modules.keys()) if m.startswith('hmdriver2')]
            for m in modules_to_remove:
                del sys.modules[m]
            
            from hmdriver2.driver import Driver
            d = create_driver_for_target(Driver, target)
            normalize_hmdriver_loggers()
            print(">> [系统] 驱动对象 (Driver) 初始化/重置成功！")
        except Exception as ex:
            print(f">> [系统警告] hmdriver2 驱动重置失败: {ex}")
            d = None

def poll_task():
    global LAST_POLL_FPORT_REFRESH
    # 后台轻量轮询 App 当前任务；失败时只刷新端口转发，不重置驱动，避免空闲时卡顿。
    try:
        res = send_request({"type": "poll"})
        data = json.loads(res)
        return data.get("task", "")
    except Exception:
        # 轮询失败（例如设备被刚刚切换，9126 通道断开），仅在此处轻量补发一次端口映射
        # 不连带重置 hmdriver2 驱动（避免没任务时的后台严重卡顿）
        now = time.monotonic()
        if now - LAST_POLL_FPORT_REFRESH >= POLL_FPORT_REFRESH_INTERVAL:
            LAST_POLL_FPORT_REFRESH = now
            refresh_hdc_forwarding()
        return ""

def format_debug_text_block(label, text):
    text = "" if text is None else str(text)
    return (
        f"{label} (len={len(text)})\n"
        f"----- BEGIN RAW -----\n{text}\n----- END RAW -----\n"
        f"{label} repr:\n{text!r}"
    )

def extract_json_payload(raw_text):
    # 模型输出可能包含 markdown、reasoning 文本或畸形 JSON；这里尽量抽取可执行动作对象。
    original_raw_text = "" if raw_text is None else str(raw_text)

    def _repair_leading_broken_object_quote(value):
        # 兼容模型偶发输出：```json\n{"\n  "reasoning": ...}\n```
        # 只删除 { 后面多出来的那个引号；合法的 {"reasoning": ...} 不会命中该规则。
        return re.sub(r'^(\{\s*)"\s*(?="[^"]+"\s*:)', r'\1', value.strip(), count=1)

    def _normalize_candidate_text(value):
        text = "" if value is None else str(value)
        text = text.strip()
        text = re.sub(r'^```(?:json)?\s*', '', text, flags=re.IGNORECASE)
        text = re.sub(r'\s*```$', '', text)
        text = _repair_leading_broken_object_quote(text)
        return text

    def _log_parse_issue(level, reason, cleaned_text=None, partial_data=None):
        messages = [reason, format_debug_text_block("原始响应", original_raw_text)]
        if cleaned_text is not None and cleaned_text != original_raw_text:
            messages.append(format_debug_text_block("清洗后响应", cleaned_text))
        if partial_data is not None:
            try:
                partial_text = json.dumps(partial_data, ensure_ascii=False)
            except Exception:
                partial_text = str(partial_data)
            messages.append(format_debug_text_block("已恢复的部分 JSON", partial_text))
        message = "\n".join(messages)
        if level == "warning":
            logging.warning(message)
        else:
            logging.error(message)

    def _append_candidate(candidates, seen_candidates, value):
        if value is None:
            return
        if not isinstance(value, str):
            try:
                value = json.dumps(value, ensure_ascii=False)
            except Exception:
                value = str(value)

        candidate = _normalize_candidate_text(value)
        if not candidate or candidate in seen_candidates:
            return

        seen_candidates.add(candidate)
        candidates.append(candidate)

    def _collect_wrapped_candidates(candidates, seen_candidates, value, depth=0):
        if value is None or depth > 4:
            return
        if isinstance(value, str):
            _append_candidate(candidates, seen_candidates, value)
            return
        if isinstance(value, list):
            for item in value[:8]:
                _collect_wrapped_candidates(candidates, seen_candidates, item, depth + 1)
            return
        if isinstance(value, dict):
            if "action" in value:
                _append_candidate(candidates, seen_candidates, value)

            wrapper_keys = {
                "response",
                "content",
                "output",
                "text",
                "message",
                "result",
                "data",
                "arguments",
                "tool_input",
                "choices",
                "delta",
            }
            for key, nested_value in value.items():
                if key in wrapper_keys or depth == 0:
                    _collect_wrapped_candidates(candidates, seen_candidates, nested_value, depth + 1)

    if raw_text is None:
        return None

    if not original_raw_text.strip():
        _log_parse_issue("error", "模型返回为空，无法提取 JSON。")
        return None

    raw_text = _normalize_candidate_text(original_raw_text)
    # 清理开头多余的类似 `{"\n\n\n{` 或者 `{"} ` 的结构
    raw_text = re.sub(r'^\{\s*"\s*\}?\s*(?=\{)', '', raw_text)
    # 处理开头是 `{"reasoning"` 结果前面还有额外 `{` 的情况，比如 `{"\n\n{"reasoning"...}`
    raw_text = _repair_leading_broken_object_quote(raw_text)

    text = raw_text.strip()

    # 1) 优先尝试从 ```json ... ``` 代码块中抽取
    block_match = re.search(r'```(?:json)?\s*([\s\S]*?)\s*```', text, re.IGNORECASE)
    candidates = []
    seen_candidates = set()
    if block_match:
        _append_candidate(candidates, seen_candidates, block_match.group(1))
    text = text.replace("…", "...").replace("\r", " ").replace("\n", " ")
    
    # 将包含多余非JSON字符的开头清理掉（比如响应开头包含的 "Otherwise ### Response " 等）
    # 找到第一个出现的 {，在此之前的都切掉
    first_brace = text.find('{')
    if first_brace > 0:
        text = text[first_brace:]

    # 清理开头可能未闭合的 ```json
    text = re.sub(r'^```(?:json)?\s*', '', text, flags=re.IGNORECASE)
    text = re.sub(r'\s*```$', '', text)

    # 修复数组中数字之间漏掉逗号的问题，如 [818, 119, 96 131]
    text = re.sub(r'(\d+)\s+(\d+)', r'\1, \2', text)

    wrapped_payload = None
    try:
        wrapped_payload = json.loads(text)
    except Exception:
        pass

    if isinstance(wrapped_payload, dict):
        if "action" in wrapped_payload:
            _append_candidate(candidates, seen_candidates, wrapped_payload)
        else:
            _collect_wrapped_candidates(candidates, seen_candidates, wrapped_payload)
    elif isinstance(wrapped_payload, (list, str)):
        _collect_wrapped_candidates(candidates, seen_candidates, wrapped_payload)

    _append_candidate(candidates, seen_candidates, text)

    def _attempt_close_truncated_json(candidate):
        candidate = candidate.strip()
        if not candidate or candidate[0] not in '{[':
            return None

        stack = []
        in_str = False
        escape = False
        for ch in candidate:
            if in_str:
                if escape:
                    escape = False
                elif ch == '\\':
                    escape = True
                elif ch == '"':
                    in_str = False
                continue

            if ch == '"':
                in_str = True
            elif ch == '{':
                stack.append('}')
            elif ch == '[':
                stack.append(']')
            elif ch in '}]':
                if not stack or stack[-1] != ch:
                    return None
                stack.pop()

        repaired = candidate.rstrip()
        if repaired.endswith(':'):
            return None
        if repaired.endswith(','):
            repaired = repaired[:-1].rstrip()
        if in_str:
            if escape:
                repaired += '\\'
            repaired += '"'
        while stack:
            repaired = re.sub(r',\s*$', '', repaired)
            repaired += stack.pop()
        return repaired if repaired != candidate else None

    def _extract_partial_object(candidate):
        candidate = candidate.strip()
        if not candidate.startswith('{'):
            return None

        decoder = json.JSONDecoder()
        partial = {}
        idx = 1
        length = len(candidate)

        while idx < length:
            while idx < length and candidate[idx] in ' \t\r\n,':
                idx += 1
            if idx >= length or candidate[idx] == '}':
                break

            try:
                key, idx = decoder.raw_decode(candidate, idx)
            except json.JSONDecodeError:
                break
            if not isinstance(key, str):
                break

            while idx < length and candidate[idx].isspace():
                idx += 1
            if idx >= length or candidate[idx] != ':':
                break
            idx += 1
            while idx < length and candidate[idx].isspace():
                idx += 1
            if idx >= length:
                break

            try:
                value, idx = decoder.raw_decode(candidate, idx)
            except json.JSONDecodeError:
                break

            partial[key] = value

        return partial or None

    def _try_parse(candidate):
        candidate = _normalize_candidate_text(candidate)
        if not candidate:
            return None
        
        # 针对外层包含双大括号的情况进行修复
        if candidate.startswith("{{") and candidate.endswith("}}"):
            candidate = "{" + candidate[2:-2] + "}"

        # # 直接解析
        # try:
        #     return json.loads(candidate)
        # except Exception:
        #     pass
        s = candidate
        try:
            return json.loads(s)
        except json.decoder.JSONDecodeError as e:
            if "Expecting ',' delimiter" in str(e):
                # 定义我们关心的字段名（按可能出现的顺序）
                fields = [
                    "reasoning", "thought", "action", "step", "parameters", "target_element",
                    "app", "target_app", "app_name", "package_name", "bundle", "bundle_name",
                    "final_task_description"
                ]
                field_pattern = '|'.join(re.escape(f) for f in fields)
                
                # 模式1：字段值未闭合（缺少 "）
                # 例如: "reasoning": "内容  "action":

                str_lit = r'"(?:[^"\\]|\\.)*"'

                # 模式1：字段值未闭合（缺少结尾 "）
                # 匹配: "field": "内容...（未闭合）  "next_field":
                pattern1 = rf'("({field_pattern})"\s*:\s*"((?:[^"\\]|\\.)*)?)(\s*"({field_pattern})"\s*:)'
                fixed_s1 = re.sub(pattern1, r'\1",\4', s)  # 补 " 和 ,

                # 模式2：字段值已闭合，但缺逗号
                # 匹配: "field": "完整内容"  "next_field":
                pattern2 = rf'("({field_pattern})"\s*:\s*{str_lit})(\s*"({field_pattern})"\s*:)'
                fixed_s2 = re.sub(pattern2, r'\1,\3', s)   # 只补 ,
                
                # 尝试：先用模式1（更严重），再用模式2
                for candidate in [fixed_s1, fixed_s2]:
                    if candidate != s:  # 确实做了修改
                        try:
                            return json.loads(candidate)
                        except json.JSONDecodeError:
                            continue

                # 如果都不行，再尝试更激进的通用逗号修复（谨慎使用）
                # 例如：匹配 "xxx"  后跟 "yyy": 且中间无逗号
                generic_pattern = r'("[^"]*?")(\s*"[a-zA-Z_][a-zA-Z0-9_]*"\s*:)'
                generic_fixed = re.sub(generic_pattern, r'\1,\2', s)
                if generic_fixed != s:
                    try:
                        return json.loads(generic_fixed)
                    except json.JSONDecodeError:
                        pass

            repaired = _attempt_close_truncated_json(s)
            if repaired and repaired != s:
                try:
                    return json.loads(repaired)
                except json.JSONDecodeError:
                    pass


            # === 修复 2：多余内容（包括多余 }、文字等）===
            if "Extra data" in str(e):
                try:
                    decoder = json.JSONDecoder()
                    obj, end = decoder.raw_decode(s)
                    logging.warning(f"Extra data detected. Parsed valid JSON up to position {end}.")
                    return obj
                except Exception:
                    pass
        
        except Exception as e:
            pass

        # 容错：处理外层双大括号 {{...}}
        fixed = candidate
        for _ in range(2):
            if fixed.startswith("{{") and fixed.endswith("}}"):
                fixed = fixed[1:-1].strip()
                try:
                    return json.loads(fixed)
                except Exception:
                    continue
        return None

    # 2) 先尝试候选整体解析
    for cand in candidates:
        parsed = _try_parse(cand)
        if parsed is not None:
            return parsed

    # 3) 平衡括号扫描，抽取第一个完整 JSON 对象
    for cand in candidates:
        s = cand.strip()
        in_str = False
        escape = False
        depth = 0
        start = -1

        for i, ch in enumerate(s):
            if in_str:
                if escape:
                    escape = False
                elif ch == '\\':
                    escape = True
                elif ch == '"':
                    in_str = False
                continue

            if ch == '"':
                in_str = True
            elif ch == '{':
                if depth == 0:
                    start = i
                depth += 1
            elif ch == '}':
                if depth > 0:
                    depth -= 1
                    if depth == 0 and start != -1:
                        obj_text = s[start:i+1]
                        parsed = _try_parse(obj_text)
                        if parsed is not None:
                            return parsed

    for cand in candidates:
        partial = _extract_partial_object(cand)
        if partial is not None:
            _log_parse_issue(
                "warning",
                "模型返回的 JSON 不完整，已恢复可解析字段。",
                cleaned_text=cand,
                partial_data=partial,
            )
            return partial

    _log_parse_issue("error", "无法在响应中恢复出有效 JSON。", cleaned_text=text)

    return None

def convert_qwen3_coordinates_to_absolute(bbox, width, height, is_bbox=True):
    """
    Convert Qwen normalized coordinates in 0-1000 range to absolute pixels.
    """
    if is_bbox:
        x1, y1, x2, y2 = bbox
        x1 = min(x1, 1000)
        y1 = min(y1, 1000)
        x2 = min(x2, 1000)
        y2 = min(y2, 1000)
        return [
            int(x1 * width / 1000),
            int(y1 * height / 1000),
            int(x2 * width / 1000),
            int(y2 * height / 1000),
        ]

    x, y = bbox
    x = min(x, 1000)
    y = min(y, 1000)
    return [int(x * width / 1000), int(y * height / 1000)]

def press_harmony_key(key_name, fallback_code):
    return run_with_device_control(
        f"press_harmony_key({key_name})",
        lambda: _press_harmony_key_impl(key_name, fallback_code)
    )

def _press_harmony_key_impl(key_name, fallback_code):
    if d:
        try:
            from hmdriver2.keycode import KeyCode
            key_code = getattr(KeyCode, key_name, fallback_code)
        except Exception:
            key_code = fallback_code
        run_driver_call(f"Driver.press_key({key_name})", lambda driver: driver.press_key(key_code))
    else:
        run_hdc_action_command(
            f"keyEvent({key_name})",
            f"{hdc_prefix()} shell uitest uiInput keyEvent {fallback_code}"
        )

def execute_action_and_get_details(plan, img_size=(1000, 1000)):
    return run_with_device_control(
        "execute_action_and_get_details",
        lambda: _execute_action_and_get_details_impl(plan, img_size)
    )

def _execute_action_and_get_details_impl(plan, img_size=(1000, 1000)):
    # 将 Decider JSON 转成真实设备操作。坐标统一按 Qwen/MNN 的 0-1000 归一化格式还原。
    width, height = img_size
    data = extract_json_payload(plan)
    if not isinstance(data, dict):
        print(f"JSON解析失败: {plan}")
        return "error", None
        
    action = data.get("action")
    params = data.get("parameters", data.get("coordinates", {}))

    if not action:
        print(format_debug_text_block(">> [Agent] 缺少 action 字段，已按解析错误处理", json.dumps(data, ensure_ascii=False)))
        return "error", data
    
    print(f">> [Agent] Action: {action}, Params: {params}")
    action = str(action).lower()

    if action in ["done", "stop", "terminate"]:
        return action, params
    
    if action == "click":
        if params.get("coords"):
            x, y = convert_qwen3_coordinates_to_absolute(params["coords"], width, height, is_bbox=False)
        else:
            bbox = params.get("bbox")
            if not bbox:
                raise ValueError("Click action missing required parameter: 'bbox' or 'coords'")
            abs_bbox = convert_qwen3_coordinates_to_absolute(bbox, width, height)
            x1, y1, x2, y2 = abs_bbox
            x, y = (x1 + x2) // 2, (y1 + y2) // 2

        if d:
            run_driver_call("Driver.click", lambda driver: driver.click(int(x), int(y)))
        else:
            run_hdc_action_command(
                "decider click",
                f"{hdc_prefix()} shell uitest uiInput click {int(x)} {int(y)}"
            )
        time.sleep(DEVICE_WAIT_TIME)
        
    elif action == "click_input":
        text = params.get("text", "")
        if params.get("coords"):
            px, py = convert_qwen3_coordinates_to_absolute(params["coords"], width, height, is_bbox=False)
        else:
            bbox = params.get("bbox")
            if not bbox:
                raise ValueError("Click_input action missing required parameter: 'bbox' or 'coords'")
            abs_bbox = convert_qwen3_coordinates_to_absolute(bbox, width, height)
            x1, y1, x2, y2 = abs_bbox
            px, py = (x1 + x2) // 2, (y1 + y2) // 2
            params["abs_bbox"] = abs_bbox # For history tracking
            
        if d:
            print(f">> [Agent] Clicking at {px}, {py}")
            run_driver_call("Driver.click", lambda driver: driver.click(px, py))
            time.sleep(DEVICE_WAIT_TIME)
            run_driver_call("Driver.shell(clear_input)", lambda driver: driver.shell("uitest uiInput keyEvent 2072 2017"))
            run_driver_call("Driver.press_key(2071)", lambda driver: driver.press_key(2071))
            run_driver_call("Driver.input_text", lambda driver: driver.input_text(text))
            press_harmony_key("ENTER", 2054)
        else:
            run_hdc_action_command(
                "decider click_input click",
                f"{hdc_prefix()} shell uitest uiInput click {px} {py}"
            )
            time.sleep(DEVICE_WAIT_TIME)
            run_hdc_action_command(
                "decider click_input text",
                hdc_input_text_command(text)
            )
        
    elif action == "swipe":
        # 优先支持显式起止坐标；缺省时按方向使用屏幕比例坐标，适配不同分辨率。
        start_coords = params.get("start_coords")
        end_coords = params.get("end_coords")
        if start_coords and end_coords:
            sx, sy = convert_qwen3_coordinates_to_absolute(start_coords, width, height, is_bbox=False)
            ex, ey = convert_qwen3_coordinates_to_absolute(end_coords, width, height, is_bbox=False)
            print(f">> Swipe from [{sx}, {sy}] to [{ex}, {ey}]")
            if d:
                run_driver_call("Driver.swipe", lambda driver: driver.swipe(int(sx), int(sy), int(ex), int(ey), speed=1000))
            else:
                run_hdc_action_command(
                    "decider swipe coords",
                    f"{hdc_prefix()} shell uitest uiInput swipe {int(sx)} {int(sy)} {int(ex)} {int(ey)}"
                )
        else:
            direction = params.get("direction", "UP")
            print(f">> Swipe direction: {direction}")
            direction_lower = direction.lower()
            if d:
                if direction_lower == "up":
                    run_driver_call("Driver.swipe(up)", lambda driver: driver.swipe(0.5, SWIPE_V_END, 0.5, SWIPE_V_START, speed=1000))
                elif direction_lower == "down":
                    run_driver_call("Driver.swipe(down)", lambda driver: driver.swipe(0.5, SWIPE_V_START, 0.5, SWIPE_V_END, speed=1000))
                elif direction_lower == "left":
                    run_driver_call("Driver.swipe(left)", lambda driver: driver.swipe(SWIPE_H_END, 0.5, SWIPE_H_START, 0.5, speed=1000))
                elif direction_lower == "right":
                    run_driver_call("Driver.swipe(right)", lambda driver: driver.swipe(SWIPE_H_START, 0.5, SWIPE_H_END, 0.5, speed=1000))
                else:
                    raise ValueError(f"Unknown swipe direction: {direction}")
            else:
                if direction_lower == "up":
                    sx, sy, ex, ey = 0.5 * width, SWIPE_V_END * height, 0.5 * width, SWIPE_V_START * height
                elif direction_lower == "down":
                    sx, sy, ex, ey = 0.5 * width, SWIPE_V_START * height, 0.5 * width, SWIPE_V_END * height
                elif direction_lower == "left":
                    sx, sy, ex, ey = SWIPE_H_END * width, 0.5 * height, SWIPE_H_START * width, 0.5 * height
                elif direction_lower == "right":
                    sx, sy, ex, ey = SWIPE_H_START * width, 0.5 * height, SWIPE_H_END * width, 0.5 * height
                else:
                    raise ValueError(f"Unknown swipe direction: {direction}")
                run_hdc_action_command(
                    "decider swipe direction",
                    f"{hdc_prefix()} shell uitest uiInput swipe {int(sx)} {int(sy)} {int(ex)} {int(ey)}"
                )
            
    elif action == "input":
        text = params.get("text", "")
        print(f">> Input Text: {text}")
        if d:
            run_driver_call("Driver.shell(clear_input)", lambda driver: driver.shell("uitest uiInput keyEvent 2072 2017"))
            run_driver_call("Driver.press_key(2071)", lambda driver: driver.press_key(2071))
            run_driver_call("Driver.input_text", lambda driver: driver.input_text(text))
            # Press Enter key to confirm input
            try:
                from hmdriver2.keycode import KeyCode
                run_driver_call("Driver.press_key(ENTER)", lambda driver: driver.press_key(KeyCode.ENTER))
            except ImportError:
                # fallback to hardcoded ENTER key event or 2054
                run_driver_call("Driver.press_key(2054)", lambda driver: driver.press_key(2054))
        else:
            run_hdc_action_command(
                "decider input text",
                hdc_input_text_command(text)
            )

    elif action == "open_app":
        app_name = params.get("app_name", "")
        if not app_name:
            raise ValueError("Open_app action missing required parameter: 'app_name'")
        launch_app(app_name)

    elif action == "press_home":
        press_harmony_key("HOME", 1)

    elif action == "press_back":
        press_harmony_key("BACK", 2)

    elif action == "wait":
        seconds = float(params.get("seconds", DEVICE_WAIT_TIME * 2))
        print(f">> Wait for {seconds} seconds")
        time.sleep(seconds)

    else:
        raise ValueError(f"Unknown action: {action}")

    return action, params

# ===================== Stage 1: Planner =====================
def run_planner(task):
    # Stage 1：纯文本 Planner 只负责判断要打开哪个 App，不参与后续屏幕动作决策。
    template = load_prompt("planner_oneshot_harmony.md")
    if not template:
        template = load_prompt("planner.md")
        
    # 组装纯文本 Prompt (替换可能存在的占位符，或者直接拼接)
    prompt = template.replace("{task_description}", task).replace("<task_description>", task)
    if task not in prompt:
        prompt += f"\n\n用户任务: {task}"
        
    print(f">> [Stage 1 - Planner] 发送纯文本任务分析请求...")
    res = send_request({
        "type": "action",
        "prompt": prompt
        # 注意：这里不传 image_b64，从而让手机侧 AgentRouterServer 走纯文本 planner 路径
    })
    
    print(format_debug_text_block(">> [Planner] MNN VLM 返回", res))
    sys.stdout.flush()
    
    try:
        data = extract_json_payload(res)
        if not isinstance(data, dict):
            raise ValueError("planner output is not a JSON object")
        action = str(data.get("action", "")).lower()
        if action in ["terminate", "stop"]:
            print(">> [Planner] Task cancelled by user.")
            return "__USER_CANCELLED__"
        # 兼容多种常见的键名
        app_name = data.get("app") or data.get("target_app") or data.get("app_name")
        package_name = data.get("package_name") or data.get("bundle") or data.get("bundle_name")
        if app_name:
            return app_name
        if package_name:
            print(f">> [Planner] 未返回 App 名称，直接使用包名: {package_name}")
            return package_name
        raise ValueError("planner output missing app_name/package_name")
    except Exception as ex:
        error_message = f"Planner 阶段失败，终止本次任务，不再执行 Decider: {ex}"
        print(">> [Planner][ERROR] " + error_message)
        logging.error(error_message)
        raise RuntimeError(error_message) from ex

def launch_app(app_name, reset_first=True):
    return run_with_device_control(
        "launch_app",
        lambda: _launch_app_impl(app_name, reset_first)
    )

def _launch_app_impl(app_name, reset_first=True):
    # Planner 可能返回中文 App 名，也可能直接返回 bundleName；两种都兼容。
    if not app_name:
        return False
        
    print(f">> [Planner] 准备拉起目标 App: {app_name}")
    bundle = APP_MAPPING.get(app_name)
    if not bundle and isinstance(app_name, str) and "." in app_name:
        bundle = app_name
    
    if bundle:
        ability_name = get_main_ability_for_bundle(bundle)
        if reset_first:
            stop_app_before_launch(bundle)
        if start_app_with_explicit_ability(bundle, ability_name):
            return True

        if ensure_driver_available():
            print(f">> 执行启动命令 (hmdriver2 fallback): force_start_app({bundle})")
            run_driver_call("Driver.force_start_app", lambda driver: driver.force_start_app(bundle))
            return True

        # Last-resort fallback for environments without hmdriver2.
        if bundle == "com.taobao.taobao4hmos":
            cmd = f"{hdc_prefix()} shell aa start -b {bundle} -a Taobao_mainAbility"
        else:
            cmd = f"{hdc_prefix()} shell aa start -b {bundle}"
        print(f">> 执行启动命令 (hdc fallback): {cmd}")
        try:
            result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=HDC_ACTION_TIMEOUT)
        except subprocess.TimeoutExpired:
            print(f">> [HDC warning] launch_app fallback timed out after {HDC_ACTION_TIMEOUT}s: {cmd}")
            return False
        if result.returncode == 0:
            time.sleep(APP_LAUNCH_WAIT_TIME)
            return True
        print(result.stderr.strip() or result.stdout.strip() or f">> [启动警告] HDC fallback failed: {result.returncode}")
        return False
    else:
        print(f">> [警告] 未在 APP_MAPPING 字典中找到 '{app_name}' 的包名映射，将尝试留在当前界面执行。")
        return False

# ===================== Stage 2: Task in App =====================
def run_task_in_app_agent(task):
    """Agent mode with prefix KV cache reuse. Fixed prefix is prefilled once,
    each step only prefills the variable part (action history + screenshot)."""
    global LAST_TASK_COMPLETED
    LAST_TASK_COMPLETED = False
    history_list = []

    # 1. 构造固定 prefix 并让端侧模型预填 KV；后续循环只发送 variable 部分。
    prefix_file = "e2e_v2_agent_prefix_noreason.md" if NO_REASON_MODE else "e2e_v2_agent_prefix.md"
    prefix_template = load_prompt(prefix_file)
    if not prefix_template:
        print(">> [Agent] 找不到 prefix 模板，回退到普通模式")
        return run_task_in_app(task)

    prefix = prefix_template.replace("{task}", task)
    print(f">> [Agent] Prefilling prefix ({len(prefix)} chars)...")
    prefill_res = send_request({"type": "agent_prefill", "prefix": prefix})
    if is_cancelled_status_response(prefill_res):
        print(">> [Agent] Task cancelled by user during prefill.")
        return
    print(f">> [Agent] Prefill result: {prefill_res}")
    is_cloud_qwen_mode = "cloud qwen prompt mode" in prefill_res
    screenshot_factor = 0.5 if is_cloud_qwen_mode else 0.25
    inverse_screenshot_factor = int(round(1 / screenshot_factor))
    print(f">> [Agent] Screenshot resize factor: {screenshot_factor}")

    variable_file = "e2e_v2_agent_variable_noreason.md" if NO_REASON_MODE else "e2e_v2_agent_variable.md"
    variable_template = load_prompt(variable_file)
    if not variable_template:
        print(">> [Agent] 找不到 variable 模板，回退到普通模式")
        send_request_best_effort({"type": "agent_reset"}, "Agent fallback reset")
        return run_task_in_app(task)

    # 2. 截图-推理-执行循环。每一轮都把动作摘要写入 history，减少重复操作。
    for step_idx in range(MAX_STEPS):
        print(f"\n--- [Agent Step {step_idx+1}/{MAX_STEPS}] ---")

        if is_cloud_qwen_mode:
            b64, w, h = capture_screen_mobiagent_style(screenshot_factor)
        else:
            b64, w, h = capture_screen(screenshot_factor)
        history_str = "  ".join(history_list) if history_list else "(No history)"

        variable = variable_template.replace("{history}", history_str)

        print(f">> [Agent] Sending step request (history: {len(history_list)} entries)...")
        step_request = {
            "type": "agent_step",
            "variable": variable,
            "image_b64": b64,
            "width": w,
            "height": h
        }
        res = send_request_retry_empty(step_request, context="Agent step")

        print(format_debug_text_block(">> [Agent] Response", res))
        sys.stdout.flush()
        time.sleep(0.3)

        w_full = w * inverse_screenshot_factor
        h_full = h * inverse_screenshot_factor
        img_size = (w_full, h_full)
        action, params = execute_action_and_get_details(res, img_size=img_size)

        if action in ["done", "stop", "terminate"]:
            print(">> [Agent] Task completed!")
            LAST_TASK_COMPLETED = True
            break
        elif action == "error":
            print(">> [Agent] Parse error, aborting.")
            raise RuntimeError("Agent response parse failed")

        if is_cloud_qwen_mode:
            send_request_best_effort({"type": "cloud_history_append", "response": res}, "Cloud history append")
        else:
            # 把解析到的 JSON 内容也追加到历史，便于后续推理使用
            parsed_data = extract_json_payload(res)
            try:
                data_str = json.dumps(parsed_data, ensure_ascii=False)
            except Exception:
                data_str = str(parsed_data)
            # history_list.append(f"{step_idx+1}. {data_str}\n")
            history_list.append(f"{step_idx+1}: Action={action}")

        if history_list:
            print (f"[Agent] Appended JSON data to history: {history_list[-1]}")
        time.sleep(0.7)

    # 3. 收尾重置 Agent 模式，释放端侧 KV 复用状态。
    print(">> [Agent] Resetting agent mode...")
    send_request_best_effort({"type": "agent_reset"}, "Agent 模式收尾重置")


def run_task_in_app(task):
    # 旧版普通模式：每一步发送完整图文 prompt，不做 prefix KV 复用，便于 fallback/debug。
    global LAST_TASK_COMPLETED
    LAST_TASK_COMPLETED = False
    history_list = []

    template = load_prompt("e2e_v2.md")
    if not template:
        # Fallback 的极简模板
        template = "任务目标: {task}\n历史记录: {history}\n请分析当前屏幕截图，按照要求严格输出JSON，包含reasoning, action (click/swipe/input/done), parameters。"
        
    for step_idx in range(MAX_STEPS):
        print(f"\n--- [Stage 2 - Task in App] 步骤 {step_idx+1}/{MAX_STEPS} ---")
        
        b64, w, h = capture_screen()
        
        # 格式化历史记录
        history_str = "\n".join(history_list) if history_list else "None"
        
        # 组装带历史记录的多模态 Prompt
        prompt = template.replace("{task}", task).replace("<task>", task)
        prompt = prompt.replace("{history}", history_str).replace("<history>", history_str)
        if "{history_str}" in prompt: 
            prompt = prompt.replace("{history_str}", history_str)
        
        print(f">> 发送多模态请求到手机 MNN VLM 正在思考 (包含 {len(history_list)} 条历史记录)...")
        res = send_request({
            "type": "action",
            "prompt": prompt,
            "image_b64": b64,
            "width": w,
            "height": h
        })
        
        print(format_debug_text_block(">> MNN VLM 返回", res))
        sys.stdout.flush()
        time.sleep(0.3)
        w = w * 4
        h = h * 4
        # Pass current screenshot size for coordinate conversion
        img_size = (w, h) 
        action, params = execute_action_and_get_details(res, img_size=img_size)
        
        if action in ["done", "stop", "terminate"]:
            print(">> [Task in App] 任务执行完毕！")
            break
        elif action == "error":
            print(">> [Task in App] 解析出错，终止。")
            break
            
        # 将本次操作追加到历史记录中，供下一步使用；同时记录解析到的 JSON
        parsed_data = extract_json_payload(res)
        try:
            data_str = json.dumps(parsed_data, ensure_ascii=False)
        except Exception:
            data_str = str(parsed_data)
        # history_list.append(f"{step_idx+1}. {data_str}\n")
        
        history_list.append(f"{step_idx+1}: Action={action}")

        # history_list.append(f"Step {step_idx+1}: Action={action}, Params={params}")
        
        time.sleep(0.7)

# ===================== Main Loop =====================
def run_agent_loop(stop_event=None):
    global LAST_TASK_COMPLETED
    if stop_event is None:
        stop_event = AGENT_LOOP_STOP_EVENT
    reset_agent_loop_stop()

    print("初始化 HDC 端口转发...")
    # 由于该脚本可能被多次重启或前置 HDC 挂载占用，先强制清理端口再映射，防止冲突
    forward_result = refresh_hdc_forwarding(verbose=True)
    if forward_result == 0:
        print(">> 监听模式已启动。等待手机 APP 端派发任务...")
    else:
        print(">> 监听模式暂未就绪：请先完成 HDC 手动配置，再从手机 App 重新触发任务。")
    
    active_task = ""
    
    while not stop_event.is_set() and not AGENT_LOOP_STOP_EVENT.is_set():
        task_finished = False
        try:
            task = poll_task()
            if not task:
                # 清理无任务时的状态
                if active_task:
                    print(">> 任务已被重置或结束。")
                    active_task = ""
                if stop_event.wait(2) or AGENT_LOOP_STOP_EVENT.is_set():
                    break
                continue
                
            if task != active_task:
                print(f"\n>>>>>>>> 开始新任务: {task} <<<<<<<<")
                active_task = task
                
                # 【触发式逻辑】在执行真正的新任务开始前，确保设备端口及驱动是健康状态
                print(">> [环境就绪准备] 刷新 HDC 端口并初始化 hmdriver2 驱动...")
                refresh_hdc_forwarding()
                reset_driver()
                
                # 1. 确保 App 端任务和模型上下文干净；preserve_execution 保留浮窗执行态。
                send_request_best_effort({"type": "clear", "preserve_execution": True}, "任务开始前清理状态")
                
                # 2. Stage 1：Planner 解析意图并启动目标 App。
                app_name = run_planner(task)
                if app_name == "__USER_CANCELLED__":
                    print(">> [Planner] 用户取消任务，跳过后续 Decider。")
                else:
                    if not app_name:
                        raise RuntimeError("Planner 未返回目标 App，终止本次任务，不再执行 Decider")
                    success = launch_app(app_name)
                    if success:
                        print(">> 等待 App 启动加载完成...")
                        time.sleep(0.3)
                    
                    # 3. 再次清空上下文，隔离 Planner 的纯文本历史和后续图文历史。
                    send_request_best_effort({"type": "clear", "preserve_execution": True}, "Planner 后清理上下文")

                    # 4. Stage 2：任务在目标 App 内循环执行。
                    if USE_AGENT_MODE:
                        run_task_in_app_agent(task)
                    else:
                        run_task_in_app(task)
                task_finished = True
                bring_llm_app_to_foreground()
                
                # 6. 任务全部结束，清除手机端状态
                print(">> 当前任务流程已全部结束，清理状态并等待下一个任务...")
                send_request_best_effort({"type": "clear"}, "任务结束后清理状态")
                active_task = ""
                
        except Exception as e:
            err_msg = str(e)
            if (task_finished or LAST_TASK_COMPLETED) and is_connection_closed_error(err_msg):
                print(f"\n>> [提示] 任务已完成，收尾连接被 App/HDC 关闭：{err_msg}")
                active_task = ""
                LAST_TASK_COMPLETED = False
                continue
            print(f"\n>> [错误重启] 任务执行过程中发生异常: {err_msg}")
            
            # 如果中间执行阶段底层管道破裂（手机刚刚拔下等），主动重置以便不卡死
            if "broken pipe" in err_msg.lower() or "104" in err_msg or "32" in err_msg:
                print(">> [自愈] 检测到设备掉线(Broken Pipe)！")
                reset_driver()
                    
            try:
                # 尝试把界面回到应用, 并在 app 中显示异常
                bring_llm_app_to_foreground()
                send_request_best_effort({"type": "error", "message": f"任务执行出错: {err_msg}"}, "错误状态上报")
            except Exception:
                pass
            active_task = ""
            print(">> 状态已清理，将避免服务完全退出，准备继续接收后续任务。")
            
        if stop_event.wait(2) or AGENT_LOOP_STOP_EVENT.is_set():
            break

    print(">> Agent loop stopped.")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--no_reason", action="store_true", help="Use prompts without reasoning")
    args = parser.parse_args()
    set_no_reason_mode(args.no_reason)
    run_agent_loop()
