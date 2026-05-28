#!/usr/bin/env bash
# =============================================================================
#  doc-export 一键部署脚本 v2.3 修正增强版
#  功能：部署公文安全下载服务（Word/PDF），提供一次性下载链接
#  修复：安全漏洞、格式乱码、权限问题、跨平台兼容、输入校验等
#  用法：bash install_doc_export.sh
# =============================================================================
set -euo pipefail

# ---------- 颜色定义 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ---------- 权限检查 ----------
check_sudo() {
    if [ "$EUID" -ne 0 ] && ! sudo -n true 2>/dev/null; then
        warn "需要 sudo 权限（用于安装系统包、配置字体、systemd 服务）"
        read -p "按回车继续..." dummy
    fi
}

# ---------- 基础环境检查 ----------
info "检测系统基础环境..."
command -v python3 >/dev/null || error "请先安装 python3"
command -v pip3 >/dev/null   || error "请先安装 pip3"

# ---------- LibreOffice 检测与安装 ----------
HAS_SOFFICE=0
if command -v soffice >/dev/null; then
    info "LibreOffice 已安装，将启用 PDF 导出"
    HAS_SOFFICE=1
else
    warn "未找到 LibreOffice（PDF 导出功能依赖它）"
    read -p "是否自动安装 LibreOffice-headless？[Y/n] " ans
    if [[ "$ans" =~ ^[Nn]$ ]]; then
        warn "PDF 导出将被禁用"
    else
        info "正在安装 LibreOffice..."
        if sudo apt-get update -qq && sudo apt-get install -y -qq libreoffice-writer; then
            HAS_SOFFICE=1
            info "LibreOffice 安装成功"
        else
            warn "安装失败，PDF 功能将不可用"
        fi
    fi
fi

# ---------- 技能目录 ----------
SKILL_HOME="${HOME}/.openclaw/skills/doc-export"
mkdir -p "$SKILL_HOME"/{assets,.cache,logs}
cd "$SKILL_HOME"
info "技能目录：$SKILL_HOME"

# ---------- 交互式配置（增加校验） ----------
echo ""
echo "━━━━━━━━━━━━━━━━━━ 服务配置 ━━━━━━━━━━━━━━━━━━━━"
# 端口校验
while true; do
    read -p "监听端口 [10091]: " PORT; PORT=${PORT:-10091}
    if [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then
        # 检查端口是否被占用
        if ss -tuln | grep -q ":$PORT "; then
            warn "端口 $PORT 已被占用，请更换"
        else
            break
        fi
    else
        warn "请输入 1-65535 之间的数字"
    fi
done

# IP 地址校验（简单格式检查）
while true; do
    read -p "内网 IP 地址 [192.168.31.101]: " INTRANET; INTRANET=${INTRANET:-"192.168.31.101"}
    if [[ "$INTRANET" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        break
    else
        warn "请输入有效的 IPv4 地址"
    fi
done
while true; do
    read -p "外网 IP 地址 [81.68.248.64]: " EXTRANET; EXTRANET=${EXTRANET:-"81.68.248.64"}
    if [[ "$EXTRANET" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        break
    else
        warn "请输入有效的 IPv4 地址"
    fi
done

# 文件保存目录
while true; do
    read -p "文件保存目录 [/opt/lobster_docs]: " LOCAL; LOCAL=${LOCAL:-/opt/lobster_docs}
    if [ -d "$LOCAL" ] || mkdir -p "$LOCAL" 2>/dev/null; then
        break
    else
        warn "无法创建目录 $LOCAL，请检查权限或重新输入"
    fi
done

read -p "发文机关全称（如 ××市人民政府办公室）: " ORG_NAME; ORG_NAME=${ORG_NAME:-"××市人民政府办公室"}

# 确保保存目录存在且用户有权限
sudo mkdir -p "$LOCAL"
sudo chown "$USER:$USER" "$LOCAL"

# =============================================================================
#  字体安装函数（改进包管理器检测）
# =============================================================================
run_font_setup() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🖋️  中文字体环境检查 / 安装"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local SUDO=""
    [ "$EUID" -ne 0 ] && SUDO="sudo"

    # 检测包管理器
    if command -v apt-get >/dev/null; then
        PKG_MGR="apt"
    elif command -v yum >/dev/null; then
        PKG_MGR="yum"
    elif command -v dnf >/dev/null; then
        PKG_MGR="dnf"
    else
        warn "未检测到 apt/yum/dnf，将跳过字体包安装"
        PKG_MGR="none"
    fi

    echo "[1/5] 安装字体配置工具..."
    case $PKG_MGR in
        apt) $SUDO apt-get install -y fontconfig 2>/dev/null || true ;;
        yum) $SUDO yum install -y fontconfig 2>/dev/null || true ;;
        dnf) $SUDO dnf install -y fontconfig 2>/dev/null || true ;;
    esac

    echo "[2/5] 安装开源中文字体（WQY + Noto CJK）..."
    case $PKG_MGR in
        apt)
            $SUDO apt-get install -y fonts-wqy-zenhei fonts-wqy-microhei fonts-noto-cjk 2>/dev/null || true
            ;;
        yum)
            $SUDO yum install -y wqy-zenhei-fonts wqy-microhei-fonts 2>/dev/null || true
            ;;
        dnf)
            $SUDO dnf install -y wqy-zenhei-fonts wqy-microhei-fonts google-noto-cjk-fonts 2>/dev/null || true
            ;;
    esac

    echo ""
    echo "[3/5] 如需严格还原『仿宋_GB2312 / 方正小标宋简体』外观，"
    echo "     你需要有合法授权的字体文件（可从 Windows C:\\Windows\\Fonts 拷贝）："
    echo "      关键文件：simfang.ttf / simhei.ttf"
    echo ""
    read -p "  是否从指定目录拷贝 Windows 字体？(y/N): " CP_WIN
    if [[ "$CP_WIN" =~ ^[Yy]$ ]]; then
        read -p "  输入字体源目录绝对路径（如 /mnt/c/Windows/Fonts）: " SRC_DIR
        if [ -d "$SRC_DIR" ]; then
            $SUDO mkdir -p /usr/share/fonts/chinese
            echo "  正在拷贝 .ttf / .ttc ..."
            $SUDO cp -v "$SRC_DIR"/*.ttf /usr/share/fonts/chinese/ 2>/dev/null || true
            $SUDO cp -v "$SRC_DIR"/*.ttc /usr/share/fonts/chinese/ 2>/dev/null || true
            $SUDO chmod 644 /usr/share/fonts/chinese/*
            $SUDO mkfontscale /usr/share/fonts/chinese 2>/dev/null || true
            $SUDO mkfontdir  /usr/share/fonts/chinese 2>/dev/null || true
            info "字体已放到 /usr/share/fonts/chinese/"
        else
            warn "目录不存在，跳过"
        fi
    fi

    echo "[4/5] 刷新字体缓存..."
    $SUDO fc-cache -fv 2>&1 | tail -5 || true

    echo "[5/5] 验证中文字体可见性："
    fc-list :lang=zh | head -10 2>/dev/null || echo "  (fc-list 无输出，但不影响使用)"
    echo ""
    echo "--- 字体匹配测试 ---"
    echo -n "  仿宋 → "; fc-match "FangSong" 2>/dev/null || echo "(未匹配)"
    echo -n "  SimSun → "; fc-match "SimSun"   2>/dev/null || echo "(未匹配)"
    echo ""
    info "字体环境就绪。"
}

read -p "是否现在配置中文字体？（推荐，可保证 PDF 效果）[Y/n] " DO_FONT
if [[ ! "$DO_FONT" =~ ^[Nn]$ ]]; then
    run_font_setup
fi

# =============================================================================
#  生成配置文件（config.yaml 及示例）
# =============================================================================
info "生成 config.yaml 及示例配置..."

cat > config.yaml <<YAML
version: "2.3.0"
org:
  name: "${ORG_NAME}"
  signatory: "${ORG_NAME}"
red_header:
  image: "assets/red_header_bar.png"
  height_mm: 56
service:
  bind: "0.0.0.0"
  port: ${PORT}
urls:
  lan: "http://${INTRANET}:${PORT}"
  wan: "http://${EXTRANET}:${PORT}"
  local_root: "${LOCAL}"
security:
  tok_bytes: 16
  pwd_length: 6
  ttl_seconds: 300
  max_fail: 3
fonts:
  fallback_body: "FangSong"
  fallback_title: "SimSun"
  search_names: ["仿宋_GB2312","FangSong","仿宋","SimSun","宋体"]
cleanup:
  interval_seconds: 60
log:
  enabled: false
  file: "logs/server.log"
YAML

cat > config.yaml.example <<'YAMLE'
version: "2.3.0"
org:
  name: "××市人民政府办公室"
  signatory: "××市人民政府办公室"
red_header:
  image: "assets/red_header_bar.png"
  height_mm: 56
service:
  bind: "0.0.0.0"
  port: 10091
urls:
  lan: "http://192.168.31.101:10091"
  wan: "http://81.68.248.64:10091"
  local_root: "/opt/lobster_docs"
security:
  tok_bytes: 16
  pwd_length: 6
  ttl_seconds: 300
  max_fail: 3
fonts:
  fallback_body: "FangSong"
  fallback_title: "SimSun"
  search_names: ["仿宋_GB2312","FangSong","仿宋","SimSun","宋体"]
cleanup:
  interval_seconds: 60
log:
  enabled: false
  file: "logs/server.log"
YAMLE

# =============================================================================
#  核心服务代码（server.py） - 已修复安全漏洞
# =============================================================================
info "生成核心服务程序..."

cat > server.py <<'PYEOF'
#!/usr/bin/env python3
"""
server.py — 公文安全下载服务 v2.3
功能：注册文件，生成一次性 token + 6 位密码，提供下载页面，自动清理
修复：路径遍历漏洞（仅允许 LOCAL_ROOT 目录内的文件）
"""
import os, time, secrets, threading, logging, shutil
from pathlib import Path
import yaml
from fastapi import FastAPI, Query, HTTPException, Request
from fastapi.responses import FileResponse, HTMLResponse
from fastapi.middleware.cors import CORSMiddleware
import uvicorn

# ---------- 加载配置 ----------
SKILL_DIR = Path(__file__).resolve().parent
with open(SKILL_DIR / "config.yaml", encoding="utf-8") as f:
    CFG = yaml.safe_load(f)

def env_override(cfg_path, env_var, default=None):
    """用环境变量覆盖配置项，自动匹配类型"""
    val = os.getenv(env_var)
    if not val:
        return
    keys = cfg_path.split('.')
    d = CFG
    for k in keys[:-1]:
        d = d.setdefault(k, {})
    try:
        existing = d.get(keys[-1])
        if existing is not None:
            if isinstance(existing, bool):
                d[keys[-1]] = val.lower() in ('true', '1', 'yes')
            else:
                d[keys[-1]] = type(existing)(val)
        else:
            d[keys[-1]] = val
    except (ValueError, TypeError):
        logging.warning(f"环境变量 {env_var}={val} 转换失败，将忽略")

# 允许通过环境变量覆盖关键配置
env_override('service.port', 'DOC_SERVICE_PORT')
env_override('urls.lan', 'DOC_LAN_URL')
env_override('urls.wan', 'DOC_WAN_URL')
env_override('urls.local_root', 'DOC_LOCAL_ROOT')
env_override('cleanup.interval_seconds', 'DOC_CLEANUP_INTERVAL')
env_override('log.enabled', 'DOC_LOG_ENABLED')
env_override('log.file', 'DOC_LOG_FILE')

# ---------- 日志配置 ----------
LOG_CFG = CFG.get('log', {})
if LOG_CFG.get('enabled'):
    log_file = SKILL_DIR / LOG_CFG.get('file', 'logs/server.log')
    log_file.parent.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(filename=str(log_file), level=logging.INFO,
                        format='%(asctime)s %(levelname)s: %(message)s')
else:
    logging.basicConfig(level=logging.INFO, format='%(levelname)s: %(message)s')

# ---------- 全局变量 ----------
SVC   = CFG["service"]
SEC   = CFG["security"]
URLS  = CFG["urls"]
LOCAL = Path(URLS["local_root"]).resolve()
LOCAL.mkdir(parents=True, exist_ok=True)

TOKENS: dict[str, dict] = {}
LOCK = threading.Lock()

# ---------- 安全校验：确保文件路径在允许目录内 ----------
def is_safe_path(file_path: Path) -> bool:
    """检查文件是否位于 LOCAL_ROOT 目录下（防路径遍历）"""
    try:
        resolved = file_path.resolve()
        return str(resolved).startswith(str(LOCAL))
    except Exception:
        return False

# ---------- Token 管理 ----------
def purge_expired():
    """清理过期 token 及相关文件"""
    now = time.time()
    with LOCK:
        expired = [k for k, v in TOKENS.items() if v["exp"] < now]
        for k in expired:
            for pk in ("file", "pdf"):
                fp = TOKENS[k].get(pk)
                if fp and os.path.isfile(fp):
                    try:
                        os.remove(fp)
                    except Exception as e:
                        logging.warning(f"清理文件失败 {fp}: {e}")
            del TOKENS[k]
    if expired:
        logging.info(f"清理了 {len(expired)} 个过期 token")
    return len(expired)

def cleanup_loop():
    """定时清理守护线程"""
    interval = CFG.get("cleanup", {}).get("interval_seconds", 60)
    while True:
        time.sleep(interval)
        purge_expired()

def gen_token() -> str:
    return secrets.token_urlsafe(SEC.get("tok_bytes", 16))

def gen_password() -> str:
    length = SEC["pwd_length"]
    return f"{secrets.randbelow(10**length):0{length}d}"

def register_file(docx_path: Path) -> tuple[str, str]:
    """注册文件，返回 token 和密码"""
    # 安全校验：仅允许特定目录下的文件
    if not is_safe_path(docx_path):
        raise HTTPException(400, "文件路径非法，不允许访问外部文件")
    if not docx_path.exists():
        raise HTTPException(400, "文件不存在")

    with LOCK:
        purge_expired()
        tok = gen_token()
        while tok in TOKENS:
            tok = gen_token()
        pwd = gen_password()
        rec = {
            "file": str(docx_path.resolve()),
            "pdf": None,
            "exp": time.time() + SEC["ttl_seconds"],
            "fail": 0,
            "used": False,
            "pwd": pwd
        }
        # 如果同目录下存在同名 PDF 则自动注册
        pdf_path = docx_path.with_suffix(".pdf")
        if pdf_path.exists():
            rec["pdf"] = str(pdf_path.resolve())
        TOKENS[tok] = rec
        logging.info(f"注册文件: {docx_path.name} (tok={tok})")
    return tok, pwd

# ---------- HTML 页面模板 ----------
def download_page(tok: str, rec: dict = None, error: str = None, expired: bool = False):
    remain = max(0, int((rec.get("exp", 0) - time.time())) if rec else 0) if not expired else 0
    local_docx = rec.get("file", "") if rec else ""
    local_pdf = rec.get("pdf", "") if rec else ""
    err_html = f'<div class="error">{error}</div>' if error else ""

    form_html = ""
    if not expired and rec and not rec.get("used"):
        form_html = f'''<form method="GET" id="df">
<input type="hidden" name="tok" value="{tok}">
<div class="pwd-group">
<input type="text" name="pwd" maxlength="{SEC['pwd_length']}" placeholder="输入6位密码" autofocus>
</div>
<div class="btns">
<button type="submit" class="btn">📥 下载 Word</button>
<button type="submit" class="btn sec" formaction="/dl/pdf?tok={tok}">📄 下载 PDF</button>
</div>
</form>'''

    local_html = ""
    if local_docx:
        local_html += f'''<div class="local-item" onclick="copyText('{local_docx}')" title="点击复制">📁 Word 本地路径：<code>{local_docx}</code></div>'''
    if local_pdf:
        local_html += f'''<div class="local-item" onclick="copyText('{local_pdf}')" title="点击复制">📎 PDF 本地路径：<code>{local_pdf}</code></div>'''

    return HTMLResponse(f"""<!DOCTYPE html><html lang="zh"><head><meta charset="utf-8"><title>🔐 公文安全下载</title>
<style>*{{margin:0;padding:0;box-sizing:border-box}}body{{font-family:"Microsoft YaHei","PingFang SC",sans-serif;background:linear-gradient(135deg,#0f0c29,#302b63,#24243e);min-height:100vh;display:flex;align-items:center;justify-content:center;color:#e0e0e0}}.card{{background:rgba(255,255,255,.08);backdrop-filter:blur(20px);border-radius:24px;padding:40px;max-width:480px;width:90%;text-align:center}}.icon{{font-size:48px;margin-bottom:16px}}h1{{font-size:22px;color:#fff;margin-bottom:8px}}.sub{{font-size:14px;color:#a0a0c0;margin-bottom:24px}}.error{{background:rgba(255,80,80,.15);border:1px solid rgba(255,80,80,.3);color:#ff6b6b;padding:10px 16px;border-radius:12px;font-size:14px;margin-bottom:16px}}.pwd-group{{margin-bottom:20px}}input{{width:100%;padding:14px;background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.15);border-radius:14px;font-size:24px;color:#fff;text-align:center;letter-spacing:12px;outline:none;font-family:"Courier New",monospace}}input:focus{{border-color:#667eea}}.btns{{display:flex;gap:12px;margin-top:20px}}.btn{{flex:1;padding:14px;border:none;border-radius:14px;font-size:16px;font-weight:600;cursor:pointer;background:linear-gradient(135deg,#667eea,#764ba2);color:#fff;text-decoration:none}}.btn:hover{{transform:translateY(-2px);box-shadow:0 8px 20px rgba(102,126,234,.3)}}.sec{{background:rgba(255,255,255,.08);color:#ccc;border:1px solid rgba(255,255,255,.1)}}.fp{{margin-top:24px;text-align:left;font-size:13px}}.local-item{{background:rgba(0,0,0,.3);padding:8px 12px;border-radius:8px;margin-bottom:6px;word-break:break-all;cursor:pointer;transition:.2s}}.local-item:hover{{background:rgba(102,126,234,.2)}}.local-item code{{color:#667eea;font-size:12px}}</style>
<script>function copyText(text){{navigator.clipboard.writeText(text).then(()=>alert('已复制到剪贴板'))}}</script></head><body>
<div class="card"><div class="icon">{'🔐' if not expired else '⏳'}</div><h1>{rec.get('file','文档').split('/')[-1] if rec else '公文下载'}</h1>
<p class="sub">{'请输入6位临时密码，5分钟内有效' if not expired else '链接已过期'}</p>{err_html}{form_html}<div class="fp">{local_html}</div></div></body></html>""")

# ---------- FastAPI 应用 ----------
app = FastAPI()
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

@app.on_event("startup")
def start_cleanup():
    threading.Thread(target=cleanup_loop, daemon=True).start()
    logging.info(f"服务启动，端口 {SVC['port']}")

@app.get("/ping")
def ping():
    return {"ok": True}

@app.get("/health")
def health():
    purge_expired()
    with LOCK:
        total = len(TOKENS)
    stat = os.statvfs(LOCAL)
    free_mb = (stat.f_bavail * stat.f_frsize) // (1024*1024)
    return {
        "ok": True,
        "active_tokens": total,
        "disk_free_mb": free_mb,
        "pdf_available": shutil.which("soffice") is not None
    }

@app.post("/api/register")
async def api_register(body: dict):
    """
    注册文件接口
    请求体：{"file": "/opt/lobster_docs/通知.docx"}
    返回下载链接（不带密码）和密码
    """
    fpath = Path(body["file"])
    # 安全校验在此处统一调用
    if not is_safe_path(fpath):
        raise HTTPException(400, "文件路径非法，仅允许访问指定目录下的文件")
    tok, pwd = register_file(fpath)
    links = {}
    for key, url in [("lan", URLS["lan"]), ("wan", URLS["wan"])]:
        links[key] = f"{url}/dl?tok={tok}"
    return {
        "ok": True,
        "token": tok,
        "password": pwd,
        "expire_in": SEC["ttl_seconds"],
        "download_links": links,
        "local_path": str(fpath.resolve()),
        "pdf_available": os.path.isfile(fpath.with_suffix(".pdf"))
    }

@app.get("/dl")
def dl_page(tok: str = Query(...), pwd: str = Query(default="")):
    """下载页面，验证密码后提供 Word 文件"""
    with LOCK:
        rec = TOKENS.get(tok)
    if not rec or rec.get("used"):
        raise HTTPException(410, "链接已过期或已使用")
    if time.time() > rec["exp"]:
        with LOCK:
            TOKENS.pop(tok, None)
        return download_page(tok, expired=True)
    if not pwd:
        return download_page(tok, rec)
    if pwd != rec["pwd"]:
        with LOCK:
            rec["fail"] += 1
            if rec["fail"] >= SEC["max_fail"]:
                TOKENS.pop(tok, None)
                return download_page(tok, error="密码错误次数过多，链接已作废", expired=True)
        return download_page(tok, rec, error="密码错误")
    # 验证成功，返回文件并删除 token（一次性使用）
    with LOCK:
        TOKENS.pop(tok, None)
    return FileResponse(rec["file"], filename=os.path.basename(rec["file"]))

@app.get("/dl/pdf")
def dl_pdf(tok: str = Query(...), pwd: str = Query(...)):
    """下载 PDF 文件"""
    with LOCK:
        rec = TOKENS.get(tok)
    if not rec or rec.get("used") or time.time() > rec["exp"]:
        raise HTTPException(410)
    if pwd != rec["pwd"]:
        with LOCK:
            rec["fail"] += 1
            if rec["fail"] >= SEC["max_fail"]:
                TOKENS.pop(tok, None)
        raise HTTPException(403, "密码错误")
    pdf = rec.get("pdf")
    if not pdf or not os.path.isfile(pdf):
        raise HTTPException(404, "PDF 文件不存在")
    with LOCK:
        TOKENS.pop(tok, None)
    return FileResponse(pdf, filename=os.path.basename(pdf))

if __name__ == "__main__":
    uvicorn.run(app, host=SVC["bind"], port=SVC["port"])
PYEOF

# =============================================================================
#  公文生成器（build_docx.py）—— 跨平台日期、增强表格支持
# =============================================================================
info "生成公文构建脚本..."

cat > build_docx.py <<'PYEOF'
#!/usr/bin/env python3
"""
build_docx.py — 生成符合 GB/T 9704 的公文 Word/PDF
v2.3 改进：跨平台日期格式、结构化内容支持、附件、表格、红头自动嵌入
"""
import argparse, json, os, sys, subprocess
from pathlib import Path
from datetime import datetime
from docx import Document
from docx.shared import Pt, Cm, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.oxml.ns import qn, nsdecls
from docx.oxml import parse_xml
import yaml

# ---------- 工具函数 ----------
def set_font(run, name, size, bold=False, color=None):
    """设置字体属性，同时指定西文和中文字体"""
    run.font.name = name
    run.font.size = Pt(size)
    run.font.bold = bold
    if color:
        run.font.color.rgb = RGBColor(*color)
    rPr = run._element.get_or_add_rPr()
    rPr.rFonts.set(qn('w:eastAsia'), name)

def ensure_normal(doc, font):
    """设置正文默认样式"""
    s = doc.styles['Normal']
    s.font.name = font
    s.font.size = Pt(16)
    rPr = s.element.get_or_add_rPr()
    rPr.rFonts.set(qn('w:eastAsia'), font)

def add_red_header(section, img_path):
    """在页眉插入红头图片，失败则返回 False"""
    if not os.path.isfile(img_path):
        return False
    header = section.header
    para = header.paragraphs[0] if header.paragraphs else header.add_paragraph()
    # 清理多余的段落
    for p in header.paragraphs[1:]:
        p._element.getparent().remove(p._element)
    para.paragraph_format.space_before = Pt(0)
    para.paragraph_format.space_after = Pt(0)
    para.paragraph_format.line_spacing = 1.0
    para.add_run().add_picture(img_path, width=Cm(17.0))
    para.alignment = WD_ALIGN_PARAGRAPH.CENTER
    section.header_distance = Cm(0.5)
    return True

def set_cell_shading(cell, color):
    """设置单元格底色"""
    shd = parse_xml(f'<w:shd {nsdecls("w")} w:fill="{color}"/>')
    cell._tc.get_or_add_tcPr().append(shd)

def add_attachments(doc, attachments, font):
    """添加附件列表"""
    if not attachments:
        return
    doc.add_paragraph()
    p = doc.add_paragraph()
    set_font(p.add_run("附件："), font, 16, bold=False)
    for i, att in enumerate(attachments, 1):
        pi = doc.add_paragraph()
        pi.paragraph_format.first_line_indent = Cm(0)
        set_font(pi.add_run(f"{i}. {att}"), font, 16)

def build_doc(cfg, title, content_blocks, attachments, sign_date, out_path):
    """主构建函数"""
    doc = Document()
    sec = doc.sections[0]
    sec.top_margin = Cm(3.7)
    sec.bottom_margin = Cm(3.5)
    sec.left_margin = Cm(2.8)
    sec.right_margin = Cm(2.6)
    sec.page_width = Cm(21.0)
    sec.page_height = Cm(29.7)

    body_font = cfg.get("fonts", {}).get("fallback_body", "FangSong")
    title_font = cfg.get("fonts", {}).get("fallback_title", "SimSun")
    ensure_normal(doc, body_font)

    # 红头
    img_rel = cfg.get("red_header", {}).get("image", "assets/red_header_bar.png")
    img_path = str(Path(__file__).parent / img_rel)
    if not add_red_header(sec, img_path):
        # 回退：纯文字红头
        p = doc.add_paragraph()
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        set_font(p.add_run(cfg["org"]["name"]), title_font, 22, bold=True)
        p2 = doc.add_paragraph()
        p2.alignment = WD_ALIGN_PARAGRAPH.CENTER
        set_font(p2.add_run("━" * 32), "SimSun", 14, color=(192, 0, 0))

    # 标题
    p_t = doc.add_paragraph()
    p_t.alignment = WD_ALIGN_PARAGRAPH.CENTER
    set_font(p_t.add_run(title), title_font, 22, bold=True)

    # 正文内容块
    for block in content_blocks:
        t = block.get("type", "body")
        text = block.get("text", "")
        if t == "title":
            p = doc.add_paragraph()
            p.alignment = WD_ALIGN_PARAGRAPH.CENTER
            set_font(p.add_run(text), title_font, 22, bold=True)
        elif t == "heading1":
            p = doc.add_paragraph()
            set_font(p.add_run(text), "黑体", 18, bold=True)
        elif t == "heading2":
            p = doc.add_paragraph()
            set_font(p.add_run(text), "楷体", 16, bold=True)
        elif t == "emphasis":
            p = doc.add_paragraph()
            p.paragraph_format.left_indent = Cm(0.8)
            set_font(p.add_run(text), body_font, 16, bold=True)
        elif t == "signature":
            p = doc.add_paragraph()
            p.alignment = WD_ALIGN_PARAGRAPH.RIGHT
            set_font(p.add_run(text), body_font, 16)
        elif t == "table":
            headers = block.get("headers", [])
            rows = block.get("rows", [])
            if headers and rows:
                tbl = doc.add_table(rows=1 + len(rows), cols=len(headers))
                tbl.style = 'Table Grid'
                tbl.alignment = WD_TABLE_ALIGNMENT.CENTER
                # 表头
                for i, h in enumerate(headers):
                    c = tbl.rows[0].cells[i]
                    c.text = h
                    for pp in c.paragraphs:
                        pp.alignment = WD_ALIGN_PARAGRAPH.CENTER
                        for r in pp.runs:
                            set_font(r, "黑体", 12, bold=True)
                    set_cell_shading(c, "D9E2F3")
                # 数据行
                for ri, rd in enumerate(rows):
                    for ci, v in enumerate(rd):
                        c = tbl.rows[ri + 1].cells[ci]
                        c.text = v
                        for pp in c.paragraphs:
                            for r in pp.runs:
                                set_font(r, body_font, 11)
                doc.add_paragraph()
        elif t == "main-to":
            p = doc.add_paragraph()
            set_font(p.add_run(text), body_font, 16)
            p.paragraph_format.first_line_indent = Cm(0)
            p.paragraph_format.line_spacing = Pt(28)
            p.alignment = WD_ALIGN_PARAGRAPH.JUSTIFY
        else:  # 普通正文
            p = doc.add_paragraph()
            set_font(p.add_run(text), body_font, 16)
            p.paragraph_format.first_line_indent = Cm(0.85)
            p.paragraph_format.line_spacing = Pt(28)
            p.alignment = WD_ALIGN_PARAGRAPH.JUSTIFY

    # 附件
    add_attachments(doc, attachments, body_font)

    # 落款
    p_s = doc.add_paragraph()
    p_s.alignment = WD_ALIGN_PARAGRAPH.RIGHT
    set_font(p_s.add_run(f"{cfg['org']['signatory']}\n{sign_date}"), body_font, 16)

    out = Path(out_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    doc.save(str(out))
    return str(out)

def to_pdf(docx_path):
    """调用 LibreOffice 转换为 PDF"""
    try:
        subprocess.run(
            ["soffice", "--headless", "--convert-to", "pdf",
             "--outdir", os.path.dirname(docx_path), docx_path],
            check=True, timeout=60,
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE
        )
        p = Path(docx_path).with_suffix(".pdf")
        if p.exists():
            return str(p)
        else:
            print("[warn] PDF 转换失败：未生成文件", file=sys.stderr)
            return None
    except subprocess.CalledProcessError as e:
        err = e.stderr.decode() if e.stderr else '未知错误'
        print(f"[warn] PDF 转换失败：{err}", file=sys.stderr)
        return None

# ---------- 命令行入口 ----------
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="生成公文 Word/PDF")
    parser.add_argument("--config", default="config.yaml", help="配置文件路径")
    parser.add_argument("--title", required=True, help="公文标题")
    parser.add_argument("--body", default="", help="纯文本正文（每行一段）")
    parser.add_argument("--body-json", default="", help="结构化正文 JSON 文件路径")
    parser.add_argument("--main-to", default="", help="主送机关")
    parser.add_argument("--attachments", nargs="*", default=[], help="附件名称列表")
    # 跨平台安全日期格式
    now = datetime.now()
    default_date = f"{now.year}年{now.month}月{now.day}日"
    parser.add_argument("--sign-date", default=default_date, help="落款日期")
    parser.add_argument("--out", required=True, help="输出 Word 路径")
    parser.add_argument("--pdf", action="store_true", help="同时生成 PDF")
    args = parser.parse_args()

    cfg = yaml.safe_load(Path(args.config).read_text(encoding="utf-8"))

    if args.body_json:
        blocks = json.loads(Path(args.body_json).read_text(encoding="utf-8"))
    else:
        blocks = []
        if args.main_to:
            blocks.append({"type": "main-to", "text": args.main_to})
        for line in args.body.split("\n"):
            line = line.strip()
            if line:
                blocks.append({"type": "body", "text": line})

    docx_path = build_doc(cfg, args.title, blocks, args.attachments, args.sign_date, args.out)
    result = {"ok": True, "docx": docx_path}
    if args.pdf:
        pdf_path = to_pdf(docx_path)
        result["pdf"] = pdf_path
    print(json.dumps(result, ensure_ascii=False))
PYEOF

# ---------- 红头图片生成器 ----------
cat > gen_red_header.py <<'PYEOF'
#!/usr/bin/env python3
"""
生成 GB/T 9704-2012 红头 PNG 模板
用法: python3 gen_red_header.py "机关名称"
"""
import sys
from PIL import Image, ImageDraw, ImageFont

WIDTH_PX = 794
HEADER_HEIGHT = 110
LINE_COLOR = (192, 0, 0)
TEXT_COLOR = (0, 0, 0)
BG_COLOR = (255, 255, 255, 0)

def find_font(size):
    """按优先级查找中文字体"""
    paths = [
        "/usr/share/fonts/chinese/SimSun.ttf",
        "/usr/share/fonts/chinese/FangSong_GB2312.ttf",
        "/usr/share/fonts/wqy-zenhei/wqy-zenhei.ttc",
        "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
        "/System/Library/Fonts/STSong.ttf",
        "/Library/Fonts/SimSun.ttf",
    ]
    for p in paths:
        try:
            return ImageFont.truetype(p, size)
        except Exception:
            continue
    return ImageFont.load_default()

def gen(org_name):
    img = Image.new("RGBA", (WIDTH_PX, HEADER_HEIGHT), BG_COLOR)
    draw = ImageDraw.Draw(img)
    font = find_font(26)
    bbox = draw.textbbox((0, 0), org_name, font=font)
    x = (WIDTH_PX - (bbox[2] - bbox[0])) // 2
    draw.text((x, 10), org_name, fill=TEXT_COLOR, font=font)
    draw.line([(50, 52), (WIDTH_PX - 50, 52)], fill=LINE_COLOR, width=2)
    out = "assets/red_header_bar.png"
    img.save(out)
    print(f"✅ 红头模板已生成：{out}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("用法: python3 gen_red_header.py \"机关名称\"")
        sys.exit(1)
    gen(sys.argv[1])
PYEOF

# ---------- 辅助文件 ----------
info "生成依赖清单及技能说明..."

cat > requirements.txt <<REQ
fastapi>=0.100.0
uvicorn[standard]>=0.20.0
python-docx>=1.0.0
pyyaml>=6.0
Pillow>=10.0
REQ

cat > SKILL.md <<'SKMD'
---
name: doc-export
description: 生成 GB/T 9704 公文 Word/PDF，提供安全一次性下载链接（6位密码，5分钟有效），支持结构化内容、附件、表格、红头图片自动生成。
trigger: 导出/生成/下发公文，下载文档
---
## 功能
1. 收集标题、正文（支持 Markdown 转结构化 JSON）、附件等。
2. 生成 .docx 和可选的 PDF。
3. 返回内网/外网一次性下载链接（不含密码），密码单独显示。
4. 自动清理过期文件。

## 调用示例
```bash
python3 build_docx.py --config config.yaml --title "关于XXX的通知" \
  --body-json /tmp/content.json --attachments "附件1：计划" --pdf \
  --out /opt/lobster_docs/通知.docx
SKMD

mkdir -p assets
cat > assets/README.md <<'RED'
将透明 PNG 保存为 red_header_bar.png（宽 794~1200px，高 80~130px）。
或运行 python3 gen_red_header.py "机关名称" 自动生成。
RED

info "安装 Python 依赖..."
pip3 install --user -r requirements.txt -q || error "依赖安装失败，请检查网络或手动执行: pip3 install --user -r requirements.txt"

if [ ! -f assets/red_header_bar.png ]; then
warn "未找到 assets/red_header_bar.png"
read -p "是否现在生成红头图片？（需已安装 Pillow）[Y/n] " GEN
if [[ ! "
G
E
N
"
=
 
[
N
n
]
GEN"=  
[
 Nn] ]]; then
python3 gen_red_header.py "$ORG_NAME" || true
else
warn "红头图片将使用文字替代，不影响公文格式。"
fi
fi

read -p "是否安装 systemd 服务实现开机自启？[Y/n] " AUTO
if [[ ! "
A
U
T
O
"
=
 
[
N
n
]
AUTO"=  
[
 Nn] ]]; then
SERVICE="/etc/systemd/system/lobster-doc-export.service"
PY=
(
w
h
i
c
h
p
y
t
h
o
n
3
)
s
u
d
o
t
e
e
"
(whichpython3)sudotee"SERVICE" > /dev/null <<SYSD
[Unit]
Description=Lobster Doc Export Service
After=network.target

[Service]
Type=simple
User=
U
S
E
R
W
o
r
k
i
n
g
D
i
r
e
c
t
o
r
y
=
USERWorkingDirectory=SKILL_HOME
ExecStart=
P
Y
PYSKILL_HOME/server.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SYSD
sudo systemctl daemon-reload
sudo systemctl enable --now lobster-doc-export
info "服务已启动："
systemctl status lobster-doc-export --no-pager || true
else
warn "手动启动：cd $SKILL_HOME && python3 server.py &"
fi
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "
G
R
E
E
N
✅部署完成！（
v
2.3
修正增强版）
GREEN✅部署完成！（v2.3修正增强版）{NC}"
echo " 服务端口：
P
O
R
T
"
e
c
h
o
"
内网下载：
h
t
t
p
:
/
/
PORT"echo"内网下载：http://{INTRANET}:
P
O
R
T
/
d
l
"
e
c
h
o
"
外网下载：
h
t
t
p
:
/
/
PORT/dl"echo"外网下载：http://{EXTRANET}:
P
O
R
T
/
d
l
"
e
c
h
o
"
文件目录：
PORT/dl"echo"文件目录：{LOCAL}"
echo " 健康检查：curl http://127.0.0.1:${PORT}/health"
echo " 红头生成：cd {SKILL_HOME} && python3 gen_red_header.py \"{ORG_NAME}""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"











