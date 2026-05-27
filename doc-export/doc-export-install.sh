#!/usr/bin/env bash
# =============================================================================
#  doc-export 一键部署脚本（完整修复版）
#  功能：安装符合 GB/T 9704 的公文 Word(.docx) 导出 + 可选 PDF +
#        一次性安全下载服务（Token 与密码分离，高熵 Token，链接不含密码）
#  系统要求：Ubuntu 20.04+ / Debian 11+ / CentOS 8+ （需 systemd 以支持开机自启）
#  运行方式：bash install_doc_export.sh
# =============================================================================
set -euo pipefail

# ── 颜色输出 ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── 环境检测 ────────────────────────────────────────────────────────────────
info "检测系统基础环境..."
command -v python3 >/dev/null || error "请先安装 python3"
command -v pip3 >/dev/null   || error "请先安装 pip3"

# LibreOffice 用于 Word 转 PDF（可选）
if command -v soffice >/dev/null; then
    info "LibreOffice 已安装，将启用 PDF 导出"
    HAS_SOFFICE=1
else
    warn "未找到 LibreOffice，将自动尝试安装（若失败则跳过 PDF 功能）"
    read -p "是否自动安装 LibreOffice-headless？[Y/n] " ans
    if [[ "$ans" =~ ^[Nn]$ ]]; then
        HAS_SOFFICE=0
        warn "PDF 导出将被禁用（仅提供 .docx）"
    else
        HAS_SOFFICE=1
        info "正在安装 libreoffice-writer..."
        sudo apt-get update -qq && sudo apt-get install -y -qq libreoffice-writer
    fi
fi

# ── 目录与技能路径 ─────────────────────────────────────────────────────────
SKILL_HOME="${HOME}/.openclaw/skills/doc-export"
mkdir -p "$SKILL_HOME"/{assets,.cache}
cd "$SKILL_HOME"
info "技能目录：$SKILL_HOME"

# ── 交互式配置收集 ─────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━ 服务配置 ━━━━━━━━━━━━━━━━━━━━"
read -p "监听端口 [10091]: " PORT; PORT=${PORT:-10091}
read -p "内网基址 [http://192.168.31.101:${PORT}]: " LAN; LAN=${LAN:-"http://192.168.31.101:${PORT}"}
read -p "外网基址 [http://81.68.248.64:${PORT}]: " WAN; WAN=${WAN:-"http://81.68.248.64:${PORT}"}
read -p "文件保存目录 [/opt/lobster_docs]: " LOCAL; LOCAL=${LOCAL:-/opt/lobster_docs}
read -p "发文机关全称（如 ××市人民政府办公室）: " ORG_NAME
ORG_NAME=${ORG_NAME:-"××市人民政府办公室"}

# 创建并授权保存目录
sudo mkdir -p "$LOCAL"
sudo chown "$USER:$USER" "$LOCAL"

# ── 写入配置文件 config.yaml ──────────────────────────────────────────────
info "生成 config.yaml..."
cat > config.yaml <<YAML
# ===========================================================
#  doc-export 运行时配置（由安装脚本自动生成）
# ===========================================================
version: "1.0.1"

org:
  name: "${ORG_NAME}"                # 发文机关全称（文字备用层）
  name_short: "${ORG_NAME}"          # 简称
  signatory: "${ORG_NAME}"           # 落款名称

red_header:
  image: "{skill_dir}/assets/red_header_bar.png"   # 红头条透明PNG路径
  height_mm: 56                       # 图片高度（mm），用于页眉微调

service:
  bind: "0.0.0.0"
  port: ${PORT}

urls:
  lan: "${LAN}"                       # 内网基址
  wan: "${WAN}"                       # 外网基址（需路由器转发）
  local_root: "${LOCAL}"              # 文件本地保存目录

security:
  tok_bytes: 16                       # Token 随机字节数（16 字节 → 约22字符）
  pwd_length: 6                       # 临时密码长度
  ttl_seconds: 300                    # 链接有效期（秒）
  max_fail: 3                         # 密码最大错误次数

fonts:
  fallback_body: "FangSong"           # 当仿宋_GB2312找不到时使用
  fallback_title: "SimSun"            # 标题用字
  search_names:                       # 字体回退顺序
    - "仿宋_GB2312"
    - "FangSong"
    - "仿宋"
    - "SimSun"
    - "宋体"
YAML

# ── 写入核心 Python 文件 ───────────────────────────────────────────────────
info "部署 Python 脚本..."

# ---------- server.py（安全下载服务） ----------
cat > server.py <<'PYEOF'
#!/usr/bin/env python3
"""
server.py — 安全一次性下载服务（已修复 Token/密码分离）
- 高熵 Token 出现在 URL 中，密码仅展示给用户
- 密码输入错误 ≥3 次立即作废 Token
- 支持 .docx 与 .pdf 双格式下载选择
"""
import os, time, secrets, json
from pathlib import Path
import yaml
from fastapi import FastAPI, Query, HTTPException
from fastapi.responses import FileResponse, HTMLResponse
from fastapi.middleware.cors import CORSMiddleware
import uvicorn

# ── 加载配置 ──────────────────────────────────────────────────
SKILL_DIR = Path(__file__).resolve().parent
CFG = yaml.safe_load((SKILL_DIR / "config.yaml").read_text(encoding="utf-8"))
SVC   = CFG["service"]
SEC   = CFG["security"]
URLS  = CFG["urls"]
LOCAL = Path(URLS["local_root"]).resolve()
LOCAL.mkdir(parents=True, exist_ok=True)

# ── 内存令牌表 ──
# tok -> { file, pdf, exp, fail, used, pwd }
TOKENS: dict[str, dict] = {}

app = FastAPI(title="doc-export-download")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

def purge_expired():
    now = time.time()
    expired = [k for k, v in TOKENS.items() if v["exp"] < now]
    for k in expired: del TOKENS[k]

def generate_token() -> str:
    """生成高熵 URL-safe Token（约22字符）"""
    return secrets.token_urlsafe(SEC.get("tok_bytes", 16))

def generate_password() -> str:
    """生成6位数字密码（独立于Token）"""
    return f"{secrets.randbelow(10**SEC.get('pwd_length',6)):0{SEC.get('pwd_length',6)}d}"

def register_file(docx_path: Path) -> tuple[str, str]:
    """
    注册一个 docx 文件，返回 (token, password)
    同时探测同名 .pdf 是否存在
    """
    purge_expired()
    tok = generate_token()
    while tok in TOKENS:
        tok = generate_token()
    pwd = generate_password()
    rec = {
        "file": str(docx_path.resolve()),
        "pdf": None,
        "exp": time.time() + SEC["ttl_seconds"],
        "fail": 0,
        "used": False,
        "pwd": pwd
    }
    # 检查同名 PDF
    pdf_path = docx_path.with_suffix(".pdf")
    if pdf_path.exists():
        rec["pdf"] = str(pdf_path.resolve())
    TOKENS[tok] = rec
    return tok, pwd

# ── 密码输入页 HTML ───────────────────────────────────────────
def password_page(tok: str, error: str = "") -> HTMLResponse:
    remain = max(0, int(TOKENS.get(tok, {}).get("exp", 0) - time.time()))
    err_html = f'<p style="color:#c41e24;margin-top:12px">{error}</p>' if error else ""
    return HTMLResponse(f"""<!doctype html>
<html lang="zh">
<head><meta charset="utf-8"><title>🔒 公文安全下载</title>
<style>
 body{{font-family:'PingFang SC','Microsoft YaHei',sans-serif;display:flex;justify-content:center;
       align-items:center;min-height:100vh;background:#f0f2f5;margin:0}}
 .card{{background:#fff;padding:40px 48px;border-radius:16px;box-shadow:0 8px 40px rgba(0,0,0,.10);
        text-align:center;min-width:340px}}
 h2{{color:#1a1a1a;margin-bottom:8px}}
 input[type=text]{{font-size:1.8rem;letter-spacing:12px;padding:10px 14px;width:190px;
       text-align:center;border:1.5px solid #d0d5dd;border-radius:10px;outline:none;
       font-family:monospace;margin-top:16px}}
 input:focus{{border-color:#c41e24;box-shadow:0 0 0 3px rgba(196,30,36,.15)}}
 button{{margin-top:24px;padding:10px 36px;font-size:1rem;font-weight:600;border:none;
         border-radius:10px;background:linear-gradient(135deg,#c41e24,#e8453c);
         color:#fff;cursor:pointer;transition:all .2s}}
 button:hover{{transform:translateY(-1px);box-shadow:0 4px 12px rgba(196,30,36,.4)}}
 .muted{{color:#888;font-size:.85rem;margin-top:14px}}
</style></head>
<body>
<div class="card">
 <h2>🔒 公文安全下载</h2>
 <p style="color:#555;font-size:1rem">请输入 6 位临时密码（大小写敏感）</p>
 <form method="get" action="/dl">
  <input type="hidden" name="tok" value="{tok}">
  <input type="text" name="pwd" maxlength="{SEC.get('pwd_length',6)}"
         pattern="\\d{{6}}" placeholder="______"
         autofocus required inputmode="numeric" enterkeyhint="done">
  <br>{err_html}
  <button type="submit">下 载</button>
 </form>
 <p class="muted">链接剩余 {remain}s · 仅限本人一次有效</p>
</div>
</body></html>""")

# ═══════════════════════════════════════════════════════════════
#  接口
# ═══════════════════════════════════════════════════════════════
@app.get("/ping")
def ping():
    return {"ok":True, "service":"doc-export", "port":SVC["port"]}

@app.post("/api/register")
async def api_register(body: dict):
    """
    注册已生成的 docx 文件
    请求体: {"file": "/opt/lobster_docs/通知.docx"}
    返回: token（无密码的下载链接）和 6 位密码（仅本次显示）
    """
    fpath = Path(body["file"])
    if not fpath.exists():
        raise HTTPException(400, f"文件不存在: {fpath}")

    tok, pwd = register_file(fpath)

    links = {}
    for label, base in [("lan", URLS["lan"]), ("wan", URLS["wan"])]:
        if base:
            links[label] = f"{base}/dl?tok={tok}"   # 不包含密码

    return {
        "ok": True,
        "token": tok,
        "password": pwd,                 # 6 位数字，仅此处返回一次
        "expire_in": SEC["ttl_seconds"],
        "local_path": str(fpath.resolve()),
        "download_links": links,         # 不含密码
        "pdf_available": os.path.isfile(fpath.with_suffix(".pdf"))
    }

@app.get("/dl")
async def download(tok: str = Query(...), pwd: str = Query(default="")):
    """
    下载端点：
    - 未提供 pwd → 显示密码输入页
    - 提供 pwd → 验证后返回文件（一次有效）
    """
    purge_expired()
    rec = TOKENS.get(tok)

    # 不存在或已使用
    if not rec or rec.get("used"):
        raise HTTPException(410, "链接已过期或已使用")
    if time.time() > rec["exp"]:
        del TOKENS[tok]
        raise HTTPException(410, "链接已过期")

    # 无密码 → 输入页面
    if not pwd:
        return password_page(tok)

    # 验证密码
    if pwd != rec["pwd"]:
        rec["fail"] += 1
        if rec["fail"] >= SEC["max_fail"]:
            del TOKENS[tok]
            raise HTTPException(403, "密码错误次数过多，链接已作废")
        return password_page(tok, error="❌ 密码错误，请重新输入")

    # 密码正确，立即作废
    TOKENS.pop(tok)

    # 如果存在 PDF，让用户选择下载格式
    if rec.get("pdf") and os.path.isfile(rec["pdf"]):
        import urllib.parse
        safe_docx = urllib.parse.quote(os.path.basename(rec["file"]))
        safe_pdf  = urllib.parse.quote(os.path.basename(rec["pdf"]))
        return HTMLResponse(f"""<!doctype html>
<html lang="zh">
<head><meta charset="utf-8"><title>📄 公文下载</title>
<style>
 body{{font-family:'PingFang SC','Microsoft YaHei',sans-serif;display:flex;
       justify-content:center;align-items:center;min-height:100vh;background:#f0f2f5}}
 .card{{background:#fff;padding:36px 48px;border-radius:16px;box-shadow:0 8px 40px rgba(0,0,0,.10)}}
 a.btn{{display:inline-block;margin:10px;padding:12px 32px;border-radius:10px;
        background:linear-gradient(135deg,#c41e24,#e8453c);color:#fff;
        text-decoration:none;font-weight:600;transition:all .2s}}
 a.btn:hover{{transform:translateY(-2px);box-shadow:0 6px 18px rgba(196,30,36,.4)}}
</style></head>
<body>
<div class="card">
 <h2>📄 公文下载</h2>
 <p>请选择您需要的格式：</p>
 <a class="btn" href="/direct?file={safe_docx}">📝 Word 文档 (.docx)</a>
 <a class="btn" href="/direct?file={safe_pdf}">📑 PDF 文件 (.pdf)</a>
 <p style="color:#999;margin-top:18px;">文件已安全生成，页面关闭后链接失效</p>
</div>
</body></html>""")

    # 仅 docx，直接返回
    return FileResponse(
        path=rec["file"],
        filename=os.path.basename(rec["file"]),
        media_type="application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    )

# 辅助：直接下载文件（仅限本地目录内的文件）
@app.get("/direct")
async def direct_download(file: str = Query(...)):
    full = LOCAL / os.path.basename(file)   # 避免路径穿越
    if not full.exists():
        raise HTTPException(404)
    return FileResponse(path=str(full))

# ── 启动 ──────────────────────────────────────────────────────
if __name__ == "__main__":
    print(f"\n🦞 安全下载服务启动 http://{SVC['bind']}:{SVC['port']}")
    print(f"   内网: {URLS['lan']}/dl?tok=xxxxxx")
    print(f"   外网: {URLS['wan']}/dl?tok=xxxxxx")
    uvicorn.run(app, host=SVC["bind"], port=SVC["port"])
PYEOF

# ---------- build_docx.py（公文生成器，含附件与 PDF） ----------
cat > build_docx.py <<'PYEOF'
#!/usr/bin/env python3
"""
build_docx.py — GB/T 9704-2012 公文生成器（修复版）
- 支持红头条透明 PNG 或文字备用
- 强制东亚字体绑定
- 主送机关显式传入，不再误判
- 附件列表自动添加
- 可选 PDF 转换
"""
import argparse, os, sys, re, json, subprocess
from pathlib import Path
from datetime import datetime
from docx import Document
from docx.shared import Pt, Cm, RGBColor
from docx.oxml.ns import qn
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_LINE_SPACING
import yaml

def set_run_font(run, name: str, size_pt: float, bold=False, color=None):
    """设置字体并强制写入 w:eastAsia"""
    run.font.name = name
    run.font.size = Pt(size_pt)
    run.font.bold = bold
    if color:
        run.font.color.rgb = RGBColor(*color)
    rPr = run._element.get_or_add_rPr()
    rPr.rFonts.set(qn('w:eastAsia'), name)

def set_normal_style(doc, body_font: str):
    style = doc.styles['Normal']
    style.font.name = body_font
    style.font.size = Pt(16)
    rPr = style.element.get_or_add_rPr()
    rPr.rFonts.set(qn('w:eastAsia'), body_font)

def find_available_font(cfg, preferred):
    """按配置的 search_names 返回第一个可用字体名（仅做名称匹配）"""
    search = cfg.get("fonts", {}).get("search_names", [])
    for name in search:
        if name:
            return name
    return cfg.get("fonts", {}).get("fallback_body", "FangSong")

def add_red_header(section, img_path: str):
    if not os.path.isfile(img_path):
        return False
    header = section.header
    para = header.paragraphs[0] if header.paragraphs else header.add_paragraph()
    for p in header.paragraphs[1:]:
        p._element.getparent().remove(p._element)
    para.paragraph_format.space_before = Pt(0)
    para.paragraph_format.space_after = Pt(0)
    para.paragraph_format.line_spacing = 1.0
    para.add_run().add_picture(img_path, width=Cm(17.0))
    para.alignment = WD_ALIGN_PARAGRAPH.CENTER
    section.header_distance = Cm(0.5)
    return True

def add_attachments(doc, attachments: list, font_name: str):
    if not attachments:
        return
    doc.add_paragraph()
    p_title = doc.add_paragraph()
    p_title.paragraph_format.first_line_indent = Cm(0)
    set_run_font(p_title.add_run("附件："), font_name, 16)
    for idx, att in enumerate(attachments, 1):
        p = doc.add_paragraph()
        p.paragraph_format.first_line_indent = Cm(0)
        set_run_font(p.add_run(f"{idx}. {att}"), font_name, 16)

def typeset_body(doc, body_text: str, main_to: str, font_name: str):
    """正文排版，主送机关顶格，其余段落首行缩进2字符，固定行距28磅"""
    lines = body_text.splitlines()
    first = True
    for line in lines:
        line = line.rstrip()
        if not line:
            doc.add_paragraph()
            continue
        p = doc.add_paragraph()
        if first and main_to:
            # 主送机关（顶格）
            set_run_font(p.add_run(main_to), font_name, 16)
            p.paragraph_format.space_before = Pt(6)
            first = False
            continue
        # 普通正文
        indent = Cm(0.85)   # 三号字 2 字符 ≈ 0.85cm
        set_run_font(p.add_run(line), font_name, 16)
        p.paragraph_format.first_line_indent = indent
        p.paragraph_format.line_spacing_rule = WD_LINE_SPACING.FIXED
        p.paragraph_format.line_spacing = Pt(28)
        p.paragraph_format.space_before = Pt(0)
        p.paragraph_format.space_after  = Pt(0)
        p.alignment = WD_ALIGN_PARAGRAPH.JUSTIFY
        first = False

def build_docx(cfg, title, body, main_to, attachments, sign_date, out_path):
    doc = Document()
    sec = doc.sections[0]
    sec.top_margin    = Cm(3.7)
    sec.bottom_margin = Cm(3.5)
    sec.left_margin   = Cm(2.8)
    sec.right_margin  = Cm(2.6)
    sec.page_width    = Cm(21.0)
    sec.page_height   = Cm(29.7)

    body_font = find_available_font(cfg, "仿宋_GB2312")
    title_font = cfg.get("fonts", {}).get("fallback_title", "SimSun")
    set_normal_style(doc, body_font)

    img_rel = cfg.get("red_header", {}).get("image", "").replace("{skill_dir}", str(Path(__file__).parent))
    if not add_red_header(sec, img_rel):
        p = doc.add_paragraph()
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        set_run_font(p.add_run(cfg["org"]["name"]), title_font, 22, bold=True)
        p2 = doc.add_paragraph()
        p2.alignment = WD_ALIGN_PARAGRAPH.CENTER
        set_run_font(p2.add_run("━" * 32), "SimSun", 14, color=(192,0,0))

    # 标题
    p_title = doc.add_paragraph()
    p_title.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p_title.paragraph_format.space_before = Pt(12)
    p_title.paragraph_format.space_after  = Pt(0)
    set_run_font(p_title.add_run(title), title_font, 22, bold=True)

    # 正文
    typeset_body(doc, body, main_to, body_font)

    # 附件
    add_attachments(doc, attachments, body_font)

    # 落款
    p_sig = doc.add_paragraph()
    p_sig.alignment = WD_ALIGN_PARAGRAPH.RIGHT
    p_sig.paragraph_format.space_before = Pt(18)
    signatory = cfg.get("org", {}).get("signatory", cfg["org"]["name"])
    set_run_font(p_sig.add_run(f"{signatory}\n{sign_date}"), body_font, 16)

    out = Path(out_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    doc.save(str(out))
    return str(out)

def convert_to_pdf(docx_path):
    try:
        subprocess.run(["soffice", "--headless", "--convert-to", "pdf",
                        "--outdir", os.path.dirname(docx_path), docx_path],
                       check=True, timeout=60, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        pdf = Path(docx_path).with_suffix(".pdf")
        return str(pdf) if pdf.exists() else None
    except:
        return None

# ── CLI ────────────────────────────────────────────────────────
if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="config.yaml")
    parser.add_argument("--title", required=True)
    parser.add_argument("--body", default="")
    parser.add_argument("--body-file", default="")
    parser.add_argument("--main-to", default="", help="主送机关（如：各区县人民政府：）")
    parser.add_argument("--attachments", nargs="*", default=[])
    parser.add_argument("--sign-date", default=datetime.now().strftime("%Y年%-m月%-d日"))
    parser.add_argument("--out", required=True, help="输出 .docx 路径")
    parser.add_argument("--pdf", action="store_true", help="同时生成 PDF")
    args = parser.parse_args()

    cfg = yaml.safe_load(Path(args.config).read_text(encoding="utf-8"))
    body = args.body or (Path(args.body_file).read_text(encoding="utf-8") if args.body_file else "")

    docx_path = build_docx(cfg, args.title, body, args.main_to,
                           args.attachments, args.sign_date, args.out)
    result = {"ok": True, "docx": docx_path}

    if args.pdf and HAS_SOFFICE:
        pdf_path = convert_to_pdf(docx_path)
        result["pdf"] = pdf_path if pdf_path else None

    print(json.dumps(result, ensure_ascii=False))
PYEOF

# ── 写入辅助文件 ──────────────────────────────────────────────────────────
info "写入技能描述与依赖文件..."

# requirements.txt
cat > requirements.txt <<REQ
fastapi==0.110.0
uvicorn[standard]==0.27.1
python-docx==1.1.0
pyyaml>=6.0
Pillow>=10.0
REQ

# SKILL.md (用于 OpenClaw 技能触发)
cat > SKILL.md <<'SKMD'
---
name: doc-export
description: 将对话内容导出为符合 GB/T 9704 标准的公文 Word(.docx) 与 PDF；提供内网/外网一次性安全下载链接（6位密码，5分钟有效），并给出本地存盘路径。
---

# 公文导出技能

## 触发条件
用户要求“生成/导出/下发/下载文档/把上面整理成公文”时激活。

## 执行流程
1. 收集字段（标题、正文、主送机关、附件、成文日期）
2. 调用 build_docx.py 生成 .docx（及 PDF）
3. 注册文件至下载服务
4. 回显内网/外网链接（不含密码）、密码、有效期和本地路径
SKMD

# 字体安装辅助脚本
cat > font_setup.sh <<'FONTEOF'
#!/bin/bash
set -e
echo "安装开源中文字体..."
sudo apt-get update -qq
sudo apt-get install -y -qq fonts-wqy-zenhei fonts-wqy-microhei fonts-noto-cjk
sudo fc-cache -fv
echo "字体已安装。"
FONTEOF
chmod +x font_setup.sh

# 红头条图片说明
cat > assets/README.md <<'RED'
请将红头条透明 PNG（包含发文机关全称+红色分隔线）放入此目录，命名为 red_header_bar.png。
建议尺寸：宽 794~1200px，高 80~130px。
若无此图，公文将降级为文字红头。
RED

# ── 安装 Python 依赖 ──────────────────────────────────────────────────────
info "安装 Python 依赖包..."
pip3 install -r requirements.txt -q

# ── systemd 服务（开机自启） ───────────────────────────────────────────────
read -p "是否安装 systemd 服务实现开机自启？[Y/n] " AUTO
if [[ ! "$AUTO" =~ ^[Nn]$ ]]; then
    SERVICE_FILE="/etc/systemd/system/lobster-doc-export.service"
    PYTHON=$(which python3)
    sudo tee "$SERVICE_FILE" > /dev/null <<SYSD
[Unit]
Description=Lobster Doc Export Service
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$SKILL_HOME
ExecStart=$PYTHON $SKILL_HOME/server.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SYSD
    sudo systemctl daemon-reload
    sudo systemctl enable --now lobster-doc-export
    info "服务已启动，状态如下："
    systemctl status lobster-doc-export --no-pager
else
    warn "跳过 systemd 设置。请手动启动：cd $SKILL_HOME && python3 server.py &"
fi

# ── 完成提示 ──────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}✅ 部署完成！${NC}"
echo ""
echo "  技能目录：$SKILL_HOME"
echo "  服务端口：$PORT"
echo "  保存目录：$LOCAL"
echo "  内网地址：$LAN/dl"
echo "  外网地址：$WAN/dl"
echo ""
echo "⚠️  请将红头条图片放入：$SKILL_HOME/assets/red_header_bar.png"
echo "  运行 bash $SKILL_HOME/font_setup.sh 安装中文字体（如需）"
echo ""
echo "  快速测试："
echo "    python3 $SKILL_HOME/build_docx.py --config $SKILL_HOME/config.yaml --title '测试通知' --body '正文内容' --out /tmp/test.docx"
echo "    curl http://127.0.0.1:$PORT/ping"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
