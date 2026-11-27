# Tests the registered COM server PascalJavaBridge.JVM from Windows PowerShell.
# Usage: powershell -NoProfile -File TestCom.ps1 <classpath> [<path of jvm.dll>]
# (register first: regsvr32 /n /i:user PascalJavaBridgeCom.dll)
param([string]$ClassPath, [string]$JvmPath)
$failures = 0
function Check($cond, $what) {
    if ($cond) { "  ok   $what" } else { "  FAIL $what"; $script:failures++ }
}

"PowerShell"
$jvm = New-Object -ComObject PascalJavaBridge.JVM
# PowerShell reads and writes COM properties only with type info: call them as methods
if ($JvmPath) { [void]$jvm.JvmPath($JvmPath) }
[void]$jvm.Start($ClassPath, "-Xcheck:jni")
Check $jvm.Running() "Running()"

$list = $jvm.New("java.util.ArrayList")
[void]$list.add(42)
[void]$list.add("x")
Check ($list.size() -eq 2) "ArrayList.add/size"
Check ($list.get(1) -eq "x") "get"
Check ($jvm.Static("java.lang.Math").max(3, 7) -eq 7) "static method"
Check ($jvm.Static("java.lang.Integer").MAX_VALUE() -eq 2147483647) "static field, read as a method"
Check ($jvm.Static("java.lang.String").format("%d-%s", 5, "x") -eq "5-x") "varargs"
$squares = $jvm.New("demo.Torture").squares(4)
Check ($squares[3] -eq 9) "int[] -> array"

$msg = ""
try { $jvm.New("demo.Torture").fail("boom") } catch { $msg = $_.Exception.Message }
Check ($msg -like "*boom*") "Java exception -> PowerShell exception ($msg)"

""
if ($failures -eq 0) { "ALL TESTS PASSED" } else { "$failures TEST(S) FAILED" }
exit $failures
