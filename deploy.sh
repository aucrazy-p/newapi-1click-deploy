#!/usr/bin/env bash
#
# newapi 一键部署 / 管理脚本（轻量服务器 / SQLite 版）
# 适用：1G 内存轻量服务器、国内网络
#
# 交互菜单： bash deploy.sh
# 单行命令： bash deploy.sh install|start|stop|restart|uninstall|update|status|logs|backup|address
#
# 特性：
#   - 菜单式管理：安装 / 启动 / 停止 / 重启 / 卸载 / 更新 / 状态 / 日志 / 备份 / 访问地址
#   - 自动检测 Docker，已装则跳过，未装则用国内镜像源安装
#   - SQLite 数据库（单文件，最省内存，1G 服务器无压力）
#   - 自动配置 Docker 国内镜像加速
#   - 自动生成随机 SESSION_SECRET / CRYPTO_SECRET
#   - 镜像源自动回退：阿里云 → github.ai.plus → Docker Hub
#
# 环境变量：
#   NEWAPI_DIR   安装目录（默认 /opt/new-api）
#   NEWAPI_PORT  对外端口（默认 3000）

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

[ "$(id -u)" -ne 0 ] && { error "请使用 root 运行（或 sudo bash deploy.sh）"; exit 1; }

INSTALL_DIR="${NEWAPI_DIR:-/opt/new-api}"
ENV_FILE="$INSTALL_DIR/.deploy.env"

# 兼容 docker compose 插件与老版 docker-compose 二进制
dc() {
  if docker compose version >/dev/null 2>&1; then docker compose "$@"
  else docker-compose "$@"; fi
}

# ---------- Docker 检测 / 安装 ----------
install_docker() {
  info "未检测到 Docker，开始安装（国内镜像源）..."
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://mirrors.cloud.tencent.com/docker-ce/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://mirrors.cloud.tencent.com/docker-ce/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  elif command -v yum >/dev/null 2>&1; then
    yum install -y yum-utils
    yum-config-manager --add-repo https://mirrors.cloud.tencent.com/docker-ce/linux/centos/docker-ce.repo
    yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  else
    curl -fsSL https://get.daocloud.io/docker | bash
  fi
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": [
    "https://mirror.ccs.tencentyun.com",
    "https://docker.m.daocloud.io"
  ]
}
EOF
  systemctl enable --now docker
  info "Docker 安装完成。"
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    info "已检测到 Docker，跳过安装。"
  else
    install_docker
  fi
  if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
    warn "docker compose 缺失，尝试补齐..."
    if command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y docker-compose-plugin
    elif command -v yum >/dev/null 2>&1; then yum install -y docker-compose-plugin; fi
    if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
      curl -fsSL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 -o /usr/local/bin/docker-compose
      chmod +x /usr/local/bin/docker-compose
    fi
  fi
}

# ---------- 镜像选择（按顺序回退） ----------
detect_image() {
  local cands=( "registry.cn-hangzhou.aliyuncs.com/quantumous/new-api:latest"
                "github.ai.plus/quantumous/new-api:latest"
                "calciumion/new-api:latest" )
  IMAGE=""
  for img in "${cands[@]}"; do
    info "尝试拉取镜像: $img"
    if docker pull "$img" >/dev/null 2>&1; then IMAGE="$img"; info "镜像可用: $IMAGE"; break
    else warn "拉取失败，尝试下一个"; fi
  done
  [ -z "$IMAGE" ] && { error "所有镜像源均失败，请检查网络后重试。"; return 1; }
  return 0
}

require_stack() {
  if [ ! -f "$INSTALL_DIR/docker-compose.yml" ]; then
    error "未找到 $INSTALL_DIR/docker-compose.yml，请先执行「1 安装」。"
    return 1
  fi
  return 0
}

load_port() {
  PORT=3000
  [ -f "$ENV_FILE" ] && . "$ENV_FILE"
  PORT="${PORT:-3000}"
}

# ---------- 各操作 ----------
do_install() {
  ensure_docker
  detect_image || return 1
  mkdir -p "$INSTALL_DIR"; cd "$INSTALL_DIR"
  local PORT="${NEWAPI_PORT:-3000}"
  local SESS CRYPTO
  SESS="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)"
  CRYPTO="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)"
  cat > docker-compose.yml <<EOF
services:
  new-api:
    image: ${IMAGE}
    container_name: new-api
    restart: always
    ports:
      - '${PORT}:3000'
    volumes:
      - ./data:/data
      - ./logs:/app/logs
    environment:
      - TZ=Asia/Shanghai
      - ERROR_LOG_ENABLED=true
      - SESSION_SECRET=${SESS}
      - CRYPTO_SECRET=${CRYPTO}
    healthcheck:
      test: ['CMD-SHELL', "wget -q -O - http://localhost:3000/api/status | grep -o '\"success\":\\s*true' || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
EOF
  echo "PORT=${PORT}" > "$ENV_FILE"
  info "启动 new-api（端口 ${PORT}）..."
  dc up -d
  sleep 3
  info "部署完成！访问: http://$(curl -fsSL ipinfo.io/ip 2>/dev/null || hostname -I | awk '{print $1}'):${PORT}"
  info "首次打开进入初始化页面，设置管理员账号密码即可。"
}

do_start()    { require_stack || return 1; cd "$INSTALL_DIR"; dc up -d; info "已启动。"; }
do_stop()     { require_stack || return 1; cd "$INSTALL_DIR"; dc stop; info "已停止（数据保留）。"; }
do_restart()  { require_stack || return 1; cd "$INSTALL_DIR"; dc restart; info "已重启。"; }
do_update()   { require_stack || return 1; cd "$INSTALL_DIR"; dc pull && dc up -d; info "已更新到最新镜像并重启。"; }
do_status()   { require_stack || return 1; cd "$INSTALL_DIR"; dc ps; }
do_logs()     { require_stack || return 1; cd "$INSTALL_DIR"; dc logs --tail=100 new-api; }
do_uninstall() {
  require_stack || return 1
  cd "$INSTALL_DIR"
  read -r -p "确认卸载？将停止并移除容器与镜像，数据目录 $INSTALL_DIR/data 保留 [y/N]: " ans
  case "$ans" in
    y|Y) dc down --rmi local -v; info "已卸载（数据目录已保留）。如需彻底删除：rm -rf $INSTALL_DIR";;
    *) info "已取消。";;
  esac
}
do_backup() {
  require_stack || return 1
  local dst="/opt/new-api-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar -czf "$dst" -C "$INSTALL_DIR" data logs 2>/dev/null && info "已备份到 $dst" || error "备份失败"
}
do_address() {
  load_port
  info "访问地址: http://$(curl -fsSL ipinfo.io/ip 2>/dev/null || hostname -I | awk '{print $1}'):${PORT}"
}

# ---------- 菜单 ----------
show_menu() {
  echo
  echo -e "${CYAN}====== newapi 管理菜单 ======${NC}"
  echo " 1) 安装       2) 启动       3) 停止"
  echo " 4) 重启       5) 卸载       6) 更新(升级)"
  echo " 7) 状态       8) 日志       9) 备份数据"
  echo "10) 访问地址    0) 退出"
  echo -e "${CYAN}=============================${NC}"
}

# 单行命令模式： bash deploy.sh <action>
if [ -n "${1:-}" ]; then
  case "$1" in
    install|start|stop|restart|uninstall|update|status|logs|backup|address) "do_$1" ;;
    *) error "未知操作: $1（可选: install/start/stop/restart/uninstall/update/status/logs/backup/address）"; exit 1 ;;
  esac
  exit 0
fi

while true; do
  show_menu
  read -r -p "请选择 [0-10]: " c
  case "$c" in
    1)  do_install ;;
    2)  do_start ;;
    3)  do_stop ;;
    4)  do_restart ;;
    5)  do_uninstall ;;
    6)  do_update ;;
    7)  do_status ;;
    8)  do_logs ;;
    9)  do_backup ;;
    10) do_address ;;
    0|q|Q) info "退出。"; exit 0 ;;
    *) warn "无效选择，请输入 0-10。" ;;
  esac
done
