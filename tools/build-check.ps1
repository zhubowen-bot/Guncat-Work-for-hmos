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

# ===== 快速门槛(每次都跑, 合起来几秒钟) =====
# 只做静态检查: 文档坏链 / 随包 .so 依赖闭合 / 许可覆盖。
# 这三项不需要设备、不需要 qemu, 却能拦住真机上最致命的两类问题(soname 缺失、缺 DT_NEEDED)。
#
# 慢的"23 项运行库自检"要 qemu 跑一遍完整 Python 栈(约 10 分钟), 只在需要时手动跑:
#     bash tooling/python/run-verify-stack.sh          (或本脚本加 -Full)
# 约定: **不要在每次打包时无脑跑它** —— 改个标题也等 10 分钟是不可接受的。
$full = ($args -contains '-Full') -or ($args -contains '-WithPythonStack')
# 不要用 Test-Path '\\wsl$\...' 探测: 访问 root 家目录会 Access denied 并中断脚本。
# 直接让 WSL 自己 test -d, 看退出码。
$hasRootfs = $false
try {
  & wsl -d Ubuntu -u root -- test -d /root/alpine-a64 2>$null | Out-Null
  $hasRootfs = ($LASTEXITCODE -eq 0)
} catch {
  $hasRootfs = $false
}
# ===== 服务层类型检查（与 CI 完全一致，约 3 秒）=====
# CI 会跑 `node check-setup.mjs && npx tsc -p check/tsconfig.json`；本地不跑的话，
# 就会出现"本地构建通过、GitHub 报 TS2339"这种来回（真踩过：fileIo.statSync(...).isFile 在
# harness 的类型桩里不存在）。放在这里把它挡在推送之前。
Write-Host '== 服务层类型检查(tsc) =='
$npx = Get-Command npx -ErrorAction SilentlyContinue
if ($null -ne $npx) {
  Push-Location (Join-Path (Get-Location) 'test\guncat-harness')
  try {
    & node check-setup.mjs 2>&1 | Out-Null
    & npx -y -p typescript@5.5.4 tsc -p check/tsconfig.json 2>&1 | Select-Object -Last 8
    if ($LASTEXITCODE -ne 0) {
      Write-Error "服务层类型检查失败(exit $LASTEXITCODE) —— 修好再打包/推送"
      exit 7
    }
  } finally {
    Pop-Location
  }
} else {
  Write-Host '   （未找到 npx，跳过类型检查）'
}

if ($hasRootfs) {
  $here = (Get-Location).Path
  $drive = $here.Substring(0, 1).ToLower()
  $wslPath = '/mnt/' + $drive + ($here.Substring(2) -replace '\\', '/')
  Write-Host '== 文档相对链接检查 =='
  & wsl -d Ubuntu -u root -- bash -c "cd '$wslPath' && python3 tooling/docs-check.py --strict" 2>&1 | Select-Object -Last 4
  if ($LASTEXITCODE -ne 0) {
    Write-Error "文档里有坏链(exit $LASTEXITCODE) —— 修好再打包"
    exit 4
  }
  Write-Host '== 原生库依赖闭合检查 =='
  & wsl -d Ubuntu -u root -- bash -c "cd '$wslPath' && python3 tooling/python/check-sonames.py --strict" 2>&1 | Select-Object -Last 5
  if ($LASTEXITCODE -ne 0) {
    Write-Error "随包 .so 依赖不闭合(exit $LASTEXITCODE) —— 补 soname 或重新链接"
    exit 6
  }
  Write-Host '== 第三方许可覆盖检查 =='
  & wsl -d Ubuntu -u root -- bash -c "cd '$wslPath' && python3 tooling/license-check.py --strict" 2>&1 | Select-Object -Last 4
  if ($LASTEXITCODE -ne 0) {
    Write-Error "有随包组件缺少许可声明(exit $LASTEXITCODE) —— 补 THIRD_PARTY_NOTICES.md"
    exit 5
  }

  if ($full) {
    Write-Host '== 原生 Python 技术栈自检(24 项, 约 10 分钟) =='
    & wsl -d Ubuntu -u root -- bash -c "cd '$wslPath' && SSL_CERT_FILE='$wslPath/entry/src/main/resources/rawfile/python/cacert.pem' bash tooling/python/run-verify-stack.sh" 2>&1 | Select-Object -Last 10
    if ($LASTEXITCODE -ne 0) {
      Write-Error "Python 技术栈自检失败(exit $LASTEXITCODE) —— 先修好运行库再打包"
      exit 3
    }
  } else {
    Write-Host '== 已跳过 23 项运行库自检(需要时用 -Full) =='
  }
} else {
  Write-Host '== 跳过静态检查(未找到 WSL rootfs) =='
}

& $node $hvigor --mode module -p module=entry@default -p product=default assembleHap --no-daemon
exit $LASTEXITCODE
