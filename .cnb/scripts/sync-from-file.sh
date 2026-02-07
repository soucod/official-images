#!/bin/bash
# sync-from-file.sh - 从文件批量同步 Docker 镜像到 CNB 仓库
#
# 用法:
#   ./sync-from-file.sh [文件路径] [选项]
#   ./sync-from-file.sh                    # 默认读取 docker-images.txt
#   ./sync-from-file.sh mylist.txt
#   ./sync-from-file.sh --arch arm64       # 指定架构
#
# 文件格式 (每行一个镜像):
#   nginx:latest
#   mysql:8.0
#   ghcr.io/graalvm/graalvm-ce:ol9-java11
#   # 注释行以 # 开头
#
# 选项:
#   --arch ARCH        架构 (默认: amd64)
#   --dry-run          仅打印命令，不执行
#   --parallel N       并行同步数量 (默认: 1)

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
DRY_RUN=false
PARALLEL=1

# 统计
TOTAL=0
SUCCESS=0
FAILED=0
SKIPPED=0

usage() {
    cat << EOF
用法: $0 [文件路径] [选项]

从文件批量同步 Docker 镜像到 CNB 仓库

示例:
  $0                           # 使用默认文件 docker-images.txt
  $0 mylist.txt               # 使用指定文件
  $0 --arch arm64             # 同步 arm64 架构

选项:
  --arch ARCH        架构 (默认: amd64)
  --dry-run          仅打印命令，不执行
  --parallel N       并行同步数量 (默认: 1)
  -h, --help         显示帮助

文件格式:
  每行一个镜像，支持以下格式:
  - nginx:latest
  - mysql:8.0
  - ghcr.io/graalvm/graalvm-ce:ol9-java11
  以 # 开头的行为注释
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
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --parallel)
            PARALLEL="$2"
            shift 2
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
    log_error "镜像列表文件不存在: $IMAGE_FILE"
    exit 1
fi

# 构建同步选项
SYNC_OPTS="--arch $ARCH"
if [[ "$DRY_RUN" == true ]]; then
    SYNC_OPTS="$SYNC_OPTS --dry-run"
fi

log_info "========================================"
log_info "批量同步 Docker 镜像到 CNB"
log_info "========================================"
log_info "镜像列表: $IMAGE_FILE"
log_info "架构:     $ARCH"
log_info "DRY-RUN:  $DRY_RUN"
log_info "========================================"

# 读取并处理镜像列表
while IFS= read -r line || [[ -n "$line" ]]; do
    # 去除首尾空白
    line=$(echo "$line" | xargs)

    # 跳过空行和注释
    if [[ -z "$line" ]] || [[ "$line" == \#* ]]; then
        continue
    fi

    ((TOTAL++))
    log_step "[$TOTAL] 处理: $line"

    # 调用同步脚本
    if "${SCRIPT_DIR}/sync-image.sh" "$line" $SYNC_OPTS; then
        ((SUCCESS++))
        log_info "[$TOTAL] ✓ 成功: $line"
    else
        ((FAILED++))
        log_error "[$TOTAL] ✗ 失败: $line"
    fi

    echo ""
done < "$IMAGE_FILE"

# 输出统计
log_info "========================================"
log_info "同步完成!"
log_info "========================================"
log_info "总计:   $TOTAL"
log_info "成功:   $SUCCESS"
log_info "失败:   $FAILED"
log_info "========================================"

# 如果有失败的，返回非零退出码
if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
