#!/bin/bash
# sync-from-file.sh - 从文件批量同步 Docker 镜像到 CNB 仓库
#
# 用法:
#   bash sync-from-file.sh [文件路径] [选项]
#
# 选项:
#   --arch ARCH            架构 (默认: amd64)
#   --parallel N           并行数量 (默认: 3)
#   --skip-existing        跳过已存在的镜像
#   --continue-on-error    即便有部分镜像失败也生成报告并不以错误退出
#   --dry-run              仅打印，不执行

set -euo pipefail

# 获取脚本目录
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

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
DEFAULT_FILE="${PROJECT_DIR}/docker-images.txt"
ARCH="amd64"
PARALLEL=3
DRY_RUN=false
SKIP_EXISTING=false
CONTINUE_ON_ERROR=false

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
  --arch ARCH            架构 (默认: amd64)
  --parallel N           并行数量 (默认: 3)
  --skip-existing        跳过已存在的镜像
  --continue-on-error    即便有部分镜像失败也记录报告并正常退出 (退出码 0)
  --dry-run              仅打印，不执行
  -h, --help             显示帮助
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
        --continue-on-error|--ignore-errors) CONTINUE_ON_ERROR=true; shift ;;
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

# 提取有效镜像 (过滤注释、空行、配置行)
IMAGES=$(tr -d '\r' < "$IMAGE_FILE" | grep -v '^#' | grep -v '^--' | grep -v '^[[:space:]]*$' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
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
log_info "容错继续模式: $CONTINUE_ON_ERROR"
log_info "========================================"

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

# 生成同步报告文件
REPORT_FILE="${PROJECT_DIR}/SYNC_REPORT.md"
log_info "生成同步报告: $REPORT_FILE"

generate_sync_report "$SUCCESS_LIST" "$FAILED_LIST" "$SKIPPED_LIST" "$ARCH" "$START_TIME" "$IMAGE_FILE" > "$REPORT_FILE" 2>/dev/null || true

log_info "报告已生成: $REPORT_FILE"

# 自动上报到 CNB Issues
if [[ -n "${CNB_TOKEN:-}" ]]; then
    log_info "正在将同步报告提交到 CNB Issues..."
    REPORT_BODY=$(cat "$REPORT_FILE" 2>/dev/null || echo "同步完成")
    
    if [[ -n "${CNB_ISSUE_IID:-}" ]]; then
        # 场景 A: 由 Issue 触发的同步，回复评论并在全部成功时关闭
        log_info "更新触发源 Issue #$CNB_ISSUE_IID"
        issue_comment "$CNB_ISSUE_IID" "$REPORT_BODY"
        if [[ $FAILED_COUNT -eq 0 ]]; then
            issue_close "$CNB_ISSUE_IID"
        fi
    else
        # 场景 B: 由 Push / Web 触发，新建一个 Issue 记录报告
        local status_tag="✅"
        [[ $FAILED_COUNT -gt 0 ]] && status_tag="⚠️"
        local issue_title="${status_tag} [Docker 同步报告] 成功:${SUCCESS_COUNT} / 跳过:${SKIPPED_COUNT} / 失败:${FAILED_COUNT} (${START_TIME})"
        issue_create "$issue_title" "$REPORT_BODY"
    fi
else
    log_warn "未检测到 CNB_TOKEN，跳过 Issue 报告创建"
fi

# 清理临时文件
rm -f "$SUCCESS_LIST" "$FAILED_LIST" "$SKIPPED_LIST"

# 根据容错模式决定退出码
if [[ "$CONTINUE_ON_ERROR" == true ]]; then
    log_info "容错模式启用，流水线正常结束 (退出码 0)"
    exit 0
else
    [[ $FAILED_COUNT -gt 0 ]] && exit 1
    exit 0
fi
