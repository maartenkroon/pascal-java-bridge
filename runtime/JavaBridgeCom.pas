{ JavaBridgeCom - late-bound COM Automation access to Java objects (Delphi, Windows).

  TJavaDispatch implements IDispatch for any Java object, or for the static
  members of a Java class. Members are looked up by name at run time and the
  overload is chosen from the actual VARIANT arguments (the Java helper class
  pascaljavabridge.dynamic.DynamicInvoker does the reflection; its bytecode is
  embedded from JavaBridgeDynamic.inc). JavaComJVM returns the entry object
  with Start, New, Static, Cast and Implement.

  No type library and no generated code are involved: this is for IDispatch
  clients (VBScript, VBA, PowerShell, JScript, Delphi OleVariant, C# dynamic).

  Threading: the objects may be called on any thread (each thread is attached
  to the JVM as needed). A COM object passed to Implement is only called on
  the thread that passed it; a Java call on another thread gets a
  RuntimeException. Its release, after Java garbage-collects the proxy, is
  deferred to that thread's next call into this unit (or JavaComReleasePending).
}
unit JavaBridgeCom;

interface

uses
  Winapi.Windows, Winapi.ActiveX, System.SysUtils, System.SyncObjs, System.Variants,
  JavaBridge;

type
  { IDispatch over a Java object (or over the static members of a class). It
    also implements IJavaHandle, so it can be passed back to Java and used
    with JavaHandleOf / JavaClassNameOf. }
  TJavaDispatch = class(TInterfacedObject, IDispatch, IJavaHandle)
  private
    FObj: IJavaObject;     { nil for a static view }
    FView: IJavaObject;    { java.lang.Class whose members are visible }
    function IsStatic: Boolean;
    function InvokeValue(Flags: Word; const Args: array of OleVariant): OleVariant;
  public
    { Obj: the Java object. View: the class whose members are used (nil: the
      object's own class). }
    constructor Create(const Obj: IJavaObject; const View: IJavaObject = nil);
    { The static members (methods, fields) of Cls, a java.lang.Class. }
    constructor CreateStatic(const Cls: IJavaObject);
    { IDispatch }
    function GetTypeInfoCount(out Count: Integer): HResult; stdcall;
    function GetTypeInfo(Index, LocaleID: Integer; out TypeInfo): HResult; stdcall;
    function GetIDsOfNames(const IID: TGUID; Names: Pointer;
      NameCount, LocaleID: Integer; DispIDs: Pointer): HResult; stdcall;
    function Invoke(DispID: Integer; const IID: TGUID; LocaleID: Integer;
      Flags: Word; var Params; VarResult, ExcepInfo, ArgErr: Pointer): HResult; stdcall;
    { IJavaHandle: the object's global reference; for a static view, the class }
    function JavaGlobalRef: jobject;
    property JavaObject: IJavaObject read FObj;
  end;

{ The entry object (ProgID PascalJavaBridge.JVM once a COM server registers it):
    Start(classPath [, jvmOption...]) -> Boolean (False if already running)
    Running -> Boolean
    JvmPath (read/write): jvm.dll to load; default: from JAVA_HOME
    New(className [, arg...])        -> a new Java object
    Static(className)                -> the static members of a class
    Cast(obj, className)             -> obj, restricted to the members of className
    Implement(interfaceName, object) -> a Java proxy that calls object's methods
                                        by name (or its default member)
  New, Static and Implement start the JVM without options if it isn't running. }
function JavaComJVM: IDispatch;

{ Conversions used by TJavaDispatch. Java null is Null; numbers become I4
  (Long: I4 when it fits, else I8), R4 or R8; char and String become BSTR;
  arrays become variant arrays; other objects become a TJavaDispatch. }
function JavaToVariant(const Obj: IJavaObject): OleVariant;
function JavaFromVariant(const V: OleVariant): IJavaObject;

{ Releases COM objects that Java dropped on another thread (see Implement)
  and that belong to the calling thread. Called automatically on every call
  into this unit. }
procedure JavaComReleasePending;

{ A Java proxy for the Java interface IfaceName whose methods call Disp (see
  Implement above). }
function JavaComImplement(const IfaceName: UnicodeString; const Disp: IDispatch): IJavaObject;

{ An IEnumVARIANT over an Iterable, Iterator, Enumeration, Map or array. }
function JavaComEnum(const Obj: IJavaObject): IUnknown;

implementation

uses
  System.Win.ComObj;

{$I JavaBridgeDynamic.inc}

{$IF DYNAMIC_CLASS_COUNT <> 3}
  {$MESSAGE ERROR 'JavaBridgeDynamic.inc changed: update EnsureDynamic'}
{$IFEND}

type
  TOleVariantArray = array[0..65535] of OleVariant;
  POleVariantArray = ^TOleVariantArray;
  TOleVariants = array of OleVariant;

  { Static methods of DynamicInvoker }
  TDynFn = (dfFindClass, dfMemberId, dfInvoke, dfNewInstance, dfCast, dfTypeCode,
    dfLongValue, dfDoubleValue, dfBooleanValue, dfStringValue, dfArrayElements,
    dfIterator, dfHasNext, dfNext, dfAbstractMethods, dfCoerceResult);

const
  DYN_CLASS: PAnsiChar = 'pascaljavabridge/dynamic/DynamicInvoker';
  DYN_NAME: array[TDynFn] of PAnsiChar = ('findClass', 'memberId', 'invoke',
    'newInstance', 'cast', 'typeCode', 'longValue', 'doubleValue', 'booleanValue',
    'stringValue', 'arrayElements', 'iterator', 'hasNext', 'next', 'abstractMethods',
    'coerceResult');
  DYN_SIG: array[TDynFn] of PAnsiChar = (
    '(Ljava/lang/String;)Ljava/lang/Class;',
    '(Ljava/lang/Class;ZLjava/lang/String;)I',
    '(Ljava/lang/Object;Ljava/lang/Class;II[Ljava/lang/Object;)Ljava/lang/Object;',
    '(Ljava/lang/Class;[Ljava/lang/Object;)Ljava/lang/Object;',
    '(Ljava/lang/Object;Ljava/lang/Class;)Ljava/lang/Object;',
    '(Ljava/lang/Object;)I',
    '(Ljava/lang/Object;)J',
    '(Ljava/lang/Object;)D',
    '(Ljava/lang/Object;)Z',
    '(Ljava/lang/Object;)Ljava/lang/String;',
    '(Ljava/lang/Object;)[Ljava/lang/Object;',
    '(Ljava/lang/Object;)Ljava/util/Iterator;',
    '(Ljava/util/Iterator;)Z',
    '(Ljava/util/Iterator;)Ljava/lang/Object;',
    '(Ljava/lang/Class;)Ljava/lang/String;',
    '(Ljava/lang/Class;ILjava/lang/Object;)Ljava/lang/Object;');

  { DynamicInvoker.typeCode }
  T_NULL = 0; T_BOOLEAN = 1; T_BYTE = 2; T_SHORT = 3; T_INT = 4; T_LONG = 5;
  T_FLOAT = 6; T_DOUBLE = 7; T_CHAR = 8; T_STRING = 9; T_ARRAY = 10;

  IID_NULL: TGUID = '{00000000-0000-0000-0000-000000000000}';
  NEWENUM_NAME = '_NewEnum';

var
  GDynLock: TCriticalSection;
  GDynCls: jclass;
  GDynNested: array[1..DYNAMIC_CLASS_COUNT - 1] of jclass;
  GDynMid: array[TDynFn] of jmethodID;
  GObjectCls: jclass;
  GMidGetClass: jmethodID;

{ ---------------------------------------------------------------------------
  Java helper calls
  --------------------------------------------------------------------------- }

procedure EnsureDynamic;
var
  Cls: jclass;
begin
  if GDynCls <> nil then
    Exit;
  GDynLock.Acquire;
  try
    if GDynCls <> nil then
      Exit;
    { the outer class first, then the nested classes; GDynCls is set last
      because it is tested without the lock }
    Cls := JrDefineClass(DYNAMIC_NAME_0, @DYNAMIC_BYTES_0[0], Length(DYNAMIC_BYTES_0));
    GDynNested[1] := JrDefineClass(DYNAMIC_NAME_1, @DYNAMIC_BYTES_1[0], Length(DYNAMIC_BYTES_1));
    GDynNested[2] := JrDefineClass(DYNAMIC_NAME_2, @DYNAMIC_BYTES_2[0], Length(DYNAMIC_BYTES_2));
    GDynCls := Cls;
  finally
    GDynLock.Release;
  end;
end;

procedure EnsureVM;
begin
  if not JavaVMRunning then
    JavaStartVM('', []);
end;

function JV(O: jobject): jvalue; inline;
begin
  Result.j := 0;
  Result.l := O;
end;

function JI(I: Integer): jvalue; inline;
begin
  Result.j := 0;
  Result.i := I;
end;

function JZ(B: Boolean): jvalue; inline;
begin
  Result.j := 0;
  Result.z := Ord(B);
end;

function DynCall(F: TDynFn; const Args: array of jvalue; Kind: TJavaKind): jvalue;
var
  Mid: jmethodID;
  P: Pjvalue;
begin
  EnsureDynamic;
  Mid := JrResolveMethod(GDynMid[F], GDynCls, DYN_CLASS, DYN_NAME[F], DYN_SIG[F], True);
  if Length(Args) = 0 then
    P := nil
  else
    P := @Args[0];
  Result := JrCall(GDynCls, Mid, P, Kind, True);
end;

function DynObj(F: TDynFn; const Args: array of jvalue): IJavaObject;
begin
  Result := JavaWrapLocal(DynCall(F, Args, jkObject).l);
end;

function DynString(F: TDynFn; const Args: array of jvalue): UnicodeString;
begin
  Result := JrTakeString(DynCall(F, Args, jkObject).l);
end;

function NewJavaString(const S: UnicodeString): IJavaObject;
begin
  Result := JavaWrapLocal(JrNewString(S));
end;

function FindJavaClass(const Name: UnicodeString): IJavaObject;
var
  S: IJavaObject;
begin
  EnsureVM;
  S := NewJavaString(Name);
  Result := DynObj(dfFindClass, [JV(JrHandle(S))]);
end;

function ClassOf(const Obj: IJavaObject): IJavaObject;
var
  Mid: jmethodID;
begin
  Mid := JrResolveMethod(GMidGetClass, GObjectCls, 'java/lang/Object', 'getClass',
    '()Ljava/lang/Class;', False);
  Result := JavaWrapLocal(JrCall(JrHandle(Obj), Mid, nil, jkObject, False).l);
end;

function ObjectClass: jclass;
begin
  Result := JrResolveClass(GObjectCls, 'java/lang/Object');
end;

{ A local reference to a new Object[] holding Args converted to Java. }
function NewArgArray(const Args: array of OleVariant): jarray;
var
  A: TJavaObjectArray;
  I: Integer;
begin
  SetLength(A, Length(Args));
  for I := 0 to High(Args) do
    A[I] := JavaFromVariant(Args[I]);
  Result := JrNewObjectArray(A, ObjectClass);
end;

{ ---------------------------------------------------------------------------
  Conversions
  --------------------------------------------------------------------------- }

function Box(const Value: jvalue; Kind: TJavaKind): IJavaObject;
begin
  Result := JavaWrapLocal(JrBox(Value, Kind));
end;

function BoxInt(I: Integer): IJavaObject;
begin
  Result := Box(JI(I), jkInt);
end;

function BoxLong(L: Int64): IJavaObject;
var
  V: jvalue;
begin
  V.j := L;
  Result := Box(V, jkLong);
end;

function BoxDouble(D: Double): IJavaObject;
var
  V: jvalue;
begin
  V.j := 0;
  V.d := D;
  Result := Box(V, jkDouble);
end;

function BoxFloat(F: Single): IJavaObject;
var
  V: jvalue;
begin
  V.j := 0;
  V.f := F;
  Result := Box(V, jkFloat);
end;

function ArrayToJava(const V: OleVariant): IJavaObject;
var
  A, Row: TJavaObjectArray;
  I, J, Lo, Lo2: Integer;
begin
  case VarArrayDimCount(V) of
    1:
      begin
        Lo := VarArrayLowBound(V, 1);
        SetLength(A, VarArrayHighBound(V, 1) - Lo + 1);
        for I := 0 to High(A) do
          A[I] := JavaFromVariant(V[Lo + I]);
      end;
    2:
      begin
        { rows of columns: Object[][], e.g. an Excel range }
        Lo := VarArrayLowBound(V, 1);
        Lo2 := VarArrayLowBound(V, 2);
        SetLength(A, VarArrayHighBound(V, 1) - Lo + 1);
        for I := 0 to High(A) do
        begin
          SetLength(Row, VarArrayHighBound(V, 2) - Lo2 + 1);
          for J := 0 to High(Row) do
            Row[J] := JavaFromVariant(V[Lo + I, Lo2 + J]);
          A[I] := JavaWrapLocal(JrNewObjectArray(Row, ObjectClass));
        end;
      end;
  else
    raise EJavaError.Create('Only 1- and 2-dimensional arrays can be passed to Java');
  end;
  Result := JavaWrapLocal(JrNewObjectArray(A, ObjectClass));
end;

function JavaFromVariant(const V: OleVariant): IJavaObject;
var
  D: OleVariant;
  VT: TVarType;
  U: IInterface;
  H: IJavaHandle;
begin
  VT := TVarData(V).VType;
  if (VT and varByRef) <> 0 then
  begin
    OleCheck(VariantCopyInd(D, V));
    Exit(JavaFromVariant(D));
  end;
  if (VT and varArray) <> 0 then
    Exit(ArrayToJava(V));
  case VT of
    varEmpty, varNull:
      Result := nil;
    varSmallint, varShortInt, varByte, varWord, varInteger, 22 { VT_INT }:
      Result := BoxInt(V);
    varLongWord, 23 { VT_UINT }:
      if TVarData(V).VLongWord > LongWord(MaxInt) then
        Result := BoxLong(TVarData(V).VLongWord)
      else
        Result := BoxInt(Integer(TVarData(V).VLongWord));
    varInt64:
      Result := BoxLong(TVarData(V).VInt64);
    varUInt64:
      Result := BoxLong(Int64(TVarData(V).VUInt64));
    varSingle:
      Result := BoxFloat(TVarData(V).VSingle);
    varDouble, varCurrency, varDate, 14 { VT_DECIMAL }:
      Result := BoxDouble(Double(V));
    varBoolean:
      Result := Box(JZ(TVarData(V).VBoolean), jkBoolean);
    varOleStr, varString, varUString:
      Result := NewJavaString(UnicodeString(V));
    varDispatch, varUnknown:
      begin
        U := IInterface(TVarData(V).VUnknown);
        if U = nil then
          Result := nil
        else if Supports(U, IJavaHandle, H) and (H.JavaGlobalRef <> nil) then
          Result := JavaWrapLocal(JrNewLocalRef(H.JavaGlobalRef))
        else
          raise EJavaError.Create('Only Java objects can be passed to Java; ' +
            'wrap a COM object with Implement');
      end;
    varError:
      raise EJavaError.Create('Missing argument');
  else
    raise EJavaError.CreateFmt('A Variant of type %d cannot be passed to Java', [VT]);
  end;
end;

function JavaToVariant(const Obj: IJavaObject): OleVariant;
var
  H: jobject;
  L: Int64;
  Elems: TJavaObjectArray;
  I: Integer;
begin
  H := JrHandle(Obj);
  if H = nil then
    Exit(Null);
  case DynCall(dfTypeCode, [JV(H)], jkInt).i of
    T_NULL:
      Result := Null;
    T_BOOLEAN:
      Result := DynCall(dfBooleanValue, [JV(H)], jkBoolean).z <> 0;
    T_BYTE, T_SHORT, T_INT:
      Result := Integer(DynCall(dfLongValue, [JV(H)], jkLong).j);
    T_LONG:
      begin
        L := DynCall(dfLongValue, [JV(H)], jkLong).j;
        if (L >= Low(Integer)) and (L <= High(Integer)) then
          Result := Integer(L)
        else
          Result := L;
      end;
    T_FLOAT:
      Result := Single(DynCall(dfDoubleValue, [JV(H)], jkDouble).d);
    T_DOUBLE:
      Result := DynCall(dfDoubleValue, [JV(H)], jkDouble).d;
    T_CHAR, T_STRING:
      Result := WideString(DynString(dfStringValue, [JV(H)]));
    T_ARRAY:
      begin
        Elems := JrTakeObjectArray(DynCall(dfArrayElements, [JV(H)], jkObject).l);
        Result := VarArrayCreate([0, High(Elems)], varVariant);
        for I := 0 to High(Elems) do
          Result[I] := JavaToVariant(Elems[I]);
      end;
  else
    Result := IDispatch(TJavaDispatch.Create(Obj));
  end;
end;

{ ---------------------------------------------------------------------------
  IDispatch helpers
  --------------------------------------------------------------------------- }

{ Arguments in call order, dereferenced, without trailing missing ones. }
function ReadArgs(const P: TDispParams): TOleVariants;
var
  I, N: Integer;
  Src: POleVariantArray;
begin
  N := P.cArgs;
  SetLength(Result, N);
  Src := POleVariantArray(P.rgvarg);
  for I := 0 to N - 1 do
    OleCheck(VariantCopyInd(Result[I], Src^[N - 1 - I]));
  while (N > 0) and (TVarData(Result[N - 1]).VType = varError)
    and (TVarData(Result[N - 1]).VError = HResult(DISP_E_PARAMNOTFOUND)) do
    Dec(N);
  SetLength(Result, N);
end;

function CheckNamedArgs(const P: TDispParams; Flags: Word): HResult;
begin
  Result := S_OK;
  if P.cNamedArgs = 0 then
    Exit;
  if (P.cNamedArgs = 1) and ((Flags and (DISPATCH_PROPERTYPUT or DISPATCH_PROPERTYPUTREF)) <> 0)
    and (P.rgdispidNamedArgs^[0] = DISPID_PROPERTYPUT) then
    Exit;
  Result := DISP_E_NONAMEDARGS;
end;

function FillExcepInfo(E: Exception; ExcepInfo: Pointer): HResult;
var
  P: PExcepInfo;
  Source: UnicodeString;
begin
  if ExcepInfo = nil then
    Exit(E_FAIL);
  P := PExcepInfo(ExcepInfo);
  FillChar(P^, SizeOf(P^), 0);
  if (E is EJavaException) and (EJavaException(E).JavaClassName <> '') then
    Source := EJavaException(E).JavaClassName
  else
    Source := 'PascalJavaBridge';
  P^.bstrSource := Source;
  P^.bstrDescription := E.Message;
  P^.scode := E_FAIL;
  Result := DISP_E_EXCEPTION;
end;

function PWideCharArg(Names: Pointer; I: Integer): UnicodeString;
begin
  Result := PPWideChar(PByte(Names) + I * SizeOf(PWideChar))^;
end;

procedure SetDispID(DispIDs: Pointer; I, Id: Integer);
begin
  PInteger(PByte(DispIDs) + I * SizeOf(Integer))^ := Id;
end;

{ ---------------------------------------------------------------------------
  Deferred release of COM objects dropped by Java on another thread
  --------------------------------------------------------------------------- }

type
  TPendingRelease = record
    Owner: TThreadID;
    Obj: Pointer;   { holds one reference }
  end;

var
  GPendingLock: TCriticalSection;
  GPending: array of TPendingRelease;
  GPendingCount: Integer;

procedure DeferRelease(Owner: TThreadID; Obj: Pointer);
begin
  GPendingLock.Acquire;
  try
    if GPendingCount = Length(GPending) then
      SetLength(GPending, 2 * GPendingCount + 4);
    GPending[GPendingCount].Owner := Owner;
    GPending[GPendingCount].Obj := Obj;
    Inc(GPendingCount);
  finally
    GPendingLock.Release;
  end;
end;

procedure JavaComReleasePending;
var
  Mine: array of Pointer;
  I, N, K: Integer;
  Me: TThreadID;
begin
  if GPendingCount = 0 then   { unlocked read: a miss is caught next time }
    Exit;
  Me := GetCurrentThreadId;
  N := 0;
  GPendingLock.Acquire;
  try
    SetLength(Mine, GPendingCount);
    K := 0;
    for I := 0 to GPendingCount - 1 do
      if GPending[I].Owner = Me then
      begin
        Mine[N] := GPending[I].Obj;
        Inc(N);
      end
      else
      begin
        GPending[K] := GPending[I];
        Inc(K);
      end;
    GPendingCount := K;
  finally
    GPendingLock.Release;
  end;
  for I := 0 to N - 1 do
    IInterface(Mine[I])._Release;
end;

{ ---------------------------------------------------------------------------
  For Each support
  --------------------------------------------------------------------------- }

type
  TJavaEnum = class(TInterfacedObject, IEnumVARIANT)
  private
    FIter: IJavaObject;
  public
    constructor Create(const Iter: IJavaObject);
    function Next(celt: LongWord; var rgvar: OleVariant;
      out pceltFetched: LongWord): HResult; stdcall;
    function Skip(celt: LongWord): HResult; stdcall;
    function Reset: HResult; stdcall;
    function Clone(out Enum: IEnumVARIANT): HResult; stdcall;
  end;

constructor TJavaEnum.Create(const Iter: IJavaObject);
begin
  inherited Create;
  FIter := Iter;
end;

function TJavaEnum.Next(celt: LongWord; var rgvar: OleVariant;
  out pceltFetched: LongWord): HResult;
var
  P: POleVariantArray;
  N: LongWord;
begin
  N := 0;
  try
    P := @rgvar;
    while (N < celt) and (DynCall(dfHasNext, [JV(JrHandle(FIter))], jkBoolean).z <> 0) do
    begin
      P^[N] := JavaToVariant(DynObj(dfNext, [JV(JrHandle(FIter))]));
      Inc(N);
    end;
    if N = celt then
      Result := S_OK
    else
      Result := S_FALSE;
  except
    Result := E_FAIL;
  end;
  if @pceltFetched <> nil then
    pceltFetched := N;
end;

function TJavaEnum.Skip(celt: LongWord): HResult;
var
  N: LongWord;
begin
  N := 0;
  try
    while (N < celt) and (DynCall(dfHasNext, [JV(JrHandle(FIter))], jkBoolean).z <> 0) do
    begin
      DynObj(dfNext, [JV(JrHandle(FIter))]);
      Inc(N);
    end;
    if N = celt then
      Result := S_OK
    else
      Result := S_FALSE;
  except
    Result := E_FAIL;
  end;
end;

function TJavaEnum.Reset: HResult;
begin
  Result := E_NOTIMPL;   { a Java Iterator can't restart }
end;

function TJavaEnum.Clone(out Enum: IEnumVARIANT): HResult;
begin
  Pointer(Enum) := nil;
  Result := E_NOTIMPL;
end;

{ ---------------------------------------------------------------------------
  TJavaDispatch
  --------------------------------------------------------------------------- }

constructor TJavaDispatch.Create(const Obj: IJavaObject; const View: IJavaObject);
begin
  inherited Create;
  if JrHandle(Obj) = nil then
    raise EJavaError.Create('TJavaDispatch needs a Java object');
  FObj := Obj;
  if View <> nil then
    FView := View
  else
    FView := ClassOf(Obj);
end;

constructor TJavaDispatch.CreateStatic(const Cls: IJavaObject);
begin
  inherited Create;
  if JrHandle(Cls) = nil then
    raise EJavaError.Create('TJavaDispatch.CreateStatic needs a java.lang.Class');
  FView := Cls;
end;

function TJavaDispatch.IsStatic: Boolean;
begin
  Result := FObj = nil;
end;

function TJavaDispatch.JavaGlobalRef: jobject;
begin
  if FObj <> nil then
    Result := JrHandle(FObj)
  else
    Result := JrHandle(FView);
end;

function TJavaDispatch.GetTypeInfoCount(out Count: Integer): HResult;
begin
  Count := 0;
  Result := S_OK;
end;

function TJavaDispatch.GetTypeInfo(Index, LocaleID: Integer; out TypeInfo): HResult;
begin
  Pointer(TypeInfo) := nil;
  Result := E_NOTIMPL;
end;

function TJavaDispatch.GetIDsOfNames(const IID: TGUID; Names: Pointer;
  NameCount, LocaleID: Integer; DispIDs: Pointer): HResult;
var
  Name: UnicodeString;
  S: IJavaObject;
  Id, I: Integer;
begin
  try
    JavaComReleasePending;
    for I := 1 to NameCount - 1 do
      SetDispID(DispIDs, I, DISPID_UNKNOWN);   { named arguments are not supported }
    Name := PWideCharArg(Names, 0);
    if SameText(Name, NEWENUM_NAME) then
      Id := DISPID_NEWENUM
    else
    begin
      S := NewJavaString(Name);
      Id := DynCall(dfMemberId, [JV(JrHandle(FView)), JZ(IsStatic), JV(JrHandle(S))], jkInt).i;
    end;
    SetDispID(DispIDs, 0, Id);
    if (Id = -1) or (NameCount > 1) then
      Result := DISP_E_UNKNOWNNAME
    else
      Result := S_OK;
  except
    Result := E_FAIL;
  end;
end;

{ DISPID_VALUE: obj(i) is get(i), obj(i) = x is set(i, x), plain obj is
  toString(). }
function TJavaDispatch.InvokeValue(Flags: Word; const Args: array of OleVariant): OleVariant;
var
  Name: UnicodeString;
  S, R: IJavaObject;
  Id: Integer;
  A: jarray;
begin
  if (Flags and (DISPATCH_PROPERTYPUT or DISPATCH_PROPERTYPUTREF)) <> 0 then
    Name := 'set'
  else if Length(Args) > 0 then
    Name := 'get'
  else
    Name := 'toString';
  S := NewJavaString(Name);
  Id := DynCall(dfMemberId, [JV(JrHandle(FView)), JZ(IsStatic), JV(JrHandle(S))], jkInt).i;
  if Id = -1 then
    raise EJavaError.CreateFmt('%s has no %s method for the default member',
      [string(JavaClassNameOf(FView)), Name]);
  A := NewArgArray(Args);
  try
    R := DynObj(dfInvoke, [JV(JrHandle(FObj)), JV(JrHandle(FView)), JI(Id),
      JI(DISPATCH_METHOD), JV(A)]);
  finally
    JrDeleteLocal(A);
  end;
  Result := JavaToVariant(R);
end;

function TJavaDispatch.Invoke(DispID: Integer; const IID: TGUID; LocaleID: Integer;
  Flags: Word; var Params; VarResult, ExcepInfo, ArgErr: Pointer): HResult;
var
  Args: TOleVariants;
  A: jarray;
  R: IJavaObject;
  V: OleVariant;
begin
  Result := CheckNamedArgs(TDispParams(Params), Flags);
  if Result <> S_OK then
    Exit;
  try
    JavaComReleasePending;
    Args := ReadArgs(TDispParams(Params));
    if DispID = DISPID_NEWENUM then
    begin
      R := DynObj(dfIterator, [JV(JavaGlobalRef)]);
      V := IUnknown(TJavaEnum.Create(R) as IEnumVARIANT);
    end
    else if DispID = DISPID_VALUE then
      V := InvokeValue(Flags, Args)
    else
    begin
      A := NewArgArray(Args);
      try
        R := DynObj(dfInvoke, [JV(JrHandle(FObj)), JV(JrHandle(FView)), JI(DispID),
          JI(Flags), JV(A)]);
      finally
        JrDeleteLocal(A);
      end;
      V := JavaToVariant(R);
    end;
    if VarResult <> nil then
      POleVariant(VarResult)^ := V;
    Result := S_OK;
  except
    on E: Exception do
      Result := FillExcepInfo(E, ExcepInfo);
  end;
end;

{ ---------------------------------------------------------------------------
  Callbacks: a Java proxy that calls a COM object by method name
  --------------------------------------------------------------------------- }

type
  TJavaComCallback = class(TInterfacedObject)
  private
    FDisp: IDispatch;
    FIface: IJavaObject;
    FNames: array of UnicodeString;
    FIds: array of Integer;   { 0 = not looked up yet; DISPID_VALUE is looked up as -2 }
    FOwner: TThreadID;
    FIsFunction: Boolean;
    function DispIdOf(Index: Integer): Integer;
    function HasMember(const Name: UnicodeString): Boolean;
  public
    constructor Create(const Disp: IDispatch; const Iface: IJavaObject;
      const Sigs: UnicodeString);
    destructor Destroy; override;
  end;

constructor TJavaComCallback.Create(const Disp: IDispatch; const Iface: IJavaObject;
  const Sigs: UnicodeString);
var
  Lines: TArray<string>;
  I: Integer;
begin
  inherited Create;
  FDisp := Disp;
  FIface := Iface;
  FOwner := GetCurrentThreadId;
  Lines := string(Sigs).Split([#10]);
  SetLength(FNames, Length(Lines));
  SetLength(FIds, Length(Lines));
  for I := 0 to High(Lines) do
    FNames[I] := Copy(Lines[I], 1, Pos('(', Lines[I]) - 1);
  { A JScript function has members call and apply (Function.prototype), which
    must not be mistaken for a Java method apply: always call the function. }
  FIsFunction := HasMember('call') and HasMember('apply');
end;

function TJavaComCallback.HasMember(const Name: UnicodeString): Boolean;
var
  P: PWideChar;
  Id: Integer;
begin
  P := PWideChar(Name);
  Result := FDisp.GetIDsOfNames(IID_NULL, @P, 1, LOCALE_USER_DEFAULT, @Id) = S_OK;
end;

destructor TJavaComCallback.Destroy;
begin
  if (FDisp <> nil) and (GetCurrentThreadId <> FOwner) then
  begin
    { usually Java's Cleaner thread: hand the reference to the owning thread }
    DeferRelease(FOwner, Pointer(FDisp));
    Pointer(FDisp) := nil;
  end;
  inherited;
end;

function TJavaComCallback.DispIdOf(Index: Integer): Integer;
var
  Name: UnicodeString;
  P: PWideChar;
  Id: Integer;
begin
  if FIds[Index] = 0 then
  begin
    Name := FNames[Index];
    P := PWideChar(Name);
    if FIsFunction or (FDisp.GetIDsOfNames(IID_NULL, @P, 1, LOCALE_USER_DEFAULT, @Id) <> S_OK) then
      Id := DISPID_VALUE;   { a JScript function, VBScript GetRef, ... }
    if Id = DISPID_VALUE then
      FIds[Index] := -2
    else
      FIds[Index] := Id;
  end;
  Result := FIds[Index];
  if Result = -2 then
    Result := DISPID_VALUE;
end;

function ComCallbackDispatch(const ATarget: IInterface; AIndex: Integer;
  AArgs: jarray): jobject;
var
  CB: TJavaComCallback;
  Args: TJavaObjectArray;
  Vars: TOleVariants;
  P: TDispParams;
  Res: OleVariant;
  Excep: TExcepInfo;
  Hr: HResult;
  I, N: Integer;
  Value: IJavaObject;
begin
  CB := TJavaComCallback(ATarget as TObject);
  if GetCurrentThreadId <> CB.FOwner then
    raise EJavaError.CreateFmt('COM callback %s called on another thread; a COM object ' +
      'can only be called on the thread that passed it to Implement', [CB.FNames[AIndex]]);
  JavaComReleasePending;
  Args := JrTakeObjectArray(JrNewLocalRef(AArgs));
  N := Length(Args);
  SetLength(Vars, N);
  for I := 0 to N - 1 do
    Vars[N - 1 - I] := JavaToVariant(Args[I]);   { DISPPARAMS are in reverse order }
  FillChar(P, SizeOf(P), 0);
  if N > 0 then
    P.rgvarg := PVariantArgList(@Vars[0]);
  P.cArgs := N;
  FillChar(Excep, SizeOf(Excep), 0);
  Hr := CB.FDisp.Invoke(CB.DispIdOf(AIndex), IID_NULL, LOCALE_USER_DEFAULT,
    DISPATCH_METHOD, P, @Res, @Excep, nil);
  if Hr = DISP_E_EXCEPTION then
  begin
    if Assigned(Excep.pfnDeferredFillIn) then
      Excep.pfnDeferredFillIn(@Excep);
    raise EJavaError.CreateFmt('%s: %s', [string(Excep.bstrSource), string(Excep.bstrDescription)]);
  end;
  if Failed(Hr) then
    raise EJavaError.CreateFmt('COM callback %s failed: %s',
      [CB.FNames[AIndex], SysErrorMessage(Cardinal(Hr))]);
  Value := JavaFromVariant(Res);
  Result := DynCall(dfCoerceResult, [JV(JrHandle(CB.FIface)), JI(AIndex), JV(JrHandle(Value))],
    jkObject).l;
end;

function ImplementInterface(const IfaceName: UnicodeString; const Disp: IDispatch): IJavaObject;
var
  Iface: IJavaObject;
  Sigs: UnicodeString;
  CB: TJavaComCallback;
begin
  if Disp = nil then
    raise EJavaError.Create('Implement needs a COM object');
  Iface := FindJavaClass(IfaceName);
  Sigs := DynString(dfAbstractMethods, [JV(JrHandle(Iface))]);
  if Sigs = '' then
    raise EJavaError.CreateFmt('%s has no abstract methods', [string(IfaceName)]);
  CB := TJavaComCallback.Create(Disp, Iface, Sigs);
  Result := JavaWrapLocal(JrCreateProxy(JrHandle(Iface), CB, ComCallbackDispatch,
    PAnsiChar(UTF8Encode(Sigs))));
end;

{ ---------------------------------------------------------------------------
  Entry object
  --------------------------------------------------------------------------- }

type
  TJavaComEntry = class(TInterfacedObject, IDispatch)
  private
    FJvmPath: string;
  public
    function GetTypeInfoCount(out Count: Integer): HResult; stdcall;
    function GetTypeInfo(Index, LocaleID: Integer; out TypeInfo): HResult; stdcall;
    function GetIDsOfNames(const IID: TGUID; Names: Pointer;
      NameCount, LocaleID: Integer; DispIDs: Pointer): HResult; stdcall;
    function Invoke(DispID: Integer; const IID: TGUID; LocaleID: Integer;
      Flags: Word; var Params; VarResult, ExcepInfo, ArgErr: Pointer): HResult; stdcall;
  end;

const
  ENTRY_NAMES: array[1..7] of string = ('Start', 'Running', 'JvmPath', 'New', 'Static',
    'Cast', 'Implement');
  ID_START = 1; ID_RUNNING = 2; ID_JVMPATH = 3; ID_NEW = 4; ID_STATIC = 5; ID_CAST = 6;
  ID_IMPLEMENT = 7;

function TJavaComEntry.GetTypeInfoCount(out Count: Integer): HResult;
begin
  Count := 0;
  Result := S_OK;
end;

function TJavaComEntry.GetTypeInfo(Index, LocaleID: Integer; out TypeInfo): HResult;
begin
  Pointer(TypeInfo) := nil;
  Result := E_NOTIMPL;
end;

function TJavaComEntry.GetIDsOfNames(const IID: TGUID; Names: Pointer;
  NameCount, LocaleID: Integer; DispIDs: Pointer): HResult;
var
  Name: string;
  I: Integer;
begin
  Name := PWideCharArg(Names, 0);
  for I := 1 to NameCount - 1 do
    SetDispID(DispIDs, I, DISPID_UNKNOWN);
  SetDispID(DispIDs, 0, DISPID_UNKNOWN);
  Result := DISP_E_UNKNOWNNAME;
  for I := Low(ENTRY_NAMES) to High(ENTRY_NAMES) do
    if SameText(Name, ENTRY_NAMES[I]) then
    begin
      SetDispID(DispIDs, 0, I);
      if NameCount = 1 then
        Result := S_OK;
    end;
end;

function ArgString(const Args: TOleVariants; I: Integer; const What: string): UnicodeString;
begin
  if (I > High(Args)) or VarIsNull(Args[I]) or VarIsEmpty(Args[I]) then
    raise EJavaError.CreateFmt('%s expected', [What]);
  Result := VarToStr(Args[I]);
end;

procedure AddOptions(const V: OleVariant; var Opts: TArray<string>);
var
  I: Integer;
begin
  if VarIsArray(V) then
  begin
    for I := VarArrayLowBound(V, 1) to VarArrayHighBound(V, 1) do
      AddOptions(V[I], Opts);
  end
  else if not (VarIsNull(V) or VarIsEmpty(V)) and (VarToStr(V) <> '') then
    Opts := Opts + [VarToStr(V)];
end;

function TJavaComEntry.Invoke(DispID: Integer; const IID: TGUID; LocaleID: Integer;
  Flags: Word; var Params; VarResult, ExcepInfo, ArgErr: Pointer): HResult;
var
  Args: TOleVariants;
  V: OleVariant;
  Opts: TArray<string>;
  Cls, Obj: IJavaObject;
  A: jarray;
  I: Integer;
  Put: Boolean;
begin
  Result := CheckNamedArgs(TDispParams(Params), Flags);
  if Result <> S_OK then
    Exit;
  try
    JavaComReleasePending;
    Args := ReadArgs(TDispParams(Params));
    Put := (Flags and (DISPATCH_PROPERTYPUT or DISPATCH_PROPERTYPUTREF)) <> 0;
    V := Unassigned;
    case DispID of
      ID_START:
        begin
          if JavaVMRunning then
            V := False
          else
          begin
            Opts := nil;
            if (Length(Args) > 0) and not VarIsArray(Args[0]) and (VarToStr(Args[0]) <> '') then
              Opts := ['-Djava.class.path=' + VarToStr(Args[0])];
            for I := 1 to High(Args) do
              AddOptions(Args[I], Opts);
            JavaStartVM(FJvmPath, Opts);
            V := True;
          end;
        end;
      ID_RUNNING:
        V := JavaVMRunning;
      ID_JVMPATH:
        { JvmPath(path) also sets it, for clients that cannot put properties (PowerShell) }
        if Put or (Length(Args) > 0) then
          FJvmPath := ArgString(Args, 0, 'jvm.dll path')
        else
          V := FJvmPath;
      ID_NEW:
        begin
          Cls := FindJavaClass(ArgString(Args, 0, 'Class name'));
          A := NewArgArray(Copy(Args, 1, MaxInt));
          try
            Obj := DynObj(dfNewInstance, [JV(JrHandle(Cls)), JV(A)]);
          finally
            JrDeleteLocal(A);
          end;
          V := JavaToVariant(Obj);
        end;
      ID_STATIC:
        V := IDispatch(TJavaDispatch.CreateStatic(FindJavaClass(ArgString(Args, 0, 'Class name'))));
      ID_CAST:
        begin
          if Length(Args) < 2 then
            raise EJavaError.Create('Cast(object, className) expected');
          Obj := JavaFromVariant(Args[0]);
          Cls := FindJavaClass(ArgString(Args, 1, 'Class name'));
          DynObj(dfCast, [JV(JrHandle(Obj)), JV(JrHandle(Cls))]);
          if Obj = nil then
            V := Null
          else
            V := IDispatch(TJavaDispatch.Create(Obj, Cls));
        end;
      ID_IMPLEMENT:
        begin
          if (Length(Args) < 2) or (TVarData(Args[1]).VType <> varDispatch) then
            raise EJavaError.Create('Implement(interfaceName, object) expected');
          Obj := ImplementInterface(ArgString(Args, 0, 'Interface name'),
            IDispatch(TVarData(Args[1]).VDispatch));
          V := IDispatch(TJavaDispatch.Create(Obj));
        end;
    else
      Exit(DISP_E_MEMBERNOTFOUND);
    end;
    if VarResult <> nil then
      POleVariant(VarResult)^ := V;
    Result := S_OK;
  except
    on E: Exception do
      Result := FillExcepInfo(E, ExcepInfo);
  end;
end;

function JavaComJVM: IDispatch;
begin
  Result := TJavaComEntry.Create;
end;

function JavaComImplement(const IfaceName: UnicodeString; const Disp: IDispatch): IJavaObject;
begin
  Result := ImplementInterface(IfaceName, Disp);
end;

function JavaComEnum(const Obj: IJavaObject): IUnknown;
begin
  Result := TJavaEnum.Create(DynObj(dfIterator, [JV(JrHandle(Obj))])) as IEnumVARIANT;
end;

initialization
  GDynLock := TCriticalSection.Create;
  GPendingLock := TCriticalSection.Create;

finalization
  FreeAndNil(GPendingLock);
  FreeAndNil(GDynLock);

end.
