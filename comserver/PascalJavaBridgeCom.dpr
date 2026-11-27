library PascalJavaBridgeCom;

{ In-process COM server for JavaBridgeCom (Delphi, Windows). It registers one
  class, ProgID PascalJavaBridge.JVM, whose objects are JavaComJVM entry
  objects (late binding through IDispatch, no type library):

    Set jvm = CreateObject("PascalJavaBridge.JVM")
    jvm.Start "myapp.jar"
    Set list = jvm.New("java.util.ArrayList")

  Registration:
    regsvr32 PascalJavaBridgeCom.dll              all users (elevated prompt)
    regsvr32 /n /i:user PascalJavaBridgeCom.dll   current user only
    regsvr32 /u [/n /i:user] ...                  unregister

  The JVM runs inside the client process: one JVM per process, with the
  bitness of the client (64-bit cscript or Office needs a 64-bit JDK and this
  DLL built with dcc64). The DLL is never unloaded once loaded, because a JVM
  can't be unloaded. }

uses
  Winapi.Windows, Winapi.ActiveX, System.SysUtils, System.Win.Registry,
  JavaBridge, JavaBridgeCom;

const
  { name-based like the generated GUIDs: pascal-java-bridge-com-clsid:PascalJavaBridge.JVM }
  CLSID_JVM: TGUID = '{2867DDA4-DC6B-321C-8D65-4514D273A5E5}';
  PROGID = 'PascalJavaBridge.JVM';
  DESCRIPTION = 'pascal-java-bridge JVM (late-bound access to Java)';

type
  TJvmFactory = class(TInterfacedObject, IClassFactory)
  public
    function CreateInstance(const UnkOuter: IUnknown; const IID: TGUID;
      out Obj): HResult; stdcall;
    function LockServer(fLock: BOOL): HResult; stdcall;
  end;

function TJvmFactory.CreateInstance(const UnkOuter: IUnknown; const IID: TGUID;
  out Obj): HResult;
begin
  Pointer(Obj) := nil;
  if UnkOuter <> nil then
    Exit(CLASS_E_NOAGGREGATION);
  try
    Result := JavaComJVM.QueryInterface(IID, Obj);
  except
    Result := E_UNEXPECTED;
  end;
end;

function TJvmFactory.LockServer(fLock: BOOL): HResult;
begin
  Result := S_OK;   { never unloaded anyway }
end;

function DllGetClassObject(const CLSID, IID: TGUID; var Obj): HResult; stdcall;
begin
  Pointer(Obj) := nil;
  if not IsEqualGUID(CLSID, CLSID_JVM) then
    Exit(CLASS_E_CLASSNOTAVAILABLE);
  Result := (TJvmFactory.Create as IClassFactory).QueryInterface(IID, Obj);
end;

function DllCanUnloadNow: HResult; stdcall;
begin
  Result := S_FALSE;   { a loaded JVM (and its threads calling into this DLL) can't go away }
end;

function ModulePath: string;
var
  Buf: array[0..MAX_PATH] of Char;
begin
  SetString(Result, Buf, GetModuleFileName(HInstance, Buf, Length(Buf)));
end;

procedure WriteKey(Reg: TRegistry; const Key, Name, Value: string);
begin
  if not Reg.OpenKey(Key, True) then
    raise ERegistryException.CreateFmt('Cannot create %s', [Key]);
  Reg.WriteString(Name, Value);
  Reg.CloseKey;
end;

{ Root: HKEY_LOCAL_MACHINE (all users) or HKEY_CURRENT_USER; keys under Software\Classes. }
function Register(Root: HKEY; Install: Boolean): HResult;
const
  BASE = 'Software\Classes\';
var
  Reg: TRegistry;
  Clsid: string;
begin
  Clsid := GUIDToString(CLSID_JVM);
  Reg := TRegistry.Create(KEY_READ or KEY_WRITE);
  try
    try
      Reg.RootKey := Root;
      if Install then
      begin
        WriteKey(Reg, BASE + PROGID, '', DESCRIPTION);
        WriteKey(Reg, BASE + PROGID + '\CLSID', '', Clsid);
        WriteKey(Reg, BASE + 'CLSID\' + Clsid, '', DESCRIPTION);
        WriteKey(Reg, BASE + 'CLSID\' + Clsid + '\ProgID', '', PROGID);
        WriteKey(Reg, BASE + 'CLSID\' + Clsid + '\InprocServer32', '', ModulePath);
        { the objects attach any thread to the JVM, so no apartment marshalling is needed }
        WriteKey(Reg, BASE + 'CLSID\' + Clsid + '\InprocServer32', 'ThreadingModel', 'Both');
      end
      else
      begin
        Reg.DeleteKey(BASE + 'CLSID\' + Clsid + '\InprocServer32');
        Reg.DeleteKey(BASE + 'CLSID\' + Clsid + '\ProgID');
        Reg.DeleteKey(BASE + 'CLSID\' + Clsid);
        Reg.DeleteKey(BASE + PROGID + '\CLSID');
        Reg.DeleteKey(BASE + PROGID);
      end;
      Result := S_OK;
    except
      on E: ERegistryException do
        Result := E_ACCESSDENIED;
    end;
  finally
    Reg.Free;
  end;
end;

function DllRegisterServer: HResult; stdcall;
begin
  Result := Register(HKEY_LOCAL_MACHINE, True);
end;

function DllUnregisterServer: HResult; stdcall;
begin
  Result := Register(HKEY_LOCAL_MACHINE, False);
end;

{ regsvr32 /n /i:user registers for the current user only (no elevation). }
function DllInstall(bInstall: BOOL; pszCmdLine: PWideChar): HResult; stdcall;
begin
  if SameText(pszCmdLine, 'user') then
    Result := Register(HKEY_CURRENT_USER, bInstall)
  else if bInstall then
    Result := DllRegisterServer
  else
    Result := DllUnregisterServer;
end;

exports
  DllGetClassObject,
  DllCanUnloadNow,
  DllRegisterServer,
  DllUnregisterServer,
  DllInstall;

begin
  IsMultiThread := True;   { JVM threads call into the DLL }
end.
