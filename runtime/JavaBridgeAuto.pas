{ JavaBridgeAuto - support for generated early-bound COM wrappers (Delphi, Windows).

  The generator option --com writes <unit>Com.pas: dual interfaces (IJFooDisp,
  IJFooClass) implemented by classes derived from TJavaAutoObject, plus a
  description of the type library. TJavaTypeLibBuilder turns that description
  into a type library through ICreateTypeLib2 at run time: in memory, for
  IDispatch (names, properties, argument coercion through DispInvoke), or as a
  .tlb file that is registered with the COM server, for C#, C++ and VB6.

  Types in a description: '' (void), 'I2', 'I4', 'I8', 'R4', 'R8', 'BOOL',
  'BSTR', 'VARIANT', 'DISPATCH', 'UNKNOWN', or the name of an interface in the
  library.
}
unit JavaBridgeAuto;

interface

uses
  Winapi.Windows, Winapi.ActiveX, System.SysUtils, System.Classes, System.SyncObjs,
  System.Variants, JavaBridge, JavaBridgeCom;

type
  TJavaInvokeKind = (jiMethod, jiGet, jiPut);

  { Collects a type library description, then builds it. }
  TJavaTypeLibBuilder = class
  private type
    TFunc = record
      Name: UnicodeString;
      DispId: Integer;
      Kind: TJavaInvokeKind;
      RetType: string;
      ParamTypes, ParamNames: TArray<string>;
    end;
    TIntf = record
      Name: UnicodeString;
      IID: TGUID;
      Parent: string;
      Doc: UnicodeString;
      Funcs: TArray<TFunc>;
      Create: ICreateTypeInfo;
    end;
    TCoClass = record
      Name: UnicodeString;
      CLSID: TGUID;
      DefaultIntf: string;
      Doc: UnicodeString;
    end;
  private
    FName, FDoc: UnicodeString;
    FLibID: TGUID;
    FIntfs: TArray<TIntf>;
    FCoClasses: TArray<TCoClass>;
    FCurrent: Integer;
    FStep: string;
    function IndexOf(const Name: string): Integer;
    function Build(const FileName: UnicodeString): ICreateTypeLib2;
  public
    constructor Create(const Name: UnicodeString; const LibID: TGUID; const Doc: UnicodeString);
    { Declares a dual interface; Parent '' means IDispatch. Functions added
      next belong to it, in vtable order. }
    procedure AddInterface(const Name: UnicodeString; const IID: TGUID; const Parent: string;
      const Doc: UnicodeString = '');
    procedure AddFunc(const Name: UnicodeString; DispId: Integer; Kind: TJavaInvokeKind;
      const RetType: string; const ParamTypes, ParamNames: array of string);
    procedure AddCoClass(const Name: UnicodeString; const CLSID: TGUID; const DefaultIntf: string;
      const Doc: UnicodeString = '');
    { Builds the library in memory. }
    function BuildInMemory: ITypeLib;
    { Writes it to FileName (a .tlb). }
    procedure SaveToFile(const FileName: UnicodeString);
    property LibID: TGUID read FLibID;
  end;

  TJavaTypeLibFunc = function: ITypeLib;

  { Base of the generated automation classes: IDispatch through the type
    library (DispInvoke on the dual interface), Java exceptions as IErrorInfo,
    IJavaHandle so the object can be passed to the late-bound layer too. }
  TJavaAutoObject = class(TInterfacedObject, IDispatch, ISupportErrorInfo, IJavaHandle)
  protected
    FJava: IJavaObject;
    FIID: TGUID;
    FTypeLib: TJavaTypeLibFunc;
    FTypeInfo: ITypeInfo;
    function TypeInfo: ITypeInfo;
    { IDispatch for another dual interface AIID of this object (the generated
      classes map that interface's IDispatch methods to these): its own type
      info, so DISPIDs and names are that interface's. }
    function TypeInfoFor(const AIID: TGUID): ITypeInfo;
    function GetTypeInfoFor(const AIID: TGUID; Index: Integer; out TypeInfo): HResult;
    function GetIDsOfNamesFor(const AIID: TGUID; Names: Pointer; NameCount: Integer;
      DispIDs: Pointer): HResult;
    function InvokeFor(const AIID: TGUID; DispID: Integer; Flags: Word; var Params;
      VarResult, ExcepInfo, ArgErr: Pointer): HResult;
  public
    { Obj: the wrapped Java object (nil for class objects); IID: the dual
      interface this object implements; TypeLib: returns the library. }
    constructor Create(const Obj: IJavaObject; const IID: TGUID; TypeLib: TJavaTypeLibFunc);
    function SafeCallException(ExceptObject: TObject; ExceptAddr: Pointer): HResult; override;
    { IDispatch }
    function GetTypeInfoCount(out Count: Integer): HResult; stdcall;
    function GetTypeInfo(Index, LocaleID: Integer; out TypeInfo): HResult; stdcall;
    function GetIDsOfNames(const IID: TGUID; Names: Pointer;
      NameCount, LocaleID: Integer; DispIDs: Pointer): HResult; stdcall;
    function Invoke(DispID: Integer; const IID: TGUID; LocaleID: Integer;
      Flags: Word; var Params; VarResult, ExcepInfo, ArgErr: Pointer): HResult; stdcall;
    { ISupportErrorInfo }
    function InterfaceSupportsErrorInfo(const iid: TIID): HResult; stdcall;
    { IJavaHandle }
    function JavaGlobalRef: jobject;
    property JavaObject: IJavaObject read FJava;
  end;

{ The Java object behind a COM object of this bridge (TJavaAutoObject or
  TJavaDispatch), as a new wrapper; nil for nil. Raises EJavaError for other
  COM objects. }
function JavaComObject(const D: IInterface): IJavaObject;

{ Stores Value in Slot (an interface variable) unless Slot is already set,
  thread-safely; used by generated classes to cache a wrapper. }
procedure JavaComCacheIntf(var Slot; const Value: IInterface);

{ Array conversions for generated code: variant arrays (any element types
  that convert) to Java arrays and back. }
function JrVarToBooleanArray(const V: OleVariant): TJavaBooleanArray;
function JrVarToByteArray(const V: OleVariant): TJavaByteArray;
function JrVarToCharArray(const V: OleVariant): TJavaCharArray;
function JrVarToShortArray(const V: OleVariant): TJavaShortArray;
function JrVarToIntArray(const V: OleVariant): TJavaIntArray;
function JrVarToLongArray(const V: OleVariant): TJavaLongArray;
function JrVarToFloatArray(const V: OleVariant): TJavaFloatArray;
function JrVarToDoubleArray(const V: OleVariant): TJavaDoubleArray;
function JrVarToStringArray(const V: OleVariant): TJavaStringArray;
function JrVarToObjectArray(const V: OleVariant): TJavaObjectArray;
function JrBooleanArrayToVar(const A: TJavaBooleanArray): OleVariant;
function JrByteArrayToVar(const A: TJavaByteArray): OleVariant;
function JrCharArrayToVar(const A: TJavaCharArray): OleVariant;
function JrShortArrayToVar(const A: TJavaShortArray): OleVariant;
function JrIntArrayToVar(const A: TJavaIntArray): OleVariant;
function JrLongArrayToVar(const A: TJavaLongArray): OleVariant;
function JrFloatArrayToVar(const A: TJavaFloatArray): OleVariant;
function JrDoubleArrayToVar(const A: TJavaDoubleArray): OleVariant;
function JrStringArrayToVar(const A: TJavaStringArray): OleVariant;
function JrObjectArrayToVar(const A: TJavaObjectArray): OleVariant;

{ Registers / unregisters a type library file, for all users or (PerUser)
  for the current user. }
procedure JavaRegisterTypeLib(const FileName: UnicodeString; PerUser: Boolean);
procedure JavaUnregisterTypeLib(const LibID: TGUID; PerUser: Boolean);

{ A Java char from a COM string of length 1. }
function JrComChar(const S: WideString): WideChar;

{ Starts the JVM unless it runs: class path, then options (strings or arrays
  of strings). False if it was already running. }
function JrComStart(const JvmPath: string; const ClassPath: WideString;
  const Options: OleVariant): Boolean;
{ Starts the JVM without options unless it runs. }
procedure JrComEnsureVM(const JvmPath: string);

type
  TJavaComCreateFunc = function: IDispatch;
  TJavaTypeLibMaker = function: TJavaTypeLibBuilder;

{ For a COM server's DllGetClassObject: a class factory for CLSID that
  creates objects with Create. }
function JavaComClassObject(const CLSID, IID: TGUID; var Obj; const ServedCLSID: TGUID;
  Create: TJavaComCreateFunc): HResult;

{ For a COM server's DllRegisterServer / DllUnregisterServer / DllInstall:
  (un)registers the class (CLSID, ProgID, InprocServer32 = this DLL,
  ThreadingModel Both) and the type library, which MakeLib describes and
  which is written next to the DLL as <dll name>.tlb. PerUser: HKCU instead
  of HKLM. }
function JavaComRegisterServer(Install, PerUser: Boolean; const CLSID: TGUID;
  const ProgID, Description: string; MakeLib: TJavaTypeLibMaker): HResult;

implementation

uses
  System.Win.ComObj, System.Win.Registry;

const
  IID_StdOle: TGUID = '{00020430-0000-0000-C000-000000000046}';

function RegisterTypeLibForUser(tlib: ITypeLib; szFullPath, szHelpDir: POleStr): HResult;
  stdcall; external 'oleaut32.dll' name 'RegisterTypeLibForUser';
function UnRegisterTypeLibForUser(const libID: TGUID; wVerMajor, wVerMinor: Word;
  lcid: TLCID; syskind: TSysKind): HResult; stdcall; external 'oleaut32.dll' name 'UnRegisterTypeLibForUser';

{ ---------------------------------------------------------------------------
  TJavaTypeLibBuilder
  --------------------------------------------------------------------------- }

constructor TJavaTypeLibBuilder.Create(const Name: UnicodeString; const LibID: TGUID;
  const Doc: UnicodeString);
begin
  inherited Create;
  FName := Name;
  FLibID := LibID;
  FDoc := Doc;
  FCurrent := -1;
end;

procedure TJavaTypeLibBuilder.AddInterface(const Name: UnicodeString; const IID: TGUID;
  const Parent: string; const Doc: UnicodeString);
var
  I: TIntf;
begin
  I := Default(TIntf);
  I.Name := Name;
  I.IID := IID;
  I.Parent := Parent;
  I.Doc := Doc;
  FIntfs := FIntfs + [I];
  FCurrent := High(FIntfs);
end;

procedure TJavaTypeLibBuilder.AddFunc(const Name: UnicodeString; DispId: Integer;
  Kind: TJavaInvokeKind; const RetType: string; const ParamTypes, ParamNames: array of string);
var
  F: TFunc;
  I: Integer;
begin
  if FCurrent < 0 then
    raise EJavaError.Create('AddFunc before AddInterface');
  F.Name := Name;
  F.DispId := DispId;
  F.Kind := Kind;
  F.RetType := RetType;
  SetLength(F.ParamTypes, Length(ParamTypes));
  SetLength(F.ParamNames, Length(ParamTypes));
  for I := 0 to High(ParamTypes) do
  begin
    F.ParamTypes[I] := ParamTypes[I];
    if I <= High(ParamNames) then
      F.ParamNames[I] := ParamNames[I]
    else
      F.ParamNames[I] := 'p' + IntToStr(I);
  end;
  FIntfs[FCurrent].Funcs := FIntfs[FCurrent].Funcs + [F];
end;

procedure TJavaTypeLibBuilder.AddCoClass(const Name: UnicodeString; const CLSID: TGUID;
  const DefaultIntf: string; const Doc: UnicodeString);
var
  C: TCoClass;
begin
  C.Name := Name;
  C.CLSID := CLSID;
  C.DefaultIntf := DefaultIntf;
  C.Doc := Doc;
  FCoClasses := FCoClasses + [C];
end;

function TJavaTypeLibBuilder.IndexOf(const Name: string): Integer;
begin
  for Result := 0 to High(FIntfs) do
    if SameText(FIntfs[Result].Name, Name) then
      Exit;
  Result := -1;
end;

function TJavaTypeLibBuilder.Build(const FileName: UnicodeString): ICreateTypeLib2;
var
  StdOle: ITypeLib;
  DispInfo: ITypeInfo;
  Lib: ICreateTypeLib2;

  function RefTo(const CTI: ICreateTypeInfo; const TI: ITypeInfo): HRefType;
  begin
    OleCheck(CTI.AddRefTypeInfo(TI, Result));
  end;

  function InfoOf(Index: Integer): ITypeInfo;
  begin
    Result := FIntfs[Index].Create as ITypeInfo;
  end;

  { Fills TD (and, for interface pointers, Inner) for a type name. }
  procedure SetType(const CTI: ICreateTypeInfo; const T: string; var TD: TTypeDesc;
    var Inner: TTypeDesc);
  var
    K: Integer;
  begin
    FillChar(TD, SizeOf(TD), 0);
    FillChar(Inner, SizeOf(Inner), 0);
    if T = '' then TD.vt := VT_VOID
    else if T = 'I2' then TD.vt := VT_I2
    else if T = 'I4' then TD.vt := VT_I4
    else if T = 'I8' then TD.vt := VT_I8
    else if T = 'R4' then TD.vt := VT_R4
    else if T = 'R8' then TD.vt := VT_R8
    else if T = 'BOOL' then TD.vt := VT_BOOL
    else if T = 'BSTR' then TD.vt := VT_BSTR
    else if T = 'VARIANT' then TD.vt := VT_VARIANT
    else if T = 'DISPATCH' then TD.vt := VT_DISPATCH
    else if T = 'UNKNOWN' then TD.vt := VT_UNKNOWN
    else
    begin
      K := IndexOf(T);
      if K < 0 then
        raise EJavaError.CreateFmt('Type library: unknown type %s', [T]);
      Inner.hreftype := RefTo(CTI, InfoOf(K));
      Inner.vt := VT_USERDEFINED;
      TD.ptdesc := @Inner;
      TD.vt := VT_PTR;
    end;
  end;

  procedure AddFuncs(Index: Integer);
  var
    CTI: ICreateTypeInfo;
    F: TFunc;
    FD: TFuncDesc;
    N, P, Total: Integer;
    Elems: array of TElemDesc;
    Inner: array of TTypeDesc;      { pointee of VT_PTR element types }
    Outer: array of TTypeDesc;      { the [out, retval] pointer types }
    Names: array of POleStr;
    NameStrs: array of UnicodeString;
    RetInner: TTypeDesc;
    HasRet: Boolean;
  begin
    CTI := FIntfs[Index].Create;
    for N := 0 to High(FIntfs[Index].Funcs) do
    begin
      F := FIntfs[Index].Funcs[N];
      HasRet := F.RetType <> '';
      Total := Length(F.ParamTypes) + Ord(HasRet);
      SetLength(Elems, Total);
      SetLength(Inner, Total + 1);
      SetLength(Outer, Total + 1);
      for P := 0 to High(F.ParamTypes) do
      begin
        SetType(CTI, F.ParamTypes[P], Elems[P].tdesc, Inner[P]);
        Elems[P].paramdesc.wParamFlags := PARAMFLAG_FIN;
      end;
      if HasRet then
      begin
        { [out, retval] T* }
        P := Total - 1;
        SetType(CTI, F.RetType, Outer[P], Inner[P]);
        if Outer[P].vt = VT_PTR then
        begin
          { interface: T** }
          RetInner := Outer[P];
          Outer[Total] := RetInner;
          Elems[P].tdesc.ptdesc := @Outer[Total];
        end
        else
          Elems[P].tdesc.ptdesc := @Outer[P];
        Elems[P].tdesc.vt := VT_PTR;
        Elems[P].paramdesc.wParamFlags := PARAMFLAG_FOUT or PARAMFLAG_FRETVAL;
      end;
      FillChar(FD, SizeOf(FD), 0);
      FD.memid := F.DispId;
      FD.funckind := FUNC_PUREVIRTUAL;
      case F.Kind of
        jiMethod: FD.invkind := INVOKE_FUNC;
        jiGet: FD.invkind := INVOKE_PROPERTYGET;
        jiPut: FD.invkind := INVOKE_PROPERTYPUT;
      end;
      FD.callconv := CC_STDCALL;
      FD.cParams := Total;
      if Total > 0 then
        FD.lprgelemdescParam := PElemDescList(@Elems[0]);
      FD.elemdescFunc.tdesc.vt := VT_HRESULT;
      FStep := 'AddFuncDesc ' + F.Name;
      OleCheck(CTI.AddFuncDesc(N, FD));
      FStep := 'names ' + F.Name;
      { names: the function, its parameters and the retval; a put's
        value parameter is unnamed) }
      SetLength(NameStrs, 1 + Length(F.ParamTypes));
      NameStrs[0] := F.Name;
      for P := 0 to High(F.ParamTypes) do
        NameStrs[P + 1] := F.ParamNames[P];
      if F.Kind = jiPut then
        SetLength(NameStrs, Length(NameStrs) - 1)
      else if HasRet then
        NameStrs := NameStrs + ['Result'];
      SetLength(Names, Length(NameStrs));
      for P := 0 to High(NameStrs) do
        Names[P] := PWideChar(NameStrs[P]);
      OleCheck(CTI.SetFuncAndParamNames(N, POleStrList(@Names[0]), Length(Names)));
    end;
  end;

var
  I, K: Integer;
  CTI: ICreateTypeInfo;
  Done: TArray<Boolean>;


  procedure LayOutWithParents(Index: Integer);
  var
    P: Integer;
  begin
    if Done[Index] then
      Exit;
    P := IndexOf(FIntfs[Index].Parent);
    if P >= 0 then
      LayOutWithParents(P);
    OleCheck(FIntfs[Index].Create.LayOut);
    Done[Index] := True;
  end;

begin
  FStep := 'stdole';
  try
  OleCheck(LoadRegTypeLib(IID_StdOle, 2, 0, 0, StdOle));
  OleCheck(StdOle.GetTypeInfoOfGuid(IDispatch, DispInfo));
  OleCheck(CreateTypeLib2({$IFDEF WIN64}SYS_WIN64{$ELSE}SYS_WIN32{$ENDIF}, PWideChar(FileName), Lib));
  OleCheck(Lib.SetGuid(FLibID));
  OleCheck(Lib.SetName(PWideChar(FName)));
  OleCheck(Lib.SetVersion(1, 0));
  OleCheck(Lib.SetLcid(0));
  if FDoc <> '' then
    OleCheck(Lib.SetDocString(PWideChar(FDoc)));
  FStep := 'interfaces';
  { 1. all interfaces exist, so functions can refer to any of them }
  for I := 0 to High(FIntfs) do
  begin
    OleCheck(Lib.CreateTypeInfo(PWideChar(FIntfs[I].Name), TKIND_INTERFACE, CTI));
    OleCheck(CTI.SetGuid(FIntfs[I].IID));
    OleCheck(CTI.SetVersion(1, 0));
    if FIntfs[I].Doc <> '' then
      OleCheck(CTI.SetDocString(PWideChar(FIntfs[I].Doc)));
    FIntfs[I].Create := CTI;
  end;
  FStep := 'functions';
  { 2. parents and functions }
  for I := 0 to High(FIntfs) do
  begin
    CTI := FIntfs[I].Create;
    K := IndexOf(FIntfs[I].Parent);
    if FIntfs[I].Parent = '' then
      OleCheck(CTI.AddImplType(0, RefTo(CTI, DispInfo)))
    else if K < 0 then
      raise EJavaError.CreateFmt('Type library: unknown parent %s', [FIntfs[I].Parent])
    else
      OleCheck(CTI.AddImplType(0, RefTo(CTI, InfoOf(K))));
    { dual requires the IDispatch ancestry to be known first }
    FStep := 'flags ' + FIntfs[I].Name;
    OleCheck(CTI.SetTypeFlags(TYPEFLAG_FDUAL or TYPEFLAG_FOLEAUTOMATION));
    AddFuncs(I);
  end;
  FStep := 'layout';
  { 3. lay out, parents first }
  SetLength(Done, Length(FIntfs));
  for I := 0 to High(FIntfs) do
    LayOutWithParents(I);
  FStep := 'coclasses';
  { 4. coclasses }
  for I := 0 to High(FCoClasses) do
  begin
    OleCheck(Lib.CreateTypeInfo(PWideChar(FCoClasses[I].Name), TKIND_COCLASS, CTI));
    OleCheck(CTI.SetGuid(FCoClasses[I].CLSID));
    OleCheck(CTI.SetTypeFlags(TYPEFLAG_FCANCREATE));
    if FCoClasses[I].Doc <> '' then
      OleCheck(CTI.SetDocString(PWideChar(FCoClasses[I].Doc)));
    K := IndexOf(FCoClasses[I].DefaultIntf);
    if K < 0 then
      raise EJavaError.CreateFmt('Type library: unknown interface %s', [FCoClasses[I].DefaultIntf]);
    OleCheck(CTI.AddImplType(0, RefTo(CTI, InfoOf(K))));
    OleCheck(CTI.SetImplTypeFlags(0, IMPLTYPEFLAG_FDEFAULT));
    OleCheck(CTI.LayOut);
  end;
  Result := Lib;
  except
    on E: Exception do
      raise EJavaError.CreateFmt('Type library %s (%s): %s', [FName, FStep, E.Message]);
  end;
end;

function TJavaTypeLibBuilder.BuildInMemory: ITypeLib;
begin
  Result := Build('') as ITypeLib;
end;

procedure TJavaTypeLibBuilder.SaveToFile(const FileName: UnicodeString);
begin
  OleCheck(Build(FileName).SaveAllChanges);
end;

{ ---------------------------------------------------------------------------
  Registration
  --------------------------------------------------------------------------- }

procedure JavaRegisterTypeLib(const FileName: UnicodeString; PerUser: Boolean);
var
  Lib: ITypeLib;
begin
  OleCheck(LoadTypeLibEx(PWideChar(FileName), REGKIND_NONE, Lib));
  if PerUser then
    OleCheck(RegisterTypeLibForUser(Lib, PWideChar(FileName), nil))
  else
    OleCheck(RegisterTypeLib(Lib, PWideChar(FileName), nil));
end;

procedure JavaUnregisterTypeLib(const LibID: TGUID; PerUser: Boolean);
var
  Kind: TSysKind;
begin
  Kind := {$IFDEF WIN64}SYS_WIN64{$ELSE}SYS_WIN32{$ENDIF};
  if PerUser then
    UnRegisterTypeLibForUser(LibID, 1, 0, 0, Kind)
  else
    UnRegisterTypeLib(LibID, 1, 0, 0, Kind);
end;

{ ---------------------------------------------------------------------------
  TJavaAutoObject
  --------------------------------------------------------------------------- }

constructor TJavaAutoObject.Create(const Obj: IJavaObject; const IID: TGUID;
  TypeLib: TJavaTypeLibFunc);
begin
  inherited Create;
  FJava := Obj;
  FIID := IID;
  FTypeLib := TypeLib;
end;

function TJavaAutoObject.TypeInfo: ITypeInfo;
var
  TI, Vtbl: ITypeInfo;
  Ref: HRefType;
begin
  if FTypeInfo = nil then
  begin
    OleCheck(FTypeLib().GetTypeInfoOfGuid(FIID, TI));
    { the vtable (TKIND_INTERFACE) half of the dual interface, for DispInvoke }
    if Succeeded(TI.GetRefTypeOfImplType(-1, Ref)) then
    begin
      OleCheck(TI.GetRefTypeInfo(Ref, Vtbl));   { not into TI: an out parameter is cleared first }
      TI := Vtbl;
    end;
    FTypeInfo := TI;
  end;
  Result := FTypeInfo;
end;

function TJavaAutoObject.SafeCallException(ExceptObject: TObject; ExceptAddr: Pointer): HResult;
var
  CEI: ICreateErrorInfo;
  Source, Desc: UnicodeString;
begin
  Result := E_UNEXPECTED;
  if Failed(CreateErrorInfo(CEI)) then
    Exit;
  Source := 'PascalJavaBridge';
  Desc := '';
  if ExceptObject is EJavaException then
  begin
    if EJavaException(ExceptObject).JavaClassName <> '' then
      Source := EJavaException(ExceptObject).JavaClassName;
    Desc := EJavaException(ExceptObject).Message;
  end
  else if ExceptObject is Exception then
    Desc := Exception(ExceptObject).Message;
  CEI.SetGUID(FIID);
  CEI.SetSource(PWideChar(Source));
  CEI.SetDescription(PWideChar(Desc));
  SetErrorInfo(0, CEI as IErrorInfo);
  if (ExceptObject is EOleSysError) and Failed(EOleSysError(ExceptObject).ErrorCode) then
    Result := EOleSysError(ExceptObject).ErrorCode
  else
    Result := E_FAIL;
end;

function TJavaAutoObject.GetTypeInfoCount(out Count: Integer): HResult;
begin
  Count := 1;
  Result := S_OK;
end;

function TJavaAutoObject.GetTypeInfo(Index, LocaleID: Integer; out TypeInfo): HResult;
begin
  Pointer(TypeInfo) := nil;
  if Index <> 0 then
    Exit(DISP_E_BADINDEX);
  try
    ITypeInfo(TypeInfo) := Self.TypeInfo;
    Result := S_OK;
  except
    Result := E_UNEXPECTED;
  end;
end;

function TJavaAutoObject.GetIDsOfNames(const IID: TGUID; Names: Pointer;
  NameCount, LocaleID: Integer; DispIDs: Pointer): HResult;
begin
  try
    JavaComReleasePending;
    Result := DispGetIDsOfNames(TypeInfo, Names, NameCount, DispIDs);
  except
    Result := E_UNEXPECTED;
  end;
end;

function TJavaAutoObject.Invoke(DispID: Integer; const IID: TGUID; LocaleID: Integer;
  Flags: Word; var Params; VarResult, ExcepInfo, ArgErr: Pointer): HResult;
var
  P: Pointer;
begin
  try
    JavaComReleasePending;
    if not GetInterface(FIID, P) then
      Exit(E_NOINTERFACE);
    try
      { "Set obj.prop = x" (PROPERTYPUTREF): the library only has property puts }
      if (Flags and DISPATCH_PROPERTYPUTREF) <> 0 then
        Flags := (Flags and not DISPATCH_PROPERTYPUTREF) or DISPATCH_PROPERTYPUT;
      Result := DispInvoke(P, TypeInfo, DispID, Flags, TDispParams(Params), VarResult,
        ExcepInfo, ArgErr);
    finally
      IInterface(P)._Release;
    end;
  except
    Result := E_UNEXPECTED;
  end;
end;

var
  GTypeInfoLock: TCriticalSection;
  GTypeInfoIIDs: TArray<TGUID>;
  GTypeInfos: TArray<ITypeInfo>;

{ The vtable half of dual interface IID in Lib, cached (IIDs are unique). }
function VtblTypeInfo(const Lib: ITypeLib; const IID: TGUID): ITypeInfo;
var
  TI, Vtbl: ITypeInfo;
  Ref: HRefType;
  I: Integer;
begin
  GTypeInfoLock.Acquire;
  try
    for I := 0 to High(GTypeInfoIIDs) do
      if IsEqualGUID(GTypeInfoIIDs[I], IID) then
        Exit(GTypeInfos[I]);
    OleCheck(Lib.GetTypeInfoOfGuid(IID, TI));
    if Succeeded(TI.GetRefTypeOfImplType(-1, Ref)) then
    begin
      OleCheck(TI.GetRefTypeInfo(Ref, Vtbl));
      TI := Vtbl;
    end;
    GTypeInfoIIDs := GTypeInfoIIDs + [IID];
    GTypeInfos := GTypeInfos + [TI];
    Result := TI;
  finally
    GTypeInfoLock.Release;
  end;
end;

function TJavaAutoObject.TypeInfoFor(const AIID: TGUID): ITypeInfo;
begin
  if IsEqualGUID(AIID, FIID) then
    Result := TypeInfo
  else
    Result := VtblTypeInfo(FTypeLib(), AIID);
end;

function TJavaAutoObject.GetTypeInfoFor(const AIID: TGUID; Index: Integer; out TypeInfo): HResult;
begin
  Pointer(TypeInfo) := nil;
  if Index <> 0 then
    Exit(DISP_E_BADINDEX);
  try
    ITypeInfo(TypeInfo) := TypeInfoFor(AIID);
    Result := S_OK;
  except
    Result := E_UNEXPECTED;
  end;
end;

const
  { A name that the extra interface doesn't have but the object's own (most
    specific) interface has gets that interface's DISPID plus this, so late-bound
    clients reach every member of the run-time class through any interface. }
  DISPID_OWN_BASE = $01000000;

function TJavaAutoObject.GetIDsOfNamesFor(const AIID: TGUID; Names: Pointer; NameCount: Integer;
  DispIDs: Pointer): HResult;
begin
  try
    JavaComReleasePending;
    Result := DispGetIDsOfNames(TypeInfoFor(AIID), Names, NameCount, DispIDs);
    if (Result = DISP_E_UNKNOWNNAME) and not IsEqualGUID(AIID, FIID) then
    begin
      Result := DispGetIDsOfNames(TypeInfo, Names, NameCount, DispIDs);
      if Succeeded(Result) and (PInteger(DispIDs)^ > 0) then
        Inc(PInteger(DispIDs)^, DISPID_OWN_BASE);
    end;
  except
    Result := E_UNEXPECTED;
  end;
end;

function TJavaAutoObject.InvokeFor(const AIID: TGUID; DispID: Integer; Flags: Word; var Params;
  VarResult, ExcepInfo, ArgErr: Pointer): HResult;
var
  P: Pointer;
begin
  if DispID >= DISPID_OWN_BASE then
    Exit(InvokeFor(FIID, DispID - DISPID_OWN_BASE, Flags, Params, VarResult, ExcepInfo, ArgErr));
  try
    JavaComReleasePending;
    if not GetInterface(AIID, P) then
      Exit(E_NOINTERFACE);
    try
      if (Flags and DISPATCH_PROPERTYPUTREF) <> 0 then
        Flags := (Flags and not DISPATCH_PROPERTYPUTREF) or DISPATCH_PROPERTYPUT;
      Result := DispInvoke(P, TypeInfoFor(AIID), DispID, Flags, TDispParams(Params), VarResult,
        ExcepInfo, ArgErr);
    finally
      IInterface(P)._Release;
    end;
  except
    Result := E_UNEXPECTED;
  end;
end;

procedure JavaComCacheIntf(var Slot; const Value: IInterface);
begin
  if (Value <> nil) and (TInterlocked.CompareExchange(Pointer(Slot), Pointer(Value), nil) = nil) then
    Value._AddRef;   { the slot now holds a reference }
end;

function TJavaAutoObject.InterfaceSupportsErrorInfo(const iid: TIID): HResult;
begin
  Result := S_OK;
end;

function TJavaAutoObject.JavaGlobalRef: jobject;
begin
  Result := JrHandle(FJava);
end;

{ ---------------------------------------------------------------------------
  Helpers
  --------------------------------------------------------------------------- }

function JavaComObject(const D: IInterface): IJavaObject;
var
  H: IJavaHandle;
begin
  if D = nil then
    Exit(nil);
  if not Supports(D, IJavaHandle, H) then
    raise EJavaError.Create('Not a Java object of this bridge');
  if H.JavaGlobalRef = nil then
    Exit(nil);
  Result := JavaWrapLocal(JrNewLocalRef(H.JavaGlobalRef));
end;

{ Elements of a 1-dimensional variant array (Null/Empty: no elements). }
function Elements(const V: OleVariant): TArray<OleVariant>;
var
  I, Lo: Integer;
  D: OleVariant;
begin
  Result := nil;
  if (TVarData(V).VType and varByRef) <> 0 then
  begin
    OleCheck(VariantCopyInd(D, V));
    Exit(Elements(D));
  end;
  if VarIsNull(V) or VarIsEmpty(V) then
    Exit;
  if not VarIsArray(V) or (VarArrayDimCount(V) <> 1) then
    raise EJavaError.Create('A 1-dimensional array is expected');
  Lo := VarArrayLowBound(V, 1);
  SetLength(Result, VarArrayHighBound(V, 1) - Lo + 1);
  for I := 0 to High(Result) do
    Result[I] := V[Lo + I];
end;

function JrVarToBooleanArray(const V: OleVariant): TJavaBooleanArray;
var E: TArray<OleVariant>; I: Integer;
begin
  E := Elements(V); SetLength(Result, Length(E));
  for I := 0 to High(E) do Result[I] := E[I];
end;

function JrVarToByteArray(const V: OleVariant): TJavaByteArray;
var E: TArray<OleVariant>; I: Integer;
begin
  E := Elements(V); SetLength(Result, Length(E));
  for I := 0 to High(E) do Result[I] := ShortInt(Integer(E[I]));
end;

function JrVarToCharArray(const V: OleVariant): TJavaCharArray;
var E: TArray<OleVariant>; I: Integer; S: string;
begin
  E := Elements(V); SetLength(Result, Length(E));
  for I := 0 to High(E) do
    if VarIsStr(E[I]) then
    begin
      S := E[I];
      if Length(S) <> 1 then
        raise EJavaError.Create('A char array element must be a 1-character string or a number');
      Result[I] := S[1];
    end
    else
      Result[I] := WideChar(Word(Integer(E[I])));
end;

function JrVarToShortArray(const V: OleVariant): TJavaShortArray;
var E: TArray<OleVariant>; I: Integer;
begin
  E := Elements(V); SetLength(Result, Length(E));
  for I := 0 to High(E) do Result[I] := SmallInt(Integer(E[I]));
end;

function JrVarToIntArray(const V: OleVariant): TJavaIntArray;
var E: TArray<OleVariant>; I: Integer;
begin
  E := Elements(V); SetLength(Result, Length(E));
  for I := 0 to High(E) do Result[I] := E[I];
end;

function JrVarToLongArray(const V: OleVariant): TJavaLongArray;
var E: TArray<OleVariant>; I: Integer;
begin
  E := Elements(V); SetLength(Result, Length(E));
  for I := 0 to High(E) do Result[I] := E[I];
end;

function JrVarToFloatArray(const V: OleVariant): TJavaFloatArray;
var E: TArray<OleVariant>; I: Integer;
begin
  E := Elements(V); SetLength(Result, Length(E));
  for I := 0 to High(E) do Result[I] := E[I];
end;

function JrVarToDoubleArray(const V: OleVariant): TJavaDoubleArray;
var E: TArray<OleVariant>; I: Integer;
begin
  E := Elements(V); SetLength(Result, Length(E));
  for I := 0 to High(E) do Result[I] := E[I];
end;

function JrVarToStringArray(const V: OleVariant): TJavaStringArray;
var E: TArray<OleVariant>; I: Integer;
begin
  E := Elements(V); SetLength(Result, Length(E));
  for I := 0 to High(E) do Result[I] := VarToStr(E[I]);
end;

function JrVarToObjectArray(const V: OleVariant): TJavaObjectArray;
var E: TArray<OleVariant>; I: Integer;
begin
  E := Elements(V); SetLength(Result, Length(E));
  for I := 0 to High(E) do Result[I] := JavaFromVariant(E[I]);
end;

function NewVarArray(N: Integer): OleVariant;
begin
  Result := VarArrayCreate([0, N - 1], varVariant);
end;

function JrBooleanArrayToVar(const A: TJavaBooleanArray): OleVariant;
var I: Integer;
begin
  Result := NewVarArray(Length(A));
  for I := 0 to High(A) do Result[I] := A[I];
end;

function JrByteArrayToVar(const A: TJavaByteArray): OleVariant;
var I: Integer;
begin
  Result := NewVarArray(Length(A));
  for I := 0 to High(A) do Result[I] := Integer(A[I]);
end;

function JrCharArrayToVar(const A: TJavaCharArray): OleVariant;
var I: Integer;
begin
  Result := NewVarArray(Length(A));
  for I := 0 to High(A) do Result[I] := WideString(A[I]);
end;

function JrShortArrayToVar(const A: TJavaShortArray): OleVariant;
var I: Integer;
begin
  Result := NewVarArray(Length(A));
  for I := 0 to High(A) do Result[I] := Integer(A[I]);
end;

function JrIntArrayToVar(const A: TJavaIntArray): OleVariant;
var I: Integer;
begin
  Result := NewVarArray(Length(A));
  for I := 0 to High(A) do Result[I] := A[I];
end;

function JrLongArrayToVar(const A: TJavaLongArray): OleVariant;
var I: Integer;
begin
  Result := NewVarArray(Length(A));
  for I := 0 to High(A) do Result[I] := A[I];
end;

function JrFloatArrayToVar(const A: TJavaFloatArray): OleVariant;
var I: Integer;
begin
  Result := NewVarArray(Length(A));
  for I := 0 to High(A) do Result[I] := A[I];
end;

function JrDoubleArrayToVar(const A: TJavaDoubleArray): OleVariant;
var I: Integer;
begin
  Result := NewVarArray(Length(A));
  for I := 0 to High(A) do Result[I] := A[I];
end;

function JrStringArrayToVar(const A: TJavaStringArray): OleVariant;
var I: Integer;
begin
  Result := NewVarArray(Length(A));
  for I := 0 to High(A) do Result[I] := WideString(A[I]);
end;

function JrObjectArrayToVar(const A: TJavaObjectArray): OleVariant;
var I: Integer;
begin
  Result := NewVarArray(Length(A));
  for I := 0 to High(A) do Result[I] := JavaToVariant(A[I]);
end;

{ ---------------------------------------------------------------------------
  Starting the JVM, chars
  --------------------------------------------------------------------------- }

function JrComChar(const S: WideString): WideChar;
begin
  if Length(S) <> 1 then
    raise EJavaError.CreateFmt('A Java char needs a string of length 1, not "%s"', [string(S)]);
  Result := S[1];
end;

procedure AddOptions(const V: OleVariant; var Opts: TArray<string>);
var
  I: Integer;
  D: OleVariant;
begin
  if (TVarData(V).VType and varByRef) <> 0 then
  begin
    OleCheck(VariantCopyInd(D, V));
    AddOptions(D, Opts);
  end
  else if VarIsArray(V) then
  begin
    for I := VarArrayLowBound(V, 1) to VarArrayHighBound(V, 1) do
      AddOptions(V[I], Opts);
  end
  else if not (VarIsNull(V) or VarIsEmpty(V) or (TVarData(V).VType = varError))
    and (VarToStr(V) <> '') then
    Opts := Opts + [VarToStr(V)];
end;

function JrComStart(const JvmPath: string; const ClassPath: WideString;
  const Options: OleVariant): Boolean;
var
  Opts: TArray<string>;
begin
  if JavaVMRunning then
    Exit(False);
  Opts := nil;
  if ClassPath <> '' then
    Opts := ['-Djava.class.path=' + string(ClassPath)];
  AddOptions(Options, Opts);
  JavaStartVM(JvmPath, Opts);
  Result := True;
end;

procedure JrComEnsureVM(const JvmPath: string);
begin
  if not JavaVMRunning then
    JavaStartVM(JvmPath, []);
end;

{ ---------------------------------------------------------------------------
  COM server support
  --------------------------------------------------------------------------- }

type
  TJavaComFactory = class(TInterfacedObject, IClassFactory)
  private
    FCreate: TJavaComCreateFunc;
  public
    constructor Create(ACreate: TJavaComCreateFunc);
    function CreateInstance(const UnkOuter: IUnknown; const IID: TGUID;
      out Obj): HResult; stdcall;
    function LockServer(fLock: BOOL): HResult; stdcall;
  end;

constructor TJavaComFactory.Create(ACreate: TJavaComCreateFunc);
begin
  inherited Create;
  FCreate := ACreate;
end;

function TJavaComFactory.CreateInstance(const UnkOuter: IUnknown; const IID: TGUID;
  out Obj): HResult;
begin
  Pointer(Obj) := nil;
  if UnkOuter <> nil then
    Exit(CLASS_E_NOAGGREGATION);
  try
    Result := FCreate().QueryInterface(IID, Obj);
  except
    Result := E_UNEXPECTED;
  end;
end;

function TJavaComFactory.LockServer(fLock: BOOL): HResult;
begin
  Result := S_OK;
end;

function JavaComClassObject(const CLSID, IID: TGUID; var Obj; const ServedCLSID: TGUID;
  Create: TJavaComCreateFunc): HResult;
begin
  Pointer(Obj) := nil;
  if not IsEqualGUID(CLSID, ServedCLSID) then
    Exit(CLASS_E_CLASSNOTAVAILABLE);
  Result := (TJavaComFactory.Create(Create) as IClassFactory).QueryInterface(IID, Obj);
end;

function ModulePath: string;
var
  Buf: array[0..MAX_PATH] of Char;
begin
  SetString(Result, Buf, GetModuleFileName(HInstance, Buf, Length(Buf)));
end;

function JavaComRegisterServer(Install, PerUser: Boolean; const CLSID: TGUID;
  const ProgID, Description: string; MakeLib: TJavaTypeLibMaker): HResult;
const
  BASE = 'Software\Classes\';
var
  Reg: TRegistry;
  ClsKey, LibFile: string;
  B: TJavaTypeLibBuilder;
  LibID: TGUID;

  procedure WriteKey(const Key, Name, Value: string);
  begin
    if not Reg.OpenKey(Key, True) then
      raise ERegistryException.CreateFmt('Cannot create %s', [Key]);
    Reg.WriteString(Name, Value);
    Reg.CloseKey;
  end;

begin
  ClsKey := GUIDToString(CLSID);
  LibFile := ChangeFileExt(ModulePath, '.tlb');
  try
    B := MakeLib();
    try
      LibID := B.LibID;
      if Install then
        B.SaveToFile(LibFile);
    finally
      B.Free;
    end;
    Reg := TRegistry.Create(KEY_READ or KEY_WRITE);
    try
      if PerUser then
        Reg.RootKey := HKEY_CURRENT_USER
      else
        Reg.RootKey := HKEY_LOCAL_MACHINE;
      if Install then
      begin
        WriteKey(BASE + ProgID, '', Description);
        WriteKey(BASE + ProgID + '\CLSID', '', ClsKey);
        WriteKey(BASE + 'CLSID\' + ClsKey, '', Description);
        WriteKey(BASE + 'CLSID\' + ClsKey + '\ProgID', '', ProgID);
        WriteKey(BASE + 'CLSID\' + ClsKey + '\TypeLib', '', GUIDToString(LibID));
        WriteKey(BASE + 'CLSID\' + ClsKey + '\Version', '', '1.0');
        WriteKey(BASE + 'CLSID\' + ClsKey + '\InprocServer32', '', ModulePath);
        WriteKey(BASE + 'CLSID\' + ClsKey + '\InprocServer32', 'ThreadingModel', 'Both');
      end
      else
      begin
        Reg.DeleteKey(BASE + 'CLSID\' + ClsKey + '\InprocServer32');
        Reg.DeleteKey(BASE + 'CLSID\' + ClsKey + '\Version');
        Reg.DeleteKey(BASE + 'CLSID\' + ClsKey + '\TypeLib');
        Reg.DeleteKey(BASE + 'CLSID\' + ClsKey + '\ProgID');
        Reg.DeleteKey(BASE + 'CLSID\' + ClsKey);
        Reg.DeleteKey(BASE + ProgID + '\CLSID');
        Reg.DeleteKey(BASE + ProgID);
      end;
    finally
      Reg.Free;
    end;
    if Install then
      JavaRegisterTypeLib(LibFile, PerUser)
    else
    begin
      JavaUnregisterTypeLib(LibID, PerUser);
      if FileExists(LibFile) then
        DeleteFile(LibFile);
    end;
    Result := S_OK;
  except
    on E: ERegistryException do
      Result := E_ACCESSDENIED;
    on E: EOleSysError do
      Result := E.ErrorCode;
    on E: Exception do
      Result := SELFREG_E_CLASS;
  end;
end;

initialization
  GTypeInfoLock := TCriticalSection.Create;

finalization
  GTypeInfos := nil;
  FreeAndNil(GTypeInfoLock);

end.
