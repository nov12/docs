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
    echo "Error: $*" >&2
    exit 1
}

info() {
    echo "==> $*"
}

warn() {
    echo "Warning: $*" >&2
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
            die "The current user is not root and sudo is not installed."

        sudo -v ||
            die "Unable to obtain sudo privileges."

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
        die "Unable to determine the home directory of user ${TARGET_USER}."

    command -v ssh-keygen >/dev/null ||
        die "ssh-keygen was not found."

    command -v openssl >/dev/null ||
        die "openssl was not found."

    command -v systemctl >/dev/null ||
        die "systemctl was not found."

    if command -v sshd >/dev/null; then
        SSHD_BIN="$(command -v sshd)"
    elif [[ -x /usr/sbin/sshd ]]; then
        SSHD_BIN="/usr/sbin/sshd"
    else
        die "sshd was not found."
    fi

    [[ -f "${SSHD_CONFIG}" ]] ||
        die "Cannot find ${SSHD_CONFIG}."

    if ! command -v curl >/dev/null &&
       ! command -v wget >/dev/null; then
        die "curl or wget must be installed."
    fi

    info "Target user: ${TARGET_USER}"
    info "Home directory: ${TARGET_HOME}"
}

# ============================================================
# 下载 GitHub 公钥
# ============================================================

download_keys() {
    KEYS_FILE="$(mktemp)"

    info "Downloading SSH public keys for ${GITHUB_USER} from GitHub..."

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
        die "The downloaded SSH public key file is empty."

    ssh-keygen -lf "${KEYS_FILE}" >/dev/null 2>&1 ||
        die "The content returned by GitHub is not a valid SSH public key."

    info "SSH public key validation succeeded."

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

        if ask "authorized_keys already exists. Overwrite it? If not, the keys will be merged and deduplicated automatically."; then

            backup="${authorized_keys}.bak.$(date +%Y%m%d-%H%M%S)"

            "${SUDO[@]}" cp -a \
                "${authorized_keys}" \
                "${backup}"

            info "Existing public keys have been backed up to ${backup}"

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

            info "Public keys have been merged and deduplicated."
        fi

    else
        "${SUDO[@]}" install \
            -m 600 \
            -o "${TARGET_USER}" \
            -g "${TARGET_GROUP}" \
            "${KEYS_FILE}" \
            "${authorized_keys}"
    fi

    info "SSH public key installation completed."
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

    if ask "Disable SSH password authentication?"; then
        disable_password=1
    fi

    if ask "Change the SSH port?"; then

        if systemctl is-active --quiet ssh.socket 2>/dev/null; then
            warn "ssh.socket is currently managing the SSH listening port."
            warn "To avoid incorrect changes, this script will not modify ssh.socket automatically."
            die "Please handle ssh.socket manually before changing the SSH port."
        fi

        while true; do
            read -r -p "Enter the new SSH port [1024-65535]: " ssh_port

            if [[ "${ssh_port}" =~ ^[0-9]+$ ]] &&
               (( ssh_port >= 1024 && ssh_port <= 65535 )); then
                break
            fi

            echo "The port must be an integer between 1024 and 65535."
        done

        change_port=1
    fi

    if (( !disable_password && !change_port )); then
        info "No SSH service configuration changes were made."
        return
    fi

    "${SUDO[@]}" install \
        -d \
        -m 755 \
        "${SSHD_DROPIN_DIR}"

    new_config="$(mktemp)"

    {
        echo "# This file is managed by sshkey.sh"
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
        warn "Restoring the previous SSH configuration..."

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

    info "Validating the SSH configuration..."

    if ! "${SUDO[@]}" "${SSHD_BIN}" -t; then
        restore_sshd
        die "SSH configuration syntax validation failed. The previous configuration has been restored."
    fi

    effective="$("${SUDO[@]}" "${SSHD_BIN}" -T)"

    if ! grep -qx "pubkeyauthentication yes" <<< "${effective}"; then
        restore_sshd
        die "PubkeyAuthentication did not take effect. The previous configuration has been restored."
    fi

    if (( disable_password )); then

        if ! grep -qx "passwordauthentication no" <<< "${effective}"; then
            restore_sshd
            die "PasswordAuthentication did not take effect. The previous configuration has been restored."
        fi

        if ! grep -qx "kbdinteractiveauthentication no" <<< "${effective}"; then
            restore_sshd
            die "KbdInteractiveAuthentication did not take effect. The previous configuration has been restored."
        fi
    fi

    if (( change_port )); then

        if ! grep -qx "port ${ssh_port}" <<< "${effective}"; then
            restore_sshd
            die "SSH port ${ssh_port} did not take effect. The previous configuration has been restored."
        fi
    fi

    if "${SUDO[@]}" systemctl is-active --quiet ssh.service; then

        if ! "${SUDO[@]}" systemctl reload ssh.service; then
            restore_sshd
            die "Failed to reload the SSH service. The previous configuration has been restored."
        fi

    elif "${SUDO[@]}" systemctl is-active --quiet sshd.service; then

        if ! "${SUDO[@]}" systemctl reload sshd.service; then
            restore_sshd
            die "Failed to reload the SSH service. The previous configuration has been restored."
        fi

    else
        restore_sshd
        die "No running SSH service was found. The previous configuration has been restored."
    fi

    rm -f "${backup:-}"

    info "SSH service configuration was applied successfully."

    if (( change_port )); then
        echo
        warn "The SSH port has been changed to ${ssh_port}."
        warn "Make sure your firewall, cloud security group, and related rules allow TCP ${ssh_port}."
        warn "Do not close the current SSH session. Test the new connection from another terminal first."
        echo
        echo "Test command:"
        echo "ssh -p ${ssh_port} ${TARGET_USER}@server-address"
    fi
}

# ============================================================
# 修改当前用户密码
# ============================================================

change_password() {
    local password

    if ! ask "Change the local password for ${TARGET_USER}?"; then
        return
    fi

    password="$(openssl rand -base64 18)"

    printf '%s:%s\n' \
        "${TARGET_USER}" \
        "${password}" |
        "${SUDO[@]}" chpasswd

    echo
    echo "New password for user ${TARGET_USER}:"
    echo "${password}"
    echo

    warn "Save this password immediately."
}

# ============================================================
# 创建新 sudo 用户
# ============================================================

create_user() {
    local username
    local home
    local group
    local password

    read -r -p "Enter a new sudo username, or press Enter to skip: " username

    [[ -z "${username}" ]] &&
        return

    [[ "${username}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] ||
        die "Invalid username format."

    if id "${username}" >/dev/null 2>&1; then
        die "User ${username} already exists."
    fi

    getent group sudo >/dev/null ||
        die "The sudo group does not exist on this system."

    command -v adduser >/dev/null ||
        die "The adduser command is not available on this system."

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
        die "Unable to determine the new user's home directory."

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

    info "User ${username} has been created and added to the sudo group."
    info "SSH public key installation completed."

    if ask_yes "Set a random password for ${username}? sudo requires this password by default."; then

        password="$(openssl rand -base64 18)"

        printf '%s:%s\n' \
            "${username}" \
            "${password}" |
            "${SUDO[@]}" chpasswd

        echo
        echo "Password for user ${username}:"
        echo "${password}"
        echo

        warn "Save this password immediately."

    else
        warn "User ${username} currently has no usable password."
        warn "With the default Debian/Ubuntu sudo configuration, this user will usually be unable to authenticate to sudo with a password."
    fi
}

# ============================================================
# 删除脚本
# ============================================================

delete_self() {
    local script

    if ! ask_yes "Delete this script?"; then
        info "This script has been kept."
        return
    fi

    script="${BASH_SOURCE[0]:-}"

    if [[ -z "${script}" || ! -f "${script}" ]]; then
        warn "No deletable script file was detected; the script may have been executed through a pipe."
        return
    fi

    if rm -- "${script}" 2>/dev/null; then
        info "This script has been deleted."
    else
        warn "Unable to delete this script: ${script}"
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
    echo "Configuration completed"
    echo "============================================================"
    echo
    echo "GitHub user: ${GITHUB_USER}"
    echo "Target user: ${TARGET_USER}"
    echo
    warn "Do not close the current SSH session until you have confirmed that the new SSH connection works."
    echo

    delete_self
}

main "$@"
