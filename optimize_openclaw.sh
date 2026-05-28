#!/bin/bash
# ============================================================
# 远山boss OpenClaw Token 优化维护脚本 v2.1
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
# 1. 清理旧会话文件（保留当前活跃会话，使用 find -print0 防止文件名含特殊字符）
# ============================================================
log "[1/4] 清理历史会话..."
for agent_dir in "$AGENTS_DIR"/*/; do
    [ -d "$agent_dir" ] || continue
    agent_id=$(basename "$agent_dir")
    session_dir="$agent_dir/sessions"
    session_file="$session_dir/sessions.json"

    [[ -f "$session_file" ]] || { log "  跳过 $agent_id（无会话）"; continue; }

    # 读取当前会话 key
    current_key=""
    if command -v python3 &>/dev/null; then
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
    sdir = '$session_dir'
    best = None
    best_mtime = 0
    for fname in os.listdir(sdir):
        if fname.endswith('.jsonl') and not fname.endswith('.reset'):
            fpath = os.path.join(sdir, fname)
            mtime = os.path.getmtime(fpath)
            if mtime > best_mtime:
                best_mtime = mtime
                best = fname[:-6]  # remove .jsonl
    cur = best or ''
print(cur)
" 2>/dev/null || echo "")
    fi

    log "  代理: $agent_id  当前: ${current_key:-(无)}"

    # 使用 find -print0 + while read -d '' 处理含特殊字符的文件名
    while IFS= read -r -d '' f; do
        base=$(basename "$f")
        session_id=$(echo "$base" | sed -n 's/^\([a-f0-9-]\{36\}\).*/\1/p')
        [[ -z "$session_id" ]] && continue
        [[ "$session_id" == "$current_key" ]] && continue
        run "rm -f '${f}'"
    done < <(find "$session_dir" -maxdepth 1 -type f \
        \( -name "*.jsonl" -o -name "*.trajectory.jsonl" -o -name "*.trajectory-path.json" \) \
        2>/dev/null -print0)

    # 清理 .reset 文件
    while IFS= read -r -d '' f; do
        run "rm -f '${f}'"
    done < <(find "$session_dir" -maxdepth 1 -type f -name "*.reset*" 2>/dev/null -print0)

    log "  已完成 $agent_id"
done

# ============================================================
# 2. 精简 AGENTS.md（保护团队定制内容）
# ============================================================
log "[2/4] 精简 AGENTS.md..."
agents_md="$WORKSPACE_DIR/AGENTS.md"

if [[ -f "$agents_md" ]]; then
    size=$(wc -c < "$agents_md")
    # 只精简超过5KB的文件，且不覆盖团队定制的AGENTS.md（含有"团队协作"标记）
    if [[ "$size" -gt 5000 ]] && ! grep -q "团队架构\|团队协作协议" "$agents_md" 2>/dev/null; then
        log "  当前: ${size}B → 精简"
        cat > /tmp/optimized_agents.md << 'EOF'
# AGENTS.md

## Session Startup
Use runtime-provided startup context first (AGENTS.md / SOUL.md / USER.md / MEMORY.md / daily memories).
Do NOT re-read startup files unless explicitly asked or context is missing.

## Memory
- **Daily notes:** `memory/YYYY-MM-DD.md` — raw session logs
- **Long-term:** `MEMORY.md` — curated wisdom, updated periodically

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
- Use cron for precise timing / isolated tasks.
EOF
        new_size=$(wc -c < /tmp/optimized_agents.md)
        log "  优化后: ${new_size}B（节省 $((size - new_size))B）"
        if ! $DRY_RUN; then
            mv /tmp/optimized_agents.md "$agents_md"
            log "  ✅ AGENTS.md 已精简"
        else
            rm /tmp/optimized_agents.md
        fi
    else
        log "  当前: ${size}B（已在合理范围或为团队定制版，跳过）"
    fi
fi

# ============================================================
# 3. 整理工作区大文件（使用进程替代避免子shell陷阱）
# ============================================================
log "[3/4] 整理工作区大文件..."
docs_dir="$WORKSPACE_DIR/docs"

total_moved=0
while IFS= read -r -d '' f; do
    base=$(basename "$f")
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
            total_moved=$((total_moved + 1))
        fi
    fi
done < <(find "$WORKSPACE_DIR" -maxdepth 1 -type f \( -name "*.md" -o -name "*.txt" \) -print0 2>/dev/null)

if $DRY_RUN; then
    log "  预览模式，不实际移动"
else
    log "  移动了 ${total_moved} 个文件到 docs/"
fi

# ============================================================
# 4. 保持 HEARTBEAT.md 干净（保护非注释任务内容）
# ============================================================
log "[4/4] 检查 HEARTBEAT.md..."
hb="$WORKSPACE_DIR/HEARTBEAT.md"
if [[ -f "$hb" ]]; then
    # 统计真正的内容行（非注释、非空行）
    code_lines=$(grep -c '^[^#[:space:]]' "$hb" 2>/dev/null || echo 0)
    if [[ "$code_lines" -gt 0 ]]; then
        # 检查是否含有任务指示
        if grep -qi 'cron\|task\|check\|remind\|heartbeat' <(grep '^[^#]' "$hb" 2>/dev/null); then
            log "  发现 $code_lines 行有效内容（含任务指示），保留"
        else
            log "  发现 $code_lines 行有效内容（非任务类）→ 重置"
            if ! $DRY_RUN; then
                cat > "$hb" << 'EOF'
# Keep this file empty (or with only comments) to skip heartbeat API calls.

# Add tasks below when you want the agent to check something periodically.
EOF
                log "  ✅ HEARTBEAT.md 已重置"
            fi
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
