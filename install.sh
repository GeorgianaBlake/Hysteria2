#!/usr/bin/env bash
# https://github.com/GeorgianaBlake/Hysteria2
# Hysteria2一键管理脚本：安装/更新/查看/更改端口/更改密码/删除
# 适配 Debian/Ubuntu (apt) 与 CentOS/RHEL/Alma/Rocky (yum/dnf)

set -euo pipefail

SERVICE="hysteria-server.service" # Hysteria2服务
CONF_DIR="/etc/hysteria" # 配置目录
CONF_FILE="${CONF_DIR}/config.yaml" # 主配置文件
CLIENT_FILE="${CONF_DIR}/hyclient.txt" # 文本清单
TZ_DEFAULT="Asia/Shanghai" # 默认时区
SHELL_VERSION="0.1.0" # 版本
H2_SNI="bing.com"  # 伪装域名
H2_ALIASES="Hysteria2" # 别名

# 字体颜色配置
Font="\033[0m"

Black="\033[30m"   # 黑色
Red="\033[31m"     # 红色
Green="\033[32m"   # 绿色
Yellow="\033[33m"  # 黄色
Blue="\033[34m"    # 蓝色
Magenta="\033[35m" # 紫/洋红
Cyan="\033[36m"    # 青
White="\033[37m"   # 白色

BBlack="\033[90m"
BRed="\033[91m"
BGreen="\033[92m"
BYellow="\033[93m"
BBlue="\033[94m"
BMagenta="\033[95m"
BCyan="\033[96m"
BWhite="\033[97m"

BlackBG="\033[40m"
RedBG="\033[41m"
GreenBG="\033[42m"
YellowBG="\033[43m"
BlueBG="\033[44m"
MagentaBG="\033[45m"
CyanBG="\033[46m"
WhiteBG="\033[47m"

Bold="\033[1m"
Dim="\033[2m"
Italic="\033[3m"
Underline="\033[4m"
Blink="\033[5m"
Reverse="\033[7m"
Hidden="\033[8m"
Strike="\033[9m"

OK="${Green}[OK]${Font}"
ERROR="${Red}[ERROR]${Font}"
WARN="${Yellow}[WARN]${Font}"
INFO="${Cyan}[INFO]${Font}"

trap 'echo -e "\n${WARN} 已中断"; exit 1' INT

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    clear
    echo "Error: 必须使用 root 运行本脚本!" 1>&2
    exit 1
  fi
}

center() {
  local s="$1"
  local cols
  cols=$(tput cols 2>/dev/null || echo 80)

  local noansi
  noansi=$(printf '%b' "$s" | sed -r 's/\x1B\[[0-9;]*[A-Za-z]//g')

  local width
  width=$(LC_ALL=C.UTF-8 awk -v str="$noansi" '
    BEGIN{
      n = split(str, a, "")
      w = 0
      for(i=1;i<=n;i++){
        c = a[i]
        if (c ~ /[ -~]/) w += 1
        else             w += 2
      }
      print w
    }')

  local pad=$(( (cols - width) / 2 ))
  (( pad < 0 )) && pad=0
  printf "%*s%b\n" "$pad" "" "$s"
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

os_install() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y curl gawk openssl
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl gawk openssl
  elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release || true
    yum install -y curl gawk openssl
  else
    echo "未识别的包管理器，请手动安装 curl、gawk、openssl 后重试"
    exit 1
  fi
}

# -------- 安装状态检测 --------
service_installed() { systemctl status "${SERVICE}" >/dev/null 2>&1; }
service_active() { systemctl is-active --quiet "${SERVICE}"; }

is_installed() {
  # 满足：存在二进制 或 服务可用，并且存在配置文件，认为已安装
  if { has_cmd hysteria || service_installed; } && [[ -f "${CONF_FILE}" ]]; then
    return 0
  fi
  return 1
}

status_text() {
  if is_installed; then
    if service_active; then
      echo -e "${BGreen}已安装（运行中）${Font}"
    else
      echo -e "${BYellow}已安装（已停止）${Font}"
    fi
  else
    echo -e "${BRed}未安装${Font}"
  fi
}

get_ip() {
  local ip4 ip6
  ip4=$(curl -s -4 http://www.cloudflare.com/cdn-cgi/trace | awk -F= '/^ip=/{print $2}')
  if [[ -n "${ip4}" ]]; then
    echo "${ip4}"
    return
  fi
  ip6=$(curl -s -6 http://www.cloudflare.com/cdn-cgi/trace | awk -F= '/^ip=/{print $2}')
  if [[ -n "${ip6}" ]]; then
    echo "${ip6}"
    return
  fi
  curl -s https://api.ipify.org || true
}

random_port() { shuf -i 2000-65000 -n 1; }

# 确保端口是数字并且在合法范围内
valid_port() {
  local p="${1:-}"
  [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

# 检查端口是否被占用
is_port_free() {
  local port="$1"
  ss -tuln | grep ":$port " >/dev/null 2>&1
}

read_port_interactive() {
  local input
  while true; do
    read -t 15 -p "回车或等待15秒为随机端口，或者自定义端口请输入(1-65535)：" input || true
    if [[ -z "${input:-}" ]]; then
      input=$(random_port)
    fi

    # 验证端口是否合法
    if ! valid_port "$input"; then
      echo "端口不合法：$input，请输入一个有效的端口（1-65535）。"
      continue
    fi

    # 检查端口是否被占用
    if is_port_free "$input"; then
      echo "端口 $input 已被占用，请选择另一个端口。"
      continue
    fi

    # 如果端口合法且未被占用，退出循环
    echo "$input"
    break
  done
}

gen_password() { cat /proc/sys/kernel/random/uuid; }

ensure_cert() {
  mkdir -p "${CONF_DIR}"
  if [[ ! -f "${CONF_DIR}/server.key" || ! -f "${CONF_DIR}/server.crt" ]]; then
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
      -keyout "${CONF_DIR}/server.key" \
      -out "${CONF_DIR}/server.crt" -subj "/CN=${H2_SNI}" -days 36500
    chown hysteria:hysteria "${CONF_DIR}/server.key" "${CONF_DIR}/server.crt" || true
  fi
}

write_config() {
  # 参数：端口 密码
  local port="$1" pass="$2"
  mkdir -p "${CONF_DIR}"
  cat > "${CONF_FILE}" <<EOF
listen: :${port}
tls:
  cert: ${CONF_DIR}/server.crt
  key: ${CONF_DIR}/server.key

auth:
  type: password
  password: ${pass}

masquerade:
  type: proxy
  proxy:
    url: https://${H2_SNI}
    rewriteHost: true
quic:
  initStreamReceiveWindow: 26843545
  maxStreamReceiveWindow: 26843545
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864
EOF
}

client_export() {
  if [[ ! -f "${CONF_FILE}" ]]; then
    echo "未找到 ${CONF_FILE}"
    return 1
  fi
  local port pass ip link
  port=$(sed -nE 's/^[[:space:]]*listen:[[:space:]]*.*:([0-9]+)[[:space:]]*$/\1/p' "${CONF_FILE}")
  if [[ -z "${port}" ]]; then
    port=$(awk '/^[[:space:]]*listen:/ { if (match($0, /:([0-9]+)[[:space:]]*$/, a)) print a[1] }' "${CONF_FILE}")
  fi
  pass=$(sed -nE 's/^[[:space:]]*password:[[:space:]]*(.*)$/\1/p' "${CONF_FILE}")
  ip=$(get_ip)
  link="${pass}@${ip}:${port}/?insecure=1&sni=${H2_SNI}#${H2_ALIASES}"

  cat > "${CLIENT_FILE}" <<EOF
=========== Hysteria2 配置参数 ===========
代理模式：Hysteria2
地址：${ip}
端口：${port}
密码：${pass}
SNI：${H2_SNI}
传输协议：tls
跳过证书验证：true
=========================================
链接（可复制导入）：
hysteria2://${link}
EOF
}

restart_service() {
  systemctl daemon-reload || true
  systemctl enable "${SERVICE}" || true
  systemctl restart "${SERVICE}"
  systemctl status --no-pager "${SERVICE}" | sed -n '1,6p' || true
}

require_installed() {
  if ! is_installed; then
    echo -e "${ERROR} 未检测到安装，请先执行安装。"
    return 1
  fi
  return 0
}

install_hy2() {
  local force="${1:-}"
  if is_installed && [[ "${force}" != "force" ]]; then
    read -rp "检测到已安装，是否覆盖安装并重置端口/密码？(y/N): " ans
    if [[ ! "${ans:-N}" =~ ^[yY]$ ]]; then
      echo "已取消。"
      return
    fi
  fi
  timedatectl set-timezone "${TZ_DEFAULT}" || true
  os_install
  echo "开始安装 Hysteria2..."
  bash <(curl -fsSL https://get.hy2.sh/)
  ensure_cert

  local port pass
  port=$(read_port_interactive)
  pass=$(gen_password)
  write_config "${port}" "${pass}"
  restart_service
  client_export

  clear
  echo -e "${OK} 安装完成，以下为客户端导入参数："
  echo
  cat "${CLIENT_FILE}"
  echo
  exit 0
}


update_hy2() {
  if ! is_installed; then
    echo -e "${WARN} 未安装，无法更新。请先安装。"
    return
  fi
  os_install
  echo "更新 Hysteria2 到最新版..."
  bash <(curl -fsSL https://get.hy2.sh/)
  restart_service
  client_export
  echo -e "${OK} 更新完成。"
}

view_hy2() {
  if ! require_installed; then return; fi
  client_export
  echo
  cat "${CLIENT_FILE}"
}

set_port() {
  if ! require_installed; then return; fi
  local new_port
  new_port=$(read_port_interactive)
  sed -i -E "s/^listen:\s*:.*/listen: :${new_port}/" "${CONF_FILE}"
  restart_service
  client_export
  clear
  echo -e "${OK} 端口已更新为：${new_port}"
  echo
  echo -e "${INFO} 当前客户端导入参数："
  echo
  cat "${CLIENT_FILE}"
  echo
  exit 0
}

set_password() {
  if ! require_installed; then return; fi
  local new_pass
  read -p "回车随机生成密码，或输入自定义密码：" new_pass || true
  if [[ -z "${new_pass:-}" ]]; then
    new_pass=$(gen_password)
  fi
  sed -i -E "s/^([[:space:]]*)password:\s*.*/\1password: ${new_pass}/" "${CONF_FILE}"
  restart_service
  client_export
  clear
  echo -e "${OK} 密码已更新为：${new_pass}"
  echo
  echo -e "${INFO} 当前客户端导入参数："
  echo
  cat "${CLIENT_FILE}"
  echo
  exit 0
}

uninstall_hy2() {
  if ! is_installed; then
    echo -e "${WARN} 未安装，无需卸载。"
    return
  fi
  read -p "确认卸载并删除配置与证书？(y/N): " ans
  if [[ "${ans:-N}" != [yY] ]]; then
    echo "已取消。"
    return
  fi
  systemctl stop "${SERVICE}" || true
  systemctl disable "${SERVICE}" || true
  rm -f /usr/local/bin/hysteria /usr/bin/hysteria || true
  rm -f /etc/systemd/system/${SERVICE} || true
  systemctl daemon-reload || true
  rm -rf "${CONF_DIR}" || true
  echo -e "${OK} 卸载完成。"
}

pause() { read -rp "按回车返回菜单..." _; }

quit() { exit 0; }

hr() { printf '%*s\n' 40 '' | tr ' ' '='; }

draw_header() {
  hr
  echo -e " Hysteria2 一键管理"
  echo -e " https://github.com/GeorgianaBlake/Hysteria2"
  echo -e " 当前脚本版本: ${Magenta}${SHELL_VERSION}${Font}"
  echo -e " 安装状态：$(status_text)"
  hr
}

menu() {
  while true; do
    clear
    draw_header
    if is_installed; then
      echo -e "${Cyan}1. 重新安装（覆盖并重置端口/密码）${Font}"
      echo -e "${Cyan}2. 更新 Hysteria2${Font}"
      echo -e "${Cyan}3. 查看当前配置${Font}"
      echo -e "${Cyan}4. 更改端口${Font}"
      echo -e "${Cyan}5. 更改密码${Font}"
      echo -e "${Cyan}6. 卸载并删除配置${Font}"
      echo -e "${Cyan}0. 退出${Font}"
      hr
      read -p "请输入数字 [0-6]: " choice
      case "${choice}" in
        1) install_hy2 "force"; pause ;;
        2) update_hy2; pause ;;
        3) view_hy2; quit ;;
        4) set_port; pause ;;
        5) set_password; pause ;;
        6) uninstall_hy2; pause ;;
        0) exit 0 ;;
        *) echo "无效选项"; pause ;;
      esac
    else
      echo -e "${Cyan}1. 安装${Font}"
      echo -e "${Cyan}0. 退出${Font}"
      hr
      read -p "请输入数字 [0-1]: " choice
      case "${choice}" in
        1) install_hy2; pause ;;
        0) exit 0 ;;
        *) echo "未安装，只有 [1 安装] 或 [0 退出] 可用"; pause ;;
      esac
    fi
  done
}

# -------- 主流程 --------
ensure_root
menu
