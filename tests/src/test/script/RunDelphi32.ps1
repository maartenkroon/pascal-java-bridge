# The 32-bit Delphi build and tests (Maven profile delphi32-tests, -Djvm32.home=<32-bit JDK 17..23>;
# JDK 24 and later have no 32-bit Windows build). Compiles TestBindings (both layouts), TestCom,
# TestComEarly (both layouts) and the two COM servers with dcc32, runs the tests on the 32-bit JVM
# under -Xcheck:jni, and with <scripts> = "true" also runs the COM script tests through the 32-bit
# script hosts (RunComScripts.ps1 -Wow64; VBA is left out: it needs a 32-bit Office).
param([string]$Dcc, [string]$Jvm32Home, [string]$Generated, [string]$GeneratedPP, [string]$TestSrc,
      [string]$ComServerSrc, [string]$OutDir, [string]$ClassPath, [string]$Scripts)
# not "Stop": Windows PowerShell turns a native program's stderr line (a test's expected Java
# stack trace) into a terminating error under 2>&1
$ErrorActionPreference = "Continue"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$jvm = Join-Path $Jvm32Home "bin\server\jvm.dll"
if (-not (Test-Path $jvm)) { throw "no $jvm (set -Djvm32.home to a 32-bit JDK or JRE, 17 to 23)" }
$bytes = [IO.File]::ReadAllBytes($jvm)
if ([BitConverter]::ToUInt16($bytes, [BitConverter]::ToInt32($bytes, 0x3C) + 4) -ne 0x14C) {
    throw "$jvm is not a 32-bit (x86) DLL"
}

# name, output subdirectory, source, unit search path, extra arguments
$builds = @(
    @("TestBindings", "single", "$TestSrc\TestBindings.pas", $Generated, @()),
    @("TestBindings", "per-package", "$TestSrc\TestBindings.pas", $GeneratedPP, @("-DUNIT_PER_PACKAGE")),
    @("TestCom", "single", "$TestSrc\TestCom.pas", $Generated, @()),
    @("TestComEarly", "single", "$TestSrc\TestComEarly.pas", $Generated, @()),
    @("TestComEarly", "per-package", "$TestSrc\TestComEarly.pas", $GeneratedPP, @()),
    @("PascalJavaBridgeCom", "comserver", $ComServerSrc, $Generated, @("-I$Generated")),
    @("JDemoComServer", "jdemo-comserver", "$Generated\JDemoComServer.dpr", $Generated, @("-I$Generated")))
foreach ($b in $builds) {
    $dir = Join-Path $OutDir $b[1]
    New-Item -ItemType Directory -Force $dir | Out-Null
    "dcc32 $($b[1])/$($b[0])"
    Push-Location $dir
    try {
        & $Dcc @(@("-B", "-Q", "-NSSystem", "-NU$dir", "-E$dir", "-U$($b[3])") + $b[4] + @($b[2]))
        if ($LASTEXITCODE -ne 0) { throw "dcc32 failed for $($b[1])/$($b[0])" }
    } finally { Pop-Location }
}

$env:JAVA_HOME = $Jvm32Home
$failed = 0
foreach ($b in $builds | Where-Object { $_[0] -like "Test*" }) {
    $exe = Join-Path (Join-Path $OutDir $b[1]) ($b[0] + ".exe")
    "=== 32-bit $($b[1])/$($b[0])"
    $out = & $exe --checkjni --classpath $ClassPath 2>&1 | ForEach-Object { "$_" }
    $out
    if ($LASTEXITCODE -ne 0 -or -not ($out -contains "ALL TESTS PASSED")) { $failed++ }
}

if ($Scripts -eq "true") {
    "=== 32-bit COM script tests"
    & "$env:windir\SysWOW64\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass `
        -File "$here\RunComScripts.ps1" (Join-Path $OutDir "comserver\PascalJavaBridgeCom.dll") $ClassPath $jvm `
        (Join-Path $OutDir "jdemo-comserver\JDemoComServer.dll") "false"
    if ($LASTEXITCODE -ne 0) { $failed++ }
}
if ($failed -ne 0) { "$failed 32-bit test run(s) failed"; exit 1 }
"ALL 32-BIT TESTS PASSED"
