<!-- 这是一张图片，ocr 内容为： -->

![](https://cdn.nlark.com/yuque/0/2026/png/27875807/1771929911927-d85a6718-38c0-48e1-8841-aab9082b1c69.png)

更新时间：20260416

<!-- 这是一张图片，ocr 内容为： -->

![](https://cdn.nlark.com/yuque/0/2026/png/27875807/1776322226461-eb97919a-834c-443f-8b39-157e25a3609a.png)

## 一、适用范围与使用原则

本基线适用于使用 `containerd` 作为容器运行时的 Linux 主机，覆盖主机侧与守护进程侧的安全控制，不覆盖业务镜像构建、Pod 规范、Kubernetes Admission、应用进程内安全控制。

- 适用对象：独立 `containerd` 主机、Kubernetes 节点上的 `containerd` 运行时
- 适用版本：
  - `containerd 1.x`：推荐使用 `version = 2`
  - `containerd 2.x`：推荐使用 `version = 3`
- 使用原则：
  - 不写死发行版相关路径，先确认实际安装路径
  - 不将 Pod 或容器启动参数误写成主机基线
  - 不将 Docker 专属配置误并入 `containerd` 基线

执行前建议先确认实际路径：

```bash
command -v containerd
command -v runc
systemctl show -p FragmentPath containerd
systemctl show -p FragmentPath containerd.socket
systemctl show -p DropInPaths containerd
```

## 二、审核策略

### 1. 审核规则持久化

审计规则应持久化在 `/etc/audit/rules.d/*.rules`，并使用 `augenrules --load` 或发行版等效机制加载。不要将基线写成只适用于单一发行版的 `/etc/audit/rules.d/audit.rules + service auditd restart` 固定流程。

### 2. 审核重点应落在静态关键对象

应优先审计以下对象：

- `/etc/containerd` 目录及 `config.toml`
- 仓库证书与 `hosts.toml` 配置目录
- `/var/lib/containerd`
- `/run/containerd` 与 `containerd.sock`
- `/etc/default/containerd`（如发行版存在该文件）
- `systemd` service/socket unit 及 drop-in
- `containerd`、`containerd-shim`、`containerd-shim-runc-v1`、`containerd-shim-runc-v2`、`runc` 或实际 runtime 二进制

建议规则示例：

```bash
-w /etc/containerd -p wa -k containerd-dir
-w /etc/containerd/config.toml -p wa -k containerd-config
-w /etc/containerd/certs.d -p wa -k containerd-registry
-w /var/lib/containerd -p wa -k containerd-state
-w /run/containerd -p wa -k containerd-run
-w /run/containerd/containerd.sock -p wa -k containerd-sock
-w /etc/default/containerd -p wa -k containerd-env
-w <containerd-service-unit> -p wa -k containerd-service
-w <containerd-socket-unit> -p wa -k containerd-service
-w <containerd-binary> -p x -k containerd-bin
-w <containerd-shim-binary> -p x -k containerd-bin
-w <containerd-shim-runc-v1-binary> -p x -k containerd-bin
-w <containerd-shim-runc-v2-binary> -p x -k containerd-bin
-w <runtime-binary> -p x -k containerd-runtime
```

要求：

- `<containerd-service-unit>`、`<containerd-socket-unit>` 必须替换为系统实际路径，不要硬编码为 `/lib/systemd/system/...`
- `<containerd-binary>`、`<runtime-binary>` 必须通过 `command -v` 或运行时配置确认
- `/etc/default/containerd` 不是所有发行版都有，仅在文件存在时纳入审计
- 如果使用自定义 `config_path`，应同步审计自定义证书目录

### 3. `/run/containerd` 审计的落地口径

`/run/containerd` 属于高频运行态目录，审计噪声通常高于静态配置目录。但很多扫描平台和合规基线会显式要求覆盖该目录及 `containerd.sock`。因此若目标是对齐通用扫描项，建议默认纳入；若在自有基线中需要降噪，应明确记录例外原因，而不是直接遗漏该项。

## 三、文件权限与所有权

### 1. 配置目录与配置文件

基线要求：

- `/etc/containerd` 所有者应为 `root:root`，权限应为 `755` 或更严格
- `/etc/containerd/config.toml` 所有者应为 `root:root`，权限应为 `640` 或更严格
- `/etc/containerd/certs.d` 不得对非特权用户开放写权限
- 仓库私钥文件权限应为 `600`

参考命令：

```bash
chown root:root /etc/containerd
chmod 755 /etc/containerd
chown root:root /etc/containerd/config.toml
chmod 640 /etc/containerd/config.toml
```

### 2. Socket、状态目录与二进制文件

基线要求：

- `containerd.sock` 不得为 world-writable
- `containerd.sock` 所有者应为 `root`，所属组仅允许可信管理主体使用
- `/var/lib/containerd`、`/run/containerd` 不得允许非特权用户写入
- `containerd`、`containerd-shim-runc-v2`、`runc` 及其它 runtime 二进制不得允许非特权用户写入

推荐口径：

- `containerd.sock` 权限设置为 `660` 或更严格
- 仅当确有运维编排需求时，才把非 `root` 账号纳入其所属组

### 3. systemd Unit 管理方式

基线要求：

- 不直接修改发行版自带 unit 文件
- 自定义参数通过 `systemd drop-in` 管理
- unit 文件与 drop-in 文件应为 `root:root`，权限为 `644` 或更严格

这样做的原因是，直接修改 vendor unit 容易在升级时被覆盖，也不利于审计和变更追踪。

## 四、服务配置与运行加固

### 1. 配置版本与 cgroup 驱动

基线要求：

- `containerd 1.x` 配置文件应使用 `version = 2`
- `containerd 2.x` 配置文件应使用 `version = 3`
- 在基于 `systemd` 的主机上，应使用 `SystemdCgroup = true`

配置示例：

```toml
# containerd 2.x
version = 3

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
  SystemdCgroup = true
```

```toml
# containerd 1.x
version = 2

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = true
```

### 2. 守护进程暴露面控制

基线要求：

- 默认仅使用本地 Unix Socket，不额外开放远程明文管理接口
- 非排障场景不应长期启用 debug socket 或 `debug` 级别日志，建议保持 `level = "info"`
- 若启用 CRI streaming，地址应保持在回环地址，避免绑定到非受控网卡

检查重点：

- `[grpc].tcp_address` 应保持为空，除非存在明确的远程管理需求
- 若必须启用 TCP 管理接口，应同时具备访问控制、网络隔离和 TLS 保护
- 若使用 CRI 插件，`stream_server_address` 应保持为 `127.0.0.1`
- `[debug].level` 建议保持为 `info`

### 3. Linux 安全模块集成

基线要求：

- 在启用 AppArmor 的主机上，不应关闭 `containerd` 的 AppArmor 集成
- 在启用 SELinux 的主机上，应启用 `enable_selinux = true`
- 不应通过固定写死的 MCS Label 作为通用基线示例

配置示例：

```toml
# containerd 2.x
[plugins.'io.containerd.cri.v1.runtime']
  enable_selinux = true
  disable_apparmor = false
```

```toml
# containerd 1.x
[plugins."io.containerd.grpc.v1.cri"]
  enable_selinux = true
  disable_apparmor = false
```

### 4. Runtime 默认值不得放宽

如使用自定义 runtime 或额外 runtime class，基线要求如下：

- 保持 `cgroup_writable = false`
- 保持 `privileged_without_host_devices = false`
- 未经风险评估，不放宽 `privileged_without_host_devices_all_devices_allowed`
- 仅使用受信任来源提供的 `runc`、`crun`、Kata 或其它 runtime

这些选项一旦放宽，会直接扩大容器对宿主机设备和 cgroup 的影响面。

## 五、镜像仓库与供应链控制

### 1. 使用 `config_path` 管理仓库配置

基线要求：

- 统一通过 `config_path` 指向受控目录，例如 `/etc/containerd/certs.d`
- 新部署不应继续依赖已废弃的 `registry.configs`、`registry.mirrors` 作为长期配置方案
- 仓库证书、客户端证书和 `hosts.toml` 应纳入主机配置管理

配置示例：

```toml
# containerd 2.x
[plugins.'io.containerd.cri.v1.images'.registry]
  config_path = "/etc/containerd/certs.d"
```

```toml
# containerd 1.x
[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "/etc/containerd/certs.d"
```

### 2. 禁止不安全仓库传输

基线要求：

- 默认只允许 `HTTPS`
- 不应使用明文 `HTTP` 仓库
- 不应以 `skip_verify = true` 作为常态配置
- 自建仓库应配置 CA 证书或双向认证材料

`hosts.toml` 参考示例：

```toml
server = "https://registry.example.com"

[host."https://registry.example.com"]
  capabilities = ["pull", "resolve"]
  ca = "/etc/containerd/certs.d/registry.example.com/ca.crt"
```

### 3. 镜像引用应具备不可变性

基线要求：

- 不使用 `:latest` 作为生产基线
- 优先使用固定版本标签，最好进一步固定到 Digest
- 节点只保留最小必要仓库访问能力

建议口径：

- 拉取节点通常只需要 `pull`、`resolve`
- 只有确有推送职责的主机才允许 `push`

## 六、明确不属于本基线的控制项

以下控制项很重要，但不应写入 `containerd 主机基线`，应分别纳入 Pod、工作负载或集群侧安全基线：

- `readOnlyRootFilesystem`
- `allowPrivilegeEscalation: false`
- Seccomp Profile 选择
- AppArmor Profile 选择
- `--device`、`hostPath`、敏感目录挂载
- `--uts=host`
- `--cgroupns=host`
- `pids-limit`
- 镜像内运行 `sshd`

这些控制项属于容器运行规范、Kubernetes `securityContext`、镜像构建规范或准入控制，不属于主机侧 `containerd` 守护进程本身的配置边界。

## 七、最小核查清单

在发布或审计前，至少确认以下项目：

1. 配置文件版本与已安装 `containerd` 主版本匹配。
2. `SystemdCgroup = true` 已在 `systemd` 主机上启用。
3. `/etc/containerd`、`config.toml`、`certs.d`、`containerd.sock`、runtime 二进制不存在非特权写权限。
4. 审计规则已覆盖 `/etc/containerd`、`config.toml`、`certs.d`、`/var/lib/containerd`、`/run/containerd`、`containerd.sock`、`/etc/default/containerd`（如存在）、unit 文件和关键二进制。
5. `containerd.service`、`containerd.socket` 等 unit 文件权限与所有权正确。
6. 仓库配置使用 `config_path` 管理，并通过 `HTTPS` 与受信任证书访问。
7. 未暴露不必要的 TCP 管理接口，`[debug].level` 保持为 `info`。
8. `cgroup_writable`、`privileged_without_host_devices` 等 runtime 默认值未被放宽。
9. 文档中未混入 Docker 专属配置，也未混入 Pod 级安全控制。

## 八、与 Kubernetes 节点基线的关系

若主机同时作为 Kubernetes 节点，本基线应与以下内容配套使用：

- `kubelet` 基线
- Pod 安全基线
- 镜像仓库与签名策略
- Admission / Policy 控制

这样才能把“主机侧运行时安全”和“工作负载侧最小权限”完整拼起来，避免单靠 `containerd` 文档承担本不属于它的控制职责。

## 九、主机核查与整改命令表

以下表格只保留适合主机侧基线的项目，格式统一为“检查项 / 检查命令 / 修复建议”。其中 `config.toml`、`hosts.toml`、`systemd` 启动参数等高风险配置，不建议用 `sed` 一类命令盲改，应先备份再人工合并建议片段。

| 检查项 | 检查命令 | 修复建议 |
| --- | --- | --- |
| 确保为 `/etc/containerd` 目录配置了审核 | `auditctl -l`<br>`grep -R -n '/etc/containerd' /etc/audit/rules.d` | 在 `/etc/audit/rules.d/containerd.rules` 增加 `-w /etc/containerd -p wa -k containerd-dir`<br>执行 `augenrules --load` |
| 确保为 `containerd` 配置文件 `/etc/containerd/config.toml` 配置了审核 | `auditctl -l`<br>`grep -R -n '/etc/containerd/config.toml' /etc/audit/rules.d` | 在 `/etc/audit/rules.d/containerd.rules` 增加 `-w /etc/containerd/config.toml -p wa -k containerd-config`<br>执行 `augenrules --load` |
| 确保为 `containerd` 仓库配置目录 `/etc/containerd/certs.d` 配置了审核 | `auditctl -l`<br>`grep -R -n '/etc/containerd/certs.d' /etc/audit/rules.d` | 在 `/etc/audit/rules.d/containerd.rules` 增加 `-w /etc/containerd/certs.d -p wa -k containerd-registry`<br>执行 `augenrules --load` |
| 确保为 `/var/lib/containerd` 配置了审核 | `auditctl -l`<br>`grep -R -n '/var/lib/containerd' /etc/audit/rules.d` | 在 `/etc/audit/rules.d/containerd.rules` 增加 `-w /var/lib/containerd -p wa -k containerd-state`<br>执行 `augenrules --load` |
| 确保为 `/run/containerd` 配置了审核 | `auditctl -l`<br>`grep -R -n '/run/containerd' /etc/audit/rules.d` | 在 `/etc/audit/rules.d/containerd.rules` 增加 `-w /run/containerd -p wa -k containerd-run`<br>执行 `augenrules --load` |
| 确保为 `containerd.sock` 配置了审核 | `auditctl -l`<br>`grep -R -n '/run/containerd/containerd.sock' /etc/audit/rules.d` | 在 `/etc/audit/rules.d/containerd.rules` 增加 `-w /run/containerd/containerd.sock -p wa -k containerd-sock`<br>执行 `augenrules --load` |
| 确保为 `/etc/default/containerd` 配置了审核 | `test -f /etc/default/containerd && grep -R -n '/etc/default/containerd' /etc/audit/rules.d` | 若文件存在，在 `/etc/audit/rules.d/containerd.rules` 增加 `-w /etc/default/containerd -p wa -k containerd-env`<br>执行 `augenrules --load` |
| 确保为 `containerd.service`、`containerd.socket` 配置了审核 | `systemctl show -p FragmentPath --value containerd`<br>`systemctl show -p FragmentPath --value containerd.socket`<br>`auditctl -l` | 按实际路径追加审计规则：`-w <service-unit> -p wa -k containerd-service`、`-w <socket-unit> -p wa -k containerd-service`<br>执行 `augenrules --load` |
| 确保为 `containerd` 关键二进制配置了审核 | `command -v containerd`<br>`command -v containerd-shim`<br>`command -v containerd-shim-runc-v1`<br>`command -v containerd-shim-runc-v2`<br>`command -v runc`<br>`auditctl -l` | 按实际路径追加审计规则：`-w <binary> -p x -k containerd-bin` 或 `-w <runtime-binary> -p x -k containerd-runtime`<br>执行 `augenrules --load` |
| 确保 `/etc/containerd`、`config.toml` 和 `certs.d` 权限正确 | `stat -c '%U:%G %a %n' /etc/containerd /etc/containerd/config.toml /etc/containerd/certs.d` | 执行 `chown root:root /etc/containerd /etc/containerd/config.toml /etc/containerd/certs.d`<br>执行 `chmod 755 /etc/containerd /etc/containerd/certs.d`<br>执行 `chmod 640 /etc/containerd/config.toml` |
| 确保 `containerd.sock`、`/run/containerd`、`/var/lib/containerd` 和关键二进制不存在非特权写权限 | `stat -c '%U:%G %a %n' /run/containerd /run/containerd/containerd.sock /var/lib/containerd`<br>`stat -c '%U:%G %a %n' "$(command -v containerd)" "$(command -v runc)"` | 执行 `chown root:root /run/containerd/containerd.sock`<br>执行 `chmod 660 /run/containerd/containerd.sock`<br>执行 `chmod go-w /run/containerd /var/lib/containerd "$(command -v containerd)" "$(command -v runc)"` |
| 确保 `containerd.service`、`containerd.socket` 和 `/etc/default/containerd` 权限正确 | `systemctl show -p FragmentPath --value containerd`<br>`systemctl show -p FragmentPath --value containerd.socket`<br>`stat -c '%U:%G %a %n' /etc/default/containerd` | 保持 unit 文件与环境文件为 `root:root`，权限为 `644` 或更严格 |
| 确保 `containerd` 自定义启动参数通过 `systemd drop-in` 管理 | `systemctl show -p FragmentPath -p DropInPaths containerd`<br>`systemctl cat containerd` | 不直接修改 vendor unit。将自定义参数写入 `/etc/systemd/system/containerd.service.d/*.conf`<br>完成后执行 `systemctl daemon-reload && systemctl restart containerd` |
| 确保 `config.toml` 版本与已安装 `containerd` 主版本匹配，且 `SystemdCgroup = true` | `containerd --version`<br>`grep -nE '^[[:space:]]*version[[:space:]]*=' /etc/containerd/config.toml`<br>`grep -n 'SystemdCgroup' /etc/containerd/config.toml` | `containerd 1.x` 使用 `version = 2`<br>`containerd 2.x` 使用 `version = 3`<br>在对应 runtime 配置块中设置 `SystemdCgroup = true`，修改后执行 `systemctl restart containerd` |
| 确保 runtime 默认值未被放宽 | `grep -n 'cgroup_writable' /etc/containerd/config.toml`<br>`grep -n 'privileged_without_host_devices' /etc/containerd/config.toml`<br>`grep -n 'privileged_without_host_devices_all_devices_allowed' /etc/containerd/config.toml` | 确保 `cgroup_writable = false`、`privileged_without_host_devices = false`、`privileged_without_host_devices_all_devices_allowed = false` |
| 确保日志记录级别设置为 `info` | `grep -n 'level' /etc/containerd/config.toml` | 在 `[debug]` 配置块设置 `level = "info"`，非排障场景不要长期使用 `debug` |
| 确保未关闭 `SELinux` / `AppArmor` 集成 | `grep -n 'enable_selinux' /etc/containerd/config.toml`<br>`grep -n 'disable_apparmor' /etc/containerd/config.toml` | 确保 `enable_selinux = true`，并确保 `disable_apparmor = false` |
| 确保未暴露不必要的 TCP 管理接口，且 CRI streaming 仅监听回环地址 | `grep -n 'tcp_address' /etc/containerd/config.toml`<br>`grep -n 'disable_tcp_service' /etc/containerd/config.toml`<br>`grep -n 'stream_server_address' /etc/containerd/config.toml` | 确保 `[grpc].tcp_address = ""`、`disable_tcp_service = true`、`stream_server_address = "127.0.0.1"` |
| 确保 registry 通过 `config_path` 管理，且 `hosts.toml` 未使用 `http://` 或 `skip_verify = true` | `grep -n 'config_path' /etc/containerd/config.toml`<br>`find /etc/containerd/certs.d -maxdepth 2 -name hosts.toml -print`<br>`grep -R -n 'http://' /etc/containerd/certs.d`<br>`grep -R -n 'skip_verify = true' /etc/containerd/certs.d` | 确保 registry 使用 `config_path` 管理，并移除 `http://` 和 `skip_verify = true` 这类不安全配置 |

## 十、整合脚本

下载地址：

已补充整合脚本：`Containerd/containerd_host_baseline.sh`

脚本职责如下：

- `check`：执行主机侧基线检查并输出 `PASS / WARN / FAIL`
- `fix-audit`：生成并加载 `containerd` 审计规则，覆盖目录、socket、unit、环境文件和关键二进制
- `fix-perms`：修复目录、文件、socket、unit、环境文件和关键二进制的权限与所有权
- `fix-socket-dropin`：生成 `containerd.socket` 的权限 drop-in
- `print-config`：输出 `config.toml` 的建议配置片段，供人工合并

推荐用法：

```bash
bash Containerd/containerd_host_baseline.sh check
bash Containerd/containerd_host_baseline.sh fix-audit
bash Containerd/containerd_host_baseline.sh fix-perms
bash Containerd/containerd_host_baseline.sh fix-socket-dropin
bash Containerd/containerd_host_baseline.sh print-config
```

自动化边界：

- 脚本只自动处理“可确定、可回滚、低歧义”的整改项。
- `config.toml`、`hosts.toml`、`containerd.service` 的参数合并仍建议人工确认后再改。
- 若主机不是 `systemd` / `auditd` 环境，脚本会跳过对应动作并给出提示。

## 参考链接

- containerd 项目主页：[https://github.com/containerd/containerd](https://github.com/containerd/containerd)
- containerd CRI 配置文档：[https://github.com/containerd/containerd/blob/main/docs/cri/config.md](https://github.com/containerd/containerd/blob/main/docs/cri/config.md)
- containerd registry `hosts.toml` 配置文档：[https://github.com/containerd/containerd/blob/main/docs/hosts.md](https://github.com/containerd/containerd/blob/main/docs/hosts.md)
- Kubernetes Container Runtimes 文档：[https://kubernetes.io/docs/setup/production-environment/container-runtimes/](https://kubernetes.io/docs/setup/production-environment/container-runtimes/)
- Kubernetes Pod Security Standards：[https://kubernetes.io/docs/concepts/security/pod-security-standards/](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- OCI Runtime Specification：[https://github.com/opencontainers/runtime-spec](https://github.com/opencontainers/runtime-spec)
- Linux `auditctl(8)` 手册：[https://man7.org/linux/man-pages/man8/auditctl.8.html](https://man7.org/linux/man-pages/man8/auditctl.8.html)

<!-- 这是一张图片，ocr 内容为： -->

![](https://cdn.nlark.com/yuque/0/2026/jpeg/27875807/1771929928377-73947b1a-b47e-45da-b30d-a74da57a76fd.jpeg)
