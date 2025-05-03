#!/bin/bash

# ==================================================
# 定制版 AList 安装/更新/卸载脚本 (简化版，无菜单)
# 源: ffdsghhf/alist GitHub Releases
# 安装路径: /opt/alist
# 特性: Musl 优先 + glibc 回退, 支持 GitHub 代理
# ==================================================

# --- 配置 ---
DEFAULT_INSTALL_PATH_BASE='/opt/alist'
DEFAULT_VERSION='v3.44.0' # !!! 请确保这里是你想要默认安装/更新的 Tag !!!
GITHUB_REPO="ffdsghhf/alist"

# --- 全局变量 ---
INSTALL_PATH_BASE="$DEFAULT_INSTALL_PATH_BASE"
BINARY_INSTALL_PATH=""
DATA_DIR=""
ARCH="UNKNOWN"
VERSION="$DEFAULT_VERSION"
FORCE_INSTALL='false'
SERVICE_NAME="alist"
GH_PROXY="${GH_PROXY:-}"

RED_COLOR='\e[1;31m'; GREEN_COLOR='\e[1;32m'; YELLOW_COLOR='\e[1;33m'; RES='\e[0m'

# --- 函数定义 ---
print_error() { echo -e "\r\n${RED_COLOR}错误： $1${RES}\r\n" >&2; }
print_success() { echo -e "${GREEN_COLOR}$1${RES}"; }
print_warning() { echo -e "${YELLOW_COLOR}$1${RES}"; }

parse_args() {
  shift # 移除操作命令 install/update/uninstall
  while [[ $# -gt 0 ]]; do
    case $1 in
      -p|--path) INSTALL_PATH_BASE="$2"; if [[ "$INSTALL_PATH_BASE" != /* ]]; then print_error "路径 '$INSTALL_PATH_BASE' 需为绝对路径。"; exit 1; fi; INSTALL_PATH_BASE="${INSTALL_PATH_BASE%/}"; shift 2 ;;
      -v|--version) VERSION="$2"; shift 2 ;;
      -y|--yes) echo "警告：在此简化脚本中 -y 参数无效。"; shift ;; # -y 在无菜单脚本中通常无意义
      --forced) FORCE_INSTALL='true'; shift ;;
      *) print_error "未知参数: $1"; exit 1 ;;
    esac
  done
  BINARY_INSTALL_PATH="${INSTALL_PATH_BASE}/alist"; DATA_DIR="${INSTALL_PATH_BASE}/data";
}

check_environment() {
  print_success "检查环境..."; if [ "$(id -u)" != "0" ]; then print_error "需 root 权限。"; exit 1; fi
  if command -v arch >/dev/null 2>&1; then platform=$(arch); else platform=$(uname -m); fi
  case "$platform" in x86_64|amd64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;; armv7l) ARCH=armv7 ;; arm) ARCH=armv6 ;; *) ARCH="UNKNOWN" ;; esac
  if [ "$ARCH" == "UNKNOWN" ]; then print_error "不支持架构 '$platform'。"; exit 1; fi; print_success "架构: $ARCH"
  if ! command -v systemctl >/dev/null 2>&1; then print_error "需 systemd。"; exit 1; fi
  if ! command -v curl &> /dev/null && ! command -v wget &> /dev/null; then print_error "需 curl 或 wget。"; exit 1; fi
  if curl --help | grep progress-bar >/dev/null 2>&1; then CURL_BAR="--progress-bar"; fi
}

check_installation_for_install() {
  print_success "检查安装..."; if [ -f "$BINARY_INSTALL_PATH" ] && [ "$FORCE_INSTALL" = 'false' ]; then print_error "路径 '$BINARY_INSTALL_PATH' 已存在。使用 'update' 或 '--forced'。"; exit 1; fi
  # 端口检查等 (省略细节，按需添加)
  if [ "$FORCE_INSTALL" = 'true' ]; then # 强制安装处理
    if systemctl is-active --quiet "$SERVICE_NAME"; then print_warning "停止现有服务..."; systemctl stop "$SERVICE_NAME" || true; fi
    if [ -d "$INSTALL_PATH_BASE" ]; then print_warning "强制删除目录 $INSTALL_PATH_BASE ..."; rm -rf "$INSTALL_PATH_BASE"; fi
  fi
}

download_and_extract() {
  # ... (下载和解压逻辑，包含 Musl/glibc 回退，与之前版本相同) ...
  print_success "准备下载 AList $VERSION ($ARCH)..."
  local filename_base="alist-linux"; local filename_suffix="${ARCH}.tar.gz"
  local filename_musl="${filename_base}-musl-${filename_suffix}"; local filename_glibc="${filename_base}-${filename_suffix}"
  local download_url_musl="${GH_PROXY}https://github.com/${GITHUB_REPO}/releases/download/${VERSION}/${filename_musl}"
  local temp_tarball_musl="/tmp/alist-${VERSION}-musl-${ARCH}.tar.gz"
  local download_url_glibc="${GH_PROXY}https://github.com/${GITHUB_REPO}/releases/download/${VERSION}/${filename_glibc}"
  local temp_tarball_glibc="/tmp/alist-${VERSION}-${ARCH}.tar.gz"
  local download_url=""; local temp_tarball=""; local downloaded_type=""
  print_success "尝试下载 Musl: $download_url_musl"; if command -v curl &> /dev/null; then curl -L -f -o "$temp_tarball_musl" "$download_url_musl" $CURL_BAR; else wget -O "$temp_tarball_musl" "$download_url_musl" --progress=bar:force 2>&1; fi
  if [ $? -eq 0 ]; then download_url="$download_url_musl"; temp_tarball="$temp_tarball_musl"; downloaded_type="Musl"; print_success "Musl 下载成功。"; rm -f "$temp_tarball_glibc";
  else print_warning "Musl 下载失败，尝试 glibc..."; rm -f "$temp_tarball_musl"; print_success "尝试下载 glibc: $download_url_glibc"; if command -v curl &> /dev/null; then curl -L -f -o "$temp_tarball_glibc" "$download_url_glibc" $CURL_BAR; else wget -O "$temp_tarball_glibc" "$download_url_glibc" --progress=bar:force 2>&1; fi
    if [ $? -eq 0 ]; then download_url="$download_url_glibc"; temp_tarball="$temp_tarball_glibc"; downloaded_type="glibc"; print_success "glibc 下载成功。";
    else print_error "下载失败，版本 '$VERSION' 的 Musl 和 glibc 附件均无法下载。"; rm -f "$temp_tarball_glibc"; exit 1; fi; fi
  mkdir -p "$INSTALL_PATH_BASE"; local temp_extract_dir="/tmp/alist_extracted_$$"; mkdir -p "$temp_extract_dir"; print_success "解压 ($downloaded_type)..."; tar -zxvf "$temp_tarball" -C "$temp_extract_dir"
  if [ $? -ne 0 ]; then print_error "解压失败。"; rm -f "$temp_tarball"; rm -rf "$temp_extract_dir"; exit 1; fi
  if [ ! -f "$temp_extract_dir/alist" ]; then print_error "未找到 'alist' 文件。"; rm -f "$temp_tarball"; rm -rf "$temp_extract_dir"; exit 1; fi
  mv "$temp_extract_dir/alist" "$BINARY_INSTALL_PATH"; chmod +x "$BINARY_INSTALL_PATH"; print_success "二进制 ($downloaded_type) 已安装到 $BINARY_INSTALL_PATH"
  rm -f "$temp_tarball"; rm -rf "$temp_extract_dir";
}

setup_systemd() {
  # ... (Systemd 配置逻辑，与之前版本相同) ...
  print_success "配置 systemd..."; local service_file_path="/etc/systemd/system/${SERVICE_NAME}.service"; mkdir -p "$DATA_DIR";
  cat << EOF > "$service_file_path"
[Unit]
Description=AList Service (Custom Build from ${GITHUB_REPO})
After=network.target network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root; Group=root # 安全警告: 建议修改
WorkingDirectory=${INSTALL_PATH_BASE}
ExecStart=${BINARY_INSTALL_PATH} server --data ${DATA_DIR}
Restart=on-failure; RestartSec=5
#LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
  print_success "服务文件创建: $service_file_path"; systemctl daemon-reload; systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || print_warning "启用服务失败"; systemctl restart "$SERVICE_NAME"; sleep 2;
  if systemctl is-active --quiet "$SERVICE_NAME"; then print_success "服务已启动。"; else print_error "服务启动失败，请查日志。"; exit 1; fi
}

show_install_success() {
  print_success "定制版 AList 安装成功！"; echo -e "\r\n访问: ${GREEN_COLOR}http://<服务器IP>:5244/${RES}\r\n";
  echo -e "路径: ${GREEN_COLOR}${INSTALL_PATH_BASE}${RES}"; echo -e "数据: ${GREEN_COLOR}${DATA_DIR}${RES}"; echo "";
  print_warning "密码获取方式:"; print_warning " journalctl -u ${SERVICE_NAME} | grep password"; print_warning " 或 cd ${INSTALL_PATH_BASE} && ./alist admin random"; echo "";
}

uninstall() {
  # ... (卸载逻辑，与之前版本相同) ...
  print_warning "卸载 AList..."; if systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then print_success "停止并移除服务..."; systemctl stop "$SERVICE_NAME" || true; systemctl disable "$SERVICE_NAME" || true; rm -f "/etc/systemd/system/${SERVICE_NAME}.service"; systemctl daemon-reload; else print_warning "服务未找到。"; fi
  print_success "删除目录: $INSTALL_PATH_BASE ..."; if [ -d "$INSTALL_PATH_BASE" ]; then rm -rf "$INSTALL_PATH_BASE"; print_success "已删除。"; else print_warning "目录未找到。"; fi; print_success "卸载完成。"
}

update() {
  # ... (更新逻辑，与之前版本相同，内部调用 download_and_extract) ...
  print_success "更新 AList..."; if [ ! -f "$BINARY_INSTALL_PATH" ]; then print_error "未找到 AList。"; exit 1; fi; if ! systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then print_error "未找到服务。"; exit 1; fi
  print_success "停止服务..."; systemctl stop "$SERVICE_NAME" || print_warning "停止失败。"; local backup_path="/tmp/alist.bak.$$"
  print_success "备份到 $backup_path ..."; cp "$BINARY_INSTALL_PATH" "$backup_path"; print_success "下载新版 $VERSION ..."; download_and_extract
  print_success "启动服务..."; systemctl start "$SERVICE_NAME"; sleep 2;
  if systemctl is-active --quiet "$SERVICE_NAME"; then print_success "更新成功！"; rm -f "$backup_path"; else print_error "服务启动失败！回滚..."; mv "$backup_path" "$BINARY_INSTALL_PATH"; systemctl start "$SERVICE_NAME"; print_error "已回滚。更新失败。"; exit 1; fi
  echo ""; print_warning "建议检查后台配置兼容性。"; echo "";
}

# --- 主逻辑 ---
if [ -z "$1" ]; then
    print_error "需要提供操作命令: install, update, uninstall"
    echo "用法示例:"
    echo "  安装: bash $0 install [-v <版本>] [-p <路径>] [--forced]"
    echo "  更新: bash $0 update [-v <版本>]"
    echo "  卸载: bash $0 uninstall [-p <路径>]"
    exit 1
fi

action="$1"
parse_args "$@" # 会移除 $1
check_environment

case "$action" in
    install)
        check_installation_for_install
        download_and_extract
        setup_systemd
        show_install_success
        ;;
    uninstall)
        uninstall
        ;;
    update)
        update
        ;;
    *)
        print_error "未知操作: $action. 支持的操作: install, update, uninstall"
        exit 1
        ;;
esac

exit 0
