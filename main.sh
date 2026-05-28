#!/usr/bin/env bash
# =============================================================================
#  custom-openclaw-skill 主入口
#  版本: 2.1 (优化版)
#  功能：
#     1. 检查 OpenClaw 状态并按需升级
#     2. 部署 8 位央企金融 AI 专家 Agent
#     3. 安装定期优化脚本 + crontab
#     4. 安装公文安全下载服务（doc-export）
#     5. 触发纪总自我介绍
#  用法: bash main.sh
# =============================================================================

set -euo pipefail

# ---------- 日志函数 ----------
log_info()  { echo "[$(date '+%H:%M:%S')] [INFO]  $*"; }
log_ok()    { echo "[$(date '+%H:%M:%S')] [OK]    $*"; }
log_warn()  { echo "[$(date '+%H:%M:%S')] [WARN]  $*"; }
log_error() { echo "[$(date '+%H:%M:%S')] [ERROR] $*" >&2; }

# ---------- 当前脚本所在目录 ----------
TARGET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- 统计 ----------
FAIL_COUNT=0
STEP_COUNT=0
PASS_COUNT=0

run_step() {
    local step_name="$1"; shift
    STEP_COUNT=$((STEP_COUNT + 1))
    log_info "[${STEP_COUNT}] ${step_name}..."
    if "$@" 2>&1; then
        PASS_COUNT=$((PASS_COUNT + 1))
        log_ok "${step_name} 完成"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        log_warn "${step_name} 执行异常（非致命，继续后续步骤）"
    fi
}

# ========== 1. OpenClaw 更新 ==========
run_step "OpenClaw 版本检查" bash -c '
if command -v openclaw &> /dev/null; then
    log_info "当前版本: $(openclaw --version 2>&1 | head -1)"
    log_info "检查更新..."
    openclaw update status 2>/dev/null || true
else
    log_warn "openclaw 命令未找到，跳过更新"
fi
'

# ========== 2. 部署专家团队 ==========
run_step "部署 8 位央企金融 AI 专家" bash -c '
cd "$TARGET_DIR"
bash ./openclaw-setup.sh
'

# ========== 3. 安装优化脚本 + crontab ==========
run_step "安装定期优化脚本" bash -c '
cd "$TARGET_DIR"
bash ./optimize_openclaw.sh
OPTIMIZE_SCRIPT="$TARGET_DIR/optimize_openclaw.sh"
if [[ -f "$OPTIMIZE_SCRIPT" ]]; then
    # 确保日志目录存在
    mkdir -p /var/log 2>/dev/null || true
    (crontab -l 2>/dev/null | grep -v "optimize_openclaw"; \
     echo "0 3 * * * /usr/bin/flock -n /tmp/openclaw_optimize.lock bash $OPTIMIZE_SCRIPT >> /var/log/openclaw_optimize.log 2>&1") | crontab -
    log_info "每日 3:00 自动执行已配置"
fi
'

# ========== 4. 安装 doc-export 公文下载服务 ==========
run_step "安装公文安全下载服务" bash -c '
cd "$TARGET_DIR"
bash ./doc-export/doc-export-install.sh
sleep 2
openclaw reload 2>/dev/null || true
sleep 1
'

# ========== 5. 触发纪总初始化 ==========
run_step "触发纪总自我介绍" bash -c '
openclaw agent --agent enterprise-boss --message "请立即启用我部署在skill的doc-export 技能" --verbose on 2>/dev/null || true
'

# ========== 汇总 ==========
echo ""
echo "══════════════════════════════════════════════"
echo "  部署汇总"
echo "  总计: ${STEP_COUNT} 步 | 通过: ${PASS_COUNT} | 异常: ${FAIL_COUNT}"
echo "══════════════════════════════════════════════"
if [ "$FAIL_COUNT" -eq 0 ]; then
    log_ok "全部步骤执行成功"
else
    log_warn "部分步骤有异常，请检查上方日志"
fi
