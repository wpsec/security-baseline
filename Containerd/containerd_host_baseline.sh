#!/usr/bin/env bash

set -euo pipefail

MODE="${1:-check}"
shift || true

# 为保持兼容性保留该参数，当前默认启用 /run/containerd 审计。
INCLUDE_RUN_DIR_AUDIT=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    --include-run-dir-audit)
      INCLUDE_RUN_DIR_AUDIT=1
      ;;
    *)
      echo "未知参数：$1" >&2
      exit 2
      ;;
  esac
  shift
done

CONFIG_DIR="${CONFIG_DIR:-/etc/containerd}"
CONFIG_FILE="${CONFIG_FILE:-/etc/containerd/config.toml}"
CERTS_DIR="${CERTS_DIR:-/etc/containerd/certs.d}"
STATE_DIR="${STATE_DIR:-/var/lib/containerd}"
RUN_DIR="${RUN_DIR:-/run/containerd}"
SOCKET_PATH="${SOCKET_PATH:-/run/containerd/containerd.sock}"
DEFAULT_ENV_FILE="${DEFAULT_ENV_FILE:-/etc/default/containerd}"
AUDIT_RULES_FILE="${AUDIT_RULES_FILE:-/etc/audit/rules.d/containerd.rules}"

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
  if [ -e "$path" ]; then
    cp -a "$path" "${path}.bak.$(timestamp)"
  fi
}

discover_paths() {
  CONTAINERD_BIN="$(command -v containerd 2>/dev/null || true)"
  SHIM_LEGACY_BIN="$(command -v containerd-shim 2>/dev/null || true)"
  SHIM_V1_BIN="$(command -v containerd-shim-runc-v1 2>/dev/null || true)"
  SHIM_V2_BIN="$(command -v containerd-shim-runc-v2 2>/dev/null || true)"
  RUNTIME_BIN="$(command -v runc 2>/dev/null || true)"

  if have_cmd systemctl; then
    SERVICE_UNIT="$(systemctl show -p FragmentPath --value containerd 2>/dev/null || true)"
    SOCKET_UNIT="$(systemctl show -p FragmentPath --value containerd.socket 2>/dev/null || true)"
    SOCKET_UNIT_EXISTS=0
    if systemctl list-unit-files 2>/dev/null | grep -q '^containerd\.socket'; then
      SOCKET_UNIT_EXISTS=1
    fi
  else
    SERVICE_UNIT=""
    SOCKET_UNIT=""
    SOCKET_UNIT_EXISTS=0
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

audit_rule_exists() {
  local target="$1"
  local perm="$2"
  grep -RqsF -- "-w ${target} -p ${perm}" /etc/audit/rules.d 2>/dev/null
}

check_audit_target() {
  local path="$1"
  local perm="$2"
  local if_missing="${3:-warn}"
  local path_exists=1

  if [ -z "$path" ]; then
    if [ "$if_missing" = "fail" ]; then
      fail "未找到审计目标路径"
    else
      warn "未找到审计目标路径"
    fi
    return
  fi

  if [ ! -e "$path" ] && [ ! -S "$path" ]; then
    path_exists=0
  fi

  if audit_rule_exists "$path" "$perm"; then
    pass "已为 ${path} 配置审计规则"
  else
    fail "未为 ${path} 配置审计规则"
  fi

  if [ "$path_exists" -eq 0 ]; then
    if [ "$if_missing" = "fail" ]; then
      fail "审计目标不存在：${path}"
    else
      warn "审计目标不存在：${path}"
    fi
  fi
}

check_optional_audit_target() {
  local path="$1"
  local perm="$2"

  if [ -z "$path" ] || { [ ! -e "$path" ] && [ ! -S "$path" ]; }; then
    warn "可选审计目标不存在：${path:-未知}"
    return
  fi

  check_audit_target "$path" "$perm" warn
}

check_owner_mode_if_present() {
  local path="$1"
  local expected_owner="$2"
  local max_mode="$3"
  local item="$4"

  if [ -n "$path" ] && [ -e "$path" ]; then
    check_owner_mode "$path" "$expected_owner" "$max_mode" "$item"
  else
    warn "${item}：未找到路径"
  fi
}

check_owner_mode() {
  local path="$1"
  local expected_owner="$2"
  local max_mode="$3"
  local item="$4"
  local owner mode

  if [ ! -e "$path" ]; then
    fail "${item}：未找到 ${path}"
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

  if [ ! -e "$path" ]; then
    warn "${item}：未找到 ${path}"
    return
  fi

  mode="$(stat -c '%a' "$path")"
  if perm_stricter_or_equal "$mode" "$max_mode"; then
    pass "${item}：mode=${mode}"
  else
    fail "${item}：mode=${mode}，期望 mode<=${max_mode}"
  fi
}

check_config_line() {
  local pattern="$1"
  local item="$2"

  if [ ! -f "$CONFIG_FILE" ]; then
    fail "${item}：未找到 ${CONFIG_FILE}"
    return
  fi

  if grep -Eq "$pattern" "$CONFIG_FILE"; then
    pass "$item"
  else
    fail "$item"
  fi
}

check_version_alignment() {
  local major config_version

  if [ ! -f "$CONFIG_FILE" ]; then
    fail "配置版本检查：未找到 ${CONFIG_FILE}"
    return
  fi

  if [ -z "$CONTAINERD_BIN" ]; then
    warn "配置版本检查：未找到 containerd 二进制"
    return
  fi

  major="$("$CONTAINERD_BIN" --version 2>/dev/null | sed -n 's/.* \([0-9][0-9]*\)\..*/\1/p' | head -n1)"
  config_version="$(sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$CONFIG_FILE" | head -n1)"

  if [ -z "$major" ] || [ -z "$config_version" ]; then
    warn "配置版本检查：无法判断版本是否匹配"
    return
  fi

  case "$major" in
    1)
      if [ "$config_version" = "2" ]; then
        pass "containerd 1.x 的配置版本匹配"
      else
        fail "配置版本不匹配：containerd 1.x 应使用 version = 2"
      fi
      ;;
    2)
      if [ "$config_version" = "3" ]; then
        pass "containerd 2.x 的配置版本匹配"
      else
        fail "配置版本不匹配：containerd 2.x 应使用 version = 3"
      fi
      ;;
    *)
      warn "配置版本检查：暂不支持的主版本 ${major}"
      ;;
  esac
}

check_audit_rules() {
  if ! have_cmd auditctl; then
    warn "已跳过审计检查：未找到 auditctl"
    return
  fi

  check_audit_target "$CONFIG_DIR" wa warn
  check_audit_target "$CONFIG_FILE" wa fail
  check_audit_target "$CERTS_DIR" wa warn
  check_audit_target "$STATE_DIR" wa warn
  check_audit_target "$RUN_DIR" wa fail
  check_audit_target "$SOCKET_PATH" wa fail
  check_optional_audit_target "$DEFAULT_ENV_FILE" wa
  check_audit_target "$SERVICE_UNIT" wa warn
  check_audit_target "$SOCKET_UNIT" wa warn
  check_audit_target "$CONTAINERD_BIN" x fail
  check_audit_target "$SHIM_LEGACY_BIN" x warn
  check_audit_target "$SHIM_V1_BIN" x warn
  check_audit_target "$SHIM_V2_BIN" x warn
  check_audit_target "$RUNTIME_BIN" x warn
}

check_hosts_security() {
  if [ ! -d "$CERTS_DIR" ]; then
    warn "已跳过 registry 检查：未找到 ${CERTS_DIR}"
    return
  fi

  if grep -R -nE 'http://|skip_verify[[:space:]]*=[[:space:]]*true' "$CERTS_DIR" >/dev/null 2>&1; then
    fail "${CERTS_DIR} 下存在不安全的 registry 传输配置"
  else
    pass "${CERTS_DIR} 下未发现不安全的 registry 传输配置"
  fi
}

host_has_selinux() {
  if have_cmd selinuxenabled && selinuxenabled; then
    return 0
  fi

  [ -d /sys/fs/selinux ]
}

host_has_apparmor() {
  if [ -r /sys/module/apparmor/parameters/enabled ] && \
    grep -q 'Y' /sys/module/apparmor/parameters/enabled 2>/dev/null; then
    return 0
  fi

  have_cmd apparmor_parser
}

run_checks() {
  discover_paths

  check_audit_rules
  check_owner_mode "$CONFIG_DIR" "root:root" 755 "配置目录权限"
  check_owner_mode "$CONFIG_FILE" "root:root" 640 "配置文件权限"
  check_owner_mode_if_present "$DEFAULT_ENV_FILE" "root:root" 644 "默认环境文件权限"
  check_owner_mode_if_present "$SERVICE_UNIT" "root:root" 644 "service 单元文件权限"
  check_owner_mode_if_present "$SOCKET_UNIT" "root:root" 644 "socket 单元文件权限"

  if [ -d "$CERTS_DIR" ]; then
    check_owner_mode "$CERTS_DIR" "root:root" 755 "镜像仓库配置目录权限"
  else
    warn "未找到 registry 配置目录：${CERTS_DIR}"
  fi

  if [ -S "$SOCKET_PATH" ]; then
    check_owner_mode "$SOCKET_PATH" "root:root" 660 "套接字权限"
  else
    warn "未找到 Socket：${SOCKET_PATH}"
  fi

  check_mode_max "$RUN_DIR" 755 "运行目录权限"
  check_mode_max "$STATE_DIR" 755 "状态目录权限"

  if [ -n "$CONTAINERD_BIN" ]; then
    check_owner_mode "$CONTAINERD_BIN" "root:root" 755 "containerd 二进制权限"
  fi
  if [ -n "$SHIM_LEGACY_BIN" ]; then
    check_owner_mode "$SHIM_LEGACY_BIN" "root:root" 755 "containerd-shim 二进制权限"
  fi
  if [ -n "$SHIM_V1_BIN" ]; then
    check_owner_mode "$SHIM_V1_BIN" "root:root" 755 "containerd-shim-runc-v1 二进制权限"
  fi
  if [ -n "$SHIM_V2_BIN" ]; then
    check_owner_mode "$SHIM_V2_BIN" "root:root" 755 "containerd-shim-runc-v2 二进制权限"
  fi
  if [ -n "$RUNTIME_BIN" ]; then
    check_owner_mode "$RUNTIME_BIN" "root:root" 755 "runtime 二进制权限"
  fi

  check_version_alignment
  check_config_line 'SystemdCgroup[[:space:]]*=[[:space:]]*true' "SystemdCgroup 已启用"
  check_config_line 'cgroup_writable[[:space:]]*=[[:space:]]*false' "cgroup_writable 保持禁用"
  check_config_line 'privileged_without_host_devices[[:space:]]*=[[:space:]]*false' "privileged_without_host_devices 保持禁用"
  check_config_line 'privileged_without_host_devices_all_devices_allowed[[:space:]]*=[[:space:]]*false' "privileged_without_host_devices 不允许所有设备"

  if host_has_selinux; then
    check_config_line 'enable_selinux[[:space:]]*=[[:space:]]*true' "SELinux 集成已启用"
  else
    warn "已跳过 SELinux 集成检查：主机未检测到 SELinux"
  fi

  if host_has_apparmor; then
    check_config_line 'disable_apparmor[[:space:]]*=[[:space:]]*false' "AppArmor 集成已启用"
  else
    warn "已跳过 AppArmor 集成检查：主机未检测到 AppArmor"
  fi

  check_config_line 'tcp_address[[:space:]]*=[[:space:]]*""' "TCP 管理端点已禁用"
  check_config_line 'disable_tcp_service[[:space:]]*=[[:space:]]*true' "CRI TCP 服务已禁用"
  check_config_line 'stream_server_address[[:space:]]*=[[:space:]]*"127\.0\.0\.1"' "CRI streaming 仅监听回环地址"
  check_config_line 'level[[:space:]]*=[[:space:]]*"info"' "日志级别已设置为 info"
  check_config_line 'config_path[[:space:]]*=[[:space:]]*"/etc/containerd/certs\.d"' "镜像仓库 config_path 已配置"
  check_hosts_security

  printf '\n汇总：通过=%s 警告=%s 失败=%s\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
  if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
  fi
}

write_audit_rules() {
  {
    if [ -d "$CONFIG_DIR" ]; then
      printf -- '-w %s -p wa -k containerd-dir\n' "$CONFIG_DIR"
    fi

    printf -- '-w %s -p wa -k containerd-config\n' "$CONFIG_FILE"

    if [ -d "$CERTS_DIR" ]; then
      printf -- '-w %s -p wa -k containerd-registry\n' "$CERTS_DIR"
    fi

    if [ -d "$STATE_DIR" ]; then
      printf -- '-w %s -p wa -k containerd-state\n' "$STATE_DIR"
    fi

    if [ -n "$SERVICE_UNIT" ]; then
      printf -- '-w %s -p wa -k containerd-service\n' "$SERVICE_UNIT"
    fi

    if [ -n "$SOCKET_UNIT" ]; then
      printf -- '-w %s -p wa -k containerd-service\n' "$SOCKET_UNIT"
    fi

    if [ "$INCLUDE_RUN_DIR_AUDIT" -eq 1 ] && [ -d "$RUN_DIR" ]; then
      printf -- '-w %s -p wa -k containerd-run\n' "$RUN_DIR"
    fi

    if [ -S "$SOCKET_PATH" ] || [ -e "$SOCKET_PATH" ]; then
      printf -- '-w %s -p wa -k containerd-sock\n' "$SOCKET_PATH"
    fi

    if [ -f "$DEFAULT_ENV_FILE" ]; then
      printf -- '-w %s -p wa -k containerd-env\n' "$DEFAULT_ENV_FILE"
    fi

    if [ -n "$CONTAINERD_BIN" ]; then
      printf -- '-w %s -p x -k containerd-bin\n' "$CONTAINERD_BIN"
    fi

    if [ -n "$SHIM_LEGACY_BIN" ]; then
      printf -- '-w %s -p x -k containerd-bin\n' "$SHIM_LEGACY_BIN"
    fi

    if [ -n "$SHIM_V1_BIN" ]; then
      printf -- '-w %s -p x -k containerd-bin\n' "$SHIM_V1_BIN"
    fi

    if [ -n "$SHIM_V2_BIN" ]; then
      printf -- '-w %s -p x -k containerd-bin\n' "$SHIM_V2_BIN"
    fi

    if [ -n "$RUNTIME_BIN" ]; then
      printf -- '-w %s -p x -k containerd-runtime\n' "$RUNTIME_BIN"
    fi
  } >"$AUDIT_RULES_FILE"
}

fix_audit() {
  require_root
  discover_paths

  install -d -m 750 /etc/audit/rules.d
  backup_if_exists "$AUDIT_RULES_FILE"
  write_audit_rules
  chmod 640 "$AUDIT_RULES_FILE"

  if have_cmd augenrules; then
    augenrules --load
  elif have_cmd service; then
    service auditd restart
  else
    warn "审计规则已写入，但未找到 augenrules 或 service 命令"
  fi

  info "审计规则已更新到 ${AUDIT_RULES_FILE}"
}

fix_perms() {
  require_root
  discover_paths

  if [ -d "$CONFIG_DIR" ]; then
    chown root:root "$CONFIG_DIR"
    chmod 755 "$CONFIG_DIR"
  fi

  if [ -f "$CONFIG_FILE" ]; then
    chown root:root "$CONFIG_FILE"
    chmod 640 "$CONFIG_FILE"
  fi

  if [ -f "$DEFAULT_ENV_FILE" ]; then
    chown root:root "$DEFAULT_ENV_FILE"
    chmod 644 "$DEFAULT_ENV_FILE"
  fi

  if [ -n "$SERVICE_UNIT" ] && [ -e "$SERVICE_UNIT" ]; then
    chown root:root "$SERVICE_UNIT"
    chmod 644 "$SERVICE_UNIT"
  fi

  if [ -n "$SOCKET_UNIT" ] && [ -e "$SOCKET_UNIT" ]; then
    chown root:root "$SOCKET_UNIT"
    chmod 644 "$SOCKET_UNIT"
  fi

  if [ -d "$CERTS_DIR" ]; then
    chown -R root:root "$CERTS_DIR"
    find "$CERTS_DIR" -type d -exec chmod 755 {} +
    find "$CERTS_DIR" -type f -name '*.key' -exec chmod 600 {} +
    find "$CERTS_DIR" -type f ! -name '*.key' -exec chmod 644 {} +
  fi

  if [ -S "$SOCKET_PATH" ]; then
    chown root:root "$SOCKET_PATH"
    chmod 660 "$SOCKET_PATH"
  fi

  if [ -d "$RUN_DIR" ]; then
    chmod go-w "$RUN_DIR"
  fi

  if [ -d "$STATE_DIR" ]; then
    chmod go-w "$STATE_DIR"
  fi

  if [ -n "$CONTAINERD_BIN" ]; then
    chmod go-w "$CONTAINERD_BIN"
  fi

  if [ -n "$SHIM_LEGACY_BIN" ]; then
    chmod go-w "$SHIM_LEGACY_BIN"
  fi

  if [ -n "$SHIM_V1_BIN" ]; then
    chmod go-w "$SHIM_V1_BIN"
  fi

  if [ -n "$SHIM_V2_BIN" ]; then
    chmod go-w "$SHIM_V2_BIN"
  fi

  if [ -n "$RUNTIME_BIN" ]; then
    chmod go-w "$RUNTIME_BIN"
  fi

  info "权限修复已完成"
}

fix_socket_dropin() {
  require_root
  discover_paths

  if ! have_cmd systemctl; then
    echo "未找到 systemctl。" >&2
    exit 1
  fi

  install -d -m 755 /etc/systemd/system/containerd.socket.d
  cat >/etc/systemd/system/containerd.socket.d/10-permissions.conf <<'EOF'
[Socket]
SocketMode=0660
SocketUser=root
SocketGroup=root
EOF

  chown root:root /etc/systemd/system/containerd.socket.d/10-permissions.conf
  chmod 644 /etc/systemd/system/containerd.socket.d/10-permissions.conf
  systemctl daemon-reload

  if [ "$SOCKET_UNIT_EXISTS" -eq 1 ]; then
    systemctl restart containerd.socket || true
  fi

  systemctl restart containerd || true
  info "套接字 drop-in 已更新"
}

print_config() {
  cat <<'EOF'
# containerd 2.x 示例
version = 3

[plugins.'io.containerd.cri.v1.runtime']
  enable_selinux = true
  disable_apparmor = false

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc]
  privileged_without_host_devices = false
  privileged_without_host_devices_all_devices_allowed = false
  cgroup_writable = false

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
  SystemdCgroup = true

[plugins.'io.containerd.grpc.v1.cri']
  disable_tcp_service = true
  stream_server_address = "127.0.0.1"
  stream_server_port = "0"
  enable_tls_streaming = false

[plugins.'io.containerd.cri.v1.images'.registry]
  config_path = "/etc/containerd/certs.d"

[grpc]
  address = "/run/containerd/containerd.sock"
  tcp_address = ""

[debug]
  level = "info"

# containerd 1.x 示例
version = 2

[plugins."io.containerd.grpc.v1.cri"]
  enable_selinux = true
  disable_apparmor = false
  disable_tcp_service = true
  stream_server_address = "127.0.0.1"
  stream_server_port = "0"
  enable_tls_streaming = false

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
  privileged_without_host_devices = false
  privileged_without_host_devices_all_devices_allowed = false
  cgroup_writable = false

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = true

[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "/etc/containerd/certs.d"

[grpc]
  address = "/run/containerd/containerd.sock"
  tcp_address = ""

[debug]
  level = "info"
EOF
}

usage() {
  cat <<'EOF'
用法：
  containerd_host_baseline.sh check              执行主机侧基线检查，输出通过 / 警告 / 失败
  containerd_host_baseline.sh fix-audit          生成并加载 containerd 审计规则
  containerd_host_baseline.sh fix-perms          修复目录、文件、二进制和套接字权限
  containerd_host_baseline.sh fix-socket-dropin  生成 containerd.socket 权限 drop-in
  containerd_host_baseline.sh print-config       输出建议配置片段，供人工合并
  containerd_host_baseline.sh -h|--help|help     显示帮助信息

说明：
  默认已包含 /run/containerd 审计规则；--include-run-dir-audit 参数仅为兼容保留。
EOF
}

case "$MODE" in
  check)
    run_checks
    ;;
  fix-audit)
    fix_audit
    ;;
  fix-perms)
    fix_perms
    ;;
  fix-socket-dropin)
    fix_socket_dropin
    ;;
  print-config)
    print_config
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
