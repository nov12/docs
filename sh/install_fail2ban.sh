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

DELETE_SELF=true


# -------------------------------------------------------------
# 输出
# -------------------------------------------------------------

log() {
    printf '==> %s\n' "$*"
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
#
# sshd -T 会解析 sshd_config 和 sshd_config.d，
# 比直接 grep 配置文件可靠。
#
# 若当前就是通过 SSH 执行，再加入当前连接实际使用的
# 服务端端口，降低错误配置导致远程锁死的风险。
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
#
# UFW 负责访问控制。
# SSH 暴力破解交给 fail2ban，不额外配置 ufw limit，
# 避免重复规则和策略职责混乱。
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

cleanup() {
    rm -f -- "${tmp_jail}"
}
trap cleanup EXIT

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
# 安装配置
#
# 使用独立的 jail.d/*.local，而不是覆盖 jail.local。
#
# 99-ssh-hardening.local：
#   - 与系统默认配置分离
#   - 与用户自己的 jail.local 分离
#   - 加载优先级较高
#   - 明确属于本脚本管理
# -------------------------------------------------------------

install -d -m 0755 "${JAIL_DIR}"

if [[ -f ${JAIL_FILE} ]]; then
    backup_file="$(mktemp "${JAIL_FILE}.XXXXXX.bak")"

    cp -a \
        "${JAIL_FILE}" \
        "${backup_file}"

    log "已临时备份原配置：${backup_file}"
fi

install \
    -m 0644 \
    "${tmp_jail}" \
    "${JAIL_FILE}"


# -------------------------------------------------------------
# 回滚配置
# -------------------------------------------------------------

rollback_config() {
    if [[ -n ${backup_file} && -f ${backup_file} ]]; then
        mv -f "${backup_file}" "${JAIL_FILE}"
        printf '已恢复原配置：%s\n' "${JAIL_FILE}" >&2
    else
        rm -f -- "${JAIL_FILE}"
        printf '已移除本次新增配置：%s\n' "${JAIL_FILE}" >&2
    fi
}


# -------------------------------------------------------------
# 配置校验
# -------------------------------------------------------------

log "校验 fail2ban 配置 ..."

if ! fail2ban-client -t; then
    rollback_config
    die "fail2ban 配置校验失败，新配置未应用"
fi


# -------------------------------------------------------------
# 启动 fail2ban
# -------------------------------------------------------------

log "启用并重启 fail2ban ..."

systemctl enable fail2ban

if ! systemctl restart fail2ban; then
    printf '错误：fail2ban 启动失败\n' >&2

    rollback_config
    systemctl restart fail2ban || true

    exit 1
fi

if ! systemctl is-active --quiet fail2ban; then
    rollback_config
    systemctl restart fail2ban || true

    die "fail2ban 未正常运行，请检查：journalctl -u fail2ban"
fi


# -------------------------------------------------------------
# 状态检查
# -------------------------------------------------------------

log "fail2ban SSH jail 状态："

if ! fail2ban-client status sshd; then
    rollback_config
    systemctl restart fail2ban || true

    die "fail2ban 已启动，但 sshd jail 未正常加载"
fi


# -------------------------------------------------------------
# 安装成功
# -------------------------------------------------------------

# 到这里才说明新配置完整通过：
#   - 语法检查
#   - 服务启动
#   - daemon 状态
#   - sshd jail 状态

if [[ -n ${backup_file} ]]; then
    rm -f -- "${backup_file}"
fi

log "UFW 状态："
ufw status verbose

printf '\n'


# -------------------------------------------------------------
# 自动删除脚本
# -------------------------------------------------------------

if [[ ${DELETE_SELF} == true ]]; then
    script_path="${BASH_SOURCE[0]:-}"

    # curl ... | bash 时 BASH_SOURCE 为空，不执行删除。
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
