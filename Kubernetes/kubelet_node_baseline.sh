#!/usr/bin/env bash

set -euo pipefail

MODE="${1:-env-info}"
shift || true

KUBELET_CONFIG_FILE="${KUBELET_CONFIG_FILE:-}"
KUBELET_KUBECONFIG_FILE="${KUBELET_KUBECONFIG_FILE:-}"
KUBELET_SERVICE_NAME="${KUBELET_SERVICE_NAME:-kubelet}"

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

timestamp() {
  date +%F-%H%M%S
}

info() {
  printf '[信息] %s\n' "$*"
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf '[通过] %s\n' "$*"
}

warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  printf '[警告] %s\n' "$*"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '[失败] %s\n' "$*"
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "该操作需要 root 权限。" >&2
    exit 1
  fi
}

backup_if_exists() {
  local path="$1"
  local dir base backup_target

  if [ -e "$path" ]; then
    dir="$(dirname "$path")"
    base="$(basename "$path")"
    backup_target="${dir}/${base}.bak.$(timestamp)"
    cp -a "$path" "$backup_target"
    info "已备份 ${path} 到 ${backup_target}"
  fi
}

find_first_existing_path() {
  local candidate

  for candidate in "$@"; do
    if [ -n "$candidate" ] && [ -e "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

discover_kubelet_cmdline() {
  if have_cmd pgrep; then
    pgrep -af kubelet 2>/dev/null | awk '
      /(^|[[:space:]\/])kubelet([[:space:]]|$)/ {
        $1 = ""
        sub(/^ /, "", $0)
        print
        exit
      }
    '
    return
  fi

  ps -eo args= 2>/dev/null | awk '
    /(^|[[:space:]\/])kubelet([[:space:]]|$)/ {
      print
      exit
    }
  '
}

get_flag_value() {
  local flag="$1"
  local arg next
  local i

  for ((i = 0; i < ${#KUBELET_ARGS[@]}; i++)); do
    arg="${KUBELET_ARGS[$i]}"
    if [ "$arg" = "--${flag}" ]; then
      if [ $((i + 1)) -lt "${#KUBELET_ARGS[@]}" ]; then
        next="${KUBELET_ARGS[$((i + 1))]}"
        if [[ "$next" != --* ]]; then
          printf '%s\n' "$next"
          return 0
        fi
      fi
      printf 'true\n'
      return 0
    fi

    case "$arg" in
      --"${flag}"=*)
        printf '%s\n' "${arg#*=}"
        return 0
        ;;
    esac
  done

  return 1
}

normalize_bool() {
  local value
  value="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"

  case "$value" in
    true|1|yes|on)
      printf 'true\n'
      ;;
    false|0|no|off)
      printf 'false\n'
      ;;
    *)
      printf '%s\n' "$value"
      ;;
  esac
}

yaml_get_value() {
  local file="$1"
  local path="$2"

  awk -v target="$path" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    function build_path(current_key,    i, out) {
      out = ""
      for (i = 1; i <= depth; i++) {
        if (keys[i] != "") {
          if (out != "") {
            out = out "."
          }
          out = out keys[i]
        }
      }
      if (out != "") {
        out = out "."
      }
      out = out current_key
      return out
    }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ {
      next
    }
    {
      match($0, /[^ ]/)
      indent = RSTART - 1
      line = $0

      if (match(line, /^[[:space:]]*([A-Za-z0-9_-]+):[[:space:]]*(.*)$/, m) == 0) {
        next
      }

      key = m[1]
      value = m[2]

      while (depth > 0 && indent <= indents[depth]) {
        delete indents[depth]
        delete keys[depth]
        depth--
      }

      if (value == "" || value ~ /^[[:space:]]*#/) {
        depth++
        indents[depth] = indent
        keys[depth] = key
        next
      }

      current = build_path(key)
      if (current == target) {
        value = trim(value)
        sub(/[[:space:]]+#.*$/, "", value)
        gsub(/^["'\'']|["'\'']$/, "", value)
        print value
        exit
      }
    }
  ' "$file"
}

discover_paths() {
  KUBELET_BIN="$(command -v kubelet 2>/dev/null || true)"
  KUBELET_CMDLINE="$(discover_kubelet_cmdline || true)"
  read -r -a KUBELET_ARGS <<<"${KUBELET_CMDLINE:-}"

  if have_cmd systemctl; then
    SERVICE_UNIT="$(systemctl show -p FragmentPath --value "$KUBELET_SERVICE_NAME" 2>/dev/null || true)"
    ACTIVE_STATE="$(systemctl is-active "$KUBELET_SERVICE_NAME" 2>/dev/null || true)"
    ENABLED_STATE="$(systemctl is-enabled "$KUBELET_SERVICE_NAME" 2>/dev/null || true)"
  else
    SERVICE_UNIT="$(find_first_existing_path \
      /usr/lib/systemd/system/kubelet.service \
      /lib/systemd/system/kubelet.service \
      /etc/systemd/system/kubelet.service || true)"
    ACTIVE_STATE="未检测到 systemctl"
    ENABLED_STATE="未检测到 systemctl"
  fi

  if [ -z "$KUBELET_CONFIG_FILE" ]; then
    KUBELET_CONFIG_FILE="$(get_flag_value config 2>/dev/null || true)"
  fi
  if [ -z "$KUBELET_CONFIG_FILE" ]; then
    KUBELET_CONFIG_FILE="$(find_first_existing_path \
      /var/lib/kubelet/config.yaml \
      /etc/kubernetes/kubelet/config.yaml || true)"
  fi

  if [ -z "$KUBELET_KUBECONFIG_FILE" ]; then
    KUBELET_KUBECONFIG_FILE="$(get_flag_value kubeconfig 2>/dev/null || true)"
  fi
  if [ -z "$KUBELET_KUBECONFIG_FILE" ]; then
    KUBELET_KUBECONFIG_FILE="$(find_first_existing_path \
      /etc/kubernetes/kubelet.conf \
      /var/lib/kubelet/kubeconfig || true)"
  fi
}

print_path_status() {
  local label="$1"
  local path="$2"

  if [ -z "$path" ]; then
    printf '  %-24s %s\n' "$label" "未检测到"
    return
  fi

  if [ -e "$path" ]; then
    printf '  %-24s %s\n' "$label" "$path"
  else
    printf '  %-24s %s (当前不存在)\n' "$label" "$path"
  fi
}

effective_value() {
  local flag="$1"
  local yaml_path="$2"
  local value

  value="$(get_flag_value "$flag" 2>/dev/null || true)"
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
    return
  fi

  if [ -n "$KUBELET_CONFIG_FILE" ] && [ -f "$KUBELET_CONFIG_FILE" ]; then
    yaml_get_value "$KUBELET_CONFIG_FILE" "$yaml_path" || true
  fi
}

perm_stricter_or_equal() {
  local current="$1"
  local target="$2"
  local i cur tgt

  if [ "${#current}" -lt 3 ] || [ "${#target}" -lt 3 ]; then
    return 1
  fi

  current="${current: -3}"
  target="${target: -3}"

  for i in 0 1 2; do
    cur="${current:$i:1}"
    tgt="${target:$i:1}"
    if [ "$cur" -gt "$tgt" ]; then
      return 1
    fi
  done

  return 0
}

check_owner_mode() {
  local path="$1"
  local expected_owner="$2"
  local max_mode="$3"
  local item="$4"
  local owner mode

  if [ -z "$path" ] || [ ! -e "$path" ]; then
    fail "${item}：未找到路径"
    return
  fi

  owner="$(stat -c '%U:%G' "$path")"
  mode="$(stat -c '%a' "$path")"

  if [ "$owner" = "$expected_owner" ] && perm_stricter_or_equal "$mode" "$max_mode"; then
    pass "${item}：${owner} ${mode}"
  else
    fail "${item}：当前=${owner} ${mode}，期望 owner=${expected_owner}，mode<=${max_mode}"
  fi
}

check_mode_max() {
  local path="$1"
  local max_mode="$2"
  local item="$3"
  local mode

  if [ -z "$path" ] || [ ! -e "$path" ]; then
    fail "${item}：未找到路径"
    return
  fi

  mode="$(stat -c '%a' "$path")"
  if perm_stricter_or_equal "$mode" "$max_mode"; then
    pass "${item}：mode=${mode}"
  else
    fail "${item}：mode=${mode}，期望 mode<=${max_mode}"
  fi
}

check_owner() {
  local path="$1"
  local expected_owner="$2"
  local item="$3"
  local owner

  if [ -z "$path" ] || [ ! -e "$path" ]; then
    fail "${item}：未找到路径"
    return
  fi

  owner="$(stat -c '%U:%G' "$path")"
  if [ "$owner" = "$expected_owner" ]; then
    pass "${item}：${owner}"
  else
    fail "${item}：当前=${owner}，期望 owner=${expected_owner}"
  fi
}

check_anonymous_auth() {
  local value
  value="$(normalize_bool "$(effective_value anonymous-auth authentication.anonymous.enabled)")"

  if [ "$value" = "false" ]; then
    pass "anonymous-auth 已禁用"
  else
    fail "anonymous-auth 未禁用"
  fi
}

check_client_ca_file() {
  local value
  value="$(effective_value client-ca-file authentication.x509.clientCAFile)"

  if [ -z "$value" ]; then
    fail "client-ca-file 未设置"
    return
  fi

  if [ -f "$value" ]; then
    pass "client-ca-file 已设置且文件存在：${value}"
  else
    fail "client-ca-file 已设置但文件不存在：${value}"
  fi
}

check_authorization_mode() {
  local value normalized
  value="$(effective_value authorization-mode authorization.mode)"
  normalized="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"

  if [ -z "$value" ]; then
    fail "authorization-mode 未显式设置，默认值不满足基线"
    return
  fi

  if [[ "$normalized" == *alwaysallow* ]]; then
    fail "authorization-mode 仍为 AlwaysAllow"
  else
    pass "authorization-mode 已设置为 ${value}"
  fi
}

check_make_iptables_util_chains() {
  local value
  value="$(normalize_bool "$(effective_value make-iptables-util-chains makeIPTablesUtilChains)")"

  if [ -z "$value" ]; then
    pass "make-iptables-util-chains 未显式设置，按 kubelet 默认值 true 处理"
    return
  fi

  if [ "$value" = "true" ]; then
    pass "make-iptables-util-chains 已启用"
  else
    fail "make-iptables-util-chains 未启用"
  fi
}

print_env_info() {
  local version_output

  discover_paths

  if [ -n "$KUBELET_BIN" ]; then
    version_output="$("$KUBELET_BIN" --version 2>/dev/null || true)"
  else
    version_output="未检测到"
  fi

  echo "Kubelet Node 环境信息："
  printf '  %-24s %s\n' "当前目录" "$PWD"
  printf '  %-24s %s\n' "备份策略" "修复前备份到源文件同目录，并附加时间戳"
  printf '  %-24s %s\n' "kubelet 版本" "$version_output"
  printf '  %-24s %s\n' "服务状态" "${ACTIVE_STATE:-未知}"
  printf '  %-24s %s\n' "开机自启" "${ENABLED_STATE:-未知}"
  print_path_status "kubelet 二进制" "$KUBELET_BIN"
  print_path_status "service 单元" "$SERVICE_UNIT"
  print_path_status "kubeconfig 文件" "$KUBELET_KUBECONFIG_FILE"
  print_path_status "配置文件" "$KUBELET_CONFIG_FILE"
  printf '  %-24s %s\n' "anonymous-auth" "$(effective_value anonymous-auth authentication.anonymous.enabled || echo 未检测到)"
  printf '  %-24s %s\n' "client-ca-file" "$(effective_value client-ca-file authentication.x509.clientCAFile || echo 未检测到)"
  printf '  %-24s %s\n' "authorization-mode" "$(effective_value authorization-mode authorization.mode || echo 未检测到)"
  printf '  %-24s %s\n' "make-iptables-util-chains" "$(effective_value make-iptables-util-chains makeIPTablesUtilChains || echo 未显式设置)"
  if [ -n "$KUBELET_CMDLINE" ]; then
    printf '  %-24s %s\n' "运行参数" "$KUBELET_CMDLINE"
  else
    printf '  %-24s %s\n' "运行参数" "未检测到运行中的 kubelet"
  fi
}

run_checks() {
  discover_paths

  check_anonymous_auth
  check_client_ca_file
  check_authorization_mode
  check_mode_max "$SERVICE_UNIT" 644 "kubelet 服务文件权限"
  check_mode_max "$KUBELET_KUBECONFIG_FILE" 644 "kubelet.conf 权限"
  check_mode_max "$KUBELET_CONFIG_FILE" 644 "kubelet 配置文件权限"
  check_owner "$KUBELET_CONFIG_FILE" "root:root" "kubelet 配置文件所有权"
  check_make_iptables_util_chains
  check_owner "$SERVICE_UNIT" "root:root" "kubelet 服务文件所有权"

  printf '\n汇总：通过=%s 警告=%s 失败=%s\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
  if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
  fi
}

fix_perms() {
  require_root
  discover_paths

  if [ -n "$SERVICE_UNIT" ] && [ -e "$SERVICE_UNIT" ]; then
    backup_if_exists "$SERVICE_UNIT"
    chown root:root "$SERVICE_UNIT"
    chmod 644 "$SERVICE_UNIT"
  else
    warn "未找到 kubelet 服务文件，跳过权限修复"
  fi

  if [ -n "$KUBELET_KUBECONFIG_FILE" ] && [ -e "$KUBELET_KUBECONFIG_FILE" ]; then
    backup_if_exists "$KUBELET_KUBECONFIG_FILE"
    chmod 644 "$KUBELET_KUBECONFIG_FILE"
  else
    warn "未找到 kubelet.conf，跳过权限修复"
  fi

  if [ -n "$KUBELET_CONFIG_FILE" ] && [ -e "$KUBELET_CONFIG_FILE" ]; then
    backup_if_exists "$KUBELET_CONFIG_FILE"
    chown root:root "$KUBELET_CONFIG_FILE"
    chmod 644 "$KUBELET_CONFIG_FILE"
  else
    warn "未找到 kubelet 配置文件，跳过权限修复"
  fi

  info "kubelet 节点文件权限修复已完成"
}

print_config() {
  cat <<'EOF'
authentication:
  anonymous:
    enabled: false
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
authorization:
  mode: Webhook
makeIPTablesUtilChains: true
EOF
}

usage() {
  cat <<'EOF'
用法：
  kubelet_node_baseline.sh                     默认输出 kubelet 节点环境信息
  kubelet_node_baseline.sh env-info           输出 kubelet 节点环境信息
  kubelet_node_baseline.sh check              执行 ACK Node 基线检查
  kubelet_node_baseline.sh fix-perms          修复 kubelet.service、kubelet.conf、config 文件权限
  kubelet_node_baseline.sh print-config       输出建议的 KubeletConfiguration 配置片段
  kubelet_node_baseline.sh -h|--help|help     显示帮助信息

说明：
  该脚本仅自动修复文件权限，不自动修改 kubelet 鉴权与授权参数。
  鉴权参数优先以运行中的 kubelet 实际启动参数为准，未显式设置时回退检查配置文件。
  修复前会先在源文件同目录生成备份文件，并附加时间戳命名。
EOF
}

case "$MODE" in
  env|env-info|info)
    print_env_info
    ;;
  check)
    run_checks
    ;;
  fix-perms)
    fix_perms
    ;;
  print-config)
    print_config
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "未知模式：$MODE" >&2
    usage
    exit 2
    ;;
esac
