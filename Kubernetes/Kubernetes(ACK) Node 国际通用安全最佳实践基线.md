## 一、适用范围与使用原则

本基线适用于 Kubernetes 工作节点，重点覆盖 `kubelet` 在节点侧的访问控制、身份鉴别和文件权限控制。本文档按 ACK Node 常见检查项整理，但不依赖 ACK 专有实现。

- 适用对象：Kubernetes 工作节点、ACK Node、使用 `systemd` 管理 `kubelet` 的 Linux 节点
- 本文范围：`kubelet` 服务参数、`KubeletConfiguration` 配置文件、`kubelet.conf` 与 `systemd` unit 文件权限
- 不在本文范围：控制平面组件、Admission、RBAC 设计、etcd、CNI、容器运行时

使用原则：

- 优先检查 `kubelet` 运行时实际参数；若命令行未显式设置，再回退检查 `KubeletConfiguration`
- 不直接改发行版自带的 vendor unit 内容，优先通过配置文件或 drop-in 管理
- 文件权限可以自动修复；鉴权参数涉及节点引导方式，建议先核实现状再变更

## 二、参数映射与判定口径

`kubelet` 相关安全参数同时可能出现在命令行参数和 `KubeletConfiguration` 中。常见映射关系如下：

| 检查项 | 命令行参数 | 配置文件字段 | 判定口径 |
| --- | --- | --- | --- |
| 禁止匿名访问 | `--anonymous-auth=false` | `authentication.anonymous.enabled: false` | 未显式设置时按默认允许匿名处理，应判为不满足基线 |
| 设置客户端 CA | `--client-ca-file` | `authentication.x509.clientCAFile` | 需有非空值，且指向的 CA 文件实际存在 |
| 禁止 `AlwaysAllow` | `--authorization-mode=Webhook` | `authorization.mode: Webhook` | 只要仍为 `AlwaysAllow`，即判不满足基线 |
| 保持 iptables utility chains | `--make-iptables-util-chains=true` | `makeIPTablesUtilChains: true` | 未显式设置时，`kubelet` 默认值为 `true` |

说明：

- `kubelet` 命令行参数优先级高于 `KubeletConfiguration`
- 在 kubeadm / ACK 常见部署中，运行时参数通常来自 `systemd` unit、drop-in 和环境变量拼接
- 如需整改鉴权参数，推荐改 `KubeletConfiguration` 或受控 drop-in，而不是直接改 vendor unit

## 三、基线要求

### 1. 访问控制与身份鉴别

基线要求：

- 确保 `--anonymous-auth=false`
- 确保已设置 `--client-ca-file`
- 确保 `--authorization-mode` 不为 `AlwaysAllow`，推荐为 `Webhook`
- 确保 `--make-iptables-util-chains=true`

推荐 `KubeletConfiguration` 片段：

```yaml
authentication:
  anonymous:
    enabled: false
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
authorization:
  mode: Webhook
makeIPTablesUtilChains: true
```

### 2. 文件权限

基线要求：

- `kubelet.service` 实际 unit 文件所有者应为 `root:root`
- `kubelet.service` 实际 unit 文件权限应为 `644` 或更严格
- `--kubeconfig` 指向的 `kubelet.conf` 权限应为 `644` 或更严格
- `--config` 指向的 `KubeletConfiguration` 文件权限应为 `644` 或更严格
- `--config` 指向的 `KubeletConfiguration` 文件所有者应为 `root:root`

参考命令：

```bash
systemctl show -p FragmentPath --value kubelet
stat -c '%U:%G %a %n' "$(systemctl show -p FragmentPath --value kubelet)"
stat -c '%U:%G %a %n' /etc/kubernetes/kubelet.conf
stat -c '%U:%G %a %n' /var/lib/kubelet/config.yaml
```

## 四、最小核查清单

建议至少确认以下项目：

1. 运行中的 `kubelet` 未启用匿名访问。
2. `kubelet` 已配置客户端 CA 文件。
3. `kubelet` 未使用 `AlwaysAllow` 授权模式。
4. `kubelet` 服务文件所有权和权限符合基线。
5. `kubelet.conf` 与 `KubeletConfiguration` 权限符合基线。
6. `KubeletConfiguration` 文件所有者为 `root:root`。
7. `makeIPTablesUtilChains` 未被显式关闭。

## 五、主机核查与整改命令表

| 检查项 | 检查命令 | 整改建议 |
| --- | --- | --- |
| **高危** 确保 `--anonymous-auth` 参数设置为 `false` | `ps -ef | grep '[k]ubelet'`<br>`grep -n 'anonymous:' /var/lib/kubelet/config.yaml` | 在 `KubeletConfiguration` 中设置 `authentication.anonymous.enabled: false`，或通过受控启动参数显式设置 `--anonymous-auth=false` |
| **高危** 确保 `--client-ca-file` 参数设置为适当的值 | `ps -ef | grep '[k]ubelet'`<br>`grep -n 'clientCAFile' /var/lib/kubelet/config.yaml` | 在 `KubeletConfiguration` 中设置 `authentication.x509.clientCAFile`，并确保 CA 文件真实存在且受控 |
| **高危** 确保 `--authorization-mode` 参数未设置为 `AlwaysAllow` | `ps -ef | grep '[k]ubelet'`<br>`grep -n 'mode:' /var/lib/kubelet/config.yaml` | 推荐设置为 `Webhook`，不要继续使用 `AlwaysAllow` |
| **高危** 确保 kubelet 服务文件权限设置为 `644` 或更严格 | `systemctl show -p FragmentPath --value kubelet`<br>`stat -c '%a %n' "$(systemctl show -p FragmentPath --value kubelet)"` | 将实际 unit 文件权限收敛为 `644` 或更严格 |
| **中危** 确保 kubelet 服务文件所有权设置为 `root:root` | `stat -c '%U:%G %n' "$(systemctl show -p FragmentPath --value kubelet)"` | 将实际 unit 文件所有者调整为 `root:root` |
| **高危** 确保 `--kubeconfig` 指向的 `kubelet.conf` 权限设置为 `644` 或更严格 | `ps -ef | grep '[k]ubelet'`<br>`stat -c '%a %n' /etc/kubernetes/kubelet.conf` | 将 `kubelet.conf` 权限收敛为 `644` 或更严格 |
| **高危** 确保 `kubelet --config` 配置文件权限设置为 `644` 或更严格 | `ps -ef | grep '[k]ubelet'`<br>`stat -c '%U:%G %a %n' /var/lib/kubelet/config.yaml` | 将 `KubeletConfiguration` 文件权限收敛为 `644` 或更严格 |
| **高危** 确保 `kubelet --config` 配置文件所有权设置为 `root:root` | `stat -c '%U:%G %n' /var/lib/kubelet/config.yaml` | 将 `KubeletConfiguration` 文件所有者调整为 `root:root` |
| **高危** 确保 `--make-iptables-util-chains` 参数设置为 `true` | `ps -ef | grep '[k]ubelet'`<br>`grep -n 'makeIPTablesUtilChains' /var/lib/kubelet/config.yaml` | 保持 `makeIPTablesUtilChains: true`；如未显式设置，按 `kubelet` 默认值 `true` 处理，但建议在受控配置中显式声明 |

## 六、整合脚本

仓库提供配套脚本：

- `Kubernetes/kubelet_node_baseline.sh`

脚本职责如下：

- 无参数执行：输出 `kubelet` 节点环境信息
- `check`：检查上述 9 个 Node 基线项目
- `fix-perms`：仅修复 `kubelet.service`、`kubelet.conf`、`KubeletConfiguration` 的文件权限与必要所有权
- `print-config`：输出建议的 `KubeletConfiguration` 片段

推荐用法：

```bash
bash Kubernetes/kubelet_node_baseline.sh
bash Kubernetes/kubelet_node_baseline.sh check
sudo bash Kubernetes/kubelet_node_baseline.sh fix-perms
bash Kubernetes/kubelet_node_baseline.sh print-config
```

自动化边界：

- 脚本会自动修复文件权限，但不会直接改 `kubelet` 鉴权参数
- 鉴权参数的实际来源可能是启动参数、环境变量、drop-in 或配置文件，自动改写风险较高
- 修复前会先在源文件同目录生成备份文件，并附加时间戳

## 七、参考链接

- Kubernetes 官方文档：<https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/>
- Kubernetes 官方文档：<https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/>
- Kubernetes 官方文档：<https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/>
