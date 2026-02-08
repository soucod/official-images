#!/bin/bash
# issue-helper.sh - CNB Issue 操作助手
#
# 用法:
#   source issue-helper.sh
#   issue_create "标题" "内容"
#   issue_comment $ISSUE_ID "评论内容"
#   issue_update $ISSUE_ID "新内容"
#
# 环境变量:
#   CNB_TOKEN       CNB API Token (必填)
#   CNB_API_URL     CNB API 地址 (默认: https://api.cnb.cool)
#   CNB_REPO_SLUG   仓库路径 (如: avwq/soucod/official-images)

set -euo pipefail

# 配置
CNB_API_URL="${CNB_API_URL:-https://api.cnb.cool}"
CNB_REPO_SLUG="${CNB_REPO_SLUG:-${CNB_ORG:-}/${CNB_PROJECT:-}}"

# 颜色输出
log_issue() { echo -e "\033[0;35m[ISSUE]\033[0m $*"; }

# URL 编码仓库路径
url_encode() {
    local string="$1"
    echo -n "$string" | sed 's/\//%2F/g'
}

# 创建 Issue
# 用法: issue_create "标题" "内容"
# 返回: ISSUE_IID (Issue 编号)
issue_create() {
    local title="$1"
    local body="${2:-}"
    
    if [[ -z "${CNB_TOKEN:-}" ]]; then
        log_issue "⚠️ CNB_TOKEN 未设置，跳过 Issue 创建"
        return 1
    fi
    
    # 确保 CNB_REPO_SLUG 正确设置
    if [[ -z "${CNB_REPO_SLUG:-}" ]]; then
        CNB_REPO_SLUG="${CNB_ORG:-}/${CNB_PROJECT:-}"
    fi
    
    log_issue "创建 Issue: $title"
    log_issue "仓库: $CNB_REPO_SLUG"
    log_issue "API: ${CNB_API_URL}"
    
    local response iid
    
    # 方式1: CNB OpenAPI (推荐)
    # POST https://api.cnb.cool/{group}/{repo}/issues
    response=$(curl -s -w "\n%{http_code}" -X POST \
        "${CNB_API_URL}/${CNB_REPO_SLUG}/issues" \
        -H "Authorization: Bearer ${CNB_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "{\"title\": \"${title}\", \"body\": \"${body}\"}" \
        2>/dev/null) || true
    
    local http_code=$(echo "$response" | tail -1)
    local body_response=$(echo "$response" | head -n -1)
    
    log_issue "响应码: $http_code"
    
    # 解析 Issue ID (支持数字和字符串格式)
    # CNB 返回格式: "number":"1" 或 "iid":1
    iid=$(echo "$body_response" | grep -oE '"iid"\s*:\s*[0-9]+' | head -1 | grep -oE '[0-9]+' || echo "")
    if [[ -z "$iid" ]]; then
        # CNB 格式: "number":"1" (字符串)
        iid=$(echo "$body_response" | grep -oE '"number"\s*:\s*"[0-9]+"' | head -1 | grep -oE '[0-9]+' || echo "")
    fi
    if [[ -z "$iid" ]]; then
        # 备选: "number":1 (数字)
        iid=$(echo "$body_response" | grep -oE '"number"\s*:\s*[0-9]+' | head -1 | grep -oE '[0-9]+' || echo "")
    fi
    if [[ -z "$iid" ]]; then
        iid=$(echo "$body_response" | grep -oE '"id"\s*:\s*[0-9]+' | head -1 | grep -oE '[0-9]+' || echo "")
    fi
    
    if [[ -n "$iid" ]] && [[ "$http_code" =~ ^2 ]]; then
        log_issue "✓ Issue #$iid 创建成功"
        echo "$iid"
        return 0
    fi
    
    # 方式2: CNB OpenAPI 备选格式
    response=$(curl -s -w "\n%{http_code}" -X POST \
        "${CNB_API_URL}/${CNB_REPO_SLUG}/-/issues" \
        -H "Authorization: Bearer ${CNB_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "{\"title\": \"${title}\", \"description\": \"${body}\"}" \
        2>/dev/null) || true
    
    http_code=$(echo "$response" | tail -1)
    body_response=$(echo "$response" | head -n -1)
    
    # 完整解析逻辑（与方式1相同）
    iid=$(echo "$body_response" | grep -oE '"iid"\s*:\s*[0-9]+' | head -1 | grep -oE '[0-9]+' || echo "")
    if [[ -z "$iid" ]]; then
        iid=$(echo "$body_response" | grep -oE '"number"\s*:\s*"[0-9]+"' | head -1 | grep -oE '[0-9]+' || echo "")
    fi
    if [[ -z "$iid" ]]; then
        iid=$(echo "$body_response" | grep -oE '"number"\s*:\s*[0-9]+' | head -1 | grep -oE '[0-9]+' || echo "")
    fi
    
    if [[ -n "$iid" ]] && [[ "$http_code" =~ ^2 ]]; then
        log_issue "✓ Issue #$iid 创建成功 (格式2)"
        echo "$iid"
        return 0
    fi
    
    # 记录失败详情，但不阻塞同步
    log_issue "⚠️ Issue 创建失败 (HTTP $http_code)"
    log_issue "响应内容: ${body_response:0:200}"
    return 1
}

# 添加 Issue 评论
# 用法: issue_comment $ISSUE_IID "评论内容"
issue_comment() {
    local iid="$1"
    local body="$2"
    
    if [[ -z "${CNB_TOKEN:-}" ]] || [[ -z "$iid" ]]; then
        return 1
    fi
    
    local repo_encoded
    repo_encoded=$(url_encode "$CNB_REPO_SLUG")
    
    curl -s -X POST \
        "${CNB_API_URL}/api/v4/projects/${repo_encoded}/issues/${iid}/notes" \
        -H "PRIVATE-TOKEN: ${CNB_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"body\": \"${body}\"}" \
        >/dev/null 2>&1 || true
}

# 更新 Issue 内容
# 用法: issue_update $ISSUE_IID "新内容"
issue_update() {
    local iid="$1"
    local body="$2"
    
    if [[ -z "${CNB_TOKEN:-}" ]] || [[ -z "$iid" ]]; then
        return 1
    fi
    
    # CNB API 格式
    local response http_code
    response=$(curl -s -w "\n%{http_code}" -X PATCH \
        "${CNB_API_URL}/${CNB_REPO_SLUG}/issues/${iid}" \
        -H "Authorization: Bearer ${CNB_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "{\"body\": \"${body}\"}" \
        2>/dev/null) || true
    
    http_code=$(echo "$response" | tail -1)
    if [[ "$http_code" =~ ^2 ]]; then
        log_issue "✓ Issue #$iid 内容已更新"
    else
        log_issue "⚠️ Issue #$iid 更新失败 (HTTP $http_code)"
    fi
}

# 关闭 Issue
# 用法: issue_close $ISSUE_IID
issue_close() {
    local iid="$1"
    
    if [[ -z "${CNB_TOKEN:-}" ]] || [[ -z "$iid" ]]; then
        return 1
    fi
    
    # CNB API 格式
    local response http_code
    response=$(curl -s -w "\n%{http_code}" -X PATCH \
        "${CNB_API_URL}/${CNB_REPO_SLUG}/issues/${iid}" \
        -H "Authorization: Bearer ${CNB_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d '{"state": "closed"}' \
        2>/dev/null) || true
    
    http_code=$(echo "$response" | tail -1)
    if [[ "$http_code" =~ ^2 ]]; then
        log_issue "✓ Issue #$iid 已关闭"
    else
        log_issue "⚠️ Issue #$iid 关闭失败 (HTTP $http_code)"
    fi
}

# 生成同步报告 Markdown
# 用法: generate_sync_report
generate_sync_report() {
    local success_file="${1:-/tmp/sync-success-$$.txt}"
    local failed_file="${2:-/tmp/sync-failed-$$.txt}"
    local skipped_file="${3:-/tmp/sync-skipped-$$.txt}"
    local arch="${4:-amd64}"
    local start_time="${5:-$(date '+%Y-%m-%d %H:%M:%S')}"
    local source_file="${6:-docker-images.txt}"
    
    local success_count=$(wc -l < "$success_file" 2>/dev/null | tr -d ' ' || echo 0)
    local failed_count=$(wc -l < "$failed_file" 2>/dev/null | tr -d ' ' || echo 0)
    local skipped_count=$(wc -l < "$skipped_file" 2>/dev/null | tr -d ' ' || echo 0)
    local total=$((success_count + failed_count + skipped_count))
    local end_time=$(date '+%Y-%m-%d %H:%M:%S')
    
    cat << EOF
# 🔄 Docker 镜像同步报告

## 📋 任务信息

| 项目 | 值 |
|------|------|
| 📁 来源文件 | \`$source_file\` |
| 🏗️ 目标架构 | \`$arch\` |
| 🕐 开始时间 | $start_time |
| 🕐 结束时间 | $end_time |

---

## 📊 同步统计

| 状态 | 数量 | 说明 |
|------|------|------|
| ✅ 成功 | **$success_count** | 已推送到 CNB 仓库 |
| ⊘ 跳过 | $skipped_count | 已存在或未更新 |
| ❌ 失败 | $failed_count | 同步失败需检查 |
| 📦 **总计** | **$total** | |

---

EOF

    # 失败列表 (始终展开，重要信息)
    if [[ -s "$failed_file" ]]; then
        echo "## ❌ 失败镜像 ($failed_count 个)"
        echo ""
        echo "| # | 镜像 |"
        echo "|---|------|"
        local idx=0
        while read -r img; do
            idx=$((idx + 1))
            echo "| $idx | \`$img\` |"
        done < "$failed_file"
        echo ""
        echo "---"
        echo ""
    fi

    # 成功列表 (使用表格，折叠)
    if [[ -s "$success_file" ]]; then
        echo "## ✅ 成功镜像 ($success_count 个)"
        echo ""
        echo "<details><summary>点击展开查看</summary>"
        echo ""
        echo "| # | 镜像 |"
        echo "|---|------|"
        local idx=0
        while read -r img; do
            idx=$((idx + 1))
            echo "| $idx | \`$img\` |"
        done < "$success_file"
        echo ""
        echo "</details>"
        echo ""
        echo "---"
        echo ""
    fi

    # 跳过列表 (折叠)
    if [[ -s "$skipped_file" ]]; then
        echo "## ⊘ 跳过镜像 ($skipped_count 个)"
        echo ""
        echo "<details><summary>点击展开查看</summary>"
        echo ""
        echo "| # | 镜像 |"
        echo "|---|------|"
        local idx=0
        while read -r img; do
            idx=$((idx + 1))
            echo "| $idx | \`$img\` |"
        done < "$skipped_file"
        echo ""
        echo "</details>"
    fi

    echo ""
    echo "---"
    echo ""
    echo "> 📌 本报告由 CNB Docker 镜像同步工具自动生成"
}

