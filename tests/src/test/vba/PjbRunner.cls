' A java.lang.Runnable implemented in VBA (typed callback interface of JDemo).
Option Compare Database
Option Explicit

Implements JDemo.IJRunnableCallbackDisp

Public Calls As Long

Private Sub IJRunnableCallbackDisp_run()
    Calls = Calls + 1
End Sub
