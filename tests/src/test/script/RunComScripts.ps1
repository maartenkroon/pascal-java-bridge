# Registers the COM server for the current user, runs the VBScript, JScript and PowerShell tests
# against it, and always unregisters it again.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File RunComScripts.ps1 <dll> <classpath> <jvm.dll>
param([string]$Dll, [string]$ClassPath, [string]$JvmPath)
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Invoke-Regsvr32([string[]]$Arguments) {
    $p = Start-Process regsvr32 -ArgumentList ($Arguments + "`"$Dll`"") -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "regsvr32 $Arguments failed with exit code $($p.ExitCode)" }
}

$failed = 0
Invoke-Regsvr32 @("/s", "/n", "/i:user")
try {
    cscript //nologo "$here\TestCom.vbs" $ClassPath $JvmPath
    if ($LASTEXITCODE -ne 0) { $failed++ }
    cscript //nologo "$here\TestCom.js" $ClassPath $JvmPath
    if ($LASTEXITCODE -ne 0) { $failed++ }
    powershell -NoProfile -ExecutionPolicy Bypass -File "$here\TestCom.ps1" $ClassPath $JvmPath
    if ($LASTEXITCODE -ne 0) { $failed++ }
} finally {
    Invoke-Regsvr32 @("/s", "/u", "/n", "/i:user")
}
if ($failed -ne 0) { "$failed COM script test(s) failed"; exit 1 }
