# KVM Ubuntu Server 自动化安装

通过虚拟化技术一键部署 Ubuntu Server 24.04 虚拟机，自动安装 Docker、docker-compose 和 Google Chrome。

- **Linux 宿主机**：使用 KVM/libvirt，支持 Arch、Debian/Ubuntu、Fedora/RHEL、openSUSE 等主流发行版
- **Windows 宿主机**：使用 VirtualBox，支持 Windows 10/11 全版本（含 Home）

通过 Xpra（Linux）或 VcXsrv（Windows）将 VM 内的 Chrome 无缝转发到宿主机桌面。

## 前置要求

### Linux

- CPU 支持硬件虚拟化 (Intel VT-x / AMD-V)
- Linux 宿主机

### Windows

- CPU 支持硬件虚拟化
- Windows 10/11（VirtualBox 和 OpenSSH 会自动安装）

## 快速开始

### Linux

```bash
# 1. 复制并编辑配置
cp vm/config.env.example vm/config.env
vim vm/config.env

# 2. 智能启动（首次自动安装，后续直接启动）
./linux/setup.sh

# 3. SSH 连入
./linux/ssh.sh

# 4. 启动 Chrome（无缝显示在宿主机桌面）
./linux/chrome.sh
```

### Windows

```cmd
:: 1. 复制并编辑配置
copy vm\config.env.example vm\config.env
notepad vm\config.env

:: 2. 智能启动（首次自动安装 VirtualBox + VM，后续直接启动）
windows\setup.cmd

:: 3. SSH 连入
windows\ssh.cmd

:: 4. 启动 Chrome（VcXsrv 独立窗口 / HTML5 浏览器模式）
windows\chrome.cmd
```

> 每个 `.cmd` 文件自动以 Bypass 执行策略调用对应的 `.ps1` 脚本，无需手动修改 PowerShell 执行策略。

## 脚本说明

| Linux 脚本 | Windows 脚本 | 功能 |
|------------|-------------|------|
| `linux/setup.sh` | `windows\setup.cmd` | 智能入口：VM 不存在时安装，已存在时启动 |
| `linux/install.sh` | `windows\install.cmd` | 完整安装：依赖、镜像、VM 创建、Docker + 扩展模块 |
| `linux/start.sh` | `windows\start.cmd` | 启动已有 VM，增量执行扩展模块 |
| `linux/provision.sh` | `windows\provision.cmd` | 扩展执行入口：推送并执行 extensions/ 中的脚本 |
| `linux/destroy.sh` | `windows\destroy.cmd` | 销毁 VM、清理磁盘和 SSH 密钥 |
| `linux/status.sh` | `windows\status.cmd` | 查看 VM 运行状态 |
| `linux/ssh.sh` | `windows\ssh.cmd` | SSH 连入 VM |
| `linux/chrome.sh` | `windows\chrome.cmd` | Chrome 浏览器转发到宿主机桌面 |

## 配置项

编辑 `vm/config.env` 或通过环境变量覆盖：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `VM_NAME` | ubuntu-server | VM 名称 |
| `VM_CPUS` | 2 | CPU 核数 |
| `VM_MEMORY` | 2048 | 内存 (MB) |
| `VM_DISK_SIZE` | 20 | 磁盘大小 (GB) |
| `VM_USER` | wpsweb | 登录用户名 |
| `UBUNTU_VERSION` | 24.04 | Ubuntu 版本 |
| `NETWORK_MODE` | nat | 网络模式 (nat/bridge) |
| `DATA_DIR` | ~/.kvm-ubuntu | 镜像和磁盘存储目录 |

> 登录方式为 SSH 密钥认证，密钥在安装时自动生成，销毁 VM 时自动删除。

## 项目结构

```
├── README.md
├── .gitignore
│
├── linux/                          # Linux 宿主机脚本 (KVM/libvirt)
│   ├── setup.sh                    # 智能入口
│   ├── install.sh                  # 完整安装
│   ├── start.sh                    # 启动 VM
│   ├── provision.sh                # 扩展执行
│   ├── destroy.sh                  # 销毁 VM
│   ├── status.sh / ssh.sh          # 状态 / SSH
│   ├── chrome.sh                   # Chrome 转发 (Xpra seamless)
│   └── lib/                        # Bash 模块
│       ├── log.sh                  # 日志
│       ├── pkg.sh                  # 跨发行版包管理
│       ├── sys.sh                  # 系统检测
│       ├── sudo.sh                 # 提权处理
│       ├── utils.sh                # 通用工具
│       └── vm.sh                   # KVM 操作封装
│
├── windows/                        # Windows 宿主机脚本 (VirtualBox)
│   ├── setup.ps1                   # 智能入口
│   ├── install.ps1                 # 完整安装
│   ├── start.ps1                   # 启动 VM
│   ├── provision.ps1               # 扩展执行
│   ├── destroy.ps1                 # 销毁 VM
│   ├── status.ps1 / ssh.ps1        # 状态 / SSH
│   ├── chrome.ps1                  # Chrome 转发 (VcXsrv / HTML5)
│   └── lib/                        # PowerShell 模块
│       ├── Log.psm1                # 日志
│       ├── Config.psm1             # 配置加载
│       ├── Utils.psm1              # 通用工具
│       └── VM.psm1                 # VirtualBox 操作封装
│
└── vm/                             # 共享 — VM 相关（跨平台）
    ├── config.env                  # 用户配置
    ├── config.env.example          # 配置模板
    ├── cloud-init/
    │   └── user-data.yaml.tpl      # cloud-init 模板
    └── extensions/                 # 扩展模块
        ├── 10-chrome-xpra.sh       # Chrome + Xpra
        └── 20-example.sh           # 示例模板
```

## 扩展系统

通过 `vm/extensions/` 目录管理 VM 内的软件安装扩展，支持幂等执行和增量更新。Linux 和 Windows 共享同一套扩展脚本。

### 工作原理

- **首次安装**：`install` 完成 cloud-init（Docker）后，自动调用 `provision` 执行全部扩展
- **日常启动**：`start` / `setup` 启动 VM 后，自动调用 `provision` 做增量检查（已安装的秒级跳过）
- **手动执行**：新增扩展后直接运行 `provision`，无需重建 VM

### 创建新扩展

```bash
cp vm/extensions/20-example.sh vm/extensions/30-my-app.sh
# 编辑脚本，替换安装逻辑
# 运行 provision 或 setup
```

### 扩展规范

- 文件名格式：`NN-name.sh`（NN 控制执行顺序）
- 幂等保证：通过 `/opt/kvm-extensions/<name>.done` 标记文件
- 以 root 权限运行
- 建议编号：10-29 基础设施，30-49 开发工具，50-69 业务应用，70+ 自定义

## Chrome 转发

### Linux — Xpra Seamless 模式

Chrome 窗口通过 Xpra 的 seamless 模式直接出现在宿主机桌面上，与原生应用无差别。

```bash
./linux/chrome.sh
```

### Windows — VcXsrv + SSH X11（首选）

Chrome 通过 X11 转发作为独立窗口出现在 Windows 桌面和任务栏上。VcXsrv 会自动安装。

```powershell
.\windows\chrome.ps1
```

如果 VcXsrv 无法安装，自动回退到 Xpra HTML5 浏览器模式（通过浏览器访问 `http://VM_IP:10000`）。

## 工作原理

1. 检测宿主机环境，自动安装虚拟化依赖（Linux: KVM/libvirt, Windows: VirtualBox）
2. 下载 Ubuntu Cloud Image（已下载则跳过）
3. 创建虚拟磁盘（Linux: qcow2, Windows: VDI）
4. 自动生成 SSH 密钥对用于安全认证
5. 通过 cloud-init 模板生成初始化配置（Docker 安装）
6. 创建 VM 并导入磁盘
7. cloud-init 在 VM 内完成基础设施安装
8. VM 就绪后通过扩展系统安装 Chrome/Xpra 等软件
9. 输出 SSH 连接信息

## lib/ 模块说明

### Linux (Bash)

所有库函数使用 `::` 命名空间风格，如 `log::info`、`pkg::install`、`vm::create_disk`。

- **log.sh** — 带颜色和时间戳的日志输出
- **pkg.sh** — 统一包管理接口，自动映射不同发行版的包名差异
- **sys.sh** — 发行版检测、CPU 架构检测、KVM/libvirt 状态检查
- **sudo.sh** — sudo/doas 自动检测和权限验证
- **utils.sh** — 文件下载、命令检查、轮询等待等通用函数
- **vm.sh** — VM 生命周期管理（创建、启动、销毁、状态查询）

### Windows (PowerShell)

- **Log.psm1** — 彩色时间戳日志（Write-LogInfo, Write-LogWarn 等）
- **Config.psm1** — 配置文件加载（读取 vm/config.env）
- **Utils.psm1** — 文件下载、用户确认、条件等待
- **VM.psm1** — VirtualBox 操作封装（VBoxManage CLI）
