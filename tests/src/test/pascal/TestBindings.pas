program TestBindings;

{ Exercises the generated JDemo unit. Compiles with FPC and Delphi. }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}
{$IFDEF MSWINDOWS}{$APPTYPE CONSOLE}{$ENDIF}

uses
  {$IFDEF FPC}
  {$IFDEF UNIX}cthreads,{$ENDIF}   { FPC needs this for threads on Unix }
  SysUtils, Classes,
  {$ELSE}
  System.SysUtils, System.Classes,
  {$ENDIF}
  JavaBridge, JDemo;

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

procedure TestGreeter;
var
  G: IJGreeter;
begin
  WriteLn('Greeter');
  Check(TJGreeter.add(40, 2) = 42, 'static int method');
  Check(Pos('Hello Pascal', TJGreeter.greet('Pascal')) = 1, 'static String method');
  G := TJGreeter.New('>> ');
  Check(G.decorate('x') = '>> x', 'constructor + instance method');
  Check(G.toString <> '', 'inherited java.lang.Object.toString');
end;

procedure TestTorture;
var
  T: IJTorture;
  B: IJBase;
  O: IJObject;
  SB: IJStringBuilder;
  Ints: TJavaIntArray;
  Strs: TJavaStringArray;
  L: IJList;
  It: IJIterator;
  S: UnicodeString;
  R: IJRunnable;
begin
  WriteLn('Torture');
  T := TJTorture.New;
  Check((T.&type = 1) and (T.&begin = 2) and (T.&end = 3) and (T.&read = 4)
    and (T.&index = 5) and (T.&string = 6), 'keywords as method names');
  Check(T.Destroy = 'Destroy', 'method named Destroy');
  Check(T.Free = 'Free', 'method named Free');
  Check(T.ClassName = 'ClassName', 'method named ClassName');
  Check(T.QueryInterface_1 = 7, 'QueryInterface renamed');
  Check(T._AddRef_1 = 8, '_AddRef renamed');
  Check(T.RefCount = 9, 'RefCount');
  Check(T.JavaGlobalRef = 10, 'JavaGlobalRef (runtime member name)');
  Check(T.JrCall_1 = 12, 'JrCall renamed');
  Check(T.Result_1 = 13, 'Result renamed');
  Check(T.Self_2 = 14, 'Self renamed');
  Check(T.IJObject_1 = 16, 'type name as method name');
  Check(T.Integer_1 = 17, 'Integer as method name');
  Check(T.p0 = 18, 'p0 as method name');
  Check((T.getURL = 'getURL') and (T.getUrl_1 = 'getUrl'), 'case-only difference');
  Check(T.over(1) = 'int', 'overload int');
  Check(T.over(Int64(1)) = 'long', 'overload long');
  Check(T.over('s') = 'String', 'overload String');
  Check(T.over(1, 'x') = 'int,String', 'overload int,String');
  SB := TJStringBuilder.New;
  Check(T.over(SB) = 'StringBuilder', 'overload wrapped type');
  Check(T.over(1.5) = 'Base.double', 'overload inherited from Base');
  T.over;
  Check(T.counter = 42, 'method counter()');
  Check(T.counter_1 = 41, 'field counter (getter)');
  T.Set_counter(100);
  Check(T.counter_1 = 100, 'field counter (setter)');
  Check(T.baseField = 7, 'inherited field');
  Check(TJTorture.describe(3) = 'static 3', 'static/instance same name (static)');
  Check(T.describe = 'instance', 'static/instance same name (instance)');
  Check(TJTorture.cast_1('a') = 'cast:a', 'static named cast renamed');
  Check(TJTorture.New_1 = 'static New', 'static named New renamed');
  Check(TJTorture.instances >= 1, 'static field');
  Check(TJTorture.New(5).counter_1 = 5, 'constructor (int)');
  Check(TJTorture.New('abc').counter_1 = 3, 'constructor (String)');

  Ints := T.squares(5);
  Check((Length(Ints) = 5) and (Ints[4] = 16), 'int[] result');
  Check(T.sum(Ints) = 30, 'int[] parameter');
  Strs := T.split('a,b,c');
  Check((Length(Strs) = 3) and (Strs[2] = 'c'), 'String[] result');
  Check(T.join(Strs) = 'a+b+c', 'String[] parameter');
  S := T.unicode('x');
  Check(S = 'x ' + #$00E9#$4E2D#$D83D#$DE00, 'unicode round trip');
  Check(T.nullString = '', 'null String -> empty');
  Check(T.caf_u00E9 = 'caf' + #$00E9, 'non-ASCII identifier');

  B := T.self_1;                                 { Java self() -> self_1 (Self is reserved) }
  Check(B.who = 'Torture', 'virtual dispatch through base interface');
  Check(TJTorture.IsInstance(B), 'IsInstance');
  Check(TJTorture.Cast(B).&type = 1, 'Cast to subtype');
  O := B;                                        { interface upcast }
  Check(TJBase.Cast(O).who = 'Torture', 'upcast + Cast');
  Check(not TJGreeter.IsInstance(O), 'IsInstance negative');
  try
    TJGreeter.Cast(O);
    Check(False, 'invalid cast raises');
  except
    on E: EJavaCastError do Check(True, 'invalid cast raises EJavaCastError');
  end;
  Check(JavaSameObject(T, B), 'JavaSameObject');
  Check(JavaClassNameOf(B) = 'demo.Torture', 'JavaClassNameOf');

  R := TJRunnable.Cast(T);                       { Torture implements Runnable }
  R.run;
  Check(T.counter_1 = 101, 'Java interface via Cast');

  L := T.list('one', 'two');
  Check(L.size = 2, 'List.size');
  It := L.iterator;
  S := '';
  while It.hasNext do
    S := S + It.next.toString;
  Check(S = 'onetwo', 'Iterator');

  try
    T.fail('boom');
    Check(False, 'exception raised');
  except
    on E: EJavaException do
      Check((E.JavaClassName = 'java.lang.IllegalStateException') and (Pos('boom', E.Message) > 0),
        'Java exception -> EJavaException (' + string(E.Message) + ')');
  end;

  Check(TJTorture_Inner.New.hello = 'inner', 'nested class');
end;

procedure TestCollections;
var
  M: IJHashMap;
  L: IJArrayList;
  SB: IJStringBuilder;
  I: Integer;
begin
  WriteLn('Collections');
  L := TJArrayList.New;
  for I := 1 to 3 do
    L.add(TJStringBuilder.New(UnicodeString(IntToStr(I))));
  Check(L.size = 3, 'ArrayList.add/size');
  Check(L.get(1).toString = '2', 'ArrayList.get + toString');
  M := TJHashMap.New;
  M.put(TJStringBuilder.New('k'), L);
  Check(M.size = 1, 'HashMap.put/size');
  SB := TJStringBuilder.New;
  SB.append('a').append(1).append(True);
  Check(SB.toString = 'a1true', 'fluent StringBuilder');
end;

{ ---- callbacks: Pascal classes implementing Java interfaces ---- }
type
  TListener = class(TInterfacedObject, IJCallbackHost_ListenerCallback)
  public
    Log: UnicodeString;
    procedure onEvent(const p0: UnicodeString; p1: Integer);
  end;

  TCalculator = class(TInterfacedObject, IJCallbackHost_CalculatorCallback)
  public
    function apply(p0, p1: Integer): Integer;
    function scale(p0: Double): Double;
    function test(p0: Int64; p1: WideChar): Boolean;
    function &name: UnicodeString;
    function range(p0: Integer): TJavaIntArray;
    function wrap(const p0: UnicodeString): IJList;
  end;

  { re-lists the interface so its own apply is used; the rest comes from TCalculator }
  TReentrant = class(TCalculator, IJCallbackHost_CalculatorCallback)
  public
    function apply(p0, p1: Integer): Integer;
  end;

  TByLength = class(TInterfacedObject, IJComparatorCallback)
  public
    function compare(const p0, p1: IJObject): Integer;
  end;

  TDoubler = class(TInterfacedObject, IJFunctionCallback)
  public
    function apply(const p0: IJObject): IJavaObject;
  end;

  TThreadRunnable = class(TInterfacedObject, IJRunnableCallback)
  public
    RanOn: TThreadID;
    procedure run;
  end;

  TFailing = class(TInterfacedObject, IJRunnableCallback)
  public
    JavaFailure: Boolean;
    procedure run;
  end;

var
  CallbackObjectsAlive: Integer = 0;

type
  TCounted = class(TInterfacedObject, IJRunnableCallback)
  public
    constructor Create;
    destructor Destroy; override;
    procedure run;
  end;

procedure TListener.onEvent(const p0: UnicodeString; p1: Integer);
begin
  Log := Log + p0 + '=' + UnicodeString(IntToStr(p1)) + ';';
end;

function TCalculator.apply(p0, p1: Integer): Integer; begin Result := p0 * 10 + p1; end;
function TCalculator.scale(p0: Double): Double; begin Result := p0 * 2; end;
function TCalculator.test(p0: Int64; p1: WideChar): Boolean; begin Result := (p0 = 5) and (p1 = 'x'); end;
function TCalculator.&name: UnicodeString; begin Result := 'pascal ' + #$00E9; end;
function TCalculator.range(p0: Integer): TJavaIntArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, p0);
  for I := 0 to p0 - 1 do
    Result[I] := I + 1;
end;
function TCalculator.wrap(const p0: UnicodeString): IJList;
var
  L: IJArrayList;
begin
  L := TJArrayList.New;
  L.add(TJStringBuilder.New('[' + p0 + ']'));
  Result := TJList.Cast(L);   { ArrayList implements List: checked cast }
end;

{ calls back into Java while Java is calling us }
function TReentrant.apply(p0, p1: Integer): Integer; begin Result := TJGreeter.add(p0, p1) * 100; end;

function TByLength.compare(const p0, p1: IJObject): Integer;
begin
  Result := Length(p0.toString) - Length(p1.toString);
end;

function TDoubler.apply(const p0: IJObject): IJavaObject;
begin
  Result := TJStringBuilder.New(p0.toString + p0.toString);
end;

procedure TThreadRunnable.run;
begin
  RanOn := GetCurrentThreadId;
end;

procedure TFailing.run;
begin
  if JavaFailure then
    TJTorture.New.fail('from java via pascal')
  else
    raise EInvalidOperation.Create('pascal failure');
end;

constructor TCounted.Create;
begin
  inherited Create;
  {$IFDEF FPC}InterlockedIncrement{$ELSE}AtomicIncrement{$ENDIF}(CallbackObjectsAlive);
end;

destructor TCounted.Destroy;
begin
  {$IFDEF FPC}InterlockedDecrement{$ELSE}AtomicDecrement{$ENDIF}(CallbackObjectsAlive);
  inherited Destroy;
end;

procedure TCounted.run;
begin
end;

procedure CreateManyCallbacks;
var
  I: Integer;
begin
  for I := 1 to 1000 do
    TJRunnable.Implement(TCounted.Create).run;
end;

procedure TestCallbacks;
var
  Host: IJCallbackHost;
  Lst: TListener;
  LstIntf: IJCallbackHost_ListenerCallback;
  S: UnicodeString;
  L: IJArrayList;
  TR: TThreadRunnable;
  TRIntf: IJRunnableCallback;
  F: TFailing;
  FIntf: IJRunnableCallback;
  Before: Integer;
begin
  WriteLn('Callbacks');
  Host := TJCallbackHost.New;
  Lst := TListener.Create;
  LstIntf := Lst;
  Host.addListener(TJCallbackHost_Listener.Implement(LstIntf));
  Host.fire('a', 1);
  Host.fire('b', 2);
  Check(Lst.Log = 'a=1;b=2;', 'listener (void, String + int args)');

  S := TJCallbackHost.useCalculator(TJCallbackHost_Calculator.Implement(TCalculator.Create));
  Check(Pos('23,3.0,true,calc:pascal ' + #$00E9 + ',[1, 2, 3],[w],PascalCallback[', S) = 1,
    'primitive/String/array/object args and results, default method (' + string(S) + ')');

  Check(TJCallbackHost.useCalculator(TJCallbackHost_Calculator.Implement(TReentrant.Create)) <> '',
    'reentrant: callback calls Java');
  Check(Pos('500,', TJCallbackHost.useCalculator(TJCallbackHost_Calculator.Implement(TReentrant.Create))) = 1,
    'reentrant result');

  L := TJArrayList.New;
  L.add(TJStringBuilder.New('ccc'));
  L.add(TJStringBuilder.New('a'));
  L.add(TJStringBuilder.New('bb'));
  L.sort(TJComparator.Implement(TByLength.Create));
  Check(L.toString = '[a, bb, ccc]', 'java.util.Comparator used by ArrayList.sort');

  Check(TJCallbackHost.applyTwice(TJFunction.Implement(TDoubler.Create),
    TJStringBuilder.New('ab')).toString = 'abababab', 'generic java.util.function.Function');

  TR := TThreadRunnable.Create;
  TRIntf := TR;
  TJCallbackHost.runInThread(TJRunnable.Implement(TRIntf));
  Check((TR.RanOn <> 0) and (TR.RanOn <> GetCurrentThreadId), 'callback on a Java-created thread');

  F := TFailing.Create;
  FIntf := F;
  S := TJCallbackHost.runCatching(TJRunnable.Implement(FIntf));
  Check(S = 'java.lang.RuntimeException: EInvalidOperation: pascal failure',
    'Pascal exception -> Java RuntimeException (' + string(S) + ')');
  F.JavaFailure := True;
  S := TJCallbackHost.runCatching(TJRunnable.Implement(FIntf));
  Check(S = 'java.lang.IllegalStateException: from java via pascal',
    'Java exception passes through a Pascal callback unchanged (' + string(S) + ')');

  Before := JavaCallbackCount;
  CreateManyCallbacks;   { separate routine: its hidden temporaries are released on return }
  Check(CallbackObjectsAlive > 0, 'callback objects kept alive by Java');
  TJCallbackHost.gc;
  Check(CallbackObjectsAlive = 0, 'callback objects released after Java GC (' +
    IntToStr(CallbackObjectsAlive) + ' left)');
  Check(JavaCallbackCount <= Before, 'JavaCallbackCount back to ' + IntToStr(JavaCallbackCount));
end;

type
  TWorker = class(TThread)
  public
    Ok: Boolean;
    procedure Execute; override;
  end;

procedure TWorker.Execute;
var
  I: Integer;
  L: IJArrayList;
begin
  Ok := False;
  try
    L := TJArrayList.New;
    for I := 1 to 20000 do
    begin
      L.add(TJStringBuilder.New(UnicodeString(IntToStr(I))));
      if TJGreeter.add(I, 1) <> I + 1 then Exit;
    end;
    Ok := (L.size = 20000) and (L.get(19999).toString = '20000');
    L := nil;
  finally
    JavaDetachThread;
  end;
end;

procedure TestThreads;
var
  W: array[0..7] of TWorker;
  I: Integer;
  AllOk: Boolean;
begin
  WriteLn('Threads');
  for I := 0 to High(W) do
    W[I] := TWorker.Create(False);
  AllOk := True;
  for I := 0 to High(W) do
  begin
    W[I].WaitFor;
    AllOk := AllOk and W[I].Ok;
    W[I].Free;
  end;
  Check(AllOk, '8 threads x 20000 calls/objects');
end;

procedure Benchmark;
const
  N = 5000000;
var
  I, Sum: Integer;
  T0: QWord;
begin
  Sum := 0;
  T0 := GetTickCount64;
  for I := 1 to N do
    Sum := TJGreeter.add(Sum, 1);
  WriteLn(Format('Benchmark: %d wrapped static calls, %.1f ns/call', [N,
    (GetTickCount64 - T0) * 1e6 / N]));
  T0 := GetTickCount64;
  TJCallbackHost.sumApply(TJCallbackHost_Calculator.Implement(TCalculator.Create), N div 5);
  WriteLn(Format('Benchmark: %d Java->Pascal callback calls, %.1f ns/call', [N div 5,
    (GetTickCount64 - T0) * 1e6 / (N div 5)]));
end;

var
  ClassPath: string;
  CheckJNI: Boolean;
  I: Integer;
begin
  { usage: TestBindings [--checkjni] [--classpath <dir-or-jars>]
    default class path: target/classes next to the executable (Maven layout) }
  ClassPath := ExtractFilePath(ParamStr(0)) + 'classes';
  CheckJNI := False;
  I := 1;
  while I <= ParamCount do
  begin
    if ParamStr(I) = '--checkjni' then
      CheckJNI := True
    else if (ParamStr(I) = '--classpath') and (I < ParamCount) then
    begin
      Inc(I);
      ClassPath := ParamStr(I);
    end;
    Inc(I);
  end;
  if CheckJNI then
    JavaStartVM('', ['-Djava.class.path=' + ClassPath, '-Xcheck:jni'])
  else
    JavaStartVM('', ['-Djava.class.path=' + ClassPath]);
  try
    TestGreeter;
    TestTorture;
    TestCollections;
    TestThreads;
    TestCallbacks;
  except
    on E: Exception do
    begin
      WriteLn('UNEXPECTED ', E.ClassName, ': ', E.Message);
      Inc(Failures);
    end;
  end;
  Benchmark;
  JavaStopVM;
  WriteLn;
  if Failures = 0 then WriteLn('ALL TESTS PASSED') else WriteLn(Failures, ' FAILURE(S)');
  ExitCode := Failures;
end.
