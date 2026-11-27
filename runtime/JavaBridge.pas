{ JavaBridge - runtime support for generated Java wrappers.

  Embeds (or attaches to) a JVM through JNI and provides the helpers that the
  generated binding units call. Compiles with Free Pascal (any mode; the unit
  switches itself to Delphi mode) and with Delphi.

  Naming rules (so generated units can never collide with this unit):
    * public helpers used by generated code start with "Jr"
    * public types start with "TJava", "IJava", "EJava", "j" (JNI types) or "jk"
    * public routines meant for users start with "Java"
}
unit JavaBridge;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ELSE}
  { CreateFromLocal/CreateFromGlobal: only relevant for C++Builder }
  {$WARN DUPLICATE_CTOR_DTOR OFF}
{$ENDIF}

interface

uses
  {$IFDEF FPC}
  SysUtils, SyncObjs;
  {$ELSE}
  System.SysUtils, System.SyncObjs;
  {$ENDIF}

{ ---------------------------------------------------------------------------
  JNI basic types
  --------------------------------------------------------------------------- }
type
  jboolean = Byte;
  jbyte    = ShortInt;
  jchar    = Word;
  jshort   = SmallInt;
  jint     = Integer;
  jlong    = Int64;
  jfloat   = Single;
  jdouble  = Double;
  jsize    = jint;

  jobject    = Pointer;
  jclass     = jobject;
  jstring    = jobject;
  jarray     = jobject;
  jthrowable = jobject;
  jmethodID  = Pointer;
  jfieldID   = Pointer;

  Pjvalue = ^jvalue;
  jvalue = record
    case Integer of
      0: (z: jboolean);
      1: (b: jbyte);
      2: (c: jchar);
      3: (s: jshort);
      4: (i: jint);
      5: (j: jlong);
      6: (f: jfloat);
      7: (d: jdouble);
      8: (l: jobject);
  end;

  { JNIEnv / JavaVM are pointers to a pointer to a function table. We index the
    table directly instead of declaring all ~235 entries. }
  TJavaFuncTable = array[0..511] of Pointer;
  PJavaFuncTable = ^TJavaFuncTable;
  PJNIEnv  = ^PJavaFuncTable;
  PPJNIEnv = ^PJNIEnv;
  PJavaVM  = ^PJavaFuncTable;
  PPJavaVM = ^PJavaVM;

  { Kind of a Java value; used by the generic call / field helpers. }
  TJavaKind = (jkObject, jkBoolean, jkByte, jkChar, jkShort, jkInt, jkLong,
               jkFloat, jkDouble, jkVoid);

{ ---------------------------------------------------------------------------
  Array types used in generated signatures
  --------------------------------------------------------------------------- }
type
  IJavaObject = interface;

  TJavaBooleanArray = array of Boolean;
  TJavaByteArray    = array of ShortInt;
  TJavaCharArray    = array of WideChar;
  TJavaShortArray   = array of SmallInt;
  TJavaIntArray     = array of Integer;
  TJavaLongArray    = array of Int64;
  TJavaFloatArray   = array of Single;
  TJavaDoubleArray  = array of Double;
  TJavaStringArray  = array of UnicodeString;
  TJavaObjectArray  = array of IJavaObject;

{ ---------------------------------------------------------------------------
  Object model
  --------------------------------------------------------------------------- }

  { Root of every generated wrapper interface. Intentionally has no methods of
    its own, so no Java member name can ever clash with it. }
  IJavaObject = interface(IInterface)
    ['{6B3C2E1A-6F0D-4D2B-9B53-2C3F5A7E1D01}']
  end;

  { Gives access to the underlying JNI global reference. Implemented by every
    wrapper object but deliberately NOT inherited by the generated interfaces.
    Use JavaHandleOf() rather than this interface directly. }
  IJavaHandle = interface(IInterface)
    ['{6B3C2E1A-6F0D-4D2B-9B53-2C3F5A7E1D02}']
    function JavaGlobalRef: jobject;
  end;

  { Base implementation class for all wrappers. Owns one JNI global reference
    which is released when the last Pascal interface reference goes away. }
  TJavaObjectImpl = class(TInterfacedObject, IJavaObject, IJavaHandle)
  private
    FJavaRef: jobject;
  public
    { Takes a *local* reference, converts it to a global one and deletes the
      local reference. Ref must not be nil. }
    constructor CreateFromLocal(Ref: jobject);
    { Takes ownership of an existing *global* reference. }
    constructor CreateFromGlobal(Ref: jobject);
    destructor Destroy; override;
    function JavaGlobalRef: jobject;
  end;
  TJavaObjectImplClass = class of TJavaObjectImpl;

  { Raised when a Java method throws. }
  EJavaException = class(Exception)
  private
    FJavaClassName: UnicodeString;
    FThrowable: IJavaObject;
  public
    constructor CreateJava(const AClassName, AMessage: UnicodeString;
      const AThrowable: IJavaObject);
    { Fully qualified Java class name, e.g. 'java.lang.IllegalStateException'. }
    property JavaClassName: UnicodeString read FJavaClassName;
    { The java.lang.Throwable object; cast it with a generated wrapper's Cast. }
    property Throwable: IJavaObject read FThrowable;
  end;

  { Raised when the JVM cannot be started or a class/member cannot be found. }
  EJavaError = class(Exception);
  { Raised by the generated Cast functions. }
  EJavaCastError = class(EJavaError);

{ ---------------------------------------------------------------------------
  User API
  --------------------------------------------------------------------------- }

{ Loads libjvm and creates a JVM in this process.
  LibJvmPath: full path of libjvm.so / jvm.dll; if empty, it is derived from
  the JAVA_HOME environment variable.
  Options: JVM options, e.g. '-Djava.class.path=...', '-Xmx512m'.
  MaskFPUExceptions: the JVM requires floating point exceptions to be masked.
  When True (recommended) this is done for every thread that calls into Java. }
procedure JavaStartVM(const LibJvmPath: string; const Options: array of string;
  MaskFPUExceptions: Boolean = True);

{ Use an already running JVM, e.g. when this Pascal code is a native library
  loaded by Java (call it from JNI_OnLoad). }
procedure JavaUseVM(VM: PJavaVM; MaskFPUExceptions: Boolean = True);

{ Destroys the JVM started by JavaStartVM. Wrappers still alive afterwards
  are safely released without touching the JVM. }
procedure JavaStopVM;

function JavaVMRunning: Boolean;

{ Detach the calling thread from the JVM. Call this before a thread that used
  Java terminates (threads are attached automatically on first use). }
procedure JavaDetachThread;

{ JNIEnv of the calling thread (attaches the thread if needed). }
function JavaEnv: PJNIEnv;

{ JNI global reference of a wrapper (nil for nil). }
function JavaHandleOf(const Obj: IInterface): jobject;

{ True if both wrappers refer to the same Java object (Java's ==). }
function JavaSameObject(const A, B: IInterface): Boolean;

{ Java class name of the object, e.g. 'java.util.ArrayList'. }
function JavaClassNameOf(const Obj: IInterface): UnicodeString;

{ Wraps a JNI local reference into an untyped wrapper (nil for nil). The
  local reference is deleted. }
function JavaWrapLocal(Ref: jobject): IJavaObject;

{ ---------------------------------------------------------------------------
  Helpers for generated code (names start with Jr)
  --------------------------------------------------------------------------- }
function JrEnv: PJNIEnv;
function JrResolveClass(var Slot: jclass; Name: PAnsiChar): jclass;
function JrResolveMethod(var Slot: jmethodID; var ClassSlot: jclass;
  ClassName, Name, Sig: PAnsiChar; IsStatic: Boolean): jmethodID;
function JrResolveField(var Slot: jfieldID; var ClassSlot: jclass;
  ClassName, Name, Sig: PAnsiChar; IsStatic: Boolean): jfieldID;

function JrCall(Target: jobject; Method: jmethodID; Args: Pjvalue;
  Kind: TJavaKind; IsStatic: Boolean): jvalue;
function JrNewObject(Cls: jclass; Method: jmethodID; Args: Pjvalue): jobject;
function JrGetField(Target: jobject; Field: jfieldID; Kind: TJavaKind;
  IsStatic: Boolean): jvalue;
procedure JrSetField(Target: jobject; Field: jfieldID; Kind: TJavaKind;
  IsStatic: Boolean; const Value: jvalue);

function JrHandle(const Obj: IInterface): jobject;
function JrNewGlobalRef(Ref: jobject): jobject;
procedure JrDeleteLocal(Ref: jobject);
function JrNewString(const S: UnicodeString): jstring;
function JrTakeString(Ref: jstring): UnicodeString;
function JrIsInstance(const Obj: IInterface; Cls: jclass): Boolean;
{ Returns the handle of Obj after checking it is an instance of Cls. }
function JrCheckCast(const Obj: IInterface; Cls: jclass;
  const JavaName: UnicodeString): jobject;

function JrNewBooleanArray(const A: TJavaBooleanArray): jarray;
function JrNewByteArray(const A: TJavaByteArray): jarray;
function JrNewCharArray(const A: TJavaCharArray): jarray;
function JrNewShortArray(const A: TJavaShortArray): jarray;
function JrNewIntArray(const A: TJavaIntArray): jarray;
function JrNewLongArray(const A: TJavaLongArray): jarray;
function JrNewFloatArray(const A: TJavaFloatArray): jarray;
function JrNewDoubleArray(const A: TJavaDoubleArray): jarray;
function JrNewStringArray(const A: TJavaStringArray): jarray;
function JrNewObjectArray(const A: TJavaObjectArray; ElementClass: jclass): jarray;

function JrTakeBooleanArray(Ref: jarray): TJavaBooleanArray;
function JrTakeByteArray(Ref: jarray): TJavaByteArray;
function JrTakeCharArray(Ref: jarray): TJavaCharArray;
function JrTakeShortArray(Ref: jarray): TJavaShortArray;
function JrTakeIntArray(Ref: jarray): TJavaIntArray;
function JrTakeLongArray(Ref: jarray): TJavaLongArray;
function JrTakeFloatArray(Ref: jarray): TJavaFloatArray;
function JrTakeDoubleArray(Ref: jarray): TJavaDoubleArray;
function JrTakeStringArray(Ref: jarray): TJavaStringArray;
function JrTakeObjectArray(Ref: jarray): TJavaObjectArray;

{ ---------------------------------------------------------------------------
  Callbacks (Java -> Pascal)
  --------------------------------------------------------------------------- }
type
  { Generated per Java interface: calls method AIndex of the Pascal callback
    ATarget with the boxed Java arguments AArgs; returns a (local) Java
    reference or boxed primitive, or nil. }
  TJavaDispatchFunc = function(const ATarget: IInterface; AIndex: Integer;
    AArgs: jarray): jobject;

{ Creates a java.lang.reflect.Proxy implementing IfaceClass whose abstract
  methods (listed in Sigs as 'name(descriptor)' lines, in dispatch order) are
  forwarded to Dispatch(Callback, ...). Returns a local reference. }
function JrCreateProxy(IfaceClass: jclass; const Callback: IInterface;
  Dispatch: TJavaDispatchFunc; Sigs: PAnsiChar): jobject;
{ Element Index of the argument array: unboxed for primitive kinds, a local
  reference for jkObject. }
function JrArgValue(Args: jarray; Index: Integer; Kind: TJavaKind): jvalue;
{ Boxes a primitive (Integer.valueOf etc.); returns a local reference. }
function JrBox(const Value: jvalue; Kind: TJavaKind): jobject;
function JrNewLocalRef(Ref: jobject): jobject;

{ Number of Pascal callback objects currently referenced from Java. They are
  released (on Java's Cleaner thread) after Java garbage-collects the proxy. }
function JavaCallbackCount: Integer;

implementation

uses
  {$IFDEF FPC}
  Math, dynlibs;
  {$ELSE}
  System.Math
  {$IFDEF MSWINDOWS}, Winapi.Windows{$ENDIF};
  {$ENDIF}

const
  JNI_OK = 0;
  JNI_EDETACHED = -2;
  JNI_VERSION_10 = $000A0000;

  { Indices in the JNINativeInterface function table (see jni.h). }
  FN_FindClass            = 6;
  FN_ExceptionOccurred    = 15;
  FN_ExceptionClear       = 17;
  FN_NewGlobalRef         = 21;
  FN_DeleteGlobalRef      = 22;
  FN_DeleteLocalRef       = 23;
  FN_IsSameObject         = 24;
  FN_NewObjectA           = 30;
  FN_GetObjectClass       = 31;
  FN_IsInstanceOf         = 32;
  FN_GetMethodID          = 33;
  FN_CallObjectMethodA    = 36;   { + 3 * kind }
  FN_GetFieldID           = 94;
  FN_GetObjectField       = 95;   { + kind }
  FN_SetObjectField       = 104;  { + kind }
  FN_GetStaticMethodID    = 113;
  FN_CallStaticObjectMethodA = 116; { + 3 * kind }
  FN_GetStaticFieldID     = 144;
  FN_GetStaticObjectField = 145;  { + kind }
  FN_SetStaticObjectField = 154;  { + kind }
  FN_NewString            = 163;
  FN_GetStringLength      = 164;
  FN_GetArrayLength       = 171;
  FN_NewObjectArray       = 172;
  FN_GetObjectArrayElement = 173;
  FN_SetObjectArrayElement = 174;
  FN_NewBooleanArray      = 175;  { + kind - 1 }
  FN_GetBooleanArrayRegion = 199; { + kind - 1 }
  FN_SetBooleanArrayRegion = 207; { + kind - 1 }
  FN_GetStringRegion      = 220;
  FN_ExceptionCheck       = 228;
  FN_DefineClass          = 5;
  FN_Throw                = 13;
  FN_ThrowNew             = 14;
  FN_NewLocalRef          = 25;
  FN_NewStringUTF         = 167;
  FN_RegisterNatives      = 215;

  { Indices in the JNIInvokeInterface function table. }
  VMFN_DestroyJavaVM       = 3;
  VMFN_AttachCurrentThread = 4;
  VMFN_DetachCurrentThread = 5;
  VMFN_GetEnv              = 6;
  VMFN_AttachCurrentThreadAsDaemon = 7;

type
  TJavaVMOption = record
    optionString: PAnsiChar;
    extraInfo: Pointer;
  end;
  TJavaVMInitArgs = record
    version: jint;
    nOptions: jint;
    options: ^TJavaVMOption;
    ignoreUnrecognized: jboolean;
  end;

  TFnCreateJavaVM = function(vm: PPJavaVM; env: PPJNIEnv; args: Pointer): jint; {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnVM_Simple    = function(vm: PJavaVM): jint; {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnVM_Attach    = function(vm: PJavaVM; penv: PPJNIEnv; args: Pointer): jint; {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnVM_GetEnv    = function(vm: PJavaVM; penv: PPJNIEnv; version: jint): jint; {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};

  TFnFindClass     = function(env: PJNIEnv; name: PAnsiChar): jclass; {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnEnvOnly_Obj   = function(env: PJNIEnv): jobject; {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnEnvOnly       = procedure(env: PJNIEnv); {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnEnvOnly_Bool  = function(env: PJNIEnv): jboolean; {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnObj_Obj       = function(env: PJNIEnv; obj: jobject): jobject; {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnObj           = procedure(env: PJNIEnv; obj: jobject); {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnObjObj_Bool   = function(env: PJNIEnv; a, b: jobject): jboolean; {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnGetMember     = function(env: PJNIEnv; cls: jclass; name, sig: PAnsiChar): Pointer; {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnObj_Int       = function(env: PJNIEnv; obj: jobject): jint; {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};

  TFnCallObject  = function(env: PJNIEnv; obj: jobject; m: jmethodID; args: Pjvalue): jobject;  {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnCallBoolean = function(env: PJNIEnv; obj: jobject; m: jmethodID; args: Pjvalue): jboolean; {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnCallByte    = function(env: PJNIEnv; obj: jobject; m: jmethodID; args: Pjvalue): jbyte;    {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnCallChar    = function(env: PJNIEnv; obj: jobject; m: jmethodID; args: Pjvalue): jchar;    {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnCallShort   = function(env: PJNIEnv; obj: jobject; m: jmethodID; args: Pjvalue): jshort;   {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnCallInt     = function(env: PJNIEnv; obj: jobject; m: jmethodID; args: Pjvalue): jint;     {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnCallLong    = function(env: PJNIEnv; obj: jobject; m: jmethodID; args: Pjvalue): jlong;    {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnCallFloat   = function(env: PJNIEnv; obj: jobject; m: jmethodID; args: Pjvalue): jfloat;   {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnCallDouble  = function(env: PJNIEnv; obj: jobject; m: jmethodID; args: Pjvalue): jdouble;  {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnCallVoid    = procedure(env: PJNIEnv; obj: jobject; m: jmethodID; args: Pjvalue);         {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};

  TFnGetObject  = function(env: PJNIEnv; obj: jobject; f: jfieldID): jobject;  {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnGetBoolean = function(env: PJNIEnv; obj: jobject; f: jfieldID): jboolean; {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnGetByte    = function(env: PJNIEnv; obj: jobject; f: jfieldID): jbyte;    {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnGetChar    = function(env: PJNIEnv; obj: jobject; f: jfieldID): jchar;    {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnGetShort   = function(env: PJNIEnv; obj: jobject; f: jfieldID): jshort;   {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnGetInt     = function(env: PJNIEnv; obj: jobject; f: jfieldID): jint;     {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnGetLong    = function(env: PJNIEnv; obj: jobject; f: jfieldID): jlong;    {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnGetFloat   = function(env: PJNIEnv; obj: jobject; f: jfieldID): jfloat;   {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnGetDouble  = function(env: PJNIEnv; obj: jobject; f: jfieldID): jdouble;  {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};

  TFnSetObject  = procedure(env: PJNIEnv; obj: jobject; f: jfieldID; v: jobject);  {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnSetBoolean = procedure(env: PJNIEnv; obj: jobject; f: jfieldID; v: jboolean); {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnSetByte    = procedure(env: PJNIEnv; obj: jobject; f: jfieldID; v: jbyte);    {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnSetChar    = procedure(env: PJNIEnv; obj: jobject; f: jfieldID; v: jchar);    {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnSetShort   = procedure(env: PJNIEnv; obj: jobject; f: jfieldID; v: jshort);   {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnSetInt     = procedure(env: PJNIEnv; obj: jobject; f: jfieldID; v: jint);     {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnSetLong    = procedure(env: PJNIEnv; obj: jobject; f: jfieldID; v: jlong);    {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnSetFloat   = procedure(env: PJNIEnv; obj: jobject; f: jfieldID; v: jfloat);   {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnSetDouble  = procedure(env: PJNIEnv; obj: jobject; f: jfieldID; v: jdouble);  {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};

  TFnNewString       = function(env: PJNIEnv; chars: PWideChar; len: jsize): jstring; {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnGetStringRegion = procedure(env: PJNIEnv; s: jstring; start, len: jsize; buf: PWideChar); {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnNewPrimArray    = function(env: PJNIEnv; len: jsize): jarray; {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnArrayRegion     = procedure(env: PJNIEnv; arr: jarray; start, len: jsize; buf: Pointer); {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnNewObjectArray  = function(env: PJNIEnv; len: jsize; cls: jclass; init: jobject): jarray; {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnGetObjArrayElem = function(env: PJNIEnv; arr: jarray; index: jsize): jobject; {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnSetObjArrayElem = procedure(env: PJNIEnv; arr: jarray; index: jsize; v: jobject); {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnDefineClass     = function(env: PJNIEnv; name: PAnsiChar; loader: jobject; buf: Pointer; len: jsize): jclass; {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnThrow           = function(env: PJNIEnv; obj: jthrowable): jint; {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnThrowNew        = function(env: PJNIEnv; cls: jclass; msg: PAnsiChar): jint; {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TFnNewStringUTF    = function(env: PJNIEnv; s: PAnsiChar): jstring; {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
  TJavaNativeMethod = record
    name: PAnsiChar;
    signature: PAnsiChar;
    fnPtr: Pointer;
  end;
  TFnRegisterNatives = function(env: PJNIEnv; cls: jclass; methods: Pointer; n: jint): jint; {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};

  { Owned by the Java proxy; freed by release0 when the proxy is collected. }
  TJavaCallbackBinding = class
    Target: IInterface;
    Dispatch: TJavaDispatchFunc;
  end;

var
  GVM: PJavaVM = nil;
  GVMRunning: Boolean = False;
  GOwnsVM: Boolean = False;
  GMaskFPU: Boolean = True;
  GLock: TCriticalSection = nil;
  {$IFDEF FPC}
  GLib: TLibHandle = NilHandle;
  {$ELSE}
  GLib: HMODULE = 0;
  {$ENDIF}

  { cached for exception handling }
  GClsObject, GClsClass, GClsString: jclass;

  { callbacks }
  GHandlerCls: jclass;
  GMidCreateProxy: jmethodID;
  GClsRuntimeException: jclass;
  GCallbackCount: Integer = 0;
  GBoxCls: array[TJavaKind] of jclass;
  GBoxValueOf, GBoxUnbox: array[TJavaKind] of jmethodID;
  GMidToString, GMidGetClass, GMidGetName: jmethodID;

threadvar
  TEnv: PJNIEnv;

{ ---------------------------------------------------------------------------
  Thread / VM handling
  --------------------------------------------------------------------------- }

procedure MaskFPU;
begin
  {$IFDEF FPC}
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow,
    exUnderflow, exPrecision]);
  {$ELSE}
  SetExceptionMask(exAllArithmeticExceptions);
  {$ENDIF}
end;

function AttachThread: PJNIEnv;
var
  Env: PJNIEnv;
  R: jint;
begin
  if not GVMRunning then
    raise EJavaError.Create('Java VM is not running');
  Env := nil;
  R := TFnVM_GetEnv(GVM^^[VMFN_GetEnv])(GVM, @Env, JNI_VERSION_10);
  if R = JNI_EDETACHED then
  begin
    { Attach as daemon: a thread that forgets JavaDetachThread then cannot
      block JavaStopVM (DestroyJavaVM waits for non-daemon threads). }
    if TFnVM_Attach(GVM^^[VMFN_AttachCurrentThreadAsDaemon])(GVM, @Env, nil) <> JNI_OK then
      raise EJavaError.Create('Cannot attach thread to the Java VM');
  end
  else if R <> JNI_OK then
    raise EJavaError.Create('JNI GetEnv failed');
  if GMaskFPU then
    MaskFPU;
  TEnv := Env;
  Result := Env;
end;

function JrEnv: PJNIEnv;
begin
  Result := TEnv;
  if Result = nil then
    Result := AttachThread;
end;

function JavaEnv: PJNIEnv;
begin
  Result := JrEnv;
end;

procedure ClearException(Env: PJNIEnv);
begin
  TFnEnvOnly(Env^^[FN_ExceptionClear])(Env);
end;

function FindClassGlobal(Env: PJNIEnv; Name: PAnsiChar): jclass;
var
  L: jclass;
begin
  L := TFnFindClass(Env^^[FN_FindClass])(Env, Name);
  if L = nil then
  begin
    ClearException(Env);
    raise EJavaError.CreateFmt('Java class not found: %s', [string(AnsiString(Name))]);
  end;
  Result := TFnObj_Obj(Env^^[FN_NewGlobalRef])(Env, L);
  TFnObj(Env^^[FN_DeleteLocalRef])(Env, L);
end;

procedure InitCommon;
var
  Env: PJNIEnv;
  M: TFnGetMember;
begin
  Env := JrEnv;
  GClsObject := FindClassGlobal(Env, 'java/lang/Object');
  GClsClass := FindClassGlobal(Env, 'java/lang/Class');
  GClsString := FindClassGlobal(Env, 'java/lang/String');
  M := TFnGetMember(Env^^[FN_GetMethodID]);
  GMidToString := M(Env, GClsObject, 'toString', '()Ljava/lang/String;');
  GMidGetClass := M(Env, GClsObject, 'getClass', '()Ljava/lang/Class;');
  GMidGetName := M(Env, GClsClass, 'getName', '()Ljava/lang/String;');
end;

function DefaultLibJvmPath: string;
var
  Home: string;
begin
  Home := GetEnvironmentVariable('JAVA_HOME');
  if Home = '' then
    raise EJavaError.Create('JAVA_HOME is not set and no libjvm path was given');
  {$IFDEF MSWINDOWS}
  Result := IncludeTrailingPathDelimiter(Home) + 'bin\server\jvm.dll';
  {$ELSE}
    {$IFDEF DARWIN}
  Result := IncludeTrailingPathDelimiter(Home) + 'lib/server/libjvm.dylib';
    {$ELSE}
  Result := IncludeTrailingPathDelimiter(Home) + 'lib/server/libjvm.so';
    {$ENDIF}
  {$ENDIF}
end;

function LoadJvmSymbol(const Path: string): Pointer;
begin
  {$IFDEF FPC}
  GLib := LoadLibrary(Path);
  if GLib = NilHandle then
    raise EJavaError.CreateFmt('Cannot load %s', [Path]);
  Result := GetProcedureAddress(GLib, 'JNI_CreateJavaVM');
  {$ELSE}
  GLib := SafeLoadLibrary(Path);
  if GLib = 0 then
    raise EJavaError.CreateFmt('Cannot load %s', [Path]);
  Result := GetProcAddress(GLib, 'JNI_CreateJavaVM');
  {$ENDIF}
  if Result = nil then
    raise EJavaError.CreateFmt('JNI_CreateJavaVM not found in %s', [Path]);
end;

procedure JavaStartVM(const LibJvmPath: string; const Options: array of string;
  MaskFPUExceptions: Boolean);
var
  Path: string;
  CreateVM: TFnCreateJavaVM;
  Opts: array of TJavaVMOption;
  OptStr: array of UTF8String;
  Args: TJavaVMInitArgs;
  Env: PJNIEnv;
  I: Integer;
begin
  if GVMRunning then
    raise EJavaError.Create('Java VM already running');
  Path := LibJvmPath;
  if Path = '' then
    Path := DefaultLibJvmPath;
  CreateVM := TFnCreateJavaVM(LoadJvmSymbol(Path));

  GMaskFPU := MaskFPUExceptions;
  if GMaskFPU then
    MaskFPU;

  SetLength(Opts, Length(Options));
  SetLength(OptStr, Length(Options));
  for I := 0 to High(Options) do
  begin
    OptStr[I] := UTF8Encode(UnicodeString(Options[I]));
    Opts[I].optionString := PAnsiChar(OptStr[I]);
    Opts[I].extraInfo := nil;
  end;
  FillChar(Args, SizeOf(Args), 0);
  Args.version := JNI_VERSION_10;
  Args.nOptions := Length(Opts);
  if Length(Opts) > 0 then
    Args.options := @Opts[0];
  Args.ignoreUnrecognized := 0;

  Env := nil;
  if CreateVM(@GVM, @Env, @Args) <> JNI_OK then
    raise EJavaError.Create('JNI_CreateJavaVM failed');
  GVMRunning := True;
  GOwnsVM := True;
  TEnv := Env;
  InitCommon;
end;

procedure JavaUseVM(VM: PJavaVM; MaskFPUExceptions: Boolean);
begin
  GVM := VM;
  GMaskFPU := MaskFPUExceptions;
  GVMRunning := True;
  GOwnsVM := False;
  InitCommon;
end;

procedure JavaStopVM;
begin
  if not GVMRunning then
    Exit;
  GVMRunning := False;
  if GOwnsVM then
    TFnVM_Simple(GVM^^[VMFN_DestroyJavaVM])(GVM);
  GVM := nil;
  TEnv := nil;
end;

function JavaVMRunning: Boolean;
begin
  Result := GVMRunning;
end;

procedure JavaDetachThread;
begin
  if GVMRunning and (TEnv <> nil) then
    TFnVM_Simple(GVM^^[VMFN_DetachCurrentThread])(GVM);
  TEnv := nil;
end;

{ ---------------------------------------------------------------------------
  Exceptions
  --------------------------------------------------------------------------- }

constructor EJavaException.CreateJava(const AClassName, AMessage: UnicodeString;
  const AThrowable: IJavaObject);
begin
  inherited Create(string(AMessage));
  FJavaClassName := AClassName;
  FThrowable := AThrowable;
end;

function SafeToString(Env: PJNIEnv; Obj: jobject; Mid: jmethodID): UnicodeString;
var
  S: jobject;
begin
  Result := '';
  S := TFnCallObject(Env^^[FN_CallObjectMethodA])(Env, Obj, Mid, nil);
  if TFnEnvOnly_Bool(Env^^[FN_ExceptionCheck])(Env) <> 0 then
  begin
    ClearException(Env);
    Exit;
  end;
  Result := JrTakeString(S);
end;

procedure RaisePendingException(Env: PJNIEnv);
var
  T, C: jobject;
  ClsName, Msg: UnicodeString;
  Wrapper: IJavaObject;
begin
  T := TFnEnvOnly_Obj(Env^^[FN_ExceptionOccurred])(Env);
  ClearException(Env);
  ClsName := '';
  C := TFnCallObject(Env^^[FN_CallObjectMethodA])(Env, T, GMidGetClass, nil);
  if TFnEnvOnly_Bool(Env^^[FN_ExceptionCheck])(Env) <> 0 then
    ClearException(Env)
  else if C <> nil then
  begin
    ClsName := SafeToString(Env, C, GMidGetName);
    JrDeleteLocal(C);
  end;
  Msg := SafeToString(Env, T, GMidToString);
  Wrapper := TJavaObjectImpl.CreateFromLocal(T);
  raise EJavaException.CreateJava(ClsName, Msg, Wrapper);
end;

procedure CheckException(Env: PJNIEnv); {$IFDEF FPC}inline;{$ENDIF}
begin
  if TFnEnvOnly_Bool(Env^^[FN_ExceptionCheck])(Env) <> 0 then
    RaisePendingException(Env);
end;

{ ---------------------------------------------------------------------------
  TJavaObjectImpl
  --------------------------------------------------------------------------- }

constructor TJavaObjectImpl.CreateFromLocal(Ref: jobject);
var
  Env: PJNIEnv;
begin
  inherited Create;
  Env := JrEnv;
  FJavaRef := TFnObj_Obj(Env^^[FN_NewGlobalRef])(Env, Ref);
  TFnObj(Env^^[FN_DeleteLocalRef])(Env, Ref);
end;

constructor TJavaObjectImpl.CreateFromGlobal(Ref: jobject);
begin
  inherited Create;
  FJavaRef := Ref;
end;

destructor TJavaObjectImpl.Destroy;
var
  Env: PJNIEnv;
begin
  if (FJavaRef <> nil) and GVMRunning then
  begin
    Env := TEnv;
    if Env <> nil then
      TFnObj(Env^^[FN_DeleteGlobalRef])(Env, FJavaRef)
    else
    begin
      { The calling thread is not attached (e.g. a hidden temporary released
        after JavaDetachThread, or a thread that never used Java). Attach
        briefly, without leaving the thread attached afterwards. }
      if TFnVM_GetEnv(GVM^^[VMFN_GetEnv])(GVM, @Env, JNI_VERSION_10) = JNI_OK then
        TFnObj(Env^^[FN_DeleteGlobalRef])(Env, FJavaRef)
      else if TFnVM_Attach(GVM^^[VMFN_AttachCurrentThreadAsDaemon])(GVM, @Env, nil) = JNI_OK then
      begin
        TFnObj(Env^^[FN_DeleteGlobalRef])(Env, FJavaRef);
        TFnVM_Simple(GVM^^[VMFN_DetachCurrentThread])(GVM);
      end;
    end;
  end;
  FJavaRef := nil;
  inherited Destroy;
end;

function TJavaObjectImpl.JavaGlobalRef: jobject;
begin
  Result := FJavaRef;
end;

{ ---------------------------------------------------------------------------
  Lookups
  --------------------------------------------------------------------------- }

function JrResolveClass(var Slot: jclass; Name: PAnsiChar): jclass;
begin
  Result := Slot;
  if Result <> nil then
    Exit;
  GLock.Acquire;
  try
    if Slot = nil then
      Slot := FindClassGlobal(JrEnv, Name);
    Result := Slot;
  finally
    GLock.Release;
  end;
end;

function JrResolveMethod(var Slot: jmethodID; var ClassSlot: jclass;
  ClassName, Name, Sig: PAnsiChar; IsStatic: Boolean): jmethodID;
var
  Env: PJNIEnv;
  Cls: jclass;
begin
  Result := Slot;
  if Result <> nil then
    Exit;
  Env := JrEnv;
  Cls := JrResolveClass(ClassSlot, ClassName);
  if IsStatic then
    Result := TFnGetMember(Env^^[FN_GetStaticMethodID])(Env, Cls, Name, Sig)
  else
    Result := TFnGetMember(Env^^[FN_GetMethodID])(Env, Cls, Name, Sig);
  if Result = nil then
  begin
    ClearException(Env);
    raise EJavaError.CreateFmt('Java method not found: %s.%s%s',
      [string(AnsiString(ClassName)), string(AnsiString(Name)), string(AnsiString(Sig))]);
  end;
  Slot := Result;   { pointer-sized write; races only store the same value }
end;

function JrResolveField(var Slot: jfieldID; var ClassSlot: jclass;
  ClassName, Name, Sig: PAnsiChar; IsStatic: Boolean): jfieldID;
var
  Env: PJNIEnv;
  Cls: jclass;
begin
  Result := Slot;
  if Result <> nil then
    Exit;
  Env := JrEnv;
  Cls := JrResolveClass(ClassSlot, ClassName);
  if IsStatic then
    Result := TFnGetMember(Env^^[FN_GetStaticFieldID])(Env, Cls, Name, Sig)
  else
    Result := TFnGetMember(Env^^[FN_GetFieldID])(Env, Cls, Name, Sig);
  if Result = nil then
  begin
    ClearException(Env);
    raise EJavaError.CreateFmt('Java field not found: %s.%s',
      [string(AnsiString(ClassName)), string(AnsiString(Name))]);
  end;
  Slot := Result;
end;

{ ---------------------------------------------------------------------------
  Calls and fields
  --------------------------------------------------------------------------- }

function JrCall(Target: jobject; Method: jmethodID; Args: Pjvalue;
  Kind: TJavaKind; IsStatic: Boolean): jvalue;
var
  Env: PJNIEnv;
  F: Pointer;
begin
  Env := JrEnv;
  if Target = nil then
    raise EJavaError.Create('Java method called on a null reference');
  if IsStatic then
    F := Env^^[FN_CallStaticObjectMethodA + 3 * Ord(Kind)]
  else
    F := Env^^[FN_CallObjectMethodA + 3 * Ord(Kind)];
  Result.j := 0;
  case Kind of
    jkObject:  Result.l := TFnCallObject(F)(Env, Target, Method, Args);
    jkBoolean: Result.z := TFnCallBoolean(F)(Env, Target, Method, Args);
    jkByte:    Result.b := TFnCallByte(F)(Env, Target, Method, Args);
    jkChar:    Result.c := TFnCallChar(F)(Env, Target, Method, Args);
    jkShort:   Result.s := TFnCallShort(F)(Env, Target, Method, Args);
    jkInt:     Result.i := TFnCallInt(F)(Env, Target, Method, Args);
    jkLong:    Result.j := TFnCallLong(F)(Env, Target, Method, Args);
    jkFloat:   Result.f := TFnCallFloat(F)(Env, Target, Method, Args);
    jkDouble:  Result.d := TFnCallDouble(F)(Env, Target, Method, Args);
    jkVoid:    TFnCallVoid(F)(Env, Target, Method, Args);
  end;
  CheckException(Env);
end;

function JrNewObject(Cls: jclass; Method: jmethodID; Args: Pjvalue): jobject;
var
  Env: PJNIEnv;
begin
  Env := JrEnv;
  Result := TFnCallObject(Env^^[FN_NewObjectA])(Env, Cls, Method, Args);
  CheckException(Env);
end;

function JrGetField(Target: jobject; Field: jfieldID; Kind: TJavaKind;
  IsStatic: Boolean): jvalue;
var
  Env: PJNIEnv;
  F: Pointer;
begin
  Env := JrEnv;
  if Target = nil then
    raise EJavaError.Create('Java field read on a null reference');
  if IsStatic then
    F := Env^^[FN_GetStaticObjectField + Ord(Kind)]
  else
    F := Env^^[FN_GetObjectField + Ord(Kind)];
  Result.j := 0;
  case Kind of
    jkObject:  Result.l := TFnGetObject(F)(Env, Target, Field);
    jkBoolean: Result.z := TFnGetBoolean(F)(Env, Target, Field);
    jkByte:    Result.b := TFnGetByte(F)(Env, Target, Field);
    jkChar:    Result.c := TFnGetChar(F)(Env, Target, Field);
    jkShort:   Result.s := TFnGetShort(F)(Env, Target, Field);
    jkInt:     Result.i := TFnGetInt(F)(Env, Target, Field);
    jkLong:    Result.j := TFnGetLong(F)(Env, Target, Field);
    jkFloat:   Result.f := TFnGetFloat(F)(Env, Target, Field);
    jkDouble:  Result.d := TFnGetDouble(F)(Env, Target, Field);
  else
    raise EJavaError.Create('Invalid field kind');
  end;
  CheckException(Env);
end;

procedure JrSetField(Target: jobject; Field: jfieldID; Kind: TJavaKind;
  IsStatic: Boolean; const Value: jvalue);
var
  Env: PJNIEnv;
  F: Pointer;
begin
  Env := JrEnv;
  if Target = nil then
    raise EJavaError.Create('Java field write on a null reference');
  if IsStatic then
    F := Env^^[FN_SetStaticObjectField + Ord(Kind)]
  else
    F := Env^^[FN_SetObjectField + Ord(Kind)];
  case Kind of
    jkObject:  TFnSetObject(F)(Env, Target, Field, Value.l);
    jkBoolean: TFnSetBoolean(F)(Env, Target, Field, Value.z);
    jkByte:    TFnSetByte(F)(Env, Target, Field, Value.b);
    jkChar:    TFnSetChar(F)(Env, Target, Field, Value.c);
    jkShort:   TFnSetShort(F)(Env, Target, Field, Value.s);
    jkInt:     TFnSetInt(F)(Env, Target, Field, Value.i);
    jkLong:    TFnSetLong(F)(Env, Target, Field, Value.j);
    jkFloat:   TFnSetFloat(F)(Env, Target, Field, Value.f);
    jkDouble:  TFnSetDouble(F)(Env, Target, Field, Value.d);
  else
    raise EJavaError.Create('Invalid field kind');
  end;
  CheckException(Env);
end;

{ ---------------------------------------------------------------------------
  References and strings
  --------------------------------------------------------------------------- }

function JrHandle(const Obj: IInterface): jobject;
var
  H: IJavaHandle;
begin
  if (Obj <> nil) and (Obj.QueryInterface(IJavaHandle, H) = 0) then
    Result := H.JavaGlobalRef
  else
    Result := nil;
end;

function JavaHandleOf(const Obj: IInterface): jobject;
begin
  Result := JrHandle(Obj);
end;

function JrNewGlobalRef(Ref: jobject): jobject;
var
  Env: PJNIEnv;
begin
  Result := nil;
  if Ref <> nil then
  begin
    Env := JrEnv;
    Result := TFnObj_Obj(Env^^[FN_NewGlobalRef])(Env, Ref);
  end;
end;

procedure JrDeleteLocal(Ref: jobject);
var
  Env: PJNIEnv;
begin
  if Ref <> nil then
  begin
    Env := JrEnv;
    TFnObj(Env^^[FN_DeleteLocalRef])(Env, Ref);
  end;
end;

function JrNewString(const S: UnicodeString): jstring;
var
  Env: PJNIEnv;
begin
  Env := JrEnv;
  Result := TFnNewString(Env^^[FN_NewString])(Env, PWideChar(S), Length(S));
  CheckException(Env);
end;

function JrTakeString(Ref: jstring): UnicodeString;
var
  Env: PJNIEnv;
  Len: jsize;
begin
  Result := '';
  if Ref = nil then
    Exit;
  Env := JrEnv;
  Len := TFnObj_Int(Env^^[FN_GetStringLength])(Env, Ref);
  SetLength(Result, Len);
  if Len > 0 then
    TFnGetStringRegion(Env^^[FN_GetStringRegion])(Env, Ref, 0, Len, PWideChar(Result));
  TFnObj(Env^^[FN_DeleteLocalRef])(Env, Ref);
end;

function JrIsInstance(const Obj: IInterface; Cls: jclass): Boolean;
var
  Env: PJNIEnv;
  H: jobject;
begin
  H := JrHandle(Obj);
  if H = nil then
    Exit(False);
  Env := JrEnv;
  Result := TFnObjObj_Bool(Env^^[FN_IsInstanceOf])(Env, H, Cls) <> 0;
end;

function JrCheckCast(const Obj: IInterface; Cls: jclass;
  const JavaName: UnicodeString): jobject;
begin
  Result := JrHandle(Obj);
  if Result = nil then
    Exit;
  if not JrIsInstance(Obj, Cls) then
    raise EJavaCastError.CreateFmt('%s cannot be cast to %s',
      [string(JavaClassNameOf(Obj)), string(JavaName)]);
end;

function JavaSameObject(const A, B: IInterface): Boolean;
var
  Env: PJNIEnv;
begin
  Env := JrEnv;
  Result := TFnObjObj_Bool(Env^^[FN_IsSameObject])(Env, JrHandle(A), JrHandle(B)) <> 0;
end;

function JavaClassNameOf(const Obj: IInterface): UnicodeString;
var
  Env: PJNIEnv;
  H, C: jobject;
begin
  Result := '';
  H := JrHandle(Obj);
  if H = nil then
    Exit;
  Env := JrEnv;
  C := TFnObj_Obj(Env^^[FN_GetObjectClass])(Env, H);
  Result := SafeToString(Env, C, GMidGetName);
  JrDeleteLocal(C);
end;

function JavaWrapLocal(Ref: jobject): IJavaObject;
begin
  if Ref = nil then
    Result := nil
  else
    Result := TJavaObjectImpl.CreateFromLocal(Ref);
end;

{ ---------------------------------------------------------------------------
  Arrays
  --------------------------------------------------------------------------- }

function NewPrimArray(Kind: TJavaKind; Data: Pointer; Len: Integer): jarray;
var
  Env: PJNIEnv;
begin
  Env := JrEnv;
  Result := TFnNewPrimArray(Env^^[FN_NewBooleanArray + Ord(Kind) - 1])(Env, Len);
  CheckException(Env);
  if Len > 0 then
    TFnArrayRegion(Env^^[FN_SetBooleanArrayRegion + Ord(Kind) - 1])(Env, Result, 0, Len, Data);
end;

{ Returns the length; copies into Data via the callback after the caller
  allocated it. Two-step so we can keep typed dynamic arrays. }
function PrimArrayLength(Ref: jarray): Integer;
var
  Env: PJNIEnv;
begin
  if Ref = nil then
    Exit(0);
  Env := JrEnv;
  Result := TFnObj_Int(Env^^[FN_GetArrayLength])(Env, Ref);
end;

procedure PrimArrayCopyAndFree(Kind: TJavaKind; Ref: jarray; Data: Pointer; Len: Integer);
var
  Env: PJNIEnv;
begin
  if Ref = nil then
    Exit;
  Env := JrEnv;
  if Len > 0 then
    TFnArrayRegion(Env^^[FN_GetBooleanArrayRegion + Ord(Kind) - 1])(Env, Ref, 0, Len, Data);
  TFnObj(Env^^[FN_DeleteLocalRef])(Env, Ref);
end;

function JrNewBooleanArray(const A: TJavaBooleanArray): jarray;
begin
  Result := NewPrimArray(jkBoolean, Pointer(A), Length(A));
end;

function JrNewByteArray(const A: TJavaByteArray): jarray;
begin
  Result := NewPrimArray(jkByte, Pointer(A), Length(A));
end;

function JrNewCharArray(const A: TJavaCharArray): jarray;
begin
  Result := NewPrimArray(jkChar, Pointer(A), Length(A));
end;

function JrNewShortArray(const A: TJavaShortArray): jarray;
begin
  Result := NewPrimArray(jkShort, Pointer(A), Length(A));
end;

function JrNewIntArray(const A: TJavaIntArray): jarray;
begin
  Result := NewPrimArray(jkInt, Pointer(A), Length(A));
end;

function JrNewLongArray(const A: TJavaLongArray): jarray;
begin
  Result := NewPrimArray(jkLong, Pointer(A), Length(A));
end;

function JrNewFloatArray(const A: TJavaFloatArray): jarray;
begin
  Result := NewPrimArray(jkFloat, Pointer(A), Length(A));
end;

function JrNewDoubleArray(const A: TJavaDoubleArray): jarray;
begin
  Result := NewPrimArray(jkDouble, Pointer(A), Length(A));
end;

function JrTakeBooleanArray(Ref: jarray): TJavaBooleanArray;
begin
  Result := nil;
  SetLength(Result, PrimArrayLength(Ref));
  PrimArrayCopyAndFree(jkBoolean, Ref, Pointer(Result), Length(Result));
end;

function JrTakeByteArray(Ref: jarray): TJavaByteArray;
begin
  Result := nil;
  SetLength(Result, PrimArrayLength(Ref));
  PrimArrayCopyAndFree(jkByte, Ref, Pointer(Result), Length(Result));
end;

function JrTakeCharArray(Ref: jarray): TJavaCharArray;
begin
  Result := nil;
  SetLength(Result, PrimArrayLength(Ref));
  PrimArrayCopyAndFree(jkChar, Ref, Pointer(Result), Length(Result));
end;

function JrTakeShortArray(Ref: jarray): TJavaShortArray;
begin
  Result := nil;
  SetLength(Result, PrimArrayLength(Ref));
  PrimArrayCopyAndFree(jkShort, Ref, Pointer(Result), Length(Result));
end;

function JrTakeIntArray(Ref: jarray): TJavaIntArray;
begin
  Result := nil;
  SetLength(Result, PrimArrayLength(Ref));
  PrimArrayCopyAndFree(jkInt, Ref, Pointer(Result), Length(Result));
end;

function JrTakeLongArray(Ref: jarray): TJavaLongArray;
begin
  Result := nil;
  SetLength(Result, PrimArrayLength(Ref));
  PrimArrayCopyAndFree(jkLong, Ref, Pointer(Result), Length(Result));
end;

function JrTakeFloatArray(Ref: jarray): TJavaFloatArray;
begin
  Result := nil;
  SetLength(Result, PrimArrayLength(Ref));
  PrimArrayCopyAndFree(jkFloat, Ref, Pointer(Result), Length(Result));
end;

function JrTakeDoubleArray(Ref: jarray): TJavaDoubleArray;
begin
  Result := nil;
  SetLength(Result, PrimArrayLength(Ref));
  PrimArrayCopyAndFree(jkDouble, Ref, Pointer(Result), Length(Result));
end;

function JrNewStringArray(const A: TJavaStringArray): jarray;
var
  Env: PJNIEnv;
  I: Integer;
  S: jstring;
begin
  Env := JrEnv;
  Result := TFnNewObjectArray(Env^^[FN_NewObjectArray])(Env, Length(A), GClsString, nil);
  CheckException(Env);
  for I := 0 to High(A) do
  begin
    S := JrNewString(A[I]);
    TFnSetObjArrayElem(Env^^[FN_SetObjectArrayElement])(Env, Result, I, S);
    JrDeleteLocal(S);
  end;
end;

function JrNewObjectArray(const A: TJavaObjectArray; ElementClass: jclass): jarray;
var
  Env: PJNIEnv;
  I: Integer;
begin
  Env := JrEnv;
  Result := TFnNewObjectArray(Env^^[FN_NewObjectArray])(Env, Length(A), ElementClass, nil);
  CheckException(Env);
  for I := 0 to High(A) do
  begin
    TFnSetObjArrayElem(Env^^[FN_SetObjectArrayElement])(Env, Result, I, JrHandle(A[I]));
    CheckException(Env);   { ArrayStoreException for wrong element types }
  end;
end;

function JrTakeStringArray(Ref: jarray): TJavaStringArray;
var
  Env: PJNIEnv;
  I: Integer;
begin
  Result := nil;
  SetLength(Result, PrimArrayLength(Ref));
  if Ref = nil then
    Exit;
  Env := JrEnv;
  for I := 0 to High(Result) do
    Result[I] := JrTakeString(TFnGetObjArrayElem(Env^^[FN_GetObjectArrayElement])(Env, Ref, I));
  JrDeleteLocal(Ref);
end;

function JrTakeObjectArray(Ref: jarray): TJavaObjectArray;
var
  Env: PJNIEnv;
  I: Integer;
begin
  Result := nil;
  SetLength(Result, PrimArrayLength(Ref));
  if Ref = nil then
    Exit;
  Env := JrEnv;
  for I := 0 to High(Result) do
    Result[I] := JavaWrapLocal(TFnGetObjArrayElem(Env^^[FN_GetObjectArrayElement])(Env, Ref, I));
  JrDeleteLocal(Ref);
end;

{ ---------------------------------------------------------------------------
  Callbacks (Java -> Pascal)
  --------------------------------------------------------------------------- }

{$I JavaBridgeHandler.inc}

function JrNewLocalRef(Ref: jobject): jobject;
var
  Env: PJNIEnv;
begin
  Result := nil;
  if Ref <> nil then
  begin
    Env := JrEnv;
    Result := TFnObj_Obj(Env^^[FN_NewLocalRef])(Env, Ref);
  end;
end;

function JavaCallbackCount: Integer;
begin
  Result := GCallbackCount;
end;

procedure ThrowToJava(Env: PJNIEnv; E: TObject);
var
  Msg: UTF8String;
  H: jobject;
begin
  if (E is EJavaException) and (EJavaException(E).Throwable <> nil) then
  begin
    { a Java exception that passed through Pascal: rethrow the original }
    H := JrHandle(EJavaException(E).Throwable);
    if H <> nil then
    begin
      TFnThrow(Env^^[FN_Throw])(Env, H);
      Exit;
    end;
  end;
  if E is Exception then
    Msg := UTF8Encode(UnicodeString(E.ClassName + ': ' + Exception(E).Message))
  else if E <> nil then
    Msg := UTF8Encode(UnicodeString('Pascal exception ' + E.ClassName))
  else
    Msg := 'Pascal exception';
  TFnThrowNew(Env^^[FN_ThrowNew])(Env, GClsRuntimeException, PAnsiChar(Msg));
end;

procedure EnterFromJava(Env: PJNIEnv);
begin
  if TEnv = nil then
  begin
    { first Pascal code on this (possibly Java-created) thread }
    TEnv := Env;
    if GMaskFPU then
      MaskFPU;
  end;
end;

{ static native Object invoke0(long handle, int index, Object[] args) }
function NativeInvoke(Env: PJNIEnv; Cls: jclass; Handle: jlong; Index: jint;
  Args: jarray): jobject; {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
var
  B: TJavaCallbackBinding;
begin
  Result := nil;
  EnterFromJava(Env);
  B := TJavaCallbackBinding(Pointer(NativeUInt(Handle)));
  try
    Result := B.Dispatch(B.Target, Index, Args);
  except
    on E: TObject do
    begin
      Result := nil;
      ThrowToJava(Env, E);
    end;
  end;
end;

{ static native void release0(long handle) }
procedure NativeRelease(Env: PJNIEnv; Cls: jclass; Handle: jlong);
  {$IFDEF MSWINDOWS}stdcall{$ELSE}cdecl{$ENDIF};
var
  B: TJavaCallbackBinding;
begin
  EnterFromJava(Env);
  B := TJavaCallbackBinding(Pointer(NativeUInt(Handle)));
  try
    B.Target := nil;   { may run the Pascal object's destructor }
  except
    { never let a Pascal exception unwind into the JVM }
  end;
  B.Free;
  {$IFDEF FPC}
  InterlockedDecrement(GCallbackCount);
  {$ELSE}
  AtomicDecrement(GCallbackCount);
  {$ENDIF}
end;

function DefineHandlerClass(Env: PJNIEnv; Loader: jobject; Name: PAnsiChar;
  Bytes: Pointer; Len: Integer): jclass;
var
  L: jclass;
begin
  L := TFnFindClass(Env^^[FN_FindClass])(Env, Name);
  if L = nil then
  begin
    ClearException(Env);
    L := TFnDefineClass(Env^^[FN_DefineClass])(Env, Name, Loader, Bytes, Len);
    CheckException(Env);
  end;
  Result := TFnObj_Obj(Env^^[FN_NewGlobalRef])(Env, L);
  TFnObj(Env^^[FN_DeleteLocalRef])(Env, L);
end;

procedure EnsureCallbackSupport;
var
  Env: PJNIEnv;
  ClsLoader, Loader: jobject;
  Mid: jmethodID;
  Cls: jclass;
  Natives: array[0..1] of TJavaNativeMethod;
begin
  if GHandlerCls <> nil then
    Exit;
  GLock.Acquire;
  try
    if GHandlerCls <> nil then
      Exit;
    Env := JrEnv;
    ClsLoader := FindClassGlobal(Env, 'java/lang/ClassLoader');
    Mid := TFnGetMember(Env^^[FN_GetStaticMethodID])(Env, ClsLoader,
      'getSystemClassLoader', '()Ljava/lang/ClassLoader;');
    Loader := JrCall(ClsLoader, Mid, nil, jkObject, True).l;
    TFnObj(Env^^[FN_DeleteGlobalRef])(Env, ClsLoader);

    Cls := DefineHandlerClass(Env, Loader, HANDLER_NAME_0, @HANDLER_BYTES_0[0],
      Length(HANDLER_BYTES_0));
    TFnObj(Env^^[FN_DeleteGlobalRef])(Env, DefineHandlerClass(Env, Loader,
      HANDLER_NAME_1, @HANDLER_BYTES_1[0], Length(HANDLER_BYTES_1)));
    JrDeleteLocal(Loader);

    Natives[0].name := 'invoke0';
    Natives[0].signature := '(JI[Ljava/lang/Object;)Ljava/lang/Object;';
    Natives[0].fnPtr := @NativeInvoke;
    Natives[1].name := 'release0';
    Natives[1].signature := '(J)V';
    Natives[1].fnPtr := @NativeRelease;
    if TFnRegisterNatives(Env^^[FN_RegisterNatives])(Env, Cls, @Natives[0], 2) <> JNI_OK then
    begin
      ClearException(Env);
      raise EJavaError.Create('RegisterNatives failed for the callback handler');
    end;
    GMidCreateProxy := TFnGetMember(Env^^[FN_GetStaticMethodID])(Env, Cls, 'create',
      '(Ljava/lang/Class;Ljava/lang/String;J)Ljava/lang/Object;');
    if GMidCreateProxy = nil then
    begin
      ClearException(Env);
      raise EJavaError.Create('Callback handler class is invalid');
    end;
    GClsRuntimeException := FindClassGlobal(Env, 'java/lang/RuntimeException');
    GHandlerCls := Cls;
  finally
    GLock.Release;
  end;
end;

function JrCreateProxy(IfaceClass: jclass; const Callback: IInterface;
  Dispatch: TJavaDispatchFunc; Sigs: PAnsiChar): jobject;
var
  Env: PJNIEnv;
  B: TJavaCallbackBinding;
  A: array[0..2] of jvalue;
begin
  if Callback = nil then
    raise EJavaError.Create('Callback object is nil');
  EnsureCallbackSupport;
  Env := JrEnv;
  B := TJavaCallbackBinding.Create;
  B.Target := Callback;
  B.Dispatch := Dispatch;
  A[0].l := IfaceClass;
  A[1].l := TFnNewStringUTF(Env^^[FN_NewStringUTF])(Env, Sigs);
  A[2].j := jlong(NativeUInt(B));
  try
    Result := JrCall(GHandlerCls, GMidCreateProxy, @A[0], jkObject, True).l;
  except
    JrDeleteLocal(A[1].l);
    B.Free;
    raise;
  end;
  JrDeleteLocal(A[1].l);
  {$IFDEF FPC}
  InterlockedIncrement(GCallbackCount);
  {$ELSE}
  AtomicIncrement(GCallbackCount);
  {$ENDIF}
end;

const
  BOX_CLASS: array[jkBoolean..jkDouble] of PAnsiChar = ('java/lang/Boolean',
    'java/lang/Byte', 'java/lang/Character', 'java/lang/Short', 'java/lang/Integer',
    'java/lang/Long', 'java/lang/Float', 'java/lang/Double');
  BOX_UNBOX: array[jkBoolean..jkDouble] of PAnsiChar = ('booleanValue', 'byteValue',
    'charValue', 'shortValue', 'intValue', 'longValue', 'floatValue', 'doubleValue');
  BOX_PRIM: array[jkBoolean..jkDouble] of AnsiChar = ('Z', 'B', 'C', 'S', 'I', 'J', 'F', 'D');

procedure ResolveBox(Kind: TJavaKind);
var
  Env: PJNIEnv;
  Cls: jclass;
  UnboxSig, ValueOfSig: AnsiString;
begin
  if not (Kind in [jkBoolean..jkDouble]) then
    raise EJavaError.Create('Invalid box kind');
  Env := JrEnv;
  Cls := JrResolveClass(GBoxCls[Kind], BOX_CLASS[Kind]);
  UnboxSig := AnsiString('()') + BOX_PRIM[Kind];
  ValueOfSig := AnsiString('(') + BOX_PRIM[Kind] + ')L' + AnsiString(BOX_CLASS[Kind]) + ';';
  GBoxUnbox[Kind] := TFnGetMember(Env^^[FN_GetMethodID])(Env, Cls, BOX_UNBOX[Kind],
    PAnsiChar(UnboxSig));
  GBoxValueOf[Kind] := TFnGetMember(Env^^[FN_GetStaticMethodID])(Env, Cls, 'valueOf',
    PAnsiChar(ValueOfSig));
end;

function JrBox(const Value: jvalue; Kind: TJavaKind): jobject;
var
  V: jvalue;
begin
  if GBoxValueOf[Kind] = nil then
    ResolveBox(Kind);
  V := Value;
  Result := JrCall(GBoxCls[Kind], GBoxValueOf[Kind], @V, jkObject, True).l;
end;

function JrArgValue(Args: jarray; Index: Integer; Kind: TJavaKind): jvalue;
var
  Env: PJNIEnv;
  L: jobject;
begin
  Env := JrEnv;
  L := TFnGetObjArrayElem(Env^^[FN_GetObjectArrayElement])(Env, Args, Index);
  CheckException(Env);
  if Kind = jkObject then
  begin
    Result.j := 0;
    Result.l := L;
    Exit;
  end;
  if GBoxUnbox[Kind] = nil then
    ResolveBox(Kind);
  try
    Result := JrCall(L, GBoxUnbox[Kind], nil, Kind, False);
  finally
    JrDeleteLocal(L);
  end;
end;

initialization
  GLock := TCriticalSection.Create;

finalization
  { Interfaces held in global variables of other units may be released after
    this point; TJavaObjectImpl.Destroy checks GVMRunning first. }
  FreeAndNil(GLock);

end.
