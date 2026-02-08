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
    
    local repo_encoded
    repo_encoded=$(url_encode "$CNB_REPO_SLUG")
    
    log_issue "创建 Issue: $title"
    
    local response
    response=$(curl -s -X POST \
        "${CNB_API_URL}/api/v4/projects/${repo_encoded}/issues" \
        -H "PRIVATE-TOKEN: ${CNB_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"title\": \"${title}\", \"description\": \"${body}\"}" \
        2>/dev/null) || true
    
    local iid
    iid=$(echo "$response" | grep -o '"iid":[0-9]*' | head -1 | grep -o '[0-9]*' || echo "")
    
    if [[ -n "$iid" ]]; then
        log_issue "✓ Issue #$iid 创建成功"
        echo "$iid"
    else
        log_issue "⚠️ Issue 创建失败: $response"
        return 1
    fi
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
    
    local repo_encoded
    repo_encoded=$(url_encode "$CNB_REPO_SLUG")
    
    curl -s -X PUT \
        "${CNB_API_URL}/api/v4/projects/${repo_encoded}/issues/${iid}" \
        -H "PRIVATE-TOKEN: ${CNB_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"description\": \"${body}\"}" \
        >/dev/null 2>&1 || true
}

# 关闭 Issue
# 用法: issue_close $ISSUE_IID
issue_close() {
    local iid="$1"
    
    if [[ -z "${CNB_TOKEN:-}" ]] || [[ -z "$iid" ]]; then
        return 1
    fi
    
    local repo_encoded
    repo_encoded=$(url_encode "$CNB_REPO_SLUG")
    
    curl -s -X PUT \
        "${CNB_API_URL}/api/v4/projects/${repo_encoded}/issues/${iid}" \
        -H "PRIVATE-TOKEN: ${CNB_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{"state_event": "close"}' \
        >/dev/null 2>&1 || true
    
    log_issue "Issue #$iid 已关闭"
}

# 生成同步报告 Markdown
# 用法: generate_sync_report
generate_sync_report() {
    local success_file="${1:-/tmp/sync-success-$$.txt}"
    local failed_file="${2:-/tmp/sync-failed-$$.txt}"
    local skipped_file="${3:-/tmp/sync-skipped-$$.txt}"
    local arch="${4:-amd64}"
    local start_time="${5:-$(date '+%Y-%m-%d %H:%M:%S')}"
    
    local success_count=$(wc -l < "$success_file" 2>/dev/null | tr -d ' ' || echo 0)
    local failed_count=$(wc -l < "$failed_file" 2>/dev/null | tr -d ' ' || echo 0)
    local skipped_count=$(wc -l < "$skipped_file" 2>/dev/null | tr -d ' ' || echo 0)
    local total=$((success_count + failed_count + skipped_count))
    
    cat << EOF
## 📊 同步统计

| 项目 | 值 |
|------|------|
| 🕐 开始时间 | $start_time |
| 🏗️ 架构 | $arch |
| 📦 总计 | $total |
| ✅ 成功 | $success_count |
| ⊘ 跳过 | $skipped_count |
| ❌ 失败 | $failed_count |

---

EOF

    if [[ -s "$failed_file" ]]; then
        echo "## ❌ 失败列表"
        echo ""
        echo '```'
        cat "$failed_file"
        echo '```'
        echo ""
    fi

    if [[ -s "$success_file" ]]; then
        echo "## ✅ 成功列表"
        echo ""
        echo "<details><summary>展开查看 ($success_count 个)</summary>"
        echo ""
        echo '```'
        cat "$success_file"
        echo '```'
        echo ""
        echo "</details>"
        echo ""
    fi

    if [[ -s "$skipped_file" ]]; then
        echo "## ⊘ 跳过列表"
        echo ""
        echo "<details><summary>展开查看 ($skipped_count 个)</summary>"
        echo ""
        echo '```'
        cat "$skipped_file"
        echo '```'
        echo ""
        echo "</details>"
    fi
}
