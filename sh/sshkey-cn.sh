#!/usr/bin/env bash
#
# sshkey.sh
#
# 适用环境：
#   Debian / Ubuntu
#   OpenSSH
#   systemd
#
# 功能：
#   1. 从 GitHub 下载并验证 SSH 公钥
#   2. 安装、覆盖或合并 authorized_keys
#   3. 可选关闭 SSH 密码认证
#   4. 可选修改 SSH 端口
#   5. 使用独立 sshd_config.d 配置文件
#   6. 使用 sshd -t 和 sshd -T 验证配置
#   7. 配置失败自动恢复
#   8. 可选修改当前用户密码
#   9. 可选创建 sudo 用户
#  10. 执行成功后可删除脚本，默认删除
#

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# ============================================================
# 配置
# ============================================================

GITHUB_USER="${GITHUB_USER:-nov12}"
KEYS_URL="https://github.com/${GITHUB_USER}.keys"

SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSHD_DROPIN="${SSHD_DROPIN_DIR}/00-sshkey.conf"

# ============================================================
# 通用函数
# ============================================================

die() {
    echo "错误：$*" >&2
    exit 1
}

info() {
    echo "==> $*"
}

warn() {
    echo "警告：$*" >&2
}

# 默认否
ask() {
    local answer

    read -r -p "$1 [y/N] " answer

    case "$answer" in
        y|Y|yes|YES|Yes)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# 默认是
ask_yes() {
    local answer

    read -r -p "$1 [Y/n] " answer

    case "$answer" in
        n|N|no|NO|No)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

# ============================================================
# 环境检查
# ============================================================

check_env() {
    if (( EUID == 0 )); then
        SUDO=()
    else
        command -v sudo >/dev/null ||
            die "当前用户不是 root，且系统没有 sudo。"

        sudo -v ||
            die "无法获取 sudo 权限。"

        SUDO=(sudo)
    fi

    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        TARGET_USER="${SUDO_USER}"
    else
        TARGET_USER="$(id -un)"
    fi

    TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
    TARGET_GROUP="$(id -gn "${TARGET_USER}")"

    [[ -n "${TARGET_HOME}" ]] ||
        die "无法确定用户 ${TARGET_USER} 的主目录。"

    command -v ssh-keygen >/dev/null ||
        die "未找到 ssh-keygen。"

    command -v openssl >/dev/null ||
        die "未找到 openssl。"

    command -v systemctl >/dev/null ||
        die "未找到 systemctl。"

    if command -v sshd >/dev/null; then
        SSHD_BIN="$(command -v sshd)"
    elif [[ -x /usr/sbin/sshd ]]; then
        SSHD_BIN="/usr/sbin/sshd"
    else
        die "未找到 sshd。"
    fi

    [[ -f "${SSHD_CONFIG}" ]] ||
        die "找不到 ${SSHD_CONFIG}。"

    if ! command -v curl >/dev/null &&
       ! command -v wget >/dev/null; then
        die "需要安装 curl 或 wget。"
    fi

    info "目标用户：${TARGET_USER}"
    info "主目录：${TARGET_HOME}"
}

# ============================================================
# 下载 GitHub 公钥
# ============================================================

download_keys() {
    KEYS_FILE="$(mktemp)"

    info "正在从 GitHub 下载 ${GITHUB_USER} 的 SSH 公钥……"

    if command -v curl >/dev/null; then
        curl \
            --fail \
            --silent \
            --show-error \
            --location \
            --proto '=https' \
            --connect-timeout 10 \
            --max-time 30 \
            "${KEYS_URL}" \
            -o "${KEYS_FILE}"
    else
        wget \
            --quiet \
            --https-only \
            --timeout=30 \
            -O "${KEYS_FILE}" \
            "${KEYS_URL}"
    fi

    [[ -s "${KEYS_FILE}" ]] ||
        die "下载到的 SSH 公钥为空。"

    ssh-keygen -lf "${KEYS_FILE}" >/dev/null 2>&1 ||
        die "GitHub 返回的内容不是有效的 SSH 公钥。"

    info "SSH 公钥验证成功。"

    ssh-keygen -lf "${KEYS_FILE}"
}

# ============================================================
# 安装 SSH 公钥
# ============================================================

install_keys() {
    local ssh_dir
    local authorized_keys
    local backup
    local merged

    ssh_dir="${TARGET_HOME}/.ssh"
    authorized_keys="${ssh_dir}/authorized_keys"

    "${SUDO[@]}" install \
        -d \
        -m 700 \
        -o "${TARGET_USER}" \
        -g "${TARGET_GROUP}" \
        "${ssh_dir}"

    if [[ -f "${authorized_keys}" ]]; then

        if ask "authorized_keys 已存在，是否覆盖？不覆盖则自动合并并去重。"; then

            backup="${authorized_keys}.bak.$(date +%Y%m%d-%H%M%S)"

            "${SUDO[@]}" cp -a \
                "${authorized_keys}" \
                "${backup}"

            info "原公钥已备份到 ${backup}"

            "${SUDO[@]}" install \
                -m 600 \
                -o "${TARGET_USER}" \
                -g "${TARGET_GROUP}" \
                "${KEYS_FILE}" \
                "${authorized_keys}"

        else
            merged="$(mktemp)"

            {
                "${SUDO[@]}" cat "${authorized_keys}"
                cat "${KEYS_FILE}"
            } |
                awk '
                    NF && !seen[$0]++ {
                        print
                    }
                ' > "${merged}"

            "${SUDO[@]}" install \
                -m 600 \
                -o "${TARGET_USER}" \
                -g "${TARGET_GROUP}" \
                "${merged}" \
                "${authorized_keys}"

            rm -f "${merged}"

            info "公钥已合并并去重。"
        fi

    else
        "${SUDO[@]}" install \
            -m 600 \
            -o "${TARGET_USER}" \
            -g "${TARGET_GROUP}" \
            "${KEYS_FILE}" \
            "${authorized_keys}"
    fi

    info "SSH 公钥安装完成。"
}

# ============================================================
# 配置 SSH
# ============================================================

configure_sshd() {
    local disable_password=0
    local change_port=0
    local ssh_port=""
    local new_config
    local backup=""
    local old_exists=0
    local effective

    if ask "是否关闭 SSH 密码认证？"; then
        disable_password=1
    fi

    if ask "是否修改 SSH 端口？"; then

        if systemctl is-active --quiet ssh.socket 2>/dev/null; then
            warn "检测到 ssh.socket 正在管理 SSH 监听端口。"
            warn "为避免错误修改，本脚本不会自动处理 ssh.socket。"
            die "请先手动处理 ssh.socket，再修改 SSH 端口。"
        fi

        while true; do
            read -r -p "请输入新的 SSH 端口 [1024-65535]：" ssh_port

            if [[ "${ssh_port}" =~ ^[0-9]+$ ]] &&
               (( ssh_port >= 1024 && ssh_port <= 65535 )); then
                break
            fi

            echo "端口必须是 1024-65535 之间的整数。"
        done

        change_port=1
    fi

    if (( !disable_password && !change_port )); then
        info "没有修改 SSH 服务配置。"
        return
    fi

    "${SUDO[@]}" install \
        -d \
        -m 755 \
        "${SSHD_DROPIN_DIR}"

    new_config="$(mktemp)"

    {
        echo "# 此文件由 sshkey.sh 管理"
        echo "PubkeyAuthentication yes"
        echo "PermitEmptyPasswords no"

        if (( disable_password )); then
            echo "PasswordAuthentication no"
            echo "KbdInteractiveAuthentication no"
        fi

        if (( change_port )); then
            echo "Port ${ssh_port}"
        fi
    } > "${new_config}"

    if [[ -f "${SSHD_DROPIN}" ]]; then
        backup="$(mktemp)"

        # 只备份内容，避免 sudo cp -a 改变临时文件所有权
        "${SUDO[@]}" cat "${SSHD_DROPIN}" > "${backup}"

        old_exists=1
    fi

    "${SUDO[@]}" install \
        -m 644 \
        -o root \
        -g root \
        "${new_config}" \
        "${SSHD_DROPIN}"

    rm -f "${new_config}"

    restore_sshd() {
        warn "正在恢复原 SSH 配置……"

        if (( old_exists )); then
            "${SUDO[@]}" install \
                -m 644 \
                -o root \
                -g root \
                "${backup}" \
                "${SSHD_DROPIN}"
        else
            "${SUDO[@]}" rm -f "${SSHD_DROPIN}"
        fi

        "${SUDO[@]}" systemctl reload ssh.service 2>/dev/null ||
        "${SUDO[@]}" systemctl reload sshd.service 2>/dev/null ||
        true
    }

    info "正在验证 SSH 配置……"

    if ! "${SUDO[@]}" "${SSHD_BIN}" -t; then
        restore_sshd
        die "SSH 配置语法验证失败，原配置已恢复。"
    fi

    effective="$("${SUDO[@]}" "${SSHD_BIN}" -T)"

    if ! grep -qx "pubkeyauthentication yes" <<< "${effective}"; then
        restore_sshd
        die "PubkeyAuthentication 没有实际生效，原配置已恢复。"
    fi

    if (( disable_password )); then

        if ! grep -qx "passwordauthentication no" <<< "${effective}"; then
            restore_sshd
            die "PasswordAuthentication 没有实际生效，原配置已恢复。"
        fi

        if ! grep -qx "kbdinteractiveauthentication no" <<< "${effective}"; then
            restore_sshd
            die "KbdInteractiveAuthentication 没有实际生效，原配置已恢复。"
        fi
    fi

    if (( change_port )); then

        if ! grep -qx "port ${ssh_port}" <<< "${effective}"; then
            restore_sshd
            die "SSH 端口 ${ssh_port} 没有实际生效，原配置已恢复。"
        fi
    fi

    if "${SUDO[@]}" systemctl is-active --quiet ssh.service; then

        if ! "${SUDO[@]}" systemctl reload ssh.service; then
            restore_sshd
            die "重新加载 SSH 服务失败，原配置已恢复。"
        fi

    elif "${SUDO[@]}" systemctl is-active --quiet sshd.service; then

        if ! "${SUDO[@]}" systemctl reload sshd.service; then
            restore_sshd
            die "重新加载 SSH 服务失败，原配置已恢复。"
        fi

    else
        restore_sshd
        die "没有找到正在运行的 SSH 服务，原配置已恢复。"
    fi

    rm -f "${backup:-}"

    info "SSH 服务配置已成功应用。"

    if (( change_port )); then
        echo
        warn "SSH 端口已修改为 ${ssh_port}。"
        warn "请自行确认防火墙、云安全组等已经放行 TCP ${ssh_port}。"
        warn "不要关闭当前 SSH 会话，请先使用另一个终端测试新连接。"
        echo
        echo "测试命令："
        echo "ssh -p ${ssh_port} ${TARGET_USER}@服务器地址"
    fi
}

# ============================================================
# 修改当前用户密码
# ============================================================

change_password() {
    local password

    if ! ask "是否修改 ${TARGET_USER} 的本地密码？"; then
        return
    fi

    password="$(openssl rand -base64 18)"

    printf '%s:%s\n' \
        "${TARGET_USER}" \
        "${password}" |
        "${SUDO[@]}" chpasswd

    echo
    echo "用户 ${TARGET_USER} 的新密码："
    echo "${password}"
    echo

    warn "请立即保存该密码。"
}

# ============================================================
# 创建新 sudo 用户
# ============================================================

create_user() {
    local username
    local home
    local group
    local password

    read -r -p "输入要创建的新 sudo 用户名，直接回车跳过：" username

    [[ -z "${username}" ]] &&
        return

    [[ "${username}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] ||
        die "用户名格式不合法。"

    if id "${username}" >/dev/null 2>&1; then
        die "用户 ${username} 已经存在。"
    fi

    getent group sudo >/dev/null ||
        die "系统不存在 sudo 用户组。"

    command -v adduser >/dev/null ||
        die "系统没有 adduser 命令。"

    "${SUDO[@]}" adduser \
        --disabled-password \
        --gecos "" \
        "${username}"

    "${SUDO[@]}" usermod \
        -aG sudo \
        "${username}"

    home="$(getent passwd "${username}" | cut -d: -f6)"
    group="$(id -gn "${username}")"

    [[ -n "${home}" ]] ||
        die "无法确定新用户的主目录。"

    "${SUDO[@]}" install \
        -d \
        -m 700 \
        -o "${username}" \
        -g "${group}" \
        "${home}/.ssh"

    "${SUDO[@]}" install \
        -m 600 \
        -o "${username}" \
        -g "${group}" \
        "${KEYS_FILE}" \
        "${home}/.ssh/authorized_keys"

    info "用户 ${username} 创建完成，并已加入 sudo 用户组。"
    info "SSH 公钥安装完成。"

    if ask_yes "是否为 ${username} 设置随机密码？sudo 默认需要该密码。"; then

        password="$(openssl rand -base64 18)"

        printf '%s:%s\n' \
            "${username}" \
            "${password}" |
            "${SUDO[@]}" chpasswd

        echo
        echo "用户 ${username} 的密码："
        echo "${password}"
        echo

        warn "请立即保存该密码。"

    else
        warn "用户 ${username} 当前没有可用密码。"
        warn "在 Debian/Ubuntu 默认 sudo 配置下，该用户通常无法通过 sudo 密码认证。"
    fi
}

# ============================================================
# 删除脚本
# ============================================================

delete_self() {
    local script

    if ! ask_yes "是否删除本脚本？"; then
        info "已保留本脚本。"
        return
    fi

    script="${BASH_SOURCE[0]:-}"

    if [[ -z "${script}" || ! -f "${script}" ]]; then
        warn "没有检测到可删除的脚本文件，可能是通过管道执行。"
        return
    fi

    if rm -- "${script}" 2>/dev/null; then
        info "本脚本已删除。"
    else
        warn "无法删除本脚本：${script}"
    fi
}

# ============================================================
# 主程序
# ============================================================

main() {
    trap 'rm -f "${KEYS_FILE:-}"' EXIT

    check_env
    download_keys
    install_keys
    configure_sshd
    change_password
    create_user

    echo
    echo "============================================================"
    echo "配置完成"
    echo "============================================================"
    echo
    echo "GitHub 用户：${GITHUB_USER}"
    echo "目标用户：${TARGET_USER}"
    echo
    warn "确认新的 SSH 连接正常之前，请不要关闭当前 SSH 会话。"
    echo

    delete_self
}

main "$@"
