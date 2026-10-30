# 构建与发布

## 自动发布技能

项目技能位于 [releasing-winkey](../.agents/skills/releasing-winkey/SKILL.md)。在本项目中说“发布一个版本”“发布当前修复”或“打 tag 发布”，即可让代理按实际改动选择版本，更新版本文件，完成验证、提交、标签推送并跟进 GitHub Release。也可显式调用 `$releasing-winkey`，或指定“发布 0.4.0”。

版本递增、构建号、标签命名、发布范围和失败恢复规则统一维护在技能内。技能中的只读助手负责计算版本；真正发布需要执行完整技能流程。普通代码推送不会自动选择版本或创建标签。

## 已有标签

截至 **2026-10-30** 核对，本地和 GitHub 上均有下列正式标签：

| 标签 | 提交 | 应用版本 | 构建号 | GitHub Release |
| --- | --- | --- | --- | --- |
| `v0.3.0` | `377fecaa3dc2dee4f071a98420ba40ef5bfd9a74` | `0.3.0` | `5` | 已发布 |
| `v0.4.0` | `8174a3e33c7a8fe8767e9ab879664f9b4afe99df` | `0.4.0` | `6` | 已发布 |
| `v0.4.1` | `685135cf4de7e3258a8ab336e18663244553f958` | `0.4.1` | `7` | 已发布 |
| `v0.4.2` | `eabde05fabba0fee2ee1cca0f3a9784d0806b8d7` | `0.4.2` | `8` | 已发布 |

该表是核对快照，实际发布时必须重新读取远端状态：

```sh
git fetch origin --tags
git ls-remote --tags origin
git tag --list --sort=version:refname
```

`v0.4.0` 包含 Caps Lock 独立开关、保留原生 Command+Tab 应用切换，以及打开授权设置时不再额外弹出辅助功能访问提示的修复。两个架构的构建与发布均已通过，四个附件已上传。

`v0.4.1` 修复 Caps Lock 显示大写但仍输出小写的问题。`v0.4.2` 移除安全输入状态下应用主动暂停映射的规则，避免该规则使 Ctrl 粘贴短暂失效；系统自身的事件限制仍可能影响映射。`v0.4.2` 的主分支和标签构建均已通过，Apple Silicon、Intel 两个 ZIP 及各自 SHA-256 文件共四个附件已公开发布。

在此基线上，单纯修复的下一版为 `v0.4.3`，新增功能的下一版为 `v0.5.0`；构建号至少为 `9`。这两个版本尚未创建，不应复用现有标签。

## 本地构建

需要 macOS 13+ 和 Xcode Command Line Tools。应用版本由根目录的 `Info.plist` 中 `CFBundleShortVersionString` 决定。

```sh
# 只运行快捷键和状态机测试
bash scripts/test.sh

# 测试、编译、生成图标、临时签名并验证
bash scripts/build.sh

# 生成当前 Mac 架构的 ZIP 和 SHA-256 校验文件
bash scripts/package.sh

# 发布前同时校验标签与应用版本一致
bash scripts/package.sh v0.4.0
```

可安装应用默认输出到 `release/WinKeyForMac.app`；发布包命名为 `release/WinKeyForMac-<版本>-macOS-<架构>.zip`，并附带同名 `.zip.sha256` 文件。`arm64` 对应 Apple Silicon，`x86_64` 对应 Intel。压缩包保留应用目录结构、文件元数据和可执行权限。

过程文件放在 `.work/`，构建产物放在 `release/`，两者均被 Git 忽略。全新检出可直接构建，不依赖历史产物。测试覆盖快捷键规则和状态机；真实键盘、辅助功能授权、不同应用和睡眠唤醒仍需实机验证。

## GitHub Actions 发布

[Build and Release](../.github/workflows/release.yml) 在推送 `main` 或提交 Pull Request 时分别构建 Apple Silicon 和 Intel 应用，运行测试、验证签名并打包。结果保留在 Actions Artifacts 中 14 天。

| 触发方式 | 构建与测试 | 发布 GitHub Release |
| --- | --- | --- |
| 推送 `main` | 是 | 否 |
| 向 `main` 提交 Pull Request | 是 | 否 |
| 推送符合版本规则的 `v*` 标签 | 是 | 两种架构都成功后发布 |
| 手动运行并指定已存在的标签 | 是，构建该标签对应的源码 | 上传或补全该版本 |

手动执行时也遵循技能中的规则。例如，下一次修复版选定 `0.4.3` 后：

1. 更新 `Info.plist` 的 `CFBundleShortVersionString` 为 `0.4.3`，`CFBundleVersion` 至少为 `9`，同步界面版本，验证并提交本次发布所需的全部源码、测试和配置。
2. 记录该次提交的准确 SHA，推送到 `main`，等待该 SHA 对应的主分支构建通过，再创建带说明的标签。以下变量必须填入实际已经验证的提交：

   ```sh
   release_commit="实际已验证的提交 SHA"
   git push origin "${release_commit}:refs/heads/main"
   # 等待上述提交的主分支 CI 成功后继续。
   git tag -a v0.4.3 "$release_commit" -m "WinKeyForMac v0.4.3"
   git push origin refs/tags/v0.4.3
   ```

3. GitHub Actions 检出标签对应源码，在两种架构的 macOS runner 上构建。标签必须严格等于 `v` 加应用版本，不一致时终止发布。
4. 两个构建全部成功后，流程验证压缩包校验值，创建 Release 草稿，上传两个 ZIP 和各自的 SHA-256 文件，再公开发布。源码压缩包由 GitHub 自动提供。

无需额外配置 Secret，流程使用 GitHub 提供的 `GITHUB_TOKEN`，仅发布任务具有 `contents: write` 权限。当前构建采用临时签名，尚未进行 Developer ID 签名和公证，Release 说明会提示安装限制。发布者仍应在目标系统上验证下载、解压、启动和授权。

发布失败时，可在 Actions 中重跑失败任务。也可在默认分支的 **Actions → Build and Release → Run workflow** 中填写已存在的标签，重新构建该标签对应的源码并上传附件。重复发布会替换同名附件，保留现有 Release 的标题与说明；未完成上传的草稿会在重跑成功后发布。

下载 ZIP 和对应的校验文件后，在下载目录执行：

```sh
shasum -a 256 -c WinKeyForMac-0.4.0-macOS-arm64.zip.sha256
```
