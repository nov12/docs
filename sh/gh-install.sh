#!/usr/bin/env bash

set -e

cat <<'EOF'
============================================================
通用 GitHub Release 安装器

用法：
  gh-install owner/repo
  gh-install owner/repo binary_name
  gh-install https://github.com/owner/repo
  gh-install

示例：
  gh-install zellij-org/zellij
  gh-install BurntSushi/ripgrep rg
  gh-install https://github.com/zellij-org/zellij

环境变量：
  INSTALL_DIR=/usr/local/bin

功能：
  - 支持 owner/repo 或 GitHub 仓库链接
  - 无参数时交互输入仓库
  - 自动检测系统和 CPU 架构
  - 多个 Release 文件时上下键选择
  - 支持 GitHub URL 前缀代理
  - 已安装程序自动覆盖更新
============================================================

EOF


# ------------------------------------------------------------
# 基础配置
# ------------------------------------------------------------

install_dir="${INSTALL_DIR:-/usr/local/bin}"
tmp_dir="$(mktemp -d)"

# 代理列表，格式：显示名称|URL前缀
# URL前缀为空表示直连
# 特殊值 CUSTOM 表示运行时手动输入
proxy_list=(
    "Direct GitHub|"
    "gh-proxy.com|https://gh-proxy.com/"
    "akams.cn|https://github.akams.cn/"
    "ghproxy.net|https://ghproxy.net/"
    "homeboyc.cn|https://ghproxy.homeboyc.cn/"
    "Custom proxy|CUSTOM"
)

trap 'rm -rf "$tmp_dir"' EXIT

echo "GitHub Release Installer"


# ------------------------------------------------------------
# 上下键选择菜单
# ------------------------------------------------------------

menu() {
    local title="$1"
    shift

    local options=("$@")
    local selected=0
    local key

    while true; do
        printf "\033[2J\033[H"
        echo "$title"
        echo

        for i in "${!options[@]}"; do
            if [[ "$i" == "$selected" ]]; then
                printf " > %s\n" "${options[$i]}"
            else
                printf "   %s\n" "${options[$i]}"
            fi
        done

        IFS= read -rsn1 key

        if [[ "$key" == $'\x1b' ]]; then
            read -rsn2 key

            case "$key" in
                '[A') ((selected--)) || true ;;
                '[B') ((selected++)) || true ;;
            esac

            (( selected < 0 )) && selected=$((${#options[@]} - 1))
            (( selected >= ${#options[@]} )) && selected=0

        elif [[ -z "$key" ]]; then
            MENU_RESULT="$selected"
            return
        fi
    done
}


# ------------------------------------------------------------
# GitHub 下载代理选择
# ------------------------------------------------------------

proxy_names=()

for item in "${proxy_list[@]}"; do
    proxy_names+=("${item%%|*}")
done

menu "Download source:" "${proxy_names[@]}"

proxy="${proxy_list[$MENU_RESULT]#*|}"

if [[ "$proxy" == "CUSTOM" ]]; then
    printf "\033[2J\033[H"
    read -rp "Proxy prefix: " proxy
fi

[[ -n "$proxy" && "$proxy" != */ ]] && proxy="$proxy/"


# ------------------------------------------------------------
# GitHub URL 代理处理
# ------------------------------------------------------------

proxy_url() {
    if [[ -n "$proxy" ]]; then
        echo "${proxy}$1"
    else
        echo "$1"
    fi
}


# ------------------------------------------------------------
# GitHub 仓库输入与解析
# ------------------------------------------------------------

repo="${1:-}"
binary_name="${2:-}"

if [[ -z "$repo" ]]; then
    printf "\033[2J\033[H"
    read -rp "GitHub repository (owner/repo or URL): " repo

    if [[ -z "$repo" ]]; then
        echo "Repository cannot be empty."
        exit 1
    fi
fi

# 支持 owner/repo、完整仓库地址以及 Release 页面地址
repo="${repo#https://github.com/}"
repo="${repo#http://github.com/}"
repo="${repo#github.com/}"
repo="${repo#/}"

owner="${repo%%/*}"
rest="${repo#*/}"
repo_name="${rest%%/*}"
repo_name="${repo_name%.git}"

if [[ -z "$owner" || -z "$repo_name" || "$owner" == "$repo_name" ]]; then
    echo "Invalid GitHub repository: $repo"
    exit 1
fi

repo="$owner/$repo_name"

# 默认使用仓库名称作为最终命令名称
[[ -z "$binary_name" ]] && binary_name="$repo_name"


# ------------------------------------------------------------
# 系统与 CPU 架构检测
# ------------------------------------------------------------

case "$(uname -s)" in
    Linux)
        os_pattern='linux'
        ;;
    Darwin)
        os_pattern='darwin|apple'
        ;;
    *)
        echo "Unsupported system: $(uname -s)"
        exit 1
        ;;
esac

case "$(uname -m)" in
    x86_64|amd64)
        arch_pattern='x86_64|amd64'
        ;;
    aarch64|arm64)
        arch_pattern='aarch64|arm64'
        ;;
    armv7l|armv7)
        arch_pattern='armv7'
        ;;
    i386|i686)
        arch_pattern='i386|i686|386'
        ;;
    *)
        echo "Unsupported architecture: $(uname -m)"
        exit 1
        ;;
esac


# ------------------------------------------------------------
# GitHub Release 查找
# ------------------------------------------------------------

api="https://api.github.com/repos/$repo/releases/latest"

echo "Fetching release..."

mapfile -t assets < <(
    curl -fsSL "$(proxy_url "$api")" |
    grep '"browser_download_url"' |
    sed -E 's/.*"([^"]+)".*/\1/'
)

if [[ ${#assets[@]} -eq 0 ]]; then
    echo "No release assets found."
    exit 1
fi


# ------------------------------------------------------------
# Release 文件筛选
# ------------------------------------------------------------

mapfile -t matched < <(
    printf '%s\n' "${assets[@]}" |
    grep -Ei "$os_pattern" |
    grep -Ei "$arch_pattern" |
    grep -Eiv 'sha256|sha512|checksum|checksums|\.sig$|\.asc$' || true
)

# 自动匹配失败时显示 Release 中的全部文件
if [[ ${#matched[@]} -eq 0 ]]; then
    matched=("${assets[@]}")
fi


# ------------------------------------------------------------
# Release 文件选择
# ------------------------------------------------------------

if [[ ${#matched[@]} -eq 1 ]]; then
    url="${matched[0]}"
else
    names=()

    for item in "${matched[@]}"; do
        names+=("${item##*/}")
    done

    menu "Select release asset:" "${names[@]}"
    url="${matched[$MENU_RESULT]}"
fi

filename="${url##*/}"
download="$tmp_dir/$filename"


# ------------------------------------------------------------
# Release 文件下载
# ------------------------------------------------------------

echo "Downloading $filename..."

curl -fL "$(proxy_url "$url")" -o "$download"


# ------------------------------------------------------------
# Release 文件解压
# ------------------------------------------------------------

mkdir -p "$tmp_dir/extract"

case "$filename" in
    *.tar.gz|*.tgz)
        tar -xzf "$download" -C "$tmp_dir/extract"
        ;;
    *.tar.xz|*.txz)
        tar -xJf "$download" -C "$tmp_dir/extract"
        ;;
    *.tar.bz2|*.tbz2)
        tar -xjf "$download" -C "$tmp_dir/extract"
        ;;
    *.zip)
        unzip -q "$download" -d "$tmp_dir/extract"
        ;;
    *)
        cp "$download" "$tmp_dir/extract/$binary_name"
        ;;
esac


# ------------------------------------------------------------
# 可执行文件查找
# ------------------------------------------------------------

binary="$(find "$tmp_dir/extract" -type f -name "$binary_name" | head -n1)"

if [[ -z "$binary" ]]; then
    echo "Binary not found: $binary_name"
    exit 1
fi


# ------------------------------------------------------------
# 程序安装与覆盖更新
# ------------------------------------------------------------

target="$install_dir/$binary_name"

if [[ -e "$target" ]]; then
    echo "Updating $target..."
else
    echo "Installing to $target..."
fi

if [[ -w "$install_dir" ]]; then
    install -m 755 "$binary" "$target"
else
    sudo install -m 755 "$binary" "$target"
fi


# ------------------------------------------------------------
# 安装完成
# ------------------------------------------------------------

echo "Installed successfully."

"$target" --version 2>/dev/null || true
