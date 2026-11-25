program RawJniDemo;

{ Embeds a JVM inside this Free Pascal process via the JNI Invocation API
  and calls Java methods directly (no IPC). }

{$mode objfpc}{$H+}

uses
  SysUtils, Math, dynlibs, jni;

type
  TJNI_CreateJavaVM = function(vm: PPJavaVM; env: PPJNIEnv; args: Pointer): jint; cdecl;

var
  JvmLib: TLibHandle;
  VM: PJavaVM;
  Env: PJNIEnv;

procedure CheckJava(const What: string);
begin
  if Env^^.ExceptionCheck(Env) <> JNI_FALSE then
  begin
    Env^^.ExceptionDescribe(Env);   // prints the Java stack trace to stderr
    Env^^.ExceptionClear(Env);
    raise Exception.Create('Java exception in ' + What);
  end;
end;

function JStr(const S: UTF8String): jstring;
begin
  Result := Env^^.NewStringUTF(Env, PChar(S));
end;

function PasStr(JS: jstring): UTF8String;
var
  P: PChar;
begin
  P := Env^^.GetStringUTFChars(Env, JS, nil);
  Result := P;
  Env^^.ReleaseStringUTFChars(Env, JS, P);
end;

procedure StartJVM(const LibJvmPath, ClassPath: string);
var
  CreateVM: TJNI_CreateJavaVM;
  Opts: array[0..1] of JavaVMOption;
  Args: JavaVMInitArgs;
  CpOpt: AnsiString;
begin
  JvmLib := LoadLibrary(LibJvmPath);
  if JvmLib = NilHandle then
    raise Exception.Create('Cannot load ' + LibJvmPath);
  CreateVM := TJNI_CreateJavaVM(GetProcAddress(JvmLib, 'JNI_CreateJavaVM'));

  // FPC unmasks FPU exceptions by default; the JVM expects them masked.
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide,
                    exOverflow, exUnderflow, exPrecision]);

  CpOpt := '-Djava.class.path=' + ClassPath;
  Opts[0].optionString := PChar(CpOpt);
  Opts[0].extraInfo := nil;
  Opts[1].optionString := '-Xss4m';
  Opts[1].extraInfo := nil;

  FillChar(Args, SizeOf(Args), 0);
  Args.version := JNI_VERSION_1_6;   // fine for any modern JDK
  Args.nOptions := Length(Opts);
  Args.options := @Opts[0];
  Args.ignoreUnrecognized := nil;    // = JNI_FALSE (declared as pointer in FPC's jni.pas)

  if CreateVM(@VM, @Env, @Args) <> JNI_OK then
    raise Exception.Create('JNI_CreateJavaVM failed');
end;

const
  Iterations = 10000000;
var
  Cls: jclass;
  MAdd, MGreet, MCtor, MDecorate: jmethodID;
  A: array[0..1] of jvalue;
  Obj: jobject;
  Res: jobject;
  I, Sum: jint;
  T0: QWord;
begin
  StartJVM(GetEnvironmentVariable('JAVA_HOME') + '/lib/server/libjvm.so',
           ExtractFilePath(ParamStr(0)) + '../java');

  Cls := Env^^.FindClass(Env, 'demo/Greeter');
  CheckJava('FindClass');

  // Look up method IDs once and cache them: lookups are slow, calls are fast.
  MAdd      := Env^^.GetStaticMethodID(Env, Cls, 'add', '(II)I');
  MGreet    := Env^^.GetStaticMethodID(Env, Cls, 'greet', '(Ljava/lang/String;)Ljava/lang/String;');
  MCtor     := Env^^.GetMethodID(Env, Cls, '<init>', '(Ljava/lang/String;)V');
  MDecorate := Env^^.GetMethodID(Env, Cls, 'decorate', '(Ljava/lang/String;)Ljava/lang/String;');
  CheckJava('GetMethodID');

  // 1. Static method with primitives
  A[0].i := 40; A[1].i := 2;
  WriteLn('add(40, 2) = ', Env^^.CallStaticIntMethodA(Env, Cls, MAdd, @A[0]));

  // 2. Static method with strings
  A[0].l := JStr('Free Pascal');
  Res := Env^^.CallStaticObjectMethodA(Env, Cls, MGreet, @A[0]);
  CheckJava('greet');
  WriteLn(PasStr(Res));
  Env^^.DeleteLocalRef(Env, A[0].l);
  Env^^.DeleteLocalRef(Env, Res);

  // 3. Create an object and call an instance method
  A[0].l := JStr('>> ');
  Obj := Env^^.NewObjectA(Env, Cls, MCtor, @A[0]);
  CheckJava('new Greeter');
  Env^^.DeleteLocalRef(Env, A[0].l);
  A[0].l := JStr('decorated');
  Res := Env^^.CallObjectMethodA(Env, Obj, MDecorate, @A[0]);
  CheckJava('decorate');
  WriteLn(PasStr(Res));
  Env^^.DeleteLocalRef(Env, A[0].l);
  Env^^.DeleteLocalRef(Env, Res);
  Env^^.DeleteLocalRef(Env, Obj);

  // 4. Call overhead benchmark
  Sum := 0;
  T0 := GetTickCount64;
  for I := 1 to Iterations do
  begin
    A[0].i := Sum; A[1].i := 1;
    Sum := Env^^.CallStaticIntMethodA(Env, Cls, MAdd, @A[0]);
  end;
  WriteLn(Format('%d calls in %d ms  (~%.1f ns/call), sum=%d',
    [Iterations, GetTickCount64 - T0,
     (GetTickCount64 - T0) * 1e6 / Iterations, Sum]));

  VM^^.DestroyJavaVM(VM);
end.
