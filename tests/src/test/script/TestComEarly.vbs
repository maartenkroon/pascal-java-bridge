' Tests the generated COM server PascalJavaBridge.JDemo (JDemoComServer.dll, registered) from
' VBScript, which goes through IDispatch and the type library.
' Usage: cscript //nologo TestComEarly.vbs <classpath> <path of jvm.dll>
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

Dim e, t, l, item, sum, msg
Set e = CreateObject("PascalJavaBridge.JDemo")
WScript.Echo "VBScript (type library)"
e.JvmPath = WScript.Arguments(1)
Call Check(e.Start(WScript.Arguments(0), Array("-Xcheck:jni")), "Start")
Call Check(e.Greeter.add(40, 2) = 42, "static method")
Set t = e.Torture.New()
t.counter_1 = 3
Call Check(t.counter_1 = 3 And t.counter() = 4, "property put/get")
Call Check(t.over_3(1) = "int", "overload by unique name")
Dim b : Set b = t.self()
Call Check(b.over_3(1) = "int", "Base result is a Torture (run-time class)")
Set l = e.ArrayList.New()
l.add 1 : l.add 2 : l.add 3
sum = 0
For Each item In l
  sum = sum + item
Next
Call Check(sum = 6, "For Each (_NewEnum)")
Call Check(CStr(l) = "[1, 2, 3]", "default member is toString")
Call Check(l.get(2) = 3, "VARIANT result")
On Error Resume Next
t.fail "boom"
msg = Err.Source & ": " & Err.Description
On Error GoTo 0
Call Check(InStr(msg, "java.lang.IllegalStateException") = 1, "Java exception (" & msg & ")")

WScript.Echo
If failures = 0 Then
  WScript.Echo "ALL TESTS PASSED"
Else
  WScript.Echo failures & " TEST(S) FAILED"
End If
WScript.Quit failures
