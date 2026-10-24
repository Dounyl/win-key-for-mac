# 构建与发布

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
bash scripts/package.sh v0.3.0
```

可安装应用默认输出到 `release/WinKeyForMac.app`；发布包命名为 `release/WinKeyForMac-<版本>-macOS-<架构>.zip`，并附带同名 `.zip.sha256` 文件。`arm64` 对应 Apple Silicon，`x86_64` 对应 Intel。压缩包保留应用目录结构、文件元数据和可执行权限。

过程文件放在 `.work/`，构建产物放在 `release/`，两者均被 Git 忽略。全新检出可直接构建，不依赖历史产物。测试覆盖快捷键规则和状态机；真实键盘、辅助功能授权、不同应用和睡眠唤醒仍需实机验证。

## GitHub Actions 发布

[Build and Release](../.github/workflows/release.yml) 在推送 `main` 或提交 Pull Request 时分别构建 Apple Silicon 和 Intel 应用，运行测试、验证签名并打包。结果保留在 Actions Artifacts 中 14 天。

正式发布步骤：

1. 更新 `Info.plist` 的 `CFBundleShortVersionString`（例如 `0.3.0`）及 `CFBundleVersion`，提交并推送版本对应的所有源码。
2. 给该提交创建对应标签并推送：

   ```sh
   git tag v0.3.0
   git push origin v0.3.0
   ```

3. GitHub Actions 检出标签对应源码，在两种架构的 macOS runner 上构建。标签必须严格等于 `v` 加应用版本，不一致时终止发布。
4. 两个构建全部成功后，流程验证压缩包校验值，创建 Release 草稿，上传两个 ZIP 和各自的 SHA-256 文件，再公开发布。源码压缩包由 GitHub 自动提供。

无需额外配置 Secret，流程使用 GitHub 提供的 `GITHUB_TOKEN`，仅发布任务具有 `contents: write` 权限。当前构建采用临时签名，尚未进行 Developer ID 签名和公证，Release 说明会提示安装限制。发布者仍应在目标系统上验证下载、解压、启动和授权。

发布失败时，可在 Actions 中重跑失败任务。也可在默认分支的 **Actions → Build and Release → Run workflow** 中填写已存在的标签，重新构建该标签对应的源码并上传附件。重复发布会替换同名附件，保留现有 Release 的标题与说明；未完成上传的草稿会在重跑成功后发布。

下载 ZIP 和对应的校验文件后，在下载目录执行：

```sh
shasum -a 256 -c WinKeyForMac-0.3.0-macOS-arm64.zip.sha256
```
