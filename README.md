# KVM Ubuntu Server 自动化安装

通过 KVM/libvirt 一键部署 Ubuntu Server 24.04 虚拟机，自动安装 Docker 和 docker-compose。支持在 Arch、Debian/Ubuntu、Fedora/RHEL、openSUSE 等主流 Linux 发行版上运行。

## 前置要求

- CPU 支持硬件虚拟化 (Intel VT-x / AMD-V)
- Linux 宿主机

## 快速开始

```bash
# 1. 编辑配置（可选，默认即可用）
vim config.env

# 2. 一键安装
./install.sh

# 3. SSH 连入
./ssh.sh
```

## 脚本说明

| 脚本 | 功能 |
|------|------|
| `install.sh` | 主安装脚本，完成依赖安装、镜像下载、VM 创建的全流程 |
| `destroy.sh` | 销毁 VM 并清理磁盘文件 |
| `status.sh` | 查看 VM 运行状态和连接信息 |
| `ssh.sh` | 快捷 SSH 连入 VM |

## 配置项

编辑 `config.env` 或通过环境变量覆盖：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `VM_NAME` | ubuntu-server | VM 名称 |
| `VM_CPUS` | 2 | CPU 核数 |
| `VM_MEMORY` | 2048 | 内存 (MB) |
| `VM_DISK_SIZE` | 20 | 磁盘大小 (GB) |
| `VM_USER` | ubuntu | 登录用户名 |
| `VM_PASSWORD` | ubuntu | 登录密码 |
| `UBUNTU_VERSION` | 24.04 | Ubuntu 版本 |
| `NETWORK_MODE` | nat | 网络模式 (nat/bridge) |
| `DATA_DIR` | ~/.kvm-ubuntu | 镜像和磁盘存储目录 |

## 项目结构

```
├── install.sh              主入口
├── destroy.sh              销毁 VM
├── status.sh               查看状态
├── ssh.sh                  SSH 连入
├── config.env              配置文件
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
- **vm.sh** — VM 生命周期管理（创建磁盘、seed ISO、安装、销毁、状态查询）

## 工作原理

1. 检测宿主机环境，自动安装 KVM/libvirt 依赖
2. 下载 Ubuntu Cloud Image（已下载则跳过）
3. 基于 cloud image 创建 qcow2 磁盘
4. 通过 cloud-init 模板生成初始化配置（含 Docker 安装）
5. `virt-install` 创建 VM 并导入磁盘
6. cloud-init 在 VM 内自动完成系统配置和 Docker 安装
7. VM 就绪后输出 SSH 连接信息
