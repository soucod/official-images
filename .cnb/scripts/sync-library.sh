#!/bin/bash
# sync-library.sh - 同步 library 目录中定义的 Docker Official Images 到 CNB 仓库
#
# 用法:
#   ./sync-library.sh <镜像名> [选项]
#   ./sync-library.sh openjdk --versions 5       # 同步 openjdk 最近5个版本
#   ./sync-library.sh alpine --all-versions      # 同步 alpine 所有版本
#   ./sync-library.sh --all --versions 5         # 同步所有镜像最近5个版本
#
# 选项:
#   --versions N        同步最近 N 个主版本 (默认: 5)
#   --all-versions      同步所有版本
#   --all               同步所有镜像
#   --arch ARCH         架构 (默认: amd64)
#   --dry-run           仅打印，不执行
#
# 环境变量:
#   CNB_REGISTRY        CNB 镜像仓库 (默认: docker.cnb.cool)
#   CNB_ORG             CNB 组织名 (必填)
#   CNB_PROJECT         CNB 项目名 (必填)

set -euo pipefail

# 获取脚本目录
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
LIBRARY_DIR="${PROJECT_DIR}/library"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step() { echo -e "${BLUE}[STEP]${NC} $*"; }

# 默认配置
CNB_REGISTRY="${CNB_REGISTRY:-docker.cnb.cool}"
CNB_ORG="${CNB_ORG:-}"
CNB_PROJECT="${CNB_PROJECT:-}"
VERSION_COUNT=5
ALL_VERSIONS=false
SYNC_ALL=false
ARCH="amd64"
DRY_RUN=false

# 统计
TOTAL=0
SUCCESS=0
FAILED=0

usage() {
    cat << EOF
用法: $0 <镜像名> [选项]

同步 library 目录中的 Docker Official Images 到 CNB 仓库

示例:
  $0 openjdk                      # 同步 openjdk 最近5个版本
  $0 alpine --versions 3          # 同步 alpine 最近3个版本
  $0 nginx --all-versions         # 同步 nginx 所有版本
  $0 --all --versions 5           # 同步所有镜像最近5个版本

选项:
  --versions N        同步最近 N 个主版本 (默认: 5)
  --all-versions      同步所有版本
  --all               同步所有镜像
  --arch ARCH         架构 (默认: amd64)
  --dry-run           仅打印，不执行
  -h, --help          显示帮助
EOF
    exit 0
}

# 从 library 文件中提取 Tags
# 返回格式: 每行一个 tag
extract_tags() {
    local lib_file="$1"
    local arch="$2"

    # 读取文件，提取 Tags 行，跳过 Windows 相关的块
    local in_windows_block=false
    local current_tags=""
    local current_archs=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        # 检测 Tags 行
        if [[ "$line" =~ ^Tags:\ (.+) ]]; then
            current_tags="${BASH_REMATCH[1]}"
            current_archs=""
            in_windows_block=false
        # 检测 Architectures 行
        elif [[ "$line" =~ ^Architectures:\ (.+) ]]; then
            current_archs="${BASH_REMATCH[1]}"
            # 检查是否包含目标架构
            if [[ "$current_archs" == *"windows"* ]]; then
                in_windows_block=true
            elif [[ "$current_archs" == *"$arch"* ]] || [[ "$current_archs" == *"amd64"* && "$arch" == "amd64" ]]; then
                # 输出当前 Tags
                echo "$current_tags" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
            fi
        # 空行重置状态
        elif [[ -z "$line" ]]; then
            current_tags=""
            current_archs=""
            in_windows_block=false
        fi
    done < "$lib_file"
}

# 从 tags 列表中提取主版本号并排序
# 输入: 每行一个 tag
# 输出: 排序后的唯一主版本号列表
extract_major_versions() {
    local tags="$1"

    echo "$tags" | while read -r tag; do
        # 提取第一个数字作为主版本
        # 例如: 27-ea-7-jdk -> 27, 3.23.3 -> 3, latest -> (跳过)
        if [[ "$tag" =~ ^([0-9]+) ]]; then
            echo "${BASH_REMATCH[1]}"
        fi
    done | sort -rn | uniq
}

# 获取指定主版本的第一个 tag (最具体的版本)
get_version_tag() {
    local tags="$1"
    local major="$2"

    echo "$tags" | grep "^${major}" | head -1
}

# 同步单个镜像
sync_image() {
    local image_name="$1"
    local lib_file="${LIBRARY_DIR}/${image_name}"

    if [[ ! -f "$lib_file" ]]; then
        log_error "library 文件不存在: $lib_file"
        return 1
    fi

    log_info "========================================"
    log_info "处理镜像: $image_name"
    log_info "========================================"

    # 提取所有 Tags
    local all_tags
    all_tags=$(extract_tags "$lib_file" "$ARCH")

    if [[ -z "$all_tags" ]]; then
        log_warn "未找到适用于 $ARCH 架构的 tags"
        return 0
    fi

    # 提取主版本号
    local major_versions
    major_versions=$(extract_major_versions "$all_tags")

    # 确定要同步的版本
    local versions_to_sync
    if [[ "$ALL_VERSIONS" == true ]]; then
        versions_to_sync="$major_versions"
    else
        versions_to_sync=$(echo "$major_versions" | head -n "$VERSION_COUNT")
    fi

    # 同步每个版本
    local sync_count=0
    while IFS= read -r major; do
        [[ -z "$major" ]] && continue

        local tag
        tag=$(get_version_tag "$all_tags" "$major")

        if [[ -z "$tag" ]]; then
            continue
        fi

        sync_count=$((sync_count + 1))
        log_step "[$sync_count] 同步: ${image_name}:${tag}"

        local source_image="docker.io/library/${image_name}:${tag}"
        local target_image="${CNB_REGISTRY}/${CNB_ORG}/${CNB_PROJECT}/${image_name}:${tag}"

        if [[ "$DRY_RUN" == true ]]; then
            log_info "[DRY-RUN] 源: $source_image"
            log_info "[DRY-RUN] 目标: $target_image"
            SUCCESS=$((SUCCESS + 1))
        else
            # 调用 sync-image.sh 进行实际同步
            if bash "${SCRIPT_DIR}/sync-image.sh" "${image_name}:${tag}" --arch "$ARCH"; then
                SUCCESS=$((SUCCESS + 1))
                log_info "✓ 成功: ${image_name}:${tag}"
            else
                FAILED=$((FAILED + 1))
                log_error "✗ 失败: ${image_name}:${tag}"
            fi
        fi

        TOTAL=$((TOTAL + 1))
    done <<< "$versions_to_sync"

    # 同步 latest 标签 (如果存在)
    if echo "$all_tags" | grep -q "^latest$"; then
        log_step "同步: ${image_name}:latest"
        if [[ "$DRY_RUN" == true ]]; then
            log_info "[DRY-RUN] 目标: ${CNB_REGISTRY}/${CNB_ORG}/${CNB_PROJECT}/${image_name}:latest"
            SUCCESS=$((SUCCESS + 1))
        else
            if bash "${SCRIPT_DIR}/sync-image.sh" "${image_name}:latest" --arch "$ARCH"; then
                SUCCESS=$((SUCCESS + 1))
            else
                FAILED=$((FAILED + 1))
            fi
        fi
        TOTAL=$((TOTAL + 1))
    fi

    log_info "✓ ${image_name} 处理完成 (同步 $sync_count 个版本)"
}

# 主逻辑
main() {
    local images=()

    # 解析参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            --versions)
                VERSION_COUNT="$2"
                shift 2
                ;;
            --all-versions)
                ALL_VERSIONS=true
                shift
                ;;
            --all)
                SYNC_ALL=true
                shift
                ;;
            --arch)
                ARCH="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            -*)
                log_error "未知选项: $1"
                exit 1
                ;;
            *)
                images+=("$1")
                shift
                ;;
        esac
    done

    # 自动检测 CNB 环境变量
    if [[ -z "$CNB_ORG" ]] && [[ -n "${CNB_REPO_SLUG:-}" ]]; then
        CNB_ORG="${CNB_REPO_SLUG%%/*}"
    fi
    if [[ -z "$CNB_PROJECT" ]] && [[ -n "${CNB_REPO_SLUG:-}" ]]; then
        CNB_PROJECT="${CNB_REPO_SLUG#*/}"
    fi

    # 验证配置
    if [[ -z "$CNB_ORG" ]] || [[ -z "$CNB_PROJECT" ]]; then
        log_error "CNB_ORG 和 CNB_PROJECT 必须设置"
        exit 1
    fi

    # 确定要处理的镜像列表
    if [[ "$SYNC_ALL" == true ]]; then
        for lib_file in "$LIBRARY_DIR"/*; do
            [[ -f "$lib_file" ]] && images+=("$(basename "$lib_file")")
        done
    elif [[ ${#images[@]} -eq 0 ]]; then
        log_error "必须指定镜像名或使用 --all"
        usage
    fi

    log_info "========================================"
    log_info "Library 镜像同步"
    log_info "========================================"
    log_info "目标仓库: ${CNB_REGISTRY}/${CNB_ORG}/${CNB_PROJECT}/"
    log_info "架构: $ARCH"
    log_info "版本数量: $([[ "$ALL_VERSIONS" == true ]] && echo "全部" || echo "$VERSION_COUNT")"
    log_info "镜像数量: ${#images[@]}"
    log_info "DRY-RUN: $DRY_RUN"
    log_info "========================================"

    # 同步每个镜像
    for image_name in "${images[@]}"; do
        sync_image "$image_name"
        echo ""
    done

    # 输出统计
    log_info "========================================"
    log_info "同步完成!"
    log_info "========================================"
    log_info "总计:   $TOTAL"
    log_info "成功:   $SUCCESS"
    log_info "失败:   $FAILED"
    log_info "========================================"

    [[ $FAILED -gt 0 ]] && exit 1
}

main "$@"
