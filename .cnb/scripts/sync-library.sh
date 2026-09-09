#!/bin/bash
# sync-library.sh - 同步 library 目录中定义的 Docker Official Images 到 CNB 仓库
#
# 用法:
#   ./sync-library.sh <镜像名> [选项]
#   ./sync-library.sh openjdk --versions 5       # 同步 openjdk 最近5个版本
#   ./sync-library.sh alpine --all-versions      # 同步 alpine 所有版本
#   ./sync-library.sh --all --versions 3         # 同步所有官方镜像最近3个版本
#
# 选项:
#   --versions N           同步最近 N 个主版本 (默认: 3)
#   --all-versions         同步所有版本
#   --all                  同步所有官方镜像
#   --arch ARCH            架构 (默认: amd64)
#   --parallel N           并行数量 (默认: 3)
#   --skip-existing        跳过已存在于 CNB 仓库的镜像 (默认开启)
#   --continue-on-error    即便有部分镜像失败也生成报告并正常退出
#   --dry-run              仅打印，不执行

set -euo pipefail

if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
LIBRARY_DIR="${PROJECT_DIR}/library"

# 加载报告生成助手与 Issue 操作助手
source "${SCRIPT_DIR}/issue-helper.sh" 2>/dev/null || true

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
CNB_ORG="${CNB_ORG:-avwq}"
CNB_PROJECT="${CNB_PROJECT:-soucod/official-images}"
VERSION_COUNT=3
ALL_VERSIONS=false
SYNC_ALL=false
ARCH="amd64"
PARALLEL=3
DRY_RUN=false
SKIP_EXISTING=true
CONTINUE_ON_ERROR=false

# 结果记录
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
SUCCESS_LIST="/tmp/sync-lib-success-${TIMESTAMP}.txt"
FAILED_LIST="/tmp/sync-lib-failed-${TIMESTAMP}.txt"
SKIPPED_LIST="/tmp/sync-lib-skipped-${TIMESTAMP}.txt"
START_TIME=$(date '+%Y-%m-%d %H:%M:%S')

usage() {
    cat << EOF
用法: $0 [镜像名] [选项]

同步 library 目录中的 Docker Official Images 到 CNB 仓库

示例:
  $0 openjdk                      # 同步 openjdk 最近3个版本
  $0 alpine --versions 3          # 同步 alpine 最近3个版本
  $0 --all --versions 3           # 同步所有官方镜像最近3个版本

选项:
  --versions N           同步最近 N 个主版本 (默认: 3)
  --all-versions         同步所有版本
  --all                  同步所有官方镜像
  --arch ARCH            架构 (默认: amd64)
  --parallel N           并行并发数 (默认: 3)
  --skip-existing        跳过已存在的镜像 (默认开启)
  --continue-on-error    容错模式，即便失败也正常退出
  --dry-run              仅打印，不执行
  -h, --help             显示帮助
EOF
    exit 0
}

# 从 library 文件中提取 Tags
extract_tags() {
    local lib_file="$1"
    local arch="$2"

    local in_windows_block=false
    local current_tags=""
    local current_archs=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^Tags:\ (.+) ]]; then
            current_tags="${BASH_REMATCH[1]}"
            current_archs=""
            in_windows_block=false
        elif [[ "$line" =~ ^Architectures:\ (.+) ]]; then
            current_archs="${BASH_REMATCH[1]}"
            if [[ "$current_archs" == *"windows"* ]]; then
                in_windows_block=true
            elif [[ "$current_archs" == *"$arch"* ]] || [[ "$current_archs" == *"amd64"* && "$arch" == "amd64" ]]; then
                echo "$current_tags" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
            fi
        elif [[ -z "$line" ]]; then
            current_tags=""
            current_archs=""
            in_windows_block=false
        fi
    done < "$lib_file"
}

# 从 tags 列表中提取主版本号并排序
extract_major_versions() {
    local tags="$1"

    echo "$tags" | while read -r tag; do
        if [[ "$tag" =~ ^([0-9]+) ]]; then
            echo "${BASH_REMATCH[1]}"
        fi
    done | sort -rn | uniq
}

# 获取指定主版本的第一个 tag
get_version_tag() {
    local tags="$1"
    local major="$2"

    echo "$tags" | grep "^${major}" | head -1
}

# 同步单个镜像版本
sync_single_target() {
    local full_img="$1"
    local idx="$2"
    local result=0

    local sync_args=(--arch "$ARCH")
    [[ "$DRY_RUN" == true ]] && sync_args+=(--dry-run)
    [[ "$SKIP_EXISTING" == true ]] && sync_args+=(--skip-existing)

    log_step "[$idx] 开始同步: $full_img"
    bash "${SCRIPT_DIR}/sync-image.sh" "$full_img" "${sync_args[@]}" 2>&1 || result=$?

    if [[ $result -eq 0 ]]; then
        echo "$full_img" >> "$SUCCESS_LIST"
        log_info "[$idx] ✓ 成功: $full_img"
    elif [[ $result -eq 2 ]]; then
        echo "$full_img" >> "$SKIPPED_LIST"
        log_info "[$idx] ⊘ 跳过: $full_img"
    else
        echo "$full_img" >> "$FAILED_LIST"
        log_error "[$idx] ✗ 失败: $full_img"
    fi
}

export -f sync_single_target log_info log_warn log_error log_step
export SCRIPT_DIR SUCCESS_LIST FAILED_LIST SKIPPED_LIST GREEN YELLOW RED BLUE NC ARCH DRY_RUN SKIP_EXISTING

# 主逻辑
main() {
    local images=()

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
            --parallel)
                PARALLEL="$2"
                shift 2
                ;;
            --skip-existing)
                SKIP_EXISTING=true
                shift
                ;;
            --no-skip-existing)
                SKIP_EXISTING=false
                shift
                ;;
            --continue-on-error|--ignore-errors)
                CONTINUE_ON_ERROR=true
                shift
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

    if [[ -z "$CNB_ORG" ]] && [[ -n "${CNB_REPO_SLUG:-}" ]]; then
        CNB_ORG="${CNB_REPO_SLUG%%/*}"
    fi
    if [[ -z "$CNB_PROJECT" ]] && [[ -n "${CNB_REPO_SLUG:-}" ]]; then
        CNB_PROJECT="${CNB_REPO_SLUG#*/}"
    fi

    # 初始化临时文件
    > "$SUCCESS_LIST"
    > "$FAILED_LIST"
    > "$SKIPPED_LIST"

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
    log_info "Library 官方镜像同步"
    log_info "========================================"
    log_info "目标仓库: ${CNB_REGISTRY}/${CNB_ORG}/${CNB_PROJECT}/"
    log_info "架构:     $ARCH"
    log_info "版本数量: $([[ "$ALL_VERSIONS" == true ]] && echo "全部" || echo "$VERSION_COUNT")"
    log_info "镜像数量: ${#images[@]}"
    log_info "并行并发: $PARALLEL"
    log_info "跳过已存在: $SKIP_EXISTING"
    log_info "容错继续模式: $CONTINUE_ON_ERROR"
    log_info "========================================"

    # 收集全部需要同步的目标镜像 tag
    local targets_to_sync=()
    for image_name in "${images[@]}"; do
        local lib_file="${LIBRARY_DIR}/${image_name}"
        [[ ! -f "$lib_file" ]] && continue

        local all_tags
        all_tags=$(extract_tags "$lib_file" "$ARCH")
        [[ -z "$all_tags" ]] && continue

        local major_versions
        major_versions=$(extract_major_versions "$all_tags")

        local versions_to_sync
        if [[ "$ALL_VERSIONS" == true ]]; then
            versions_to_sync="$major_versions"
        else
            versions_to_sync=$(echo "$major_versions" | head -n "$VERSION_COUNT")
        fi

        while IFS= read -r major; do
            [[ -z "$major" ]] && continue
            local tag
            tag=$(get_version_tag "$all_tags" "$major")
            [[ -n "$tag" ]] && targets_to_sync+=("${image_name}:${tag}")
        done <<< "$versions_to_sync"

        if echo "$all_tags" | grep -q "^latest$"; then
            targets_to_sync+=("${image_name}:latest")
        fi
    done

    local total_targets=${#targets_to_sync[@]}
    log_info "已解析出 $total_targets 个待同步的镜像版本标签"

    local sync_opts="--arch $ARCH"
    [[ "$DRY_RUN" == true ]] && sync_opts="$sync_opts --dry-run"
    [[ "$SKIP_EXISTING" == true ]] && sync_opts="$sync_opts --skip-existing"

    # 并行执行同步
    local idx=0
    for full_img in "${targets_to_sync[@]}"; do
        idx=$((idx + 1))
        echo "$idx $full_img"
    done | xargs -P "$PARALLEL" -L 1 bash -c 'sync_single_target "$2" "$1"' _

    # 统计
    local success_count=$(wc -l < "$SUCCESS_LIST" 2>/dev/null | tr -d ' ' || echo 0)
    local failed_count=$(wc -l < "$FAILED_LIST" 2>/dev/null | tr -d ' ' || echo 0)
    local skipped_count=$(wc -l < "$SKIPPED_LIST" 2>/dev/null | tr -d ' ' || echo 0)
    local total=$((success_count + failed_count + skipped_count))

    log_info "========================================"
    log_info "Library 镜像同步完成!"
    log_info "========================================"
    log_info "总计:   $total"
    log_info "成功:   $success_count"
    log_info "跳过:   $skipped_count"
    log_info "失败:   $failed_count"
    log_info "========================================"

    # 生成同步报告
    local report_file="${PROJECT_DIR}/SYNC_LIBRARY_REPORT.md"
    generate_sync_report "$SUCCESS_LIST" "$FAILED_LIST" "$SKIPPED_LIST" "$ARCH" "$START_TIME" "library (全量官方定义)" > "$report_file" 2>/dev/null || true
    log_info "报告已生成: $report_file"

    # 上报到 Issues
    if [[ -n "${CNB_TOKEN:-}" ]]; then
        log_info "正在提交 Library 同步报告到 CNB Issues..."
        local report_body
        report_body=$(cat "$report_file" 2>/dev/null || echo "Library 同步完成")
        if [[ -n "${CNB_ISSUE_IID:-}" ]]; then
            issue_comment "$CNB_ISSUE_IID" "$report_body"
            [[ $failed_count -eq 0 ]] && issue_close "$CNB_ISSUE_IID"
        else
            local status_tag="✅"
            [[ $failed_count -gt 0 ]] && status_tag="⚠️"
            local title="${status_tag} [Library 官方镜像同步报告] 成功:${success_count} / 跳过:${skipped_count} / 失败:${failed_count} (${START_TIME})"
            issue_create "$title" "$report_body"
        fi
    fi

    # 清理
    rm -f "$SUCCESS_LIST" "$FAILED_LIST" "$SKIPPED_LIST"

    if [[ "$CONTINUE_ON_ERROR" == true ]]; then
        exit 0
    else
        [[ $failed_count -gt 0 ]] && exit 1
        exit 0
    fi
}

main "$@"
