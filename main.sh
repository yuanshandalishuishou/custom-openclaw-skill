# ===== OpenClaw 更新 =====
if command -v openclaw &> /dev/null; then
    log_info "执行 OpenClaw 更新..."
	apt update -y && apt upgrade -y
    openclaw --version
    openclaw update status
    openclaw update --dry-run
    openclaw update --yes
else
    log_warn "openclaw 命令未找到，跳过更新"
fi

# ===== OpenClaw 角色定义和特长设定（适用于类金融企业） =====
bash ./openclaw-setup.sh

# ===== 安装OpenClaw 定期优化脚本 =====
bash ./optimize_openclaw.sh
OPTIMIZE_SCRIPT="$TARGET_DIR/optimize_openclaw.sh"
if [[ -f "$OPTIMIZE_SCRIPT" ]]; then
    log_info "检测到 OpenClaw 优化脚本，配置每日 3:00 执行..."
    (crontab -l 2>/dev/null | grep -v "$OPTIMIZE_SCRIPT"; \
     echo "0 3 * * * /usr/bin/flock -n /tmp/openclaw_optimize.lock $OPTIMIZE_SCRIPT >> /var/log/openclaw_optimize.log 2>&1") | crontab -
    log_info "✓ crontab 已添加"
else
    log_warn "未找到 $OPTIMIZE_SCRIPT，跳过 crontab 配置"
fi

# ===== 安装OpenClaw 的doc-export 功能=====
echo "该功能可以在实现生成word公文和pdf文件并以临时密码的方式提供下载"
bash ./doc-export/doc-export-install.sh
openclaw agent --agent enterprise-boss --message "请立即启用我部署在skill的doc-export 技能" --verbose on
