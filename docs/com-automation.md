# Design note: COM / Automation for Delphi

Status: **proposal, not implemented.** Written on 2026-11-27 so the work can continue on a
Windows machine. Nothing here has been compiled: development so far happened on Linux with
FPC only, and **Delphi has never compiled this project**. Step 0 below comes first.

## Goal

Make Java classes usable from COM clients (Excel/VBA, VBScript, PowerShell, C#, VB6, C++) through
a COM server written in Delphi and built on the existing wrappers:

```
COM client
   │  IDispatch (late binding)  or  dual-interface vtable (early binding)
   ▼
Delphi COM server  ── TJFooAuto delegates to ──►  IJFoo (existing wrapper) ── JNI ──► JVM
```

The COM layer is an **extra output for Delphi only**. The existing Pascal wrappers stay unchanged
and keep working on FPC.

## Step 0: get Delphi compiling (prerequisite)

1. Compile `runtime/JavaBridge.pas` and the generated `JDemo` (both layouts: single unit and
   `--unit-per-package`) plus `tests/src/test/pascal/TestBindings.pas` with dcc32/dcc64.
2. The riskiest construct is method resolution clauses on overloaded interface methods
   (`function IJFoo.bar = J_3;` where `J_3` is overloaded). FPC accepts one clause per name.
   Check whether Delphi does too, or needs something else.
3. Run the tests on Windows (FPC too, if possible: `stdcall` JNI calling convention, `jvm.dll`
   loading from `JAVA_HOME\bin\server`).
4. Add the Delphi build to the docs and, if practical, to Maven (an exec profile like
   `pascal-tests`, activated by a `dcc.executable` property).

## Part 1: late binding (do this first)

This needs no generated code. It is all runtime, in a new unit (e.g. `runtime/JavaBridgeCom.pas`):

- **`TJavaDispatch`**: implements `IDispatch` for *any* Java object (holds an `IJavaObject`).
  - `GetIDsOfNames`: looks up public methods/fields of the object's class by name, using
    reflection through JNI (`Class.getMethods`), case-insensitively. DISPIDs are cached per
    `jclass`.
  - `Invoke`: chooses the overload **at run time** from the actual `VARIANT` argument types and
    count (like Java's own overload resolution, simplified), converts the arguments, and calls
    through `java.lang.reflect.Method.invoke`, or better through a cached `jmethodID` +
    `Call*MethodA`. Property get/put map to public fields and to `getX`/`setX`.
  - Results: primitives/strings become `VARIANT`s; objects become a new `TJavaDispatch`.
- **Entry object** `PascalJavaBridge.JVM` (registered coclass, ProgID):
  - `New(className, args...)`, `Static(className)` (an object whose IDispatch exposes static
    methods and fields), `Cast(obj, className)`, `Start(classpath, options)`.
  - Example (VBScript): `Set jvm = CreateObject("PascalJavaBridge.JVM")` then
    `Set list = jvm.New("java.util.ArrayList")`, `list.add 42`, `jvm.Static("java.lang.Math").max(1, 2)`.
- Callbacks: `jvm.Implement("java.lang.Runnable", someIDispatch)` creates a Java Proxy whose
  calls go to the client's `IDispatch.Invoke` by method name. This reuses `JrCreateProxy` with a
  dispatcher that forwards to IDispatch.

## Part 2: early binding (generated)

A new generator option (e.g. `--com`, Maven `<com>true</com>`) that additionally writes:

- for each Java type `Foo`:
  - **dual interface** `IJFooDisp` (derived from `IDispatch`, `dual`, `oleautomation`),
    with the same parent chain as `IJFoo` (single inheritance fits);
  - **class object interface** `IJFooClass`: constructors (`New`, `New_1`, ...), static
    methods, static fields. COM creation takes no parameters, so constructors cannot be coclass
    constructors. The entry object hands these out (`jvm.JFoo` or `jvm.Class_("...")`);
  - Delphi classes `TJFooAuto` (`TAutoIntfObject` descendants) that delegate to `IJFoo` / `TJFoo`;
- a **type library**, either:
  - (a) generated `.ridl`/IDL text compiled with `midl` (Windows SDK) or Delphi's `GenTLB`,
    linked as a resource (`{$R *.tlb}`); or
  - (b) built at registration time by the server itself through `ICreateTypeLib2`, so no
    external tools are needed. More code, but self-contained;
- a Delphi project for the server (library or exe, see open decisions), with registration.

### Mapping rules

| Java | Automation type |
|---|---|
| `int` / `short` | `Integer` (`long` in IDL) / `SmallInt` |
| `long` | `Int64` (LONGLONG: VBA 64-bit and C# only, **not VBScript**) |
| `float` / `double` | `Single` / `Double` |
| `boolean` | `WordBool` (VARIANT_BOOL) |
| `byte` | `SmallInt` (COM `Byte` is unsigned) |
| `char` | `SmallInt` (or a 1-char `WideString`) |
| `String` | `WideString` (BSTR) |
| arrays | `SAFEARRAY` in `OleVariant` |
| wrapped type `Foo` | `IJFooDisp` |
| other objects | `IDispatch` (a `TJavaDispatch`) |

### Other rules

- **Overloads**: COM has none. Early binding uses unique names (`append`, `append_1`, ...).
  The existing naming code (`Scope`, `allocate`) already guarantees uniqueness case-insensitively,
  which type libraries also require; it needs a mode where overloads never share a name.
  Late binding resolves overloads at run time.
- **Reserved names**: avoid IDispatch/IUnknown members (`QueryInterface`, `AddRef`, `Release`,
  `GetTypeInfoCount`, `GetTypeInfo`, `GetIDsOfNames`, `Invoke`) and VBA keywords, through the
  same claim mechanism.
- **Exceptions**: `safecall` methods. Java exceptions become `EOleException` / `IErrorInfo`
  with source = Java class name and description = message, so VBA shows them as run-time errors.
- **GUIDs**: name-based like today, with new seeds: `pascal-java-bridge-com-libid:<unit>`,
  `...-com-iid:<class>`, `...-com-class-iid:<class>`, `...-com-clsid:<class>`. They must stay
  stable across regenerations.
- **Lifetime**: COM reference counting maps directly onto the existing global-ref wrappers.
- **Threads**: apartment threading model. JNI auto-attach (daemon) handles any COM thread.

## Open decisions (for the user)

1. **In-process DLL vs out-of-process EXE server.**
   - In-proc: fast (~100 ns per call + COM overhead). It loads the JVM into the host process
     (e.g. Excel): only one JVM per process, the JVM's bitness must match the host's (64-bit
     Office needs a 64-bit JDK), and a JVM crash kills the host.
   - Out-of-proc: isolates the JVM. Calls are marshalled across processes (tens of µs each).
2. **Which clients matter most.** VBA/VBScript/PowerShell mainly need Part 1. C#/C++/VB6
   gain most from Part 2.

Recommendation: Step 0, then Part 1 (`TJavaDispatch` + `PascalJavaBridge.JVM`), then Part 2.

## Windows-specific reminders

- The Delphi debugger stops on first-chance exceptions that the JVM raises on purpose: on
  Windows the JVM uses SEH (access violations for safepoints and null checks) instead of
  SIGSEGV. Add them to the debugger's ignored exceptions, or run without the debugger.
  (Lazarus/FpDebug on Linux: see the README section "Debugging in Lazarus".)
- `jvm.dll` must be found from `JAVA_HOME\bin\server`. Don't copy it elsewhere.
- Registration: `regsvr32` for a DLL (needs an elevated prompt for HKLM, or register per user
  under HKCU), `/regserver` for an EXE.
