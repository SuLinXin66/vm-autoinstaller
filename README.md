# KVM Ubuntu Server 自动化安装

通过虚拟化技术一键部署 Ubuntu Server 24.04 虚拟机，自动安装 Docker、docker-compose 和 Google Chrome。

- **Linux 宿主机**：使用 KVM/libvirt，支持 Arch、Debian/Ubuntu、Fedora/RHEL、openSUSE 等主流发行版
- **Windows 宿主机**：使用 VirtualBox，支持 Windows 10/11 全版本（含 Home）

通过 Xpra（Linux）或 VcXsrv（Windows）将 VM 内的 Chrome 无缝转发到宿主机桌面。

## 快速开始（CLI 方式）

下载对应平台的 installer 并运行：

```bash
# Linux / macOS
chmod +x installer-linux-amd64
./installer-linux-amd64
# 重新打开终端后即可使用

# 首次创建并启动 VM
kvm-ubuntu setup

# 直接 SSH 进入 VM
kvm-ubuntu

# 启动 Chrome
kvm-ubuntu chrome
```

```powershell
# Windows — 双击或在终端中运行
.\installer-windows-amd64.exe
# 重新打开终端后即可使用

# 首次创建并启动 VM
kvm-ubuntu setup

# 直接 SSH 进入 VM
kvm-ubuntu

# 启动 Chrome
kvm-ubuntu chrome
```

## CLI 子命令

| 子命令 | 功能 |
|--------|------|
| *(无)* | SSH 进入 VM（需已安装且运行中） |
| `setup` | 智能入口：VM 不存在时安装，已存在时启动 |
| `stop` | 停止 VM |
| `status` | 查看 VM 运行状态 |
| `destroy` | 销毁 VM、清理磁盘和 SSH 密钥 |
| `provision` | 推送并执行 extensions/ 中的扩展脚本 |
| `ssh` | 显式 SSH 连入（与无参数等价） |
| `chrome` | Chrome 浏览器转发到宿主机桌面 |
| `exec -- <cmd>` | 在 VM 内执行命令（非交互） |
| `cp <src> <dst>` | 宿主机与 VM 间拷贝文件 |
| `config` | 查看/修改配置（表格展示、类型校验、pending 提示） |
| `info` | 查看应用信息、VM 状态、版本等 |
| `sync` | 增量更新脚本资源（不覆盖用户配置） |
| `upgrade` | 检查 CLI/installer 新版本 |
| `uninstall` | 卸载：销毁 VM → 删除数据目录 → 撤销 PATH |
| `completion` | 生成 shell 补全脚本（powershell/bash/zsh） |

## 配置项

编辑配置：`kvm-ubuntu config` 或手动编辑 `scripts/vm/config.env`

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

## 前置要求

### Linux

- CPU 支持硬件虚拟化 (Intel VT-x / AMD-V)

### Windows

- CPU 支持硬件虚拟化
- Windows 10/11（VirtualBox 和 OpenSSH 会自动安装）

## 项目结构

```
build.env                       # 构建变量（fork/定制时修改此文件）
Makefile                        # 构建入口
go.mod
cmd/
  installer/                    # installer 程序（embed 全部资源）
  cli/                          # 日常 CLI 壳（Cobra）
internal/                       # Go 共享包
scripts/                        # 平台脚本（从仓库根迁入）
  linux/                        # Linux 宿主机脚本 (KVM/libvirt)
    setup.sh / install.sh / stop.sh / ...
    lib/                        # Bash 模块
  windows/                      # Windows 宿主机脚本 (VirtualBox)
    setup.ps1 / install.ps1 / stop.ps1 / ...
    setup.cmd / ...
    lib/                        # PowerShell 模块
  vm/                           # 共享资源
    config.env.example          # 配置模板
    cloud-init/                 # cloud-init 模板
    extensions/                 # 扩展模块
    config/                     # dotfiles 等
```

## 扩展系统

通过 `scripts/vm/extensions/` 目录管理 VM 内的软件安装扩展。

- **首次安装**：`setup` 完成 cloud-init 后自动执行全部扩展
- **日常启动**：`setup` 启动 VM 后做增量检查（已安装的秒级跳过）
- **手动执行**：新增扩展后运行 `kvm-ubuntu provision`

```bash
cp scripts/vm/extensions/20-example.sh scripts/vm/extensions/30-my-app.sh
# 编辑脚本，替换安装逻辑
kvm-ubuntu provision
```

扩展规范：文件名 `NN-name.sh`（NN 控制顺序），以 root 权限运行，通过标记文件保证幂等。

## 构建（开发者/fork 作者）

构建需要 Go 1.22+ 和类 Unix 环境（Linux/macOS，Windows 需 WSL/Git Bash）。

```bash
# 1. 编辑构建配置（fork 后按需修改）
vim build.env

# 2. 构建全平台 installer
make release

# 3. 产物在 dist/ 下
ls dist/
```

`build.env` 变量：

| 变量 | 说明 |
|------|------|
| `APP_NAME` | 安装后的命令名（默认 `kvm-ubuntu`） |
| `REPO_URL` | 仓库地址（用于 sync/upgrade） |
| `BRANCH` | 默认分支 |

Fork 时只需修改 `build.env`，无需改 Go 源码或 Makefile。

## FAQ

**installer 干什么？** — 把 CLI 工具和脚本资源安装到用户数据目录并加入 PATH。运行一次即可。

**`setup` 干什么？** — 首次运行创建 VM，后续运行启动已有 VM 并增量执行扩展。

**直接敲命令名（无参数）？** — 等价于 `ssh`，进入 VM 交互终端。需 VM 已运行。

**`DATA_ROOT` 和 `DATA_DIR` 的区别？** — `DATA_ROOT`（如 `~/.local/share/kvm-ubuntu`）是 CLI 与脚本的安装目录，由 installer 管理，`uninstall` 清理。`DATA_DIR`（如 `~/.kvm-ubuntu`）是 VM 磁盘/密钥存储目录，由脚本管理，`destroy` 清理。

## Shell 补全

```bash
# Bash
echo 'eval "$(kvm-ubuntu completion bash)"' >> ~/.bashrc

# Zsh
echo 'eval "$(kvm-ubuntu completion zsh)"' >> ~/.zshrc

# PowerShell
Add-Content $PROFILE 'kvm-ubuntu completion powershell | Invoke-Expression'
```
