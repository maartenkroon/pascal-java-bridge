program TestCom;

{ Exercises JavaBridgeCom (late-bound IDispatch access to Java) through Delphi
  OleVariant late binding, the same IDispatch calls VBScript or VBA make.
  Delphi on Windows only. No COM registration needed. }

{$APPTYPE CONSOLE}

uses
  Winapi.Windows, Winapi.ActiveX, System.SysUtils, System.Variants, System.Win.ComObj,
  JavaBridge, JavaBridgeCom;

var
  Failures: Integer = 0;

procedure Check(Cond: Boolean; const What: string);
begin
  if Cond then
    WriteLn('  ok   ', What)
  else
  begin
    WriteLn('  FAIL ', What);
    Inc(Failures);
  end;
end;

{ Calls DISPID_VALUE / DISPID_NEWENUM directly (Delphi syntax can't). }
function CallDispId(const Obj: OleVariant; DispID: Integer; Flags: Word;
  const Args: array of OleVariant): OleVariant;
var
  P: TDispParams;
  Rev: array of OleVariant;
  Excep: TExcepInfo;
  PutId: Integer;
  I: Integer;
begin
  SetLength(Rev, Length(Args));
  for I := 0 to High(Args) do
    Rev[High(Args) - I] := Args[I];
  FillChar(P, SizeOf(P), 0);
  if Length(Rev) > 0 then
    P.rgvarg := PVariantArgList(@Rev[0]);
  P.cArgs := Length(Rev);
  PutId := DISPID_PROPERTYPUT;
  if (Flags and DISPATCH_PROPERTYPUT) <> 0 then
  begin
    P.rgdispidNamedArgs := @PutId;
    P.cNamedArgs := 1;
  end;
  FillChar(Excep, SizeOf(Excep), 0);
  OleCheck(IDispatch(Obj).Invoke(DispID, GUID_NULL, 0, Flags, P, @Result, @Excep, nil));
end;

{ A COM object with one method, implemented by hand like a script class. }
type
  TScriptObject = class(TInterfacedObject, IDispatch)
  public
    Calls: Integer;
    LastArgs: array of OleVariant;
    MethodName: string;       { '' : only a default member, like a JScript function }
    ReturnValue: OleVariant;
    Fail: Boolean;
    destructor Destroy; override;
    function GetTypeInfoCount(out Count: Integer): HResult; stdcall;
    function GetTypeInfo(Index, LocaleID: Integer; out TypeInfo): HResult; stdcall;
    function GetIDsOfNames(const IID: TGUID; Names: Pointer;
      NameCount, LocaleID: Integer; DispIDs: Pointer): HResult; stdcall;
    function Invoke(DispID: Integer; const IID: TGUID; LocaleID: Integer;
      Flags: Word; var Params; VarResult, ExcepInfo, ArgErr: Pointer): HResult; stdcall;
  end;

var
  Destroyed: Integer = 0;
  DestroyedOnMain: Boolean = True;

destructor TScriptObject.Destroy;
begin
  Inc(Destroyed);
  DestroyedOnMain := DestroyedOnMain and (GetCurrentThreadId = MainThreadID);
  inherited;
end;

function TScriptObject.GetTypeInfoCount(out Count: Integer): HResult;
begin
  Count := 0;
  Result := S_OK;
end;

function TScriptObject.GetTypeInfo(Index, LocaleID: Integer; out TypeInfo): HResult;
begin
  Result := E_NOTIMPL;
end;

function TScriptObject.GetIDsOfNames(const IID: TGUID; Names: Pointer;
  NameCount, LocaleID: Integer; DispIDs: Pointer): HResult;
begin
  if (MethodName <> '') and SameText(PPWideChar(Names)^, MethodName) then
  begin
    PInteger(DispIDs)^ := 1;
    Result := S_OK;
  end
  else
    Result := DISP_E_UNKNOWNNAME;
end;

function TScriptObject.Invoke(DispID: Integer; const IID: TGUID; LocaleID: Integer;
  Flags: Word; var Params; VarResult, ExcepInfo, ArgErr: Pointer): HResult;
var
  P: TDispParams;
  I: Integer;
begin
  P := TDispParams(Params);
  if ((MethodName <> '') and (DispID <> 1)) or ((MethodName = '') and (DispID <> DISPID_VALUE)) then
    Exit(DISP_E_MEMBERNOTFOUND);
  Inc(Calls);
  SetLength(LastArgs, P.cArgs);
  for I := 0 to P.cArgs - 1 do
    LastArgs[I] := POleVariant(PByte(P.rgvarg) + (P.cArgs - 1 - I) * SizeOf(OleVariant))^;
  if Fail then
  begin
    FillChar(PExcepInfo(ExcepInfo)^, SizeOf(TExcepInfo), 0);
    PExcepInfo(ExcepInfo)^.bstrSource := 'Script';
    PExcepInfo(ExcepInfo)^.bstrDescription := 'script failure';
    PExcepInfo(ExcepInfo)^.scode := E_FAIL;
    Exit(DISP_E_EXCEPTION);
  end;
  if VarResult <> nil then
    POleVariant(VarResult)^ := ReturnValue;
  Result := S_OK;
end;

function RaisesOle(const What: string; Proc: TProc; const Expect: string): Boolean;
begin
  Result := False;
  try
    Proc;
    WriteLn('  (no exception for ', What, ')');
  except
    on E: EOleException do
    begin
      Result := (Expect = '') or (Pos(Expect, E.Message) > 0) or (Pos(Expect, E.Source) > 0);
      if not Result then
        WriteLn('  (', What, ': ', E.Source, ': ', E.Message, ')');
    end;
    on E: EOleError do
      Result := Expect = '';
  end;
end;

{ In its own routine, so no hidden temporary keeps the proxy alive. }
procedure ImplementAndDrop(const JVM: OleVariant);
var
  Obj: IDispatch;
  R: OleVariant;
begin
  Obj := TScriptObject.Create;
  R := JVM.Implement('java.lang.Runnable', Obj);
end;

var
  JVM, L, SB, M, T, F, R, Arr, E, Host, Fn: OleVariant;
  Enum: IEnumVARIANT;
  Fetched: LongWord;
  Item: OleVariant;
  Sum, I: Integer;
  ClassPath: string;
  CheckJNI: Boolean;
  Opts: OleVariant;
  Script, Comparator, Func: TScriptObject;
  ScriptIntf, ComparatorIntf, FuncIntf: IDispatch;
begin
  CoInitialize(nil);
  ClassPath := '';
  CheckJNI := False;
  I := 1;
  while I <= ParamCount do
  begin
    if ParamStr(I) = '--classpath' then
    begin
      Inc(I);
      ClassPath := ParamStr(I);
    end
    else if ParamStr(I) = '--checkjni' then
      CheckJNI := True;
    Inc(I);
  end;
  try
    JVM := JavaComJVM;
    WriteLn('Entry object');
    Check(not JVM.Running, 'Running before Start');
    if CheckJNI then
      Opts := VarArrayOf(['-Xcheck:jni'])
    else
      Opts := VarArrayOf([]);
    Check(JVM.Start(ClassPath, Opts) = True, 'Start');
    Check(JVM.Running, 'Running after Start');
    Check(JVM.Start(ClassPath) = False, 'second Start is a no-op');

    WriteLn('Objects and overloads');
    L := JVM.New('java.util.ArrayList');
    L.add(42);
    L.add('x');
    L.add(Null);
    Check(L.size = 3, 'ArrayList.add/size');
    Check(L.get(0) = 42, 'Integer result');
    Check(L.get(1) = 'x', 'String result');
    Check(VarIsNull(L.get(2)), 'null -> Null');
    Check(VarType(L.size) = varInteger, 'int -> VT_I4');
    Check(L.isEmpty = False, 'boolean result');
    Check(L.toString = '[42, x, null]', 'toString');
    SB := JVM.New('java.lang.StringBuilder', 'ab');
    SB.append(1);
    SB.append(2.5);
    SB.append(True);
    SB.append('z');
    Check(SB.toString = 'ab12.5truez', 'StringBuilder.append overloads (int, double, boolean, String)');
    T := JVM.New('demo.Torture');
    Check(T.over(1) = 'int', 'overload: int');
    Check(T.over('s') = 'String', 'overload: String');
    Check(T.over(1, 'b') = 'int,String', 'overload: int,String');
    Check(T.over(Int64(5000000000)) = 'long', 'overload: long');
    Check(T.over(1.5) = 'Base.double', 'overload: double (inherited)');
    Check(T.over(SB) = 'StringBuilder', 'overload: Java object argument');
    Check(JVM.New('demo.Torture', 'abcd').counter = 4, 'constructor overload (String)');
    Check(JVM.New('demo.Torture', 7).counter = 7, 'constructor overload (int)');

    WriteLn('Fields and properties');
    Check(T.counter = 41, 'field read (wins over the method counter())');
    T.counter := 99;
    Check(T.counter = 99, 'field write');
    Check(T.baseField = 7, 'inherited field');
    F := JVM.New('java.io.File', 'C:\temp\x.txt');
    Check(F.Name = 'x.txt', 'getter getName as property Name');
    Check(F.absolute = True, 'getter isAbsolute as property');
    Check((T.getURL = 'getURL') and (T.getUrl = 'getUrl'), 'exact case preferred');
    Check(T.Destroy = 'Destroy', 'Java method named Destroy');

    WriteLn('Statics');
    M := JVM.Static('java.lang.Math');
    Check(M.max(1, 2) = 2, 'static method');
    Check(Abs(M.PI - 3.14159265) < 1E-6, 'static field');
    Check(JVM.Static('java.lang.Integer').MAX_VALUE = MaxInt, 'static final field');
    Check(JVM.Static('demo.Torture').describe(3) = 'static 3', 'static/instance same name (static)');
    Check(T.describe = 'instance', 'static/instance same name (instance)');
    Check(JVM.Static('java.lang.Character').isDigit('5'), 'String of length 1 -> char');
    Check(JVM.Static('java.lang.String').format('%d-%s', 5, 'x') = '5-x', 'varargs');
    Check(JVM.Static('java.util.List').of(1, 2, 3).size = 3, 'static interface method');
    R := JVM.Static('java.lang.System').currentTimeMillis;
    Check(VarType(R) = varInt64, 'long outside int range -> VT_I8');
    Check(JVM.Static('java.lang.Long').valueOf(5) = 5, 'small long -> VT_I4');
    Check(JVM.Static('java.lang.Integer').toBinaryString(3.0) = '11', 'whole Double -> int');

    WriteLn('Arrays');
    Arr := T.squares(4);
    Check(VarIsArray(Arr) and (VarArrayHighBound(Arr, 1) = 3) and (Arr[3] = 9), 'int[] -> variant array');
    Check(T.sum(VarArrayOf([1, 2, 3])) = 6, 'variant array -> int[]');
    Check(T.join(VarArrayOf(['a', 'b'])) = 'a+b', 'variant array -> String[]');
    Check(T.split('a,b,c')[2] = 'c', 'String[] result');
    Check(T.unicode('x') = 'x ' + #$00E9#$4E2D#$D83D#$DE00, 'unicode round trip');

    WriteLn('Default member and For Each');
    Check(CallDispId(L, DISPID_VALUE, DISPATCH_METHOD or DISPATCH_PROPERTYGET, [1]) = 'x',
      'DISPID_VALUE with an index -> get');
    CallDispId(L, DISPID_VALUE, DISPATCH_PROPERTYPUT, [1, 'y']);
    Check(L.get(1) = 'y', 'DISPID_VALUE put -> set');
    Check(CallDispId(SB, DISPID_VALUE, DISPATCH_PROPERTYGET, []) = 'ab12.5truez',
      'DISPID_VALUE without arguments -> toString');
    L := JVM.New('java.util.ArrayList');
    L.add(1); L.add(2); L.add(3);
    E := CallDispId(L, DISPID_NEWENUM, DISPATCH_METHOD or DISPATCH_PROPERTYGET, []);
    Enum := IUnknown(E) as IEnumVARIANT;
    Sum := 0;
    while Enum.Next(1, Item, Fetched) = S_OK do
      Sum := Sum + Integer(Item);
    Check(Sum = 6, '_NewEnum over a List (For Each)');

    WriteLn('Cast');
    Check(JVM.Cast(L, 'java.util.List').size = 3, 'Cast to an interface');
    Check(RaisesOle('Cast', procedure begin JVM.Cast(L, 'java.lang.String') end,
      'ClassCastException'), 'invalid Cast raises');
    Check(RaisesOle('restricted view', procedure begin JVM.Cast(L, 'java.util.Collection').get(0) end,
      ''), 'Cast restricts the visible members');

    WriteLn('Errors');
    Check(RaisesOle('Java exception', procedure begin T.fail('boom') end,
      'java.lang.IllegalStateException'), 'Java exception -> EOleException (source = class)');
    Check(RaisesOle('Java exception message', procedure begin T.fail('boom') end, 'boom'),
      'Java exception message');
    Check(RaisesOle('unknown member', procedure begin L.noSuchMethod end, ''), 'unknown member');
    Check(RaisesOle('no matching overload', procedure begin T.over(1, 2, 3, 4) end, 'no overload'),
      'no matching overload');
    Check(RaisesOle('unknown class', procedure begin JVM.New('no.such.Class') end,
      'ClassNotFoundException'), 'unknown class');

    WriteLn('Callbacks');
    Script := TScriptObject.Create;
    ScriptIntf := Script;
    Script.MethodName := 'run';
    R := JVM.Implement('java.lang.Runnable', ScriptIntf);
    Host := JVM.Static('demo.CallbackHost');
    Check(Host.runCatching(R) = 'no exception', 'Runnable implemented by a COM object');
    Check(Script.Calls = 1, 'COM method called');
    Comparator := TScriptObject.Create;
    ComparatorIntf := Comparator;
    Comparator.ReturnValue := -1;
    Comparator.MethodName := 'compare';
    L := JVM.New('java.util.ArrayList');
    L.add('b'); L.add('a');
    L.sort(JVM.Implement('java.util.Comparator', ComparatorIntf));
    Check((Comparator.Calls > 0) and (Length(Comparator.LastArgs) = 2), 'Comparator called with 2 args');
    Func := TScriptObject.Create;
    FuncIntf := Func;
    Func.ReturnValue := 'from script';
    Fn := JVM.Implement('java.util.function.Function', FuncIntf);   { default member only }
    Check(Host.applyTwice(Fn, 'x') = 'from script', 'default member as the method (JScript function)');
    Check(Func.Calls = 2, 'called twice');
    Check(Func.LastArgs[0] = 'from script', 'callback argument converted');
    Script.Fail := True;
    Check(Pos('script failure', Host.runCatching(R)) > 0, 'COM exception -> Java RuntimeException');
    Script.Fail := False;

    WriteLn('Callback threads and lifetime');
    WriteLn('  (expected below: Java reports a RuntimeException in thread java-worker)');
    I := Script.Calls;
    Host.runInThread(R);
    Check(Script.Calls = I, 'COM object not called on a Java-created thread');
    I := Destroyed;
    ImplementAndDrop(JVM);
    Host.gc;   { Java releases the proxy on its Cleaner thread: deferred }
    JVM.Running;   { any call into JavaBridgeCom on this thread releases it }
    Check(Destroyed = I + 1, 'COM object released after Java GC');
    Check(DestroyedOnMain, 'released on the thread that passed it');
  except
    on Ex: Exception do
    begin
      WriteLn('UNEXPECTED ', Ex.ClassName, ': ', Ex.Message);
      Inc(Failures);
    end;
  end;
  WriteLn;
  if Failures = 0 then
    WriteLn('ALL TESTS PASSED')
  else
    WriteLn(Failures, ' TEST(S) FAILED');
  ExitCode := Ord(Failures > 0);
end.
