program TestComEarly;

{ Exercises the generated early-bound COM wrappers (JDemoCom, from --com): vtable
  calls through the dual interfaces, IDispatch through the type library, and
  the type library itself. Delphi on Windows only; no COM registration needed. }

{$APPTYPE CONSOLE}

uses
  Winapi.Windows, Winapi.ActiveX, System.SysUtils, System.Variants, System.Win.ComObj,
  JavaBridge, JavaBridgeCom, JavaBridgeAuto, JDemoCom;

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

function RaisesOle(Proc: TProc; const Expect: string): Boolean;
begin
  Result := False;
  try
    Proc;
  except
    on E: EOleException do
      Result := (Pos(Expect, E.Message) > 0) or (Pos(Expect, E.Source) > 0);
    on E: EOleError do
      Result := Expect = '';
  end;
end;

{ A COM object with a method run, like a script class. }
type
  TRunner = class(TInterfacedObject, IDispatch)
  public
    Calls: Integer;
    function GetTypeInfoCount(out Count: Integer): HResult; stdcall;
    function GetTypeInfo(Index, LocaleID: Integer; out TypeInfo): HResult; stdcall;
    function GetIDsOfNames(const IID: TGUID; Names: Pointer;
      NameCount, LocaleID: Integer; DispIDs: Pointer): HResult; stdcall;
    function Invoke(DispID: Integer; const IID: TGUID; LocaleID: Integer;
      Flags: Word; var Params; VarResult, ExcepInfo, ArgErr: Pointer): HResult; stdcall;
  end;

function TRunner.GetTypeInfoCount(out Count: Integer): HResult;
begin
  Count := 0;
  Result := S_OK;
end;

function TRunner.GetTypeInfo(Index, LocaleID: Integer; out TypeInfo): HResult;
begin
  Result := E_NOTIMPL;
end;

function TRunner.GetIDsOfNames(const IID: TGUID; Names: Pointer;
  NameCount, LocaleID: Integer; DispIDs: Pointer): HResult;
begin
  PInteger(DispIDs)^ := 1;
  if SameText(PPWideChar(Names)^, 'run') then
    Result := S_OK
  else
    Result := DISP_E_UNKNOWNNAME;
end;

function TRunner.Invoke(DispID: Integer; const IID: TGUID; LocaleID: Integer;
  Flags: Word; var Params; VarResult, ExcepInfo, ArgErr: Pointer): HResult;
begin
  Inc(Calls);
  Result := S_OK;
end;

{ Typed callbacks: Delphi objects implementing the generated IJ...CallbackDisp
  interfaces. Their IDispatch fails, so the calls must go through the vtables. }
var
  GTypedDestroyed: Integer = 0;

type
  TNoDispatch = class(TInterfacedObject)
  public
    destructor Destroy; override;
    function GetTypeInfoCount(out Count: Integer): HResult; stdcall;
    function GetTypeInfo(Index, LocaleID: Integer; out TypeInfo): HResult; stdcall;
    function GetIDsOfNames(const IID: TGUID; Names: Pointer;
      NameCount, LocaleID: Integer; DispIDs: Pointer): HResult; stdcall;
    function Invoke(DispID: Integer; const IID: TGUID; LocaleID: Integer;
      Flags: Word; var Params; VarResult, ExcepInfo, ArgErr: Pointer): HResult; stdcall;
  end;

  TTypedRunner = class(TNoDispatch, IDispatch, IJRunnableCallbackDisp)
  public
    Calls: Integer;
    Fail: Boolean;
    procedure run; safecall;
  end;

  TTypedCalc = class(TNoDispatch, IDispatch, IJCallbackHost_CalculatorCallbackDisp)
  public
    Entry: IJDemoEntry;
    function apply(p0: Integer; p1: Integer): Integer; safecall;
    function &name: WideString; safecall;
    function range(p0: Integer): OleVariant; safecall;
    function scale(p0: Double): Double; safecall;
    function test(p0: Int64; const p1: WideString): WordBool; safecall;
    function wrap(const p0: WideString): IJListDisp; safecall;
  end;

  TTypedComparator = class(TNoDispatch, IDispatch, IJComparatorCallbackDisp)
  public
    function compare(const p0: OleVariant; const p1: OleVariant): Integer; safecall;
  end;

  TTypedSource = class(TNoDispatch, IDispatch, IJCallbackHost_SourceCallbackDisp)
  public
    function items(p0: Integer): OleVariant; safecall;
  end;

function TTypedSource.items(p0: Integer): OleVariant;
begin
  Result := VarArrayOf(['a', p0]);
end;

destructor TNoDispatch.Destroy;
begin
  Inc(GTypedDestroyed);
  inherited;
end;

function TNoDispatch.GetTypeInfoCount(out Count: Integer): HResult;
begin
  Count := 0;
  Result := E_NOTIMPL;
end;

function TNoDispatch.GetTypeInfo(Index, LocaleID: Integer; out TypeInfo): HResult;
begin
  Pointer(TypeInfo) := nil;
  Result := E_NOTIMPL;
end;

function TNoDispatch.GetIDsOfNames(const IID: TGUID; Names: Pointer;
  NameCount, LocaleID: Integer; DispIDs: Pointer): HResult;
begin
  Result := E_NOTIMPL;
end;

function TNoDispatch.Invoke(DispID: Integer; const IID: TGUID; LocaleID: Integer;
  Flags: Word; var Params; VarResult, ExcepInfo, ArgErr: Pointer): HResult;
begin
  Result := E_NOTIMPL;
end;

procedure TTypedRunner.run;
begin
  Inc(Calls);
  if Fail then
    raise Exception.Create('typed failure');
end;

function TTypedCalc.apply(p0: Integer; p1: Integer): Integer;
begin
  Result := p0 + p1;
end;

function TTypedCalc.&name: WideString;
begin
  Result := 'typed';
end;

function TTypedCalc.range(p0: Integer): OleVariant;
var
  I: Integer;
begin
  Result := VarArrayCreate([0, p0 - 1], varInteger);
  for I := 0 to p0 - 1 do
    Result[I] := I * I;
end;

function TTypedCalc.scale(p0: Double): Double;
begin
  Result := p0 * 2;
end;

function TTypedCalc.test(p0: Int64; const p1: WideString): WordBool;
begin
  Result := (p0 = 5) and (p1 = 'x');
end;

function TTypedCalc.wrap(const p0: WideString): IJListDisp;
var
  A: IJArrayListDisp;
begin
  A := Entry.ArrayList.New;
  A.add(p0 + p0);
  Result := Entry.List.Cast(A);
end;

function TTypedComparator.compare(const p0: OleVariant; const p1: OleVariant): Integer;
begin
  Result := Integer(p1) - Integer(p0);   { descending }
end;

{ In a procedure of its own, so no hidden temporary keeps the proxy alive. }
procedure TypedCallbackForGc(const E: IJDemoEntry);
var
  R: IJRunnableDisp;
  D: IDispatch;
begin
  D := TTypedRunner.Create;
  R := E.Runnable.Implement(D);
  E.CallbackHost.runCatching(R);
end;

function TypeName(const D: IDispatch): string;
var
  TI: ITypeInfo;
  N: WideString;
begin
  OleCheck(D.GetTypeInfo(0, 0, TI));
  OleCheck(TI.GetDocumentation(-1, @N, nil, nil, nil));
  Result := N;
end;

var
  E: IJDemoEntry;
  T: IJTortureDisp;
  B: IJBaseDisp;
  L: IJListDisp;
  AL, Sorted: IJArrayListDisp;
  LI: IJListDisp;
  LD: IDispatch;
  M: IJHashMapDisp;
  SB: IJStringBuilderDisp;
  R: IJRunnableDisp;
  V, Arr, Item: OleVariant;
  Enum: IEnumVARIANT;
  Fetched: LongWord;
  Runner: TRunner;
  RunnerIntf: IDispatch;
  TypedRunner: TTypedRunner;
  Calc: TTypedCalc;
  D: IDispatch;
  S: string;
  Destroyed: Integer;
  Lib: ITypeLib;
  LibB: TJavaTypeLibBuilder;
  LibFile: string;
  ClassPath, Opt: string;
  I, Sum: Integer;
begin
  CoInitialize(nil);
  ClassPath := '';
  Opt := '';
  I := 1;
  while I <= ParamCount do
  begin
    if ParamStr(I) = '--classpath' then
    begin
      Inc(I);
      ClassPath := ParamStr(I);
    end
    else if ParamStr(I) = '--checkjni' then
      Opt := '-Xcheck:jni';
    Inc(I);
  end;
  try
    WriteLn('Entry');
    E := JDemoComEntry;
    Check(not E.Running, 'Running before Start');
    Check(E.Start(ClassPath, Opt), 'Start');
    Check(E.Running, 'Running');

    WriteLn('Early binding (vtable)');
    Check(E.Greeter.add(40, 2) = 42, 'static method');
    Check(E.Greeter.New('>> ').decorate('x') = '>> x', 'constructor + instance method');
    T := E.Torture.New;
    Check((T.&type = 1) and (T.&begin = 2) and (T.&end = 3), 'keywords as member names');
    Check((T.Destroy = 'Destroy') and (T.Free = 'Free') and (T.Free_1(3) = 'Free3'),
      'TObject member names (Destroy, Free, Free_1)');
    Check((T.over_2('s') = 'String') and (T.over_3(1) = 'int') and (T.over_4(5) = 'long')
      and (T.over_7(1, 'b') = 'int,String') and (T.over(1.5) = 'Base.double'),
      'overloads have unique names');
    Check((T.Invoke_1 = 19) and (T.Release_1 = 20), 'IDispatch/IUnknown names renamed');
    Check(T.counter = 42, 'method counter()');
    Check(T.counter_1 = 41, 'field counter as property counter_1');
    T.counter_1 := 7;
    Check(T.counter = 8, 'property put');
    Check(E.Torture.New_2(5).counter_1 = 5, 'constructor New_2(int)');
    Check(E.Torture.New_1('abcd').counter_1 = 4, 'constructor New_1(String)');
    Check(E.Torture.describe(3) = 'static 3', 'static method on the class object');
    Check(E.Torture.instances >= 3, 'static field as property');
    Arr := T.squares(4);
    Check(VarIsArray(Arr) and (Arr[3] = 9), 'int[] -> variant array');
    Check(T.sum(VarArrayOf([1, 2, 3])) = 6, 'variant array -> int[]');
    Check(T.join(VarArrayOf(['a', 'b'])) = 'a+b', 'variant array -> String[]');
    Check(T.unicode('x') = 'x ' + #$00E9#$4E2D#$D83D#$DE00, 'unicode');
    Check(T.nullString = '', 'null String -> empty');
    B := T.self;
    Check(B.who = 'Torture', 'wrapped result, virtual dispatch');
    Check(Supports(B, IJTortureDisp), 'result typed IJBaseDisp is a Torture (QueryInterface)');
    Check(TypeName(B as IDispatch) = 'IJTortureDisp', 'result has the run-time class''s type info');
    V := B as IDispatch;
    Check(V.over_3(1) = 'int', 'subclass member by name on a Base result');
    V := Unassigned;
    Check(TypeName(E.Base.New.self as IDispatch) = 'IJBaseDisp', 'a plain Base stays IJBaseDisp');
    L := T.list('a', 'b');
    Check((L.size = 2) and (L.get(1) = 'b'), 'wrapped List result, Object result as VARIANT');
    L.add(42);
    Check(L.get(2) = 42, 'VARIANT argument (Object parameter)');
    M := E.HashMap.New;
    M.put('k', 42);
    Check(M.get('k') = 42, 'HashMap put/get with VARIANTs');
    SB := E.StringBuilder.New_1('ab');
    SB.append('c').append_1(1).append_3(2.5).append_4(True);
    Check(SB.toString = 'abc12.5true', 'fluent StringBuilder (append = String overload)');
    Check(T.over_5(SB) = 'StringBuilder', 'wrapped argument');
    AL := E.ArrayList.New;
    AL.add(1); AL.add(2); AL.add(3);
    Enum := AL._NewEnum as IEnumVARIANT;
    Sum := 0;
    while Enum.Next(1, Item, Fetched) = S_OK do
      Sum := Sum + Integer(Item);
    Check(Sum = 6, '_NewEnum (For Each)');
    Check(E.List.Cast(AL).size = 3, 'Cast to an interface');
    Check(E.List.IsInstance(AL) and not E.Map.IsInstance(AL), 'IsInstance');
    Check(Supports(AL, IJListDisp, LI) and (LI.size = 3) and (LI.get(0) = 1),
      'ArrayList implements IJListDisp (extra interface, vtable)');
    LD := LI;
    Check(TypeName(LD) = 'IJListDisp', 'IDispatch of the extra interface has its own type info');
    V := LD;
    Check(V.size = 3, 'late binding through the extra interface');
    V.trimToSize;
    Check(V.size = 3, 'run-time class member by name through the extra interface (trimToSize)');
    V := Unassigned;
    LD := nil;
    LI := nil;
    Check(Supports(T, IJRunnableDisp), 'Torture implements IJRunnableDisp (extra interface)');
    Check(TypeName(T.list('a', 'b') as IDispatch) = 'IJArrayListDisp',
      'List result is an IJArrayListDisp (run-time class through an extra interface)');
    Check(RaisesOle(procedure begin E.Map.Cast(AL) end, 'cannot be cast'), 'invalid Cast raises');
    Check(RaisesOle(procedure begin T.fail('boom') end, 'java.lang.IllegalStateException'),
      'Java exception -> EOleException, source = Java class');
    Check(RaisesOle(procedure begin T.fail('boom') end, 'boom'), 'Java exception message');
    Runner := TRunner.Create;
    RunnerIntf := Runner;
    R := E.Runnable.Implement(RunnerIntf);
    Check(E.CallbackHost.runCatching(R) = 'no exception', 'Implement: COM object as java.lang.Runnable');
    Check(Runner.Calls = 1, 'COM object called');

    WriteLn('Typed callbacks (vtable)');
    TypedRunner := TTypedRunner.Create;
    D := TypedRunner;
    R := E.Runnable.Implement(D);
    Check(E.CallbackHost.runCatching(R) = 'no exception', 'IJRunnableCallbackDisp as java.lang.Runnable');
    Check(TypedRunner.Calls = 1, 'called through the vtable (its IDispatch fails)');
    TypedRunner.Fail := True;
    Check(Pos('RuntimeException', string(E.CallbackHost.runCatching(R))) > 0,
      'exception in a typed callback -> Java RuntimeException');
    TypedRunner.Fail := False;
    R := nil;
    D := nil;
    Calc := TTypedCalc.Create;
    Calc.Entry := E;
    D := Calc;
    Calc := nil;
    S := E.CallbackHost.useCalculator(E.CallbackHost_Calculator.Implement(D));
    Check(Copy(S, 1, 35) ='5,3.0,true,calc:typed,[0, 1, 4],ww,', 'typed callback: all parameter and result types');
    D := TTypedComparator.Create;
    Sorted := E.ArrayList.New;
    Sorted.add(1); Sorted.add(3); Sorted.add(2);
    Sorted.sort(E.Comparator.Implement(D));
    D := nil;
    Check(Sorted.toString = '[3, 2, 1]', 'typed Comparator (VARIANT parameters)');
    D := TTypedSource.Create;
    Check(E.CallbackHost.joinItems(E.CallbackHost_Source.Implement(D), 7) = '[a, 7]',
      'typed callback returning Object[]');
    D := nil;
    Destroyed := GTypedDestroyed;
    TypedCallbackForGc(E);
    E.CallbackHost.gc;
    JavaComReleasePending;
    Check(GTypedDestroyed > Destroyed, 'typed callback released after Java GC');

    WriteLn('Late binding through the type library');
    V := T as IDispatch;
    Check(TypeName(T as IDispatch) = 'IJTortureDisp', 'GetTypeInfo');
    Check(V.over_3(1) = 'int', 'method by name');
    Check(V.counter_1 = 7, 'property get by name');
    V.counter_1 := 9;
    Check(T.counter_1 = 9, 'property put by name');
    Check(V.self.who = 'Torture', 'chained call');
    Check(VarType(V.squares(2)) and varArray <> 0, 'array result');
    Check(V.over(2) = 'Base.double', 'argument coerced to the declared type (int -> double)');
    V := AL as IDispatch;
    Check(V.toString = '[1, 2, 3]', 'inherited member');
    Check(RaisesOle(procedure begin V.noSuchMember end, ''), 'unknown name');
    V := E as IDispatch;
    Check(V.Greeter.add(1, 2) = 3, 'entry by name');
    Check(RaisesOle(procedure begin V.Torture.New.fail('late boom') end, 'late boom'),
      'Java exception through IDispatch');

    WriteLn('Type library');
    Lib := JDemoTypeLib;
    Check(Lib.GetTypeInfoCount >= 40, 'in-memory library has the interfaces');
    LibFile := ExtractFilePath(ParamStr(0)) + 'JDemoCom.tlb';
    LibB := JDemoNewTypeLibBuilder;
    try
      LibB.SaveToFile(LibFile);
    finally
      LibB.Free;
    end;
    OleCheck(LoadTypeLibEx(PWideChar(WideString(LibFile)), REGKIND_NONE, Lib));
    Check(Lib.GetTypeInfoCount >= 40, '.tlb written and loaded');
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
