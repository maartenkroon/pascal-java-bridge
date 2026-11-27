' Tests the generated COM server PascalJavaBridge.JDemo from VBA, early bound: the project
' references the registered JDemoComServer.tlb (library JDemo). TestVba.ps1 puts this module and
' the class modules PjbRunner and PjbListener into a temporary Access database and calls
' PjbRunTests, which returns the report.
Option Compare Database
Option Explicit

Private failures As Long
Private report As String

Private Sub Check(ByVal cond As Boolean, ByVal what As String)
    If cond Then
        report = report & "  ok   " & what & vbCrLf
    Else
        report = report & "  FAIL " & what & vbCrLf
        failures = failures + 1
    End If
End Sub

Public Function PjbRunTests(ByVal classPath As String, ByVal jvmPath As String) As String
    Dim e As JDemo.IJDemoEntry
    Dim t As JDemo.IJTortureDisp
    Dim b As JDemo.IJBaseDisp
    Dim al As JDemo.IJArrayListDisp
    Dim li As JDemo.IJListDisp
    Dim host As JDemo.IJCallbackHostDisp
    Dim o As Object
    Dim runner As PjbRunner
    Dim listener As PjbListener
    Dim item As Variant, sq As Variant
    Dim sum As Long
    Dim msg As String, src As String

    failures = 0
#If Win64 Then
    report = "VBA in " & Application.Name & " " & Application.Version & " (64-bit)" & vbCrLf
#Else
    report = "VBA in " & Application.Name & " " & Application.Version & " (32-bit)" & vbCrLf
#End If
    On Error GoTo Unexpected

    ' "Class not registered" here: Access doesn't see the registration (e.g. made from a sandboxed
    ' shell whose registry writes are virtualized; Access is started by COM outside of it)
    Set e = New JDemo.JDemo
    e.JvmPath = jvmPath
    Check e.Start(classPath, "-Xcheck:jni"), "New JDemo.JDemo, Start (early bound)"
    Check e.Running, "Running"
    Check e.Greeter.add(40, 2) = 42, "static method"

    Set t = e.Torture.New
    t.counter_1 = 5
    Check t.counter_1 = 5 And t.counter = 6, "field as property, method of the same name"
    Check t.over_3(1) = "int" And t.over_2("s") = "String" And t.over_4(5) = "long", _
        "overloads by unique name (long as LongLong)"
    Check t.unicode("x") = "x " & ChrW(&HE9) & ChrW(&H4E2D) & ChrW(&HD83D) & ChrW(&HDE00), "Unicode"
    sq = t.squares(4)
    Check UBound(sq) = 3 And sq(3) = 9, "int[] result as array"
    Check t.sum(Array(1, 2, 3)) = 6, "array argument"

    Set b = t.self
    Check b.who = "Torture", "wrapped result, virtual dispatch"
    Check TypeOf b Is JDemo.IJTortureDisp, "Base result is a Torture (TypeOf ... Is)"

    Set al = e.ArrayList.New
    al.add 1
    al.add 2
    al.add 3
    sum = 0
    For Each item In al
        sum = sum + item
    Next
    Check sum = 6, "For Each (_NewEnum)"
    Check CStr(al) = "[1, 2, 3]", "default member is toString"
    Set li = al
    Check li.size = 3 And li.indexOf(2) = 1, "ArrayList as IJListDisp (Set li = al)"

    Set o = t
    Check o.over_3(1) = "int", "late binding (As Object)"

    On Error Resume Next
    t.fail "boom"
    msg = Err.Description
    src = Err.Source
    On Error GoTo Unexpected
    Check InStr(msg, "boom") > 0 And InStr(src, "java.lang.IllegalStateException") = 1, _
        "Java exception -> VBA error (" & src & ": " & msg & ")"

    Set runner = New PjbRunner
    Check e.CallbackHost.runCatching(e.Runnable.Implement(runner)) = "no exception", _
        "Implements IJRunnableCallbackDisp"
    Check runner.Calls = 1, "VBA class called through the vtable"
    Set listener = New PjbListener
    Set host = e.CallbackHost.New
    host.addListener e.CallbackHost_Listener.Implement(listener)
    host.fire "x", 5
    Check listener.Log = "x=5;", "typed Listener, called from Java"

    If failures = 0 Then
        report = report & vbCrLf & "ALL TESTS PASSED"
    Else
        report = report & vbCrLf & failures & " TEST(S) FAILED"
    End If
    PjbRunTests = report
    Exit Function

Unexpected:
    PjbRunTests = report & "UNEXPECTED " & Err.Number & ": " & Err.Source & ": " & Err.Description _
        & vbCrLf & vbCrLf & (failures + 1) & " TEST(S) FAILED"
End Function
