#!/usr/bin/env bash

set -euo pipefail

MODE="env-info"
INPUT_PATH="${INPUT_PATH:-}"

if [ "$#" -gt 0 ] && [[ "${1:-}" != -* ]]; then
  MODE="$1"
  shift
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    -f|--input)
      INPUT_PATH="${2:-}"
      shift 2
      ;;
    -h|--help|help)
      MODE="help"
      shift
      ;;
    *)
      echo "未知参数：$1" >&2
      exit 2
      ;;
  esac
done

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

info() {
  printf '[信息] %s\n' "$*"
}

fail_exit() {
  echo "$*" >&2
  exit 1
}

require_input() {
  if [ -z "$INPUT_PATH" ]; then
    fail_exit "执行 check 时必须指定 -f|--input <file-or-dir>。"
  fi
}

is_manifest_dir() {
  [ -d "$1" ]
}

is_manifest_file() {
  [ -f "$1" ]
}

python_has_yaml() {
  have_cmd python3 || return 1
  python3 -c 'import yaml' >/dev/null 2>&1
}

parse_manifest_with_python() {
  local input="$1"

  python3 - "$input" <<'PY'
import json
import sys
from pathlib import Path

import yaml


def load_documents(path: Path):
    suffix = path.suffix.lower()
    if suffix == ".json":
        with path.open("r", encoding="utf-8") as fh:
            data = json.load(fh)
        if isinstance(data, list):
            return [item for item in data if item is not None]
        return [] if data is None else [data]

    with path.open("r", encoding="utf-8") as fh:
        return [doc for doc in yaml.safe_load_all(fh) if doc is not None]


input_path = Path(sys.argv[1])
if not input_path.exists():
    print(f"输入路径不存在：{input_path}", file=sys.stderr)
    sys.exit(1)

documents = []
if input_path.is_dir():
    candidates = sorted(
        path for path in input_path.iterdir()
        if path.is_file() and path.suffix.lower() in {".yaml", ".yml", ".json"}
    )
    if not candidates:
        print(f"目录中未发现 YAML/JSON 清单：{input_path}", file=sys.stderr)
        sys.exit(1)
    for candidate in candidates:
        documents.extend(load_documents(candidate))
else:
    documents.extend(load_documents(input_path))

if not documents:
    print(f"输入清单为空：{input_path}", file=sys.stderr)
    sys.exit(1)

payload = documents[0] if len(documents) == 1 else {
    "apiVersion": "v1",
    "kind": "List",
    "items": documents,
}
json.dump(payload, sys.stdout, ensure_ascii=False)
PY
}

parse_manifest_with_kubectl() {
  local input="$1"
  local -a kubectl_args=(
    create
    --dry-run=client
    --validate=false
    -f "$input"
    -o json
  )

  kubectl "${kubectl_args[@]}"
}

normalize_manifest_to_json() {
  local input="$1"

  if is_manifest_dir "$input"; then
    if python_has_yaml; then
      parse_manifest_with_python "$input"
      return
    fi

    if ! have_cmd kubectl; then
      fail_exit "解析 YAML 清单优先依赖 python3 + PyYAML；当前未检测到 PyYAML，且 kubectl 不可用。"
    fi

    parse_manifest_with_kubectl "$input"
    return
  fi

  if is_manifest_file "$input"; then
    if [[ "$input" == *.json ]]; then
      cat "$input"
      return
    fi

    if python_has_yaml; then
      parse_manifest_with_python "$input"
      return
    fi

    if have_cmd kubectl; then
      parse_manifest_with_kubectl "$input"
      return
    fi

    fail_exit "解析清单文件优先依赖 python3 + PyYAML；当前未检测到 PyYAML，且 kubectl 不可用。"
    return
  fi

  fail_exit "输入路径不存在或不是普通文件/目录：${input}"
}

print_env_info() {
  echo "Kubernetes Pod 基线检查环境信息："
  printf '  %-24s %s\n' "当前目录" "$PWD"
  printf '  %-24s %s\n' "输入路径" "${INPUT_PATH:-未指定}"
  printf '  %-24s %s\n' "kubectl" "$(command -v kubectl 2>/dev/null || echo 未检测到)"
  printf '  %-24s %s\n' "python3" "$(command -v python3 2>/dev/null || echo 未检测到)"
  printf '  %-24s %s\n' "PyYAML" "$(python_has_yaml && echo 已安装 || echo 未检测到)"
  printf '  %-24s %s\n' "检查模式" "静态清单检查，不自动改 YAML"
  printf '  %-24s %s\n' "支持资源" "Pod/Deployment/DaemonSet/StatefulSet/Job/CronJob 等"
}

run_checks() {
  local tmp_json

  require_input
  have_cmd python3 || fail_exit "执行清单分析需要 python3。"

  tmp_json="$(mktemp)"
  trap 'rm -f "$tmp_json"' RETURN
  normalize_manifest_to_json "$INPUT_PATH" >"$tmp_json"

  python3 - "$tmp_json" <<'PY'
import json
import sys
from pathlib import PurePosixPath

SAFE_SYSCTLS = {
    "kernel.shm_rmid_forced",
    "net.ipv4.ip_local_port_range",
    "net.ipv4.tcp_syncookies",
    "net.ipv4.ping_group_range",
    "net.ipv4.ip_unprivileged_port_start",
    "net.ipv4.ip_local_reserved_ports",
    "net.ipv4.tcp_keepalive_time",
    "net.ipv4.tcp_fin_timeout",
    "net.ipv4.tcp_keepalive_intvl",
    "net.ipv4.tcp_keepalive_probes",
}
STRICT_ALLOWED_CAP_ADDS = {"NET_BIND_SERVICE"}
DEFAULT_SECCOMP_VALUES = {"RuntimeDefault", "runtime/default", "docker/default", "Localhost"}
SENSITIVE_HOST_PATH_PREFIXES = [
    "/boot",
    "/dev",
    "/etc",
    "/lib",
    "/lib64",
    "/proc",
    "/root",
    "/run",
    "/sys",
    "/usr",
    "/var/lib/containerd",
    "/var/lib/docker",
    "/var/lib/kubelet",
    "/var/run",
]
WORKLOAD_KINDS = {
    "Pod",
    "Deployment",
    "DaemonSet",
    "StatefulSet",
    "ReplicaSet",
    "ReplicationController",
    "Job",
    "CronJob",
}


def flatten_objects(obj):
    if isinstance(obj, list):
        items = []
        for entry in obj:
            items.extend(flatten_objects(entry))
        return items

    if not isinstance(obj, dict):
        return []

    if obj.get("kind") == "List" and isinstance(obj.get("items"), list):
        items = []
        for entry in obj["items"]:
            items.extend(flatten_objects(entry))
        return items

    return [obj]


def pod_spec_for(obj):
    kind = obj.get("kind")
    if kind == "Pod":
        return obj.get("spec") or {}
    if kind in {"Deployment", "DaemonSet", "StatefulSet", "ReplicaSet"}:
        return (((obj.get("spec") or {}).get("template") or {}).get("spec") or {})
    if kind == "ReplicationController":
        return (((obj.get("spec") or {}).get("template") or {}).get("spec") or {})
    if kind == "Job":
        return (((obj.get("spec") or {}).get("template") or {}).get("spec") or {})
    if kind == "CronJob":
        return (((((obj.get("spec") or {}).get("jobTemplate") or {}).get("spec") or {}).get("template") or {}).get("spec") or {})
    return None


def workload_id(obj):
    metadata = obj.get("metadata") or {}
    namespace = metadata.get("namespace") or "default"
    name = metadata.get("name") or "unnamed"
    kind = obj.get("kind") or "Unknown"
    return f"{kind}/{namespace}/{name}"


def iter_all_containers(spec):
    for field in ("containers", "initContainers", "ephemeralContainers"):
        for container in spec.get(field) or []:
            yield field, container


def container_name(container):
    return container.get("name") or "unnamed"


def pod_security_context(spec):
    return spec.get("securityContext") or {}


def container_security_context(container):
    return container.get("securityContext") or {}


def effective_value(container, spec, key):
    csc = container_security_context(container)
    if key in csc:
        return csc.get(key)
    return pod_security_context(spec).get(key)


def is_sensitive_host_path(path):
    try:
        normalized = PurePosixPath(path)
    except Exception:
        return True

    normalized_text = str(normalized)
    for prefix in SENSITIVE_HOST_PATH_PREFIXES:
        if normalized_text == prefix or normalized_text.startswith(prefix + "/"):
            return True
    return False


def normalize_capability_list(values):
    normalized = []
    for value in values or []:
        if value is None:
            continue
        normalized.append(str(value).upper())
    return normalized


def seccomp_value_for_container(obj, spec, container):
    csc = container_security_context(container)
    container_seccomp = (csc.get("seccompProfile") or {}).get("type")
    if container_seccomp:
        return container_seccomp

    pod_seccomp = (pod_security_context(spec).get("seccompProfile") or {}).get("type")
    if pod_seccomp:
        return pod_seccomp

    annotations = (obj.get("metadata") or {}).get("annotations") or {}
    legacy_container_key = f"container.seccomp.security.alpha.kubernetes.io/{container_name(container)}"
    if legacy_container_key in annotations:
        return annotations[legacy_container_key]
    if "seccomp.security.alpha.kubernetes.io/pod" in annotations:
        return annotations["seccomp.security.alpha.kubernetes.io/pod"]
    return None


def collect_namespace_policies(objects):
    namespaces = set()
    quotas = set()
    limit_ranges = set()

    for obj in objects:
        metadata = obj.get("metadata") or {}
        kind = obj.get("kind")
        if kind == "Namespace" and metadata.get("name"):
            namespaces.add(metadata["name"])
        elif kind == "ResourceQuota" and metadata.get("namespace"):
            quotas.add(metadata["namespace"])
        elif kind == "LimitRange" and metadata.get("namespace"):
            limit_ranges.add(metadata["namespace"])

    return namespaces, quotas, limit_ranges


class Reporter:
    def __init__(self):
        self.pass_count = 0
        self.warn_count = 0
        self.fail_count = 0

    def emit(self, level, workload, title, detail=""):
        prefix = {"pass": "[通过]", "warn": "[警告]", "fail": "[失败]"}[level]
        if detail:
            print(f"{prefix} {workload} | {title} | {detail}")
        else:
            print(f"{prefix} {workload} | {title}")

        if level == "pass":
            self.pass_count += 1
        elif level == "warn":
            self.warn_count += 1
        else:
            self.fail_count += 1


with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)

objects = flatten_objects(data)
workloads = []
for obj in objects:
    if obj.get("kind") not in WORKLOAD_KINDS:
        continue
    spec = pod_spec_for(obj)
    if spec is not None:
        workloads.append((obj, spec))

if not workloads:
    print("[失败] 输入清单中未发现 Pod 或带 PodTemplate 的工作负载资源", file=sys.stderr)
    sys.exit(1)

namespaces, quotas, limit_ranges = collect_namespace_policies(objects)
reporter = Reporter()

for obj, spec in workloads:
    wid = workload_id(obj)
    metadata = obj.get("metadata") or {}
    namespace = metadata.get("namespace")
    pod_sc = pod_security_context(spec)
    containers = list(iter_all_containers(spec))

    mount_issues = []
    for field, container in containers:
        for vm in container.get("volumeMounts") or []:
            propagation = vm.get("mountPropagation")
            if propagation and propagation != "None":
                mount_issues.append(f"{field}:{container_name(container)}={propagation}")
    if mount_issues:
        reporter.emit("fail", wid, "确保设置装载传播模式不共享", "；".join(mount_issues))
    else:
        reporter.emit("pass", wid, "确保设置装载传播模式不共享")

    ape_issues = []
    for field, container in containers:
        value = container_security_context(container).get("allowPrivilegeEscalation")
        if value is not False:
            ape_issues.append(f"{field}:{container_name(container)}")
    if ape_issues:
        reporter.emit("fail", wid, "限制配置allowPrivilegeEscalation参数容器准入", "未显式设置为 false：" + "、".join(ape_issues))
    else:
        reporter.emit("pass", wid, "限制配置allowPrivilegeEscalation参数容器准入")

    non_root_issues = []
    for field, container in containers:
        run_as_non_root = effective_value(container, spec, "runAsNonRoot")
        run_as_user = effective_value(container, spec, "runAsUser")
        if run_as_user == 0 or run_as_non_root is not True:
            non_root_issues.append(f"{field}:{container_name(container)}")
    if non_root_issues:
        reporter.emit("fail", wid, "限制以root运行容器", "未满足 non-root 约束：" + "、".join(non_root_issues))
    else:
        reporter.emit("pass", wid, "限制以root运行容器")

    net_raw_issues = []
    for field, container in containers:
        caps = normalize_capability_list(((container_security_context(container).get("capabilities") or {}).get("add")) or [])
        if "NET_RAW" in caps:
            net_raw_issues.append(f"{field}:{container_name(container)}")
    if net_raw_issues:
        reporter.emit("fail", wid, "限制配置NET_RAW功能容器准入", "存在 NET_RAW：" + "、".join(net_raw_issues))
    else:
        reporter.emit("pass", wid, "限制配置NET_RAW功能容器准入")

    add_cap_issues = []
    for field, container in containers:
        caps = normalize_capability_list(((container_security_context(container).get("capabilities") or {}).get("add")) or [])
        disallowed = [cap for cap in caps if cap not in STRICT_ALLOWED_CAP_ADDS]
        if disallowed:
            add_cap_issues.append(f"{field}:{container_name(container)}={','.join(disallowed)}")
    if add_cap_issues:
        reporter.emit("fail", wid, "限制配置附加功能容器准入", "超出最小白名单：" + "；".join(add_cap_issues))
    else:
        reporter.emit("pass", wid, "限制配置附加功能容器准入")

    kernel_feature_issues = []
    for field, container in containers:
        proc_mount = container_security_context(container).get("procMount")
        if proc_mount and proc_mount != "Default":
            kernel_feature_issues.append(f"{field}:{container_name(container)} procMount={proc_mount}")
    for sysctl in pod_sc.get("sysctls") or []:
        name = sysctl.get("name")
        if name not in SAFE_SYSCTLS:
            kernel_feature_issues.append(f"unsafe-sysctl:{name}")
    if kernel_feature_issues:
        reporter.emit("fail", wid, "禁止配置具有内核功能的容器", "；".join(kernel_feature_issues))
    else:
        reporter.emit("pass", wid, "禁止配置具有内核功能的容器")

    privileged_issues = []
    for field, container in containers:
        if container_security_context(container).get("privileged") is True:
            privileged_issues.append(f"{field}:{container_name(container)}")
    if privileged_issues:
        reporter.emit("fail", wid, "不要使用特权容器", "存在 privileged 容器：" + "、".join(privileged_issues))
    else:
        reporter.emit("pass", wid, "不要使用特权容器")

    if not pod_sc:
        reporter.emit("fail", wid, "将安全上下文应用于您的 Pod 和容器", "缺少 Pod 级 securityContext")
    else:
        container_sc_issues = []
        for field, container in containers:
            if not container_security_context(container):
                container_sc_issues.append(f"{field}:{container_name(container)}")
        if container_sc_issues:
            reporter.emit("fail", wid, "将安全上下文应用于您的 Pod 和容器", "缺少容器级 securityContext：" + "、".join(container_sc_issues))
        else:
            reporter.emit("pass", wid, "将安全上下文应用于您的 Pod 和容器")

    seccomp_issues = []
    for field, container in containers:
        seccomp_value = seccomp_value_for_container(obj, spec, container)
        if seccomp_value not in DEFAULT_SECCOMP_VALUES:
            seccomp_issues.append(f"{field}:{container_name(container)}={seccomp_value or '未设置'}")
    if seccomp_issues:
        reporter.emit("fail", wid, "确保在 pod 定义中将 seccomp 配置文件设置为docker/default", "未设置默认 seccomp profile：" + "；".join(seccomp_issues))
    else:
        reporter.emit("pass", wid, "确保在 pod 定义中将 seccomp 配置文件设置为docker/default", "已接受 RuntimeDefault / docker-default / Localhost 兼容值")

    added_caps = []
    for field, container in containers:
        caps = normalize_capability_list(((container_security_context(container).get("capabilities") or {}).get("add")) or [])
        if caps:
            added_caps.append(f"{field}:{container_name(container)}={','.join(caps)}")
    if added_caps:
        reporter.emit("warn", wid, "禁止配置具有附加功能的容器", "发现 capabilities.add：" + "；".join(added_caps))
    else:
        reporter.emit("pass", wid, "禁止配置具有附加功能的容器")

    if spec.get("hostPID") is True:
        reporter.emit("fail", wid, "限制共享主机PID命名空间容器准入", "hostPID=true")
    else:
        reporter.emit("pass", wid, "限制共享主机PID命名空间容器准入")

    if spec.get("hostIPC") is True:
        reporter.emit("fail", wid, "限制共享主机IPC命名空间容器准入", "hostIPC=true")
    else:
        reporter.emit("pass", wid, "限制共享主机IPC命名空间容器准入")

    network_issues = []
    if spec.get("hostNetwork") is True:
        network_issues.append("hostNetwork=true")
    for field, container in containers:
        for port in container.get("ports") or []:
            host_port = port.get("hostPort")
            if isinstance(host_port, int) and host_port > 0:
                network_issues.append(f"{field}:{container_name(container)} hostPort={host_port}")
    if network_issues:
        reporter.emit("fail", wid, "限制使用主机网络和端口容器准入", "；".join(network_issues))
    else:
        reporter.emit("pass", wid, "限制使用主机网络和端口容器准入")

    host_path_issues = []
    for volume in spec.get("volumes") or []:
        host_path = (volume.get("hostPath") or {}).get("path")
        if host_path and is_sensitive_host_path(host_path):
            host_path_issues.append(f"{volume.get('name', 'unnamed')}={host_path}")
        elif host_path:
            host_path_issues.append(f"{volume.get('name', 'unnamed')}={host_path}")
    if host_path_issues:
        reporter.emit("fail", wid, "不要在容器上挂载敏感的主机系统目录", "发现 hostPath：" + "；".join(host_path_issues))
    else:
        reporter.emit("pass", wid, "不要在容器上挂载敏感的主机系统目录")

    if not namespace:
        reporter.emit("fail", wid, "使用命名空间创建资源管理边界", "未显式设置 metadata.namespace")
    elif namespace == "default":
        reporter.emit("fail", wid, "使用命名空间创建资源管理边界", "仍使用 default 命名空间")
    elif namespace in quotas or namespace in limit_ranges:
        reporter.emit("pass", wid, "使用命名空间创建资源管理边界", "已发现 ResourceQuota/LimitRange")
    elif namespace in namespaces:
        reporter.emit("warn", wid, "使用命名空间创建资源管理边界", "已显式使用业务命名空间，但输入清单中未发现 ResourceQuota/LimitRange")
    else:
        reporter.emit("warn", wid, "使用命名空间创建资源管理边界", "已显式使用业务命名空间，但未在输入清单中发现 Namespace/Quota 定义")

    if not namespace or namespace == "default":
        reporter.emit("fail", wid, "不应使用默认命名空间")
    else:
        reporter.emit("pass", wid, "不应使用默认命名空间")

    privileged_port_issues = []
    for field, container in containers:
        for port in container.get("ports") or []:
            for key in ("containerPort", "hostPort"):
                value = port.get(key)
                if isinstance(value, int) and 0 < value < 1024:
                    privileged_port_issues.append(f"{field}:{container_name(container)} {key}={value}")
    if privileged_port_issues:
        reporter.emit("fail", wid, "确保特权端口禁止映射到容器内", "；".join(privileged_port_issues))
    else:
        reporter.emit("pass", wid, "确保特权端口禁止映射到容器内")

print(f"\n汇总：通过={reporter.pass_count} 警告={reporter.warn_count} 失败={reporter.fail_count}")
sys.exit(1 if reporter.fail_count > 0 else 0)
PY
}

print_example() {
  cat <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: app-prod
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/enforce-version: "<cluster-version>"
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: app-prod-quota
  namespace: app-prod
spec:
  hard:
    pods: "20"
    requests.cpu: "4"
    requests.memory: 8Gi
    limits.cpu: "8"
    limits.memory: 16Gi
---
apiVersion: v1
kind: LimitRange
metadata:
  name: app-prod-defaults
  namespace: app-prod
spec:
  limits:
  - type: Container
    default:
      cpu: 500m
      memory: 512Mi
    defaultRequest:
      cpu: 100m
      memory: 128Mi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
  namespace: app-prod
spec:
  replicas: 2
  selector:
    matchLabels:
      app: app
  template:
    metadata:
      labels:
        app: app
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: app
        image: registry.example.com/app:v1.0.0
        ports:
        - containerPort: 8080
        securityContext:
          allowPrivilegeEscalation: false
          privileged: false
          capabilities:
            drop:
            - ALL
          runAsNonRoot: true
EOF
}

usage() {
  cat <<'EOF'
用法：
  pod_baseline.sh                               默认输出 Pod 基线检查环境信息
  pod_baseline.sh env-info                      输出 Pod 基线检查环境信息
  pod_baseline.sh check -f <file-or-dir>        检查清单中的 17 项 Pod 基线
  pod_baseline.sh print-example                 输出 Namespace / Quota / Deployment 参考片段
  pod_baseline.sh -h|--help|help                显示帮助信息

说明：
  check 模式需要 -f|--input 指定 Pod 或工作负载清单文件 / 目录。
  单文件和目录都支持；目录下会按文件名顺序读取 `.yaml`、`.yml`、`.json`。
  YAML 清单优先使用 python3 + PyYAML 本地解析；未安装 PyYAML 时回退到 kubectl。
  JSON 清单可直接解析。
  示例：`check -f ./pod.yaml`、`check -f ./manifests/`
  脚本只做静态检查，不自动修改 YAML。
EOF
}

case "$MODE" in
  env|env-info|info)
    print_env_info
    ;;
  check)
    run_checks
    ;;
  print-example)
    print_example
    ;;
  help)
    usage
    ;;
  *)
    echo "未知模式：$MODE" >&2
    usage
    exit 2
    ;;
esac
