## 一、适用范围与使用原则

本基线适用于 Linux 平台上的 Kubernetes Pod 与带 `PodTemplate` 的工作负载清单，覆盖 Pod 规约中的访问控制、特权控制、命名空间隔离、端口暴露与资源边界控制。

- 适用对象：`Pod`、`Deployment`、`DaemonSet`、`StatefulSet`、`Job`、`CronJob` 等工作负载清单
- 本文范围：`spec` / `template.spec`、Pod/Container `securityContext`、命名空间与配额边界
- 不在本文范围：Node 级 `kubelet`、容器运行时、控制平面组件、镜像构建流程、RBAC 设计

使用原则：

- 优先使用 `Pod Security Admission` 在命名空间级别施加 `baseline` / `restricted` 约束，再用清单规范做补充
- 运行时安全字段优先写入 `securityContext`，不要依赖默认值碰运气
- 对于 `Pod` 基线，自动修 YAML 风险高于主机侧文件权限修复，因此脚本只做检查与建议输出，不自动改清单

## 二、字段映射与判定口径

以下 17 项检查均以 `Pod` 规约为准；对于控制器资源，实际检查对象是 `spec.template.spec`。

### 1. 容器安全上下文

| 检查项 | 主要字段 | 判定口径 |
| --- | --- | --- |
| 确保设置装载传播模式不共享 | `volumeMounts[*].mountPropagation` | 仅允许省略或显式为 `None`，不允许 `HostToContainer` / `Bidirectional` |
| 限制配置 `allowPrivilegeEscalation` 参数容器准入 | `containers[*].securityContext.allowPrivilegeEscalation` | 必须显式为 `false` |
| 限制以 root 运行容器 | `runAsNonRoot`、`runAsUser` | 必须保证容器有效配置不是 root，推荐 `runAsNonRoot: true` 且不使用 `runAsUser: 0` |
| 限制配置 `NET_RAW` 功能容器准入 | `capabilities.add` | 不允许添加 `NET_RAW` |
| 限制配置附加功能容器准入 | `capabilities.add` | 高危口径下仅允许非常小的白名单，推荐只在确有需要时使用 `NET_BIND_SERVICE` |
| 禁止配置具有内核功能的容器 | `procMount`、`sysctls` | 不允许 `procMount: Unmasked`，不允许不安全 `sysctls` |
| 不要使用特权容器 | `securityContext.privileged` | 必须为 `false` 或省略 |
| 将安全上下文应用于您的 Pod 和容器 | `spec.securityContext`、`containers[*].securityContext` | Pod 级与容器级均应显式声明安全上下文 |
| 确保在 pod 定义中将 seccomp 配置文件设置为 docker/default | `seccompProfile.type` 或 legacy seccomp annotation | 现代 Kubernetes / CRI 口径应使用 `RuntimeDefault`；历史 `docker/default`、`runtime/default` 只作为兼容表述 |
| 禁止配置具有附加功能的容器 | `capabilities.add` | 低危加强口径：最好完全不添加任何 capability |

### 2. 主机命名空间与网络暴露

| 检查项 | 主要字段 | 判定口径 |
| --- | --- | --- |
| 限制共享主机 PID 命名空间容器准入 | `spec.hostPID` | 必须为 `false` 或省略 |
| 限制共享主机 IPC 命名空间容器准入 | `spec.hostIPC` | 必须为 `false` 或省略 |
| 限制使用主机网络和端口容器准入 | `spec.hostNetwork`、`ports[*].hostPort` | 不允许 `hostNetwork: true`，不允许使用 `hostPort` |
| 不要在容器上挂载敏感的主机系统目录 | `volumes[*].hostPath` | 通用基线下建议直接禁止 `hostPath`；至少不得挂载敏感系统目录 |
| 确保特权端口禁止映射到容器内 | `ports[*].containerPort`、`ports[*].hostPort` | 不应使用 `<1024` 的特权端口，建议由 Service / Ingress 在边界层完成端口映射 |

### 3. 命名空间与资源边界

| 检查项 | 主要字段 | 判定口径 |
| --- | --- | --- |
| 使用命名空间创建资源管理边界 | `metadata.namespace`、`Namespace`、`ResourceQuota`、`LimitRange` | 工作负载应落在业务命名空间，且该命名空间应配套资源边界控制 |
| 不应使用默认命名空间 | `metadata.namespace` | 不应省略命名空间，也不应落到 `default` |

## 三、基线要求

### 1. 优先对齐 Pod Security Standards

Kubernetes 官方 `Pod Security Standards` 已把特权容器、主机命名空间、`hostPath`、特权提升、额外 capability、seccomp、非安全 `sysctls` 等问题定义为 `baseline` 或 `restricted` 控制项。对业务命名空间，推荐至少满足 `baseline`，生产环境更推荐对齐 `restricted`。

命名空间标签示例：

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: app-prod
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/enforce-version: "<cluster-version>"
```

### 2. 推荐的 Pod / Container 安全配置

推荐配置片段：

```yaml
spec:
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: app
    securityContext:
      allowPrivilegeEscalation: false
      privileged: false
      capabilities:
        drop:
        - ALL
```

补充要求：

- 如确需绑定 80/443 等服务端口，优先让容器监听高位端口，再通过 `Service` / `Ingress` 做映射
- 如确需添加 capability，优先只使用 `NET_BIND_SERVICE`，并在评审中记录原因
- 对 `hostPath`、`hostNetwork`、`hostPID`、`hostIPC` 这类破坏隔离的字段，应默认禁止

### 3. 关于 `docker/default` 与 `RuntimeDefault`

“确保在 pod 定义中将 seccomp 配置文件设置为 `docker/default`”是旧时代 Docker 运行时语境下的常见表述。对当前 Kubernetes 和 CRI 实现，更合理的通用写法是：

```yaml
securityContext:
  seccompProfile:
    type: RuntimeDefault
```

若扫描平台仍沿用 `docker/default` 文案，应把它理解为“启用默认 seccomp profile”，而不是继续在 `containerd` 环境里写 Docker 专属字段。

### 4. 使用命名空间和资源配额形成边界

命名空间不仅是逻辑分组，也是资源边界的承载点。对业务工作负载，至少应做到：

- 明确写入 `metadata.namespace`
- 不把业务 Pod 落在 `default` 命名空间
- 为业务命名空间配套 `ResourceQuota`
- 视情况补充 `LimitRange`，避免 Pod 无限制创建或无限制吃掉节点资源

## 四、最小核查清单

建议至少确认以下项目：

1. 所有容器都显式设置 `allowPrivilegeEscalation: false`。
2. 所有容器都以非 root 身份运行。
3. 所有容器都未启用 `privileged`。
4. 所有容器都未添加 `NET_RAW`，且未随意增加 capability。
5. Pod 与容器都显式声明了 `securityContext`。
6. Pod 已启用 `RuntimeDefault` 或等效默认 seccomp profile。
7. Pod 未启用 `hostPID`、`hostIPC`、`hostNetwork`、`hostPort`。
8. Pod 未使用 `hostPath`，或至少未挂载敏感主机目录。
9. 工作负载未落在 `default` 命名空间。
10. 命名空间已配套 `ResourceQuota` / `LimitRange` 等边界控制。

## 五、Pod 清单核查与整改表

| 检查项 | 检查命令 / 字段 | 整改建议 |
| --- | --- | --- |
| **高危** 确保设置装载传播模式不共享 | `grep -R -n 'mountPropagation' <manifests>` | `volumeMounts[*].mountPropagation` 仅允许省略或设置为 `None`，不要使用 `HostToContainer` / `Bidirectional` |
| **高危** 限制配置 `allowPrivilegeEscalation` 参数容器准入 | `grep -R -n 'allowPrivilegeEscalation' <manifests>` | 所有容器显式设置 `allowPrivilegeEscalation: false` |
| **高危** 限制以 root 运行容器 | `grep -R -n 'runAsNonRoot\\|runAsUser' <manifests>` | Pod 级或容器级显式设置 `runAsNonRoot: true`，不要使用 `runAsUser: 0` |
| **高危** 限制配置 `NET_RAW` 功能容器准入 | `grep -R -n 'NET_RAW' <manifests>` | 不允许在 `capabilities.add` 中增加 `NET_RAW` |
| **高危** 限制配置附加功能容器准入 | `grep -R -n 'capabilities:' <manifests>` | 高危口径下仅在确有必要时增加最小 capability，推荐只保留 `NET_BIND_SERVICE` 这类白名单项 |
| **高危** 禁止配置具有内核功能的容器 | `grep -R -n 'procMount\\|sysctls' <manifests>` | 不使用 `procMount: Unmasked`，仅允许安全 `sysctls` |
| **高危** 不要使用特权容器 | `grep -R -n 'privileged:' <manifests>` | 确保 `privileged: false` 或不声明该字段 |
| **高危** 将安全上下文应用于您的 Pod 和容器 | `grep -R -n 'securityContext:' <manifests>` | 在 Pod 级和容器级都声明最小必要安全上下文 |
| **高危** 确保在 pod 定义中将 seccomp 配置文件设置为 `docker/default` | `grep -R -n 'seccompProfile\\|seccomp.security.alpha' <manifests>` | 使用 `seccompProfile.type: RuntimeDefault`；兼容老平台时可理解为等效默认 seccomp profile |
| **低危** 禁止配置具有附加功能的容器 | `grep -R -n 'capabilities:' <manifests>` | 加强口径下不添加任何 capability，并通过 `drop: [ALL]` 收紧默认能力集 |
| **高危** 限制共享主机 PID 命名空间容器准入 | `grep -R -n 'hostPID' <manifests>` | 保持 `hostPID: false` 或省略 |
| **高危** 限制共享主机 IPC 命名空间容器准入 | `grep -R -n 'hostIPC' <manifests>` | 保持 `hostIPC: false` 或省略 |
| **高危** 限制使用主机网络和端口容器准入 | `grep -R -n 'hostNetwork\\|hostPort' <manifests>` | 保持 `hostNetwork: false`，避免使用 `hostPort` |
| **高危** 不要在容器上挂载敏感的主机系统目录 | `grep -R -n 'hostPath' <manifests>` | 通用基线建议直接禁止 `hostPath`；至少不要挂载 `/proc`、`/sys`、`/etc`、`/run`、`/var/lib/kubelet` 等敏感路径 |
| **高危** 使用命名空间创建资源管理边界 | `grep -R -n '^  namespace:' <manifests>`<br>`grep -R -n 'kind: ResourceQuota\\|kind: LimitRange' <manifests>` | 将工作负载放入业务命名空间，并为命名空间配置 `ResourceQuota` / `LimitRange` |
| **高危** 不应使用默认命名空间 | `grep -R -n '^  namespace: default' <manifests>` | 显式设置业务命名空间，不要依赖默认命名空间 |
| **高危** 确保特权端口禁止映射到容器内 | `grep -R -n 'containerPort\\|hostPort' <manifests>` | 容器优先监听 `>=1024` 端口，在边界层做 80/443 映射 |

## 六、整合脚本

仓库提供配套脚本：

- `Pod/pod_baseline.sh`

脚本职责如下：

- 无参数执行：输出工具环境与输入参数信息
- `check -f <file-or-dir>`：检查单个清单文件或清单目录中的 17 项 Pod 基线
- `print-example`：输出推荐的 `Namespace`、`ResourceQuota`、`LimitRange` 与 `Deployment` 参考片段

推荐用法：

```bash
bash Pod/pod_baseline.sh check -f ./pod.yaml
bash Pod/pod_baseline.sh -f ./manifests
bash Pod/pod_baseline.sh check -f ./manifests
bash Pod/pod_baseline.sh print-example
```

自动化边界：

- 脚本检查对象是清单文件，不直接连接集群修改现有资源
- 命名空间边界与资源配额项只能依据输入清单判断；如果未把 `Namespace` / `ResourceQuota` / `LimitRange` 一并纳入检查范围，脚本只能给出有限结论
- 脚本不会自动修 YAML；对于 `Pod` 规约，人工评审与代码评审仍是主路径

## 七、参考链接

- Kubernetes 官方文档：<https://kubernetes.io/docs/concepts/security/pod-security-standards/>
- Kubernetes 官方文档：<https://kubernetes.io/docs/concepts/security/pod-security-admission/>
- Kubernetes 官方文档：<https://kubernetes.io/docs/reference/node/seccomp/>
- Kubernetes 官方文档：<https://kubernetes.io/docs/tasks/administer-cluster/sysctl-cluster/>
- Kubernetes 官方文档：<https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/>
- Kubernetes 官方文档：<https://kubernetes.io/docs/concepts/policy/resource-quotas/>
