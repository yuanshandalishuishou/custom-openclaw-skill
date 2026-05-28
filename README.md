# custom-openclaw-skill

**央企金融 AI 专家团队 — OpenClaw 一键部署 & 公文安全下载服务**

本项目在 [OpenClaw](https://openclaw.ai) 平台上，一键部署 **8 位央企金融 AI 专家 Agent**（含总协调人），
并附带 **GB/T 9704-2012 国标公文安全下载服务**（Word/PDF 生成 + 一次性安全链接）。

> 适用场景：央企分管领导（纪检、工会、信息化、合规、审计、财务）的数字化决策辅助。

---

## 目录

- [项目架构](#项目架构)
- [团队组成](#团队组成)
- [快速开始](#快速开始)
- [文件清单](#文件清单)
- [部署流程详解](#部署流程详解)
- [公文下载服务](#公文下载服务-doc-export)
  - [安装配置](#安装配置)
  - [API 接口文档](#api-接口文档)
  - [环境变量覆盖](#环境变量覆盖)
- [优化维护脚本](#优化维护脚本-optimize_openclawsh)
- [主机名配置](#主机名配置-hostname_configsh)
- [常见问题](#常见问题)
- [版本历史](#版本历史)

---

## 项目架构

```
┌──────────────────────────────────────────────────────┐
│                   远山总（用户）                       │
└──────────┬───────────────────────────────────────────┘
           │ 指令
           ▼
┌──────────────────────┐     ┌──────────────────────┐
│     纪总（总协调人）      │────▶│  openclaw reload     │
│   enterprise-boss     │     │  (技能加载)          │
└────┬──────┬──────┬────┘     └──────────────────────┘
     │      │      │
     ▼      ▼      ▼
┌─────────┐┌─────────┐┌──────────────┐
│ 业务线  ││ 技术线  ││ 政治与文书保障 │
│ 纪融    ││ 纪枢    ││ 纪棠          │
│ 纪衡    ││ 纪码    ││ (党工纪+公文)  │
│ 纪正    ││ 纪测    ││              │
└─────────┘└─────────┘└──────────────┘
                    │
                    ▼
         ┌──────────────────┐
         │ doc-export 服务  │
         │ (公文下载/安全链接)│
         └──────────────────┘
```

### 调用链路

```
main.sh
 ├── openclaw-setup.sh        → 创建/更新 8 个 Agent，写入 SOUL/MEMORY/IDENTITY
 ├── optimize_openclaw.sh     → 清理历史会话，配置每日 3:00 自动优化
 ├── doc-export-install.sh    → 安装公文安全下载服务（Python FastAPI）
 └── openclaw reload + 触发   → 加载 doc-export 技能，纪总自我介绍
```

---

## 团队组成

| 代号 | Agent ID | 角色 | 专长 |
|------|----------|------|------|
| 🎯 **纪总** | `enterprise-boss` | **总协调人** | 任务分派、结果整合、跨专家协调、公文把关 |
| 🏦 **纪融** | `financial-expert` | 金融业务专家 | 资产证券化、融资租赁、商业保理、股权投资、外汇 |
| ⚖️ **纪正** | `compliance-expert` | 合规专家 | 合规审查、制度建设、案件协查、法律咨询 |
| 🌿✍️ **纪棠** | `party-labor-discipline` | 党工纪与文书专家 | 党务、工会、纪检全流程、公文写作、中英翻译 |
| 📊 **纪衡** | `tax-expert` | 财税专家 | 会计核算、税务筹划、财务分析、国资委快报 |
| 🏗️ **纪枢** | `architect-expert` | 软件架构专家 | 信创架构、安全设计、两地三中心容灾、技术选型 |
| 💻 **纪码** | `dev-expert` | 软件开发专家 | 核心编码（Java/Go/Python）、代码审查、技术攻关 |
| 🐛 **纪测** | `qa-expert` | 软件测试专家 | 测试策略、自动化测试、性能压测、安全渗透测试 |

### 协作规则

1. **远山总的指令统一由纪总接收、解析、分派**，各专家不直接接收用户指令
2. 纪总使用 `sessions_spawn` 分派子任务，使用 `sessions_yield` 等待结果
3. 多专家并行任务可同时 spawn，统一 yield 后整合
4. **正式公文必须先经纪棠（party-labor-discipline）政治与文字润色**，方可呈报远山总
5. 内部技术讨论、非正式建议文本可由纪总直接输出

---

## 快速开始

### 前置条件

- **操作系统：** Debian 13 / Ubuntu 20.04+ / CentOS 8+
- **已安装：** [OpenClaw](https://openclaw.ai)（已启动运行）
- **依赖：** `bash`、`python3`、`pip3`、`git`

### 一键部署

```bash
# 克隆仓库
git clone https://github.com/yuanshandalishuishou/custom-openclaw-skill.git
cd custom-openclaw-skill

# 执行主安装脚本
bash main.sh
```

### 分步执行

如不想全部执行，也可分步运行：

```bash
# 第1步：部署 8 位专家 Agent
bash openclaw-setup.sh

# 第2步：安装优化脚本（含 crontab）
bash optimize_openclaw.sh

# 第3步：安装公文下载服务（交互式，需填写配置）
bash doc-export/doc-export-install.sh

# 第4步：加载技能 & 触发初始化
openclaw reload
openclaw agent --agent enterprise-boss --message "请做个自我介绍"
```

---

## 文件清单

| 文件 | 说明 |
|------|------|
| **`main.sh`** | 主入口脚本。依次执行：OpenClaw 版本检查 → Agent 部署 → 优化脚本 → 公文服务 → 纪总初始化。内置 `run_step` 错误隔离，单步失败不影响后续 |
| **`openclaw-setup.sh`** | 一键创建/更新 8 个 Agent。为每个 Agent 写入 SOUL.md（角色身份）、MEMORY.md（知识储备）、IDENTITY.md（人格设定）、TOOLS.md（工具声明）、AGENTS.md（协作协议） |
| **`optimize_openclaw.sh`** | Token 优化维护脚本。清理历史会话文件、精简 AGENTS.md、整理 workspace 大文件、重置 HEARTBEAT.md。支持 `--dry-run` 预览模式 |
| **`hostname-config.sh`** | Debian 系统主机名一键修改脚本。需要 root 权限 |
| **`README.md`** | 本文件 |
| **`doc-export/`** | 公文安全下载服务子目录 |
| **`doc-export/doc-export-install.sh`** | 公文服务安装脚本（v2.3 修正增强版）。交互式收集配置，安装 Python 依赖、中文字体、systemd 服务 |
| **`doc-export/下达的指令.txt`** | 需求说明书（原始需求文档） |

---

## 部署流程详解

### main.sh 执行流程

```
Step 1: OpenClaw 版本检查
  → 检测 openclaw 命令是否存在
  → 显示当前版本
  → 检查更新状态（不自动升级系统包）

Step 2: 部署 8 位专家 Agent
  → 调用 openclaw-setup.sh

Step 3: 安装优化脚本
  → 调用 optimize_openclaw.sh
  → 配置 crontab（每日 3:00 自动执行）

Step 4: 安装公文下载服务
  → 调用 doc-export/doc-export-install.sh
  → openclaw reload（加载新技能）

Step 5: 触发纪总初始化
  → 向 enterprise-boss 发送启用指令
```

> **注意：** 第4步 doc-export-install.sh 包含交互式输入（端口、IP、目录等），非交互环境会自动使用默认值。

---

## 公文下载服务 (doc-export)

符合 **GB/T 9704-2012《党政机关公文格式》** 的公文生成与安全下载服务。

### 功能特性

- ✅ **国标版式：** A4 纸张、页边距上3.7/下3.5/左2.8/右2.6cm、三号仿宋、首行缩进2字符、固定行距28磅
- ✅ **红头支持：** 自动嵌入透明 PNG 红头图片，无图片时自动使用文字替代
- ✅ **字体智能检测：** 自动检测系统可用中文字体，按优先级回退（`仿宋_GB2312`→`FangSong`→`仿宋`→`SimSun`→`宋体`）
- ✅ **结构化内容：** 支持多级标题、表格、附件列表、发文字号、主送机关、落款
- ✅ **安全下载：** 一次性 Token + 6 位数字密码分离，密码错误 ≥3 次自动作废
- ✅ **双格式：** Word (.docx) + PDF（需 LibreOffice）
- ✅ **自动清理：** 守护线程每 60 秒扫描一次过期文件
- ✅ **环境变量覆盖：** 关键配置可通过环境变量注入（适合容器化部署）

### 安装配置

运行安装脚本后，会依次交互式收集：

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| 监听端口 | `10091` | 服务 HTTP 端口（1-65535，含冲突检测） |
| 内网 IP | `192.168.31.101` | 内网下载链接基址（IPv4 格式校验） |
| 外网 IP | `81.68.248.64` | 外网下载链接基址（IPv4 格式校验） |
| 文件保存目录 | `/opt/lobster_docs` | 生成的公文文件存盘路径 |
| 发文机关全称 | `××市人民政府办公室` | 公文落款/红头文字回退用的机关名称 |
| 中文字体 | 可选安装 | WQY 文泉驿 / Noto CJK / Windows 字体拷贝 |
| systemd 服务 | 可选安装 | 开机自启支持 |

### API 接口文档

服务启动后提供以下 HTTP 接口：

#### `GET /ping`

健康检查。

**响应：**
```json
{"ok": true}
```

#### `GET /health`

详细健康状态。

**响应：**
```json
{
  "ok": true,
  "active_tokens": 0,
  "disk_free_mb": 48832,
  "pdf_available": true
}
```

| 字段 | 说明 |
|------|------|
| `active_tokens` | 当前活跃的下载令牌数 |
| `disk_free_mb` | 保存目录所在磁盘剩余空间（MB） |
| `pdf_available` | 是否可用 PDF 转换（依赖 LibreOffice） |

#### `POST /api/register`

注册已生成的 Word 文件，返回一次性下载 Token 和密码。

**请求体：**
```json
{
  "file": "/opt/lobster_docs/关于XXX的通知.docx"
}
```

**响应：**
```json
{
  "ok": true,
  "token": "aB3x...K7w",
  "password": "284159",
  "expire_in": 300,
  "download_links": {
    "lan": "http://192.168.31.101:10091/dl?tok=aB3x...K7w",
    "wan": "http://81.68.248.64:10091/dl?tok=aB3x...K7w"
  },
  "local_path": "/opt/lobster_docs/关于XXX的通知.docx",
  "pdf_available": true
}
```

| 字段 | 说明 |
|------|------|
| `token` | 高熵 URL-safe Token（约22字符），链接中不含密码 |
| `password` | 6 位数字密码，本处一次性返回，不再重复展示 |
| `expire_in` | 链接有效期（秒），默认 300 |
| `download_links` | 内网/外网下载链接（不包含密码） |
| `pdf_available` | 同目录下是否存在 PDF 文件 |

#### `GET /dl?tok=<token>&pwd=<password>`

下载 Word 文件。

- **无密码访问：** 返回密码输入页面（极简设计，深色主题）
- **密码正确：** 返回 .docx 文件；若同目录有同名 .pdf，返回双格式选择页
- **密码错误：** 返回错误提示，含剩余尝试次数
- **密码错误 ≥3 次：** Token 立即作废，返回「链接已作废」
- **超时（300秒）：** 返回「链接已过期」
- **成功下载后：** Token 立即作废，不可二次使用

**状态码：**
| 状态码 | 说明 |
|--------|------|
| 200 | 返回文件或 HTML 页面 |
| 403 | 密码错误/次数过多已作废 |
| 410 | 链接已过期或已使用 |

#### `GET /dl/pdf?tok=<token>&pwd=<password>`

下载 PDF 文件（逻辑同 `/dl`）。

### 环境变量覆盖

以下环境变量可覆盖 `config.yaml` 中的对应配置：

| 环境变量 | 覆盖配置项 | 示例 |
|----------|-----------|------|
| `DOC_SERVICE_PORT` | `service.port` | `10091` |
| `DOC_LAN_URL` | `urls.lan` | `http://192.168.31.101:10091` |
| `DOC_WAN_URL` | `urls.wan` | `http://81.68.248.64:10091` |
| `DOC_LOCAL_ROOT` | `urls.local_root` | `/opt/lobster_docs` |
| `DOC_CLEANUP_INTERVAL` | `cleanup.interval_seconds` | `60` |
| `DOC_LOG_ENABLED` | `log.enabled` | `true` / `false` |
| `DOC_LOG_FILE` | `log.file` | `logs/server.log` |

> 环境变量优先级高于 `config.yaml`，适合容器化部署场景。

### 安全设计

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  文件生成     │────▶│  /api/register│────▶│  下载页面     │
│  build_docx  │     │  返回 token  │     │  /dl?tok=xxx │
└──────────────┘     │  + 密码      │     │  + 密码输入   │
                     └──────────────┘     └──────┬───────┘
                                                 │
                    ┌───────────────────────────┐│
                    │ 安全策略：                 ││
                    │ · token 与密码分离传输     ││
                    │ · 密码错误≥3次→自动作废   ││
                    │ · 有效期300秒→自动清理    │▼
                    │ · 一次性下载→即时作废     ┌──────────────┐
                    │ · 路径穿越防护(is_safe)  │  文件响应     │
                    │ · 文件清理守护线程        └──────────────┘
                    └───────────────────────────┘
```

---

## 优化维护脚本 (optimize_openclaw.sh)

自动清理 OpenClaw 运行过程中产生的历史会话文件、冗余上下文，保持 Token 消耗在合理范围。

### 功能

| 模块 | 操作 | 安全保护 |
|------|------|---------|
| 1️⃣ 清理历史会话 | 删除非当前活动的 `.jsonl` / `.trajectory` 文件 | 保留当前活跃会话，`find -print0` 处理特殊文件名 |
| 2️⃣ 精简 AGENTS.md | 超过 5KB 的通用 AGENTS.md 替换为精简版 | **跳过含"团队架构"标记的定制版**，保护团队协作协议 |
| 3️⃣ 整理大文件 | >10KB 的 `.md`/`.txt` 移入 `docs/` 子目录 | 跳过核心身份文件（SOUL/USER/MEMORY 等） |
| 4️⃣ 重置 HEARTBEAT.md | 清除非注释内容行 | **跳过含任务关键词的行**，保留实际的 cron/remind 指令 |

### 使用方式

```bash
# 执行一次
bash optimize_openclaw.sh

# 预览模式（不实际执行）
bash optimize_openclaw.sh --dry-run

# 定时任务（每日 3:00）
0 3 * * * /usr/bin/flock -n /tmp/openclaw_optimize.lock /path/to/optimize_openclaw.sh >> /var/log/openclaw_optimize.log 2>&1
```

---

## 主机名配置 (hostname-config.sh)

一键修改 Debian 系统主机名。

```bash
sudo bash hostname-config.sh 新主机名
# 示例：
sudo bash hostname-config.sh office-openclaw
```

修改范围：`/etc/hostname`、`/etc/hosts`（127.0.1.1 条目）、systemd hostnamed。

---

## 常见问题

### Q: openclaw 命令不存在怎么办？

```bash
# 访问 https://openclaw.ai 查看安装文档
# 或查看本地文档
ls /usr/lib/node_modules/openclaw/docs/
```

### Q: 安装时 jq 失败怎么办？

```bash
# Debian/Ubuntu
sudo apt install jq -y

# CentOS/RHEL
sudo yum install jq -y
```

脚本已降级为警告，jq 缺失不影响 Agent 创建，仅 Agent 状态检测功能受限。

### Q: doc-export 服务启动后如何测试？

```bash
# 健康检查
curl http://127.0.0.1:10091/ping
curl http://127.0.0.1:10091/health

# 生成示例公文
python3 /path/to/doc-export/build_docx.py \
  --config /path/to/doc-export/config.yaml \
  --title "关于测试的通知" \
  --body "各部门：\n现就有关事项通知如下：\n一、高度重视\n请各单位认真组织学习。" \
  --out /opt/lobster_docs/测试通知.docx

# 注册下载链接
curl -X POST http://127.0.0.1:10091/api/register \
  -H "Content-Type: application/json" \
  -d '{"file": "/opt/lobster_docs/测试通知.docx"}'
```

### Q: PDF 转换失败怎么办？

确保已安装 LibreOffice：

```bash
# Debian/Ubuntu
sudo apt install libreoffice-writer -y

# 验证
soffice --version
```

### Q: 中文字体显示为方框或乱码？

```bash
# 安装开源中文字体
sudo apt install fonts-wqy-zenhei fonts-wqy-microhei fonts-noto-cjk

# 或从 Windows 拷贝字体
# Windows C:\Windows\Fonts 中的 simfang.ttf、simsun.ttf 等
sudo cp /path/to/windows/fonts/*.ttf /usr/share/fonts/chinese/
sudo fc-cache -fv
```

### Q: 如何单独重新部署某个 Agent？

```bash
# 删除后重新创建
openclaw agents remove <agent-id>

# 或者手动覆盖配置文件后 reload
openclaw reload
```

### Q: 端口被占用怎么办？

```bash
# 查看占用端口的进程
ss -tulpn | grep 10091

# 在安装时选择其他端口，或用环境变量覆盖
DOC_SERVICE_PORT=10092 python3 server.py
```

---

## 版本历史

| 版本 | 日期 | 变更 |
|------|------|------|
| **v2.3** | 2026-05 | 安全修复：路径穿越防护（`is_safe_path`）、线程锁（`threading.Lock`）、/direct 端点移除、环境变量覆盖、输入校验增强、跨平台包管理器支持 |
| **v2.1** | 2026-05 | **main.sh 重构：** 移除危险 `apt upgrade`、`run_step` 错误隔离模式；**optimize 修复：** 子shell变量陷阱、团队AGENTS保护、HEARTBEAT含任务关键词保留；**build_docx 增强：** 字体智能检测（`detect_available_font`）、发文字号支持；**server.py 修复：** `/dl`/`/dl/pdf` 端点增加 `purge_expired()`、剩余密码尝试次数提示 |
| **v2.0** | 2026-05 | Agent 部署脚本修复：`openclaw agents list` 容错、总协调人 TOOLS.md 定制、文书职责明确、远山总称呼统一 |

---

## 许可

本项目为央企内部工具，仅供授权用户使用。

---

*文如流水，意似高山。*

*—— 纪棠（党工纪与文书专家）*
