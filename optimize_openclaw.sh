#!/bin/bash
# ============================================================
# 远山boss OpenClaw Token 优化维护脚本
# 功能：清理历史会话、精简上下文文件、保持心跳最小化
# 用法：bash optimize_openclaw.sh              # 执行一次
#       bash optimize_openclaw.sh --dry-run    # 预览
# 定时：crontab -e 添加（推荐每6小时）：
#   0 */6 * * * /path/to/optimize_openclaw.sh
# ============================================================

set -euo pipefail
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

OPENCLAW_DIR="${OPENCLAW_DIR:-$HOME/.openclaw}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$OPENCLAW_DIR/workspace}"
AGENTS_DIR="$OPENCLAW_DIR/agents"

log()  { echo "[$(date '+%H:%M:%S')] $1"; }
run()  {
    if $DRY_RUN; then
        echo "  [预览] $1"
    else
        echo "  [执行] $1"
        eval "$1"
    fi
}

echo "============================================"
echo "远山boss OpenClaw Token 优化维护"
echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "模式: $($DRY_RUN && echo '预览' || echo '执行')"
echo "工作目录: $WORKSPACE_DIR"
echo "============================================"

# ============================================================
# 1. 清理旧会话文件（保留当前活跃会话）
# ============================================================
log "[1/4] 清理历史会话..."
for agent_dir in "$AGENTS_DIR"/*/; do
    agent_id=$(basename "$agent_dir")
    session_dir="$agent_dir/sessions"
    session_file="$session_dir/sessions.json"

    if [[ ! -f "$session_file" ]]; then
        log "  跳过 $agent_id（无会话）"
        continue
    fi

    # 读取当前会话 key，若为空则取 sessions.json 中最新的一条
    # 如果还是为空，则取 session_dir 中最新修改的 jsonl 文件
    current_key=$(python3 -c "
import json, os
with open('$session_file') as f:
    data = json.load(f)
cur = data.get('currentSession', '') or ''
if not cur:
    sessions = data.get('sessions', {})
    if sessions:
        cur = max(sessions.keys(), key=lambda k: sessions[k].get('updatedAt', ''))
if not cur:
    # 从文件系统找最新的 jsonl
    sdir = '$session_dir'
    best = None
    best_mtime = 0
    for fname in os.listdir(sdir):
        if fname.endswith('.jsonl') and not fname.endswith('.reset'):
            fpath = os.path.join(sdir, fname)
            mtime = os.path.getmtime(fpath)
            if mtime > best_mtime:
                best_mtime = mtime
                best = fname.rsplit('.',1)[0]
    cur = best or ''
print(cur)
" 2>/dev/null || echo "")

    log "  代理: $agent_id  当前: ${current_key:-(无)}"

    removed=0
    saved=0

    # 用 find 安全地查找会话文件
    find "$session_dir" -maxdepth 1 -type f \
        \( -name "*.jsonl" -o -name "*.trajectory.jsonl" -o -name "*.trajectory-path.json" \) 2>/dev/null | while read -r f; do
        base=$(basename "$f")
        session_id=$(echo "$base" | sed -n 's/^\([a-f0-9-]\{36\}\).*/\1/p')
        [[ -z "$session_id" ]] && continue

        if [[ "$session_id" == "$current_key" ]]; then
            :  # 保留
        else
            run "rm -f '$f'"
        fi
    done

    # 清理 .reset 文件
    find "$session_dir" -maxdepth 1 -type f -name "*.reset*" 2>/dev/null | while read -r f; do
        run "rm -f '$f'"
    done

    log "  已完成 $agent_id"
done

# ============================================================
# 2. 精简 AGENTS.md
# ============================================================
log "[2/4] 精简 AGENTS.md..."
agents_md="$WORKSPACE_DIR/AGENTS.md"

create_optimized_agents() {
    cat > "$1" << 'EOF'
# AGENTS.md

## Session Startup
Use runtime-provided startup context first (AGENTS.md / SOUL.md / USER.md / MEMORY.md / daily memories).
Do NOT re-read startup files unless explicitly asked or context is missing.

## Memory
- **Daily notes:** `memory/YYYY-MM-DD.md` — raw session logs
- **Long-term:** `MEMORY.md` — curated wisdom, updated periodically

### MEMORY.md Rules
- ONLY load in main session (direct chats). DO NOT load in shared/group contexts.
- Read, edit, update freely in main sessions.
- Write significant events, decisions, lessons learned.

### Write It Down
Memory doesn't survive restarts. Files do. When asked to "remember" → write to `memory/YYYY-MM-DD.md`.

## Red Lines
- Never exfiltrate private data.
- No destructive commands without asking.
- `trash` > `rm`. When in doubt, ask.

## External vs Internal
**Free:** Read files, explore, organize, learn, search the web, work in workspace.
**Ask first:** Emails, tweets, public posts, anything leaving the machine.

## Tools
Skills define tool usage. Local notes (SSH, camera, etc.) in `TOOLS.md`.

## Heartbeat
- `HEARTBEAT.md` empty → just reply `HEARTBEAT_OK`.
- If productive work needed, edit `HEARTBEAT.md` with a small checklist.
- Use cron for precise timing / isolated tasks. Batch periodic checks in heartbeat.
EOF
}

if [[ -f "$agents_md" ]]; then
    size=$(wc -c < "$agents_md")
    if [[ "$size" -gt 2000 ]]; then
        log "  当前: ${size}B → 精简"
        tmp=$(mktemp)
        create_optimized_agents "$tmp"
        new_size=$(wc -c < "$tmp")
        log "  优化后: ${new_size}B（节省 $((size - new_size))B）"
        if ! $DRY_RUN; then
            mv "$tmp" "$agents_md"
            log "  ✅ AGENTS.md 已精简"
        else
            rm "$tmp"
        fi
    else
        log "  当前: ${size}B（已在合理范围）"
    fi
fi

# ============================================================
# 3. 整理工作区大文件
# ============================================================
log "[3/4] 整理工作区大文件..."
docs_dir="$WORKSPACE_DIR/docs"

find "$WORKSPACE_DIR" -maxdepth 1 -type f \( -name "*.md" -o -name "*.txt" \) 2>/dev/null | while read -r f; do
    base=$(basename "$f")
    # 跳过核心系统文件
    case "$base" in
        AGENTS.md|SOUL.md|MEMORY.md|TOOLS.md|IDENTITY.md|USER.md|HEARTBEAT.md)
            continue ;;
    esac
    size=$(wc -c < "$f")
    if [[ "$size" -gt 10240 ]]; then
        log "  移动: $base (${size}B) → docs/"
        if ! $DRY_RUN; then
            mkdir -p "$docs_dir"
            mv "$f" "$docs_dir/"
        fi
    fi
done

# ============================================================
# 4. 保持 HEARTBEAT.md 干净
# ============================================================
log "[4/4] 保持 HEARTBEAT.md 干净..."
hb="$WORKSPACE_DIR/HEARTBEAT.md"
if [[ -f "$hb" ]]; then
    # 统计非注释行
    non_comment=$(grep -vc '^\s*$' "$hb" 2>/dev/null || echo 0)
    # 只算不是 # 开头的行
    code_lines=$(grep -c '^[^#[:space:]]' "$hb" 2>/dev/null || echo 0)
    if [[ "$code_lines" -gt 0 ]]; then
        log "  发现 $code_lines 行有效内容 → 重置"
        if ! $DRY_RUN; then
            cat > "$hb" << 'EOF'
# Keep this file empty (or with only comments) to skip heartbeat API calls.

# Add tasks below when you want the agent to check something periodically.
EOF
            log "  ✅ HEARTBEAT.md 已重置"
        fi
    else
        log "  已为最小状态"
    fi
fi

# ============================================================
# 汇总
# ============================================================
echo ""
echo "============================================"
if $DRY_RUN; then
    echo "✅ 预览完成。去掉 --dry-run 执行实际优化。"
else
    script_path=$(realpath "$0" 2>/dev/null || echo "$0")
    echo "✅ 优化完成！添加定时任务："
    echo "   crontab -e"
    echo "   0 */6 * * * $script_path"
fi
echo "============================================"
