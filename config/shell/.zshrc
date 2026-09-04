# starship
eval "$(starship init zsh)"

# python uv
. "$HOME/.local/bin/env"
export UV_CACHE_DIR=/Volumes/Dev/python/uv/cache
export UV_TOOL_DIR=/Volumes/Dev/python/uv/tools
export UV_PYTHON_INSTALL_DIR=/Volumes/Dev/python/uv/python

# golang
export GOPATH=/Volumes/Dev/go
export GOBIN=$GOPATH/bin
export PATH=$PATH:$GOBIN
export GOCACHE=$GOPATH/caches

# clean macOS junk files
macjunk() {
    local dir="."
    local clean=false

    for arg in "$@"; do
        case "$arg" in
            -C|--clean) clean=true ;;
            *) dir="$arg" ;;
        esac
    done

    local action=(-print)
    $clean && action=(-exec rm -rf -- '{}' +)

    find "$dir" \
        \( -name '.TemporaryItems' -o -name '.Trashes' -o -name '.fseventsd' \
           -o -name '.Spotlight-V100' -o -name '.DocumentRevisions-V100' \) -prune -o \
        \( -name '.DS_Store' -o -name '._*' -o -name '__MACOSX' \) \
        "${action[@]}"
}
