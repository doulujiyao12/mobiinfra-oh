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

try:
    from hmdriver2.driver import Driver
    # Some common hmdriver2 setups
    d = Driver()
except ImportError:
    print(">> [警告] 无法导入 hmdriver2，请确保它已经安装。")
    d = None

PORT = 9126
HOST = '127.0.0.1'
PROMPTS_DIR = os.path.join(os.path.dirname(__file__), "prompts")

# Agent mode toggle: True = prefix KV cache reuse, False = original chat-based flow
USE_AGENT_MODE = True

# 常数定义
MAX_STEPS = 15
MAX_RETRIES = 5
TEMP_INCREMENT = 0.1
INITIAL_TEMP = 0.0
API_TIMEOUT = 30
DECIDER_MAX_TOKENS = 256
GROUNDER_MAX_TOKENS = 128
DEVICE_WAIT_TIME = 0.5
APP_STOP_WAIT = 3

# 滑动坐标缩放比例
SWIPE_V_START = 0.3
SWIPE_V_END = 0.7
SWIPE_H_START = 0.3
SWIPE_H_END = 0.7

# LLM Agent 包名
LLM_APP_BUNDLE = "com.example.mnnllmchat"
LLM_APP_ABILITY = "EntryAbility"

def bring_llm_app_to_foreground():
    print(">> 任务结束/出错，正在自动跳回 MNN LLM Chat App...")
    if d:
        d.force_start_app(LLM_APP_BUNDLE)
    else:
        os.system(f"hdc shell aa start -b {LLM_APP_BUNDLE} -a {LLM_APP_ABILITY}")
    time.sleep(1)
APP_MAPPING = {
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
    "拼多多": "com.xunmeng.pinduoduo.hos"
}

def load_prompt(filename):
    path = os.path.join(PROMPTS_DIR, filename)
    if not os.path.exists(path):
        print(f">> [警告] 找不到 Prompt 模板文件: {path}")
        return ""
    with open(path, 'r', encoding='utf-8') as f:
        return f.read()

def run_cmd(cmd):
    return subprocess.check_output(cmd, shell=True, text=True)

def capture_screen():
    print(">> Capturing screen via hdc...")
    local_path = "screen.jpeg"
    
    # 截取屏幕并提取鸿蒙实际为你随机生成的文件名 (忽略大小写)
    output = subprocess.check_output("hdc shell snapshot_display", shell=True, text=True)
    match = re.search(r'(?i)write to\s+(/\S+\.jpeg)', output)
    
    if match:
        device_path = match.group(1)
    else:
        # Fallback 尝试捕捉任意带路径的 .jpeg 输出
        match_fallback = re.search(r'(/\S+\.jpeg)', output)
        if match_fallback:
            device_path = match_fallback.group(1)
        else:
            device_path = "/data/local/tmp/screen.jpeg"
            os.system(f"hdc shell snapshot_display {device_path}")
            
    # 先删除电脑端旧文件，防止拉取失败时继续读取旧图片
    if os.path.exists(local_path):
        os.remove(local_path)
        
    # 下拉截图到电脑（使用跨平台无输出模式，解决 Linux/zsh/win 下的 >nul 问题）
    subprocess.run(f"hdc file recv {device_path} {local_path}", shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    
    if not os.path.exists(local_path):
        print(f">> [致命错误] 从手机拉取截图失败! 无法找到 {local_path}。HDC可能卡死了，手机路径为: {device_path}")
        time.sleep(2)
        # 兜底返回空或者抛出异常都可以
    
    # 拉取后顺手把手机里的临时文件删掉，防止手机空间爆满
    subprocess.run(f"hdc shell rm \"{device_path}\"", shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    
    img = Image.open(local_path)
    w, h = img.size
    
    # 为了减少网络传输压力和内存占用，进行缩小
    factor = 0.25
    new_w, new_h = int(w * factor), int(h * factor)
    img = img.resize((new_w, new_h), Image.Resampling.LANCZOS)
    
    buffered = io.BytesIO()
    img.save(buffered, format="JPEG")
    b64 = base64.b64encode(buffered.getvalue()).decode("utf-8")
    
    return b64, new_w, new_h

def send_request(req):
    payload = json.dumps(req) + "<<EOF>>"
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.connect((HOST, PORT))
    except Exception as e:
        # 当轮询（poll）未连上时保持静默，只有其他核心请求断开时才打印错误，防止刷屏。
        if req.get("type") != "poll":
            print(">> 【错误】无法连接到手机 App端，请检查: \n1. 是否在手机App上点击了'启动 PC 控制后端(HDC)'\n2. HDC 是否正常工作\n" + str(e))
        raise e
        
    s.sendall(payload.encode('utf-8'))
    
    buffer = ""
    while True:
        data = s.recv(4096)
        if not data:
            break
        buffer += data.decode('utf-8')
        if "<<EOF>>" in buffer:
            break
            
    s.close()
    res = buffer.split("<<EOF>>")[0]
    return res

def reset_driver():
    """触发式重置：清理并重新初始化 Driver，丢弃无用的轮询阈值逻辑"""
    global d
    try:
        import sys
        # 强制把 hmdriver2 相关的模块从缓存中剔除，打破单例
        modules_to_remove = [m for m in list(sys.modules.keys()) if m.startswith('hmdriver2')]
        for m in modules_to_remove:
            del sys.modules[m]
            
        from hmdriver2.driver import Driver
        d = Driver()
        print(">> [系统] 驱动对象 (Driver) 初始化/重置成功！")
    except Exception as ex:
        print(f">> [系统警告] hmdriver2 驱动重置失败: {ex}")
        d = None

def poll_task():
    try:
        res = send_request({"type": "poll"})
        data = json.loads(res)
        return data.get("task", "")
    except:
        # 轮询失败（例如设备被刚刚切换，9126 通道断开），仅在此处轻量补发一次端口映射
        # 不连带重置 hmdriver2 驱动（避免没任务时的后台严重卡顿）
        os.system(f"hdc fport rm tcp:{PORT} tcp:{PORT} 2>/dev/null")
        os.system(f"hdc fport tcp:{PORT} tcp:{PORT} >/dev/null 2>&1")
        return ""

def extract_json_payload(raw_text):
    if not raw_text:
        return None

    raw_text = raw_text.strip()
    # 清理开头多余的类似 `{"\n\n\n{` 或者 `{"} ` 的结构
    raw_text = re.sub(r'^\{\s*"\s*\}?\s*(?=\{)', '', raw_text)
    # 处理开头是 `{"reasoning"` 结果前面还有额外 `{` 的情况，比如 `{"\n\n{"reasoning"...}`
    raw_text = re.sub(r'^\{\s*"\s*(?=")', '', raw_text)

    text = raw_text.strip()

    

    # 1) 优先尝试从 ```json ... ``` 代码块中抽取
    block_match = re.search(r'```(?:json)?\s*([\s\S]*?)\s*```', text, re.IGNORECASE)
    candidates = []
    if block_match:
        candidates.append(block_match.group(1).strip())
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
    candidates.append(text)

    def _try_parse(candidate):
        candidate = candidate.strip()
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
                fields = ["reasoning", "thought", "action", "step", "parameters", "target_element"]
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
                    except:
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
            
            # 所有修复失败，报错
            logging.error(f"解析 decider_response_str 失败: {e}\n原始内容: {s}")
            raise
        
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

    return None

def convert_qwen3_coordinates_to_absolute(bbox, width, height, is_bbox=True):
    """
    Convert Qwen/MNN VLM normalized coordinates [y1, x1, y2, x2] (0-1000) 
    to absolute pixel coordinates [x1, y1, x2, y2].
    """
    x1, y1, x2, y2 = bbox
    x1 = min(x1, 1000)
    y1 = min(y1, 1000)
    x2 = min(x2, 1000)
    y2 = min(y2, 1000)
    abs_x1 = int(x1 * width / 1000)
    abs_y1 = int(y1 * height / 1000)
    abs_x2 = int(x2 * width / 1000)
    abs_y2 = int(y2 * height / 1000)
    return [abs_x1, abs_y1, abs_x2, abs_y2]

def execute_action_and_get_details(plan, img_size=(1000, 1000)):
    width, height = img_size
    data = extract_json_payload(plan)
    if not isinstance(data, dict):
        print(f"JSON解析失败: {plan}")
        return "error", None
        
    action = data.get("action")
    params = data.get("parameters", data.get("coordinates", {}))
    
    print(f">> [Agent] Action: {action}, Params: {params}")
    
    if action == "click":
        bbox = params.get("bbox")
        if bbox:
            abs_bbox = convert_qwen3_coordinates_to_absolute(bbox, width, height)
            x1, y1, x2, y2 = abs_bbox
            x, y = (x1 + x2) // 2, (y1 + y2) // 2

        if d:
            d.click(int(x), int(y))
        else:
            os.system(f"hdc shell uitest uiInput click {int(x)} {int(y)}")
        time.sleep(DEVICE_WAIT_TIME)
        
    elif action == "click_input":
        text = params.get("text", "")
        bbox = params.get("bbox")
        if bbox:
            abs_bbox = convert_qwen3_coordinates_to_absolute(bbox, width, height)
            x1, y1, x2, y2 = abs_bbox
            px, py = (x1 + x2) // 2, (y1 + y2) // 2
            
            if d:
                print(f">> [Agent] Clicking at {px}, {py}")
                d.click(px, py)
                time.sleep(DEVICE_WAIT_TIME)
                # Input logic
                d.shell("uitest uiInput keyEvent 2072 2017")
                d.press_key(2071)
                d.input_text(text)
                try:
                    from hmdriver2.keycode import KeyCode
                    d.press_key(KeyCode.ENTER)
                except:
                    d.press_key(2054)
            else:
                os.system(f"hdc shell uitest uiInput click {px} {py}")
                time.sleep(DEVICE_WAIT_TIME)
                os.system(f"hdc shell uitest uiInput inputText '{text}'")
            
            params["abs_bbox"] = abs_bbox # For history tracking
        
    elif action == "swipe":
        direction = params.get("direction")
        if direction:
            print(f">> Swipe direction: {direction}")
            if d:
                # Based on the user provided swipe implementations
                if direction.lower() == "up":
                    d.swipe(0.5, SWIPE_V_END, 0.5, SWIPE_V_START, speed=1000)
                elif direction.lower() == "down":
                    d.swipe(0.5, SWIPE_V_START, 0.5, SWIPE_V_END, speed=1000)
                elif direction.lower() == "left":
                    d.swipe(SWIPE_H_END, 0.5, SWIPE_H_START, 0.5, speed=1000)
                elif direction.lower() == "right":
                    d.swipe(SWIPE_H_START, 0.5, SWIPE_H_END, 0.5, speed=1000)
            else:
                print(f"Swipe {direction} 暂未通过 hdc 实现")
        else:
            sx, sy = params.get("startX", 0), params.get("startY", 0)
            ex, ey = params.get("endX", 0), params.get("endY", 0)
            if d:
                d.swipe(int(sx), int(sy), int(ex), int(ey), speed=1000)
            else:
                os.system(f"hdc shell uitest uiInput swipe {int(sx)} {int(sy)} {int(ex)} {int(ey)}")
            
    elif action == "input":
        text = params.get("text", "")
        print(f">> Input Text: {text}")
        if d:
            d.shell("uitest uiInput keyEvent 2072 2017")
            d.press_key(2071)
            d.input_text(text)
            # Press Enter key to confirm input
            try:
                from hmdriver2.keycode import KeyCode
                d.press_key(KeyCode.ENTER)
            except ImportError:
                # fallback to hardcoded ENTER key event or 2054
                d.press_key(2054)
        else:
            os.system(f"hdc shell uitest uiInput inputText '{text}'")

    return action, params

# ===================== Stage 1: Planner =====================
def run_planner(task):
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
        # 注意：这里不传 image_b64，从而让 LlmServer.ets 只作为纯文本推理
    })
    
    print(f">> [Planner] MNN VLM 返回:\n{res}")
    sys.stdout.flush()
    
    try:
        data = extract_json_payload(res)
        if not isinstance(data, dict):
            raise ValueError("planner output is not a JSON object")
        # 兼容多种常见的键名
        app_name = data.get("app") or data.get("target_app") or data.get("app_name")
        return app_name
    except:
        print(">> [Planner] 解析目标 App 名称失败，使用原界面进行 fallback。")
        return None

def launch_app(app_name):
    if not app_name:
        return False
        
    print(f">> [Planner] 准备拉起目标 App: {app_name}")
    bundle = APP_MAPPING.get(app_name)
    
    if bundle:
        if d:
            print(f">> 执行启动命令 (hmdriver2): force_start_app({bundle})")
            d.force_start_app(bundle)
        else:
            # 兼容旧的 HDC 启动方式作为 Fallback
            if bundle == "com.taobao.taobao4hmos":
                cmd = f"hdc shell aa start -b {bundle} -a Taobao_mainAbility"
            else:
                cmd = f"hdc shell aa start -b {bundle}"
            print(f">> 执行启动命令 (hdc): {cmd}")
            os.system(cmd)
            
        time.sleep(1.5)
        return True
    else:
        print(f">> [警告] 未在 APP_MAPPING 字典中找到 '{app_name}' 的包名映射，将尝试留在当前界面执行。")
        return False

# ===================== Stage 2: Task in App =====================
def run_task_in_app_agent(task):
    """Agent mode with prefix KV cache reuse. Fixed prefix is prefilled once,
    each step only prefills the variable part (action history + screenshot)."""
    history_list = []

    # 1. Build and send prefix (fixed across all steps)
    prefix_template = load_prompt("e2e_v2_agent_prefix.md")
    if not prefix_template:
        print(">> [Agent] 找不到 prefix 模板，回退到普通模式")
        return run_task_in_app(task)

    prefix = prefix_template.replace("{task}", task)
    print(f">> [Agent] Prefilling prefix ({len(prefix)} chars)...")
    prefill_res = send_request({"type": "agent_prefill", "prefix": prefix})
    print(f">> [Agent] Prefill result: {prefill_res}")

    variable_template = load_prompt("e2e_v2_agent_variable.md")
    if not variable_template:
        print(">> [Agent] 找不到 variable 模板，回退到普通模式")
        send_request({"type": "agent_reset"})
        return run_task_in_app(task)

    # 2. Step loop
    for step_idx in range(MAX_STEPS):
        print(f"\n--- [Agent Step {step_idx+1}/{MAX_STEPS}] ---")

        b64, w, h = capture_screen()
        history_str = "  ".join(history_list) if history_list else "(No history)"

        variable = variable_template.replace("{history}", history_str)

        print(f">> [Agent] Sending step request (history: {len(history_list)} entries)...")
        res = send_request({
            "type": "agent_step",
            "variable": variable,
            "image_b64": b64,
            "width": w,
            "height": h
        })

        print(f">> [Agent] Response:\n{res}")
        sys.stdout.flush()
        time.sleep(0.3)

        w_full = w * 4
        h_full = h * 4
        img_size = (w_full, h_full)
        action, params = execute_action_and_get_details(res, img_size=img_size)

        if action in ["done", "stop", "terminate"]:
            print(">> [Agent] Task completed!")
            break
        elif action == "error":
            print(">> [Agent] Parse error, aborting.")
            break

        history_list.append(f"Step {step_idx+1}: Action={action}")
        time.sleep(1.7)

    # 3. Cleanup agent mode
    print(">> [Agent] Resetting agent mode...")
    send_request({"type": "agent_reset"})


def run_task_in_app(task):
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
        
        print(f">> MNN VLM 返回:\n{res}")
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
            
        # 将本次操作追加到历史记录中，供下一步使用
        history_list.append(f"Step {step_idx+1}: Action={action}")

        # history_list.append(f"Step {step_idx+1}: Action={action}, Params={params}")
        
        time.sleep(1.7)

# ===================== Main Loop =====================
if __name__ == "__main__":
    print("初始化 HDC 端口转发...")
    # 由于该脚本可能被多次重启或前置 HDC 挂载占用，先强制清理端口再映射，防止冲突
    os.system(f"hdc fport rm tcp:{PORT} tcp:{PORT} 2>/dev/null")
    os.system(f"hdc fport tcp:{PORT} tcp:{PORT}")
    
    print(">> 监听模式已启动。等待手机 APP 端派发任务...")
    
    active_task = ""
    
    while True:
        try:
            task = poll_task()
            if not task:
                # 清理无任务时的状态
                if active_task:
                    print(">> 任务已被重置或结束。")
                    active_task = ""
                time.sleep(2)
                continue
                
            if task != active_task:
                print(f"\n>>>>>>>> 开始新任务: {task} <<<<<<<<")
                active_task = task
                
                # 【触发式逻辑】在执行真正的新任务开始前，确保设备端口及驱动是健康状态
                print(">> [环境就绪准备] 刷新 HDC 端口并初始化 hmdriver2 驱动...")
                os.system(f"hdc fport rm tcp:{PORT} tcp:{PORT} 2>/dev/null")
                os.system(f"hdc fport tcp:{PORT} tcp:{PORT} >/dev/null 2>&1")
                reset_driver()
                
                # 1. 确保环境干净
                send_request({"type": "clear"})
                
                # 2. Stage 1: Planner 解析意图并启动 App
                app_name = run_planner(task)
                if app_name:
                    success = launch_app(app_name)
                    if success:
                        print(">> 等待 App 启动加载完成...")
                        time.sleep(1.3)
                
                # 3. 再次清空上下文 (隔离 Planner 的纯文本历史和后续的图文历史)
                send_request({"type": "clear"})

                # 4. Stage 2: 任务在 App 内循环执行
                if USE_AGENT_MODE:
                    run_task_in_app_agent(task)
                else:
                    run_task_in_app(task)
                bring_llm_app_to_foreground()
                
                # 6. 任务全部结束，清除手机端状态
                print(">> 当前任务流程已全部结束，清理状态并等待下一个任务...")
                send_request({"type": "clear"})
                active_task = ""
                
        except Exception as e:
            err_msg = str(e)
            print(f"\n>> [错误重启] 任务执行过程中发生异常: {err_msg}")
            
            # 如果中间执行阶段底层管道破裂（手机刚刚拔下等），主动重置以便不卡死
            if "broken pipe" in err_msg.lower() or "104" in err_msg or "32" in err_msg:
                print(">> [自愈] 检测到设备掉线(Broken Pipe)！")
                reset_driver()
                    
            try:
                # 尝试把界面回到应用, 并在 app 中显示异常
                bring_llm_app_to_foreground()
                send_request({"type": "error", "message": f"任务执行出错: {err_msg}"})
            except:
                pass
            active_task = ""
            print(">> 状态已清理，将避免服务完全退出，准备继续接收后续任务。")
            
        time.sleep(2)
