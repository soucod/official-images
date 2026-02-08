#!/bin/bash
# sync-from-file.sh - 从文件批量同步 Docker 镜像到 CNB 仓库
#
# 用法:
#   bash sync-from-file.sh [文件路径] [选项]
#
# 选项:
#   --arch ARCH        架构 (默认: amd64)
#   --parallel N       并行数量 (默认: 3)
#   --skip-existing    跳过已存在的镜像
#   --dry-run          仅打印，不执行
#   --create-issue     创建 Issue 记录结果

set -euo pipefail

# 获取脚本目录
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# 加载 Issue 助手
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
DEFAULT_FILE="${PROJECT_DIR}/docker-images.txt"
ARCH="amd64"
PARALLEL=3
DRY_RUN=false
SKIP_EXISTING=false
CREATE_ISSUE=true

# 同步结果文件
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
SUCCESS_LIST="/tmp/sync-success-${TIMESTAMP}.txt"
FAILED_LIST="/tmp/sync-failed-${TIMESTAMP}.txt"
SKIPPED_LIST="/tmp/sync-skipped-${TIMESTAMP}.txt"
START_TIME=$(date '+%Y-%m-%d %H:%M:%S')

usage() {
    cat << EOF
用法: bash $0 [文件路径] [选项]

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
        --arch) ARCH="$2"; shift 2 ;;
        --parallel) PARALLEL="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --skip-existing) SKIP_EXISTING=true; shift ;;
        --create-issue) CREATE_ISSUE=true; shift ;;
        -h|--help) usage ;;
        -*) log_error "未知选项: $1"; exit 1 ;;
        *) IMAGE_FILE="$1"; shift ;;
    esac
done

IMAGE_FILE="${IMAGE_FILE:-$DEFAULT_FILE}"

# 检查文件
if [[ ! -f "$IMAGE_FILE" ]]; then
    log_warn "镜像列表文件不存在: $IMAGE_FILE"
    exit 0
fi

# 提取有效镜像
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
[[ "$DRY_RUN" == true ]] && SYNC_OPTS="$SYNC_OPTS --dry-run"
[[ "$SKIP_EXISTING" == true ]] && SYNC_OPTS="$SYNC_OPTS --skip-existing"

log_info "========================================"
log_info "批量同步 Docker 镜像到 CNB"
log_info "========================================"
log_info "镜像列表: $IMAGE_FILE"
log_info "有效镜像: $IMAGE_COUNT 个"
log_info "架构:     $ARCH"
log_info "并行数:   $PARALLEL"
log_info "跳过已存在: $SKIP_EXISTING"
log_info "创建 Issue: $CREATE_ISSUE"
log_info "========================================"

# 创建 Issue (如果启用)
ISSUE_IID=""
if [[ "$CREATE_ISSUE" == true ]] && [[ "$DRY_RUN" != true ]]; then
    ISSUE_TITLE="sync-artifact-${TIMESTAMP}"
    ISSUE_BODY="## 🔄 镜像同步任务\\n\\n- **开始时间**: ${START_TIME}\\n- **架构**: ${ARCH}\\n- **镜像数量**: ${IMAGE_COUNT}\\n\\n⏳ 同步进行中..."
    ISSUE_IID=$(issue_create "$ISSUE_TITLE" "$ISSUE_BODY" 2>/dev/null || echo "")
fi

# 同步单个镜像
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

# 并行执行
idx=0
echo "$IMAGES" | while read -r image; do
    idx=$((idx + 1))
    echo "$idx $image"
done | xargs -P "$PARALLEL" -L 1 bash -c 'sync_single "$2" "$1"' _

# 统计结果
SUCCESS_COUNT=$(wc -l < "$SUCCESS_LIST" 2>/dev/null | tr -d ' ' || echo 0)
FAILED_COUNT=$(wc -l < "$FAILED_LIST" 2>/dev/null | tr -d ' ' || echo 0)
SKIPPED_COUNT=$(wc -l < "$SKIPPED_LIST" 2>/dev/null | tr -d ' ' || echo 0)
TOTAL=$((SUCCESS_COUNT + FAILED_COUNT + SKIPPED_COUNT))

log_info "========================================"
log_info "同步完成!"
log_info "========================================"
log_info "总计:   $TOTAL"
log_info "成功:   $SUCCESS_COUNT"
log_info "跳过:   $SKIPPED_COUNT"
log_info "失败:   $FAILED_COUNT"
log_info "========================================"

# 更新 Issue (如果启用)
if [[ -n "$ISSUE_IID" ]] && [[ "$DRY_RUN" != true ]]; then
    log_info "更新 Issue #$ISSUE_IID..."
    REPORT=$(generate_sync_report "$SUCCESS_LIST" "$FAILED_LIST" "$SKIPPED_LIST" "$ARCH" "$START_TIME" "$IMAGE_FILE" 2>/dev/null || echo "")
    if [[ -n "$REPORT" ]]; then
        # 转义特殊字符
        REPORT_ESCAPED=$(echo "$REPORT" | sed 's/"/\\"/g' | tr '\n' '\\' | sed 's/\\/\\n/g')
        issue_update "$ISSUE_IID" "$REPORT_ESCAPED" 2>/dev/null || true
        log_info "Issue #$ISSUE_IID 已更新"
    fi
    
    # 如果有失败则保持 Issue 打开，否则关闭
    if [[ $FAILED_COUNT -eq 0 ]]; then
        issue_close "$ISSUE_IID" 2>/dev/null || true
    fi
fi

# 清理临时文件
rm -f "$SUCCESS_LIST" "$FAILED_LIST" "$SKIPPED_LIST"

# 返回退出码
[[ $FAILED_COUNT -gt 0 ]] && exit 1
exit 0
