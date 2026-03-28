# KVM Ubuntu Server 自动化安装

通过 KVM/libvirt 一键部署 Ubuntu Server 24.04 虚拟机，自动安装 Docker、docker-compose 和 Google Chrome。支持在 Arch、Debian/Ubuntu、Fedora/RHEL、openSUSE 等主流 Linux 发行版上运行。

通过 Xpra 将 VM 内的 Chrome 无缝转发到宿主机桌面，与原生应用无差别。

## 前置要求

- CPU 支持硬件虚拟化 (Intel VT-x / AMD-V)
- Linux 宿主机

## 快速开始

```bash
# 1. 复制并编辑配置
cp config.env.example config.env
vim config.env

# 2. 智能启动（首次自动安装，后续直接启动）
./setup.sh

# 3. SSH 连入
./ssh.sh

# 4. 启动 Chrome（无缝显示在宿主机桌面）
./chrome.sh
```

## 脚本说明

| 脚本 | 功能 |
|------|------|
| `setup.sh` | 智能入口：VM 不存在时自动安装，已存在时直接启动 |
| `install.sh` | 完整安装：依赖安装、镜像下载、VM 创建、Docker 安装 + 扩展模块 |
| `start.sh` | 启动已存在的 VM，等待就绪后执行扩展模块增量检查 |
| `provision.sh` | 扩展模块执行入口：推送并执行 extensions/ 中的脚本 |
| `destroy.sh` | 销毁 VM、清理磁盘文件和 SSH 密钥 |
| `status.sh` | 查看 VM 运行状态和连接信息 |
| `ssh.sh` | 快捷 SSH 连入 VM |
| `chrome.sh` | 通过 Xpra 无缝转发 VM 内 Chrome 到宿主机桌面 |

## 配置项

编辑 `config.env` 或通过环境变量覆盖：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `VM_NAME` | ubuntu-server | VM 名称 |
| `VM_CPUS` | 2 | CPU 核数 |
| `VM_MEMORY` | 4096 | 内存 (MB) |
| `VM_DISK_SIZE` | 20 | 磁盘大小 (GB) |
| `VM_USER` | wpsweb | 登录用户名 |
| `UBUNTU_VERSION` | 24.04 | Ubuntu 版本 |
| `NETWORK_MODE` | nat | 网络模式 (nat/bridge) |
| `DATA_DIR` | ~/.kvm-ubuntu | 镜像和磁盘存储目录 |

> 登录方式为 SSH 密钥认证，密钥在安装时自动生成于 `$DATA_DIR/id_ed25519`，销毁 VM 时自动删除。

## 项目结构

```
├── setup.sh                智能入口（自动判断安装/启动）
├── install.sh              完整安装
├── start.sh                启动已有 VM
├── provision.sh            扩展模块执行入口
├── destroy.sh              销毁 VM
├── status.sh               查看状态
├── ssh.sh                  SSH 连入
├── chrome.sh               Xpra Chrome 转发
├── config.env              配置文件
├── extensions/             扩展模块目录
│   ├── 10-chrome-xpra.sh   Chrome + Xpra 安装
│   └── 20-example.sh       示例模板
├── lib/
│   ├── log.sh              日志模块
│   ├── pkg.sh              跨发行版包管理
│   ├── sys.sh              系统检测
│   ├── sudo.sh             提权处理
│   ├── utils.sh            通用工具
│   └── vm.sh               KVM 操作封装
└── cloud-init/
    └── user-data.yaml.tpl  cloud-init 模板
```

## lib/ 模块说明

所有库函数使用 `::` 命名空间风格，如 `log::info`、`pkg::install`、`vm::create_disk`。

- **log.sh** — 带颜色和时间戳的日志输出 (`log::info`, `log::warn`, `log::error`, `log::ok`, `log::step`)
- **pkg.sh** — 统一包管理接口，自动映射不同发行版的包名差异
- **sys.sh** — 发行版检测、CPU 架构检测、KVM/libvirt 状态检查
- **sudo.sh** — sudo/doas 自动检测和权限验证
- **utils.sh** — 文件下载、命令检查、轮询等待等通用函数
- **vm.sh** — VM 生命周期管理（创建、启动、销毁、状态查询）

## Chrome / Xpra 使用说明

VM 安装完成后，Chrome 和 Xpra 已自动安装在 VM 内部。

**启动 Chrome：**

```bash
./chrome.sh
```

Chrome 窗口将通过 Xpra 的 seamless 模式直接出现在宿主机桌面上，就像一个原生应用。支持剪贴板同步、断开重连等特性。

**前提条件：**

- 宿主机需要有图形桌面环境
- 宿主机需安装 `xpra`（`chrome.sh` 会自动检测并安装）

## 扩展系统

通过 `extensions/` 目录管理 VM 内的软件安装扩展，支持幂等执行和增量更新。

### 工作原理

- **首次安装**：`install.sh` 完成 cloud-init（Docker）后，自动调用 `provision.sh` 执行全部扩展
- **日常启动**：`start.sh` / `setup.sh` 启动 VM 后，自动调用 `provision.sh` 做增量检查（已安装的秒级跳过）
- **手动执行**：新增扩展后直接运行 `./provision.sh`，无需重建 VM

### 创建新扩展

1. 复制示例模板：

```bash
cp extensions/20-example.sh extensions/30-my-app.sh
```

2. 编辑脚本，替换安装逻辑
3. 运行 `./provision.sh` 或 `./setup.sh`

### 扩展规范

- 文件名格式：`NN-name.sh`（NN 控制执行顺序）
- 幂等保证：通过 `/opt/kvm-extensions/<name>.done` 标记文件
- 以 root 权限运行
- 建议编号：10-29 基础设施，30-49 开发工具，50-69 业务应用，70+ 自定义

## 工作原理

1. 检测宿主机环境，自动安装 KVM/libvirt 依赖
2. 下载 Ubuntu Cloud Image（已下载则跳过）
3. 基于 cloud image 创建 qcow2 磁盘
4. 自动生成 SSH 密钥对用于安全认证
5. 通过 cloud-init 模板生成初始化配置（Docker 安装）
6. `virt-install` 创建 VM 并导入磁盘
7. cloud-init 在 VM 内完成基础设施安装
8. VM 就绪后通过扩展系统安装 Chrome/Xpra 等软件
9. 输出 SSH 连接信息
