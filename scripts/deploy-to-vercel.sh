#!/usr/bin/env bash
# =============================================================================
# deploy-to-vercel.sh — 自动创建 GitHub 远端仓库并绑定 Vercel 项目
# =============================================================================
#
# 背景：
#   用户通过 AI 聊天对话生成游戏项目代码后，需要将代码推送到 GitHub 仓库，
#   并通过 Vercel 自动部署。本脚本自动化了 GitHub 仓库创建 + Vercel 项目
#   绑定 + 首次部署触发的完整流程。
#
# 核心特性：
#   - 如果 GitHub 远端仓库不存在，自动创建（支持 gh CLI 和 API 两种方式）
#   - 如果 Vercel 项目未绑定，通过 REST API 创建并关联 GitHub 仓库
#   - 已绑定则跳过，保证幂等性
#   - 所有敏感参数通过环境变量传入，不硬编码
#
# =============================================================================
# 调用方式
# =============================================================================
#
# 方式 1：通过环境变量传入（推荐用于 CI/CD）
#
#   export GITHUB_TOKEN="ghp_xxxxxxxxxxxx"
#   export VERCEL_TOKEN="xxxxxxxxxxxxx"
#   export GITHUB_REPO_NAME="my-ai-generated-game"
#   export GITHUB_ORG="my-org"              # 可选，默认使用个人账户
#   export VERCEL_TEAM_ID="team_xxxxx"       # 可选，Vercel 团队 ID
#   export PROJECT_DIR="/path/to/project"    # 可选，默认为脚本所在目录的上级
#   export VERCEL_FRAMEWORK="vite"           # 可选，默认自动检测
#
#   ./scripts/deploy-to-vercel.sh
#
#
# 方式 2：通过命令行参数传入
#
#   ./scripts/deploy-to-vercel.sh \
#       --github-token ghp_xxxxx \
#       --vercel-token xxxxxxx \
#       --repo-name my-ai-generated-game \
#       --project-dir /path/to/project \
#       --github-org my-org \          # 可选
#       --vercel-team-id team_xxxxx \   # 可选
#       --framework vite                # 可选
#
#
# 方式 3：混合使用（命令行参数优先级高于环境变量）
#
#   export GITHUB_TOKEN="ghp_xxxxxxxxxxxx"
#   export VERCEL_TOKEN="xxxxxxxxxxxxx"
#   ./scripts/deploy-to-vercel.sh --repo-name my-game
#
# =============================================================================
# 依赖
# =============================================================================
#
# 必需（二选一）：
#   - GitHub CLI (gh)：brew install gh && gh auth login
#   - 或者提供 GITHUB_TOKEN 环境变量（脚本会通过 API 直接操作）
#
# 可选但推荐：
#   - jq：用于解析 JSON 响应（脚本会自动降级到 grep/sed）
#   - git：用于推送代码到远端
#
# =============================================================================
# Vercel API 文档参考
# =============================================================================
#
#   - 创建项目:  POST https://api.vercel.com/v9/projects
#   - 查询项目:  GET  https://api.vercel.com/v9/projects?name=<name>
#   - 获取项目:  GET  https://api.vercel.com/v9/projects/<id>
#   - 触发部署:  POST https://api.vercel.com/v13/deployments
#
# =============================================================================

set -euo pipefail  # 严格模式：任何错误立即退出，未定义变量报错，管道错误传递

# ---------------------------------------------------------------------------
# 颜色输出（可选，终端支持时使用）
# ---------------------------------------------------------------------------
if [ -t 1 ] && command -v tput &>/dev/null; then
    _RED=$(tput setaf 1)
    _GREEN=$(tput setaf 2)
    _YELLOW=$(tput setaf 3)
    _BLUE=$(tput setaf 4)
    _BOLD=$(tput bold)
    _RESET=$(tput sgr0)
else
    _RED="" _GREEN="" _YELLOW="" _BLUE="" _BOLD="" _RESET=""
fi

# ---------------------------------------------------------------------------
# 辅助函数
# ---------------------------------------------------------------------------

log_info()    { echo -e "${_BLUE}[INFO]${_RESET}  $(date '+%H:%M:%S')  $*"; }
log_success() { echo -e "${_GREEN}[OK]${_RESET}    $(date '+%H:%M:%S')  $*"; }
log_warn()    { echo -e "${_YELLOW}[WARN]${_RESET}  $(date '+%H:%M:%S')  $*"; }
log_error()   { echo -e "${_RED}[ERROR]${_RESET} $(date '+%H:%M:%S')  $*" >&2; }

# 打印分隔线
log_separator() {
    echo -e "${_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_RESET}"
}

# 检查命令是否存在
check_command() {
    local cmd="$1"
    local hint="${2:-}"
    if ! command -v "$cmd" &>/dev/null; then
        log_error "缺少必需命令: $cmd"
        [ -n "$hint" ] && log_error "安装提示: $hint"
        return 1
    fi
}

# 读取 JSON 字段值（优先使用 jq，降级到 grep+sed）
# 用法: json_get <json_string> <key>
# 注意：降级方案仅支持简单的字符串值，复杂嵌套请安装 jq
json_get() {
    local json="$1"
    local key="$2"
    if command -v jq &>/dev/null; then
        echo "$json" | jq -r ".$key // empty" 2>/dev/null
    else
        # 简易降级：匹配 "key":"value" 或 "key": "value" 模式
        echo "$json" | grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
            | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --github-token)     GITHUB_TOKEN="$2";     shift 2 ;;
            --vercel-token)     VERCEL_TOKEN="$2";     shift 2 ;;
            --repo-name)        GITHUB_REPO_NAME="$2"; shift 2 ;;
            --github-org)       GITHUB_ORG="$2";       shift 2 ;;
            --vercel-team-id)   VERCEL_TEAM_ID="$2";   shift 2 ;;
            --project-dir)      PROJECT_DIR="$2";      shift 2 ;;
            --framework)        VERCEL_FRAMEWORK="$2"; shift 2 ;;
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
# 0. 前置检查与变量初始化
# ---------------------------------------------------------------------------
preflight_check() {
    log_separator
    log_info "Step 0: 前置检查与变量初始化"
    log_separator

    # --- 默认值 ---
    # PROJECT_DIR 默认为脚本所在目录的上级（即项目根目录）
    PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
    # Vercel 框架预设，默认自动检测
    VERCEL_FRAMEWORK="${VERCEL_FRAMEWORK:-}"

    # --- 验证必需变量 ---
    local missing=()

    if [ -z "${GITHUB_REPO_NAME:-}" ]; then
        log_error "缺少 GITHUB_REPO_NAME（远端 GitHub 仓库名称）"
        log_error "  通过 --repo-name 参数 或 GITHUB_REPO_NAME 环境变量设置"
        missing+=("GITHUB_REPO_NAME")
    fi

    if [ -z "${GITHUB_TOKEN:-}" ] && ! command -v gh &>/dev/null; then
        log_error "缺少 GitHub 认证方式：请安装 gh CLI (brew install gh) 或设置 GITHUB_TOKEN"
        missing+=("GITHUB_TOKEN or gh CLI")
    fi

    if [ -z "${VERCEL_TOKEN:-}" ]; then
        log_error "缺少 VERCEL_TOKEN（Vercel API 访问令牌）"
        log_error "  创建令牌: https://vercel.com/account/tokens"
        missing+=("VERCEL_TOKEN")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "缺少 ${#missing[@]} 个必需参数，退出。"
        exit 1
    fi

    # --- 派生变量 ---
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        # 通过 API 获取当前 GitHub 用户名
        local gh_user
        gh_user=$(curl -sS -H "Authorization: token ${GITHUB_TOKEN}" \
            https://api.github.com/user 2>/dev/null | json_get - login)
        GITHUB_OWNER="${GITHUB_ORG:-$gh_user}"
    else
        # 使用 gh CLI
        GITHUB_OWNER="${GITHUB_ORG:-$(gh api user --jq .login 2>/dev/null)}"
    fi

    if [ -z "${GITHUB_OWNER:-}" ]; then
        log_error "无法确定 GitHub 用户名/组织名，请检查 GITHUB_TOKEN 或 gh 登录状态"
        exit 1
    fi

    GITHUB_REMOTE="git@github.com:${GITHUB_OWNER}/${GITHUB_REPO_NAME}.git"
    GITHUB_API_REPO="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO_NAME}"

    # --- Vercel API 基础配置 ---
    VERCEL_API_BASE="https://api.vercel.com"
    VERCEL_AUTH_HEADER="Authorization: Bearer ${VERCEL_TOKEN}"

    # Vercel Team ID 查询参数（如果设置了 team）
    if [ -n "${VERCEL_TEAM_ID:-}" ]; then
        VERCEL_TEAM_QUERY="?teamId=${VERCEL_TEAM_ID}"
    else
        VERCEL_TEAM_QUERY=""
    fi

    # --- 显示配置摘要 ---
    log_info "项目目录:     ${PROJECT_DIR}"
    log_info "GitHub 仓库:  ${GITHUB_OWNER}/${GITHUB_REPO_NAME}"
    log_info "GitHub 远端:  ${GITHUB_REMOTE}"
    log_info "Vercel Team:  ${VERCEL_TEAM_ID:-未设置（使用个人账户）}"
    log_info "框架预设:    ${VERCEL_FRAMEWORK:-自动检测}"
    echo ""

    # --- 检查项目目录 ---
    if [ ! -d "$PROJECT_DIR" ]; then
        log_error "项目目录不存在: $PROJECT_DIR"
        exit 1
    fi

    # --- 检查 git 仓库 ---
    if ! git -C "$PROJECT_DIR" rev-parse --git-dir &>/dev/null; then
        log_warn "项目目录不是 git 仓库，正在初始化..."
        git -C "$PROJECT_DIR" init
        git -C "$PROJECT_DIR" add -A
        git -C "$PROJECT_DIR" commit -m "Initial commit — AI generated game project" \
            --allow-empty
        log_success "Git 仓库初始化完成"
    fi

    # --- 检查 gh CLI（如果提供 token 则不需要） ---
    local use_gh=false
    if [ -z "${GITHUB_TOKEN:-}" ]; then
        check_command gh "brew install gh && gh auth login" || exit 1
        use_gh=true
    fi

    # --- 检查 curl ---
    check_command curl || exit 1

    log_success "前置检查全部通过 ✓"
    echo ""
}

# ---------------------------------------------------------------------------
# 1. 创建 GitHub 远端仓库（如果不存在）
# ---------------------------------------------------------------------------
create_github_repo_if_needed() {
    log_separator
    log_info "Step 1: 检查/创建 GitHub 远端仓库"
    log_separator

    local repo_exists=false

    # 检查仓库是否已存在
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        # 方式 A：通过 GitHub REST API
        local http_code
        http_code=$(curl -sS -o /dev/null -w "%{http_code}" \
            -H "Authorization: token ${GITHUB_TOKEN}" \
            "$GITHUB_API_REPO" 2>/dev/null || echo "000")
        if [ "$http_code" = "200" ]; then
            repo_exists=true
        elif [ "$http_code" = "404" ]; then
            repo_exists=false
        else
            log_warn "GitHub API 返回 HTTP $http_code，假定仓库不存在"
            repo_exists=false
        fi
    else
        # 方式 B：通过 gh CLI
        if gh repo view "${GITHUB_OWNER}/${GITHUB_REPO_NAME}" &>/dev/null; then
            repo_exists=true
        else
            repo_exists=false
        fi
    fi

    if $repo_exists; then
        log_success "GitHub 远端仓库已存在: ${GITHUB_OWNER}/${GITHUB_REPO_NAME}"
        echo ""
        return 0
    fi

    # --- 仓库不存在，创建 ---
    log_info "GitHub 远端仓库不存在，正在创建..."

    if [ -n "${GITHUB_TOKEN:-}" ]; then
        # 方式 A：通过 GitHub REST API
        local create_payload
        local create_resp

        # 构造创建仓库的 JSON 请求体
        create_payload=$(cat <<EOF
{
  "name": "${GITHUB_REPO_NAME}",
  "private": false,
  "auto_init": false,
  "description": "AI-generated game project — deployed via Vercel"
}
EOF
        )

        create_resp=$(curl -sS -X POST \
            -H "Authorization: token ${GITHUB_TOKEN}" \
            -H "Content-Type: application/json" \
            -H "Accept: application/vnd.github.v3+json" \
            -d "$create_payload" \
            "https://api.github.com/user/repos" 2>&1)

        local created_name
        created_name=$(json_get "$create_resp" "full_name")

        if [ -z "$created_name" ]; then
            log_error "创建 GitHub 仓库失败。API 响应："
            echo "$create_resp" | head -5
            exit 1
        fi

        log_success "GitHub 仓库创建成功: $created_name"
    else
        # 方式 B：通过 gh CLI
        gh repo create "${GITHUB_OWNER}/${GITHUB_REPO_NAME}" \
            --public \
            --description "AI-generated game project — deployed via Vercel" \
            --source "$PROJECT_DIR" \
            --remote origin 2>/dev/null || {
            log_error "通过 gh CLI 创建仓库失败"
            exit 1
        }
        log_success "GitHub 仓库创建成功 (via gh CLI): ${GITHUB_OWNER}/${GITHUB_REPO_NAME}"
    fi

    echo ""
}

# ---------------------------------------------------------------------------
# 2. 配置 git remote 并推送代码
# ---------------------------------------------------------------------------
setup_git_remote() {
    log_separator
    log_info "Step 2: 配置 git remote 并推送代码"
    log_separator

    cd "$PROJECT_DIR"

    # 检查 remote 是否已配置
    local existing_url
    existing_url=$(git remote get-url origin 2>/dev/null || echo "")

    if [ -n "$existing_url" ]; then
        # 已有 remote，检查是否指向正确的仓库
        if echo "$existing_url" | grep -q "${GITHUB_OWNER}/${GITHUB_REPO_NAME}"; then
            log_success "origin remote 已正确配置: $existing_url"
        else
            log_warn "origin remote 指向 $existing_url"
            log_warn "正在更新为: $GITHUB_REMOTE"
            git remote set-url origin "$GITHUB_REMOTE"
            log_success "origin remote 已更新"
        fi
    else
        log_info "添加 origin remote: $GITHUB_REMOTE"
        git remote add origin "$GITHUB_REMOTE"
        log_success "origin remote 已添加"
    fi

    # 推送代码
    log_info "推送代码到远端..."
    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")

    # 如果分支名不是 main/master，先重命名
    if [ "$current_branch" != "main" ] && [ "$current_branch" != "master" ]; then
        git branch -M main
        current_branch="main"
    fi

    if git push -u origin "$current_branch" 2>&1; then
        log_success "代码推送成功 → ${GITHUB_OWNER}/${GITHUB_REPO_NAME} (branch: $current_branch)"
    else
        log_warn "推送失败，可能是远端已有内容。尝试 force push...注意：这只应在新项目上使用！"
        log_warn "如果你确定要继续（仅限新项目），取消注释下面的命令"
        # git push -u origin "$current_branch" --force
        log_error "推送失败，请手动处理 git push"
        # 不 exit，因为可能远端已有内容，用户已自行处理
    fi

    echo ""
}

# ---------------------------------------------------------------------------
# 3. 检查 Vercel 项目是否已绑定
# ---------------------------------------------------------------------------
check_vercel_project() {
    log_separator
    log_info "Step 3: 检查 Vercel 项目绑定状态"
    log_separator

    # 查询 Vercel 项目列表，按名称过滤
    local list_url="${VERCEL_API_BASE}/v9/projects${VERCEL_TEAM_QUERY}"
    # name 过滤参数
    if [[ "$list_url" == *"?"* ]]; then
        list_url="${list_url}&name=${GITHUB_REPO_NAME}"
    else
        list_url="${list_url}?name=${GITHUB_REPO_NAME}"
    fi

    local projects_resp
    projects_resp=$(curl -sS -H "$VERCEL_AUTH_HEADER" "$list_url" 2>/dev/null || echo "[]")

    # 在返回的项目列表中查找匹配名称的项目 ID
    local project_id
    if command -v jq &>/dev/null; then
        project_id=$(echo "$projects_resp" | \
            jq -r ".[] | select(.name == \"${GITHUB_REPO_NAME}\") | .id // empty" 2>/dev/null | head -1)
    else
        # 降级：用 grep 提取匹配项目名的 id
        project_id=$(echo "$projects_resp" | \
            grep -o "\"name\":\"${GITHUB_REPO_NAME}\"[^}]*\"id\":\"[^\"]*\"" | \
            head -1 | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"//' || true)
    fi

    if [ -n "$project_id" ]; then
        VERCEL_PROJECT_ID="$project_id"
        log_success "Vercel 项目已存在: ${GITHUB_REPO_NAME} (id: $VERCEL_PROJECT_ID)"
        return 0  # 已绑定
    else
        VERCEL_PROJECT_ID=""
        log_info "Vercel 项目未绑定: ${GITHUB_REPO_NAME}"
        return 1  # 未绑定
    fi
}

# ---------------------------------------------------------------------------
# 4. 创建 Vercel 项目并绑定 GitHub 仓库
# ---------------------------------------------------------------------------
create_and_bind_vercel_project() {
    log_separator
    log_info "Step 4: 创建 Vercel 项目并绑定 GitHub 仓库"
    log_separator

    # --- 自动检测框架 ---
    local framework="${VERCEL_FRAMEWORK}"
    if [ -z "$framework" ]; then
        framework=$(detect_framework)
    fi
    log_info "框架预设: $framework"

    # --- 构建目录与输出目录检测 ---
    local build_dir
    local output_dir
    build_dir=$(detect_build_dir)
    output_dir=$(detect_output_dir)
    log_info "构建目录: ${build_dir:-未检测到}"
    log_info "输出目录: ${output_dir:-未检测到}"

    # --- 安装命令检测 ---
    local install_cmd
    install_cmd=$(detect_install_command)
    log_info "安装命令: ${install_cmd:-默认}"

    # --- 构造创建项目的 API 请求 ---
    # API 文档: https://vercel.com/docs/rest-api/endpoints/projects#create-a-project
    local create_url="${VERCEL_API_BASE}/v9/projects${VERCEL_TEAM_QUERY}"

    # 构造 JSON 请求体
    # Vercel 创建项目时可以直接绑定 git 仓库
    local payload
    payload=$(cat <<EOF
{
  "name": "${GITHUB_REPO_NAME}",
  "framework": "${framework}",
  "gitRepository": {
    "type": "github",
    "repo": "${GITHUB_OWNER}/${GITHUB_REPO_NAME}"
  }
}
EOF
    )

    # 添加可选字段（仅在检测到值时）
    # 注意：这里用 jq 合并，如果没有 jq 则跳过可选字段
    if command -v jq &>/dev/null; then
        local extra_fields="{}"
        [ -n "$build_dir" ] && extra_fields=$(echo "$extra_fields" | jq ".buildCommand = \"$build_dir\"")
        [ -n "$output_dir" ] && extra_fields=$(echo "$extra_fields" | jq ".outputDirectory = \"$output_dir\"")
        [ -n "$install_cmd" ] && extra_fields=$(echo "$extra_fields" | jq ".installCommand = \"$install_cmd\"")
        payload=$(echo "$payload" | jq ". + $extra_fields")
    fi

    log_info "正在创建 Vercel 项目..."
    local create_resp
    create_resp=$(curl -sS -X POST \
        -H "$VERCEL_AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$create_url" 2>&1)

    # 检查响应
    local created_name
    local created_id
    local err_msg
    if command -v jq &>/dev/null; then
        created_name=$(echo "$create_resp" | jq -r '.name // empty' 2>/dev/null || true)
        created_id=$(echo "$create_resp" | jq -r '.id // empty' 2>/dev/null || true)
        err_msg=$(echo "$create_resp" | jq -r '.error.message // empty' 2>/dev/null || true)
    else
        created_name=$(json_get "$create_resp" "name")
        created_id=$(json_get "$create_resp" "id")
        err_msg=$(json_get "$create_resp" "message" 2>/dev/null || true)
    fi

    if [ -n "$created_name" ] && [ -n "$created_id" ]; then
        VERCEL_PROJECT_ID="$created_id"
        log_success "Vercel 项目创建成功: $created_name (id: $VERCEL_PROJECT_ID)"
    elif echo "$create_resp" | grep -q "already exists\|conflict\|PROJECT_NAME_TAKEN\|duplicate"; then
        log_warn "Vercel 项目名称已存在，尝试重新查询..."
        # 重新查询获取 ID
        if check_vercel_project; then
            log_success "找到已存在的 Vercel 项目: $VERCEL_PROJECT_ID"
        else
            log_warn "项目存在但查询失败，Vercel API 可能已自动绑定"
        fi
    else
        log_error "创建 Vercel 项目失败。API 响应："
        echo "$create_resp" | head -10
        log_error ""
        log_error "可能的原因："
        log_error "  1. VERCEL_TOKEN 无效或已过期"
        log_error "  2. 项目名称已被占用且不属于当前账户"
        log_error "  3. VERCEL_TEAM_ID 不正确"
        log_error "  4. GitHub 仓库权限不足（需要在 GitHub 上安装 Vercel App）"
        exit 1
    fi

    echo ""
}

# ---------------------------------------------------------------------------
# 4b. 为已有 Vercel 项目更新 Git 绑定（如果项目存在但未绑定 git）
# ---------------------------------------------------------------------------
update_git_binding_if_needed() {
    log_separator
    log_info "Step 4b: 检查并更新 Git 绑定"
    log_separator

    if [ -z "${VERCEL_PROJECT_ID:-}" ]; then
        log_error "VERCEL_PROJECT_ID 为空，无法检查绑定"
        return 1
    fi

    # 获取项目详情
    local detail_url="${VERCEL_API_BASE}/v9/projects/${VERCEL_PROJECT_ID}${VERCEL_TEAM_QUERY}"
    local detail_resp
    detail_resp=$(curl -sS -H "$VERCEL_AUTH_HEADER" "$detail_url" 2>/dev/null || echo "{}")

    local linked_repo
    if command -v jq &>/dev/null; then
        linked_repo=$(echo "$detail_resp" | jq -r '.link.repo // .gitRepository.repo // empty' 2>/dev/null || true)
    else
        linked_repo=$(json_get "$detail_resp" "repo" 2>/dev/null || true)
    fi

    if [ -n "$linked_repo" ]; then
        log_success "Vercel 项目已绑定 Git 仓库: $linked_repo"
        if echo "$linked_repo" | grep -q "${GITHUB_OWNER}/${GITHUB_REPO_NAME}"; then
            log_success "绑定仓库与目标一致，无需更新 ✓"
            return 0
        else
            log_warn "绑定仓库与目标不一致: $linked_repo != ${GITHUB_OWNER}/${GITHUB_REPO_NAME}"
            log_info "将通过更新 API 修正绑定..."
        fi
    else
        log_info "Vercel 项目未绑定 Git 仓库，正在绑定..."
    fi

    # 更新项目的 Git 仓库绑定
    # API: PATCH /v9/projects/:id
    local update_url="${VERCEL_API_BASE}/v9/projects/${VERCEL_PROJECT_ID}${VERCEL_TEAM_QUERY}"
    local update_payload
    update_payload=$(cat <<EOF
{
  "gitRepository": {
    "type": "github",
    "repo": "${GITHUB_OWNER}/${GITHUB_REPO_NAME}"
  }
}
EOF
    )

    local update_resp
    update_resp=$(curl -sS -X PATCH \
        -H "$VERCEL_AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d "$update_payload" \
        "$update_url" 2>&1)

    local updated_repo
    if command -v jq &>/dev/null; then
        updated_repo=$(echo "$update_resp" | jq -r '.gitRepository.repo // .link.repo // empty' 2>/dev/null || true)
    else
        updated_repo=$(json_get "$update_resp" "repo" 2>/dev/null || true)
    fi

    if [ -n "$updated_repo" ]; then
        log_success "Git 绑定更新成功: $updated_repo"
    else
        log_warn "Git 绑定可能未生效，请手动在 Vercel Dashboard 中检查"
        log_warn "Dashboard: https://vercel.com/dashboard"
    fi

    echo ""
}

# ---------------------------------------------------------------------------
# 5. 触发首次部署（可选）
# ---------------------------------------------------------------------------
trigger_deploy() {
    log_separator
    log_info "Step 5: 触发部署"
    log_separator

    # Vercel 绑定 GitHub 后，推送代码会自动触发部署
    # 但这里我们也可以通过 API 手动触发一次

    # 检查是否已经通过 git push 自动触发了部署
    if [ -n "${VERCEL_PROJECT_ID:-}" ]; then
        local deployments_url="${VERCEL_API_BASE}/v6/deployments${VERCEL_TEAM_QUERY}"
        if [[ "$deployments_url" == *"?"* ]]; then
            deployments_url="${deployments_url}&projectId=${VERCEL_PROJECT_ID}&limit=1"
        else
            deployments_url="${deployments_url}?projectId=${VERCEL_PROJECT_ID}&limit=1"
        fi

        local deploys_resp
        deploys_resp=$(curl -sS -H "$VERCEL_AUTH_HEADER" "$deployments_url" 2>/dev/null || echo "[]")

        local latest_state
        if command -v jq &>/dev/null; then
            latest_state=$(echo "$deploys_resp" | jq -r '.deployments[0].state // empty' 2>/dev/null || true)
            local latest_url
            latest_url=$(echo "$deploys_resp" | jq -r '.deployments[0].inspectorUrl // empty' 2>/dev/null || true)
        fi

        if [ "${latest_state:-}" = "READY" ]; then
            log_success "最新部署已完成且就绪 (state: READY)"
        elif [ "${latest_state:-}" = "BUILDING" ] || [ "${latest_state:-}" = "QUEUED" ]; then
            log_success "部署正在进行中 (state: ${latest_state})"
        else
            log_info "未检测到活动部署，Git push 应该会自动触发"
            log_info "你也可以在 Vercel Dashboard 中手动触发"
        fi
    fi

    log_info "Vercel Dashboard: https://vercel.com/dashboard"
    log_info "项目 URL:     https://${GITHUB_REPO_NAME}.vercel.app"
    echo ""
}

# ---------------------------------------------------------------------------
# 辅助：自动检测项目框架
# ---------------------------------------------------------------------------
detect_framework() {
    cd "$PROJECT_DIR"

    # 按优先级检测常见框架
    if [ -f "next.config.js" ] || [ -f "next.config.ts" ] || [ -f "next.config.mjs" ]; then
        echo "nextjs"
    elif [ -f "nuxt.config.js" ] || [ -f "nuxt.config.ts" ]; then
        echo "nuxtjs"
    elif [ -f "svelte.config.js" ]; then
        echo "sveltekit"
    elif [ -f "remix.config.js" ] || [ -f "remix.config.ts" ]; then
        echo "remix"
    elif [ -f "astro.config.mjs" ] || [ -f "astro.config.ts" ]; then
        echo "astro"
    elif [ -f "gatsby-config.js" ] || [ -f "gatsby-config.ts" ]; then
        echo "gatsby"
    elif [ -f "vue.config.js" ] || [ -f "vite.config.ts" ] && grep -q '"vue"' package.json 2>/dev/null; then
        echo "vue"
    elif [ -f "vite.config.ts" ] || [ -f "vite.config.js" ]; then
        # 检查是不是 React
        if grep -q '"react"' package.json 2>/dev/null; then
            echo "vite"
        else
            echo "vite"
        fi
    elif [ -f "angular.json" ]; then
        echo "angular"
    elif [ -f "package.json" ]; then
        # 降级：根据 package.json 中的依赖判断
        if grep -q '"next"' package.json 2>/dev/null; then
            echo "nextjs"
        elif grep -q '"react"' package.json 2>/dev/null; then
            echo "create-react-app"
        else
            echo "other"
        fi
    elif [ -f "index.html" ]; then
        echo "static"
    else
        echo "other"
    fi
}

# ---------------------------------------------------------------------------
# 辅助：检测构建命令
# ---------------------------------------------------------------------------
detect_build_dir() {
    cd "$PROJECT_DIR"

    if [ -f "package.json" ]; then
        if grep -q '"build"' package.json 2>/dev/null; then
            # 返回空让 Vercel 自动检测
            echo ""
        elif grep -q '"react-scripts"' package.json 2>/dev/null; then
            echo ""
        else
            echo ""
        fi
    else
        echo ""
    fi
}

# ---------------------------------------------------------------------------
# 辅助：检测输出目录
# ---------------------------------------------------------------------------
detect_output_dir() {
    cd "$PROJECT_DIR"

    if [ -f "next.config.js" ] || [ -f "next.config.ts" ]; then
        echo ".next"
    elif [ -f "nuxt.config.js" ]; then
        echo ".output"
    elif grep -q '"react-scripts"' package.json 2>/dev/null; then
        echo "build"
    elif [ -f "vite.config.ts" ] || [ -f "vite.config.js" ]; then
        echo "dist"
    else
        # 让 Vercel 自动检测
        echo ""
    fi
}

# ---------------------------------------------------------------------------
# 辅助：检测安装命令
# ---------------------------------------------------------------------------
detect_install_command() {
    cd "$PROJECT_DIR"

    if [ -f "pnpm-lock.yaml" ]; then
        echo "pnpm install"
    elif [ -f "yarn.lock" ]; then
        echo "yarn install"
    elif [ -f "bun.lockb" ]; then
        echo "bun install"
    elif [ -f "package-lock.json" ]; then
        echo "npm install"
    else
        echo ""
    fi
}

# ---------------------------------------------------------------------------
# 6. 打印部署摘要
# ---------------------------------------------------------------------------
print_summary() {
    log_separator
    echo ""
    echo -e "  ${_BOLD}${_GREEN}✓ 部署流程完成${_RESET}"
    echo ""
    echo -e "  ${_BOLD}GitHub:${_RESET}  https://github.com/${GITHUB_OWNER}/${GITHUB_REPO_NAME}"
    echo -e "  ${_BOLD}Vercel:${_RESET}   https://vercel.com/dashboard"
    echo -e "  ${_BOLD}预览:${_RESET}    https://${GITHUB_REPO_NAME}.vercel.app"
    echo ""
    log_separator
}

# =============================================================================
# 主流程
# =============================================================================
main() {
    parse_args "$@"

    echo ""
    log_info "╔══════════════════════════════════════════════════════════╗"
    log_info "║   deploy-to-vercel.sh — GitHub + Vercel 自动部署工具   ║"
    log_info "╚══════════════════════════════════════════════════════════╝"
    echo ""

    # Step 0: 前置检查
    preflight_check

    # Step 1: 创建 GitHub 仓库（如不存在）
    create_github_repo_if_needed

    # Step 2: 配置 git remote 并推送
    setup_git_remote

    # Step 3: 检查 Vercel 项目是否已绑定
    if check_vercel_project; then
        # 项目已存在，检查 git 绑定是否需要更新
        update_git_binding_if_needed
    else
        # Step 4: 创建 Vercel 项目并绑定 GitHub
        create_and_bind_vercel_project
        # Step 4b: 确认绑定状态
        update_git_binding_if_needed
    fi

    # Step 5: 触发部署
    trigger_deploy

    # Step 6: 打印摘要
    print_summary
}

# 如果直接运行此脚本（而非被 source），则执行 main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
