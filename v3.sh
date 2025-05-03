#!/bin/bash

# ==================================================
# 定制版 AList 安装脚本
# 修改自 AList 官方脚本
# 源: 你的 GitHub Fork Releases
# 安装路径: /opt/alist
# ==================================================

# --- 配置 ---
# 安装基础路径
# 用户可以通过 -p 参数覆盖，例如: bash install.sh install -p /my/custom/path
DEFAULT_INSTALL_PATH_BASE='/opt/alist'
# 要下载的版本标签 (默认 'latest'，会尝试下载 GitHub 上标记为 Latest 的 Release)
# 用户可以通过 -v 参数覆盖，例如: bash install.sh install -v v3.30.0-custom
VERSION='v3.44.0'
# 你的 GitHub 用户名/仓库名
GITHUB_REPO="ffdsghhf/alist"

# --- 全局变量 ---
INSTALL_PATH_BASE="$DEFAULT_INSTALL_PATH_BASE" # 实际安装基础路径
BINARY_INSTALL_PATH="" # 二进制文件完整路径
DATA_DIR=""          # 数据目录路径
ARCH="UNKNOWN"      # 系统架构
GH_PROXY=''         # GitHub 代理 (可选)
SKIP_CONFIRM='false' # 是否跳过确认 (用于自动化)
FORCE_INSTALL='false' # 是否强制安装 (覆盖旧版)
SERVICE_NAME="alist" # Systemd 服务名

RED_COLOR='\e[1;31m'
GREEN_COLOR='\e[1;32m'
YELLOW_COLOR='\e[1;33m'
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

# 解析命令行参数
parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -p|--path)
        INSTALL_PATH_BASE="$2"
        # 确保路径是绝对路径
        if [[ "$INSTALL_PATH_BASE" != /* ]]; then
          print_error "安装路径 '$INSTALL_PATH_BASE' 必须是绝对路径。"
          exit 1
        fi
        # 移除末尾斜杠
        INSTALL_PATH_BASE="${INSTALL_PATH_BASE%/}"
        shift # past argument
        shift # past value
        ;;
      -v|--version)
        VERSION="$2"
        shift # past argument
        shift # past value
        ;;
      -y|--yes)
        SKIP_CONFIRM='true'
        shift # past argument
        ;;
      --forced)
        FORCE_INSTALL='true'
        shift # past argument
        ;;
      *)    # 未知选项
        print_error "未知参数: $1"
        exit 1
        ;;
    esac
  done

  # 设置最终路径变量
  BINARY_INSTALL_PATH="${INSTALL_PATH_BASE}/alist"
  DATA_DIR="${INSTALL_PATH_BASE}/data"
}

# 检查运行环境
check_environment() {
  print_success "检查运行环境..."
  if [ "$(id -u)" != "0" ]; then
    print_error "此脚本需要以 root 权限运行。"
    exit 1
  fi

  # Get platform
  if command -v arch >/dev/null 2>&1; then
    platform=$(arch)
  else
    platform=$(uname -m)
  fi

  if [ "$platform" = "x86_64" ]; then
    ARCH=amd64
  elif [ "$platform" = "aarch64" ]; then
    ARCH=arm64
  elif [ "$platform" = "armv7l" ]; then
    ARCH=armv7 # 假设你的 Release 中 armv7 叫这个名字
  elif [ "$platform" = "arm" ]; then
    ARCH=armv6 # 假设你的 Release 中 armv6 叫这个名字
  else
    ARCH="UNKNOWN"
  fi

  if [ "$ARCH" == "UNKNOWN" ]; then
    print_error "不支持的系统架构 '$platform'。请确保你的 GitHub Release 提供了对应架构的附件。"
    exit 1
  fi
  print_success "系统架构: $ARCH"

  if ! command -v systemctl >/dev/null 2>&1; then
    print_error "未检测到 systemd，此脚本仅支持 systemd 系统。"
    exit 1
  fi

  if ! command -v curl &> /dev/null && ! command -v wget &> /dev/null; then
    print_error "需要安装 curl 或 wget 才能下载文件。"
    exit 1
  fi

  # CURL 进度显示
  if curl --help | grep progress-bar >/dev/null 2>&1; then # $CURL_BAR
      CURL_BAR="--progress-bar"
  fi
}

# 检查现有安装和端口占用
check_installation() {
  print_success "检查现有安装和端口..."
  # 检查目标路径是否已存在文件 (非强制安装模式)
  if [ -f "$BINARY_INSTALL_PATH" ] && [ "$FORCE_INSTALL" = 'false' ]; then
    print_error "路径 '$BINARY_INSTALL_PATH' 已存在一个文件。请使用 'update' 命令，或使用 '--forced' 参数强制覆盖，或指定其他安装路径 (-p)。"
    exit 1
  fi

  # 检查端口 5244 是否被占用
  local check_port_cmd=""
  if command -v ss >/dev/null 2>&1; then
      check_port_cmd="ss -ltn | grep -q ':5244\s'"
  elif command -v netstat >/dev/null 2>&1; then
      check_port_cmd="netstat -lnt | grep -q ':5244\s'"
  else
      print_warning "无法检查端口占用，请手动确认端口 5244 未被使用。"
  fi

  if [ -n "$check_port_cmd" ]; then
    if eval "$check_port_cmd"; then
      print_warning "端口 5244 可能已被占用。如果安装后无法启动，请检查端口冲突。"
    fi
  fi

  # 强制安装模式下，如果服务存在则停止
  if [ "$FORCE_INSTALL" = 'true' ]; then
    if systemctl is-active --quiet "$SERVICE_NAME"; then
      print_warning "检测到正在运行的 AList 服务，将停止并覆盖..."
      systemctl stop "$SERVICE_NAME" || true # 忽略停止错误
    fi
    # 强制模式下删除旧目录
    if [ -d "$INSTALL_PATH_BASE" ]; then
        print_warning "强制模式：删除已存在的目录 $INSTALL_PATH_BASE ..."
        rm -rf "$INSTALL_PATH_BASE"
    fi
  fi
}

# 下载并解压 AList
download_and_extract() {
  print_success "准备下载 AList $VERSION ($ARCH)..."

  # !!! 关键: 确保你的 GitHub Release 附件命名符合这个格式 !!!
  # 例如：alist-linux-amd64.tar.gz, alist-linux-arm64.tar.gz
  local download_url="${GH_PROXY}https://github.com/${GITHUB_REPO}/releases/download/${VERSION}/alist-linux-${ARCH}.tar.gz"
  local temp_tarball="/tmp/alist-${VERSION}-${ARCH}.tar.gz"
  local temp_extract_dir="/tmp/alist_extracted_$$" # 使用 PID 防止冲突

  print_success "下载链接: $download_url"

  # 下载
  if command -v curl &> /dev/null; then
    curl -L -o "$temp_tarball" "$download_url" $CURL_BAR
  else
    wget -O "$temp_tarball" "$download_url" --progress=bar:force 2>&1
  fi

  if [ $? -ne 0 ]; then
    print_error "下载失败，请检查 URL、网络或 GitHub Release 是否存在对应附件。"
    rm -f "$temp_tarball"
    exit 1
  fi
  print_success "下载成功。"

  # 创建安装目录和解压目录
  mkdir -p "$INSTALL_PATH_BASE"
  mkdir -p "$temp_extract_dir"

  # 解压
  print_success "正在解压文件..."
  tar -zxvf "$temp_tarball" -C "$temp_extract_dir"
  if [ $? -ne 0 ]; then
    print_error "解压失败。"
    rm -f "$temp_tarball"
    rm -rf "$temp_extract_dir"
    exit 1
  fi

  # 移动二进制文件 (假设压缩包内直接是 alist 文件)
  if [ ! -f "$temp_extract_dir/alist" ]; then
      print_error "在解压的文件中未找到 'alist' 二进制文件。请检查你的 .tar.gz 包结构。"
      rm -f "$temp_tarball"
      rm -rf "$temp_extract_dir"
      exit 1
  fi
  mv "$temp_extract_dir/alist" "$BINARY_INSTALL_PATH"
  chmod +x "$BINARY_INSTALL_PATH"
  print_success "二进制文件已安装到 $BINARY_INSTALL_PATH"

  # 清理临时文件
  rm -f "$temp_tarball"
  rm -rf "$temp_extract_dir"
}

# 配置 Systemd 服务
setup_systemd() {
  print_success "配置 systemd 服务..."
  local service_file_path="/etc/systemd/system/${SERVICE_NAME}.service"

  # 创建数据目录
  mkdir -p "$DATA_DIR"
  # !!! 安全提示：如果需要非 root 运行，在这里设置权限 chown user:group "$DATA_DIR" !!!

  # 创建服务文件
  cat << EOF > "$service_file_path"
[Unit]
Description=AList Service (Custom Build from ${GITHUB_REPO})
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
# !!! 安全警告：默认以 root 运行，强烈建议改为非 root 用户 !!!
# 1. 创建用户: sudo useradd -r -s /sbin/nologin alistuser
# 2. 修改下面两行:
# User=alistuser
# Group=alistuser
# 3. 修改目录权限: sudo chown -R alistuser:alistuser "${DATA_DIR}" "${INSTALL_PATH_BASE}" (如果需要写日志或其他文件到安装目录)
User=root
Group=root
WorkingDirectory=${INSTALL_PATH_BASE}
ExecStart=${BINARY_INSTALL_PATH} server --data ${DATA_DIR}
Restart=on-failure
RestartSec=5
# 可选: 增加文件描述符限制 (如果遇到 'too many open files' 错误)
# LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

  print_success "Systemd 服务文件已创建: $service_file_path"

  # 重载、启用并启动服务
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || print_warning "启用服务失败 (可能已启用)"
  systemctl restart "$SERVICE_NAME"
  # 等待一小段时间让服务启动
  sleep 2
  if systemctl is-active --quiet "$SERVICE_NAME"; then
      print_success "AList 服务已成功启动。"
  else
      print_error "AList 服务启动失败，请运行 'systemctl status $SERVICE_NAME' 和 'journalctl -u $SERVICE_NAME' 查看错误日志。"
      exit 1
  fi
}

# 显示成功信息
show_success_message() {
  clear
  print_success "定制版 AList 安装成功！"
  echo -e "\r\n访问地址：${GREEN_COLOR}http://<你的服务器IP>:5244/${RES}\r\n"

  echo -e "安装路径：${GREEN_COLOR}${INSTALL_PATH_BASE}${RES}"
  echo -e "二进制文件：${GREEN_COLOR}${BINARY_INSTALL_PATH}${RES}"
  echo -e "数据目录：${GREEN_COLOR}${DATA_DIR}${RES}"
  echo -e "配置文件：${GREEN_COLOR}${DATA_DIR}/config.json${RES}"
  echo ""
  echo -e "---------如何获取管理员密码？---------"
  echo -e "方法一：查看首次启动日志获取随机密码："
  echo -e "${GREEN_COLOR}journalctl -u ${SERVICE_NAME} --no-pager | grep password${RES}"
  echo -e "方法二：手动设置密码 (需要先停止服务)："
  echo -e "  ${GREEN_COLOR}systemctl stop ${SERVICE_NAME}${RES}"
  echo -e "  ${GREEN_COLOR}cd ${INSTALL_PATH_BASE}${RES}"
  echo -e "  ${GREEN_COLOR}./alist admin set NEW_PASSWORD${RES} (将 NEW_PASSWORD 替换为你想要的密码)"
  echo -e "  ${GREEN_COLOR}systemctl start ${SERVICE_NAME}${RES}"
  echo -e "------------------------------------"
  echo ""
  echo -e "服务管理命令:"
  echo -e "  启动: ${GREEN_COLOR}systemctl start ${SERVICE_NAME}${RES}"
  echo -e "  停止: ${GREEN_COLOR}systemctl stop ${SERVICE_NAME}${RES}"
  echo -e "  重启: ${GREEN_COLOR}systemctl restart ${SERVICE_NAME}${RES}"
  echo -e "  状态: ${GREEN_COLOR}systemctl status ${SERVICE_NAME}${RES}"
  echo -e "  日志: ${GREEN_COLOR}journalctl -u ${SERVICE_NAME}${RES}"
  echo ""
  print_warning "!!! 重要安全提示：服务当前以 root 用户运行。为了安全，强烈建议创建一个专用用户并修改 systemd 服务文件 (${service_file_path}) 中的 User 和 Group，并调整数据目录 (${DATA_DIR}) 的权限。请参考服务文件内的注释操作。 !!!"
  echo ""
}

# 卸载函数
uninstall() {
    print_warning "准备卸载 AList..."
    if ! systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
        print_warning "未找到 AList 服务 ($SERVICE_NAME.service)，可能未安装或已被移除。"
    else
        print_success "停止并禁用 AList 服务..."
        systemctl stop "$SERVICE_NAME" || true
        systemctl disable "$SERVICE_NAME" || true
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload
        print_success "服务已移除。"
    fi

    # 获取安装路径 (尝试从 systemd 文件读取，如果失败则使用默认或参数)
    local actual_install_path="$INSTALL_PATH_BASE" # 默认或参数指定的路径

    print_success "正在删除安装目录: $actual_install_path ..."
    if [ -d "$actual_install_path" ]; then
        rm -rf "$actual_install_path"
        print_success "目录已删除。"
    else
        print_warning "安装目录 '$actual_install_path' 未找到。"
    fi

    print_success "AList 卸载完成。"
}

# 更新函数
update() {
    print_success "准备更新 AList..."
    local service_file_path="/etc/systemd/system/${SERVICE_NAME}.service"

    if [ ! -f "$BINARY_INSTALL_PATH" ]; then
        print_error "未在 '$BINARY_INSTALL_PATH' 找到 AList 二进制文件。请先执行安装命令。"
        exit 1
    fi
    if ! systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
        print_error "未找到 AList 服务 ($SERVICE_NAME.service)，无法执行更新。"
        exit 1
    fi

    print_success "停止当前 AList 服务..."
    systemctl stop "$SERVICE_NAME" || print_warning "停止服务失败，可能未在运行。"

    # 备份旧的二进制文件
    local backup_path="/tmp/alist.bak.$$"
    print_success "备份当前二进制文件到 $backup_path ..."
    cp "$BINARY_INSTALL_PATH" "$backup_path"

    # 下载新版本 (与安装逻辑相同)
    print_success "开始下载新版本 $VERSION ..."
    download_and_extract # 复用下载解压函数

    # 启动服务
    print_success "启动更新后的 AList 服务..."
    systemctl start "$SERVICE_NAME"
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        print_success "AList 更新成功并已启动！"
        rm -f "$backup_path" # 成功后删除备份
    else
        print_error "更新后的 AList 服务启动失败！正在尝试回滚..."
        mv "$backup_path" "$BINARY_INSTALL_PATH" # 恢复备份
        systemctl start "$SERVICE_NAME" # 尝试启动旧版本
        print_error "已回滚到更新前的版本。请检查错误日志。更新失败。"
        exit 1
    fi
    echo ""
    print_warning "更新后，建议检查后台配置是否兼容新版本。"
    echo ""
}


# --- 主逻辑 ---

# 确定操作 (install, uninstall, update)
action="install" # 默认为安装
if [ -n "$1" ] && [[ "$1" == "install" || "$1" == "uninstall" || "$1" == "update" ]]; then
    action="$1"
    shift # 移除第一个参数 (操作命令)
fi

# 解析剩余参数
parse_args "$@"

# 执行环境检查 (对所有操作都需要)
check_environment

# 根据操作执行不同流程
case "$action" in
    install)
        print_success "=== 开始安装定制版 AList ==="
        check_installation
        if [ "$SKIP_CONFIRM" = 'false' ] && [ "$FORCE_INSTALL" = 'false' ] && [ -t 0 ]; then
            read -p "将安装 AList 到 '$INSTALL_PATH_BASE'. 是否继续? (y/N): " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                echo "安装已取消。"
                exit 0
            fi
        fi
        download_and_extract
        setup_systemd
        show_success_message
        ;;
    uninstall)
        print_success "=== 开始卸载 AList ==="
        if [ "$SKIP_CONFIRM" = 'false' ]; then
            read -p "将卸载位于 '$INSTALL_PATH_BASE' 的 AList 并删除 systemd 服务. 是否继续? (y/N): " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                echo "卸载已取消。"
                exit 0
            fi
        fi
        uninstall
        ;;
    update)
        print_success "=== 开始更新 AList ==="
        if [ "$SKIP_CONFIRM" = 'false' ]; then
             read -p "将尝试更新位于 '$INSTALL_PATH_BASE' 的 AList 到版本 '$VERSION'. 是否继续? (y/N): " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                echo "更新已取消。"
                exit 0
            fi
        fi
        update
        ;;
    *)
        #理论上不会到这里，因为前面有检查
        print_error "未知操作: $action"
        exit 1
        ;;
esac

exit 0
