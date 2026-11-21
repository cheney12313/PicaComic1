#requires -Version 5.1
<#
.SYNOPSIS
    一键把 PicaComic 打包成 APK（Windows 本地构建）。

.DESCRIPTION
    自动完成：环境检查 -> 生成签名密钥与 key.properties（缺失时）-> flutter pub get
    -> flutter build apk --release -> 把产物收集到 dist\ 目录。

.PARAMETER ResetKeystore
    删除并重新生成签名密钥（会改变应用签名，覆盖安装前需先卸载旧版本）。

.PARAMETER Mirror
    使用国内镜像（PUB_HOSTED_URL / FLUTTER_STORAGE_BASE_URL）。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\build_apk.ps1 -Mirror

.NOTES
    依赖：Flutter SDK（3.35+）、JDK 17+、Android SDK（含 cmdline-tools）。
    首次构建会下载 Gradle / AGP / NDK，约 2~4 GB，耗时较长。
#>
param(
    [switch]$ResetKeystore,
    [switch]$Mirror
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Fail($msg) {
    Write-Host "`n[ERROR] $msg" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------- 1. 环境检查
Write-Step '检查构建环境'

$flutter = Get-Command flutter -ErrorAction SilentlyContinue
if (-not $flutter) {
    Fail @'
未找到 flutter 命令。请先安装 Flutter SDK 并把 <flutter>\bin 加入 PATH：
  https://docs.flutter.cn/get-started/install/windows
安装后执行 flutter doctor，确保 Android toolchain 一项是 ✓。
'@
}
Write-Host ("flutter : " + $flutter.Source)
& flutter --version
if ($LASTEXITCODE -ne 0) { Fail 'flutter --version 执行失败，请检查 Flutter 安装。' }

# JDK：优先 JAVA_HOME，其次 PATH，最后找 Android Studio 自带的 JBR
$javaExe = $null
if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME 'bin\java.exe'))) {
    $javaExe = Join-Path $env:JAVA_HOME 'bin\java.exe'
} elseif (Get-Command java -ErrorAction SilentlyContinue) {
    $javaExe = (Get-Command java).Source
} else {
    $jbr = 'C:\Program Files\Android\Android Studio\jbr\bin\java.exe'
    if (Test-Path $jbr) { $javaExe = $jbr }
}
if (-not $javaExe) {
    Fail @'
未找到 JDK。AGP 8.12 / Gradle 8.14 需要 JDK 17 或更高版本。
推荐安装 Android Studio（自带 JBR 21），或安装 Temurin 17 并设置 JAVA_HOME。
'@
}
Write-Host ("java    : " + $javaExe)
$javaVersion = (& $javaExe -version 2>&1 | Out-String)
Write-Host $javaVersion.Trim()

$sdkRoot = $env:ANDROID_HOME
if (-not $sdkRoot) { $sdkRoot = $env:ANDROID_SDK_ROOT }
if (-not $sdkRoot) {
    $defaultSdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
    if (Test-Path $defaultSdk) { $sdkRoot = $defaultSdk }
}
if (-not $sdkRoot -or -not (Test-Path $sdkRoot)) {
    Fail @'
未找到 Android SDK。请安装 Android Studio，或在命令行设置：
  setx ANDROID_HOME "%LOCALAPPDATA%\Android\Sdk"
然后执行：
  flutter doctor --android-licenses
'@
}
Write-Host ("android : " + $sdkRoot)

# ------------------------------------------------------- 2. 签名配置（必需）
# android/app/build.gradle 会无条件读取 android/key.properties，
# 文件不存在时 Gradle 配置阶段就会抛 FileNotFoundException。
Write-Step '准备签名配置'

$keyPropsPath = Join-Path $ProjectRoot 'android\key.properties'
$keystorePath = Join-Path $ProjectRoot 'android\app\pica-comic.jks'

if ($ResetKeystore) {
    if (Test-Path $keystorePath) { Remove-Item $keystorePath -Force }
    if (Test-Path $keyPropsPath) { Remove-Item $keyPropsPath -Force }
    Write-Host '已删除旧的签名密钥。'
}

if (Test-Path $keyPropsPath) {
    $props = Get-Content $keyPropsPath -Raw
    if ($props -match 'storeFile\s*=\s*(.+)') {
        $storeFile = $Matches[1].Trim()
        $resolved = Join-Path (Join-Path $ProjectRoot 'android\app') $storeFile
        if (-not (Test-Path $resolved)) {
            Fail "key.properties 指向的密钥不存在：$resolved`n请用 -ResetKeystore 重新生成。"
        }
    }
    Write-Host "使用已有签名配置：$keyPropsPath"
} else {
    if (Test-Path $keystorePath) {
        Fail @"
检测到 $keystorePath ，但缺少 key.properties（密码无法恢复）。
解决方式：加 -ResetKeystore 重新生成一套签名（会改变应用签名）。
"@
    }

    $keytoolExe = $null
    $keytoolCmd = Get-Command keytool -ErrorAction SilentlyContinue
    if ($keytoolCmd) {
        $keytoolExe = $keytoolCmd.Source
    } else {
        $guess = Join-Path (Split-Path (Split-Path $javaExe)) 'bin\keytool.exe'
        if (Test-Path $guess) { $keytoolExe = $guess }
    }
    if (-not $keytoolExe) { Fail '未找到 keytool（随 JDK 提供），请检查 JAVA_HOME。' }

    $alphabet = [char[]]'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $password = -join (1..24 | ForEach-Object { $alphabet | Get-Random })
    $alias = 'picacomic'

    Write-Host '正在生成签名密钥（有效期 10000 天）...'
    & $keytoolExe -genkeypair -v `
        -keystore $keystorePath `
        -keyalg RSA -keysize 2048 -validity 10000 `
        -alias $alias -storepass $password -keypass $password `
        -dname 'CN=PicaComic, OU=Dev, O=PicaComic, L=NA, ST=NA, C=CN' 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $keystorePath)) {
        Fail '生成签名密钥失败，请检查 keytool 输出。'
    }

    @(
        "storePassword=$password"
        "keyPassword=$password"
        "keyAlias=$alias"
        'storeFile=pica-comic.jks'
    ) | Set-Content -Path $keyPropsPath -Encoding ASCII
    Write-Host "已生成：$keystorePath"
    Write-Host "已写入：$keyPropsPath"
    Write-Host '请妥善备份这两个文件；丢失后无法用同一签名覆盖安装。' -ForegroundColor Yellow
}

# ------------------------------------------------------------- 3. 依赖与构建
if ($Mirror) {
    Write-Step '启用国内镜像'
    $env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
    $env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
    Write-Host "PUB_HOSTED_URL=$env:PUB_HOSTED_URL"
    Write-Host "FLUTTER_STORAGE_BASE_URL=$env:FLUTTER_STORAGE_BASE_URL"
}

Write-Step '拉取依赖（flutter pub get）'
& flutter pub get
if ($LASTEXITCODE -ne 0) { Fail 'flutter pub get 失败（检查网络或 pub 镜像）。' }

Write-Step '构建 Release APK（首次会下载 Gradle/AGP/NDK，请耐心等待）'
$buildLog = Join-Path $ProjectRoot 'build_apk.log'
& flutter build apk --release 2>&1 | Tee-Object -FilePath $buildLog
$buildExit = $LASTEXITCODE

# ------------------------------------------------------------- 4. 收集产物
Write-Step '收集 APK'

$searchDirs = @(
    (Join-Path $ProjectRoot 'build\app\outputs\flutter-apk'),
    (Join-Path $ProjectRoot 'build\app\outputs\apk\release')
)
$found = @()
foreach ($dir in $searchDirs) {
    if (Test-Path $dir) {
        $found += Get-ChildItem -Path $dir -Filter *.apk -File -ErrorAction SilentlyContinue
    }
}
$found = $found | Sort-Object FullName -Unique

if (-not $found -or $found.Count -eq 0) {
    Write-Host "`n构建退出码：$buildExit" -ForegroundColor Red
    Write-Host "完整日志：$buildLog" -ForegroundColor Red
    Fail '没有找到任何 APK。请查看上面的 Gradle 报错（常见原因见 BUILD_APK.md 的“常见报错”）。'
}

$distDir = Join-Path $ProjectRoot 'dist'
New-Item -ItemType Directory -Force -Path $distDir | Out-Null

foreach ($apk in $found) {
    $target = Join-Path $distDir $apk.Name
    Copy-Item $apk.FullName $target -Force
    $sizeMb = [math]::Round($apk.Length / 1MB, 2)
    Write-Host ("  {0}  ({1} MB)" -f $target, $sizeMb) -ForegroundColor Green
}

if ($buildExit -ne 0) {
    Write-Host "`n注意：flutter 命令退出码为 $buildExit，但已找到 APK。" -ForegroundColor Yellow
    Write-Host '（android/app/build.gradle 里配置了 ABI 分包，flutter 工具可能因此误报"未找到 apk"。）'
    Write-Host "日志：$buildLog"
}

Write-Step '完成'
Write-Host "APK 输出目录：$distDir"
Write-Host '手机安装：把 arm64-v8a 或 universal 的 apk 传到手机点击安装（需允许安装未知来源应用）。'
