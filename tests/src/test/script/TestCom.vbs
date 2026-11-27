' Tests the registered COM server PascalJavaBridge.JVM from VBScript.
' Usage: cscript //nologo TestCom.vbs <classpath> [<path of jvm.dll>]
' (register first: regsvr32 /n /i:user PascalJavaBridgeCom.dll)
Option Explicit

Dim failures : failures = 0

Sub Check(cond, what)
  If cond Then
    WScript.Echo "  ok   " & what
  Else
    WScript.Echo "  FAIL " & what
    failures = failures + 1
  End If
End Sub

Class Runner
  Public Count
  Public Sub run()
    Count = Count + 1
  End Sub
End Class

Function CompareLength(a, b)
  CompareLength = Len(a) - Len(b)
End Function

Dim jvm, list, sb, t, item, sum, arr, r, host, e
Set jvm = CreateObject("PascalJavaBridge.JVM")
WScript.Echo "VBScript"
If WScript.Arguments.Count > 1 Then jvm.JvmPath = WScript.Arguments(1)
Call Check(jvm.Start(WScript.Arguments(0), Array("-Xcheck:jni")), "Start")
Call Check(jvm.Running, "Running")

Set list = jvm.New("java.util.ArrayList")
list.add 42
list.add "x"
Call Check(list.size = 2, "ArrayList.add/size")
Call Check(list.get(0) = 42 And list.get(1) = "x", "get")
Call Check(list(1) = "x", "default member: list(1)")
list(1) = "y"
Call Check(list.get(1) = "y", "default member put: list(1) = ...")
Call Check(CStr(list) = "[42, y]", "default member: toString")

sum = 0
For Each item In list.subList(0, 1)
  sum = sum + item
Next
Call Check(sum = 42, "For Each")

Set sb = jvm.New("java.lang.StringBuilder", "ab")
sb.append(1).append(2.5).append(True)
Call Check(sb.toString() = "ab12.5true", "fluent StringBuilder, overloads")
Call Check(jvm.Static("java.lang.Math").max(3, 7) = 7, "static method")
Call Check(jvm.Static("java.lang.Integer").MAX_VALUE = 2147483647, "static field")
Call Check(jvm.Static("java.lang.String").format("%d-%s", 5, "x") = "5-x", "varargs")

Set t = jvm.New("demo.Torture")
arr = t.squares(4)
Call Check(UBound(arr) = 3 And arr(3) = 9, "int[] -> VBScript array")
Call Check(t.sum(Array(1, 2, 3)) = 6, "VBScript array -> int[]")
t.counter = 5
Call Check(t.counter = 5, "field put/get")
Call Check(jvm.New("java.io.File", "C:\x.txt").Name = "x.txt", "getter as property")

On Error Resume Next
t.fail "boom"
e = Err.Source & ": " & Err.Description
On Error GoTo 0
Call Check(InStr(e, "java.lang.IllegalStateException") = 1 And InStr(e, "boom") > 0, _
  "Java exception -> VBScript error (" & e & ")")

Set r = New Runner
r.Count = 0
Set host = jvm.Static("demo.CallbackHost")
Call Check(host.runCatching(jvm.Implement("java.lang.Runnable", r)) = "no exception", _
  "Runnable implemented by a VBScript class")
Call Check(r.Count = 1, "VBScript method called")
Set list = jvm.New("java.util.ArrayList")
list.add "ccc" : list.add "a" : list.add "bb"
list.sort jvm.Implement("java.util.Comparator", GetRef("CompareLength"))
Call Check(CStr(list) = "[a, bb, ccc]", "Comparator from GetRef")

WScript.Echo
If failures = 0 Then
  WScript.Echo "ALL TESTS PASSED"
Else
  WScript.Echo failures & " TEST(S) FAILED"
End If
WScript.Quit failures
