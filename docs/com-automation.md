# Design note: COM / Automation for Delphi

Status: written on 2026-11-27 so the work can continue on a Windows machine. Step 0 (Delphi
compiles and passes the tests) is done. Part 1 is done, including the in-process COM server
(decision 1: DLL). Part 2 is working in both layouts (see its progress section).

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

**Result (2026-11-27, Delphi 11 / dcc64, JDK 25, Windows 11 x64):** done, except FPC on Windows
(not installed).

1. Both layouts compile with dcc64; dcc32 compiles too (not run: no 32-bit JVM). Fixes: `PtrUInt`
   → `NativeUInt`, `overload; static;` directive order, string literals split at 250 elements,
   explicit `AnsiString` in `'lit' + AnsiChar`, Delphi stand-ins for FPC RTL names in the test.
2. Delphi does **not** accept it: a clause binds only one overload, and a second clause for the
   same name is "identifier redeclared". Overloaded names now get an FPC-only clause, and under
   Delphi `reintroduce; overload;` forwarders named after the interface method, calling `J_n`.
   This works even for names like `Free`, `Destroy`, `ToString`. `JavaGlobalRef`,
   `CreateFromLocal` and `CreateFromGlobal` (called by generated bodies) are never overloaded;
   `demo.Torture` covers both cases.
3. All 75 tests pass with `-Xcheck:jni` in both layouts (stdcall and `jvm.dll` from
   `JAVA_HOME\bin\server` work).
4. `mvn verify -Ddcc.executable=dcc64` (profile `delphi-tests` in `tests/pom.xml`); README updated.

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

**Progress (2026-11-27):** everything above except the registration, in
`runtime/JavaBridgeCom.pas`. `tests/src/test/pascal/TestCom.pas` has 65 tests that drive it
through Delphi `OleVariant` late binding and pass under `-Xcheck:jni` (profile `delphi-tests`).
How it works, and how it differs from the plan:

- The reflection and overload choice run **in Java**, in `pascaljavabridge.dynamic.DynamicInvoker`
  (`handler` module, embedded as `runtime/JavaBridgeDynamic.inc` like the callback handler, and
  defined through the new `JrDefineClass`). That is far less code than JNI reflection from Pascal.
  Pascal only converts VARIANTs to boxed Java values and back.
- DISPIDs are global per (case-sensitive) name, and `memberId` checks that the class has the
  member. Calls go through `MethodHandles.publicLookup()` with the most specific accessible type as
  the reference class, so `list.iterator().next()` works although the iterator class is private.
- Overload cost: exact < widening < narrowing that fits < whole `Double` to an integer type;
  `Object` parameters cost more than specific ones; varargs last.
- Additions: `Running`, `JvmPath`, `DISPID_VALUE` (`get`/`set`/`toString`), `_NewEnum` (For Each),
  `Implement` falls back to the COM object's default member (JScript functions, `GetRef`), and
  `TJavaDispatch` implements `IJavaHandle`, so it passes straight back to Java.
- COM threading, decided: an `Implement`ed COM object is only called on the thread that passed it
  (another Java thread gets a `RuntimeException`). Its release after Java GC (on the Cleaner
  thread) is queued for that thread and done on its next call into the unit, so no COM pointer
  crosses threads. Marshalling through the GIT would allow other threads but deadlocks when the
  STA thread is waiting in Java.

**COM server (2026-11-27, decision 1: in-process DLL):** `comserver/PascalJavaBridgeCom.dpr`.
It has a hand-written class factory that returns `JavaComJVM`, and `DllRegisterServer` (HKLM)
plus `DllInstall` (`regsvr32 /n /i:user`, HKCU). There is no TComObject and no type library.
The CLSID `{2867DDA4-DC6B-321C-8D65-4514D273A5E5}` is name-based. The threading model is `Both`,
because the objects attach any thread to the JVM. `DllCanUnloadNow` always says no, because a
loaded JVM can't be unloaded. Tested from `cscript` (VBScript: 20 tests, JScript: 7) and Windows
PowerShell (8) through `tests/src/test/script/RunComScripts.ps1`, which registers for the
current user, runs them, and unregisters (`-Dcom.scripts`). Found on the way:

- A JScript function has its own `apply` and `call` members, so `Implement` treats an object with
  both as a function and always calls its default member.
- PowerShell reads and writes COM properties only through type info (they come back `$null`).
  Reading members as methods works, so `JvmPath(path)` also sets the path. Part 2's type library
  would fix this.

Not tested: VBA in Office (running VBA from a test needs Office's macro trust settings changed)
and a 32-bit build (no 32-bit JDK here). VBA uses the same IDispatch calls as VBScript.

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
| `char` | a 1-char `WideString` (implemented; `SmallInt` was the alternative) |
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

**Progress (2026-11-27):** `--com` (Maven `<com>true</com>`) in single-unit mode, in
`generator/.../ComGenerator.java` and `runtime/JavaBridgeAuto.pas`. Decisions and differences
from the plan above:

- Type library: option **(b)**, built through `ICreateTypeLib2`. The generated unit holds a
  description (`B.AddInterface` / `B.AddFunc` calls) that is built in memory for `IDispatch`, and
  written and registered as `<server>.tlb` on registration. `TJavaAutoObject` (not
  `TAutoIntfObject`) implements `IDispatch` with `DispInvoke` on the vtable half of each dual
  interface, so names, properties and argument coercion come from the type library.
- `char` is a one-character `WideString` rather than `SmallInt`. `Object` and unwrapped types are
  `VARIANT`, converted like late binding (numbers and strings by value, objects as
  `TJavaDispatch`).
- Unique names: overloads are ordered by parameter count, then by usual types first, so the
  simplest overload keeps the plain name. Fields are properties (`Get_x`/`Set_x` in Delphi).
- Additions: `Object.toString` is DISPID 0 (default member); `_NewEnum` on `Iterable`/`Map`/
  `Iterator`/`Enumeration`; `IJFooClass.Implement(comObject)` for callbacks, typed as
  `IJFooDisp`; the entry has `Start`, `Running` and `JvmPath`.
- Generated server: `<unit>ComServer.dpr`, using the generic `JavaComClassObject` /
  `JavaComRegisterServer` from `JavaBridgeAuto`.
- Threading model `Both`, like the late-bound server.
- Tests: `TestComEarly.pas` (59, in process). With `-Dcom.scripts`, the registered server is
  tested from VBScript (9) and from PowerShell and C# (27): the C# client is compiled against an
  interop assembly that .NET's `TypeLibConverter` makes from the registered `.tlb`, and it calls
  through the vtables.

`--com` with `--unit-per-package` (2026-11-27): one `<unit>Com.pas` and one type library for all
types, whose `uses` lists the types unit and every package unit. Generated names are global in
that mode too, so the COM unit differs from the single-unit one only in its `uses` clause.
`TestComEarly` passes against both layouts; the per-package server is compiled but not
registered, because it has the same CLSID and ProgID as the single-unit one.

Typed callbacks (2026-11-27): every interface with abstract methods also gets
`IJFooCallbackDisp`, a dual interface (parent `IDispatch`) with just the abstract methods, like
the Pascal `IJFooCallback`. Not `IJFooDisp` itself, because a client would then have to implement
all of `Object`'s members too. `IJFooClass.Implement` still takes an `IDispatch`. If the object
supports `IJFooCallbackDisp` (a C# class implementing the interop interface, a Delphi class), the
proxy's calls go through a generated `ComDispatch_Foo`: Java arguments to COM types, a vtable call,
the result back to Java. Other objects (script objects) are still called by name. The runtime part
is `JavaComImplementTyped` / `JavaComTypedTarget` in `JavaBridgeCom`, with the same thread rule and
deferred release as late binding. `Object[]` results get their element class from the COM unit's
own class slots. Tested from Delphi (vtable only, with `IDispatch` failing; exceptions; release
after GC; `Object[]` results) and from C# (Calculator, Listener, an exception thrown in C#).

Found on the way: a type library keeps one spelling per name, case-insensitively, so the entry's
`List` property is `list` in `JDemo` (`Torture.list()` was added first). That matters only to
case-sensitive clients (C#, C++); see the README.

Most specific wrapper (2026-11-27): a type with wrapped subtypes in its dual-interface chain gets
`ComWrap_Foo`, which tests the subtypes deepest first (`TJSub.IsInstance`) and creates that
subtype's Auto class. The object implements `IJFooDisp` as well, so the declared return type stays
valid, while `QueryInterface` and `IDispatch` (type info of the subtype) see the run-time class.
Only subtypes whose chain contains the declared type qualify. A class's chain follows its
superclasses, so an `ArrayList` returned as `List` stays `IJListDisp` (`Cast` converts); making the
Auto classes implement every wrapped interface of their class would close that gap. Constructor
and `Implement` results skip the test. Tested from Delphi, C# (cast to `IJTortureDisp`) and
VBScript (Torture's members on a `Base` result).

Still open for Part 2: 32-bit; VBA in Office; and Auto classes that implement all wrapped
interfaces of their Java class (see above).

## Open decisions (for the user)

1. **In-process DLL vs out-of-process EXE server.** Decided: in-process DLL.
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
