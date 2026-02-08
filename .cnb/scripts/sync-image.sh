#!/bin/bash
# sync-image.sh - 同步 Docker 镜像到 CNB 仓库
#
# 用法:
#   ./sync-image.sh <镜像名> [选项]
#   ./sync-image.sh nginx:latest
#   ./sync-image.sh ghcr.io/graalvm/graalvm-ce:ol9-java11
#
# 选项:
#   --tag TAG          镜像标签 (默认从镜像名解析，否则 latest)
#   --arch ARCH        架构 (默认: amd64)
#   --platform PLAT    源平台 (默认: docker.io)
#   --dry-run          仅打印命令，不执行
#
# 环境变量:
#   CNB_REGISTRY       CNB 镜像仓库 (默认: docker.cnb.cool)
#   CNB_ORG            CNB 组织名 (必填或自动检测)
#   CNB_PROJECT        CNB 项目名 (必填或自动检测)
#   SOURCE_USERNAME    源仓库用户名 (私有镜像需要)
#   SOURCE_PASSWORD    源仓库密码 (私有镜像需要)

set -euo pipefail

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# 默认配置
CNB_REGISTRY="${CNB_REGISTRY:-docker.cnb.cool}"
CNB_ORG="${CNB_ORG:-}"
CNB_PROJECT="${CNB_PROJECT:-}"
DEFAULT_PLATFORM="docker.io"
DEFAULT_TAG="latest"
DEFAULT_ARCH="amd64"
DRY_RUN=false
SKIP_EXISTING=false

# 参数解析
IMAGE=""
TAG=""
ARCH="$DEFAULT_ARCH"
PLATFORM=""

usage() {
    cat << EOF
用法: $0 <镜像名> [选项]

同步 Docker 镜像到 CNB 仓库

示例:
  $0 nginx:latest
  $0 mysql --tag 8.0
  $0 ghcr.io/graalvm/graalvm-ce:ol9-java11

选项:
  --tag TAG          镜像标签 (默认从镜像名解析)
  --arch ARCH        架构 (默认: amd64)
  --platform PLAT    源平台 (默认: docker.io)
  --skip-existing    如果目标镜像已存在则跳过 (返回码 2)
  --dry-run          仅打印命令，不执行
  -h, --help         显示帮助

环境变量:
  CNB_REGISTRY       CNB 镜像仓库 (默认: docker.cnb.cool)
  CNB_ORG            CNB 组织名
  CNB_PROJECT        CNB 项目名
EOF
    exit 0
}

# 解析镜像名称
# 输入: ghcr.io/graalvm/graalvm-ce:ol9-java11 或 nginx:latest 或 mysql
# 输出: 设置 PLATFORM, IMAGE_NAME, TAG
parse_image() {
    local input="$1"
    local temp_platform=""
    local temp_image=""
    local temp_tag=""

    # 分离标签
    if [[ "$input" == *":"* ]]; then
        temp_tag="${input##*:}"
        input="${input%:*}"
    fi

    # 判断是否包含平台前缀
    # 规则: 如果第一个 / 前的部分包含 . 或 :，则为平台
    if [[ "$input" == *"/"* ]]; then
        local first_part="${input%%/*}"
        if [[ "$first_part" == *"."* ]] || [[ "$first_part" == *":"* ]]; then
            temp_platform="$first_part"
            temp_image="${input#*/}"
        else
            temp_image="$input"
        fi
    else
        temp_image="$input"
    fi

    # 设置输出
    PLATFORM="${PLATFORM:-${temp_platform:-$DEFAULT_PLATFORM}}"
    IMAGE="${temp_image}"
    TAG="${TAG:-${temp_tag:-$DEFAULT_TAG}}"
}

# 获取纯镜像名 (不含路径)
get_image_basename() {
    local img="$1"
    # 保留整个路径作为镜像名，将 / 替换为 -
    echo "${img//\//-}"
}

# 主逻辑
main() {
    # 解析参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            --tag)
                TAG="$2"
                shift 2
                ;;
            --arch)
                ARCH="$2"
                shift 2
                ;;
            --platform)
                PLATFORM="$2"
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
            -h|--help)
                usage
                ;;
            -*)
                log_error "未知选项: $1"
                exit 1
                ;;
            *)
                if [[ -z "$IMAGE" ]]; then
                    parse_image "$1"
                fi
                shift
                ;;
        esac
    done

    # 验证必填参数
    if [[ -z "$IMAGE" ]]; then
        log_error "必须指定镜像名"
        usage
    fi

    # 尝试自动检测 CNB 环境变量
    if [[ -z "$CNB_ORG" ]] && [[ -n "${CNB_REPO_SLUG:-}" ]]; then
        CNB_ORG="${CNB_REPO_SLUG%%/*}"
    fi
    if [[ -z "$CNB_PROJECT" ]] && [[ -n "${CNB_REPO_SLUG:-}" ]]; then
        CNB_PROJECT="${CNB_REPO_SLUG#*/}"
    fi

    # 验证 CNB 配置
    if [[ -z "$CNB_ORG" ]] || [[ -z "$CNB_PROJECT" ]]; then
        log_error "CNB_ORG 和 CNB_PROJECT 必须设置"
        log_error "可通过环境变量设置，或在 CNB 环境中自动检测"
        exit 1
    fi

    # 构建源和目标镜像路径
    local source_image="${PLATFORM}/${IMAGE}:${TAG}"
    local image_basename
    image_basename=$(get_image_basename "$IMAGE")
    local target_image="${CNB_REGISTRY}/${CNB_ORG}/${CNB_PROJECT}/${image_basename}:${TAG}"

    log_info "========================================"
    log_info "同步镜像到 CNB"
    log_info "========================================"
    log_info "源镜像:   $source_image"
    log_info "目标镜像: $target_image"
    log_info "架构:     $ARCH"
    log_info "========================================"

    if [[ "$DRY_RUN" == true ]]; then
        log_warn "[DRY-RUN] 以下命令不会实际执行"
    fi

    # 检查是否跳过已存在的镜像
    if [[ "$SKIP_EXISTING" == true ]] && [[ "$DRY_RUN" != true ]]; then
        if check_image_exists "$target_image"; then
            log_info "⊘ 镜像已存在，跳过: $target_image"
            exit 2  # 返回码 2 表示跳过
        fi
    fi

    # 检测使用 skopeo 还是 docker
    if command -v skopeo &> /dev/null; then
        sync_with_skopeo "$source_image" "$target_image"
    else
        sync_with_docker "$source_image" "$target_image"
    fi

    # 同步成功，更新缓存
    update_sync_cache "$target_image"
    
    log_info "✓ 同步完成: $target_image"
}

# 检查目标镜像是否已存在
# 优化方案：本地缓存 + Registry HEAD 请求（避免下载统计）
check_image_exists() {
    local target="$1"
    local cache_file="${PROJECT_DIR}/.sync-cache.txt"
    
    # 1. 本地缓存检查 (零网络请求)
    if [[ -f "$cache_file" ]] && grep -qF "$target" "$cache_file" 2>/dev/null; then
        log_info "[缓存] 镜像已存在: $target"
        return 0
    fi
    
    # 2. Registry HEAD 请求 (最轻量，仅获取 headers)
    # 从 target 解析出 registry/repo:tag
    local registry="${target%%/*}"
    local repo_tag="${target#*/}"
    local repo="${repo_tag%:*}"
    local tag="${repo_tag##*:}"
    
    local head_response
    head_response=$(curl -sI -o /dev/null -w "%{http_code}" \
        "https://${registry}/v2/${repo}/manifests/${tag}" \
        -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
        -H "Authorization: Bearer ${CNB_TOKEN:-}" \
        2>/dev/null) || head_response="000"
    
    if [[ "$head_response" == "200" ]]; then
        log_info "[HEAD] 镜像已存在: $target"
        # 更新缓存
        echo "$target" >> "$cache_file" 2>/dev/null || true
        return 0
    fi
    
    # 3. fallback: docker manifest inspect
    if docker manifest inspect "$target" >/dev/null 2>&1; then
        log_info "[manifest] 镜像已存在: $target"
        echo "$target" >> "$cache_file" 2>/dev/null || true
        return 0
    fi
    
    return 1  # 不存在
}

# 更新缓存（同步成功后调用）
update_sync_cache() {
    local target="$1"
    local cache_file="${PROJECT_DIR}/.sync-cache.txt"
    echo "$target" >> "$cache_file" 2>/dev/null || true
}

# 使用 skopeo 同步 (推荐，无需本地存储)
sync_with_skopeo() {
    local source="$1"
    local target="$2"

    local src_auth=""
    local dest_auth=""

    # 源仓库认证
    if [[ -n "${SOURCE_USERNAME:-}" ]] && [[ -n "${SOURCE_PASSWORD:-}" ]]; then
        src_auth="--src-creds ${SOURCE_USERNAME}:${SOURCE_PASSWORD}"
    fi

    # 目标仓库认证 (CNB)
    if [[ -n "${CNB_TOKEN:-}" ]]; then
        dest_auth="--dest-creds cnb:${CNB_TOKEN}"
    fi

    local cmd="skopeo copy --override-arch $ARCH $src_auth $dest_auth docker://$source docker://$target"

    if [[ "$DRY_RUN" == true ]]; then
        echo "$cmd"
    else
        log_info "使用 skopeo 复制镜像..."
        eval "$cmd"
    fi
}

# 使用 docker 同步 (需要本地存储)
sync_with_docker() {
    local source="$1"
    local target="$2"

    if [[ "$DRY_RUN" == true ]]; then
        echo "docker pull --platform linux/$ARCH $source"
        echo "docker tag $source $target"
        echo "docker push $target"
    else
        log_info "使用 docker 拉取镜像..."
        docker pull --platform "linux/$ARCH" "$source"

        log_info "打标签..."
        docker tag "$source" "$target"

        log_info "推送到 CNB..."
        docker push "$target"

        # 清理本地镜像
        log_info "清理本地镜像..."
        docker rmi "$source" "$target" 2>/dev/null || true
    fi
}

main "$@"
