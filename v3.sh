#!/bin/bash

# ==================================================
# 定制版 AList 安装/管理脚本
# 源: ffdsghhf/alist GitHub Releases
# 特性:
# - 交互式菜单
# - 优先安装 Musl 版本 (最佳兼容性)
# - Musl 下载失败时自动尝试 glibc 版本
# - 支持 GitHub 代理 (GH_PROXY 环境变量)
# - 支持命令行直接操作 (install/update/uninstall)
# ==================================================

# --- 配置 ---
DEFAULT_INSTALL_PATH_BASE='/opt/alist'
# 默认版本 (硬编码 Tag，每次发布新版需更新这里，或后续改成动态获取)
DEFAULT_VERSION='latest' # !!! 请确保这里是你想要默认安装的 Tag !!!
GITHUB_REPO="ffdsghhf/alist"

# --- 全局变量 ---
INSTALL_PATH_BASE="$DEFAULT_INSTALL_PATH_BASE"
BINARY_INSTALL_PATH=""
DATA_DIR=""
ARCH="UNKNOWN"
VERSION="$DEFAULT_VERSION" # 初始版本，可被 -v 参数覆盖
SKIP_CONFIRM='false'
FORCE_INSTALL='false'
SERVICE_NAME="alist"
# GitHub 代理, 用户可通过环境变量 GH_PROXY 设置, 例如 export GH_PROXY='https://ghproxy.com/'
GH_PROXY="${GH_PROXY:-}" # 如果环境变量未设置则为空

# --- 颜色定义 ---
RED_COLOR='\e[1;31m'
GREEN_COLOR='\e[1;32m'
YELLOW_COLOR='\e[1;33m'
BLUE_COLOR='\e[1;34m'
RES='\e[0m'

# --- 函数定义 ---

print_error() {
  echo -e "\r\n${RED_COLOR}错误： $1${RES}\r\n" >&2
}

print_success() {
  echo -e "${GREEN_COLOR}$1${RES}"
}

print_warning() {
  echo -e "${YELLOW_COLOR}$1${RES}"
}

# 解析命令行参数 (用于 install/update/uninstall 等直接命令)
parse_args() {
  # $1 是操作命令 (install/update/uninstall), 从 $2 开始解析参数
  shift # 移除操作命令本身
  while [[ $# -gt 0 ]]; do
    case $1 in
      -p|--path)
        INSTALL_PATH_BASE="$2"
        if [[ "$INSTALL_PATH_BASE" != /* ]]; then print_error "安装路径 '$INSTALL_PATH_BASE' 必须是绝对路径。"; exit 1; fi
        INSTALL_PATH_BASE="${INSTALL_PATH_BASE%/}"
        shift 2 ;;
      -v|--version)
        VERSION="$2"
        shift 2 ;;
      -y|--yes)
        SKIP_CONFIRM='true'
        shift ;;
      --forced)
        FORCE_INSTALL='true'
        shift ;;
      *) print_error "未知参数: $1"; exit 1 ;;
    esac
  done
  # 设置最终路径
  BINARY_INSTALL_PATH="${INSTALL_PATH_BASE}/alist"
  DATA_DIR="${INSTALL_PATH_BASE}/data"
}

# 检查环境
check_environment() {
  print_success "检查运行环境..."
  if [ "$(id -u)" != "0" ]; then print_error "此脚本需要以 root 权限运行。"; exit 1; fi

  # 获取架构
  if command -v arch >/dev/null 2>&1; then platform=$(arch); else platform=$(uname -m); fi
  case "$platform" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    armv7l) ARCH=armv7 ;;
    arm) ARCH=armv6 ;; # 假设 arm 代表 v6
    *) ARCH="UNKNOWN" ;;
  esac
  if [ "$ARCH" == "UNKNOWN" ]; then print_error "不支持的系统架构 '$platform'。"; exit 1; fi
  print_success "系统架构: $ARCH"

  if ! command -v systemctl >/dev/null 2>&1; then print_error "未检测到 systemd。"; exit 1; fi
  if ! command -v curl &> /dev/null && ! command -v wget &> /dev/null; then print_error "需要安装 curl 或 wget。"; exit 1; fi
  if curl --help | grep progress-bar >/dev/null 2>&1; then CURL_BAR="--progress-bar"; fi
}

# 检查安装状态和端口
check_installation() {
  print_success "检查现有安装和端口..."
  if [ -f "$BINARY_INSTALL_PATH" ] && [ "$FORCE_INSTALL" = 'false' ]; then
    print_error "路径 '$BINARY_INSTALL_PATH' 已存在文件。请使用 'update' 或 '--forced' 或 '-p' 指定新路径。"
    # 在菜单模式下不退出，让用户可以选择其他操作
    if [[ "$COMMAND_MODE" == "true" ]]; then exit 1; fi
    return 1
  fi

  local check_port_cmd="" # 端口检查逻辑... (保持不变)
  if command -v ss >/dev/null 2>&1; then check_port_cmd="ss -ltn | grep -q ':5244\s'";
  elif command -v netstat >/dev/null 2>&1; then check_port_cmd="netstat -lnt | grep -q ':5244\s'";
  else print_warning "无法检查端口占用，请手动确认。"; fi
  if [ -n "$check_port_cmd" ] && eval "$check_port_cmd"; then print_warning "端口 5244 可能已被占用。"; fi

  if [ "$FORCE_INSTALL" = 'true' ]; then # 强制安装处理... (保持不变)
    if systemctl is-active --quiet "$SERVICE_NAME"; then print_warning "停止现有服务..."; systemctl stop "$SERVICE_NAME" || true; fi
    if [ -d "$INSTALL_PATH_BASE" ]; then print_warning "强制模式：删除目录 $INSTALL_PATH_BASE ..."; rm -rf "$INSTALL_PATH_BASE"; fi
  fi
  return 0 # 表示检查通过或在菜单模式下允许继续
}

# 下载并解压 AList (核心修改：Musl 优先 + glibc 回退)
download_and_extract() {
  print_success "准备下载 AList $VERSION ($ARCH)..."

  local filename_base="alist-linux"
  local filename_suffix="${ARCH}.tar.gz"
  local filename_musl="${filename_base}-musl-${filename_suffix}"
  local filename_glibc="${filename_base}-${filename_suffix}" # 标准 glibc 文件名

  # 优先尝试 Musl URL
  local download_url_musl="${GH_PROXY}https://github.com/${GITHUB_REPO}/releases/download/${VERSION}/${filename_musl}"
  local temp_tarball_musl="/tmp/alist-${VERSION}-musl-${ARCH}.tar.gz"

  # 备用 glibc URL
  local download_url_glibc="${GH_PROXY}https://github.com/${GITHUB_REPO}/releases/download/${VERSION}/${filename_glibc}"
  local temp_tarball_glibc="/tmp/alist-${VERSION}-${ARCH}.tar.gz" # 注意临时文件名不同

  local download_url=""
  local temp_tarball=""
  local downloaded_type="" # 记录下载成功的类型

  # 尝试下载 Musl
  print_success "尝试下载 Musl 版本: $download_url_musl"
  if command -v curl &> /dev/null; then
    curl -L -f -o "$temp_tarball_musl" "$download_url_musl" $CURL_BAR # -f 使 curl 在 HTTP 错误时失败
  else
    wget -O "$temp_tarball_musl" "$download_url_musl" --progress=bar:force 2>&1
  fi

  if [ $? -eq 0 ]; then
    # Musl 下载成功
    download_url="$download_url_musl"
    temp_tarball="$temp_tarball_musl"
    downloaded_type="Musl"
    print_success "Musl 版本下载成功。"
    rm -f "$temp_tarball_glibc" # 清理可能存在的 glibc 临时文件
  else
    # Musl 下载失败，尝试 glibc
    print_warning "Musl 版本下载失败，尝试下载标准 glibc 版本..."
    rm -f "$temp_tarball_musl" # 清理失败的 Musl 临时文件
    print_success "尝试下载 glibc 版本: $download_url_glibc"
    if command -v curl &> /dev/null; then
      curl -L -f -o "$temp_tarball_glibc" "$download_url_glibc" $CURL_BAR
    else
      wget -O "$temp_tarball_glibc" "$download_url_glibc" --progress=bar:force 2>&1
    fi

    if [ $? -eq 0 ]; then
      # glibc 下载成功
      download_url="$download_url_glibc"
      temp_tarball="$temp_tarball_glibc"
      downloaded_type="glibc"
      print_success "标准 glibc 版本下载成功。"
    else
      # 两者都失败
      print_error "下载失败，Musl 和 glibc 版本均无法下载。请检查版本号 '$VERSION' 是否存在于 Release，以及对应的附件是否存在。"
      rm -f "$temp_tarball_glibc"
      exit 1
    fi
  fi

  # 创建目录
  mkdir -p "$INSTALL_PATH_BASE"
  local temp_extract_dir="/tmp/alist_extracted_$$"
  mkdir -p "$temp_extract_dir"

  # 解压
  print_success "正在解压文件 ($downloaded_type 版本)..."
  tar -zxvf "$temp_tarball" -C "$temp_extract_dir"
  if [ $? -ne 0 ]; then print_error "解压失败。"; rm -f "$temp_tarball"; rm -rf "$temp_extract_dir"; exit 1; fi

  # 移动和设置权限
  if [ ! -f "$temp_extract_dir/alist" ]; then print_error "解压后未找到 'alist' 文件。"; rm -f "$temp_tarball"; rm -rf "$temp_extract_dir"; exit 1; fi
  mv "$temp_extract_dir/alist" "$BINARY_INSTALL_PATH"
  chmod +x "$BINARY_INSTALL_PATH"
  print_success "二进制文件 ($downloaded_type 版本) 已安装到 $BINARY_INSTALL_PATH"

  # 清理
  rm -f "$temp_tarball"
  rm -rf "$temp_extract_dir"
}

# 配置 Systemd 服务
setup_systemd() {
  # ... (setup_systemd 函数内容保持不变) ...
  print_success "配置 systemd 服务..."
  local service_file_path="/etc/systemd/system/${SERVICE_NAME}.service"
  mkdir -p "$DATA_DIR"
  cat << EOF > "$service_file_path"
[Unit]
Description=AList Service (Custom Build from ${GITHUB_REPO})
After=network.target network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
Group=root
WorkingDirectory=${INSTALL_PATH_BASE}
ExecStart=${BINARY_INSTALL_PATH} server --data ${DATA_DIR}
Restart=on-failure
RestartSec=5
#LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
  print_success "Systemd 服务文件已创建: $service_file_path"
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || print_warning "启用服务失败 (可能已启用)"
  systemctl restart "$SERVICE_NAME"
  sleep 2
  if systemctl is-active --quiet "$SERVICE_NAME"; then print_success "AList 服务已成功启动。";
  else print_error "AList 服务启动失败，请查日志。"; exit 1; fi
}

# 显示成功信息
show_success_message() {
  # ... (show_success_message 函数内容保持不变, 只需确保路径正确) ...
  clear
  print_success "定制版 AList 安装成功！"
  echo -e "\r\n访问地址：${GREEN_COLOR}http://<你的服务器IP>:5244/${RES}\r\n"
  echo -e "安装路径：${GREEN_COLOR}${INSTALL_PATH_BASE}${RES}"
  echo -e "数据目录：${GREEN_COLOR}${DATA_DIR}${RES}"
  echo -e "配置文件：${GREEN_COLOR}${DATA_DIR}/config.json${RES}"
  echo ""; print_warning "---------如何获取管理员密码？---------";
  echo -e "方法一：查看首次启动日志 (推荐):"; echo -e "  ${GREEN_COLOR}journalctl -u ${SERVICE_NAME} --no-pager | grep password${RES}";
  echo -e "方法二：手动重置 (服务运行时):"; echo -e "  ${GREEN_COLOR}cd ${INSTALL_PATH_BASE} && ./alist admin random${RES} (生成随机密码)";
  echo -e "  ${GREEN_COLOR}cd ${INSTALL_PATH_BASE} && ./alist admin set NEW_PASSWORD${RES} (设置新密码)";
  echo -e "------------------------------------"; echo ""; print_success "服务管理命令:";
  echo -e "  启动: ${GREEN_COLOR}systemctl start ${SERVICE_NAME}${RES}"; echo -e "  停止: ${GREEN_COLOR}systemctl stop ${SERVICE_NAME}${RES}";
  echo -e "  重启: ${GREEN_COLOR}systemctl restart ${SERVICE_NAME}${RES}"; echo -e "  状态: ${GREEN_COLOR}systemctl status ${SERVICE_NAME}${RES}";
  echo -e "  日志: ${GREEN_COLOR}journalctl -u ${SERVICE_NAME}${RES}"; echo "";
  print_warning "!!! 重要安全提示：服务默认以 root 运行，建议创建专用用户并修改服务配置。!!!"; echo "";
}

# 卸载函数
uninstall() {
  # ... (uninstall 函数内容保持不变) ...
  print_warning "准备卸载 AList..."
  if systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
    print_success "停止并禁用服务..."; systemctl stop "$SERVICE_NAME" || true; systemctl disable "$SERVICE_NAME" || true;
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"; systemctl daemon-reload; print_success "服务已移除。";
  else print_warning "未找到服务文件。"; fi
  print_success "删除安装目录: $INSTALL_PATH_BASE ...";
  if [ -d "$INSTALL_PATH_BASE" ]; then rm -rf "$INSTALL_PATH_BASE"; print_success "目录已删除。";
  else print_warning "安装目录未找到。"; fi
  print_success "AList 卸载完成。"
  ( sleep 2 && rm -f "/path/to/install.sh" ) > /dev/null 2>&1 &
}

# 更新函数
update() {
  # ... (update 函数内容，注意 download_and_extract 已包含 Musl/glibc 逻辑) ...
  print_success "准备更新 AList..."
  if [ ! -f "$BINARY_INSTALL_PATH" ]; then print_error "未找到 AList，请先安装。"; exit 1; fi
  if ! systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then print_error "未找到服务，无法更新。"; exit 1; fi
  print_success "停止当前服务..."; systemctl stop "$SERVICE_NAME" || print_warning "停止服务失败。";
  local backup_path="/tmp/alist.bak.$$"
  print_success "备份当前二进制文件到 $backup_path ..."; cp "$BINARY_INSTALL_PATH" "$backup_path";
  print_success "开始下载新版本 $VERSION ...";
  # 调用包含 Musl/glibc 回退逻辑的下载函数
  download_and_extract
  print_success "启动更新后的服务..."; systemctl start "$SERVICE_NAME"; sleep 2;
  if systemctl is-active --quiet "$SERVICE_NAME"; then print_success "AList 更新成功并已启动！"; rm -f "$backup_path";
  else print_error "服务启动失败！尝试回滚..."; mv "$backup_path" "$BINARY_INSTALL_PATH"; systemctl start "$SERVICE_NAME"; print_error "已回滚。更新失败。"; exit 1; fi
  echo ""; print_warning "建议检查后台配置是否兼容新版本。"; echo "";
}

# --- 新增：交互式菜单相关函数 ---
show_menu() {
    clear
    echo -e "${BLUE_COLOR}=========================================${RES}"
    echo -e "${GREEN_COLOR}    欢迎使用 定制版 AList 管理脚本      ${RES}"
    echo -e "${BLUE_COLOR}=========================================${RES}"
    echo -e " ${YELLOW_COLOR}仓库:${RES} ${GITHUB_REPO}"
    echo -e " ${YELLOW_COLOR}当前安装路径:${RES} ${INSTALL_PATH_BASE}"
    echo -e "${BLUE_COLOR}-----------------------------------------${RES}"
    echo -e " ${GREEN_COLOR}1.${RES} 安装 Alist (默认版本: $DEFAULT_VERSION)"
    echo -e " ${GREEN_COLOR}2.${RES} 更新 Alist (更新到版本: $VERSION)"
    echo -e " ${GREEN_COLOR}3.${RES} 卸载 Alist"
    echo -e "${BLUE_COLOR}-----------------------------------------${RES}"
    echo -e " ${GREEN_COLOR}4.${RES} 查看 Alist 状态"
    echo -e " ${GREEN_COLOR}5.${RES} 重置管理员密码"
    echo -e "${BLUE_COLOR}-----------------------------------------${RES}"
    echo -e " ${GREEN_COLOR}6.${RES} 启动 Alist 服务"
    echo -e " ${GREEN_COLOR}7.${RES} 停止 Alist 服务"
    echo -e " ${GREEN_COLOR}8.${RES} 重启 Alist 服务"
    echo -e "${BLUE_COLOR}-----------------------------------------${RES}"
    echo -e " ${GREEN_COLOR}0.${RES} 退出脚本"
    echo -e "${BLUE_COLOR}=========================================${RES}"
    echo
}

show_status() {
    print_success "获取 Alist 服务状态..."
    systemctl status "$SERVICE_NAME" --no-pager
}

reset_password() {
    if [ ! -f "$BINARY_INSTALL_PATH" ]; then print_error "未找到 AList，请先安装。"; return; fi
    print_warning "您可以通过以下方式重置密码："
    echo -e "  1. 生成随机密码: ${GREEN_COLOR}cd ${INSTALL_PATH_BASE} && ./alist admin random${RES}"
    echo -e "  2. 手动设置密码: ${GREEN_COLOR}cd ${INSTALL_PATH_BASE} && ./alist admin set NEW_PASSWORD${RES} (替换 NEW_PASSWORD)"
    read -p "请选择操作方式 (输入 1 或 2，其他取消): " choice
    if [ "$choice" == "1" ]; then
        cd "$INSTALL_PATH_BASE" && "$BINARY_INSTALL_PATH" admin random
    elif [ "$choice" == "2" ]; then
        read -p "请输入新密码: " new_password
        if [ -n "$new_password" ]; then
            cd "$INSTALL_PATH_BASE" && "$BINARY_INSTALL_PATH" admin set "$new_password"
        else
            print_error "密码不能为空！"
        fi
    else
        echo "已取消密码重置。"
    fi
    read -p "按 Enter键 返回菜单..." # 暂停一下让用户看到结果
}

start_service() {
    print_success "尝试启动 Alist 服务..."
    systemctl start "$SERVICE_NAME"
    sleep 1
    show_status
}

stop_service() {
    print_success "尝试停止 Alist 服务..."
    systemctl stop "$SERVICE_NAME"
    sleep 1
    show_status
}

restart_service() {
    print_success "尝试重启 Alist 服务..."
    systemctl restart "$SERVICE_NAME"
    sleep 1
    show_status
}


# --- 主逻辑 ---

COMMAND_MODE="false" # 标记是否以直接命令模式运行

# 如果第一个参数是 install/update/uninstall，则认为是直接命令模式
if [[ "$1" == "install" || "$1" == "update" || "$1" == "uninstall" ]]; then
    COMMAND_MODE="true"
    action="$1"
    parse_args "$@" # 解析 $2 及之后的参数
else
    # 如果没有参数或参数不是已知命令，则进入菜单模式
    # 但仍然需要解析可能的 -p, -v 等参数来确定路径和版本
    parse_args "$@" # 这里会处理 -p, -v 但忽略非 install/update/uninstall 的 $1
fi

# 始终执行环境检查
check_environment

# 根据模式执行
if [[ "$COMMAND_MODE" == "true" ]]; then
    # 直接命令模式
    case "$action" in
        install)
            print_success "=== 开始安装 (命令模式) ==="
            if check_installation; then
                download_and_extract
                setup_systemd
                show_success_message
            fi
            ;;
        uninstall)
            print_success "=== 开始卸载 (命令模式) ==="
            uninstall
            ;;
        update)
            print_success "=== 开始更新 (命令模式) ==="
            update
            ;;
    esac
else
    # 交互式菜单模式
    while true; do
        show_menu
        read -p "请输入选项 [0-8]: " choice
        case "$choice" in
            1) # 安装
                FORCE_INSTALL='false' # 菜单安装默认不强制
                read -p "将安装到 '$INSTALL_PATH_BASE'. 确认? (y/N): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                  if check_installation; then download_and_extract && setup_systemd && show_success_message; fi
                else echo "安装已取消。"; fi
                read -p "按 Enter键 返回菜单..." ;;
            2) # 更新
                read -p "将更新到版本 '$VERSION'. 确认? (y/N): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then update; fi
                read -p "按 Enter键 返回菜单..." ;;
            3) # 卸载
                read -p "将卸载位于 '$INSTALL_PATH_BASE' 的 AList. 确认? (y/N): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then uninstall; fi
                read -p "按 Enter键 返回菜单..." ;;
            4) # 查看状态
                show_status; read -p "按 Enter键 返回菜单..." ;;
            5) # 重置密码
                reset_password ;; # 内部已有暂停
            6) # 启动服务
                start_service; read -p "按 Enter键 返回菜单..." ;;
            7) # 停止服务
                stop_service; read -p "按 Enter键 返回菜单..." ;;
            8) # 重启服务
                restart_service; read -p "按 Enter键 返回菜单..." ;;
            0) # 退出
                echo "退出脚本。" ; exit 0 ;;
            *) # 错误输入
                print_error "无效的选项，请输入 0 到 8 之间的数字。"; sleep 2 ;;
        esac
    done
fi

exit 0
