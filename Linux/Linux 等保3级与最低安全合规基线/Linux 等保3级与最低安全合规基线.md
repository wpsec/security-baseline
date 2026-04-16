## 一、适用范围与使用原则

本基线适用于通用 Linux 服务器主机，聚焦等保三级与最低安全合规中最常见、最稳定、最适合在主机侧落地的控制项，覆盖身份鉴别、访问控制、安全审计、SSH 服务配置、文件权限与基础入侵防范。

- 适用对象：独立 Linux 主机、云主机、容器宿主机、Kubernetes Node 的宿主机操作系统
- 适用范围：本地账户、PAM 认证、口令策略、`sshd`、`auditd`、`rsyslog`、关键权限文件、基础内核安全参数
- 不在本文自动修复范围：
  - 漏洞扫描、补丁发布窗口、灰度验证、回滚审批
  - 杀毒、EDR、HIDS、主机入侵检测平台联动
  - 堡垒机、源地址白名单、运维网段管控
  - 账号审批、岗位分离、授权矩阵、共享账号治理流程
  - 数据库表级、业务文件级、应用进程级访问控制设计

使用原则：

- 优先检查“主机上可直接确认的事实”，不要把制度要求伪装成已自动校验
- 自动修复只处理“可确定、低歧义、可回滚”的主机项
- 不依赖单一发行版专有路径，优先兼容 `RHEL` / `Rocky` / `AlmaLinux` / `CentOS` / `Ubuntu` / `Debian`
- 对高风险认证配置先备份再改，避免直接覆盖用户自定义策略

执行前建议先确认主机实际环境：

```bash
cat /etc/os-release
uname -r
command -v sshd
command -v auditctl
command -v rsyslogd
command -v faillock
command -v chage
systemctl is-enabled sshd 2>/dev/null || systemctl is-enabled ssh 2>/dev/null
```

## 二、控制边界说明

你提供的参考检查项既包含主机配置项，也包含流程性、平台型和运营型要求。为了避免“脚本看起来全检查了，实际上只是表面扫一遍”，这里先划清边界。

### 1. 可在主机侧直接核查或整改的项

- 口令复杂度、口令历史、口令有效期、最小修改间隔、到期预警
- 空密码账户、`root` 是否为唯一 `UID 0` 账户
- SSH 空密码登录、`MaxAuthTries`、空闲超时、`LogLevel`
- 审计服务、日志服务、审计规则、审计日志文件保护
- 登录失败处理、会话超时、关键访问控制配置文件权限
- 不必要服务与高危端口的基础发现
- 地址空间布局随机化（ASLR）

### 2. 只能部分核查、不能一键修复的项

- 默认账户重命名或删除：不同发行版、镜像、运维体系差异大，应人工确认
- 多余账户、过期账户、共享账户：脚本可以给出线索，但不能代替账号台账
- 管理员最小权限与权限分离：需结合 `sudoers`、组织角色和审批流程综合判断
- 通过网络地址范围限制远程管理终端：通常依赖安全组、防火墙、堡垒机、ACL
- 关闭不需要的系统服务和默认共享：脚本可以列出开放端口和已启用服务，但需人工确认业务影响

### 3. 明确属于平台或流程能力的项

- 已知漏洞发现与补丁及时修补
- 恶意代码防护、病毒阻断、可信验证
- 严重入侵事件告警联动
- 审计日志异地备份、集中存储、长期留存策略

这些项目在文档中会保留，但会明确标为“需平台治理”，不误写成纯主机脚本可完全落地。

## 三、身份鉴别基线

### 1. 账户身份唯一、密码复杂度与定期更换

基线要求：

- 禁止空密码账户
- `root` 必须是唯一的 `UID 0` 账户
- 应启用密码复杂度策略，至少约束长度、字符类型和失败重试
- 应启用密码历史复用限制
- 应配置密码最长有效期、最小修改间隔和到期前告警

推荐口径：

- `minlen >= 8`
- 至少启用大写、小写、数字、特殊字符中的多类组合
- `remember >= 5`
- `PASS_MAX_DAYS <= 90`
- `PASS_MIN_DAYS >= 1`
- `PASS_WARN_AGE >= 7`

参考命令：

```bash
awk -F: 'length($2)==0 {print $1}' /etc/shadow
awk -F: '($3 == 0) {print $1}' /etc/passwd
grep -E '^\s*PASS_(MAX_DAYS|MIN_DAYS|WARN_AGE)' /etc/login.defs
grep -R -nE 'pam_pwquality\.so|pam_cracklib\.so|remember=' /etc/pam.d
```

### 2. 登录失败处理与会话控制

基线要求：

- 应启用登录失败锁定或限速机制
- 应限制非法登录次数
- 应配置登录连接超时自动退出
- 远程管理必须避免明文传输鉴别信息

推荐口径：

- 优先使用 `pam_faillock`
- SSH 仅允许协议 `2`
- 使用 `ClientAliveInterval` / `ClientAliveCountMax` 以及 shell `TMOUT` 控制空闲退出

## 四、访问控制基线

### 1. 账户分配、最小权限、权限分离

基线要求：

- 登录用户应有明确账户归属，不允许长期共享账号
- 管理操作应通过受控提权完成，不建议直接长期使用 `root` 登录
- 管理员权限应按最小授权原则配置

主机侧核查重点：

- `sudoers` 与 `/etc/sudoers.d` 是否被非特权用户写入
- 是否存在 `NOPASSWD: ALL`、`ALL=(ALL) ALL` 等过宽授权
- 是否允许 `root` 直接 SSH 登录

### 2. 访问控制配置文件保护

基线要求：

- `/etc/passwd`、`/etc/group`、`/etc/shadow`、`/etc/gshadow`
- `/etc/ssh/sshd_config`
- `/etc/pam.d/*`
- `/etc/sudoers`、`/etc/sudoers.d/*`

均应由 `root` 管理，且权限不应过宽。

推荐口径：

- `/etc/passwd`、`/etc/group`：`644` 或更严格
- `/etc/shadow`、`/etc/gshadow`：`000` / `600` / `640`，以发行版默认和可用性为准
- `/etc/ssh/sshd_config`：`600` 或 `644`
- `/etc/sudoers`：`440`

## 五、安全审计基线

### 1. 启用审计与日志

基线要求：

- 应启用 `auditd`
- 应启用 `rsyslog` 或发行版等效日志服务
- 审计应覆盖账户、身份、权限、提权、SSH 配置与审计配置自身变更

建议至少审计以下对象：

```bash
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/security/opasswd -p wa -k identity
-w /etc/sudoers -p wa -k scope
-w /etc/sudoers.d -p wa -k scope
-w /etc/ssh/sshd_config -p wa -k sshd
-w /etc/pam.d -p wa -k pam
-w /etc/login.defs -p wa -k login_defs
-w /var/log/lastlog -p wa -k logins
-w /var/run/faillock -p wa -k logins
```

### 2. 审计日志保护

基线要求：

- 审计进程不应被未授权中断
- 审计日志文件不应被普通用户删除、覆盖或篡改
- 审计记录应至少包含时间、用户、事件类型、结果等信息

说明：

- 审计字段完整性主要依赖 `auditd` 与系统日志能力，脚本只能检查服务与规则是否存在
- 审计日志备份、集中归集、长周期保存通常需要日志平台配合

## 六、SSH 与远程管理基线

基线要求：

- 禁止空密码 SSH 登录
- `MaxAuthTries` 应配置在 `3-6` 之间
- `LogLevel` 应至少为 `INFO`
- 应配置 SSH 空闲超时退出
- 建议禁止 `root` 直接远程登录，管理员使用普通账号加 `sudo`

推荐配置片段：

```conf
PermitEmptyPasswords no
PasswordAuthentication yes
MaxAuthTries 4
LogLevel INFO
ClientAliveInterval 300
ClientAliveCountMax 0
PermitRootLogin no
```

如果环境依赖堡垒机、证书登录或双因子认证，应在此基础上按企业规范收紧。

## 七、入侵防范与最小安装

### 1. 关闭不需要的服务、共享与高危暴露

基线要求：

- 遵循最小安装原则，仅安装需要的组件
- 关闭不需要的系统服务
- 识别并评估不必要的监听端口、共享服务与远程管理入口

主机侧推荐检查：

```bash
systemctl list-unit-files --state=enabled
ss -lntup
rpm -qa 2>/dev/null | sort
dpkg -l 2>/dev/null
```

说明：

- 是否“多余”必须结合业务判断，脚本只输出发现结果，不直接关停服务
- NFS、Samba、RPC、Telnet、FTP 等传统暴露服务如无业务需要，应优先关闭

### 2. 内核基础防护

基线要求：

- 应启用地址空间布局随机化（ASLR）

参考命令：

```bash
sysctl kernel.randomize_va_space
```

推荐值：

- `kernel.randomize_va_space = 2`

## 八、漏洞、恶意代码与告警能力

以下项目重要，但通常不应被写成“单机脚本已完成”：

- 已知漏洞发现与补丁修复
- 恶意代码识别与阻断
- 入侵检测与高危告警
- 远程管理终端源地址限制

建议落地方式：

- 漏洞管理平台或云安全中心定期扫描
- EDR / HIDS / 杀毒引擎 / 主机防护代理
- 堡垒机、跳板机、安全组、主机防火墙白名单
- 补丁窗口、回归验证、变更审批与回滚机制

## 九、最小核查清单

在发布或审计前，至少确认以下项目：

1. 不存在空密码账户，且 `root` 是唯一 `UID 0` 账户。
2. 已启用密码复杂度、密码历史复用限制、密码有效期和到期告警。
3. 已启用登录失败锁定或限速机制。
4. SSH 禁止空密码登录，`MaxAuthTries` 位于 `3-6`，`LogLevel` 为 `INFO`，已设置空闲超时。
5. `auditd` 与 `rsyslog` 已启用并开机自启。
6. 审计规则已覆盖身份、提权、PAM、SSH 与关键日志对象。
7. 关键访问控制配置文件权限正确，普通用户不可写。
8. 已检查启用服务和监听端口，并完成业务必要性确认。
9. ASLR 已启用。
10. 漏洞修补、恶意代码防护、入侵告警与日志备份已有平台侧支撑。

## 十、主机核查与整改命令表

### 身份鉴别

| 检查项 | 检查命令 | 修复建议 |
| --- | --- | --- |
| **高危** 应对登录的用户进行身份标识和鉴别，身份标识具有唯一性，身份鉴别信息具有复杂度要求并定期更换 | `grep -E '^\s*PASS_(MAX_DAYS|MIN_DAYS|WARN_AGE)' /etc/login.defs`<br>`grep -R -nE 'pam_pwquality\.so|pam_cracklib\.so|remember=' /etc/pam.d` | 在 `PAM` 与 `/etc/login.defs` 中启用复杂度、历史复用和失效周期控制；如发行版使用 `authselect`，应通过其模板管理 |
| **高危** 检查系统空密码账户 | `awk -F: 'length($2)==0 {print $1}' /etc/shadow` | 为账号设置强密码或立即锁定无主账号；禁止长期保留空密码账户 |
| **高危** 确保 root 是唯一的 UID 为 0 的账户 | `awk -F: '($3 == 0) {print $1}' /etc/passwd` | 非 `root` 的 `UID 0` 账户应立即整改为普通 UID 或停用 |
| **高危** 密码复杂度检查 | `grep -R -nE 'pam_pwquality\.so|pam_cracklib\.so' /etc/pam.d /etc/security` | 启用 `pam_pwquality`，建议至少要求长度、字符类型和重试次数 |
| **高危** 检查密码重用是否受限制 | `grep -R -n 'remember=' /etc/pam.d /etc/security` | 在密码修改链路配置 `remember >= 5` |
| **中危** 设置密码失效时间 | `grep -E '^PASS_MAX_DAYS' /etc/login.defs` | 建议设置 `PASS_MAX_DAYS 90` 或更短 |
| **中危** 设置密码修改最小间隔时间 | `grep -E '^PASS_MIN_DAYS' /etc/login.defs` | 建议设置 `PASS_MIN_DAYS 1` |
| **中危** 确保密码到期警告天数为 7 或更多 | `grep -E '^PASS_WARN_AGE' /etc/login.defs` | 建议设置 `PASS_WARN_AGE 7` 或更大 |
| **高危** 应具有登录失败处理功能，应配置并启用结束会话、限制非法登录次数和当登录连接超时自动退出等相关措施 | `grep -R -nE 'pam_faillock\.so|pam_tally2\.so' /etc/pam.d`<br>`grep -R -n '^TMOUT=' /etc/profile /etc/profile.d /etc/bashrc /etc/bash.bashrc` | 优先启用 `pam_faillock`；同时设置 shell `TMOUT` 和 SSH `ClientAlive*` 参数 |
| **高危** 当对服务器进行远程管理时，应采取必要措施，防止鉴别信息在网络传输过程中被窃听 | `sshd -T 2>/dev/null | grep -E '^(passwordauthentication|permitemptypasswords|kexalgorithms|ciphers|macs)'` | 仅通过 `SSH` 等加密协议远程管理；如企业要求，进一步启用堡垒机、证书登录或 MFA |

### 访问控制

| 检查项 | 检查命令 | 修复建议 |
| --- | --- | --- |
| **高危** 应重命名或删除默认账户，修改默认账户的默认口令 | `getent passwd | awk -F: '$3 >= 1000 {print $1}'` | 主机脚本只能给出账户清单；是否为默认账户需结合镜像、应用与运维规范人工确认 |
| **高危** 应对登录的用户分配账户和权限 | `getent passwd`<br>`sudo -l -U <user>` | 建立实名账户并通过 `sudo` 受控提权，避免共享账户 |
| **高危** 应及时删除或停用多余的、过期的账户，避免共享账户的存在 | `getent passwd`<br>`chage -l <user>` | 定期核对账号台账，停用离职、过期和无归属账号；共享账号迁移至实名账户或堡垒机代理 |
| **高危** 应授予管理用户所需的最小权限，实现管理用户的权限分离 | `grep -R -nE 'NOPASSWD|ALL=\(ALL(:ALL)?\) ALL' /etc/sudoers /etc/sudoers.d 2>/dev/null` | 审核 `sudoers` 规则，避免过宽授权；按职责拆分管理角色 |
| **高危** 应由授权主体配置访问控制策略，访问控制策略规定主体对客体的访问规则 | `ls -ld /etc/sudoers /etc/sudoers.d`<br>`stat -c '%U:%G %a %n' /etc/sudoers` | 通过受控配置管理维护 `sudoers` 和访问控制文件，限制非授权主体写入 |
| **高危** 访问控制的粒度应达到主体为用户级或进程级，客体为文件、数据库表级 | `namei -l /etc/shadow`<br>`namei -l /etc/sudoers` | 主机侧至少做到用户级文件权限控制；数据库表级需由数据库与应用侧另行治理 |

### 安全审计

| 检查项 | 检查命令 | 修复建议 |
| --- | --- | --- |
| **高危** 应启用安全审计功能，审计覆盖到每个用户，对重要的用户行为和重要安全事件进行审计 | `systemctl is-enabled auditd`<br>`auditctl -l` | 启用 `auditd`，并为身份、提权、PAM、SSH 配置关键对象落审计规则 |
| **高危** 审计记录应包括事件的日期和时间、用户、事件类型、事件是否成功及其他与审计相关的信息 | `ausearch -m USER_LOGIN -ts today 2>/dev/null | head` | 确保 `auditd` 正常记录标准事件类型；详细字段完整性依赖平台和规则设计 |
| **高危** 应保护审计进程，避免受到未预期的中断 | `systemctl status auditd --no-pager` | 启用 `auditd` 开机自启，并限制非授权主体停用服务 |
| **高危** 应对审计记录进行保护，定期备份，避免受到未预期的删除、修改或覆盖等 | `stat -c '%U:%G %a %n' /var/log/audit /var/log/audit/audit.log 2>/dev/null` | 收敛日志目录权限，并将备份、归集和留存交给日志平台或备份系统 |
| **高危** 确保 rsyslog 服务已启用 | `systemctl is-enabled rsyslog` | 启用 `rsyslog` 或发行版等效日志服务 |

### 文件权限

| 检查项 | 检查命令 | 修复建议 |
| --- | --- | --- |
| **高危** 访问控制配置文件的权限设置 | `stat -c '%U:%G %a %n' /etc/passwd /etc/group /etc/shadow /etc/gshadow /etc/ssh/sshd_config /etc/sudoers 2>/dev/null` | 统一收敛为 `root` 管理，防止普通用户写入 |
| **高危** 设置用户权限配置文件的权限 | `find /etc/sudoers.d -maxdepth 1 -type f -exec stat -c '%U:%G %a %n' {} + 2>/dev/null` | `/etc/sudoers.d/*` 应仅允许 `root` 管理，避免组写或其他用户写 |

### SSH 服务配置

| 检查项 | 检查命令 | 修复建议 |
| --- | --- | --- |
| **中危** 使用非 root 账号登录实例 | `sshd -T 2>/dev/null | grep '^permitrootlogin'` | 建议设置 `PermitRootLogin no`，管理员通过实名账号和 `sudo` 运维 |
| **高危** 禁止 SSH 空密码用户登录 | `sshd -T 2>/dev/null | grep '^permitemptypasswords'` | 设置 `PermitEmptyPasswords no` |
| **高危** 确保 SSH MaxAuthTries 设置为 3 到 6 之间 | `sshd -T 2>/dev/null | grep '^maxauthtries'` | 推荐设置 `MaxAuthTries 4` |
| **中危** 设置 SSH 空闲超时退出时间 | `sshd -T 2>/dev/null | grep -E '^(clientaliveinterval|clientalivecountmax)'` | 建议配置 `ClientAliveInterval 300` 和 `ClientAliveCountMax 0` |
| **中危** 确保 SSH LogLevel 设置为 INFO | `sshd -T 2>/dev/null | grep '^loglevel'` | 设置 `LogLevel INFO` |

### 入侵防范

| 检查项 | 检查命令 | 修复建议 |
| --- | --- | --- |
| **高危** 应关闭不需要的系统服务、默认共享和高危端口 | `systemctl list-unit-files --state=enabled`<br>`ss -lntup` | 结合业务梳理后关闭不必要服务；对外暴露端口通过防火墙、安全组、ACL 收敛 |
| **高危** 应能发现可能存在的已知漏洞，并在经过充分测试评估后，及时修补漏洞 | `rpm -qa --last 2>/dev/null | head`<br>`apt list --upgradable 2>/dev/null` | 该项依赖漏洞管理与补丁流程，需平台持续治理 |
| **高危** 应采用免受恶意代码攻击的技术措施或主动免疫可信验证机制及时识别入侵和病毒行为，并将其有效阻断 | `systemctl list-units | grep -Ei 'falco|auditd|osquery|agent|edr|hids|defender|clam'` | 该项依赖 EDR / HIDS / 杀毒 / 主机防护产品，需平台侧治理 |
| **高危** 应能够检测到对重要节点进行入侵的行为，并在发生严重入侵事件时提供报警 | `systemctl list-units | grep -Ei 'falco|wazuh|agent|edr|hids'` | 该项依赖告警平台、日志平台或主机安全中心，不应误判为单机脚本可完全实现 |
| **高危** 应通过设定终端接入方式或网络地址范围对通过网络进行管理的管理终端进行限制 | `ss -lntup`<br>`firewall-cmd --list-all 2>/dev/null || ufw status 2>/dev/null` | 优先通过堡垒机、安全组、主机防火墙白名单、运维网段 ACL 管控 |
| **高危** 应遵循最小安装的原则，仅安装需要的组件和应用程序 | `rpm -qa 2>/dev/null | wc -l`<br>`dpkg -l 2>/dev/null | wc -l` | 定期梳理组件清单，移除无业务依赖的软件包与调试工具 |
| **中危** 开启地址空间布局随机化 | `sysctl kernel.randomize_va_space` | 设置 `kernel.randomize_va_space = 2` |

## 十一、整合脚本

已补充配套脚本：

- `Linux/Linux 等保3级与最低安全合规基线/linux_mlps_baseline.sh`

脚本职责如下：

- 无参数执行：输出 Linux 主机环境信息
- `check`：执行主机侧等保三级 / 最低安全合规检查并输出 `PASS / WARN / FAIL`
- `fix-auth`：修复口令有效期默认值、创建 `TMOUT` 配置、加固 SSH 常见认证参数
- `fix-audit`：生成并加载主机审计规则，覆盖身份、提权、PAM、SSH 与关键日志对象
- `fix-perms`：修复关键账户、SSH、`sudoers`、审计日志文件权限
- `fix-sysctl`：启用 `ASLR`
- `fix-all`：执行可自动落地的主机侧加固项
- `print-config`：输出建议配置片段，供人工合并

推荐用法：

```bash
bash 'Linux/Linux 等保3级与最低安全合规基线/linux_mlps_baseline.sh'
bash 'Linux/Linux 等保3级与最低安全合规基线/linux_mlps_baseline.sh' check
sudo bash 'Linux/Linux 等保3级与最低安全合规基线/linux_mlps_baseline.sh' fix-auth
sudo bash 'Linux/Linux 等保3级与最低安全合规基线/linux_mlps_baseline.sh' fix-audit
sudo bash 'Linux/Linux 等保3级与最低安全合规基线/linux_mlps_baseline.sh' fix-perms
sudo bash 'Linux/Linux 等保3级与最低安全合规基线/linux_mlps_baseline.sh' fix-sysctl
sudo bash 'Linux/Linux 等保3级与最低安全合规基线/linux_mlps_baseline.sh' fix-all
bash 'Linux/Linux 等保3级与最低安全合规基线/linux_mlps_baseline.sh' print-config
```

自动化边界：

- 脚本不会删除账户、不会停服务、不会直接修改 `sudoers` 授权内容
- 漏洞修补、恶意代码防护、入侵告警、远程管理地址白名单仅输出提示，不做伪自动化
- 修复前会先在源文件同目录生成时间戳备份
- 若系统未安装 `auditd`、`rsyslog` 或 `sshd`，脚本会跳过对应修复并给出提示

## 参考链接

- Linux PAM 文档：<https://linux.die.net/man/8/pam>
- Linux `pam_pwquality(8)`：<https://man7.org/linux/man-pages/man8/pam_pwquality.8.html>
- Linux `pam_faillock(8)`：<https://man7.org/linux/man-pages/man8/pam_faillock.8.html>
- Linux `login.defs(5)`：<https://man7.org/linux/man-pages/man5/login.defs.5.html>
- OpenSSH `sshd_config(5)`：<https://man.openbsd.org/sshd_config>
- Linux `auditctl(8)`：<https://man7.org/linux/man-pages/man8/auditctl.8.html>
- Linux `sysctl.d(5)`：<https://man7.org/linux/man-pages/man5/sysctl.d.5.html>
