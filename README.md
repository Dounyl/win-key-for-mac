# WinKeyForMac

把熟悉的 Windows 快捷键带到 Mac。中文菜单栏应用，按组合键精确替换，无需交换整颗 Control 和 Command。

**替换模式**：启用后，`Ctrl+C` 复制，`Ctrl+V` 粘贴，`Ctrl+W` 关闭，`Ctrl+F` 查找；对应的 `Command+C / V / W / F` 被禁用。关闭对应规则、暂停应用或进入例外应用，即恢复原有快捷键。未列出的组合（如 `Command+Q`）保持原样。

当前版本：**0.2.0**。Swift 原生实现，单进程运行，无驱动或独立辅助服务，无网络请求，不读取剪贴板，不保存输入内容。

## 使用

1. 将编译后的 `WinKeyForMac.app` 放到固定位置并打开。
2. 若曾交换 Control / Command，在「系统设置 → 键盘 → 键盘快捷键 → 修饰键」中恢复默认。内置和外接键盘需分别检查，然后勾选应用中的确认项。
3. 点击「打开授权设置」，在「隐私与安全性 → 辅助功能」中允许 WinKeyForMac，再返回应用启用快捷键。
4. 关闭设置窗口后，应用继续运行，右上角保留 **键盘图标＋WK**。点击它可打开设置、暂停或退出。设置窗口打开时显示 Dock 图标。

如果监听启动失败，可从帮助菜单打开「输入监控」检查权限，再点击「重新检查并启用」。登录启动可在设置中开启；启用前请先确定应用位置。

## 支持的组合

| Windows 手势 | 转换后的 Mac 操作 |
| --- | --- |
| Ctrl+C / V / X / A | 复制 / 粘贴 / 剪切 / 全选 |
| Ctrl+Z / Ctrl+Y / Ctrl+Shift+Z | 撤销 / 重做 / 重做 |
| Ctrl+W / Ctrl+Shift+W | Command+W / Command+Shift+W |
| Ctrl+F / Ctrl+Shift+F | Command+F / Command+Shift+F |
| Ctrl+S / Ctrl+Shift+S | Command+S / Command+Shift+S |
| Ctrl+N / Ctrl+Shift+N / Ctrl+O / Ctrl+P | Command+N / Command+Shift+N / Command+O / Command+P |
| Ctrl+T / Ctrl+Shift+T | 新标签页 / 恢复关闭的标签页（取决于应用） |
| Ctrl+L / Ctrl+R / Ctrl+Shift+R | Command+L / Command+R / Command+Shift+R |
| Ctrl+1…9 / Ctrl+0 / Ctrl+= / Ctrl+Shift+= / Ctrl+减号 | 对应的 Command 组合，常用于标签切换与缩放 |
| Alt（Option）+Tab / Alt+Shift+Tab | macOS 应用切换器；按住 Alt 连续切换，松开确认 |
| Ctrl+空格（默认关闭） | 在系统启用的输入法间切换 |
| Ctrl+左右箭头 / Backspace / Delete（默认关闭） | Option 组合：按词移动或删除；支持 Shift 选择 |
| Ctrl+Home / End（默认关闭） | Command+上 / 下：文首或文尾；支持 Shift 选择 |

每组可单独开关。启用某组时，只禁用它对应的 **Command** 组合，包括切换应用组的 Command+Tab / Command+Shift+Tab，以及导航组的 Command+上 / 下。Option 按词导航仍可使用。额外修饰键和未知组合保持原样。切换输入法不会禁用其他系统输入法快捷键。

映射在所有非例外应用中生效，功能由目标应用的 Mac 快捷键决定。例如 Command+Shift+S 在部分应用中是「复制文档」。Alt+Tab 切换的是应用，不是 Windows 风格的每个独立窗口。菜单显示的快捷键仍由原应用提供，不会被本工具改写。

## 应用例外与恢复

终端、iTerm2、Warp、Windows App / Microsoft 远程桌面、Parallels、VMware、AnyDesk、TeamViewer 默认暂停全部映射及 Command 拦截。可在设置中移除例外，或通过菜单栏暂停最近使用的应用。

VS Code 集成终端与编辑器属于同一应用，目前无法按内部焦点区分。需要在集成终端使用 Ctrl+C 中断进程时，可暂停 VS Code 的映射。

监听在应用内独立线程运行，超时会尝试恢复；一分钟内多次失效会停止并提示检查。安全输入期间暂停转换。暂停会完成已按下按键的松键配对，然后保留系统原始行为。退出后停止监听。应用不修改系统修饰键设置，不创建自定义 LaunchAgent。

## 构建与测试

需要 macOS 13+、Xcode Command Line Tools 和 Swift 编译器。输出为当前 Mac 的 CPU 架构；当前开发验证环境为 Apple Silicon / macOS 26，其他系统和硬件尚需实机验证。

```sh
# 只运行快捷键与状态机测试
bash scripts/test.sh

# 运行测试、编译、生成图标、临时签名及验证
bash scripts/build.sh

# 或指定输出位置
bash scripts/build.sh /absolute/path/WinKeyForMac.app
```

编译明确以 macOS 13 为最低部署版本。过程文件位于被 Git 忽略的 `.work/`，应用包与压缩包也被忽略。源码、图标生成脚本及测试均纳入版本管理，可从全新检出重新构建。

测试覆盖 Windows 组合转换、对应 Command 组合拦截、长按及松键配对、暂停与前台变化、各组开关、Alt+Tab 修饰键释放、输入法切换去重和导航。真实键盘、权限、不同应用及睡眠唤醒需要实机验证。

当前构建使用本机临时签名，尚未进行 Developer ID 签名和公证。重新编译或移动应用后，macOS 可能要求重新授权辅助功能。正式分发仍需稳定签名和更多兼容性验证。

## English

WinKeyForMac is a native macOS menu bar app for Windows-style shortcuts. It replaces selected shortcuts rather than adding aliases: Ctrl+C copies while the corresponding Command+C is blocked. Pause, per-group toggles and app exclusions restore native behavior. It runs locally in one process, with no driver, helper service, clipboard access or keystroke recording. Build with `bash scripts/build.sh` on macOS 13 or later.
