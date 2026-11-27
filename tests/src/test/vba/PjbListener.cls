' A demo.CallbackHost.Listener implemented in VBA (typed callback interface of JDemo).
Option Compare Database
Option Explicit

Implements JDemo.IJCallbackHost_ListenerCallbackDisp

Public Log As String

Private Sub IJCallbackHost_ListenerCallbackDisp_onEvent(ByVal p0 As String, ByVal p1 As Long)
    Log = Log & p0 & "=" & p1 & ";"
End Sub
