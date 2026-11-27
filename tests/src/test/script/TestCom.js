// Tests the registered COM server PascalJavaBridge.JVM from JScript.
// Usage: cscript //nologo TestCom.js <classpath> [<path of jvm.dll>]
// (register first: regsvr32 /n /i:user PascalJavaBridgeCom.dll)
var failures = 0;

function check(cond, what) {
  WScript.Echo((cond ? "  ok   " : "  FAIL ") + what);
  if (!cond) failures++;
}

var args = WScript.Arguments;
var jvm = new ActiveXObject("PascalJavaBridge.JVM");
WScript.Echo("JScript");
if (args.length > 1) jvm.JvmPath = args(1);
// Start is a no-op when another script in this process already started the JVM
jvm.Start(args(0), "-Xcheck:jni");
check(jvm.Running, "Running");

var list = jvm.New("java.util.ArrayList");
list.add(1); list.add(2); list.add(3);
check(list.size() == 3, "ArrayList.add/size");
var sum = 0;
for (var en = new Enumerator(list); !en.atEnd(); en.moveNext()) sum += en.item();
check(sum == 6, "Enumerator (For Each)");
check(jvm.Static("java.lang.Math").max(1.5, 2) == 2, "static method with double");

var squares = new VBArray(jvm.New("demo.Torture").squares(3)).toArray();
check(squares.join(",") == "0,1,4", "int[] -> VBArray");

var f = jvm.Implement("java.util.function.Function", function (x) { return x + "!"; });
check(jvm.Static("demo.CallbackHost").applyTwice(f, "hi") == "hi!!", "JScript function as java.util.function.Function");

var msg = "";
try {
  jvm.New("demo.Torture").fail("boom");
} catch (e) {
  msg = e.message;
}
check(msg.indexOf("boom") >= 0, "Java exception -> JScript exception (" + msg + ")");

WScript.Echo("");
WScript.Echo(failures == 0 ? "ALL TESTS PASSED" : failures + " TEST(S) FAILED");
WScript.Quit(failures);
