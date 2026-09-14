#!/usr/bin/env bash
#
# newapi 一键部署 / 管理脚本（轻量服务器 / SQLite 版）
# 适用：1G 内存轻量服务器、国内网络
#
# 交互菜单： bash deploy.sh
# 单行命令： bash deploy.sh install|start|stop|restart|uninstall|update|status|logs|backup|address|port
#
# 特性：
#   - 菜单式管理：安装 / 启动 / 停止 / 重启 / 卸载 / 更新 / 状态 / 日志 / 备份 / 访问地址 / 修改端口
#   - 卸载可选连数据目录一起删除
#   - 自动检测 Docker 与系统发行版，按系统选择正确安装源（Ubuntu/Debian 走 apt、CentOS/RHEL 系走 yum/dnf、其他走官方脚本）
#   - SQLite 数据库（单文件，最省内存，1G 服务器无压力）
#   - 自动识别云厂商（腾讯云/阿里云，二者元数据地址互不相同可可靠识别）；识别不到则回落公共镜像，可用 NEWAPI_APT_MIRROR / NEWAPI_REGISTRY_MIRROR 指定任意云镜像
#   - 自动生成随机 SESSION_SECRET / CRYPTO_SECRET
#   - 镜像源按网络区域选择 + 拉取超时兜底：国内[阿里云→github.ai.plus→Docker Hub]，境外[Docker Hub→github.ai.plus]
#
# 环境变量：
#   NEWAPI_DIR   安装目录（默认 /opt/new-api）
#   NEWAPI_PORT  对外端口（默认 3000）
#   NEWAPI_REGION  cn/global（可跳过交互选择网络区域）
#   NEWAPI_APT_MIRROR   自定义 Docker 安装源 base，覆盖自动识别（如华为云：https://mirrors.huaweicloud.com/docker-ce/linux）
#   NEWAPI_REGISTRY_MIRROR  自定义 Docker 镜像加速地址，覆盖自动识别（如各云内网镜像 https://xxx.mirror.xxx.com）

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

# ---------- 系统识别 ----------
detect_distro() {
  DISTRO_ID="unknown"; DISTRO_LIKE=""; DISTRO_CODENAME=""
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_LIKE="${ID_LIKE:-}"
    DISTRO_CODENAME="${VERSION_CODENAME:-${VERSION_ID:-}}"
  fi
}

# ---------- 云厂商识别（用于选择同云内网镜像，加速安装） ----------
detect_cloud() {
  CLOUD="unknown"
  # 腾讯云元数据（仅腾讯云内网可达，超时即跳过）
  if curl -s --connect-timeout 2 -m 3 -o /dev/null "http://metadata.tencentyun.com/latest/meta-data/" 2>/dev/null; then
    CLOUD="tencent"
  # 阿里云元数据
  elif curl -s --connect-timeout 2 -m 3 -o /dev/null "http://100.100.100.200/latest/meta-data/" 2>/dev/null; then
    CLOUD="aliyun"
  fi
}

# 根据云厂商与区域返回 Docker apt 源 base（同云内网最快，识别不到回落公共/官方源）
docker_apt_base() {
  local id="$1"
  if [ -n "${NEWAPI_APT_MIRROR:-}" ]; then
    echo "${NEWAPI_APT_MIRROR%/}/$id"; return
  fi
  if [ "${REGION:-global}" != "cn" ]; then
    echo "https://download.docker.com/linux/$id"; return
  fi
  case "${CLOUD:-unknown}" in
    tencent) echo "https://mirrors.cloud.tencent.com/docker-ce/linux/$id" ;;
    *)       echo "https://mirrors.aliyun.com/docker-ce/linux/$id" ;;
  esac
}

docker_yum_repo() {
  if [ -n "${NEWAPI_APT_MIRROR:-}" ]; then
    echo "${NEWAPI_APT_MIRROR%/}/centos/docker-ce.repo"; return
  fi
  if [ "${REGION:-global}" != "cn" ]; then
    echo "https://download.docker.com/linux/centos/docker-ce.repo"; return
  fi
  case "${CLOUD:-unknown}" in
    tencent) echo "https://mirrors.cloud.tencent.com/docker-ce/linux/centos/docker-ce.repo" ;;
    *)       echo "https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo" ;;
  esac
}

docker_registry_mirrors() {
  if [ -n "${NEWAPI_REGISTRY_MIRROR:-}" ]; then
    echo "[\"${NEWAPI_REGISTRY_MIRROR}\"]"; return
  fi
  if [ "${REGION:-global}" != "cn" ]; then echo "[]"; return; fi
  case "${CLOUD:-unknown}" in
    tencent) echo '["https://mirror.ccs.tencentyun.com"]' ;;
    *)       echo '["https://docker.mirrors.ustc.edu.cn","https://hub-mirror.c.163.com"]' ;;
  esac
}

# ---------- Docker 安装（按系统选择正确源） ----------
install_docker_apt() {
  local id="$1" codename="$2"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  local arch; arch="$(dpkg --print-architecture)"
  local base; base="$(docker_apt_base "$id")"
  info "Docker apt 源: $base"
  if curl -fsSL "$base/gpg" -o /etc/apt/keyrings/docker.asc 2>/dev/null; then
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$arch signed-by=/etc/apt/keyrings/docker.asc] $base $codename stable" > /etc/apt/sources.list.d/docker.list
    if apt-get update -y && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
      return 0
    fi
  fi
  # 镜像源失败，回退官方源
  if [ "$base" != "https://download.docker.com/linux/$id" ]; then
    warn "镜像源安装失败，回退官方源 download.docker.com ..."
    base="https://download.docker.com/linux/$id"
    curl -fsSL "$base/gpg" -o /etc/apt/keyrings/docker.asc
    echo "deb [arch=$arch signed-by=/etc/apt/keyrings/docker.asc] $base $codename stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
}

install_docker_yum() {
  local repo; repo="$(docker_yum_repo)"
  info "Docker yum 源: $repo"
  if command -v dnf >/dev/null 2>&1; then
    dnf -y install dnf-plugins-core
    dnf config-manager --add-repo "$repo"
    dnf -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin
  else
    yum install -y yum-utils
    yum-config-manager --add-repo "$repo"
    yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  fi
}

install_docker_official() {
  info "未识别到受支持的包管理器，使用官方一键脚本安装..."
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh
}

install_docker() {
  detect_distro
  info "未检测到 Docker，开始安装（检测到系统: ${DISTRO_ID} ${DISTRO_CODENAME}）..."
  case "$DISTRO_ID" in
    ubuntu)          install_docker_apt ubuntu "$DISTRO_CODENAME" ;;
    debian)          install_docker_apt debian "$DISTRO_CODENAME" ;;
    linuxmint)       install_docker_apt ubuntu "$DISTRO_CODENAME" ;;
    kali)            install_docker_apt debian "$DISTRO_CODENAME" ;;
    centos|rhel|rocky|almalinux|fedora|anolis|openanolis|ol)
                     install_docker_yum ;;
    *)
      case "$DISTRO_LIKE" in
        *debian*) install_docker_apt debian "$DISTRO_CODENAME" ;;
        *rhel*|*fedora*) install_docker_yum ;;
        *) install_docker_official ;;
      esac ;;
  esac
  # 配置镜像加速（仅国内）：优先同云内网镜像，加速 Docker Hub 拉取；并启动
  mkdir -p /etc/docker
  local mirrors; mirrors="$(docker_registry_mirrors)"
  cat > /etc/docker/daemon.json <<EOF
{
  "registry-mirrors": $mirrors
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
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y && apt-get install -y docker-compose-plugin
    elif command -v dnf >/dev/null 2>&1; then
      dnf -y install docker-compose-plugin
    elif command -v yum >/dev/null 2>&1; then
      yum install -y docker-compose-plugin
    fi
    if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
      curl -fsSL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 -o /usr/local/bin/docker-compose
      chmod +x /usr/local/bin/docker-compose
    fi
  fi
}

# ---------- 镜像选择（按网络区域决定候选 + 拉取超时兜底） ----------
choose_region() {
  [ -n "${REGION:-}" ] && return   # 幂等：只问一次（do_install 与 detect_image 都可能调用）
  REGION="${NEWAPI_REGION:-}"
  if [ -z "$REGION" ]; then
    if [ -t 1 ]; then
      read -r -p "服务器网络区域？[1]国内  [2]境外(默认): " r </dev/tty
      case "$r" in
        1) REGION=cn ;;
        *) REGION=global ;;
      esac
    else
      REGION=global   # 非交互（无终端）默认境外策略：直连 Docker Hub，避免慢国内源
    fi
  fi
}

image_candidates() {
  if [ "${REGION:-global}" != "cn" ]; then
    CANDIDATES=( "calciumion/new-api:latest"
                 "github.ai.plus/quantumous/new-api:latest" )
    return
  fi
  if [ "${CLOUD:-unknown}" = "aliyun" ]; then
    # 阿里云：同网络优先阿里云容器镜像
    CANDIDATES=( "registry.cn-hangzhou.aliyuncs.com/quantumous/new-api:latest"
                 "calciumion/new-api:latest"
                 "github.ai.plus/quantumous/new-api:latest" )
  else
    # 腾讯云/其他云：靠同云或公共镜像加速 Docker Hub，故优先官方 Docker Hub 镜像
    CANDIDATES=( "calciumion/new-api:latest"
                 "registry.cn-hangzhou.aliyuncs.com/quantumous/new-api:latest"
                 "github.ai.plus/quantumous/new-api:latest" )
  fi
}

PULL_TIMEOUT=120
detect_image() {
  image_candidates
  IMAGE=""
  for img in "${CANDIDATES[@]}"; do
    info "尝试拉取镜像: $img"
    if timeout "$PULL_TIMEOUT" docker pull "$img" >/dev/null 2>&1; then IMAGE="$img"; info "镜像可用: $IMAGE"; break
    else warn "拉取失败或超时（${PULL_TIMEOUT}s），尝试下一个"; fi
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
  detect_cloud
  if [ -n "${NEWAPI_APT_MIRROR:-}" ] || [ -n "${NEWAPI_REGISTRY_MIRROR:-}" ]; then
    info "使用自定义镜像源覆盖：apt=${NEWAPI_APT_MIRROR:-默认} registry=${NEWAPI_REGISTRY_MIRROR:-默认}"
  fi
  info "检测到云环境: ${CLOUD:-unknown}"
  choose_region
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
      test: ['CMD-SHELL', 'wget -q -O - http://localhost:3000/api/status || exit 1']
      interval: 30s
      timeout: 10s
      retries: 3
EOF
  cat > "$ENV_FILE" <<EOF
PORT=${PORT}
REGION=${REGION}
EOF
  info "启动 new-api（端口 ${PORT}）..."
  if ! dc up -d; then
    error "启动失败，请运行「8 日志」或 cd $INSTALL_DIR && dc logs 查看。"
    return 1
  fi
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
  read -r -p "确认卸载 new-api（停止并移除容器与镜像）？[y/N]: " ans </dev/tty
  case "$ans" in
    y|Y)
      dc down --rmi local -v
      read -r -p "是否同时删除数据目录（$INSTALL_DIR，含数据库/日志）？[y/N]: " del </dev/tty
      case "$del" in
        y|Y) rm -rf "$INSTALL_DIR"; info "已卸载并删除数据目录 $INSTALL_DIR。";;
        *) info "已卸载，数据目录已保留（如需彻底删除：rm -rf $INSTALL_DIR）。";;
      esac
      ;;
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

do_change_port() {
  require_stack || return 1
  cd "$INSTALL_DIR"
  load_port
  local newport
  read -r -p "当前宿主机端口为 $PORT，请输入新端口 (1-65535): " newport </dev/tty
  if ! [[ "$newport" =~ ^[0-9]+$ ]] || [ "$newport" -lt 1 ] || [ "$newport" -gt 65535 ]; then
    error "端口无效，请输入 1-65535 之间的数字。"; return 1
  fi
  [ "$newport" = "$PORT" ] && { info "端口未变，无需修改。"; return 0; }
  if dc ps -q new-api >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":$newport "; then
    error "端口 $newport 已被占用，请换一个。"; return 1
  fi
  sed -i "s/^- '[0-9]*:3000'/- '$newport:3000'/" docker-compose.yml
  echo "PORT=$newport" > "$ENV_FILE"
  dc up -d
  sleep 2
  info "端口已修改为 $newport，访问地址: http://$(curl -fsSL ipinfo.io/ip 2>/dev/null || hostname -I | awk '{print $1}'):$newport"
}

# ---------- 菜单 ----------
show_menu() {
  echo
  echo -e "${CYAN}====== newapi 管理菜单 ======${NC}"
  echo " 1) 安装       2) 启动       3) 停止"
  echo " 4) 重启       5) 卸载       6) 更新(升级)"
  echo " 7) 状态       8) 日志       9) 备份数据"
  echo "10) 访问地址   11) 修改端口   0) 退出"
  echo -e "${CYAN}=============================${NC}"
}

# 单行命令模式： bash deploy.sh <action>
if [ -n "${1:-}" ]; then
  case "$1" in
    install|start|stop|restart|uninstall|update|status|logs|backup|address|port) "do_$1" ;;
    *) error "未知操作: $1（可选: install/start/stop/restart/uninstall/update/status/logs/backup/address/port）"; exit 1 ;;
  esac
  exit 0
fi

while true; do
  show_menu
  read -r -p "请选择 [0-11]: " c </dev/tty
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
    11) do_change_port ;;
    0|q|Q) info "退出。"; exit 0 ;;
    *) warn "无效选择，请输入 0-11。" ;;
  esac
done
