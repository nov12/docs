#!/usr/bin/env bash
# =============================================================
# install_fail2ban.sh
#
# 配置 UFW + fail2ban SSH 防护
# 适用：Debian / Ubuntu
#
# 用法：
#   sudo bash install_fail2ban.sh
#   sudo bash install_fail2ban.sh --keep
#
# 参数：
#   --keep      安装成功后保留本脚本
#   -h, --help  显示帮助
#
# 默认：
#   安装成功后自动删除本脚本
# =============================================================

set -Eeuo pipefail


# -------------------------------------------------------------
# 配置
# -------------------------------------------------------------

readonly JAIL_URL="https://raw.githubusercontent.com/nov12/docs/main/config/fail2ban/99-ssh-hardening.local"
readonly JAIL_DIR="/etc/fail2ban/jail.d"
readonly JAIL_FILE="${JAIL_DIR}/99-ssh-hardening.local"
readonly JAIL_NAME="sshd"

readonly FAIL2BAN_READY_TIMEOUT=30
readonly JAIL_READY_TIMEOUT=30

DELETE_SELF=true


# -------------------------------------------------------------
# 输出
# -------------------------------------------------------------

log() {
    printf '==> %s\n' "$*"
}

warn() {
    printf '警告：%s\n' "$*" >&2
}

die() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
用法：
  sudo bash install_fail2ban.sh [选项]

选项：
  --keep      安装成功后保留本脚本
  -h, --help  显示帮助

默认行为：
  安装成功后自动删除本脚本。
EOF
}


# -------------------------------------------------------------
# 参数
# -------------------------------------------------------------

while (( $# > 0 )); do
    case "$1" in
        --keep)
            DELETE_SELF=false
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf '错误：未知参数：%s\n\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac

    shift
done


# -------------------------------------------------------------
# 基础检查
# -------------------------------------------------------------

[[ ${EUID} -eq 0 ]] ||
    die "请使用 root 或 sudo 运行"

command -v apt-get >/dev/null 2>&1 ||
    die "仅支持使用 apt 的 Debian / Ubuntu 系统"


# -------------------------------------------------------------
# 安装依赖
# -------------------------------------------------------------

log "安装 UFW、fail2ban 及下载依赖 ..."

apt-get update
apt-get install -y \
    ufw \
    fail2ban \
    curl \
    ca-certificates


# -------------------------------------------------------------
# 检测 SSH 端口
# -------------------------------------------------------------

mapfile -t SSH_PORTS < <(
    {
        if command -v sshd >/dev/null 2>&1; then
            sshd -T 2>/dev/null |
                awk '$1 == "port" {print $2}'
        fi

        if [[ -n ${SSH_CONNECTION:-} ]]; then
            awk '{print $4}' <<<"${SSH_CONNECTION}"
        fi
    } |
        awk '
            /^[0-9]+$/ && $1 >= 1 && $1 <= 65535 {
                if (!seen[$1]++)
                    print $1
            }
        '
)

if (( ${#SSH_PORTS[@]} == 0 )); then
    SSH_PORTS=(22)
    log "未检测到 SSH 端口，使用默认 22/tcp"
fi


# -------------------------------------------------------------
# 配置 UFW
# -------------------------------------------------------------

log "放行 SSH 端口：${SSH_PORTS[*]}"

for port in "${SSH_PORTS[@]}"; do
    ufw allow "${port}/tcp" comment 'SSH'
done

if ufw status | grep -q '^Status: active'; then
    log "UFW 已启用"
else
    log "启用 UFW ..."
    ufw --force enable
fi


# -------------------------------------------------------------
# 下载 fail2ban 配置
# -------------------------------------------------------------

log "下载 fail2ban SSH 配置 ..."
log "配置来源：${JAIL_URL}"

tmp_jail="$(mktemp)"
backup_file=""
rollback_needed=false

curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --retry 3 \
    --retry-delay 1 \
    --connect-timeout 10 \
    "${JAIL_URL}" \
    --output "${tmp_jail}"

[[ -s ${tmp_jail} ]] ||
    die "下载到的 fail2ban 配置为空"

log "配置 SHA256：$(sha256sum "${tmp_jail}" | awk '{print $1}')"


# -------------------------------------------------------------
# 回滚
# -------------------------------------------------------------

rollback_config() {
    [[ ${rollback_needed} == true ]] || return 0

    if [[ -n ${backup_file} && -f ${backup_file} ]]; then
        mv -f -- "${backup_file}" "${JAIL_FILE}"
        printf '已恢复原配置：%s\n' "${JAIL_FILE}" >&2
    else
        rm -f -- "${JAIL_FILE}"
        printf '已移除本次新增配置：%s\n' "${JAIL_FILE}" >&2
    fi

    rollback_needed=false
}


rollback_and_die() {
    local message="$1"

    printf '正在回滚 fail2ban 配置 ...\n' >&2

    if rollback_config; then
        if ! systemctl restart fail2ban; then
            warn "配置已回滚，但 fail2ban 重新启动失败"
            warn "请检查：journalctl -u fail2ban"
        fi
    else
        warn "自动回滚失败，请立即检查：${JAIL_FILE}"
    fi

    die "${message}"
}


# -------------------------------------------------------------
# 清理
#
# rollback_needed=true 表示新配置已经写入，但尚未通过
# 完整验证。若脚本异常退出，尽量恢复原配置。
# -------------------------------------------------------------

cleanup() {
    local exit_code=$?

    rm -f -- "${tmp_jail}"

    if [[ ${rollback_needed} == true ]]; then
        printf '检测到安装异常中断，正在回滚 fail2ban 配置 ...\n' >&2

        if rollback_config; then
            systemctl restart fail2ban >/dev/null 2>&1 ||
                warn "配置已回滚，但 fail2ban 重新启动失败"
        else
            warn "自动回滚失败，请立即检查：${JAIL_FILE}"
        fi
    fi

    if [[ -n ${backup_file} && -f ${backup_file} ]]; then
        rm -f -- "${backup_file}"
    fi

    return "${exit_code}"
}

trap cleanup EXIT


# -------------------------------------------------------------
# 安装配置
# -------------------------------------------------------------

install -d -m 0755 "${JAIL_DIR}"

if [[ -f ${JAIL_FILE} ]]; then
    backup_file="$(mktemp "${JAIL_FILE}.XXXXXX.bak")"
    cp -a -- "${JAIL_FILE}" "${backup_file}"

    log "已临时备份原配置：${backup_file}"
fi

install -m 0644 "${tmp_jail}" "${JAIL_FILE}"

# 从这里开始，任何失败都需要恢复原配置。
rollback_needed=true


# -------------------------------------------------------------
# 配置校验
# -------------------------------------------------------------

log "校验 fail2ban 配置 ..."

if ! fail2ban-client -t; then
    rollback_and_die "fail2ban 配置校验失败，新配置未应用"
fi


# -------------------------------------------------------------
# 等待 fail2ban server / socket 就绪
# -------------------------------------------------------------

wait_for_fail2ban() {
    local timeout="$1"
    local deadline=$((SECONDS + timeout))

    while (( SECONDS < deadline )); do
        if fail2ban-client ping >/dev/null 2>&1; then
            return 0
        fi

        # 已明确进入 failed 状态，无需继续等待。
        if systemctl is-failed --quiet fail2ban; then
            return 1
        fi

        sleep 1
    done

    # 超时边界再检查一次，避免刚好在最后一秒就绪。
    fail2ban-client ping >/dev/null 2>&1
}


# -------------------------------------------------------------
# 等待指定 jail 就绪
# -------------------------------------------------------------

wait_for_jail() {
    local jail="$1"
    local timeout="$2"
    local deadline=$((SECONDS + timeout))

    while (( SECONDS < deadline )); do
        if fail2ban-client status "${jail}" >/dev/null 2>&1; then
            return 0
        fi

        if systemctl is-failed --quiet fail2ban; then
            return 1
        fi

        sleep 1
    done

    fail2ban-client status "${jail}" >/dev/null 2>&1
}


# -------------------------------------------------------------
# 启动 fail2ban
# -------------------------------------------------------------

log "启用并重启 fail2ban ..."

if ! systemctl enable fail2ban; then
    rollback_and_die "无法启用 fail2ban 服务"
fi

if ! systemctl restart fail2ban; then
    rollback_and_die "fail2ban 启动失败"
fi


# -------------------------------------------------------------
# 等待 server / socket
# -------------------------------------------------------------

log "等待 fail2ban daemon 就绪 ..."

if ! wait_for_fail2ban "${FAIL2BAN_READY_TIMEOUT}"; then
    rollback_and_die \
        "fail2ban daemon 在 ${FAIL2BAN_READY_TIMEOUT} 秒内未就绪，请检查：journalctl -u fail2ban"
fi

if ! systemctl is-active --quiet fail2ban; then
    rollback_and_die \
        "fail2ban daemon 可响应，但 systemd 服务状态异常"
fi


# -------------------------------------------------------------
# 等待 SSH jail
# -------------------------------------------------------------

log "等待 ${JAIL_NAME} jail 就绪 ..."

if ! wait_for_jail "${JAIL_NAME}" "${JAIL_READY_TIMEOUT}"; then
    rollback_and_die \
        "${JAIL_NAME} jail 在 ${JAIL_READY_TIMEOUT} 秒内未正常加载"
fi


# -------------------------------------------------------------
# 最终状态
# -------------------------------------------------------------

log "fail2ban SSH jail 状态："
fail2ban-client status "${JAIL_NAME}"


# -------------------------------------------------------------
# 提交配置
#
# 到这里说明新配置已经通过：
#   - 配置语法检查
#   - systemd 启动
#   - fail2ban server/socket 响应
#   - sshd jail 加载
# -------------------------------------------------------------

rollback_needed=false

if [[ -n ${backup_file} ]]; then
    rm -f -- "${backup_file}"
    backup_file=""
fi

log "UFW 状态："
ufw status verbose

printf '\n'


# -------------------------------------------------------------
# 自动删除脚本
# -------------------------------------------------------------

if [[ ${DELETE_SELF} == true ]]; then
    script_path="${BASH_SOURCE[0]:-}"

    # curl ... | bash 等没有普通脚本文件的情况不执行删除。
    if [[ -n ${script_path} && -f ${script_path} ]]; then
        log "删除安装脚本 ..."
        rm -f -- "${script_path}"
    fi
fi


# -------------------------------------------------------------
# 完成
# -------------------------------------------------------------

log "安装完成"
log "SSH 端口：${SSH_PORTS[*]}"
log "fail2ban 配置：${JAIL_FILE}"
