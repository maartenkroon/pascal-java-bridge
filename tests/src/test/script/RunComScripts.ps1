# Registers the COM servers for the current user, runs the script tests against them, and always
# unregisters them again.
#   <dll>        PascalJavaBridgeCom.dll (late binding): TestCom.vbs, TestCom.js, TestCom.ps1
#   <earlyDll>   optional, a generated JDemoComServer.dll (early binding, type library):
#                TestComEarly.vbs, TestComEarly.ps1 (PowerShell and C#)
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File RunComScripts.ps1 <dll> <classpath> <jvm.dll> [<earlyDll>]
param([string]$Dll, [string]$ClassPath, [string]$JvmPath, [string]$EarlyDll)
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Invoke-Regsvr32([string]$File, [string[]]$Arguments) {
    $p = Start-Process regsvr32 -ArgumentList ($Arguments + "`"$File`"") -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "regsvr32 $Arguments $File failed with exit code $($p.ExitCode)" }
}

# Runs one test script; it passes only with exit code 0 and "ALL TESTS PASSED" in its output (a
# VBScript or JScript run-time error stops the script but leaves cscript's exit code at 0).
function Invoke-TestScript([string]$Exe, [string[]]$Arguments) {
    $out = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
    $out
    if ($LASTEXITCODE -ne 0 -or -not ($out -contains "ALL TESTS PASSED")) { $script:failed++ }
}

$failed = 0
$registered = @()
$ps = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File")
try {
    Invoke-Regsvr32 $Dll @("/s", "/n", "/i:user")
    $registered += $Dll
    Invoke-TestScript cscript @("//nologo", "$here\TestCom.vbs", $ClassPath, $JvmPath)
    Invoke-TestScript cscript @("//nologo", "$here\TestCom.js", $ClassPath, $JvmPath)
    Invoke-TestScript powershell ($ps + @("$here\TestCom.ps1", $ClassPath, $JvmPath))
    if ($EarlyDll) {
        Invoke-Regsvr32 $EarlyDll @("/s", "/n", "/i:user")
        $registered += $EarlyDll
        Invoke-TestScript cscript @("//nologo", "$here\TestComEarly.vbs", $ClassPath, $JvmPath)
        Invoke-TestScript powershell ($ps + @("$here\TestComEarly.ps1", $ClassPath, $JvmPath,
            [IO.Path]::ChangeExtension($EarlyDll, ".tlb")))
    }
} finally {
    foreach ($r in $registered) { Invoke-Regsvr32 $r @("/s", "/u", "/n", "/i:user") }
}
if ($failed -ne 0) { "$failed COM script test(s) failed"; exit 1 }
