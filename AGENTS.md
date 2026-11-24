# AGENTS.md — paste-clip

极简开源 macOS 剪贴板历史 app（作者自用），产品功能和快捷键见 `README.md`。

## 范围与硬约束

- 最低 macOS 26，不写旧系统兼容和 `#available` 回退。
- 性能优先常驻低内存；其他指标不单独优化但不能退化。
- UI 全部用 AppKit（Liquid Glass `NSGlassEffectView`），不引入 SwiftUI。
- 存储用系统 SQLite C API；引入任何第三方依赖前先说明原因并征得同意。
- **不做**：富文本、图片文件、来源 app 图标、收藏/置顶、忽略 app 列表、同步。新增功能先确认。

## 架构与代码红线

- 历史不设上限：禁止全量读入内存（列表分页、SQLite 搜索、原图按 hash 落盘并在无引用时删除、缩略图按显示尺寸落盘缓存）。
- 剪贴板隐私：跳过 `org.nspasteboard.ConcealedType` / `org.nspasteboard.TransientType`；权限缺失时明确提示，不静默失败；日志严禁输出剪贴板内容。
- 并发与安全：包已默认启用 Swift 6 与 `MainActor` 隔离；不用 `@unchecked Sendable`；除非证明不会失败并注释原因，不用强制解包和 `try!`。
- URL 识别、SQLite 语句、PNG 规范化等纯逻辑与 AppKit 解耦。

## 验证与验收

- 构建打包：`scripts/bundle.sh [release|debug]` → `build/PasteClip.app`（自动用本机 Apple Development 证书签名以保持辅助功能授权）。
- 当前无测试 target，优先用 `swift build` 或独立 CLI harness 验证。
- 启动 app 用 `open -g` 后台启动，不抢前台焦点；需前台交互的功能（全局快捷键、模拟 ⌘V 粘贴）列出步骤交由用户验收。

## Git 与 Skills

- 默认直接在本地 `main` 开发；仅在并行冲突、高风险实验或需保持 `main` 可构建时新建分支/worktree（先告知用户，合并后删除）。
- 验证通过后按文件名暂存并提交，不用 `git add -A`。提交信息用英文 Conventional Commits：`<type>(<scope>): <subject>`（scope 用模块名如 `store`/`panel`/`pasteboard`/`thumbnail`，subject 小写祈使句 ≤72 字符）。
- `.agents/skills/` 提供 `swift-concurrency`（并发问题）和 `swift-practical-patterns`（AppKit/构建等实现决策）。
