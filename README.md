# 环境管理 · Environment Manager

Windows 环境的图形化管理工具：**Scoop 软件包管理 + PATH 环境变量体检**。
纯 PowerShell + WPF 实现，无需安装任何运行时或第三方依赖。

![概览](docs/screenshots/page-NavOverview.png)

## 为什么需要它

用 Scoop 管软件很方便，但它只有命令行。而 Windows 上真正麻烦的是：

- PATH 里堆了几十条路径，其中混着失效、重复、甚至别的用户留下的条目
- 想看看装了哪些软件、哪些有新版本，得记一堆 `scoop` 子命令
- 环境变量指向了不存在的目录，却没人提醒

这个工具把这些问题做成一块面板。

## 功能

| 页面 | 能做什么 |
|---|---|
| **概览** | 健康度评分、PATH/Scoop 统计、系统信息 |
| **已装软件** | 搜索安装、卸载、查看详情（`scoop info` 原文） |
| **检查更新** | 列出可更新包、单个更新、全部更新 |
| **Buckets** | 添加/移除软件源、查看各源包数量 |
| **运行时** | Node/Python/Java/Maven/Git 等版本、关键环境变量校验 |
| **PATH 变量** | 全量列表（失效/重复置顶标红）、导出、一键清理、打开系统面板 |

### 搜索匹配行为

`scoop search` 会同时匹配**包名**和**可执行文件名**。例如搜 `python` 会带出：

- `pulumi`（含 `pulumi-language-python.exe`）
- `fontforge`（含 `ffpython.exe`）

本工具**默认只按包名匹配**，过滤掉这类噪音；需要找「哪个包装了某个 exe」时，勾选「同时匹配可执行文件名」即可恢复完整结果。

## 快速开始

```powershell
# 方式一：双击启动（无控制台窗口）
启动.bat

# 方式二：直接运行
powershell -ExecutionPolicy Bypass -File src\envman.ps1

# 指定起始页
powershell -ExecutionPolicy Bypass -File src\envman.ps1 -Page NavApps

# Scoop 装在非默认位置时
powershell -ExecutionPolicy Bypass -File src\envman.ps1 -ScoopRoot "E:\Scoop"
```

## 环境要求

| 项目 | 要求 |
|---|---|
| 系统 | Windows 10 / 11 |
| PowerShell | 5.1（系统自带） |
| .NET Framework | 4.x（系统自带，WPF 依赖） |
| Scoop | 可选。没有也能用 PATH 相关功能，软件管理模块会自动隐藏 |

## 项目结构

```
environmentTool/
├── src/
│   └── envman.ps1           主程序（单文件，约 2400 行）
├── assets/
│   └── icon.ico             窗口/快捷方式图标
├── docs/
│   └── screenshots/         各页面截图
├── tools/
│   └── capture-pages.ps1    批量截图的调试脚本
├── launch.vbs               无窗口启动器
├── 启动.bat                 双击入口
└── README.md
```

## 设计说明

### 配色

固定浅色樱粉主题，不做运行时切换：

| 角色 | 色值 |
|---|---|
| 窗口底 | `#FDF2F5` |
| 卡片 | `#FFFFFF` |
| 主强调 | `#F76C9B` |
| 主文字 | `#2B2026` |
| 次文字 | `#6B5560` |
| 成功 / 警告 / 危险 | `#1E9E62` / `#B7791F` / `#D94565` |

浅色底上的半透明叠层用黑色（`#08B00000`），深色底才用白色。

### 为什么用单文件

它同时承担 UI、数据采集和业务逻辑。拆成模块需要处理 PowerShell 的脚本作用域和加载顺序，在小体量项目里反而增加复杂度。约 2400 行仍在单人可维护范围内。

### 异步与响应性

所有外部命令调用（`scoop list`、`mvn --version` 等）都在**后台 PowerShell 实例**里执行，通过 `DispatcherTimer` 轮询结果。UI 线程不做任何阻塞调用——早期版本曾因此冻结 2~3 秒。

## 已知限制

- **仅 Windows**：依赖 WPF 与 DWM
- **PowerShell 5.1**：未在 PowerShell 7 上验证（部分 API 行为可能有差异）
- **Scoop 输出解析**：通过解析 `scoop.cmd` 的表格文本实现，若 Scoop 改变输出格式需同步调整
- **中文路径**：图标等文件路径含中文，某些编码环境下可能加载失败（已有回退）

## 开发备注

### 三个容易踩的坑

这些是在本项目里真实踩过并修复的，供后续维护参考：

1. **`.ps1` 必须有 UTF-8 BOM**
   PowerShell 5.1 在无 BOM 时按系统 ANSI 代码页（简体中文为 GBK）解码，中文变乱码后引发大量语法错误。

2. **事件处理器里的循环变量是延迟求值**
   ```powershell
   foreach ($k in $keys) { $el[$k].Add_Checked({ Show-Page $k }) }  # 全部跳到最后一个
   ```
   正确做法是把值存到控件属性上，处理器从 `$s` 读回来。

3. **`DispatcherTimer` 不能存在局部变量里**
   函数返回后失去引用会被 GC 回收，Tick 永不触发。必须挂到 `$script:` 作用域。

### 调试用截图模式

```powershell
src\envman.ps1 -Shot out.png -Page NavApps
```

启动后等 1.5 秒渲染 PNG 再退出。**注意**：该模式走同步数据路径，不能用来验证异步逻辑（曾因此漏掉定时器被回收的 bug）。验证真实行为请用 `-Page` 参数启动正常窗口。
