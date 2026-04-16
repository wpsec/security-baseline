#!/usr/bin/env bash

set -euo pipefail

MODE="${1:-env-info}"
shift || true

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

LOGIN_DEFS="${LOGIN_DEFS:-/etc/login.defs}"
PROFILE_TIMEOUT_FILE="${PROFILE_TIMEOUT_FILE:-/etc/profile.d/99-security-timeout.sh}"
AUDIT_RULES_FILE="${AUDIT_RULES_FILE:-/etc/audit/rules.d/linux_mlps.rules}"
AUDIT_MANAGED_BEGIN="# BEGIN managed by linux_mlps_baseline.sh"
AUDIT_MANAGED_END="# END managed by linux_mlps_baseline.sh"
SYSCTL_ASLR_FILE="${SYSCTL_ASLR_FILE:-/etc/sysctl.d/99-security-baseline.conf}"

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

discover_paths() {
  SSHD_BIN="$(command -v sshd 2>/dev/null || true)"
  AUDITCTL_BIN="$(command -v auditctl 2>/dev/null || true)"
  RSYSLOG_BIN="$(command -v rsyslogd 2>/dev/null || true)"
  FAILLOCK_BIN="$(command -v faillock 2>/dev/null || true)"
  AUTHSELECT_BIN="$(command -v authselect 2>/dev/null || true)"

  SSH_SERVICE_NAME=""
  if have_cmd systemctl; then
    if systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service'; then
      SSH_SERVICE_NAME="sshd"
    elif systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
      SSH_SERVICE_NAME="ssh"
    fi
  fi

  SSHD_CONFIG="$(find_sshd_config)"
}

find_sshd_config() {
  if [ -f /etc/ssh/sshd_config ]; then
    echo "/etc/ssh/sshd_config"
    return
  fi

  echo ""
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

service_enabled() {
  local svc="$1"

  if ! have_cmd systemctl || [ -z "$svc" ]; then
    return 1
  fi

  systemctl is-enabled "$svc" >/dev/null 2>&1
}

service_active() {
  local svc="$1"

  if ! have_cmd systemctl || [ -z "$svc" ]; then
    return 1
  fi

  systemctl is-active "$svc" >/dev/null 2>&1
}

read_sshd_value() {
  local key="$1"

  if [ -z "$SSHD_BIN" ] || [ -z "$SSHD_CONFIG" ]; then
    echo ""
    return
  fi

  "$SSHD_BIN" -T -f "$SSHD_CONFIG" 2>/dev/null | awk -v key="$key" '$1 == key {print $2; exit}'
}

login_defs_value() {
  local key="$1"

  if [ ! -f "$LOGIN_DEFS" ]; then
    echo ""
    return
  fi

  awk -v key="$key" '$1 == key {print $2; exit}' "$LOGIN_DEFS"
}

audit_rule_exists() {
  local target="$1"
  grep -RqsF -- "$target" /etc/audit/rules.d 2>/dev/null
}

upsert_login_defs_key() {
  local key="$1"
  local value="$2"
  local file="$3"
  local tmp

  tmp="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    BEGIN { done = 0 }
    /^[[:space:]]*#/ { print; next }
    $1 == key {
      if (!done) {
        print key " " value
        done = 1
      }
      next
    }
    { print }
    END {
      if (!done) {
        print key " " value
      }
    }
  ' "$file" >"$tmp"
  mv "$tmp" "$file"
}

ensure_sshd_setting() {
  local key="$1"
  local value="$2"
  local file="$3"
  local tmp

  tmp="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    BEGIN { done = 0 }
    {
      lower = tolower($1)
      target = tolower(key)
      if (lower == target) {
        if (!done) {
          print key " " value
          done = 1
        }
        next
      }
      print
    }
    END {
      if (!done) {
        print key " " value
      }
    }
  ' "$file" >"$tmp"
  mv "$tmp" "$file"
}

auth_stack_files() {
  local files=""

  for f in /etc/pam.d/system-auth /etc/pam.d/password-auth /etc/pam.d/common-password /etc/pam.d/common-auth; do
    if [ -f "$f" ]; then
      files="${files} ${f}"
    fi
  done

  echo "$files"
}

check_empty_passwords() {
  local users

  if [ ! -r /etc/shadow ]; then
    warn "空密码账户检查：当前无权读取 /etc/shadow"
    return
  fi

  users="$(awk -F: 'length($2)==0 {print $1}' /etc/shadow)"
  if [ -z "$users" ]; then
    pass "未发现空密码账户"
  else
    fail "发现空密码账户：$(echo "$users" | paste -sd ',' -)"
  fi
}

check_uid_zero_uniqueness() {
  local users count

  users="$(awk -F: '($3 == 0) {print $1}' /etc/passwd)"
  count="$(echo "$users" | sed '/^$/d' | wc -l | tr -d ' ')"

  if [ "$count" = "1" ] && [ "$users" = "root" ]; then
    pass "root 是唯一 UID 0 账户"
  else
    fail "存在多个 UID 0 账户：$(echo "$users" | paste -sd ',' -)"
  fi
}

check_password_policy() {
  local max_days min_days warn_age auth_files

  max_days="$(login_defs_value PASS_MAX_DAYS)"
  min_days="$(login_defs_value PASS_MIN_DAYS)"
  warn_age="$(login_defs_value PASS_WARN_AGE)"

  if [ -n "$max_days" ] && [ "$max_days" -le 90 ]; then
    pass "PASS_MAX_DAYS=${max_days}"
  else
    fail "PASS_MAX_DAYS 未设置为 90 或更严格"
  fi

  if [ -n "$min_days" ] && [ "$min_days" -ge 1 ]; then
    pass "PASS_MIN_DAYS=${min_days}"
  else
    fail "PASS_MIN_DAYS 未设置为 1 或更大"
  fi

  if [ -n "$warn_age" ] && [ "$warn_age" -ge 7 ]; then
    pass "PASS_WARN_AGE=${warn_age}"
  else
    fail "PASS_WARN_AGE 未设置为 7 或更大"
  fi

  auth_files="$(auth_stack_files)"
  if [ -z "$auth_files" ]; then
    warn "未检测到常见 PAM 密码策略文件"
    return
  fi

  if grep -Eq 'pam_pwquality\.so|pam_cracklib\.so' $auth_files 2>/dev/null; then
    pass "已检测到密码复杂度模块"
  else
    fail "未检测到密码复杂度模块"
  fi

  if grep -Eq 'remember=([5-9]|[1-9][0-9]+)' $auth_files 2>/dev/null; then
    pass "已检测到密码历史复用限制"
  else
    fail "未检测到 remember >= 5 的密码历史复用限制"
  fi
}

check_faillock() {
  local auth_files

  auth_files="$(auth_stack_files)"
  if [ -z "$auth_files" ]; then
    warn "登录失败锁定检查：未检测到常见 PAM 认证文件"
    return
  fi

  if grep -Eq 'pam_faillock\.so|pam_tally2\.so' $auth_files 2>/dev/null; then
    pass "已启用登录失败处理策略"
  else
    fail "未检测到登录失败处理策略"
  fi
}

check_tmout() {
  local value

  value="$(grep -R -h -E '^[[:space:]]*TMOUT=' /etc/profile /etc/profile.d /etc/bashrc /etc/bash.bashrc 2>/dev/null | tail -n1 | sed 's/.*=//;s/[^0-9].*//')"
  if [ -n "$value" ] && [ "$value" -le 900 ] && [ "$value" -gt 0 ]; then
    pass "已配置 shell 空闲超时 TMOUT=${value}"
  else
    fail "未检测到合规的 shell 空闲超时配置"
  fi
}

check_sshd_settings() {
  local permit_empty max_auth log_level client_alive_interval client_alive_count permit_root

  if [ -z "$SSHD_BIN" ] || [ -z "$SSHD_CONFIG" ]; then
    warn "SSH 检查已跳过：未检测到 sshd 或 sshd_config"
    return
  fi

  permit_empty="$(read_sshd_value permitemptypasswords)"
  max_auth="$(read_sshd_value maxauthtries)"
  log_level="$(read_sshd_value loglevel)"
  client_alive_interval="$(read_sshd_value clientaliveinterval)"
  client_alive_count="$(read_sshd_value clientalivecountmax)"
  permit_root="$(read_sshd_value permitrootlogin)"

  if [ "$permit_empty" = "no" ]; then
    pass "SSH 已禁止空密码登录"
  else
    fail "SSH 未禁止空密码登录"
  fi

  if [ -n "$max_auth" ] && [ "$max_auth" -ge 3 ] && [ "$max_auth" -le 6 ]; then
    pass "SSH MaxAuthTries=${max_auth}"
  else
    fail "SSH MaxAuthTries 未设置在 3-6 之间"
  fi

  if [ "$log_level" = "INFO" ] || [ "$log_level" = "VERBOSE" ]; then
    pass "SSH LogLevel=${log_level}"
  else
    fail "SSH LogLevel 未设置为 INFO 或更高"
  fi

  if [ -n "$client_alive_interval" ] && [ "$client_alive_interval" -gt 0 ] &&
    [ -n "$client_alive_count" ] && [ "$client_alive_count" -le 3 ]; then
    pass "SSH 已配置空闲超时退出"
  else
    fail "SSH 未配置有效的空闲超时退出"
  fi

  if [ "$permit_root" = "no" ]; then
    pass "SSH 已禁止 root 直接登录"
  else
    warn "SSH 仍允许 root 直接登录"
  fi
}

check_services() {
  if service_enabled auditd && service_active auditd; then
    pass "auditd 已启用并运行"
  else
    fail "auditd 未启用或未运行"
  fi

  if have_cmd systemctl; then
    if systemctl list-unit-files 2>/dev/null | grep -q '^rsyslog\.service'; then
      if service_enabled rsyslog && service_active rsyslog; then
        pass "rsyslog 已启用并运行"
      else
        fail "rsyslog 未启用或未运行"
      fi
    else
      warn "未检测到 rsyslog.service，需确认是否使用等效日志服务"
    fi
  else
    warn "未检测到 systemctl，跳过服务启停检查"
  fi
}

check_audit_rules() {
  if [ -z "$AUDITCTL_BIN" ]; then
    warn "已跳过审计规则检查：未找到 auditctl"
    return
  fi

  for target in "/etc/passwd" "/etc/group" "/etc/shadow" "/etc/gshadow" "/etc/pam.d" "/etc/login.defs" "/etc/ssh/sshd_config" "/etc/sudoers"; do
    if audit_rule_exists "$target"; then
      pass "已为 ${target} 配置审计规则"
    else
      fail "未为 ${target} 配置审计规则"
    fi
  done

  if [ -d /etc/sudoers.d ]; then
    if audit_rule_exists "/etc/sudoers.d"; then
      pass "已为 /etc/sudoers.d 配置审计规则"
    else
      fail "未为 /etc/sudoers.d 配置审计规则"
    fi
  fi
}

check_file_permissions() {
  check_owner_mode "/etc/passwd" "root:root" 644 "/etc/passwd 权限"
  check_owner_mode "/etc/group" "root:root" 644 "/etc/group 权限"

  if [ -e /etc/shadow ]; then
    check_owner_mode "/etc/shadow" "root:shadow" 640 "/etc/shadow 权限"
  else
    fail "/etc/shadow 权限：未找到 /etc/shadow"
  fi

  if [ -e /etc/gshadow ]; then
    check_owner_mode "/etc/gshadow" "root:shadow" 640 "/etc/gshadow 权限"
  else
    warn "/etc/gshadow 权限：未找到 /etc/gshadow"
  fi

  if [ -n "$SSHD_CONFIG" ]; then
    check_owner_mode "$SSHD_CONFIG" "root:root" 644 "sshd_config 权限"
  fi

  if [ -e /etc/sudoers ]; then
    check_owner_mode "/etc/sudoers" "root:root" 440 "/etc/sudoers 权限"
  else
    warn "/etc/sudoers 权限：未找到 /etc/sudoers"
  fi

  if [ -d /etc/sudoers.d ]; then
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      check_owner_mode "$file" "root:root" 440 "sudoers.d 文件权限"
    done < <(find /etc/sudoers.d -maxdepth 1 -type f 2>/dev/null)
  fi

  if [ -d /var/log/audit ]; then
    check_owner_mode "/var/log/audit" "root:root" 750 "/var/log/audit 目录权限"
    if [ -f /var/log/audit/audit.log ]; then
      check_owner_mode "/var/log/audit/audit.log" "root:root" 640 "audit.log 权限"
    fi
  else
    warn "未找到 /var/log/audit，需确认审计日志目录位置"
  fi
}

check_sudo_scope() {
  if [ -f /etc/sudoers ] || [ -d /etc/sudoers.d ]; then
    if grep -R -nE 'NOPASSWD:[[:space:]]*ALL|ALL=\(ALL(:ALL)?\)[[:space:]]*ALL' /etc/sudoers /etc/sudoers.d 2>/dev/null >/dev/null; then
      warn "发现可能过宽的 sudo 授权规则，需人工复核"
    else
      pass "未发现明显过宽的 sudo 授权规则"
    fi
  else
    warn "未检测到 sudoers 配置，跳过最小权限检查"
  fi
}

check_aslr() {
  local value

  value="$(sysctl -n kernel.randomize_va_space 2>/dev/null || true)"
  if [ "$value" = "2" ]; then
    pass "ASLR 已启用"
  else
    fail "ASLR 未启用到推荐值 2"
  fi
}

print_manual_findings() {
  cat <<'EOF'
[信息] 以下控制项需人工或平台侧能力补充治理：
- 默认账户识别、重命名与删除
- 多余账户、过期账户、共享账户清理
- 已知漏洞扫描、补丁评估与灰度修补
- 恶意代码防护、EDR / HIDS / 杀毒引擎
- 入侵告警与高危事件联动
- 运维源地址白名单、堡垒机、ACL、安全组
- 最小安装与不必要服务下线的业务影响评估
EOF
}

print_env_info() {
  local os_name kernel ssh_enabled ssh_active audit_enabled audit_active rsyslog_enabled rsyslog_active

  discover_paths

  os_name="$(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"')"
  kernel="$(uname -r)"

  if [ -n "$SSH_SERVICE_NAME" ]; then
    ssh_enabled="$(systemctl is-enabled "$SSH_SERVICE_NAME" 2>/dev/null || true)"
    ssh_active="$(systemctl is-active "$SSH_SERVICE_NAME" 2>/dev/null || true)"
  else
    ssh_enabled="未知"
    ssh_active="未知"
  fi

  audit_enabled="$(systemctl is-enabled auditd 2>/dev/null || true)"
  audit_active="$(systemctl is-active auditd 2>/dev/null || true)"
  rsyslog_enabled="$(systemctl is-enabled rsyslog 2>/dev/null || true)"
  rsyslog_active="$(systemctl is-active rsyslog 2>/dev/null || true)"

  echo "Linux 等保三级与最低安全合规环境信息："
  printf '  %-24s %s\n' "当前目录" "$PWD"
  printf '  %-24s %s\n' "发行版" "${os_name:-未知}"
  printf '  %-24s %s\n' "内核版本" "$kernel"
  printf '  %-24s %s\n' "sshd 二进制" "${SSHD_BIN:-未检测到}"
  printf '  %-24s %s\n' "sshd 配置" "${SSHD_CONFIG:-未检测到}"
  printf '  %-24s %s\n' "SSH 服务名" "${SSH_SERVICE_NAME:-未检测到}"
  printf '  %-24s %s / %s\n' "SSH 状态" "${ssh_enabled:-未知}" "${ssh_active:-未知}"
  printf '  %-24s %s / %s\n' "auditd 状态" "${audit_enabled:-未知}" "${audit_active:-未知}"
  printf '  %-24s %s / %s\n' "rsyslog 状态" "${rsyslog_enabled:-未知}" "${rsyslog_active:-未知}"
  printf '  %-24s %s\n' "authselect" "${AUTHSELECT_BIN:-未检测到}"
  printf '  %-24s %s\n' "faillock" "${FAILLOCK_BIN:-未检测到}"
  printf '  %-24s %s\n' "login.defs" "$LOGIN_DEFS"
  printf '  %-24s %s\n' "审计规则文件" "$AUDIT_RULES_FILE"
  printf '  %-24s %s\n' "ASLR 配置文件" "$SYSCTL_ASLR_FILE"
}

emit_audit_rules_content() {
  cat <<'EOF'
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/security/opasswd -p wa -k identity
-w /etc/pam.d -p wa -k pam
-w /etc/login.defs -p wa -k login_defs
-w /etc/ssh/sshd_config -p wa -k sshd
-w /etc/sudoers -p wa -k scope
-w /etc/sudoers.d -p wa -k scope
-w /var/log/lastlog -p wa -k logins
-w /var/run/faillock -p wa -k logins
EOF
}

write_audit_rules() {
  local tmp existing_without_managed

  tmp="$(mktemp)"
  existing_without_managed="$(mktemp)"

  if [ -f "$AUDIT_RULES_FILE" ]; then
    awk -v begin="$AUDIT_MANAGED_BEGIN" -v end="$AUDIT_MANAGED_END" '
      $0 == begin {
        in_block = 1
        next
      }
      $0 == end {
        in_block = 0
        next
      }
      !in_block {
        print
      }
    ' "$AUDIT_RULES_FILE" >"$existing_without_managed"
  fi

  if [ -s "$existing_without_managed" ]; then
    cat "$existing_without_managed" >"$tmp"
    printf '\n' >>"$tmp"
  fi

  printf '%s\n' "$AUDIT_MANAGED_BEGIN" >>"$tmp"
  emit_audit_rules_content >>"$tmp"
  printf '%s\n' "$AUDIT_MANAGED_END" >>"$tmp"

  mv "$tmp" "$AUDIT_RULES_FILE"
  rm -f "$existing_without_managed"
}

fix_auth() {
  require_root
  discover_paths

  if [ -f "$LOGIN_DEFS" ]; then
    backup_if_exists "$LOGIN_DEFS"
    upsert_login_defs_key "PASS_MAX_DAYS" "90" "$LOGIN_DEFS"
    upsert_login_defs_key "PASS_MIN_DAYS" "1" "$LOGIN_DEFS"
    upsert_login_defs_key "PASS_WARN_AGE" "7" "$LOGIN_DEFS"
    info "已更新 ${LOGIN_DEFS} 中的密码周期默认值"
  else
    warn "未找到 ${LOGIN_DEFS}，跳过密码周期默认值修复"
  fi

  install -d -m 755 "$(dirname "$PROFILE_TIMEOUT_FILE")"
  cat >"$PROFILE_TIMEOUT_FILE" <<'EOF'
# 设置 shell 空闲超时，减少无人值守会话暴露窗口。
TMOUT=900
readonly TMOUT
export TMOUT
EOF
  chown root:root "$PROFILE_TIMEOUT_FILE"
  chmod 644 "$PROFILE_TIMEOUT_FILE"
  info "已写入 shell 空闲超时配置：${PROFILE_TIMEOUT_FILE}"

  if [ -n "$SSHD_CONFIG" ]; then
    backup_if_exists "$SSHD_CONFIG"
    ensure_sshd_setting "PermitEmptyPasswords" "no" "$SSHD_CONFIG"
    ensure_sshd_setting "MaxAuthTries" "4" "$SSHD_CONFIG"
    ensure_sshd_setting "LogLevel" "INFO" "$SSHD_CONFIG"
    ensure_sshd_setting "ClientAliveInterval" "300" "$SSHD_CONFIG"
    ensure_sshd_setting "ClientAliveCountMax" "0" "$SSHD_CONFIG"
    info "已加固 SSH 常见认证参数：${SSHD_CONFIG}"

    if [ -n "$SSH_SERVICE_NAME" ] && have_cmd systemctl; then
      systemctl reload "$SSH_SERVICE_NAME" || systemctl restart "$SSH_SERVICE_NAME" || true
    fi
  else
    warn "未找到 sshd_config，跳过 SSH 认证配置修复"
  fi

  if [ -n "$AUTHSELECT_BIN" ]; then
    warn "检测到 authselect，密码复杂度和 faillock 更适合通过 authselect profile 持久管理"
  fi
}

fix_audit() {
  require_root

  install -d -m 750 /etc/audit/rules.d
  backup_if_exists "$AUDIT_RULES_FILE"
  write_audit_rules
  chmod 640 "$AUDIT_RULES_FILE"
  chown root:root "$AUDIT_RULES_FILE"

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

  chown root:root /etc/passwd /etc/group
  chmod 644 /etc/passwd /etc/group

  if getent group shadow >/dev/null 2>&1; then
    chown root:shadow /etc/shadow
    chmod 640 /etc/shadow
    if [ -e /etc/gshadow ]; then
      chown root:shadow /etc/gshadow
      chmod 640 /etc/gshadow
    fi
  else
    chown root:root /etc/shadow
    chmod 600 /etc/shadow
    if [ -e /etc/gshadow ]; then
      chown root:root /etc/gshadow
      chmod 600 /etc/gshadow
    fi
  fi

  if [ -n "$SSHD_CONFIG" ]; then
    chown root:root "$SSHD_CONFIG"
    chmod 600 "$SSHD_CONFIG"
  fi

  if [ -e /etc/sudoers ]; then
    chown root:root /etc/sudoers
    chmod 440 /etc/sudoers
  fi

  if [ -d /etc/sudoers.d ]; then
    chown root:root /etc/sudoers.d
    chmod 750 /etc/sudoers.d
    find /etc/sudoers.d -maxdepth 1 -type f -exec chown root:root {} +
    find /etc/sudoers.d -maxdepth 1 -type f -exec chmod 440 {} +
  fi

  if [ -d /var/log/audit ]; then
    chown root:root /var/log/audit
    chmod 750 /var/log/audit
  fi

  if [ -f /var/log/audit/audit.log ]; then
    chown root:root /var/log/audit/audit.log
    chmod 640 /var/log/audit/audit.log
  fi

  info "关键配置文件权限修复已完成"
}

fix_sysctl() {
  require_root

  install -d -m 755 "$(dirname "$SYSCTL_ASLR_FILE")"
  cat >"$SYSCTL_ASLR_FILE" <<'EOF'
# 启用完整的地址空间布局随机化，提升基础内存利用攻击门槛。
kernel.randomize_va_space = 2
EOF
  chown root:root "$SYSCTL_ASLR_FILE"
  chmod 644 "$SYSCTL_ASLR_FILE"
  sysctl -w kernel.randomize_va_space=2 >/dev/null
  sysctl --system >/dev/null 2>&1 || true
  info "已启用 ASLR 并写入 ${SYSCTL_ASLR_FILE}"
}

fix_all() {
  require_root

  info "开始执行 Linux 主机侧等保三级与最低安全合规加固"
  fix_auth
  fix_perms
  fix_sysctl

  if have_cmd auditctl || [ -d /etc/audit ]; then
    fix_audit
  else
    warn "未检测到 auditd 环境，跳过审计规则修复"
  fi

  info "Linux 主机侧一键修复已完成，建议重新执行 check 进行校验"
  print_manual_findings
}

print_config() {
  cat <<'EOF'
# /etc/login.defs 建议值
PASS_MAX_DAYS 90
PASS_MIN_DAYS 1
PASS_WARN_AGE 7

# /etc/profile.d/99-security-timeout.sh
TMOUT=900
readonly TMOUT
export TMOUT

# sshd_config 建议值
PermitEmptyPasswords no
MaxAuthTries 4
LogLevel INFO
ClientAliveInterval 300
ClientAliveCountMax 0
PermitRootLogin no

# 审计规则建议片段
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/security/opasswd -p wa -k identity
-w /etc/pam.d -p wa -k pam
-w /etc/login.defs -p wa -k login_defs
-w /etc/ssh/sshd_config -p wa -k sshd
-w /etc/sudoers -p wa -k scope
-w /etc/sudoers.d -p wa -k scope
-w /var/log/lastlog -p wa -k logins
-w /var/run/faillock -p wa -k logins

# sysctl 建议值
kernel.randomize_va_space = 2
EOF
}

run_checks() {
  discover_paths

  check_empty_passwords
  check_uid_zero_uniqueness
  check_password_policy
  check_faillock
  check_tmout
  check_sshd_settings
  check_services
  check_audit_rules
  check_file_permissions
  check_sudo_scope
  check_aslr

  print_manual_findings

  printf '\n汇总：通过=%s 警告=%s 失败=%s\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
  if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
  fi
}

usage() {
  cat <<'EOF'
用法：
  linux_mlps_baseline.sh                    默认输出 Linux 主机环境信息
  linux_mlps_baseline.sh env-info          输出 Linux 主机环境信息
  linux_mlps_baseline.sh check             执行主机侧合规检查，输出通过 / 警告 / 失败
  linux_mlps_baseline.sh fix-auth          修复口令周期、shell 超时和常见 SSH 认证参数
  linux_mlps_baseline.sh fix-audit         生成并加载主机审计规则
  linux_mlps_baseline.sh fix-perms         修复关键认证与审计文件权限
  linux_mlps_baseline.sh fix-sysctl        启用 ASLR
  linux_mlps_baseline.sh fix-all           一键修复可自动落地的主机侧合规项
  linux_mlps_baseline.sh print-config      输出建议配置片段，供人工合并
  linux_mlps_baseline.sh -h|--help|help    显示帮助信息

说明：
  脚本不会删除账户、不会停服务、不会自动修改 sudo 授权内容。
  漏洞修补、恶意代码防护、入侵告警、管理终端白名单属于平台或流程能力。
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
  fix-auth)
    fix_auth
    ;;
  fix-audit)
    fix_audit
    ;;
  fix-perms)
    fix_perms
    ;;
  fix-sysctl)
    fix_sysctl
    ;;
  fix-all)
    fix_all
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
