# Tests the generated COM server PascalJavaBridge.JDemo (JDemoComServer.dll, registered) from
# Windows PowerShell (properties through the type library) and from C#, early bound: the
# registered .tlb is converted to an interop assembly (what tlbimp does) and C# calls the dual
# interfaces through their vtables.
# Usage: powershell -NoProfile -File TestComEarly.ps1 <classpath> <jvm.dll> <JDemoComServer.tlb>
param([string]$ClassPath, [string]$JvmPath, [string]$TypeLib)
$failures = 0
function Check($cond, $what) {
    if ($cond) { "  ok   $what" } else { "  FAIL $what"; $script:failures++ }
}

"PowerShell (type library)"
$e = New-Object -ComObject PascalJavaBridge.JDemo
$e.JvmPath = $JvmPath
Check ($e.JvmPath -eq $JvmPath) "property put/get on the entry"
[void]$e.Start($ClassPath, "-Xcheck:jni")
Check $e.Running "Running (property)"
$t = $e.Torture.New()
Check ($t.counter_1 -eq 41) "field as property"
$t.counter_1 = 5
Check ($t.counter() -eq 6) "property put"
Check ($e.Integer -eq $null) "no member for unwrapped classes"
Check ($t.over_3(1) -eq "int") "overload by unique name"
$l = $e.ArrayList.New()
[void]$l.add(1); [void]$l.add(2); [void]$l.add(3)
Check ((($l | ForEach-Object { $_ }) | Measure-Object -Sum).Sum -eq 6) "pipeline enumeration (_NewEnum)"
Check (($t | Get-Member -Name counter_1).Definition -like "int counter_1*") "typed members (Get-Member)"
$msg = ""
try { $t.fail("boom") } catch { $msg = $_.Exception.Message }
Check ($msg -like "*boom*") "Java exception ($msg)"

"C# (early bound through an interop assembly)"
$dir = Join-Path ([IO.Path]::GetTempPath()) ("pjb-interop-" + [Guid]::NewGuid())
New-Item -ItemType Directory $dir | Out-Null
try {
    Add-Type -TypeDefinition @"
using System;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class PjbTlbConv {
    [DllImport("oleaut32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void LoadTypeLibEx(string file, int regkind, out ITypeLib lib);
    class Sink : ITypeLibImporterNotifySink {
        public void ReportEvent(ImporterEventKind kind, int code, string msg) { }
        public Assembly ResolveRef(object typeLib) { return null; }
    }
    public static void Convert(string tlb, string dll) {
        ITypeLib lib;
        LoadTypeLibEx(tlb, 2, out lib);
        var ab = new TypeLibConverter().ConvertTypeLibToAssembly(lib, dll, TypeLibImporterFlags.None,
            new Sink(), null, null, "JDemoInterop", null);
        ab.Save(System.IO.Path.GetFileName(dll));
    }
}
"@
    $interop = Join-Path $dir "JDemoInterop.dll"
    [PjbTlbConv]::Convert($TypeLib, $interop)
    Check (Test-Path $interop) "interop assembly from the .tlb"
    Add-Type -ReferencedAssemblies $interop -TypeDefinition @"
using System;
using JDemoInterop;
public static class PjbEarly {
    public static int Run(Action<bool, string> check) {
        var e = (IJDemoEntry)Activator.CreateInstance(Type.GetTypeFromProgID("PascalJavaBridge.JDemo"));
        check(e.Running, "entry through a typed interface");
        IJGreeterClass g = e.Greeter;
        check(g.add(40, 2) == 42, "static method (vtable)");
        IJTortureDisp t = e.Torture.New();
        check(t.over_3(1) == "int" && t.over_2("s") == "String" && t.over(1.5) == "Base.double", "overloads");
        t.counter_1 = 9;
        check(t.counter_1 == 9 && t.counter() == 10, "property");
        check(t.@type() == 1, "keyword member");
        IJBaseDisp b = t.self();
        check(b.who() == "Torture", "wrapped result typed as IJBaseDisp");
        IJListDisp l = t.list("a", "b");
        check(l.size() == 2 && (string)l.@get(1) == "b", "List result, VARIANT element");
        var arr = (Array)t.squares(4);
        check(arr.Length == 4 && (int)arr.GetValue(3) == 9, "int[] as SAFEARRAY");
        check(t.sum(new object[] { 1, 2, 3 }) == 6, "object[] -> int[]");
        IJStringBuilderDisp sb = e.StringBuilder.New_1("ab");
        sb.append("c").append_1(1);
        check(sb.toString() == "abc1", "fluent StringBuilder");
        check(t.over_5(sb) == "StringBuilder", "wrapped argument");
        IJHashMapDisp m = e.HashMap.New();
        m.put("k", 42);
        check((int)m.@get("k") == 42, "HashMap with VARIANTs");
        try { t.fail("boom"); check(false, "exception"); }
        catch (System.Runtime.InteropServices.COMException ex) { check(ex.Message.Contains("boom"), "Java exception -> COMException"); }
        return 0;
    }
}
"@
    # output of a script block called as a .NET delegate does not reach the pipeline: Write-Host
    [void][PjbEarly]::Run([Action[bool, string]] {
        param($c, $w)
        if ($c) { Write-Host "  ok   $w" } else { Write-Host "  FAIL $w"; $script:failures++ }
    })
} finally {
    Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
}

""
if ($failures -eq 0) { "ALL TESTS PASSED" } else { "$failures TEST(S) FAILED" }
exit $failures
