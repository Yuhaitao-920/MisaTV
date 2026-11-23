<#
.SYNOPSIS
    MisaTV - 准备随包的 Windows 运行时（JRE / dex2jar / Maven 依赖 / Python / unidbg）。

.DESCRIPTION
    把原本运行期按需下载的运行时改成构建期准备、随包分发。产物放在仓库根的 runtime/，
    由打包步骤拷到 MisaTV.exe 旁边；App 启动后优先用随包运行时，找不到才回落旧下载逻辑。

    JRE 用 jlink 裁剪（模块清单参考 xiugou-tv 的 create_minimal_jre.ps1，GPL-3.0），
    其余运行时按原样随包——它们无法在本机验证裁剪后是否仍可用，见各段注释。

.PARAMETER Force
    忽略已有产物，全部重建。
#>
param(
    [string]$Root = "",
    [string]$CacheDir = "",
    [switch]$Force
)

$ErrorActionPreference = "Stop"
if ($Root -eq "") { $Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path }
if ($CacheDir -eq "") { $CacheDir = Join-Path $Root ".rtcache" }
$Runtime = Join-Path $Root "runtime"
New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null

# 版本与下载源。镜像顺序沿用 App 侧运行期下载的同一批（华为云 / 清华 / 阿里云优先），
# GitHub 直链只作兜底——构建机上通常更稳。
$JdkUrl     = "https://mirrors.huaweicloud.com/openjdk/17.0.2/openjdk-17.0.2_windows-x64_bin.zip"
$DexUrl     = "https://gh-proxy.com/https://github.com/pxb1988/dex2jar/releases/download/v2.4/dex-tools-v2.4.zip"
$PyEmbedUrl = "https://mirrors.huaweicloud.com/python/3.11.6/python-3.11.6-embed-amd64.zip"
$PyVersion  = "3.11.6"

# 与 App 侧 lib/services/jvm/jvm_runtime.dart 的 _libPaths 保持一致。
$MavenBases = @(
    "https://maven.aliyun.com/repository/public/",
    "https://mirrors.huaweicloud.com/repository/maven/",
    "https://repo1.maven.org/maven2/"
)
$LibPaths = @(
    "com/squareup/okhttp3/okhttp/3.14.9/okhttp-3.14.9.jar",
    "com/squareup/okio/okio/1.17.5/okio-1.17.5.jar",
    "com/google/code/gson/gson/2.10.1/gson-2.10.1.jar",
    "org/jsoup/jsoup/1.17.2/jsoup-1.17.2.jar",
    "org/json/json/20180813/json-20180813.jar",
    "org/slf4j/slf4j-api/2.0.16/slf4j-api-2.0.16.jar",
    "org/slf4j/slf4j-simple/2.0.16/slf4j-simple-2.0.16.jar",
    "org/bouncycastle/bcprov-jdk18on/1.78.1/bcprov-jdk18on-1.78.1.jar",
    "org/xerial/sqlite-jdbc/3.46.1.0/sqlite-jdbc-3.46.1.0.jar"
)

function Get-Cached([string]$Url, [string]$Name) {
    $file = Join-Path $CacheDir $Name
    if ((Test-Path $file) -and (-not $Force) -and ((Get-Item $file).Length -gt 1024)) {
        Write-Host "[=] cached $Name" -ForegroundColor DarkGray
        return $file
    }
    Write-Host "[*] downloading $Name" -ForegroundColor Cyan
    Invoke-WebRequest -Uri $Url -OutFile $file -UseBasicParsing -TimeoutSec 900
    if ((Get-Item $file).Length -lt 1024) { throw "download too small: $Url" }
    return $file
}

function Expand-Zip([string]$Zip, [string]$Dest) {
    if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
    Expand-Archive -LiteralPath $Zip -DestinationPath $Dest -Force
}

# ---------------------------------------------------------------- JRE (jlink)
$JreDir = Join-Path $Runtime "jre"
if ($Force -or -not (Test-Path (Join-Path $JreDir "bin/java.exe"))) {
    $JdkZip = Get-Cached $JdkUrl "jdk17.zip"
    $JdkStage = Join-Path $CacheDir "jdk"
    if (-not (Test-Path $JdkStage)) { Expand-Zip $JdkZip $JdkStage }
    $JLink = (Get-ChildItem -Path $JdkStage -Filter "jlink.exe" -Recurse | Select-Object -First 1).FullName
    if (-not $JLink) { throw "jlink.exe not found in JDK" }

    # 模块清单的取舍（每条都曾造成过「静默失效」，不是拍脑袋）：
    #   jdk.crypto.ec —— ECDHE 密钥交换。缺了 HTTPS 大面积握手失败，上游返回空，
    #                    表现为蜘蛛解析错误；而开发机跑完整 JDK 永远复现不了。
    #   jdk.charsets  —— GBK 页面解码，中文影视站常见。
    #   java.management —— 加固壳解包用 unidbg，AbstractEmulator 的静态块会碰
    #                    ManagementFactory。
    #   jdk.zipfs    —— dex2jar 的 DexFileFactory 通过 zip 文件系统写产物；缺了报
    #                    "cant find zipfs support"，然后静默回落原始壳 jar，站点全空白。
    $Modules = @(
        "java.base","java.desktop","java.logging","java.management","java.naming",
        "java.net.http","java.sql","java.xml",
        "jdk.crypto.ec","jdk.charsets","jdk.httpserver","jdk.unsupported","jdk.zipfs"
    ) -join ","
    if (Test-Path $JreDir) { Remove-Item -Recurse -Force $JreDir }
    & $JLink --no-header-files --no-man-pages --compress=2 --strip-debug `
        --add-modules $Modules --output $JreDir
    if (-not (Test-Path (Join-Path $JreDir "bin/java.exe"))) { throw "jlink 产物缺少 java.exe" }
    # Classpath Exception 的合规要求：legal/ 目录必须随包。
    if (-not (Test-Path (Join-Path $JreDir "legal/java.base/LICENSE"))) { throw "jlink 产物缺少 legal/java.base/LICENSE" }
    Write-Host "[+] JRE 就绪" -ForegroundColor Green
} else { Write-Host "[=] JRE 已存在，跳过" -ForegroundColor DarkGray }

# ------------------------------------------------------- dex2jar（原样随包）
# 不做裁剪：Dex2jarCmd 的 classpath 是 d2j/ 下全部 jar，裁剪后是否仍可用
# 必须用真实 classes.dex 回归验证，而这类样本无法在此环境构造。
# 体积大头是 icu4j(13MB)/antlr，等有回归样本后再单独收。
$D2jDir = Join-Path $Runtime "d2j"
if ($Force -or -not (Test-Path (Join-Path $D2jDir "dex-tools-v2.4.jar"))) {
    $DexZip = Get-Cached $DexUrl "dex-tools.zip"
    $DexStage = Join-Path $CacheDir "dex-tools"
    Expand-Zip $DexZip $DexStage
    $LibSrc = (Get-ChildItem -Path $DexStage -Filter "dex-tools-v2.4.jar" -Recurse | Select-Object -First 1).DirectoryName
    if (-not $LibSrc) { throw "dex-tools-v2.4.jar not found" }
    if (Test-Path $D2jDir) { Remove-Item -Recurse -Force $D2jDir }
    New-Item -ItemType Directory -Force -Path $D2jDir | Out-Null
    # 只搬 lib/*.jar，丢掉 d2j-*.bat/.sh 等命令行包装。
    Get-ChildItem -Path $LibSrc -Filter "*.jar" | ForEach-Object { Copy-Item $_.FullName $D2jDir -Force }
    Write-Host "[+] dex2jar 就绪（未裁剪）" -ForegroundColor Green
} else { Write-Host "[=] dex2jar 已存在，跳过" -ForegroundColor DarkGray }

# ------------------------------------------------- Maven 依赖（蜘蛛宿主库）
$LibsDir = Join-Path $Runtime "libs"
New-Item -ItemType Directory -Force -Path $LibsDir | Out-Null
foreach ($rel in $LibPaths) {
    $dest = Join-Path $LibsDir (Split-Path $rel -Leaf)
    if ((Test-Path $dest) -and -not $Force) { continue }
    $ok = $false
    foreach ($base in $MavenBases) {
        try {
            Invoke-WebRequest -Uri ($base + $rel) -OutFile $dest -UseBasicParsing -TimeoutSec 300
            if ((Get-Item $dest).Length -gt 1024) { $ok = $true; break }
        } catch { Write-Host "    mirror failed: $base" -ForegroundColor DarkYellow }
    }
    if (-not $ok) { throw "Maven 依赖下载失败: $rel" }
}
Write-Host "[+] 宿主库就绪" -ForegroundColor Green

# --------------------------------------------------------------- Python
# 用官方 embeddable 包（本身已是最精简发行版，含 python311.dll 与必要 .pyd）。
# 不再裁剪 .pyd：蜘蛛实际用到哪些扩展取决于源，裁错会在运行期 ImportError。
$PyDir = Join-Path $Runtime "python"
if ($Force -or -not (Test-Path (Join-Path $PyDir "python.exe"))) {
    $PyZip = Get-Cached $PyEmbedUrl "python-embed.zip"
    Expand-Zip $PyZip $PyDir
    if (-not (Test-Path (Join-Path $PyDir "python.exe"))) { throw "python.exe 缺失" }
    # embeddable 包默认不加载 site-packages，补一个 ._pth 让随包依赖能被 import。
    $pth = Get-ChildItem -Path $PyDir -Filter "python*._pth" | Select-Object -First 1
    if ($pth) {
        $lines = Get-Content $pth.FullName
        if ($lines -notcontains "Lib\site-packages") {
            ($lines + @("Lib\site-packages", "import site")) | Set-Content $pth.FullName -Encoding ascii
        }
    }
    Write-Host "[+] Python $PyVersion 就绪（未裁剪）" -ForegroundColor Green
} else { Write-Host "[=] Python 已存在，跳过" -ForegroundColor DarkGray }


# ------------------------------------------------------- unidbg（原样随包）
# 加固壳解包要用 unidbg 在 x64 上跑 AArch64/ARM32 的 .so；两个 JIT 后端
# （unicorn2 / dynarmic）都保留——裁剪哪一个会在特定壳上退化成「解包失败」，
# 而这类回归必须拿真实壳样本才能验证。
$UnidbgJars = @(
    "com/github/zhkl0228/unidbg-android/0.9.9/unidbg-android-0.9.9.jar",
    "com/github/zhkl0228/unidbg-api/0.9.9/unidbg-api-0.9.9.jar",
    "com/github/zhkl0228/unidbg-unicorn2/0.9.9/unidbg-unicorn2-0.9.9.jar",
    "com/github/zhkl0228/unidbg-dynarmic/0.9.9/unidbg-dynarmic-0.9.9.jar",
    "com/github/zhkl0228/unicorn/1.0.15/unicorn-1.0.15.jar",
    "com/github/zhkl0228/capstone/3.1.8/capstone-3.1.8.jar",
    "com/github/zhkl0228/keystone/0.9.7/keystone-0.9.7.jar",
    "com/github/zhkl0228/demumble/1.0.4/demumble-1.0.4.jar",
    "commons-codec/commons-codec/1.21.0/commons-codec-1.21.0.jar",
    "org/apache/commons/commons-collections4/4.5.0/commons-collections4-4.5.0.jar",
    "commons-io/commons-io/2.21.0/commons-io-2.21.0.jar",
    "com/alibaba/fastjson/1.2.83/fastjson-1.2.83.jar",
    "net/dongliu/apk-parser/2.6.10/apk-parser-2.6.10.jar",
    "net/java/dev/jna/jna/5.10.0/jna-5.10.0.jar",
    "org/scijava/native-lib-loader/2.3.5/native-lib-loader-2.3.5.jar",
    "org/slf4j/slf4j-api/2.0.16/slf4j-api-2.0.16.jar",
    "org/slf4j/slf4j-simple/2.0.16/slf4j-simple-2.0.16.jar",
    "org/ow2/asm/asm/9.7/asm-9.7.jar"
)
$UnidbgDir = Join-Path $Runtime "unidbg"
New-Item -ItemType Directory -Force -Path $UnidbgDir | Out-Null
foreach ($rel in $UnidbgJars) {
    $dest = Join-Path $UnidbgDir (Split-Path $rel -Leaf)
    if ((Test-Path $dest) -and -not $Force) { continue }
    $ok = $false
    foreach ($base in $MavenBases) {
        try {
            Invoke-WebRequest -Uri ($base + $rel) -OutFile $dest -UseBasicParsing -TimeoutSec 300
            if ((Get-Item $dest).Length -gt 1024) { $ok = $true; break }
        } catch { }
    }
    if (-not $ok) { throw "unidbg 依赖下载失败: $rel" }
}
Write-Host "[+] unidbg 就绪（未裁剪）" -ForegroundColor Green

# ------------------------------------------------------------------ 清单
$count = 0; $bytes = 0
Get-ChildItem -Path $Runtime -Recurse -File | ForEach-Object { $count++; $bytes += $_.Length }
$manifest = [ordered]@{
    jre = "temurin-jdk17.0.2-jlink"
    dex2jar = "dex-tools-v2.4"
    python = $PyVersion
    files = $count
    bytes = $bytes
}
$manifest | ConvertTo-Json | Set-Content (Join-Path $Runtime "manifest.json") -Encoding utf8
Write-Host ("[+] runtime/ 就绪：{0} 个文件，{1} MB" -f $count, [math]::Round($bytes/1MB,1)) -ForegroundColor Green
