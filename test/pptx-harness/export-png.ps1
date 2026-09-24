# 用 PowerPoint COM 把 pptx 导出为 PNG(视觉自检用)
param([string]$PptxPath, [string]$OutDir)
$ErrorActionPreference = 'Stop'
$pp = New-Object -ComObject PowerPoint.Application
try {
    $pres = $pp.Presentations.Open($PptxPath, $true, $false, $false)
    $pres.Export($OutDir, 'PNG', 1280, 720)
    $pres.Close()
    Write-Output "EXPORTED $OutDir"
} finally {
    $pp.Quit()
    [System.Runtime.Interopservices.Marshal]::ReleaseComObject($pp) | Out-Null
}
