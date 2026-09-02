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
#   CNB_TOKEN       CNB API Token (流水线自动注入)
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

# 安全生成 JSON Payload (避免 Markdown 表格、换行符和双引号破坏 JSON 格式)
safe_json_payload() {
    local title="${1:-}"
    local body="${2:-}"
    local state="${3:-}"
    
    python3 -c '
import sys, json
title = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else ""
body = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else ""
state = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None
data = {}
if title:
    data["title"] = title
if body:
    data["body"] = body
if state:
    data["state"] = state
print(json.dumps(data, ensure_ascii=False))
' "$title" "$body" "$state" 2>/dev/null || jq -n --arg title "$title" --arg body "$body" --arg state "$state" \
  '(if $title != "" then {"title": $title} else {} end) + (if $body != "" then {"body": $body} else {} end) + (if $state != "" then {"state": $state} else {} end)' 2>/dev/null
}

# 1. 创建新 Issue (适用于 Push 或 Web 触发)
# 用法: issue_create "标题" "内容"
# 返回: ISSUE_IID
issue_create() {
    local title="$1"
    local body="${2:-}"
    
    if [[ -z "${CNB_TOKEN:-}" ]]; then
        log_issue "⚠️ CNB_TOKEN 未设置，跳过 Issue 创建"
        return 0
    fi
    
    # 确保 CNB_REPO_SLUG 正确设置
    if [[ -z "${CNB_REPO_SLUG:-}" ]]; then
        CNB_REPO_SLUG="${CNB_ORG:-}/${CNB_PROJECT:-}"
    fi
    
    log_issue "创建 Issue: $title"
    log_issue "目标仓库: $CNB_REPO_SLUG"
    
    local payload
    payload=$(safe_json_payload "$title" "$body")
    
    local response iid
    
    # 方式1: CNB OpenAPI (POST https://api.cnb.cool/{group}/{repo}/issues)
    response=$(curl -s -w "\n%{http_code}" -X POST \
        "${CNB_API_URL}/${CNB_REPO_SLUG}/issues" \
        -H "Authorization: Bearer ${CNB_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "$payload" 2>/dev/null) || true
    
    local http_code=$(echo "$response" | tail -1)
    local body_response=$(echo "$response" | head -n -1)
    
    log_issue "响应码: $http_code"
    
    # 解析 Issue ID
    iid=$(echo "$body_response" | grep -oE '"iid"\s*:\s*[0-9]+' | head -1 | grep -oE '[0-9]+' || echo "")
    if [[ -z "$iid" ]]; then
        iid=$(echo "$body_response" | grep -oE '"number"\s*:\s*"[0-9]+"' | head -1 | grep -oE '[0-9]+' || echo "")
    fi
    if [[ -z "$iid" ]]; then
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
    
    # 方式2: 备用 API 路由格式
    response=$(curl -s -w "\n%{http_code}" -X POST \
        "${CNB_API_URL}/${CNB_REPO_SLUG}/-/issues" \
        -H "Authorization: Bearer ${CNB_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "$payload" 2>/dev/null) || true
    
    http_code=$(echo "$response" | tail -1)
    body_response=$(echo "$response" | head -n -1)
    
    iid=$(echo "$body_response" | grep -oE '"iid"\s*:\s*[0-9]+' | head -1 | grep -oE '[0-9]+' || echo "")
    if [[ -n "$iid" ]] && [[ "$http_code" =~ ^2 ]]; then
        log_issue "✓ Issue #$iid 创建成功"
        echo "$iid"
        return 0
    fi
    
    log_issue "⚠️ Issue 创建请求返回状态: $http_code"
    return 0
}

# 2. 添加 Issue 评论 (适用于 Issue 触发的流水线)
# 用法: issue_comment $ISSUE_IID "评论内容"
issue_comment() {
    local iid="$1"
    local body="$2"
    
    if [[ -z "${CNB_TOKEN:-}" ]] || [[ -z "$iid" ]]; then
        return 0
    fi
    
    if [[ -z "${CNB_REPO_SLUG:-}" ]]; then
        CNB_REPO_SLUG="${CNB_ORG:-}/${CNB_PROJECT:-}"
    fi
    
    local payload
    payload=$(safe_json_payload "" "$body")
    
    log_issue "正在向 Issue #$iid 发表评论报告..."
    
    # 方式1: CNB OpenAPI (POST /{repo}/issues/{iid}/comments)
    local response
    response=$(curl -s -w "\n%{http_code}" -X POST \
        "${CNB_API_URL}/${CNB_REPO_SLUG}/issues/${iid}/comments" \
        -H "Authorization: Bearer ${CNB_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "$payload" 2>/dev/null) || true
        
    local http_code=$(echo "$response" | tail -1)
    if [[ "$http_code" =~ ^2 ]]; then
        log_issue "✓ Issue #$iid 评论发表成功"
        return 0
    fi
    
    # 方式2: Fallback (POST /api/v4/projects/{id}/issues/{iid}/notes)
    local repo_encoded
    repo_encoded=$(url_encode "$CNB_REPO_SLUG")
    curl -s -X POST \
        "${CNB_API_URL}/api/v4/projects/${repo_encoded}/issues/${iid}/notes" \
        -H "PRIVATE-TOKEN: ${CNB_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$payload" >/dev/null 2>&1 || true
}

# 3. 更新 Issue 状态/内容
# 用法: issue_update $ISSUE_IID "新内容"
issue_update() {
    local iid="$1"
    local body="$2"
    
    if [[ -z "${CNB_TOKEN:-}" ]] || [[ -z "$iid" ]]; then
        return 0
    fi
    
    if [[ -z "${CNB_REPO_SLUG:-}" ]]; then
        CNB_REPO_SLUG="${CNB_ORG:-}/${CNB_PROJECT:-}"
    fi
    
    local payload
    payload=$(safe_json_payload "" "$body")
    
    curl -s -X PATCH \
        "${CNB_API_URL}/${CNB_REPO_SLUG}/issues/${iid}" \
        -H "Authorization: Bearer ${CNB_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "$payload" >/dev/null 2>&1 || true
}

# 4. 关闭 Issue
# 用法: issue_close $ISSUE_IID
issue_close() {
    local iid="$1"
    
    if [[ -z "${CNB_TOKEN:-}" ]] || [[ -z "$iid" ]]; then
        return 0
    fi
    
    if [[ -z "${CNB_REPO_SLUG:-}" ]]; then
        CNB_REPO_SLUG="${CNB_ORG:-}/${CNB_PROJECT:-}"
    fi
    
    local payload='{"state": "closed"}'
    curl -s -X PATCH \
        "${CNB_API_URL}/${CNB_REPO_SLUG}/issues/${iid}" \
        -H "Authorization: Bearer ${CNB_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "$payload" >/dev/null 2>&1 || true
    log_issue "✓ Issue #$iid 已自动标记关闭"
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
    
    local status_badge="✅ 同步全部成功"
    if [[ $failed_count -gt 0 ]]; then
        status_badge="⚠️ 存在部分同步失败 ($failed_count 个)"
    fi

    cat << EOF
# 🔄 Docker 镜像同步报告

**运行状态**: $status_badge

## 📋 任务基本信息

| 属性 | 详细内容 |
| :--- | :--- |
| 📁 **源文件清单** | \`$source_file\` |
| 🏗️ **目标架构** | \`$arch\` |
| ⏱️ **开始时间** | $start_time |
| ⏱️ **结束时间** | $end_time |

---

## 📊 同步统计汇总

| 同步状态 | 数量 | 详细说明 |
| :--- | :--- | :--- |
| ✅ **同步成功** | **$success_count** | 已成功推送到 CNB 制品库 |
| ⊘ **跳过存在** | **$skipped_count** | 目标镜像已存在，自动跳过 |
| ❌ **同步失败** | **$failed_count** | 拉取或推送失败（详见下表） |
| 📦 **总计镜像** | **$total** | 本次同步处理的镜像总数 |

---

EOF

    # 失败列表 (有失败时优先高亮展开展示)
    if [[ -s "$failed_file" ]]; then
        echo "## ❌ 失败镜像清单 ($failed_count 个)"
        echo ""
        echo "> 💡 提示：失败通常是由于上游 Tag 404 不存在、古老 Schema 1 协议废弃或并发限流导致。"
        echo ""
        echo "| # | 镜像全称 |"
        echo "| :---: | :--- |"
        local idx=0
        while read -r img; do
            [[ -z "$img" ]] && continue
            idx=$((idx + 1))
            echo "| $idx | \`$img\` |"
        done < "$failed_file"
        echo ""
        echo "---"
        echo ""
    fi

    # 成功列表 (折叠)
    if [[ -s "$success_file" ]]; then
        echo "## ✅ 成功镜像清单 ($success_count 个)"
        echo ""
        echo "<details><summary><b>点击展开查看成功镜像列表</b></summary>"
        echo ""
        echo "| # | 镜像全称 |"
        echo "| :---: | :--- |"
        local idx=0
        while read -r img; do
            [[ -z "$img" ]] && continue
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
        echo "## ⊘ 已跳过镜像清单 ($skipped_count 个)"
        echo ""
        echo "<details><summary><b>点击展开查看已存在/跳过镜像列表</b></summary>"
        echo ""
        echo "| # | 镜像全称 |"
        echo "| :---: | :--- |"
        local idx=0
        while read -r img; do
            [[ -z "$img" ]] && continue
            idx=$((idx + 1))
            echo "| $idx | \`$img\` |"
        done < "$skipped_file"
        echo ""
        echo "</details>"
        echo ""
    fi

    echo ""
    echo "---"
    echo ""
    echo "> 📌 本报告由 CNB Docker 镜像同步流水线自动生成并投递。"
}
