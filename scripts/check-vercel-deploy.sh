#!/usr/bin/env bash
# =============================================================================
# check-vercel-deploy.sh — 轮询 Vercel 部署状态，部署完成后输出回调信息
# =============================================================================
#
# 背景：
#   当 AI 通过 deploy-to-vercel.sh 推送代码到 GitHub 后，Vercel 会自动触发
#   部署。本脚本轮询 Vercel API 检测部署是否成功，并在完成后输出结构化的
#   回调信息（JSON），供 AI 消费。
#
# 核心特性：
#   - 自动发现最新部署（通过 projectId 或 repo 名称查找项目）
#   - 轮询部署状态直到完成（READY / ERROR / CANCELED）
#   - 支持超时和自定义轮询间隔
#   - 输出结构化 JSON 回调信息（部署 URL、构建时间、错误信息等）
#   - 部署成功 → exit 0；失败/超时 → exit 1
#
# =============================================================================
# 调用方式
# =============================================================================
#
# 方式 1：通过环境变量传入（推荐）
#
#   export VERCEL_TOKEN="xxxxxxxxxxxxx"
#   export GITHUB_REPO_NAME="my-ai-generated-game"   # 通过 repo 名自动查找项目
#   # 或者直接指定 projectId（跳过项目查找）：
#   export VERCEL_PROJECT_ID="prj_xxxxxxxxxxxx"
#   export VERCEL_TEAM_ID="team_xxxxx"               # 可选
#   export MAX_WAIT_SECONDS="600"                     # 可选，默认 600 秒
#   export POLL_INTERVAL="10"                         # 可选，默认 10 秒
#
#   ./scripts/check-vercel-deploy.sh
#
# 方式 2：通过命令行参数传入
#
#   ./scripts/check-vercel-deploy.sh \
#       --vercel-token xxxxxxx \
#       --repo-name my-ai-generated-game \
#       --max-wait 600 \
#       --poll-interval 10
#
# =============================================================================
# 输出格式
# =============================================================================
#
# 所有日志输出到 stderr，最终回调 JSON 输出到 stdout。
# 这样可以方便地捕获 JSON 结果：
#
#   result=$(./scripts/check-vercel-deploy.sh 2>/dev/null)
#   deploy_url=$(echo "$result" | jq -r '.deploy_url')
#
# 回调 JSON 示例（成功）：
# {
#   "status": "success",
#   "project_name": "my-game",
#   "deploy_url": "https://my-game-abc123.vercel.app",
#   "inspector_url": "https://vercel.com/...",
#   "branch": "main",
#   "commit_sha": "abc1234",
#   "build_time_seconds": 45,
#   "created_at": "2026-06-02T11:30:00Z",
#   "ready_at": "2026-06-02T11:30:45Z"
# }
#
# 回调 JSON 示例（失败）：
# {
#   "status": "error",
#   "project_name": "my-game",
#   "error_message": "Build failed: ...",
#   "inspector_url": "https://vercel.com/...",
#   "build_time_seconds": 30
# }
#
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# 颜色输出（输出到 stderr，不影响 stdout 的 JSON）
# ---------------------------------------------------------------------------
if [ -t 2 ] && command -v tput &>/dev/null; then
    _RED=$(tput setaf 1)
    _GREEN=$(tput setaf 2)
    _YELLOW=$(tput setaf 3)
    _BLUE=$(tput setaf 4)
    _CYAN=$(tput setaf 6)
    _BOLD=$(tput bold)
    _RESET=$(tput sgr0)
else
    _RED="" _GREEN="" _YELLOW="" _BLUE="" _CYAN="" _BOLD="" _RESET=""
fi

# ---------------------------------------------------------------------------
# 辅助函数（全部输出到 stderr）
# ---------------------------------------------------------------------------
log_info()    { echo -e "${_BLUE}[INFO]${_RESET}  $(date '+%H:%M:%S')  $*" >&2; }
log_success() { echo -e "${_GREEN}[OK]${_RESET}    $(date '+%H:%M:%S')  $*" >&2; }
log_warn()    { echo -e "${_YELLOW}[WARN]${_RESET}  $(date '+%H:%M:%S')  $*" >&2; }
log_error()   { echo -e "${_RED}[ERROR]${_RESET} $(date '+%H:%M:%S')  $*" >&2; }

log_separator() {
    echo -e "${_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_RESET}" >&2
}

# 进度动画：旋转指示器（输出到 stderr）
declare -a SPINNER=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
spinner_idx=0
spinner_pid=""

start_spinner() {
    local msg="$1"
    # 在后台运行旋转动画
    (
        while true; do
            printf "\r${_CYAN}  %s${_RESET} %s" "${SPINNER[$spinner_idx]}" "$msg" >&2
            spinner_idx=$(( (spinner_idx + 1) % ${#SPINNER[@]} ))
            sleep 0.1
        done
    ) &
    spinner_pid=$!
}

stop_spinner() {
    if [ -n "$spinner_pid" ] && kill -0 "$spinner_pid" 2>/dev/null; then
        kill "$spinner_pid" 2>/dev/null || true
        wait "$spinner_pid" 2>/dev/null || true
    fi
    # 清除旋转动画行
    printf "\r\033[K" >&2
}

# 退出时确保清理 spinner
cleanup() {
    stop_spinner
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# JSON 辅助函数（使用 jq 或降级方案）
# ---------------------------------------------------------------------------
json_get() {
    local json="$1"
    local key="$2"
    if command -v jq &>/dev/null; then
        echo "$json" | jq -r ".$key // empty" 2>/dev/null
    else
        # 简易降级：匹配 "key": "value" 或 "key": value
        echo "$json" | grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
            | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' 2>/dev/null || true
    fi
}

# 从部署对象中提取字段（支持蛇形和驼峰两种命名）
deploy_field() {
    local json="$1"
    local camel="$2"       # 驼峰命名（Vercel API 实际使用的格式）
    local snake="${3:-}"    # 蛇形命名（备用）
    local val
    if command -v jq &>/dev/null; then
        val=$(echo "$json" | jq -r ".${camel} // empty" 2>/dev/null || true)
        if [ -z "$val" ] && [ -n "$snake" ]; then
            val=$(echo "$json" | jq -r ".${snake} // empty" 2>/dev/null || true)
        fi
        echo "$val"
    else
        # 降级：匹配驼峰格式
        val=$(echo "$json" | grep -o "\"${camel}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
            | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' 2>/dev/null || true)
        [ -z "$val" ] && val=$(echo "$json" | grep -o "\"${camel}\":[[:space:]]*\([0-9]*\)" \
            | head -1 | sed 's/.*:[[:space:]]*\([0-9]*\).*/\1/' 2>/dev/null || true)
        # 降级：匹配蛇形格式
        if [ -z "$val" ] && [ -n "$snake" ]; then
            val=$(echo "$json" | grep -o "\"${snake}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
                | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' 2>/dev/null || true)
        fi
        echo "$val"
    fi
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --vercel-token)     VERCEL_TOKEN="$2";     shift 2 ;;
            --vercel-project-id) VERCEL_PROJECT_ID="$2"; shift 2 ;;
            --vercel-team-id)   VERCEL_TEAM_ID="$2";   shift 2 ;;
            --repo-name)        GITHUB_REPO_NAME="$2"; shift 2 ;;
            --max-wait)         MAX_WAIT_SECONDS="$2"; shift 2 ;;
            --poll-interval)    POLL_INTERVAL="$2";    shift 2 ;;
            --help|-h)
                head -80 "$0" | tail -n +2 | grep '^#' | sed 's/^# \{0,1\}//'
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                log_error "使用 --help 查看帮助"
                exit 1
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# 初始化与验证
# ---------------------------------------------------------------------------
init() {
    log_separator
    log_info "check-vercel-deploy.sh — Vercel 部署状态检测 & AI 回调"
    log_separator

    # 默认值
    MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-600}"
    POLL_INTERVAL="${POLL_INTERVAL:-10}"
    VERCEL_API_BASE="https://api.vercel.com"

    # 验证必需变量
    if [ -z "${VERCEL_TOKEN:-}" ]; then
        log_error "缺少 VERCEL_TOKEN"
        log_error "  设置: export VERCEL_TOKEN=xxx 或 --vercel-token xxx"
        exit 1
    fi

    if [ -z "${VERCEL_PROJECT_ID:-}" ] && [ -z "${GITHUB_REPO_NAME:-}" ]; then
        log_error "缺少项目标识，请提供 VERCEL_PROJECT_ID 或 GITHUB_REPO_NAME"
        log_error "  设置: export VERCEL_PROJECT_ID=prj_xxx 或 export GITHUB_REPO_NAME=xxx"
        exit 1
    fi

    VERCEL_AUTH_HEADER="Authorization: Bearer ${VERCEL_TOKEN}"

    # Vercel Team ID 查询参数
    if [ -n "${VERCEL_TEAM_ID:-}" ]; then
        VERCEL_TEAM_QUERY="?teamId=${VERCEL_TEAM_ID}"
    else
        VERCEL_TEAM_QUERY=""
    fi

    # 检查依赖
    if ! command -v curl &>/dev/null; then
        log_error "缺少 curl，请安装后重试"
        exit 1
    fi

    log_info "Vercel Token:  ${VERCEL_TOKEN:0:8}..."
    log_info "Project ID:   ${VERCEL_PROJECT_ID:-（将通过 repo 名查找）}"
    log_info "Repo Name:    ${GITHUB_REPO_NAME:-（已指定 projectId）}"
    log_info "Team ID:      ${VERCEL_TEAM_ID:-未设置}"
    log_info "最大等待:     ${MAX_WAIT_SECONDS}s"
    log_info "轮询间隔:     ${POLL_INTERVAL}s"
    echo "" >&2
}

# ---------------------------------------------------------------------------
# 通过 repo 名称查找 Vercel 项目 ID
# ---------------------------------------------------------------------------
find_project_by_name() {
    local name="$1"
    log_info "正在查找 Vercel 项目: $name ..."

    local list_url="${VERCEL_API_BASE}/v9/projects${VERCEL_TEAM_QUERY}"
    if [[ "$list_url" == *"?"* ]]; then
        list_url="${list_url}&name=${name}"
    else
        list_url="${list_url}?name=${name}"
    fi

    local resp
    resp=$(curl -sS -H "$VERCEL_AUTH_HEADER" "$list_url" 2>/dev/null || echo "{}")

    local pid
    if command -v jq &>/dev/null; then
        pid=$(echo "$resp" | jq -r ".projects[]? | select(.name == \"${name}\") | .id // empty" 2>/dev/null | head -1)
    else
        pid=$(echo "$resp" | grep -o "\"name\":\"${name}\"[^}]*\"id\":\"[^\"]*\"" \
            | head -1 | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"//' || true)
    fi

    if [ -n "$pid" ]; then
        VERCEL_PROJECT_ID="$pid"
        log_success "找到项目: $name (id: $VERCEL_PROJECT_ID)"
    else
        log_error "未找到 Vercel 项目: $name"
        log_error "  请确认项目已在 Vercel 上创建（可先运行 deploy-to-vercel.sh）"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# 获取最新部署
# ---------------------------------------------------------------------------
fetch_latest_deployment() {
    local pid="$1"
    local url="${VERCEL_API_BASE}/v6/deployments${VERCEL_TEAM_QUERY}"
    if [[ "$url" == *"?"* ]]; then
        url="${url}&projectId=${pid}&limit=1"
    else
        url="${url}?projectId=${pid}&limit=1"
    fi

    curl -sS -H "$VERCEL_AUTH_HEADER" "$url" 2>/dev/null || echo "{}"
}

# ---------------------------------------------------------------------------
# 获取某个部署的详情
# ---------------------------------------------------------------------------
fetch_deployment_detail() {
    local did="$1"
    local url="${VERCEL_API_BASE}/v12/deployments/${did}${VERCEL_TEAM_QUERY}"
    if [[ "$url" == *"?"* ]]; then
        url="${url}"
    fi
    curl -sS -H "$VERCEL_AUTH_HEADER" "$url" 2>/dev/null || echo "{}"
}

# ---------------------------------------------------------------------------
# 提取部署信息（用于最终 JSON 输出）
# ---------------------------------------------------------------------------
extract_deployment_info() {
    local deployment="$1"   # 部署对象的 JSON

    if command -v jq &>/dev/null; then
        # 使用 jq 精确提取
        local uid state name url inspector created ready meta commit msg
        uid=$(echo "$deployment" | jq -r '.uid // .id // empty' 2>/dev/null)
        state=$(echo "$deployment" | jq -r '.state // empty' 2>/dev/null)
        name=$(echo "$deployment" | jq -r '.name // empty' 2>/dev/null)
        url=$(echo "$deployment" | jq -r '.url // empty' 2>/dev/null)
        inspector=$(echo "$deployment" | jq -r '.inspectorUrl // empty' 2>/dev/null)
        created=$(echo "$deployment" | jq -r '.createdAt // empty' 2>/dev/null)
        ready=$(echo "$deployment" | jq -r '.ready // empty' 2>/dev/null)
        meta=$(echo "$deployment" | jq -r '.meta // {}' 2>/dev/null)
        commit=$(echo "$meta" | jq -r '.githubCommitSha // .gitlabCommitSha // empty' 2>/dev/null)
        msg=$(echo "$meta" | jq -r '.githubCommitMessage // .gitlabCommitMessage // empty' 2>/dev/null)
    else
        # 降级方案
        local uid state name url inspector created ready commit msg
        uid=$(json_get "$deployment" "uid")
        [ -z "$uid" ] && uid=$(json_get "$deployment" "id")
        state=$(json_get "$deployment" "state")
        name=$(json_get "$deployment" "name")
        url=$(json_get "$deployment" "url")
        inspector=$(json_get "$deployment" "inspectorUrl")
        created=$(json_get "$deployment" "createdAt")
        ready=$(json_get "$deployment" "ready")
        commit=""
        msg=""
    fi

    # 返回所有信息（用换行分隔，调用方逐行读取）
    cat <<INNEREOF
DEPLOY_UID=${uid:-unknown}
DEPLOY_STATE=${state:-UNKNOWN}
PROJECT_NAME=${name:-unknown}
DEPLOY_URL=${url:-}
INSPECTOR_URL=${inspector:-}
CREATED_AT=${created:-}
READY_AT=${ready:-}
COMMIT_SHA=${commit:-}
COMMIT_MSG=${msg:-}
INNEREOF
}

# ---------------------------------------------------------------------------
# 获取部署事件的流水日志 (events)
# ---------------------------------------------------------------------------
fetch_deployment_events() {
    local did="$1"
    local url="${VERCEL_API_BASE}/v2/deployments/${did}/events${VERCEL_TEAM_QUERY}"
    curl -sS -H "$VERCEL_AUTH_HEADER" "$url" 2>/dev/null || echo "[]"
}

# ---------------------------------------------------------------------------
# 提取错误信息（从事件日志中）
# ---------------------------------------------------------------------------
extract_error_from_events() {
    local events="$1"
    if command -v jq &>/dev/null; then
        # 查找 type 为 "error" 的事件
        echo "$events" | jq -r '[.[] | select(.type == "error")] |
            .[-1].payload.text // .[-1].payload.message //
            .[-1].text // "Unknown error"' 2>/dev/null || echo "Unknown error"
    else
        echo "Build failed (install jq for detailed error message)"
    fi
}

# ---------------------------------------------------------------------------
# 计算时间差（秒）
# ---------------------------------------------------------------------------
calc_duration_seconds() {
    local start="$1"  # 毫秒 epoch 或 ISO 8601 时间戳
    local end="$2"    # 毫秒 epoch 或 ISO 8601 时间戳
    if [ -z "$start" ] || [ -z "$end" ]; then
        echo "0"
        return
    fi
    # 转换为 epoch 秒
    local start_epoch end_epoch
    # 检测：如果是纯数字则为毫秒 epoch（如 1780401019860）
    if [[ "$start" =~ ^[0-9]+$ ]]; then
        # 毫秒 epoch → 秒
        start_epoch=$(( start / 1000 ))
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        start_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${start%%.*}" +%s 2>/dev/null || echo "0")
    else
        start_epoch=$(date -d "${start%%.*}" +%s 2>/dev/null || echo "0")
    fi

    if [[ "$end" =~ ^[0-9]+$ ]]; then
        end_epoch=$(( end / 1000 ))
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        end_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${end%%.*}" +%s 2>/dev/null || echo "0")
    else
        end_epoch=$(date -d "${end%%.*}" +%s 2>/dev/null || echo "0")
    fi
    echo $(( end_epoch - start_epoch ))
}

# 将毫秒 epoch 或 ISO 8601 时间戳转换为 ISO 8601 字符串
epoch_to_iso() {
    local ts="$1"
    if [ -z "$ts" ]; then
        echo ""
        return
    fi
    # 如果是纯数字（毫秒 epoch），转换为 ISO 8601
    if [[ "$ts" =~ ^[0-9]+$ ]]; then
        local epoch_sec=$(( ts / 1000 ))
        if [[ "$OSTYPE" == "darwin"* ]]; then
            date -j -f "%s" "$epoch_sec" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "$ts"
        else
            date -d "@$epoch_sec" -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "$ts"
        fi
    else
        # 已经是 ISO 8601 字符串，直接返回
        echo "$ts"
    fi
}

# ---------------------------------------------------------------------------
# 输出回调 JSON（到 stdout）
# ---------------------------------------------------------------------------
output_callback_json() {
    local status="$1"          # success | error | timeout | canceled
    local project_name="$2"
    local deploy_url="$3"
    local inspector_url="$4"
    local commit_sha="$5"
    local commit_msg="$6"
    local build_seconds="$7"
    local created_at="$8"
    local ready_at="$9"
    local error_msg="${10:-}"

    # 转义 commit message 和 error message 中的特殊字符
    # 注意：先 trim 掉首尾空白，避免 jq 转义出 "\n" 等干扰
    if command -v jq &>/dev/null; then
        local msg_trimmed err_trimmed
        msg_trimmed=$(printf '%s' "${commit_msg}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        err_trimmed=$(printf '%s' "${error_msg}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        local escaped_msg
        escaped_msg=$(printf '%s' "$msg_trimmed" | jq -Rs . 2>/dev/null || echo "\"${msg_trimmed}\"")
        local escaped_error
        if [ -n "$err_trimmed" ]; then
            escaped_error=$(printf '%s' "$err_trimmed" | jq -Rs . 2>/dev/null || echo "\"${err_trimmed}\"")
        else
            escaped_error='""'
        fi

        jq -n \
            --arg status "$status" \
            --arg project_name "$project_name" \
            --arg deploy_url "$deploy_url" \
            --arg inspector_url "$inspector_url" \
            --arg commit_sha "$commit_sha" \
            --argjson commit_msg "$escaped_msg" \
            --arg build_time_seconds "$build_seconds" \
            --arg created_at "$created_at" \
            --arg ready_at "$ready_at" \
            --argjson error_message "$escaped_error" \
            '{
                status: $status,
                project_name: $project_name,
                deploy_url: ("https://" + $deploy_url),
                inspector_url: $inspector_url,
                branch: "main",
                commit_sha: $commit_sha,
                commit_message: $commit_msg,
                build_time_seconds: ($build_time_seconds | tonumber),
                created_at: $created_at,
                ready_at: $ready_at,
                error_message: $error_message,
                checked_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
            }'
    else
        # 降级：手动构造 JSON（不完美但可用）
        cat <<INNEREOF
{
  "status": "$status",
  "project_name": "$project_name",
  "deploy_url": "https://$deploy_url",
  "inspector_url": "$inspector_url",
  "branch": "main",
  "commit_sha": "$commit_sha",
  "commit_message": "$commit_msg",
  "build_time_seconds": $build_seconds,
  "created_at": "$created_at",
  "ready_at": "$ready_at",
  "error_message": "$error_msg",
  "checked_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")"
}
INNEREOF
    fi
}

# ---------------------------------------------------------------------------
# 主轮询逻辑
# ---------------------------------------------------------------------------
poll_deployment() {
    local pid="$1"
    local start_time
    start_time=$(date +%s)

    # 等待一小段时间让 Vercel 接收到 webhook 并创建部署
    log_info "等待 Vercel 接收 Git push 事件（5s）..."
    sleep 5

    # 获取最新部署
    local latest_resp
    local deploy_uid
    local deploy_state

    # 先获取当前最新部署
    latest_resp=$(fetch_latest_deployment "$pid")

    if command -v jq &>/dev/null; then
        deploy_uid=$(echo "$latest_resp" | jq -r '.deployments[0].uid // .deployments[0].id // empty' 2>/dev/null)
        deploy_state=$(echo "$latest_resp" | jq -r '.deployments[0].state // empty' 2>/dev/null)
    else
        deploy_uid=$(json_get "$latest_resp" "uid")
        [ -z "$deploy_uid" ] && deploy_uid=$(json_get "$latest_resp" "id")
        deploy_state=$(json_get "$latest_resp" "state")
    fi

    if [ -z "$deploy_uid" ]; then
        log_error "未找到任何部署记录"
        log_error "这可能是因为："
        log_error "  1. Vercel 项目未正确绑定 GitHub 仓库"
        log_error "  2. Git push 未触发自动部署"
        log_error "  3. VERCEL_PROJECT_ID 不正确"
        exit 1
    fi

    log_info "最新部署:   $deploy_uid"
    log_info "初始状态:   $deploy_state"
    log_info "检查页面:   https://vercel.com/dashboard/deployments/$deploy_uid"
    echo "" >&2

    # 如果已经处于终态，直接输出
    if [ "$deploy_state" = "READY" ] || [ "$deploy_state" = "ERROR" ] || [ "$deploy_state" = "CANCELED" ]; then
        log_info "部署已处于终态 ($deploy_state)，无需等待"
        process_terminal_state "$deploy_uid" "$pid"
        return
    fi

    # --- 轮询循环 ---
    local poll_count=0
    local last_state="$deploy_state"
    local elapsed

    log_info "开始轮询部署状态..."
    echo "" >&2

    while true; do
        elapsed=$(( $(date +%s) - start_time ))

        # 超时检查
        if [ "$elapsed" -ge "$MAX_WAIT_SECONDS" ]; then
            stop_spinner
            echo "" >&2
            log_warn "等待超时 (${elapsed}s / ${MAX_WAIT_SECONDS}s)"
            output_callback_json \
                "timeout" \
                "$(deploy_field "$latest_resp" "name" "project_name")" \
                "$(deploy_field "$latest_resp" "url")" \
                "https://vercel.com/dashboard/deployments/$deploy_uid" \
                "" \
                "" \
                "$elapsed" \
                "" \
                "" \
                "Deployment polling timed out after ${MAX_WAIT_SECONDS}s. Last state: ${last_state}"
            exit 1
        fi

        # 显示进度
        local progress_msg="轮询中... 状态: ${_YELLOW}${last_state}${_RESET}  |  已等待: ${elapsed}s/${MAX_WAIT_SECONDS}s"
        printf "\r${_CYAN}  ⏳${_RESET} %s" "$progress_msg" >&2

        # 获取最新状态
        latest_resp=$(fetch_latest_deployment "$pid")

        if command -v jq &>/dev/null; then
            local new_uid new_state
            new_uid=$(echo "$latest_resp" | jq -r '.deployments[0].uid // .deployments[0].id // empty' 2>/dev/null)
            new_state=$(echo "$latest_resp" | jq -r '.deployments[0].state // empty' 2>/dev/null)

            # 如果部署 ID 变了（可能是重试或新部署），更新跟踪
            if [ -n "$new_uid" ] && [ "$new_uid" != "$deploy_uid" ]; then
                deploy_uid="$new_uid"
                log_warn "检测到新部署: $deploy_uid"
            fi
            deploy_state="$new_state"
        else
            deploy_state=$(json_get "$latest_resp" "state")
        fi

        # 状态变化时在下一行显示
        if [ "$deploy_state" != "$last_state" ]; then
            printf "\r\033[K" >&2  # 清除当前行
            log_info "状态变更:   ${last_state} → ${_YELLOW}${deploy_state}${_RESET}"
            last_state="$deploy_state"
        fi

        # 检查终态
        case "$deploy_state" in
            READY)
                printf "\r\033[K" >&2  # 清除进度行
                echo "" >&2
                log_success "部署完成！状态: READY ✓"
                process_terminal_state "$deploy_uid" "$pid"
                return
                ;;
            ERROR)
                printf "\r\033[K" >&2
                echo "" >&2
                log_error "部署失败！状态: ERROR ✗"
                process_terminal_state "$deploy_uid" "$pid"
                exit 1
                ;;
            CANCELED)
                printf "\r\033[K" >&2
                echo "" >&2
                log_warn "部署已取消！状态: CANCELED"
                process_terminal_state "$deploy_uid" "$pid"
                exit 1
                ;;
        esac

        poll_count=$((poll_count + 1))
        sleep "$POLL_INTERVAL"
    done
}

# ---------------------------------------------------------------------------
# 处理终态：拉取详细信息并输出回调 JSON
# ---------------------------------------------------------------------------
process_terminal_state() {
    local did="$1"
    local pid="$2"

    log_info "正在拉取部署详细信息..."
    local detail
    detail=$(fetch_deployment_detail "$did")

    # 提取信息
    local deploy_state project_name deploy_url inspector_url created_at ready_at
    local commit_sha commit_msg

    if command -v jq &>/dev/null; then
        # v12 API: 优先使用 readyState，降级到 status，再降级到 state
        deploy_state=$(echo "$detail" | jq -r '.readyState // .status // .state // "UNKNOWN"' 2>/dev/null)
        project_name=$(echo "$detail" | jq -r '.name // empty' 2>/dev/null)
        deploy_url=$(echo "$detail" | jq -r '.url // .alias[0] // empty' 2>/dev/null)
        inspector_url=$(echo "$detail" | jq -r '.inspectorUrl // empty' 2>/dev/null)
        # createdAt 可能是毫秒 epoch (v12) 或 ISO 8601 字符串 (v9)
        created_at=$(echo "$detail" | jq -r '.createdAt // empty' 2>/dev/null)
        # ready 是毫秒 epoch；v9 用 readyAt，v12 用 ready (number)
        ready_at=$(echo "$detail" | jq -r '.ready // .readyAt // empty' 2>/dev/null)
        commit_sha=$(echo "$detail" | jq -r '.meta.githubCommitSha // .meta.gitlabCommitSha // empty' 2>/dev/null)
        commit_msg=$(echo "$detail" | jq -r '.meta.githubCommitMessage // .meta.gitlabCommitMessage // empty' 2>/dev/null)
    else
        local info
        info=$(extract_deployment_info "$detail")
        deploy_state=$(echo "$info" | grep "^DEPLOY_STATE=" | cut -d'=' -f2-)
        project_name=$(echo "$info" | grep "^PROJECT_NAME=" | cut -d'=' -f2-)
        deploy_url=$(echo "$info" | grep "^DEPLOY_URL=" | cut -d'=' -f2-)
        inspector_url=$(echo "$info" | grep "^INSPECTOR_URL=" | cut -d'=' -f2-)
        created_at=$(echo "$info" | grep "^CREATED_AT=" | cut -d'=' -f2-)
        ready_at=$(echo "$info" | grep "^READY_AT=" | cut -d'=' -f2-)
        commit_sha=$(echo "$info" | grep "^COMMIT_SHA=" | cut -d'=' -f2-)
        commit_msg=$(echo "$info" | grep "^COMMIT_MSG=" | cut -d'=' -f2-)
    fi

    # 计算构建时间
    local build_seconds
    build_seconds=$(calc_duration_seconds "$created_at" "$ready_at")

    # 如果失败，尝试获取错误详情
    local error_msg=""
    if [ "$deploy_state" = "ERROR" ]; then
        log_info "正在拉取错误详情..."
        local events
        events=$(fetch_deployment_events "$did")
        error_msg=$(extract_error_from_events "$events")
        log_error "部署错误: $error_msg"
    fi

    # 将毫秒 epoch 时间戳转换为可读格式（用于显示和 JSON 输出）
    local created_iso ready_iso
    created_iso=$(epoch_to_iso "$created_at")
    ready_iso=$(epoch_to_iso "$ready_at")

    # 显示摘要
    echo "" >&2
    log_separator >&2
    log_info "部署摘要:" >&2
    log_info "  项目名称:   $project_name" >&2
    log_info "  部署状态:   ${_GREEN}${deploy_state}${_RESET}" >&2
    log_info "  部署 URL:   https://${deploy_url}" >&2
    [ -n "$inspector_url" ] && log_info "  检查页面:   $inspector_url" >&2
    [ -n "$commit_sha" ] && log_info "  Commit:      ${commit_sha:0:7}" >&2
    [ -n "$commit_msg" ] && log_info "  提交信息:   $commit_msg" >&2
    log_info "  构建耗时:   ${build_seconds}s" >&2
    [ -n "$created_iso" ] && log_info "  创建时间:   $created_iso" >&2
    [ -n "$ready_iso" ] && log_info "  就绪时间:   $ready_iso" >&2
    [ -n "$error_msg" ] && log_error "  错误信息:   $error_msg" >&2
    log_separator >&2
    echo "" >&2

    # 确定状态标签
    local status_label
    case "$deploy_state" in
        READY)    status_label="success" ;;
        ERROR)    status_label="error" ;;
        CANCELED) status_label="canceled" ;;
        *)        status_label="unknown" ;;
    esac

    # 输出回调 JSON 到 stdout
    output_callback_json \
        "$status_label" \
        "${project_name:-unknown}" \
        "${deploy_url}" \
        "${inspector_url:-}" \
        "${commit_sha:-}" \
        "${commit_msg:-}" \
        "${build_seconds:-0}" \
        "${created_iso:-}" \
        "${ready_iso:-}" \
        "${error_msg}"
}

# =============================================================================
# 主流程
# =============================================================================
main() {
    parse_args "$@"

    init

    # 如果未直接提供 projectId，通过 repo 名查找
    if [ -z "${VERCEL_PROJECT_ID:-}" ]; then
        find_project_by_name "$GITHUB_REPO_NAME"
    fi

    # 轮询直到部署完成
    poll_deployment "$VERCEL_PROJECT_ID"
}

# 如果直接运行此脚本（而非被 source），则执行 main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
