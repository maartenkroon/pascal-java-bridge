# Tests the registered generated COM server PascalJavaBridge.JDemo from VBA in Microsoft Access
# (the same VBA as Excel and Word). Access is used because its object model can add VBA code and
# type library references without the "Trust access to the VBA project object model" option that
# Excel and Word need; no Office setting is changed. AutomationSecurity applies to this automation
# session only. Access runs hidden in a temporary database, with a time limit (a VBA dialog would
# block it), and is always closed again.
# Usage: powershell -NoProfile -File TestVba.ps1 <classpath> <jvm.dll> <JDemoComServer.tlb>
param([string]$ClassPath, [string]$JvmPath, [string]$TypeLib)
$vbaDir = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) "vba"
$dir = Join-Path ([IO.Path]::GetTempPath()) ("pjb-vba-" + [Guid]::NewGuid())
New-Item -ItemType Directory $dir | Out-Null
$before = @(Get-Process MSACCESS -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
$report = $null
try {
    $job = Start-Job -ArgumentList $ClassPath, $JvmPath, $TypeLib, $dir, $vbaDir -ScriptBlock {
        param($ClassPath, $JvmPath, $TypeLib, $Dir, $VbaDir)
        $ErrorActionPreference = "Stop"
        $acc = New-Object -ComObject Access.Application
        try {
            $acc.AutomationSecurity = 1   # msoAutomationSecurityLow: this session only
            $acc.NewCurrentDatabase((Join-Path $Dir "PjbVbaTest.accdb"))
            [void]$acc.References.AddFromFile($TypeLib)
            $project = $acc.VBE.ActiveVBProject
            foreach ($m in @(@("PjbRunner", 2, "cls"), @("PjbListener", 2, "cls"), @("PjbTests", 1, "bas"))) {
                $c = $project.VBComponents.Add($m[1])   # 1 = standard module, 2 = class module
                $c.Name = $m[0]
                $code = $c.CodeModule
                if ($code.CountOfLines -gt 0) { $code.DeleteLines(1, $code.CountOfLines) }
                $code.AddFromString([IO.File]::ReadAllText((Join-Path $VbaDir ($m[0] + "." + $m[2]))))
            }
            $cp = $ClassPath
            $jp = $JvmPath
            $acc.Run("PjbRunTests", [ref]$cp, [ref]$jp)   # Run's arguments are by reference
        } finally {
            $acc.Quit(2)   # acQuitSaveNone
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($acc)
        }
    }
    if (Wait-Job $job -Timeout 300) {
        $report = Receive-Job $job -ErrorVariable jobErrors 2>$null
        foreach ($err in $jobErrors) { "ERROR $err" }
    } else {
        "FAIL Access did not finish within 300 s (a VBA dialog?)"
        Stop-Job $job
    }
    Remove-Job $job -Force
} finally {
    # an Access started by this test that is still running (timeout, error) is ended
    Get-Process MSACCESS -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.Id } |
        ForEach-Object { Start-Sleep -Seconds 2; if (-not $_.HasExited) { Stop-Process -Id $_.Id -Force } }
    Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
}
$report -split "`r?`n"
if ($report -and ($report -match "ALL TESTS PASSED")) { exit 0 } else { exit 1 }
