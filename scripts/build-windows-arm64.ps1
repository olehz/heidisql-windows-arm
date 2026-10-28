$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Say($msg) { Write-Host "==> $msg" }

function Find-First($names) {
  foreach ($n in $names) {
    $cmd = Get-Command $n -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
  }
  return $null
}

Say "Runner arch: $env:PROCESSOR_ARCHITECTURE"
Say "OS: $([Environment]::OSVersion.VersionString)"

New-Item -ItemType Directory -Force -Path C:\src, C:\tools\bin | Out-Null

# clang wrapper: fpc.cfg uses -XP$FPCTARGET-, so the assembler name is aarch64-win64-clang.exe
$clang = Find-First @("clang.exe", "clang")
if (-not $clang) {
  $candidates = @(
    "${env:ProgramFiles}\LLVM\bin\clang.exe",
    "${env:ProgramFiles(x86)}\LLVM\bin\clang.exe"
  )
  $clang = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $clang) { throw "clang.exe was not found on the runner" }
Say "clang: $clang"
Copy-Item $clang C:\tools\bin\aarch64-win64-clang.exe -Force
$env:PATH = "C:\tools\bin;" + $env:PATH

# Bootstrap compiler. FPC 3.2.2 has no aarch64-win64 target; trunk does.
# The x64 3.2.2 compiler runs under emulation and is only used to build trunk.
$fpcExe = $null
if (Test-Path C:\fpc) {
  $fpcExe = Get-ChildItem C:\fpc -Recurse -Filter fpc.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match 'x86_64-win64' } | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $fpcExe) {
  Say "Downloading FPC 3.2.2 x64 bootstrap"
  $archive = "C:\src\fpc-3.2.2.x86_64-win64.tar"
  $url = "https://downloads.freepascal.org/fpc/dist/3.2.2/x86_64-win64/fpc-3.2.2.x86_64-win64.tar"
  Say "GET $url"
  curl.exe -L --fail --retry 3 -o $archive $url
  if ($LASTEXITCODE -ne 0) { throw "Could not download the FPC 3.2.2 Windows archive" }
  Say "Extracting FPC 3.2.2"
  New-Item -ItemType Directory -Force -Path C:\fpc | Out-Null
  tar.exe -xf $archive -C C:\fpc
  $inner = Get-ChildItem C:\fpc -Recurse -Filter "binary*.tar" | Select-Object -First 1
  if ($inner) {
    Say "Extracting $($inner.Name)"
    New-Item -ItemType Directory -Force -Path C:\fpc\root | Out-Null
    tar.exe -xf $inner.FullName -C C:\fpc\root
    Get-ChildItem C:\fpc\root -Filter *.tar.gz | ForEach-Object {
      tar.exe -xf $_.FullName -C C:\fpc\root
    }
  }
  $fpcExe = @(
    Get-ChildItem C:\fpc -Recurse -Filter fpc.exe -ErrorAction SilentlyContinue
    Get-ChildItem C:\fpc -Recurse -Filter ppcx64.exe -ErrorAction SilentlyContinue
  ) | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $fpcExe) {
  Get-ChildItem C:\fpc -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 30 |
    ForEach-Object { Say $_.FullName }
  throw "Bootstrap compiler missing under C:\fpc"
}
$env:PATH = (Split-Path $fpcExe -Parent) + ";" + $env:PATH
& $fpcExe -iV -iTP -iTO

Say "Cloning FPC trunk"
if (-not (Test-Path C:\src\fpc\.git)) {
  git clone --depth 1 https://gitlab.com/freepascal.org/fpc/source.git C:\src\fpc
}
Say "Building FPC 3.3.1 cross compiler (x64 host, aarch64-win64 target)"
Push-Location C:\src\fpc
& make.exe all OS_TARGET=win64 CPU_TARGET=aarch64 "BINUTILSPREFIX=" "-j4"
if ($LASTEXITCODE -ne 0) { throw "FPC trunk build failed ($LASTEXITCODE)" }
& make.exe crossinstall OS_TARGET=win64 CPU_TARGET=aarch64 "BINUTILSPREFIX=" "INSTALL_PREFIX=C:\fpc-cross"
if ($LASTEXITCODE -ne 0) { throw "FPC crossinstall failed ($LASTEXITCODE)" }
Pop-Location

$pp = Get-ChildItem C:\fpc-cross,C:\src\fpc -Recurse -Filter ppcrossa64.exe -ErrorAction SilentlyContinue |
  Select-Object -First 1 -ExpandProperty FullName
if (-not $pp) { throw "ppcrossa64.exe was not installed" }
$ppDir = Split-Path $pp -Parent
@"
-Twin64
-Paarch64
-FuC:\fpc-cross\units\`$fpctarget\*
-FlC:\qt6pas\lib
-XPaarch64-win64-
"@ | Set-Content -Encoding ASCII (Join-Path $ppDir "fpc.cfg")
Say "ppcrossa64: $pp"

Say "Installing Qt 6 for Windows ARM64 (qtbase only)"
python -m pip install --disable-pip-version-check aqtinstall
Say "aqt versions for windows_arm64 desktop:"
$versions = @(python -m aqt list-qt windows_arm64 desktop)
$versions | ForEach-Object { Say $_ }
$ver = $versions | Where-Object { $_ -match '^\d+\.\d+\.\d+$' } | Sort-Object { [version]$_ } | Select-Object -Last 1
if (-not $ver) { throw "aqt listed no Qt versions for windows_arm64 desktop" }
Say "Using Qt $ver"
$archList = @(python -m aqt list-qt windows_arm64 desktop --arch $ver)
Say "aqt archs: $($archList -join ' ')"
$arch = $archList | Where-Object { $_ -match 'arm64' } | Select-Object -First 1
if (-not $arch) { throw "No ARM64 Qt architecture for windows_arm64 desktop $ver" }
Say "Using Qt arch $arch"
python -m aqt install-qt windows_arm64 desktop $ver $arch --outputdir C:\Qt
$qmake = Get-ChildItem C:\Qt -Recurse -Filter qmake.exe | Select-Object -First 1
if (-not $qmake) { throw "qmake.exe not found under C:\Qt" }
Say "qmake: $($qmake.FullName)"

Say "Building Qt6Pas.dll with the ARM64 MSVC kit"
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { $vswhere = "${env:ProgramFiles}\Microsoft Visual Studio\Installer\vswhere.exe" }
$vsInst = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.ARM64 -property installationPath
if (-not $vsInst) { throw "Visual Studio with VC ARM64 tools was not found" }
$vcvars = Join-Path $vsInst "VC\Auxiliary\Build\vcvarsall.bat"
if (-not (Test-Path $vcvars)) { throw "vcvarsall.bat missing: $vcvars" }

if (-not (Test-Path C:\src\lazarus\.git)) {
  Say "Cloning Lazarus fixes_4_8"
  git clone --depth 1 https://gitlab.com/freepascal.org/lazarus/lazarus.git C:\src\lazarus
}
$pro = "C:\src\lazarus\lcl\interfaces\qt6\cbindings\Qt6Pas.pro"
if (-not (Test-Path $pro)) { throw "Qt6Pas.pro not found" }

(Get-Content $pro) -replace 'QMAKE_CXXFLAGS \+= -Wfatal-errors -fvisibility=hidden','' | Set-Content -Encoding ASCII $pro
$qtBin = Split-Path $qmake.FullName -Parent
$buildBat = "C:\src\build-qt6pas.bat"
@"
@echo off
call "$vcvars" arm64
if errorlevel 1 exit /b 1
set PATH=$qtBin;%PATH%
where cl
cd /d C:\src\lazarus\lcl\interfaces\qt6\cbindings
"$($qmake.FullName)" -spec win32-msvc Qt6Pas.pro
if errorlevel 1 exit /b 1
nmake
if errorlevel 1 exit /b 1
"@ | Set-Content -Encoding ASCII $buildBat
cmd.exe /c $buildBat
if ($LASTEXITCODE -ne 0) { throw "Qt6Pas build failed ($LASTEXITCODE)" }

$dll = Get-ChildItem C:\src\lazarus\lcl\interfaces\qt6\cbindings -Recurse -Filter Qt6Pas.dll | Select-Object -First 1
if (-not $dll) { $dll = Get-ChildItem C:\src\lazarus\lcl\interfaces\qt6\cbindings -Recurse -Filter Qt6Pas*.dll | Select-Object -First 1 }
if (-not $dll) { throw "Qt6Pas.dll was not produced" }
Say "Qt6Pas: $($dll.FullName)"
New-Item -ItemType Directory -Force -Path C:\qt6pas\lib | Out-Null
Copy-Item $dll.FullName C:\qt6pas\lib\Qt6Pas.dll -Force
$dumpbin = Get-ChildItem (Join-Path $vsInst "VC\Tools\MSVC") -Recurse -Filter dumpbin.exe -ErrorAction SilentlyContinue |
  Where-Object { $_.DirectoryName -match 'arm64' } | Select-Object -First 1
$dlltool = Find-First @("llvm-dlltool.exe", "dlltool.exe")
if (-not $dlltool) {
  $dlltool = Get-ChildItem "${env:ProgramFiles}\LLVM\bin" -Filter "llvm-dlltool.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
}
if ($dumpbin -and $dlltool) {
  Say "Writing an import library for Qt6Pas"
  $exports = & $dumpbin.FullName /nologo /exports $dll.FullName
  $names = foreach ($line in $exports) {
    if ($line -match '^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]+\s+(\S+)') { $Matches[1] }
  }
  $def = @("LIBRARY Qt6Pas", "EXPORTS") + $names
  $defPath = "C:\qt6pas\lib\Qt6Pas.def"
  Set-Content -Encoding ASCII $defPath $def
  & $dlltool -m arm64 -d $defPath -l C:\qt6pas\lib\libQt6Pas.a
  Copy-Item C:\qt6pas\lib\libQt6Pas.a C:\qt6pas\lib\libimpQt6Pas.a -Force
} else {
  Say "dlltool or dumpbin missing; link may fail looking for libQt6Pas.a"
}
# Also copy Qt runtime DLLs next to the eventual exe.
$qtBinDlls = Get-ChildItem $qtBin -Filter "Qt6*.dll"
New-Item -ItemType Directory -Force -Path C:\qt6pas\qtbin | Out-Null
Copy-Item $qtBinDlls.FullName C:\qt6pas\qtbin -Force

Say "Building lazbuild with the bootstrap compiler"
Push-Location C:\src\lazarus
& make.exe lazbuild "FPC=$fpcExe" "-j4"
if ($LASTEXITCODE -ne 0) { throw "lazbuild build failed ($LASTEXITCODE)" }
Pop-Location
$lazbuild = "C:\src\lazarus\lazbuild.exe"
if (-not (Test-Path $lazbuild)) { throw "lazbuild.exe missing" }

Say "Building HeidiSQL --cpu=aarch64 --os=win64 --ws=qt6"
$repo = Join-Path $env:GITHUB_WORKSPACE "heidisql"
Push-Location $repo
$env:PATH = "C:\tools\bin;C:\qt6pas\lib;C:\qt6pas\qtbin;" + $env:PATH
& bash ./lazbuild-with-buildnr.sh $lazbuild -B --bm=Release --ws=qt6 --cpu=aarch64 --os=win64 "--compiler=$pp" heidisql.lpi
if ($LASTEXITCODE -ne 0) { throw "lazbuild failed ($LASTEXITCODE)" }
Pop-Location

$exe = Get-ChildItem $repo -Recurse -Filter heidisql.exe | Select-Object -First 1
if (-not $exe) { throw "heidisql.exe was not produced" }
Say "EXE $($exe.FullName) $([math]::Round($exe.Length/1MB,2)) MB"
# Copy Qt6Pas next to the exe so a later local run can at least load the binding.
Copy-Item C:\qt6pas\lib\Qt6Pas.dll (Join-Path $exe.DirectoryName "Qt6Pas.dll") -Force
Copy-Item C:\qt6pas\qtbin\*.dll $exe.DirectoryName -Force
Say "DONE"
