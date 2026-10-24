---
name: releasing-winkey
description: 为 WinKeyForMac 执行版本发布，按改动自动选择版本、同步应用版本、验证构建、提交、创建并推送 Git 标签，跟进 GitHub Release。用于本项目中的“发布版本”“发一版”“打 tag 发布”“发布修复版”“发布指定版本”或“重跑发布”；仅询问版本或标签时只核对和解释。
---

# 发布 WinKeyForMac

在仓库根目录执行。读取根目录 `Info.plist`、`scripts/package.sh` 和 `.github/workflows/release.yml`，以当前文件和远端事实为准。

用户要求发布时，自动完成版本选择、必要文件修改、验证、提交、创建标签、推送和 Release 验证，不重复询问版本号或常规发布许可。只询问影响发布范围且无法从上下文判断的问题。创建、修改本技能或询问发布规则不构成执行新发布的请求；用户只要求方案或试算时保持只读。

## 版本与标签规则

- 正式标签只能使用 `vMAJOR.MINOR.PATCH`，三个分量均为无前导零的非负整数，例如 `v0.3.1`。应用的 `CFBundleShortVersionString` 不含 `v`，必须与标签一致。现有流程不支持 `-beta`、`-rc` 等预发布后缀；需要时先实现相应支持。
- 每次先读取远端标签和本地标签，按数值语义版本排序，禁止按创建日期或字符串排序。远端为已发布事实来源；本地独有标签是待核对状态，不能视为已发布。
- 使用最新正式标签作为改动基线，结合该标签之后的提交、实际 diff 及本次包含的未提交改动选择版本。不能只看提交标题。

| 本次改动 | 自动选择 |
| --- | --- |
| 修复、兼容性修正、性能改善，或影响交付包的构建修复 | PATCH + 1 |
| 新功能、新设置、新的用户可见能力 | MINOR + 1，PATCH 归零 |
| 1.0.0 及以后引入不兼容行为 | MAJOR + 1，其余归零 |
| 0.x 阶段引入不兼容行为 | MINOR + 1，PATCH 归零；升到 1.0.0 需用户明确要求稳定版或该版本 |
| 同时包含多类改动 | 取最高级别 |

- `feat` 通常对应 minor，`fix`/`perf` 通常对应 patch，`!`/`BREAKING CHANGE` 是不兼容提示，最终仍检查实际行为。仅文档或与交付无关的维护改动默认不新发应用版本；用户明确要求这些改动也发版时选择 patch。
- 用户指定的版本优先，但必须合法、未被任何现有标签占用，且大于最新正式版本。若 `Info.plist` 已预设更高且尚未发布的有效版本，保留它；不要再次盲目递增。低于最新标签的工作版本说明可能在旧分支，先解决分支状态。
- `CFBundleVersion` 使用递增正整数：新发布至少比所有已有正式标签中的构建号大 1；已预设更高构建号则保留。首次发布沿用当前有效版本和构建号。
- 创建带说明的 annotated tag，说明为 `WinKeyForMac vX.Y.Z`，固定到本次已验证的提交 SHA。历史 `v0.3.0` 是轻量标签，可直接使用，不改写它。
- 已发布版本和已推送标签不可移动、复用或强推。代码变更必须新版本；原标签同一提交的构建/上传失败可以重跑。

## 1. 核对仓库与发布范围

1. 检查 `git status --short`、当前分支、`origin` 地址及远端 `main`。确认正在处理 WinKeyForMac 对应仓库。
2. 执行 `git fetch origin --tags` 和 `git ls-remote --tags origin`，保留远端标签、解引用 SHA 和本地差异。若已有同名标签但 SHA 不同，先报告冲突，不强制覆盖。读取实际 GitHub Releases，区分“只有标签”“发布失败”“已发布”。
3. 在 `main` 上发布已包含最新 `origin/main` 的提交。分支落后、分叉、标签基线不在当前历史中，或有并行修改时，先检查并安全整合；不自动 reset、丢弃改动或重写历史。
4. 检查基线到当前提交的 diff、已暂存与未暂存修改和未跟踪文件。用户要求发布当前改动时，将相关源码、测试和必要配置纳入同一版本；排除无关工作。若待发布范围确实无法判断，只询问具体文件范围，不泛泛要求再次确认发布。
5. 当前标签是动态事实。初始化本技能时核对到唯一远端标签 `v0.3.0`，指向 `377fecaa3dc2dee4f071a98420ba40ef5bfd9a74`，应用版本 `0.3.0`、构建号 `5`；这只是 2026-10-25 的快照，每次使用必须重新查询。

若用户要求重跑或继续已有版本，先按第 4 节核对该标签的提交和 Release 状态；成功的版本直接报告已有结果，失败的同一提交进入恢复流程，不调用新版本规划。发布成功后，更新 `docs/RELEASING.md` 的标签快照和核对日期；如需提交这次记录，作为后续文档提交，不移动已发布标签。

## 2. 生成发布计划并同步版本

按上表自行判断 bump，调用随技能附带的只读助手（只使用 Python 3 标准库）：

```sh
python3 .agents/skills/releasing-winkey/scripts/release_plan.py --bump minor
# 用户明确指定版本时：
python3 .agents/skills/releasing-winkey/scripts/release_plan.py --version 0.4.0
```

助手读取本地已获取的标签，输出完整标签清单、最新正式标签、当前版本、新版本、新构建号和目标标签。它不访问网络，也不修改文件或推送，必须先完成上一节的远端核对。最终 bump 的语义判断由执行技能的代理负责。

简要告知选定版本和理由，随后继续执行，不将该说明变成常规审批。同步：

- `Info.plist` 中 `CFBundleShortVersionString` 与 `CFBundleVersion`。
- 用户界面中的版本文字；当前 `Sources/WinKeyForMac.swift` 有 `试用版 0.3.0` 一类硬编码，检查实际文件后替换为本次版本，或改为读取应用 Bundle 版本。
- 必要的现有版本说明。README 保持面向使用者，不加入下载入口、下载说明、发布包清单或流水线细节；维护者流程放在 `docs/RELEASING.md`。

## 3. 验证、提交并推送准确的版本

1. 在 macOS 上执行 `bash scripts/package.sh "$tag"`；它包含测试、构建、图标生成、临时签名验证和当前架构打包。检查 ZIP 可解压、应用可执行位、解压后 `codesign --verify --deep --strict` 和 SHA-256。过程材料放在 Git 忽略的 `.work/`，产物放在 `release/`。缺少 macOS 时让主分支 CI 完成真实构建，并明确本地验证限制。
2. 检查 `git diff --check`，按明确文件路径暂存本次发布内容。检查整个 staged diff，确保没有误带其他工作，也没有漏掉必要源码、测试或配置。提交信息使用 Conventional Commits，例如 `chore(release): prepare v0.4.0`。
3. 记录提交 SHA 为 `release_commit`，以此固定本次发布。再次检查该提交内的应用版本、构建号及界面版本，且没有遗漏本次相关修改。后续发现同一文件被其他任务继续修改时，不静默吸收进已验证版本。
4. 推送准确提交到 `main`；出现远端快进冲突就重新核对并整合、重新验证，不强推。等待并核对该 SHA 的主分支 Build and Release 成功后，再创建正式标签。示例变量必须来自本次真实计划：

   ```sh
   git push origin "${release_commit}:refs/heads/main"
   # 确认上述 SHA 的主分支 CI 成功后继续。
   git tag -a "$tag" "$release_commit" -m "WinKeyForMac $tag"
   git push origin "refs/tags/$tag"
   ```

5. 若同名本地标签已存在，仅当其提交恰为 `release_commit` 且是本次未完成发布时才复用；禁止覆盖。若远端已存在同一标签和提交，进入恢复流程，避免重复创建新版本。推送前重新检查远端目标标签，消除检查之后的竞争；推送被拒绝时检查事实，不重试强推。

## 4. 跟进 GitHub Release

推送 `main` 只触发构建测试；推送 `v*` 标签才触发正式 Release。绑定本次标签与 SHA，等待 `.github/workflows/release.yml` 的两个架构构建和 Publish GitHub Release 都完成。使用可用的 GitHub 连接器、`gh`、官方 API 或已登录网页查看；`gh` 缺失时不因此放弃验证。等待期间保持必要的进度说明，避免频繁轮询。

核对远端标签 SHA、Release 非草稿状态，以及四个附件：`WinKeyForMac-X.Y.Z-macOS-arm64.zip`、`WinKeyForMac-X.Y.Z-macOS-x86_64.zip` 和各自 `.zip.sha256`。只在这些事实成立后报告“已发布”。报告最终版本、选择原因、提交、验证结果及 Release 位置；未完成时准确报告失败阶段。

失败恢复：先查失败原因，修复影响代码或交付内容的问题后选择新版本；若只是临时 runner、网络或同一提交上传失败，在原标签重跑失败任务，或手动运行工作流并填写原标签。现有工作流会补全草稿、替换同名附件且保留现有标题与说明。确认附件是否已经正确发布，避免无意义重跑；相同原因重试一次仍失败时停止盲目重试并说明阻塞原因。重跑已有发布时保持原源码、版本、构建号与标签。

维护版本助手时，在仓库根目录运行 `python3 .agents/skills/releasing-winkey/scripts/test_release_plan.py`。测试使用 `.work/` 下的临时 Git 仓库，覆盖版本选择和标签冲突，不连接或推送真实远端。
