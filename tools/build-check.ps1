# ArkTS 真实编译校验(使用 DevEco 自带 hvigor 工具链)
#
# 为什么需要它: 项目里的 node 侧 harness(test/guncat-harness)只能验证纯逻辑模块,
# 覆盖不到 .ets 视图/页面/视图模型。ArkUI 有一批"只有编译器才知道"的规则, 例如:
#   - @Builder 方法体内不允许声明局部变量(只能写 UI 组件语法);
#   - 自定义组件的属性名不能与内置属性同名(如 size / scale);
#   - @Prop 类型必须可赋值(null 需要显式联合类型)。
# 这个脚本跑一次真实编译, 把这些错误在提交前拦下来。
#
# 用法(在仓库根目录):
#   powershell -ExecutionPolicy Bypass -File tools/build-check.ps1
#   (装了 PowerShell 7 也可以用: pwsh -File tools/build-check.ps1)
# 注意: 本脚本含中文注释, 必须以 UTF-8 with BOM 保存, 否则 Windows PowerShell 5.1
# 会按 ANSI 解析, 报出与真实原因无关的语法错(BadExpression)。
#
# 前置条件: 已安装 DevEco Studio(默认路径 C:\Program Files\Huawei\DevEco Studio)。
# 首次运行会在 ~/.hvigor/project_caches/<hash>/workspace 下准备 hvigor 依赖。
$ErrorActionPreference = 'Stop'

$deveco = 'C:\Program Files\Huawei\DevEco Studio'
if (-not (Test-Path $deveco)) {
  Write-Error "未找到 DevEco Studio: $deveco"
  exit 2
}

$env:DEVECO_SDK_HOME = Join-Path $deveco 'sdk'
# 必须用 DevEco 自带的 node(18): 系统里的新版 node 会让 hvigor 的
# rmdirSync(recursive) 调用报错(ERR_INVALID_ARG_VALUE)。
$node = Join-Path $deveco 'tools\node\node.exe'

$wrapper = Join-Path $deveco 'tools\hvigor\bin\hvigorw.js'
# 先让 wrapper 准备好 workspace(它首次会报缺 node_modules, 这是预期的)
& $node $wrapper --version 2>&1 | Out-Null

$cacheRoot = Join-Path $env:USERPROFILE '.hvigor\project_caches'
$workspace = $null
if (Test-Path $cacheRoot) {
  foreach ($dir in Get-ChildItem $cacheRoot -Directory) {
    $candidate = Join-Path $dir.FullName 'workspace'
    if (Test-Path $candidate) { $workspace = $candidate; break }
  }
}
if (-not $workspace) {
  Write-Error "未能定位 hvigor workspace(请先在 DevEco Studio 里打开过一次本项目)"
  exit 2
}

# 把 DevEco 内置的 hvigor 包补齐到 workspace(离线可用, 无需 npm 网络)
$bundled = Join-Path $deveco 'tools\hvigor'
$ohosDir = Join-Path $workspace 'node_modules\@ohos'
New-Item -ItemType Directory -Force -Path $ohosDir | Out-Null
foreach ($pkg in @('hvigor', 'hvigor-ohos-plugin')) {
  $dst = Join-Path $ohosDir $pkg
  if (-not (Test-Path (Join-Path $dst 'package.json'))) {
    robocopy (Join-Path $bundled $pkg) $dst /E /NFL /NDL /NJH /NJS /NP | Out-Null
  }
  $depDir = Join-Path (Join-Path $bundled $pkg) 'node_modules\@ohos'
  if (Test-Path $depDir) {
    foreach ($dep in Get-ChildItem $depDir -Directory) {
      $depDst = Join-Path $ohosDir $dep.Name
      if (-not (Test-Path $depDst)) {
        robocopy $dep.FullName $depDst /E /NFL /NDL /NJH /NJS /NP | Out-Null
      }
    }
  }
}

# 直接调用 workspace 里的 hvigor: 外层 wrapper 会因 workspace 校验路径不一致而误报 ENOENT
$hvigor = Join-Path $ohosDir 'hvigor\bin\hvigor.js'
& $node $hvigor --mode module -p module=entry@default -p product=default assembleHap --no-daemon
exit $LASTEXITCODE
