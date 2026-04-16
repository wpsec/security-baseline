# security-baseline

安全基线仓库，按组件沉淀主机侧、运行时侧与平台侧的安全最佳实践、检查项和配套脚本。

## 当前内容

### Containerd

- 基线文档：[Containerd/Containerd 主机国际通用安全最佳实践基线.md](Containerd/Containerd%20主机国际通用安全最佳实践基线.md)
- 整合脚本：`Containerd/containerd_host_baseline.sh`

基线文档覆盖以下内容：

- `containerd` 主机侧适用范围、使用原则与审计策略
- 配置目录、socket、二进制权限要求
- `systemd`、CRI、registry、SELinux、AppArmor 相关加固建议
- 主机核查与整改命令表

整合脚本支持以下模式：

- `check`：执行主机侧基线检查并输出 `PASS / WARN / FAIL`
- `fix-audit`：生成并加载 `containerd` 审计规则
- `fix-perms`：修复目录、文件、socket、二进制的权限与所有权
- `fix-socket-dropin`：生成 `containerd.socket` 的权限 drop-in
- `print-config`：输出 `config.toml` 建议配置片段，供人工合并

示例：

```bash
bash Containerd/containerd_host_baseline.sh check
bash Containerd/containerd_host_baseline.sh fix-audit
bash Containerd/containerd_host_baseline.sh fix-perms
bash Containerd/containerd_host_baseline.sh fix-socket-dropin
bash Containerd/containerd_host_baseline.sh print-config
```
