# 本机 CLI 工具管理

设置中的「当前支持的 Agent CLI 工具」展示 DWS 和所有有固定可执行程序的 Agent 渠道。名称后的版本来自实际检测到的程序的 `--version`，与模型版本、桌面应用版本无关。「已安装」只说明找到了可执行程序，不代表已登录。

各工具使用对应的本地 SVG 应用图标，统一尺寸并适配深浅色模式；名称下方不再重复展示通用用途说明。图标无需联网加载，来源与许可见 `Sources/DWSAssistant/Resources/CLIIcons/CLIIcons-SOURCES.md`。

- **安装检测**：重新查找程序并读取版本。DWS 官方 bridge 补充检测桌面应用内附带的 CLI；自定义路径优先。此操作不安装软件、不调用模型。读取版本失败时仍保留「已安装」，显示「版本未知」。未安装的工具自动查询对应官方 CLI 包的稳定版，在名称旁直接显示「v版本号」，右侧只保留「安装」按钮；查询失败时显示版本暂不可用。首次打开工具设置也会执行此检测。
- **检查更新**：先检测本机安装，再查询官方版本。DWS 使用 `upgrade --check --format json`，独立 Qoder CLI 使用 `update --check`。其他 npm 发行版查询对应官方包的 `latest`；Homebrew 官方仓库查询其公开 API，第三方 tap 交给 Homebrew 的更新流程。网络或解析失败会显示错误，不当作“已是最新版本”。
- **安装 / 更新**：按钮仅显示文字。已安装工具只有确认官方版本高于当前版本时才显示「更新」，版本按「v当前版本 -> v新版本」显示。尚未检查、版本未知、检查失败或没有更高版本时均不显示更新按钮。只有点击行内按钮才执行安装或更新。npm 安装沿用已检测到的全局 prefix 和包名；Homebrew 安装使用 `brew upgrade`；支持原生更新器的独立安装调用官方更新命令。成功或失败后都会重新检测实际安装与版本。

Qoder/QoderWork、CodeBuddy/WorkBuddy 可能共用一个 CLI，检测和检查更新会复用同一结果。`custom` 没有固定程序，在会话配置中通过启动命令接入，不提供统一的安装与版本管理。

## 官方来源

| 工具 | npm 包 / 官方入口 | 独立安装的更新入口 |
| --- | --- | --- |
| DWS | [dingtalk-workspace-cli](https://github.com/DingTalk-Real-AI/dingtalk-workspace-cli#installation) | `dws upgrade --yes` |
| Codex | [@openai/codex](https://github.com/openai/codex#installation) | 按官方安装说明更新 |
| Claude Code | [@anthropic-ai/claude-code](https://code.claude.com/docs/en/setup) | `claude update` |
| Qoder | [@qoder-ai/qodercli](https://docs.qoder.com/cli/installation) | `qodercli update` |
| QoderWork | [Qoder 官方网站](https://qoder.com) | 所属桌面应用；共用独立 CLI 时使用其更新入口 |
| OpenCode | [opencode-ai](https://opencode.ai/docs/) | `opencode upgrade` |
| WorkBuddy | [WorkBuddy 官方网站](https://www.codebuddy.cn/work/) | 所属桌面应用；共用独立 CLI 时使用其更新入口 |
| CodeBuddy | [@tencent-ai/codebuddy-code](https://www.codebuddy.ai/docs/cli/quickstart) | `codebuddy update` |
| Gemini | [@google/gemini-cli](https://geminicli.com/docs/get-started/installation/) | 按官方安装说明更新 |
| Pi | [@earendil-works/pi-coding-agent](https://github.com/earendil-works/pi) | 按官方安装说明更新 |

Qoder 保留当前固定 DWS 版本使用的 `qodercli`，安装使用官方仍支持的 npm 分发；不会把新的 `qoder` 命令误认为已满足旧版 DWS 的依赖。旧 Pi npm 包沿用已安装包名。

桌面应用内附带的程序不会被面板覆盖，更新由所属应用管理；第三方 Homebrew tap 需通过 Homebrew 检查更新。缺少 npm、桌面应用渠道或自定义启动器未安装时，「安装」打开官方说明。未安装的共享渠道展示对应 CLI 包的可安装版本，并非桌面应用的版本。更新仍遵循工具自身的发布渠道与配置；面板不会改写它们。使用 npm `latest` 比较的是最新稳定发行版，预览版本高于稳定版时不执行降级。

执行命令使用参数数组，不经过 shell，不自动提权。安装/更新有超时限制，面板只展示版本、状态和简短错误提示，不展示命令输出或原始检查结果。正在被助手服务使用的工具暂停直接更新；退出面板会等待已开始的安装/更新结束。检测和更新检查仅在打开工具设置或点击按钮时进行，不加入账号的周期性检查。
