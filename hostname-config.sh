#!/bin/bash

# 一键修改Debian主机名脚本
# 使用方法：sudo bash change_hostname.sh 新主机名

set -e

# 检查是否以root权限运行
if [ "$EUID" -ne 0 ]; then
    echo "请使用sudo或以root用户运行此脚本"
    exit 1
fi

# 检查参数
if [ $# -eq 0 ]; then
    echo "使用方法: sudo $0 新主机名"
    echo "例如: sudo $0 office-openclaw"
    exit 1
fi

NEW_HOSTNAME="$1"
OLD_HOSTNAME=$(hostname)

echo "正在将主机名从 '$OLD_HOSTNAME' 修改为 '$NEW_HOSTNAME'..."

# 1. 修改/etc/hostname文件
echo "$NEW_HOSTNAME" > /etc/hostname
echo "✓ 已更新 /etc/hostname 文件"

# 2. 修改/etc/hosts文件
if grep -q "127.0.1.1" /etc/hosts; then
    # 如果存在127.0.1.1行，则替换
    sed -i "s/127\.0\.1\.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts
else
    # 如果不存在，则添加
    echo -e "127.0.0.1\tlocalhost" >> /etc/hosts
    echo -e "127.0.1.1\t$NEW_HOSTNAME" >> /etc/hosts
fi
echo "✓ 已更新 /etc/hosts 文件"

# 3. 使用hostnamectl设置主机名
hostnamectl set-hostname "$NEW_HOSTNAME"
echo "✓ 已通过hostnamectl设置主机名"

# 4. 重启hostnamed服务
systemctl restart systemd-hostnamed
echo "✓ 已重启systemd-hostnamed服务"

echo ""
echo "主机名修改完成！"
echo "当前主机名: $(hostname)"
echo ""
echo "注意：某些应用程序可能需要重启才能完全识别新主机名。"
echo "建议重启系统以确保所有服务都使用新主机名。"
echo "重启命令: sudo reboot"
