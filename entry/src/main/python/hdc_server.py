import json
import subprocess
from http.server import HTTPServer, BaseHTTPRequestHandler
import os
import sys
import argparse

NO_REASON_MODE = False

class HDCServerHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path == '/api/run_cmd':
            content_length = int(self.headers.get('Content-Length', 0))
            post_data = self.rfile.read(content_length)
            try:
                data = json.loads(post_data)
                cmd = data.get('cmd', '')
                if cmd:
                    print(f">> 正在执行远程指令: {cmd}")
                    # 使用 subprocess 执行系统命令
                    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
                    
                    # 检查是否成功连接了HDC，并在需要时启动 agent
                    if is_hdc_connected():
                        start_harmony_agent()

                    # 将stdout和stderr合并返回给手机App
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

agent_process = None

def is_hdc_connected():
    try:
        # 当只有一行[Empty]时表示空，正常应该输出设备IP或者序列号
        result = subprocess.run("hdc list targets", shell=True, capture_output=True, text=True)
        output = result.stdout.strip()
        if not output or "[Empty]" in output or "not found" in output:
            return False
        return True
    except:
        return False

def start_harmony_agent():
    global agent_process
    # 如果已经在运行中且没有退出，就不重复启动
    if agent_process is not None:
        ret_code = agent_process.poll()
        if ret_code is None:
            # 仍在运行
            return
        else:
            print(f">> [提示] harmony_agent.py 之前已退出（退出码: {ret_code}），现在准备重新拉起...")

    agent_script = os.path.join(os.path.dirname(__file__), "harmony_agent.py")
    print(f">> 正在后台自动启动任务代理: {agent_script}")
    try:
        # 使用当前运行 hdc_server 的 python 环境，避免装包问题。
        # 共享 stdout 和 stderr，使得它的输出直接打印在这个控制台里
        cmd = [sys.executable, agent_script]
        if NO_REASON_MODE:
            cmd.append("--no_reason")

        agent_process = subprocess.Popen(
            cmd,
            stdout=sys.stdout,
            stderr=sys.stderr
        )
    except Exception as e:
        print(f">> [错误] 无法启动 harmony_agent.py: {e}")

def cleanup():
    global agent_process
    if agent_process and agent_process.poll() is None:
        print("\n>> 正在关闭 harmony_agent.py...")
        agent_process.terminate()
        agent_process.wait()

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument("--no_reason", action="store_true", help="Use prompts without reasoning")
    args = parser.parse_args()
    
    if args.no_reason:
        NO_REASON_MODE = True

    # 启动代理 (如果 HDC 已经挂载)
    if is_hdc_connected():
        start_harmony_agent()
    else:
        print(">> 未检测到 HDC 设备连接，将延后到 App 端发起连接指令后再启动...")
        
    # 监听在全新的端口，和文件下载的 9123 分开，也避开 Socket 的 9126
    PORT = 9124
    server = HTTPServer(('0.0.0.0', PORT), HDCServerHandler)
    print(f"HDC 远程控制服务端已启动，监听端口: {PORT}...")
    print(f"等待手机 App 发送连接指令...")
    
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        cleanup()
        server.server_close()
        print(">> 服务已退出。")