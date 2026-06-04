# My Claude Skills

个人收藏和管理的 AI 编程助手 Skills 集合。通过 `skills.yaml` 清单统一跟踪多个 GitHub 仓库和本地 Skills，使用 `install.sh` 一键部署到 Claude Code 和 Codex：普通 skills 使用符号链接，plugin 仓库分别走 Claude Code plugin CLI 或 Codex plugin/marketplace CLI。

## Quick Start

```bash
# 安装所有 skills/plugins（clone/update + plugin/symlink 部署 + 清理）
./install.sh

# 只处理 Claude Code 或 Codex
./install.sh --target claude
./install.sh --target codex

# 预览模式，不做实际修改
./install.sh --dry-run

# 列出所有已管理的 skills 及其状态
./install.sh --list

# 显式启用清理（默认已启用）
./install.sh --cleanup

# 跳过清理，仅克隆/更新并创建符号链接
./install.sh --no-cleanup
```

**前置依赖：** `python3` + `PyYAML`（脚本会自动安装）

## 工作原理

1. `skills.yaml` 定义 skill/plugin 来源（GitHub 仓库、本地 skills）和目标目录 `skills_dir`
2. `install.sh` 会克隆/更新需要本地扫描的仓库到 `.repos/`，但只为启用的 symlink 仓库（默认启用，或显式 `enabled: true`）扫描和创建符号链接
3. 重复运行时自动检查远程仓库更新——比较本地与远程 commit hash，有更新才拉取，并显示变更的 commit 摘要（如 `Updated repo (abc1234 -> def5678)`）；已是最新则显示 `Up-to-date`
4. 符号链接指向 `.repos/` 中的目录，仓库更新后 symlink 自动指向最新内容，无需重建链接
5. 本地 skills 优先级高于同名的仓库 skills
6. `install_mode: plugin` 的仓库在 Claude target 下使用 `claude plugin`；在 Codex target 下按 `codex.mode` 使用 Codex marketplace、adapter、symlink fallback 或跳过
7. 普通 `./install.sh` 默认会清理"指向本项目 `.repos/` 或项目根目录"但已不再托管的 symlink，并删除 `.repos/` 下已不在 `skills.yaml` 的 Git clone 缓存；不会误伤 Codex 自带的 `.system/` 目录或你手动放的其他 skill 目录。需要跳过清理时使用 `--no-cleanup`

## 启用/禁用仓库

每个 `repos:` 条目都支持 `enabled` 和 `enabled_skills`。`enabled` 默认等同于 `true`，所以已有配置不需要改。

```yaml
repos:
  agent-skills:
    enabled: true
    url: https://github.com/addyosmani/agent-skills.git
    branch: main
    skills_path: skills

  baoyu-skills:
    enabled: false
    url: https://github.com/JimLiu/baoyu-skills.git
    branch: main
    skills_path: skills
    enabled_skills:
      - baoyu-compress-image
      - baoyu-translate
```

部署规则：

- `enabled: true`：部署该 repo 内全部 skills；即使写了 `enabled_skills` 或旧的 `include` 字段也不会过滤
- `enabled: false` 且没有 `enabled_skills`：继续 clone/update 该 repo，但不部署任何 symlink
- `enabled: false` 且设置了 `enabled_skills`：继续 clone/update 该 repo，只为 `enabled_skills` 列出的 skills 创建 symlink

`enabled_skills` 可以填写 repo 内的原始 skill 目录名，也可以填写加上 `prefix` 后最终创建的 symlink 名。

默认 cleanup 会移除不再应该部署的 managed symlink，但 `.repos/<repo>` clone cache 会保留并持续更新，因为它仍在 `skills.yaml` 中受管理。

## Plugin 安装模式

`install_mode: plugin` 的 repo 支持 Claude 和 Codex 两套安装方式：

```yaml
repos:
  baoyu-skills:
    install_mode: plugin
    url: https://github.com/JimLiu/baoyu-skills.git
    marketplace: baoyu-skills      # Claude Code marketplace
    plugin: baoyu-skills           # Claude Code plugin
    branch: main
    skills_path: skills
    codex:
      mode: adapter
      marketplace: baoyu-skills    # Codex selector: baoyu-skills@baoyu-skills
      plugin: baoyu-skills
      skills_path: skills

  guige-skills:
    install_mode: plugin
    url: https://github.com/luoli523/guige-skills.git
    marketplace: guige-skills
    plugin: guige
    codex:
      mode: marketplace
      marketplace: guige-skills    # Codex selector: guige@guige-skills
      plugin: guige
```

Codex 的 `codex.mode` 可选：

- `marketplace`：上游 repo 已经是 Codex marketplace 格式，直接调用 `codex plugin marketplace add/upgrade` 和 `codex plugin add <plugin>@<marketplace>`
- `adapter`：上游还不是 Codex marketplace，安装器在 `.codex-adapters/<marketplace>/` 生成本地 Codex marketplace 和 plugin wrapper，再安装 `<plugin>@<marketplace>`
- `symlink`：显式保留旧行为，直接 symlink 到 `~/.codex/skills`
- `none`：Codex target 不安装

### 多目标目录（Claude Code + Codex）

`skills_dir` 支持按 target 配置，默认配置：

```yaml
skills_dir:
  claude: ~/.claude/skills
  codex: ~/.codex/skills
```

脚本仍兼容旧的数组格式；如果 `skills_dir` 是单个字符串，Claude 和 Codex target 会共用这个目录。Codex 和 Claude Code 的 skill 目录格式兼容（同样是含 `SKILL.md` 的目录、同样的 frontmatter），因此 symlink 模式下一份源文件在两边都能被识别。Codex 自带的系统 skills（`~/.codex/skills/.system/`）不受影响。

## 添加新仓库

编辑 `skills.yaml`：

```yaml
repos:
  # 仓库内含多个 skill 子目录
  my-skills-collection:
    enabled: true           # 可选；默认 true。设为 false 仍更新仓库但不部署 symlink
    url: https://github.com/user/repo.git
    branch: main
    skills_path: "."         # 扫描路径，"." 表示根目录

  # 仓库默认禁用，但允许少数 skills 部署 symlink
  mostly-disabled-skills:
    enabled: false
    url: https://github.com/user/many-skills.git
    branch: main
    skills_path: "skills"
    enabled_skills:
      - skill-a
      - skill-b

  # 仓库本身就是一个 skill
  my-single-skill:
    url: https://github.com/user/single-skill.git
    branch: main
    single_skill: true       # 根目录有 SKILL.md

  # 给整个仓库的 skills 统一加前缀（便于辨识来自同一 set）
  some-skills:
    url: https://github.com/user/some-skills.git
    branch: main
    skills_path: "skills"
    prefix: "some-"          # 符号链接会命名为 some-<skill>
```

然后运行 `./install.sh`。

## 只安装到单个目标目录

如果只用 Claude Code（或只用 Codex），把 `skills_dir` 改成单个路径即可：

```yaml
skills_dir: ~/.claude/skills
```

或者只保留数组里你需要的那一项。

---

## 跟踪的 Skill 来源

| 仓库 | 地址 | Skills 数量 |
|------|------|-------------|
| awesome-claude-skills | https://github.com/ComposioHQ/awesome-claude-skills | ~29 |
| baoyu-skills | https://github.com/JimLiu/baoyu-skills | 21 |
| agent-skills（`agent-` 前缀） | https://github.com/addyosmani/agent-skills | 21 |
| remotion-skills | https://github.com/remotion-dev/skills | 1 |
| anything-to-notebooklm | https://github.com/joeseesun/anything-to-notebooklm | 1 |
| **本仓库（local）** | — | 1 |

---

## 本仓库 Skills（local）

| Skill | 说明 |
|-------|------|
| [huiwang-writing-style](./huiwang-writing-style/) | 《回望灯火阑珊》写作风格指南，温情现实主义青春文学创作，适用于成长小说、考研/奋斗题材 |

---

## awesome-claude-skills

来源：[ComposioHQ/awesome-claude-skills](https://github.com/ComposioHQ/awesome-claude-skills)（社区精选 Claude Skills 合集）

| Skill | 说明 |
|-------|------|
| [artifacts-builder](https://github.com/ComposioHQ/awesome-claude-skills/tree/master/artifacts-builder) | 使用 React、Tailwind CSS、shadcn/ui 构建复杂的多组件 HTML Artifact |
| [brand-guidelines](https://github.com/ComposioHQ/awesome-claude-skills/tree/master/brand-guidelines) | 将 Anthropic 官方品牌配色和排版风格应用到 Artifact |
| [canvas-design](https://github.com/ComposioHQ/awesome-claude-skills/tree/master/canvas-design) | 基于设计哲学创作 PNG/PDF 视觉艺术作品（海报、设计图等） |
| [changelog-generator](https://github.com/ComposioHQ/awesome-claude-skills/tree/master/changelog-generator) | 从 Git 提交历史自动生成面向用户的更新日志 |
| [competitive-ads-extractor](https://github.com/ComposioHQ/awesome-claude-skills/tree/master/competitive-ads-extractor) | 从广告库（Facebook、LinkedIn 等）提取并分析竞品广告策略 |
| [connect](https://github.com/ComposioHQ/awesome-claude-skills/tree/master/connect) | 连接 Gmail、Slack、GitHub、Notion 等 1000+ 应用，执行实际操作 |
| [connect-apps](https://github.com/ComposioHQ/awesome-claude-skills/tree/master/connect-apps) | 连接外部应用（Gmail、Slack、GitHub），执行发邮件、建 Issue 等操作 |
| [content-research-writer](https://github.com/ComposioHQ/awesome-claude-skills/tree/master/content-research-writer) | 辅助高质量内容写作：调研、引用、优化开头、迭代大纲 |
| [developer-growth-analysis](https://github.com/ComposioHQ/awesome-claude-skills/tree/master/developer-growth-analysis) | 分析 Claude Code 聊天历史，识别编码模式和成长空间，推送学习报告 |
| [domain-name-brainstormer](https://github.com/ComposioHQ/awesome-claude-skills/tree/master/domain-name-brainstormer) | 生成创意域名并检查 .com/.io/.dev/.ai 等可用性 |
| [file-organizer](https://github.com/ComposioHQ/awesome-claude-skills/tree/master/file-organizer) | 智能整理文件和文件夹：理解上下文、查找重复、建议更优结构 |
| [image-enhancer](https://github.com/ComposioHQ/awesome-claude-skills/tree/master/image-enhancer) | 提升图片（尤其截图）的分辨率、清晰度和锐度 |
| [internal-comms](https://github.com/ComposioHQ/awesome-claude-skills/tree/master/internal-comms) | 撰写各类内部沟通文档（状态报告、通讯、FAQ、事故报告等） |
| [invoice-organizer](https://github.com/ComposioHQ/awesome-claude-skills/tree/master/invoice-organizer) | 自动整理发票和收据：提取信息、统一命名、分类归档 |
| [langsmith-fetch](https://github.com/ComposioHQ/awesome-claude-skills/tree/master/langsmith-fetch) | 从 LangSmith Studio 获取执行追踪，调试 LangChain/LangGraph Agent |
| [lead-research-assistant](https://github.com/ComposioHQ/awesome-claude-skills/tree/master/lead-research-assistant) | 搜索目标公司，提供高质量潜在客户线索和外联策略 |
| [mcp-builder](https://github.com/ComposioHQ/awesome-claude-skills/tree/master/mcp-builder) | 创建 MCP（模型上下文协议）服务器的指南，支持 Python 和 TypeScript |
| [meeting-insights-analyzer](https://github.com/ComposioHQ/awesome-claude-skills/tree/master/meeting-insights-analyzer) | 分析会议记录，发现沟通模式和行为洞察，提供改进建议 |
| [raffle-winner-picker](https://github.com/ComposioHQ/awesome-claude-skills/tree/master/raffle-winner-picker) | 从列表或 Google Sheets 中随机抽取获奖者，确保公平透明 |
| [skill-creator](https://github.com/ComposioHQ/awesome-claude-skills/tree/master/skill-creator) | 创建或更新 Claude Skill 的指南 |
| [skill-share](https://github.com/ComposioHQ/awesome-claude-skills/tree/master/skill-share) | 创建 Claude Skill 并通过 Slack 自动分享给团队 |
| [slack-gif-creator](https://github.com/ComposioHQ/awesome-claude-skills/tree/master/slack-gif-creator) | 创建适配 Slack 尺寸约束的动画 GIF |
| [tailored-resume-generator](https://github.com/ComposioHQ/awesome-claude-skills/tree/master/tailored-resume-generator) | 分析职位描述并生成定制简历，突出相关经验和技能 |
| [template-skill](https://github.com/ComposioHQ/awesome-claude-skills/tree/master/template-skill) | Skill 模板/占位符，用于创建新 Skill 的起点 |
| [theme-factory](https://github.com/ComposioHQ/awesome-claude-skills/tree/master/theme-factory) | 为 Artifact 应用主题样式的工具包，含 10 套预设主题 |
| [twitter-algorithm-optimizer](https://github.com/ComposioHQ/awesome-claude-skills/tree/master/twitter-algorithm-optimizer) | 基于 Twitter 开源算法分析并优化推文，提升曝光和互动 |
| [video-downloader](https://github.com/ComposioHQ/awesome-claude-skills/tree/master/video-downloader) | 下载 YouTube 视频，支持自定义画质、格式和纯音频 MP3 |
| [webapp-testing](https://github.com/ComposioHQ/awesome-claude-skills/tree/master/webapp-testing) | 使用 Playwright 测试本地 Web 应用的 UI 功能 |

---

## baoyu-skills

来源：[JimLiu/baoyu-skills](https://github.com/JimLiu/baoyu-skills)（暴雨系列 Skills 合集）

| Skill | 说明 |
|-------|------|
| [baoyu-article-illustrator](https://github.com/JimLiu/baoyu-skills/tree/main/skills/baoyu-article-illustrator) | 分析文章结构，定位需要配图的位置，以「类型 x 风格」二维方式生成插图 |
| [baoyu-comic](https://github.com/JimLiu/baoyu-skills/tree/main/skills/baoyu-comic) | 知识漫画创作器，支持多种画风和语调，生成原创教育漫画 |
| [baoyu-compress-image](https://github.com/JimLiu/baoyu-skills/tree/main/skills/baoyu-compress-image) | 将图片压缩为 WebP（默认）或 PNG 格式，自动选择最佳压缩工具 |
| [baoyu-cover-image](https://github.com/JimLiu/baoyu-skills/tree/main/skills/baoyu-cover-image) | 以五维参数（类型、色板、渲染、文字、氛围）生成文章封面图 |
| [baoyu-danger-gemini-web](https://github.com/JimLiu/baoyu-skills/tree/main/skills/baoyu-danger-gemini-web) | 通过逆向工程的 Gemini Web API 生成图片和文本，支持多轮对话 |
| [baoyu-danger-x-to-markdown](https://github.com/JimLiu/baoyu-skills/tree/main/skills/baoyu-danger-x-to-markdown) | 将 X（Twitter）推文和文章转换为带 YAML 前言的 Markdown |
| [baoyu-diagram](https://github.com/JimLiu/baoyu-skills/tree/main/skills/baoyu-diagram) | 生成各类专业深色主题 SVG 图表：架构图、流程图、时序图、思维导图、时间线等 |
| [baoyu-format-markdown](https://github.com/JimLiu/baoyu-skills/tree/main/skills/baoyu-format-markdown) | 格式化纯文本或 Markdown：添加前言、标题、摘要、加粗、列表等 |
| [baoyu-image-cards](https://github.com/JimLiu/baoyu-skills/tree/main/skills/baoyu-image-cards) | 生成小红书/微信图文配图卡片系列，12 种视觉风格 × 8 种布局 × 3 套配色 |
| [baoyu-image-gen](https://github.com/JimLiu/baoyu-skills/tree/main/skills/baoyu-image-gen) | 基于 OpenAI/Google/DashScope API 的 AI 图片生成，支持文生图和参考图 |
| [baoyu-imagine](https://github.com/JimLiu/baoyu-skills/tree/main/skills/baoyu-imagine) | 多家 API（OpenAI/Google/Replicate/Jimeng 等）图片生成，支持批量并行 |
| [baoyu-infographic](https://github.com/JimLiu/baoyu-skills/tree/main/skills/baoyu-infographic) | 生成专业信息图，20 种布局和 17 种视觉风格自由组合 |
| [baoyu-markdown-to-html](https://github.com/JimLiu/baoyu-skills/tree/main/skills/baoyu-markdown-to-html) | Markdown 转带样式 HTML，兼容微信公众号，支持代码高亮和数学公式 |
| [baoyu-post-to-wechat](https://github.com/JimLiu/baoyu-skills/tree/main/skills/baoyu-post-to-wechat) | 通过 API 或 Chrome CDP 发布内容到微信公众号，支持文章和图文消息 |
| [baoyu-post-to-weibo](https://github.com/JimLiu/baoyu-skills/tree/main/skills/baoyu-post-to-weibo) | 通过 Chrome CDP 发布微博普通动态和头条文章，支持图片/视频/Markdown |
| [baoyu-post-to-x](https://github.com/JimLiu/baoyu-skills/tree/main/skills/baoyu-post-to-x) | 通过真实 Chrome 浏览器发布推文、图片、视频和长文到 X（Twitter） |
| [baoyu-slide-deck](https://github.com/JimLiu/baoyu-skills/tree/main/skills/baoyu-slide-deck) | 从内容生成专业演示文稿幻灯片图片 |
| [baoyu-translate](https://github.com/JimLiu/baoyu-skills/tree/main/skills/baoyu-translate) | 三档翻译模式（快速/常规/精翻），支持术语表和本地化，中英互译 |
| [baoyu-url-to-markdown](https://github.com/JimLiu/baoyu-skills/tree/main/skills/baoyu-url-to-markdown) | 通过 Chrome CDP 抓取任意网页并转换为 Markdown |
| [baoyu-xhs-images](https://github.com/JimLiu/baoyu-skills/tree/main/skills/baoyu-xhs-images) | 生成小红书风格信息图系列，10 种视觉风格和 8 种布局 |
| [baoyu-youtube-transcript](https://github.com/JimLiu/baoyu-skills/tree/main/skills/baoyu-youtube-transcript) | 下载 YouTube 视频字幕/封面，支持多语言、翻译、分章节、说话人识别 |

---

## remotion-skills

来源：[remotion-dev/skills](https://github.com/remotion-dev/skills)（Remotion 官方 Skills）

| Skill | 说明 |
|-------|------|
| [remotion](https://github.com/remotion-dev/skills/tree/main/skills/remotion) | Remotion 视频创作框架最佳实践，使用 React 编程式生成视频，含 30+ 规则指南 |

---

## agent-skills（带 `agent-` 前缀）

来源：[addyosmani/agent-skills](https://github.com/addyosmani/agent-skills)（覆盖开发全生命周期的 21 个 skills，统一加 `agent-` 前缀便于辨识）

### 规划与设计
| Skill | 说明 |
|-------|------|
| [agent-idea-refine](https://github.com/addyosmani/agent-skills/tree/main/skills/idea-refine) | 通过结构化的发散-收敛思维迭代精炼想法 |
| [agent-spec-driven-development](https://github.com/addyosmani/agent-skills/tree/main/skills/spec-driven-development) | 编码前先写规格说明；适用于新项目/新特性或需求不清晰时 |
| [agent-planning-and-task-breakdown](https://github.com/addyosmani/agent-skills/tree/main/skills/planning-and-task-breakdown) | 将工作拆分为可实现的有序任务 |
| [agent-api-and-interface-design](https://github.com/addyosmani/agent-skills/tree/main/skills/api-and-interface-design) | 设计稳定的 API 与模块边界（REST、GraphQL、类型契约） |
| [agent-context-engineering](https://github.com/addyosmani/agent-skills/tree/main/skills/context-engineering) | 优化 Agent 上下文设置：开始新会话、配置规则文件、切换任务 |

### 开发与实现
| Skill | 说明 |
|-------|------|
| [agent-test-driven-development](https://github.com/addyosmani/agent-skills/tree/main/skills/test-driven-development) | 测试驱动开发：实现逻辑、修 bug、改行为前先写测试 |
| [agent-incremental-implementation](https://github.com/addyosmani/agent-skills/tree/main/skills/incremental-implementation) | 增量式交付改动，避免一次性写太多代码 |
| [agent-source-driven-development](https://github.com/addyosmani/agent-skills/tree/main/skills/source-driven-development) | 基于官方文档实现，避免过时模式，每个决策都有来源引用 |
| [agent-frontend-ui-engineering](https://github.com/addyosmani/agent-skills/tree/main/skills/frontend-ui-engineering) | 构建生产级 UI：组件、布局、状态管理、避免 AI 风格化输出 |
| [agent-code-simplification](https://github.com/addyosmani/agent-skills/tree/main/skills/code-simplification) | 在不改变行为的前提下重构代码，提升可读性和可维护性 |

### 测试与调试
| Skill | 说明 |
|-------|------|
| [agent-browser-testing-with-devtools](https://github.com/addyosmani/agent-skills/tree/main/skills/browser-testing-with-devtools) | 通过 Chrome DevTools MCP 在真实浏览器里做测试（DOM、控制台、网络、性能） |
| [agent-debugging-and-error-recovery](https://github.com/addyosmani/agent-skills/tree/main/skills/debugging-and-error-recovery) | 系统化的根因调试方法（测试失败、构建损坏、行为异常） |

### 审查与质量
| Skill | 说明 |
|-------|------|
| [agent-code-review-and-quality](https://github.com/addyosmani/agent-skills/tree/main/skills/code-review-and-quality) | 多维度代码审查，合并前的质量门禁 |
| [agent-security-and-hardening](https://github.com/addyosmani/agent-skills/tree/main/skills/security-and-hardening) | 针对输入处理、认证、存储和第三方集成的安全加固 |
| [agent-performance-optimization](https://github.com/addyosmani/agent-skills/tree/main/skills/performance-optimization) | 应用性能优化：定位瓶颈、改善 Core Web Vitals、降低加载时间 |

### 发布与运维
| Skill | 说明 |
|-------|------|
| [agent-ci-cd-and-automation](https://github.com/addyosmani/agent-skills/tree/main/skills/ci-cd-and-automation) | CI/CD 流水线搭建与自动化质量门禁 |
| [agent-git-workflow-and-versioning](https://github.com/addyosmani/agent-skills/tree/main/skills/git-workflow-and-versioning) | 规范 Git 工作流：提交、分支、冲突解决、多流并行 |
| [agent-shipping-and-launch](https://github.com/addyosmani/agent-skills/tree/main/skills/shipping-and-launch) | 生产发布准备：预发清单、监控、灰度、回滚策略 |
| [agent-deprecation-and-migration](https://github.com/addyosmani/agent-skills/tree/main/skills/deprecation-and-migration) | 系统/API/特性下线与用户迁移管理 |

### 文档与元
| Skill | 说明 |
|-------|------|
| [agent-documentation-and-adrs](https://github.com/addyosmani/agent-skills/tree/main/skills/documentation-and-adrs) | 架构决策记录（ADR）与文档沉淀 |
| [agent-using-agent-skills](https://github.com/addyosmani/agent-skills/tree/main/skills/using-agent-skills) | 元 skill：发现并调用其他 agent skills |

---

## anything-to-notebooklm

来源：[joeseesun/anything-to-notebooklm](https://github.com/joeseesun/anything-to-notebooklm)

| Skill | 说明 |
|-------|------|
| [anything-to-notebooklm](https://github.com/joeseesun/anything-to-notebooklm) | 多源内容智能处理器：支持微信公众号、网页、YouTube、PDF、Markdown 等，自动上传到 NotebookLM 并生成播客/PPT/思维导图等多种格式 |
