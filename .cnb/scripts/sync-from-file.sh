#!/bin/bash
# sync-from-file.sh - 从文件批量同步 Docker 镜像到 CNB 仓库
#
# 用法:
#   bash sync-from-file.sh [文件路径] [选项]
#
# 注意: 必须使用 bash 运行此脚本
#
# 选项:
#   --arch ARCH        架构 (默认: amd64)
#   --parallel N       并行数量 (默认: 3)
#   --skip-existing    跳过已存在的镜像
#   --dry-run          仅打印，不执行
#   --create-issue     创建 Issue 记录同步结果

set -euo pipefail

# 获取脚本目录
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

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
DEFAULT_FILE="${PROJECT_DIR}/docker-images.txt"
ARCH="amd64"
PARALLEL=3
DRY_RUN=false
SKIP_EXISTING=false
CREATE_ISSUE=false

# 同步结果文件
RESULT_FILE="/tmp/sync-result-$$.txt"
SUCCESS_LIST="/tmp/sync-success-$$.txt"
FAILED_LIST="/tmp/sync-failed-$$.txt"
SKIPPED_LIST="/tmp/sync-skipped-$$.txt"

usage() {
    cat << EOF
用法: bash $0 [文件路径] [选项]

从文件批量同步 Docker 镜像到 CNB 仓库

选项:
  --arch ARCH        架构 (默认: amd64)
  --parallel N       并行数量 (默认: 3)
  --skip-existing    跳过已存在的镜像
  --dry-run          仅打印，不执行
  --create-issue     创建 Issue 记录结果
  -h, --help         显示帮助
EOF
    exit 0
}

# 解析参数
IMAGE_FILE=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --arch)
            ARCH="$2"
            shift 2
            ;;
        --parallel)
            PARALLEL="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --skip-existing)
            SKIP_EXISTING=true
            shift
            ;;
        --create-issue)
            CREATE_ISSUE=true
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
            IMAGE_FILE="$1"
            shift
            ;;
    esac
done

# 设置默认文件
IMAGE_FILE="${IMAGE_FILE:-$DEFAULT_FILE}"

# 检查文件是否存在
if [[ ! -f "$IMAGE_FILE" ]]; then
    log_warn "镜像列表文件不存在: $IMAGE_FILE"
    exit 0
fi

# 提取有效镜像列表
IMAGES=$(tr -d '\r' < "$IMAGE_FILE" | grep -v '^#' | grep -v '^[[:space:]]*$' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
IMAGE_COUNT=$(echo "$IMAGES" | grep -c . || echo 0)

if [[ "$IMAGE_COUNT" -eq 0 ]]; then
    log_warn "文件无有效内容，跳过"
    exit 0
fi

# 初始化结果文件
> "$SUCCESS_LIST"
> "$FAILED_LIST"
> "$SKIPPED_LIST"

# 构建同步选项
SYNC_OPTS="--arch $ARCH"
if [[ "$DRY_RUN" == true ]]; then
    SYNC_OPTS="$SYNC_OPTS --dry-run"
fi
if [[ "$SKIP_EXISTING" == true ]]; then
    SYNC_OPTS="$SYNC_OPTS --skip-existing"
fi

log_info "========================================"
log_info "批量同步 Docker 镜像到 CNB"
log_info "========================================"
log_info "镜像列表: $IMAGE_FILE"
log_info "有效镜像: $IMAGE_COUNT 个"
log_info "架构:     $ARCH"
log_info "并行数:   $PARALLEL"
log_info "跳过已存在: $SKIP_EXISTING"
log_info "DRY-RUN:  $DRY_RUN"
log_info "========================================"

# 同步单个镜像的函数
sync_single() {
    local image="$1"
    local idx="$2"
    local result=0
    
    log_step "[$idx] 开始: $image"
    
    bash "${SCRIPT_DIR}/sync-image.sh" "$image" $SYNC_OPTS 2>&1 || result=$?
    
    if [[ $result -eq 0 ]]; then
        echo "$image" >> "$SUCCESS_LIST"
        log_info "[$idx] ✓ 成功: $image"
    elif [[ $result -eq 2 ]]; then
        echo "$image" >> "$SKIPPED_LIST"
        log_info "[$idx] ⊘ 跳过: $image"
    else
        echo "$image" >> "$FAILED_LIST"
        log_error "[$idx] ✗ 失败: $image"
    fi
}

export -f sync_single log_info log_warn log_error log_step
export SCRIPT_DIR SYNC_OPTS SUCCESS_LIST FAILED_LIST SKIPPED_LIST
export GREEN YELLOW RED BLUE NC

# 使用 xargs 并行执行
idx=0
echo "$IMAGES" | while read -r image; do
    idx=$((idx + 1))
    echo "$idx $image"
done | xargs -P "$PARALLEL" -L 1 bash -c 'sync_single "$2" "$1"' _

# 统计结果
SUCCESS_COUNT=$(wc -l < "$SUCCESS_LIST" | tr -d ' ')
FAILED_COUNT=$(wc -l < "$FAILED_LIST" | tr -d ' ')
SKIPPED_COUNT=$(wc -l < "$SKIPPED_LIST" | tr -d ' ')
TOTAL=$((SUCCESS_COUNT + FAILED_COUNT + SKIPPED_COUNT))

log_info "========================================"
log_info "同步完成!"
log_info "========================================"
log_info "总计:   $TOTAL"
log_info "成功:   $SUCCESS_COUNT"
log_info "跳过:   $SKIPPED_COUNT"
log_info "失败:   $FAILED_COUNT"
log_info "========================================"

# 创建 Issue (如果启用)
if [[ "$CREATE_ISSUE" == true ]] && [[ "$DRY_RUN" != true ]]; then
    if command -v curl &>/dev/null && [[ -n "${CNB_TOKEN:-}" ]]; then
        ISSUE_TITLE="🔄 镜像同步报告 - $(date '+%Y-%m-%d %H:%M')"
        ISSUE_BODY="## 同步统计\n\n"
        ISSUE_BODY+="| 状态 | 数量 |\n|------|------|\n"
        ISSUE_BODY+="| ✅ 成功 | $SUCCESS_COUNT |\n"
        ISSUE_BODY+="| ⊘ 跳过 | $SKIPPED_COUNT |\n"
        ISSUE_BODY+="| ❌ 失败 | $FAILED_COUNT |\n\n"
        
        if [[ -s "$FAILED_LIST" ]]; then
            ISSUE_BODY+="## ❌ 失败列表\n\n\`\`\`\n$(cat "$FAILED_LIST")\n\`\`\`\n\n"
        fi
        
        if [[ -s "$SUCCESS_LIST" ]]; then
            ISSUE_BODY+="## ✅ 成功列表\n\n<details><summary>展开查看</summary>\n\n\`\`\`\n$(cat "$SUCCESS_LIST")\n\`\`\`\n\n</details>"
        fi
        
        log_info "创建 Issue..."
        # CNB API 创建 Issue (使用 GitLab 兼容 API)
        # curl -X POST "https://api.cnb.cool/projects/${CNB_PROJECT}/issues" ...
        log_info "Issue 功能待配置 CNB API"
    fi
fi

# 清理临时文件
rm -f "$SUCCESS_LIST" "$FAILED_LIST" "$SKIPPED_LIST" "$RESULT_FILE"

# 返回退出码
if [[ $FAILED_COUNT -gt 0 ]]; then
    exit 1
fi
