#!/usr/bin/env bash
# KVM/libvirt VM lifecycle management.
# Usage: source lib/vm.sh

[[ -n "${_LIB_VM_LOADED:-}" ]] && return 0
_LIB_VM_LOADED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"
source "${SCRIPT_DIR}/sudo.sh"
source "${SCRIPT_DIR}/utils.sh"

# Force English output for virsh to avoid localization issues
_vm::virsh() {
    sudo::exec env LC_ALL=C virsh "$@"
}

vm::exists() {
    local name="$1"
    _vm::virsh dominfo "$name" &>/dev/null
}

vm::is_running() {
    local name="$1"
    local state
    state="$(_vm::virsh domstate "$name" 2>/dev/null)" || return 1
    [[ "$state" == "running" ]]
}

vm::get_ip() {
    local name="$1"
    local ip
    ip="$(_vm::virsh domifaddr "$name" 2>/dev/null \
        | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
        | head -1)"

    if [[ -z "$ip" ]]; then
        ip="$(_vm::virsh net-dhcp-leases default 2>/dev/null \
            | grep "$name" \
            | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
            | head -1)"
    fi

    if [[ -n "$ip" ]]; then
        echo "$ip"
        return 0
    fi
    return 1
}

: "${_VM_SSH_KEY:=}"

vm::set_ssh_key() {
    _VM_SSH_KEY="$1"
}

_vm::_ssh_opts() {
    local opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR"
    if [[ -n "$_VM_SSH_KEY" && -f "$_VM_SSH_KEY" ]]; then
        opts+=" -i $_VM_SSH_KEY"
    fi
    echo "$opts"
}

_vm::_ssh_exec() {
    local user="$1" ip="$2"
    shift 2
    ssh $(_vm::_ssh_opts) "${user}@${ip}" "$@"
}

_vm::_ssh_test() {
    local user="$1" ip="$2"
    _vm::_ssh_exec "$user" "$ip" "echo ok" &>/dev/null
}

# Stream serial console output via virsh console in the background.
# Uses `script` to provide a PTY that virsh console requires.
_vm::_start_console_stream() {
    local name="$1"
    if ! command -v script &>/dev/null; then
        return 1
    fi
    # Output to stderr so it's visible when caller captures stdout via $()
    script -qf /dev/null -c "sudo env LC_ALL=C virsh console ${name} --force 2>/dev/null" >&2 2>/dev/null &
    echo $!
}

# Kill a background process and its children
_vm::_kill_bg() {
    local pid="$1"
    [[ -z "$pid" ]] && return 0
    kill -0 "$pid" 2>/dev/null || return 0
    # Kill child tree: script -> sh -> sudo -> virsh
    local children
    children="$(pgrep -P "$pid" 2>/dev/null || true)"
    for child in $children; do
        local gc
        gc="$(pgrep -P "$child" 2>/dev/null || true)"
        for g in $gc; do kill "$g" 2>/dev/null || true; done
        kill "$child" 2>/dev/null || true
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

# Full monitoring: immediately stream console -> wait IP+SSH -> tail via SSH
vm::wait_ready() {
    local name="$1"
    local user="$2"

    # Start console streaming IMMEDIATELY so user sees boot output
    log::info "实时输出 VM 控制台日志 (等待系统启动)..."
    log::separator

    local console_pid=""
    local console_restarts=0
    local max_console_restarts=2

    console_pid="$(_vm::_start_console_stream "$name")" || true

    if [[ -z "$console_pid" ]]; then
        log::warn "无法启动控制台流，将仅通过状态轮询监控"
    fi

    # --- Wait for IP (while console is streaming) ---
    # Wait longer before first IP check to avoid stale DHCP leases
    sleep 8
    local ip="" elapsed=8 interval=5

    while [[ -z "$ip" ]]; do
        if ! vm::is_running "$name" && ! vm::exists "$name"; then
            _vm::_kill_bg "$console_pid"
            log::separator
            log::error "VM [${name}] 已不存在"
            return 1
        fi

        ip="$(vm::get_ip "$name" 2>/dev/null)" || true
        if [[ -n "$ip" ]]; then break; fi

        # Restart console stream if it died (limited restarts)
        if [[ -n "$console_pid" ]] && ! kill -0 "$console_pid" 2>/dev/null; then
            if (( console_restarts < max_console_restarts )); then
                (( ++console_restarts ))
                console_pid="$(_vm::_start_console_stream "$name")" || true
            else
                console_pid=""
            fi
        fi

        sleep "$interval"
        (( elapsed += interval ))

        if (( elapsed >= 180 )); then
            _vm::_kill_bg "$console_pid"
            log::separator
            log::error "VM 在 180s 内未获取到 IP"
            return 1
        fi
    done

    log::ok "VM 已获取 IP: ${ip}"

    # --- Wait for SSH (while console is still streaming) ---
    elapsed=0
    local ssh_fail_count=0

    while true; do
        sleep "$interval"
        (( elapsed += interval ))

        if _vm::_ssh_test "$user" "$ip"; then
            break
        fi

        (( ++ssh_fail_count ))

        # Re-check IP every 30s of SSH failure (IP may have changed)
        if (( ssh_fail_count > 0 && ssh_fail_count % 6 == 0 )); then
            local new_ip
            new_ip="$(vm::get_ip "$name" 2>/dev/null)" || true
            if [[ -n "$new_ip" && "$new_ip" != "$ip" ]]; then
                log::info "VM IP 已变更: ${ip} -> ${new_ip}"
                ip="$new_ip"
                ssh_fail_count=0
            fi
        fi

        # Restart console stream if it died (limited restarts to avoid spam)
        if [[ -n "$console_pid" ]] && ! kill -0 "$console_pid" 2>/dev/null; then
            if (( console_restarts < max_console_restarts )); then
                (( ++console_restarts ))
                console_pid="$(_vm::_start_console_stream "$name")" || true
            else
                console_pid=""
            fi
        fi

        if (( elapsed >= 600 )); then
            _vm::_kill_bg "$console_pid"
            log::separator
            log::warn "SSH 在 600s 内未就绪，但 VM 仍在运行"
            log::info "可手动连接: ssh ${user}@${ip}"
            log::info "或查看控制台: virsh console ${name}"
            echo "$ip"
            return 0
        fi
    done

    # SSH is ready - stop console streaming, switch to SSH-based monitoring
    _vm::_kill_bg "$console_pid"
    log::separator
    log::ok "SSH 已就绪 (${user}@${ip})"

    # --- Monitor cloud-init via SSH ---
    local ci_status
    ci_status="$(_vm::_ssh_exec "$user" "$ip" "cloud-init status 2>/dev/null" 2>/dev/null || echo "unknown")"

    if echo "$ci_status" | grep -q "done"; then
        log::ok "cloud-init 已完成"
        echo "$ip"
        return 0
    fi

    log::info "cloud-init 仍在运行，通过 SSH 跟踪日志..."
    log::separator

    local tail_pid=""
    _vm::_ssh_exec "$user" "$ip" "sudo tail -n 50 -f /var/log/cloud-init-output.log 2>/dev/null" >&2 &
    tail_pid=$!

    while true; do
        sleep 10

        if ! kill -0 "$tail_pid" 2>/dev/null; then
            log::info "SSH 连接中断，等待恢复..."
            local rwait=0
            while (( rwait < 120 )); do
                sleep 5
                (( rwait += 5 ))
                if _vm::_ssh_test "$user" "$ip"; then
                    log::ok "SSH 已恢复"
                    break
                fi
            done

            ci_status="$(_vm::_ssh_exec "$user" "$ip" "cloud-init status 2>/dev/null" 2>/dev/null || echo "unknown")"
            if echo "$ci_status" | grep -q "done"; then
                log::separator
                log::ok "cloud-init 已完成"
                echo "$ip"
                return 0
            fi

            _vm::_ssh_exec "$user" "$ip" "sudo tail -n 10 -f /var/log/cloud-init-output.log 2>/dev/null" >&2 &
            tail_pid=$!
            continue
        fi

        ci_status="$(_vm::_ssh_exec "$user" "$ip" "cloud-init status 2>/dev/null" 2>/dev/null || echo "running")"

        if echo "$ci_status" | grep -q "done\|error\|recoverable"; then
            _vm::_kill_bg "$tail_pid"
            log::separator
            if echo "$ci_status" | grep -q "done"; then
                log::ok "cloud-init 已完成"
            else
                log::warn "cloud-init 完成但有错误"
                _vm::_ssh_exec "$user" "$ip" "cloud-init status --long 2>/dev/null" 2>/dev/null >&2 || true
            fi
            echo "$ip"
            return 0
        fi
    done
}

# 启动已存在的 VM 并等待 IP + SSH 就绪（不含 cloud-init 监控和控制台流）
vm::start() {
    local name="$1"
    local user="$2"

    if ! vm::exists "$name"; then
        log::error "VM [${name}] 不存在"
        return 1
    fi

    if vm::is_running "$name"; then
        log::ok "VM [${name}] 已在运行"
    else
        log::info "启动 VM [${name}]..."
        if ! _vm::virsh start "$name"; then
            log::error "启动 VM [${name}] 失败"
            return 1
        fi
        log::ok "VM [${name}] 已启动"
    fi

    # 等待 IP 地址
    log::info "等待 VM 获取 IP 地址..."
    sleep 5
    local ip="" elapsed=5 interval=3

    while [[ -z "$ip" ]]; do
        ip="$(vm::get_ip "$name" 2>/dev/null)" || true
        if [[ -n "$ip" ]]; then break; fi

        sleep "$interval"
        (( elapsed += interval ))

        if (( elapsed >= 60 )); then
            log::error "VM 在 60s 内未获取到 IP"
            return 1
        fi
    done

    log::ok "VM 已获取 IP: ${ip}"

    # 等待 SSH 就绪
    log::info "等待 SSH 就绪..."
    local ssh_elapsed=0

    while true; do
        if _vm::_ssh_test "$user" "$ip"; then
            break
        fi

        sleep "$interval"
        (( ssh_elapsed += interval ))

        if (( ssh_elapsed >= 60 )); then
            log::warn "SSH 在 60s 内未就绪，但 VM 正在运行"
            echo "$ip"
            return 0
        fi
    done

    log::ok "SSH 已就绪 (${user}@${ip})"
    echo "$ip"
    return 0
}

vm::create_disk() {
    local base_image="$1"
    local disk_path="$2"
    local disk_size="$3"

    log::info "创建 VM 磁盘: ${disk_path} (${disk_size}G)..."

    if [[ -f "$disk_path" ]]; then
        log::warn "磁盘文件已存在: ${disk_path}"
        return 0
    fi

    qemu-img create -f qcow2 -b "$base_image" -F qcow2 "$disk_path" "${disk_size}G"
    log::ok "VM 磁盘创建完成"
}

vm::create_seed_iso() {
    local user_data="$1"
    local seed_iso="$2"
    local meta_data="${3:-}"

    log::info "创建 cloud-init seed ISO..."

    local tmp_dir
    tmp_dir="$(mktemp -d)"

    cp "$user_data" "${tmp_dir}/user-data"

    if [[ -n "$meta_data" ]] && [[ -f "$meta_data" ]]; then
        cp "$meta_data" "${tmp_dir}/meta-data"
    else
        cat > "${tmp_dir}/meta-data" <<'METAEOF'
instance-id: iid-local01
local-hostname: ubuntu-server
METAEOF
    fi

    # Network config: DHCP on all ethernet interfaces
    cat > "${tmp_dir}/network-config" <<'NETEOF'
version: 2
ethernets:
  all-en:
    match:
      name: "e*"
    dhcp4: true
NETEOF

    if utils::check_command cloud-localds; then
        cloud-localds -N "${tmp_dir}/network-config" \
            "$seed_iso" "${tmp_dir}/user-data" "${tmp_dir}/meta-data"
    elif utils::check_command genisoimage; then
        genisoimage -output "$seed_iso" \
            -volid cidata -joliet -rock \
            "${tmp_dir}/user-data" "${tmp_dir}/meta-data" "${tmp_dir}/network-config"
    elif utils::check_command mkisofs; then
        mkisofs -output "$seed_iso" \
            -volid cidata -joliet -rock \
            "${tmp_dir}/user-data" "${tmp_dir}/meta-data" "${tmp_dir}/network-config"
    else
        rm -rf "$tmp_dir"
        log::die "无法创建 seed ISO：cloud-localds/genisoimage/mkisofs 均不可用"
    fi

    rm -rf "$tmp_dir"
    log::ok "seed ISO 创建完成: ${seed_iso}"
}

vm::install() {
    local name="$1"
    local disk="$2"
    local seed_iso="$3"
    local cpus="$4"
    local memory="$5"
    local network="$6"

    log::info "创建并启动 VM: ${name} (CPU: ${cpus}, 内存: ${memory}MB)..."

    local net_arg
    if [[ "$network" == "bridge:"* ]]; then
        local bridge="${network#bridge:}"
        net_arg="bridge=${bridge},model=virtio"
    else
        net_arg="network=default,model=virtio"
    fi

    sudo::exec virt-install \
        --name "$name" \
        --memory "$memory" \
        --vcpus "$cpus" \
        --disk "path=${disk},format=qcow2,bus=virtio" \
        --disk "path=${seed_iso},device=cdrom" \
        --os-variant ubuntu24.04 \
        --network "$net_arg" \
        --graphics none \
        --console pty,target_type=serial \
        --import \
        --noautoconsole \
        --check path_in_use=off

    log::ok "VM [${name}] 已创建并启动"
}

vm::destroy() {
    local name="$1"
    local data_dir="${2:-}"

    if ! vm::exists "$name"; then
        log::warn "VM [${name}] 不存在"
        return 0
    fi

    if vm::is_running "$name"; then
        log::info "停止 VM [${name}]..."
        _vm::virsh destroy "$name" || log::warn "停止 VM 失败，继续清理..."
        sleep 2
    fi

    log::info "删除 VM 定义..."
    _vm::virsh undefine "$name" || log::warn "删除 VM 定义失败"

    # Verify it's actually gone
    if vm::exists "$name"; then
        log::warn "VM 定义仍然存在，尝试强制删除..."
        _vm::virsh undefine "$name" --managed-save --snapshots-metadata 2>/dev/null || true
    fi

    # Manually remove VM-specific files (not the base cloud image)
    if [[ -n "$data_dir" ]]; then
        log::info "清理 VM 磁盘文件..."
        sudo rm -f "${data_dir:?}/${name}.qcow2" \
                   "${data_dir:?}/${name}-seed.iso" \
                   "${data_dir:?}/user-data.yaml"
    fi

    log::ok "VM [${name}] 已销毁"
}

vm::status() {
    local name="$1"

    if ! vm::exists "$name"; then
        log::warn "VM [${name}] 不存在"
        return 1
    fi

    local state
    state="$(_vm::virsh domstate "$name" 2>/dev/null)"

    echo "VM 名称:  ${name}"
    echo "运行状态: ${state}"

    if [[ "$state" == "running" ]]; then
        local ip
        if ip="$(vm::get_ip "$name")"; then
            echo "IP 地址:  ${ip}"
        else
            echo "IP 地址:  (获取中...)"
        fi

        local info
        info="$(_vm::virsh dominfo "$name" 2>/dev/null)"
        local cpus mem
        cpus="$(echo "$info" | grep "CPU(s):" | awk '{print $2}')"
        mem="$(echo "$info" | grep "Used memory:" | awk '{print $3}')"
        echo "CPU:      ${cpus} 核"
        if [[ -n "$mem" ]]; then
            echo "内存:     $(( mem / 1024 )) MB"
        fi
    fi
}
