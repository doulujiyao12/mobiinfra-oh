// Keep downloads pinned to a verified release; never guess the latest asset name.
export const CODEX_BRIDGE_VERSION: string = '1.1.11';
export const CODEX_BRIDGE_TAG: string = 'codex-bridge-v' + CODEX_BRIDGE_VERSION;
export const CODEX_REPOSITORY_URL: string = 'https://github.com/doulujiyao12/mobiinfra-oh';
export const CODEX_RELEASE_URL: string = CODEX_REPOSITORY_URL + '/releases/tag/' + CODEX_BRIDGE_TAG;
const DOWNLOAD_ROOT: string = CODEX_REPOSITORY_URL + '/releases/download/' + CODEX_BRIDGE_TAG + '/';
const GUIDE_ROOT: string = CODEX_REPOSITORY_URL + '/blob/' + CODEX_BRIDGE_TAG + '/docs/codex/';

export enum CodexHelpSection { Download = 'download', Connect = 'connect', Tailscale = 'tailscale' }
export enum CodexPlatform { Windows = 'windows', Mac = 'macos', Linux = 'linux' }
export interface CodexHelpParams { section: string; }
export interface CodexDownload {
  id: string;
  title: string;
  detail: string;
  filename: string;
  url: string;
}
export interface CodexGuideStep { title: string; body: string; command: string; }
export interface CodexHelpLink { title: string; url: string; }
export interface CodexGuide {
  id: string;
  title: string;
  intro: string;
  notice: string;
  steps: CodexGuideStep[];
  notes: string[];
  links: CodexHelpLink[];
}

function download(id: string, title: string, detail: string, filename: string): CodexDownload {
  return { id: id, title: title, detail: detail, filename: filename, url: DOWNLOAD_ROOT + filename };
}

export function codexDownloads(): CodexDownload[] {
  return [
    download('windows', 'Windows', 'x64 · 安装向导', 'ClawMate-Codex-' + CODEX_BRIDGE_VERSION + '-win-x64.exe'),
    download('macos', 'macOS', 'Apple Silicon（M 系列）· 解压后移入应用程序',
      'ClawMate-Codex-' + CODEX_BRIDGE_VERSION + '-darwin-arm64-unsigned.zip'),
    download('linux', 'Linux · CLI', 'x64 · 适合云服务器和无桌面环境',
      'ClawMate-Codex-Terminal-' + CODEX_BRIDGE_VERSION + '-linux-x64.tar.gz'),
    download('linux-desktop', 'Linux · 桌面', 'x64 · 解压后启动，需要图形环境',
      'ClawMate-Codex-' + CODEX_BRIDGE_VERSION + '-linux-x64-unsigned.tar.gz'),
    download('windows-cli', 'Windows · CLI', 'x64 · 终端便携版',
      'ClawMate-Codex-Terminal-' + CODEX_BRIDGE_VERSION + '-win32-x64.zip')
  ];
}

export const CODEX_DOWNLOAD_NOTICE: string = '当前为预览版，安装包未签名，Mac 未公证；Mac 仅提供 M 系列版本。Mac / Linux 桌面包已核对内容，仍需在对应系统验证运行。';
export const CODEX_PAIRING_NOTE: string = '配对码 5 分钟内有效，只能使用一次。请粘贴完整配对信息或导入配对文件；证书指纹不是 token。不要公开配对码和文件。';

const DESKTOP_NOTES: string[] = [
  CODEX_PAIRING_NOTE,
  '新任务默认允许工作目录内修改，并在需要时请求批准。可在会话右上角设置改为只读分析；完全访问需要主动选择。',
  '左上角菜单 → 电脑会话，可查看已授权项目的已有会话。实时共享需要原 Codex 后台在线且协议兼容；仅登录同一账号不会同步另一台电脑的历史。',
  '连接超时先确认电脑在线、服务已启动、手机能访问所选地址，可信网络的防火墙允许该端口。跨网络请先完成 Tailscale 组网。IP 变化后，空闲时重启服务并重新配对。',
  '窗口关闭时选择「隐藏窗口」可保留连接；选择「关闭应用」、休眠或关机会中断连接。升级前先结束任务并退出旧版，已有配置与配对数据会保留。'
];

function desktopGuide(platform: CodexPlatform): CodexGuide {
  const mac: boolean = platform === CodexPlatform.Mac;
  const platformName: string = mac ? 'macOS' : 'Windows';
  return {
    id: platform, title: platformName + ' 连接指南',
    intro: '在自己的电脑安装 ClawMate Codex 连接器，登录、选择项目，再用手机扫码。运行组件已经内置，无需另装 Node.js 或 npm。',
    notice: mac ? '适用于 Apple Silicon（M 系列）。当前应用未签名、未公证，请先核对 Release 中的 SHA256。' :
      '适用于 Windows x64。当前安装包未签名，请先核对 Release 中的 SHA256。',
    steps: [
      { title: '安装连接器', body: mac ?
        '下载 macOS ZIP 并解压，将 ClawMate Codex.app 移入「应用程序」。若系统阻止打开，确认来源和校验值后，在系统设置 → 隐私与安全性中查看允许打开的选项。无需关闭系统安全保护。' :
        '下载 Windows EXE，按安装向导完成安装，打开 ClawMate Codex。若系统提示未知发布者，请核对来源和校验值后再决定是否继续。', command: '' },
      { title: '登录 Codex 账号', body: '在电脑「连接设置」点击「使用浏览器登录」，在官方登录页面完成授权。账号需具备 Codex 使用资格。OpenAI 登录凭据留在电脑，手机使用独立的设备凭据。', command: '' },
      { title: '选择允许操作的目录', body: '点击「选择项目」，添加实际项目文件夹。保留「局域网 · 自动安全配对」，监听范围选择「允许局域网 / 远程设备访问」，保存设置。只添加你希望手机操作的项目。', command: '' },
      { title: '启动手机连接', body: '点击「启动手机连接」，确认服务已启动。手机和电脑先连接同一个可互访的 Wi-Fi；异地连接请先按 Tailscale 教程组网。默认端口为 8787，以电脑实际显示为准。', command: '' },
      { title: '生成配对二维码', body: '在电脑「手机配对」选择手机能访问的本机地址：同一 Wi-Fi 选局域网 IP，Tailscale 选 100 开头的 IP。点击「生成配对信息」，保持二维码页面打开。', command: '' },
      { title: '手机扫码或粘贴配对', body: '手机打开 Codex → 创建连接 → 扫描二维码，核对电脑名称和地址后连接。也可导入电脑导出的配对文件，或粘贴完整配对信息；不要填写「连接保护」里的指纹。', command: '' },
      { title: '开始第一条任务', body: '连接后选择项目，发送「概括这个项目的结构」。之后可在「我的连接」轻点电脑重连，右侧菜单可断开或删除连接。电脑端连接器需保持运行。', command: '' }
    ],
    notes: DESKTOP_NOTES,
    links: [{ title: '下载连接器', url: CODEX_RELEASE_URL },
      { title: '网页版指南', url: GUIDE_ROOT + platform + '.md' }]
  };
}

function linuxGuide(): CodexGuide {
  const filename: string = 'ClawMate-Codex-Terminal-' + CODEX_BRIDGE_VERSION + '-linux-x64.tar.gz';
  return {
    id: 'linux', title: 'Linux CLI 连接指南',
    intro: '适用于 x64 Linux 服务器，无需桌面环境。下面命令在服务器执行；把项目目录和示例 IP 换成自己的实际值。',
    notice: '请以持有项目和原 Codex 会话的普通用户运行。保留解压后的 bin、runtime 和 host 目录，不要只移动启动文件。',
    steps: [
      { title: '下载并解压', body: '下载终端版，先比对 Release 的 SHA256 校验清单，再解压到用户目录。目标目录应为空；升级时先结束任务并退出旧服务。', command:
        'curl -fL --retry 3 -o ' + filename + ' \\\n  ' + DOWNLOAD_ROOT + filename + '\nmkdir -p "$HOME/ClawMate-Codex"\ntar -xzf ' + filename + ' -C "$HOME/ClawMate-Codex"\ncd "$HOME/ClawMate-Codex"' },
      { title: '配置工作目录', body: '将 /absolute/project 替换为服务器已有项目的绝对路径，电脑名称可自定义。该步骤只配置桥接，不会新建或克隆项目。', command:
        './bin/clawmate-codex setup --project /absolute/project --name MyServer --host 0.0.0.0 --port 8787' },
      { title: '登录 Codex', body: '终端会显示官方验证网址和一次性登录码。在自己的手机或电脑浏览器打开该网址，输入码并完成授权，等待终端显示登录成功。不要把登录码发给其他人。', command: './bin/clawmate-codex login' },
      { title: '启动并查看地址', body: '确认服务器和手机网络可互访；异地服务器先完成 Tailscale 组网。启动后用 status 查看实际监听地址和网络状态。', command:
        './bin/clawmate-codex start\n./bin/clawmate-codex status' },
      { title: '导出一次性配对信息', body: '将下方示例 100.101.102.103 替换为 status 中服务器本机的 Tailscale IPv4；同一 Wi-Fi 可用局域网 IP。这里填写服务器地址，不是手机地址。', command:
        './bin/clawmate-codex pair --origin https://100.101.102.103:8787 --output phone.clawmate-codex-pair.json\ncat phone.clawmate-codex-pair.json' },
      { title: '手机完成配对', body: '复制上一步输出的完整 JSON，手机打开 Codex → 创建连接 → 粘贴配对信息，粘贴后连接。也可把配对文件安全传到自己的手机，再「导入配对文件」。过期则重新运行 pair。', command: '' },
      { title: '开始任务与维护', body: '手机选择项目并发送任务。用 devices 查看已配对设备；stop 在任务执行或待审批时会拒绝停服，先在手机结束任务。quit 会退出后台并中断独立任务。仅关闭 SSH 窗口不会主动停止已经启动的后台。', command:
        './bin/clawmate-codex status\n./bin/clawmate-codex devices\n# 空闲时停止连接服务\n./bin/clawmate-codex stop\n# 确认要退出后台时\n./bin/clawmate-codex quit' }
    ],
    notes: [CODEX_PAIRING_NOTE,
      '手机查看原电脑会话时，桥接需与原 Codex 使用相同 OS 用户和 CODEX_HOME，且配置该会话的实际项目目录。兼容的原生 daemon 在线时可实时共享；其他用户、容器或 no-daemon 独占会话不一定支持。',
      'Tailscale 使用用户态模式且未显示 100 开头地址时，可在首次启动后台前设置 CLAWMATE_TAILSCALE_SOCKET=/实际路径/tailscaled.sock。已有后台须在空闲时先退出，才会继承新环境变量。',
      '新任务默认允许工作目录内修改并请求批准。超时检查网络、status、服务端口与 Tailscale 策略；不要通过关闭 TLS 校验解决证书错误。'
    ],
    links: [{ title: '下载连接器', url: CODEX_RELEASE_URL }, { title: '网页版指南', url: GUIDE_ROOT + 'linux.md' }]
  };
}

export function codexConnectionGuide(platform: CodexPlatform): CodexGuide {
  return platform === CodexPlatform.Linux ? linuxGuide() : desktopGuide(platform);
}

export function codexTailscaleGuide(): CodexGuide {
  return {
    id: 'tailscale', title: 'Tailscale 组网教程',
    intro: '让异地的手机和电脑通过私有网络互访。组网成功后，ClawMate 使用电脑的 Tailscale 地址连接，无需把桥接端口开放到公网。',
    notice: '手机需有适配当前系统的 Tailscale 兼容客户端。官方安装文档目前未列出鸿蒙 NEXT；不能把 Android APK 当作鸿蒙原生安装包。没有兼容客户端时，先使用同一 Wi-Fi 连接。',
    steps: [
      { title: '电脑安装 Tailscale', body: 'Windows / macOS 从 Tailscale 官网下载安装并登录。Linux 有管理员权限时可使用下方官方命令，或按官方文档用软件包安装。没有权限或没有 TUN 的服务器，需参考官方用户态模式文档配置。', command:
        'curl -fsSL https://tailscale.com/install.sh | sh\nsudo tailscale up' },
      { title: '手机加入同一网络', body: '在兼容客户端登录同一 Tailscale 网络的账号，或由该网络管理员邀请加入。按系统提示允许 VPN，确认手机和目标电脑均在线。可在控制台的设备列表核对。', command: '' },
      { title: '记下电脑的私有 IP', body: '使用目标电脑的 Tailscale IPv4，例如 100.101.102.103。Linux 可运行下方命令；Windows / Mac 可在客户端复制地址。这个地址属于电脑，不能填成本机手机的 IP。', command:
        'tailscale status\ntailscale ip -4' },
      { title: '启动连接器并生成新配对', body: '先启动 Tailscale，再启动 ClawMate 连接器，选择自动安全配对并允许远程设备访问。在「手机配对」选 100 开头地址。Linux 使用 pair --origin 指定该地址；默认端口 8787。', command:
        './bin/clawmate-codex pair --origin https://100.101.102.103:8787 --output phone.clawmate-codex-pair.json' },
      { title: '手机用新地址连接', body: '扫描新二维码，或粘贴完整配对信息。原先保存的 192.168 开头连接不会自动切换，请回「我的连接」使用新连接。连接器应与 Tailscale 位于可互访的网络环境中。', command: '' },
      { title: '不通时逐层确认', body: '先确认两端 Tailscale 在线且能互访，再检查连接器 status。网络访问策略及电脑防火墙需允许手机访问桥接 TCP 端口。下方命令在能使用 Tailscale CLI 的设备执行，目标应换成另一端 IP；单向 ping 成功也不能代替手机到桥接端口的检查。', command:
        'tailscale ping <另一台设备的Tailscale-IP>\n./bin/clawmate-codex status' }
    ],
    notes: [
      '两端直接加入同一个 Tailscale 网络时，一般不需要出口节点、子网路由或公网端口映射。公司或学校网络的管理策略仍可能限制连接。',
      'Linux 用户态模式可能没有 tailscale0 网卡。连接器 1.1.11 可读取本机 Tailscale socket 获取地址；必要时在后台启动前指定 CLAWMATE_TAILSCALE_SOCKET。它不会替你安装、登录 Tailscale 或更改网络策略。',
      'Tailscale 负责网络互访，连接器仍负责 Codex 任务和独立配对。电脑休眠、服务退出或 VPN 断开时，手机无法继续连接。'
    ],
    links: [{ title: 'Tailscale 官方下载与安装', url: 'https://tailscale.com/docs/install' },
      { title: 'Linux 官方安装指南', url: 'https://tailscale.com/docs/install/linux' },
      { title: '无 TUN：用户态模式', url: 'https://tailscale.com/docs/concepts/userspace-networking' },
      { title: '网页版组网教程', url: GUIDE_ROOT + 'tailscale.md' }]
  };
}

export function codexHelpSection(value: string): CodexHelpSection {
  if (value === CodexHelpSection.Download) { return CodexHelpSection.Download; }
  if (value === CodexHelpSection.Tailscale) { return CodexHelpSection.Tailscale; }
  return CodexHelpSection.Connect;
}
