#!/usr/bin/env bash

set -euo pipefail

MODE="${1:-check}"
shift || true

INCLUDE_RUN_DIR_AUDIT=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --include-run-dir-audit)
      INCLUDE_RUN_DIR_AUDIT=1
      ;;
    *)
      echo "Unknown option: $1" >&2
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
  printf '[INFO] %s\n' "$*"
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf '[PASS] %s\n' "$*"
}

warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  printf '[WARN] %s\n' "$*"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '[FAIL] %s\n' "$*"
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "This action requires root." >&2
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
  SHIM_BIN="$(command -v containerd-shim-runc-v2 2>/dev/null || true)"
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
  grep -Rqs -- "-w ${target} -p ${perm}" /etc/audit/rules.d 2>/dev/null
}

check_owner_mode() {
  local path="$1"
  local expected_owner="$2"
  local max_mode="$3"
  local item="$4"
  local owner mode

  if [ ! -e "$path" ]; then
    fail "${item}: ${path} not found"
    return
  fi

  owner="$(stat -c '%U:%G' "$path")"
  mode="$(stat -c '%a' "$path")"

  if [ "$owner" = "$expected_owner" ] && perm_stricter_or_equal "$mode" "$max_mode"; then
    pass "${item}: ${owner} ${mode}"
  else
    fail "${item}: current=${owner} ${mode}, expected owner=${expected_owner}, mode<=${max_mode}"
  fi
}

check_mode_max() {
  local path="$1"
  local max_mode="$2"
  local item="$3"
  local mode

  if [ ! -e "$path" ]; then
    warn "${item}: ${path} not found"
    return
  fi

  mode="$(stat -c '%a' "$path")"
  if perm_stricter_or_equal "$mode" "$max_mode"; then
    pass "${item}: mode=${mode}"
  else
    fail "${item}: mode=${mode}, expected mode<=${max_mode}"
  fi
}

check_config_line() {
  local pattern="$1"
  local item="$2"

  if [ ! -f "$CONFIG_FILE" ]; then
    fail "${item}: ${CONFIG_FILE} not found"
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
    fail "Config version check: ${CONFIG_FILE} not found"
    return
  fi

  if [ -z "$CONTAINERD_BIN" ]; then
    warn "Config version check: containerd binary not found"
    return
  fi

  major="$("$CONTAINERD_BIN" --version 2>/dev/null | sed -n 's/.* \([0-9][0-9]*\)\..*/\1/p' | head -n1)"
  config_version="$(sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$CONFIG_FILE" | head -n1)"

  if [ -z "$major" ] || [ -z "$config_version" ]; then
    warn "Config version check: unable to determine version alignment"
    return
  fi

  case "$major" in
    1)
      if [ "$config_version" = "2" ]; then
        pass "Config version is aligned for containerd 1.x"
      else
        fail "Config version mismatch: containerd 1.x should use version = 2"
      fi
      ;;
    2)
      if [ "$config_version" = "3" ]; then
        pass "Config version is aligned for containerd 2.x"
      else
        fail "Config version mismatch: containerd 2.x should use version = 3"
      fi
      ;;
    *)
      warn "Config version check: unsupported major version ${major}"
      ;;
  esac
}

check_audit_rules() {
  if ! have_cmd auditctl; then
    warn "Audit check skipped: auditctl not found"
    return
  fi

  if audit_rule_exists "$CONFIG_FILE" wa; then
    pass "Audit rule exists for ${CONFIG_FILE}"
  else
    fail "Audit rule missing for ${CONFIG_FILE}"
  fi

  if [ -d "$CERTS_DIR" ]; then
    if audit_rule_exists "$CERTS_DIR" wa; then
      pass "Audit rule exists for ${CERTS_DIR}"
    else
      fail "Audit rule missing for ${CERTS_DIR}"
    fi
  else
    warn "Audit check skipped for ${CERTS_DIR}: directory not found"
  fi

  if [ -n "$SERVICE_UNIT" ]; then
    if audit_rule_exists "$SERVICE_UNIT" wa; then
      pass "Audit rule exists for ${SERVICE_UNIT}"
    else
      fail "Audit rule missing for ${SERVICE_UNIT}"
    fi
  else
    warn "Service unit path not found"
  fi

  if [ -n "$SOCKET_UNIT" ]; then
    if audit_rule_exists "$SOCKET_UNIT" wa; then
      pass "Audit rule exists for ${SOCKET_UNIT}"
    else
      fail "Audit rule missing for ${SOCKET_UNIT}"
    fi
  else
    warn "Socket unit path not found"
  fi

  if [ -n "$CONTAINERD_BIN" ]; then
    if audit_rule_exists "$CONTAINERD_BIN" x; then
      pass "Audit rule exists for ${CONTAINERD_BIN}"
    else
      fail "Audit rule missing for ${CONTAINERD_BIN}"
    fi
  else
    fail "containerd binary not found"
  fi

  if [ -n "$SHIM_BIN" ]; then
    if audit_rule_exists "$SHIM_BIN" x; then
      pass "Audit rule exists for ${SHIM_BIN}"
    else
      fail "Audit rule missing for ${SHIM_BIN}"
    fi
  else
    warn "containerd-shim-runc-v2 binary not found"
  fi

  if [ -n "$RUNTIME_BIN" ]; then
    if audit_rule_exists "$RUNTIME_BIN" x; then
      pass "Audit rule exists for ${RUNTIME_BIN}"
    else
      fail "Audit rule missing for ${RUNTIME_BIN}"
    fi
  else
    warn "runc binary not found"
  fi
}

check_hosts_security() {
  if [ ! -d "$CERTS_DIR" ]; then
    warn "Registry host check skipped: ${CERTS_DIR} not found"
    return
  fi

  if grep -R -nE 'http://|skip_verify[[:space:]]*=[[:space:]]*true' "$CERTS_DIR" >/dev/null 2>&1; then
    fail "Insecure registry transport settings found under ${CERTS_DIR}"
  else
    pass "No insecure registry transport settings found under ${CERTS_DIR}"
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
  check_owner_mode "$CONFIG_DIR" "root:root" 755 "Config directory permission"
  check_owner_mode "$CONFIG_FILE" "root:root" 640 "Config file permission"

  if [ -d "$CERTS_DIR" ]; then
    check_owner_mode "$CERTS_DIR" "root:root" 755 "Registry config directory permission"
  else
    warn "Registry config directory not found: ${CERTS_DIR}"
  fi

  if [ -S "$SOCKET_PATH" ]; then
    check_owner_mode "$SOCKET_PATH" "root:root" 660 "Socket permission"
  else
    warn "Socket not found: ${SOCKET_PATH}"
  fi

  check_mode_max "$RUN_DIR" 755 "Run directory permission"
  check_mode_max "$STATE_DIR" 755 "State directory permission"

  if [ -n "$CONTAINERD_BIN" ]; then
    check_mode_max "$CONTAINERD_BIN" 755 "containerd binary permission"
  fi
  if [ -n "$SHIM_BIN" ]; then
    check_mode_max "$SHIM_BIN" 755 "shim binary permission"
  fi
  if [ -n "$RUNTIME_BIN" ]; then
    check_mode_max "$RUNTIME_BIN" 755 "runtime binary permission"
  fi

  check_version_alignment
  check_config_line 'SystemdCgroup[[:space:]]*=[[:space:]]*true' "SystemdCgroup is enabled"

  if host_has_selinux; then
    check_config_line 'enable_selinux[[:space:]]*=[[:space:]]*true' "SELinux integration is enabled"
  else
    warn "SELinux integration check skipped: host SELinux not detected"
  fi

  if host_has_apparmor; then
    check_config_line 'disable_apparmor[[:space:]]*=[[:space:]]*false' "AppArmor integration is enabled"
  else
    warn "AppArmor integration check skipped: host AppArmor not detected"
  fi

  check_config_line 'tcp_address[[:space:]]*=[[:space:]]*""' "TCP management endpoint is disabled"
  check_config_line 'disable_tcp_service[[:space:]]*=[[:space:]]*true' "CRI TCP service is disabled"
  check_config_line 'stream_server_address[[:space:]]*=[[:space:]]*"127\.0\.0\.1"' "CRI streaming listens on loopback"
  check_config_line 'config_path[[:space:]]*=[[:space:]]*"/etc/containerd/certs\.d"' "Registry config_path is configured"
  check_hosts_security

  printf '\nSummary: PASS=%s WARN=%s FAIL=%s\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
  if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
  fi
}

write_audit_rules() {
  {
    printf -- '-w %s -p wa -k containerd-config\n' "$CONFIG_FILE"

    if [ -d "$CERTS_DIR" ]; then
      printf -- '-w %s -p wa -k containerd-registry\n' "$CERTS_DIR"
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

    if [ -n "$CONTAINERD_BIN" ]; then
      printf -- '-w %s -p x -k containerd-bin\n' "$CONTAINERD_BIN"
    fi

    if [ -n "$SHIM_BIN" ]; then
      printf -- '-w %s -p x -k containerd-bin\n' "$SHIM_BIN"
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
    warn "Audit rules written, but no augenrules/service command was found"
  fi

  info "Audit rules updated at ${AUDIT_RULES_FILE}"
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

  if [ -n "$SHIM_BIN" ]; then
    chmod go-w "$SHIM_BIN"
  fi

  if [ -n "$RUNTIME_BIN" ]; then
    chmod go-w "$RUNTIME_BIN"
  fi

  info "Permission fixes applied"
}

fix_socket_dropin() {
  require_root
  discover_paths

  if ! have_cmd systemctl; then
    echo "systemctl not found." >&2
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
  info "Socket drop-in updated"
}

print_config() {
  cat <<'EOF'
# containerd 2.x
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

# containerd 1.x
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
Usage:
  containerd_host_baseline.sh check
  containerd_host_baseline.sh fix-audit [--include-run-dir-audit]
  containerd_host_baseline.sh fix-perms
  containerd_host_baseline.sh fix-socket-dropin
  containerd_host_baseline.sh print-config
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
