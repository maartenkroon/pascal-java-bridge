# Design note: COM / Automation for Delphi

Status: written on 2026-11-27 so the work can continue on a Windows machine. Step 0 (Delphi
compiles and passes the tests) is done. Part 1 is done, including the in-process COM server
(decision 1: DLL). Part 2 is done (both layouts, 64-bit and 32-bit, tested up to VBA). Part 3
is a proposal: configuration, COM-style collections, more type mappings, an optional
out-of-process server.

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
(not installed then; FPC 3.2.4 x86_64-win64 passes both layouts since).

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

Not tested at first (see Part 2 for the VBA test added later): VBA in Office
and a 32-bit build (both done later, see Part 2). VBA uses the same IDispatch calls as VBScript.

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
- Tests: `TestComEarly.pas` (65, in process). With `-Dcom.scripts`, the registered server is
  tested from VBScript (10) and from PowerShell and C# (29): the C# client is compiled against an
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

All wrapped interfaces (2026-11-27): an Auto class also lists the dual interfaces of the wrapped
Java interfaces its class implements, unless its chain or its parent Auto class already has them.
Delphi's `QueryInterface` only finds listed interfaces, so their ancestors are listed too. A member
already implemented in the class hierarchy reuses that method. The others call the Java object
through a Pascal wrapper of that interface (`TJList.Cast(FJava)`, cached on first use with
`JavaComCacheIntf`), because the Pascal impl classes only implement their own chain. Each extra
dual interface maps its `GetTypeInfo` / `GetIDsOfNames` / `Invoke` to generated methods that use
its own type info (`GetTypeInfoFor` etc. in `TJavaAutoObject`). A name it doesn't know is looked
up in the object's own interface and returned as that DISPID + `$01000000`, which `Invoke` routes
back. So DISPIDs stay correct per interface, and VBScript still sees the run-time class.
`ComWrap_Foo` now considers every type whose Auto class implements `IJFooDisp`, ordered by the
number of wrapped supertypes (a subtype has more). Costs: each class implementing a wrapped
interface gets methods for that interface's members, and `ComWrap_Foo` makes one `IsInstance` call
per candidate, which can add up for widely implemented interfaces in large bindings.

Found on the way: a VBScript or JScript run-time error stops the script but leaves `cscript`'s
exit code at 0. `RunComScripts.ps1` now also requires "ALL TESTS PASSED" in each script's output.

VBA (2026-11-27): `tests/src/test/script/TestVba.ps1` (`-Dcom.vba`) starts Access hidden through
automation, creates a temporary database, adds a reference to the registered `.tlb`, adds
`tests/src/test/vba/PjbTests.bas` and the class modules `PjbRunner` / `PjbListener` through
`Application.VBE` (Access has no "Trust access to the VBA project object model" gate, unlike
Excel and Word), and calls `PjbRunTests` with `Application.Run` (by-reference arguments:
`[ref]` from PowerShell). `AutomationSecurity = low` applies to that session only. A 300 s limit
and a cleanup of the Access process it started keep a VBA dialog from hanging the build. The 18
checks cover `New JDemo.JDemo`, typed members, `LongLong`, arrays, `TypeOf ... Is`, For Each,
the default member, late binding, VBA errors, and `Implements` of the callback interfaces.

Found on the way: the Claude desktop app is an MSIX package, and every process started from it
(the shell, `regsvr32`, `cscript`) writes `HKCU` into the package's private copy. The script
tests passed because they ran inside that package too. Access is started by COM outside it, so
it doesn't see the registration ("Class not registered"). Inside the session, the VBA test got
as far as compiling the project with the reference and then failed at `New JDemo.JDemo`. Run
from an ordinary PowerShell window (`mvn -B verify "-Ddcc.executable=dcc64" "-Dcom.scripts"
"-Dcom.vba"`, quoted: PowerShell splits an unquoted `-Da.b=c` at the dot), all tests pass, VBA
included (Microsoft 365 Access, 64-bit).

32-bit (2026-11-27): Delphi 11 dcc32 with a 32-bit Temurin 17.0.16 JRE (JDK 24 and later have no
32-bit Windows build; the bytecode targets Java 17). Maven profile `delphi32-tests`
(`-Djvm32.home=...`) runs `tests/src/test/script/RunDelphi32.ps1`: all test programs in both
layouts, both COM servers, and with `-Dcom.scripts` the script tests through the 32-bit hosts. All
pass. Two bugs that 64-bit hid:

- The JVM crashed at start-up in `jimage.dll` (a call through nil). `jimage.dll` loads `zip.dll`
  by name, and `zip.dll` imports `java.dll` by name. `java.exe` finds them in its own directory,
  but a host program finds whatever comes first on the PATH, here JDK 25's 64-bit DLLs. The
  runtime now loads the JDK's own `java.dll` and `zip.dll` by full path after `jvm.dll`, so the
  by-name loads return those. This also matters on 64-bit when another JDK is earlier on the
  PATH than the one being used.
- The generated interfaces declared `[in] VARIANT` parameters as `const OleVariant`, which Delphi
  passes by reference. COM passes them by value, which is 16 bytes on the Win32 stack (on Win64 a
  pointer, so it matched there). `IDispatch` calls through `DispInvoke` failed with
  `DISP_E_BADCALLEE`. They are now plain `OleVariant` value parameters, as in Delphi's own type
  library imports.

Nothing is left open for Part 2.

## Part 3: from working to usable (proposal)

Parts 1 and 2 make Java callable from every COM client and test it from Delphi, VBScript,
JScript, PowerShell, C# and VBA, in 64-bit and 32-bit. Part 3 covers what a real user of the
servers runs into next: getting the JVM configured without code, Java collections that behave
like COM collections, the COM types that have no mapping yet, and the limits of the in-process
model. Each item stands on its own; the suggested order is at the end, and the decisions it needs
are listed under Open decisions.

### 3a. Configuration and automatic start

Today a client must set `JvmPath` and call `Start(classPath, options)` before anything else. A
class property used first (`jdemo.Torture`) starts the JVM through `JrComEnsureVM` with no class
path and no options, so the generated classes then fail with "Java class not found". For VBA
users, who just want `CreateObject("PascalJavaBridge.JDemo").Torture.New()` to work, this is the
most likely first failure.

- A configuration file next to the server DLL, `<server>.ini` (or `.json`), read on first use:
  `JavaHome` / `JvmPath`, `ClassPath` (relative entries resolved against the DLL's directory),
  `Options` (one per line, e.g. `-Xmx512m`), and optionally `Required` (fail clearly instead of
  starting without it). `Start` keeps working and overrides the file.
- Lookup order for the JVM: `JvmPath` set by the client, the file, `JAVA_HOME`, then the
  registry (`HKLM\SOFTWARE\JavaSoft\JDK\<CurrentVersion>\JavaHome`).
- A clear error when the JVM's bitness doesn't match the host (load `jvm.dll`, check the PE
  machine type first): "32-bit Office needs a 32-bit JVM (JDK 17 to 23)" instead of "Cannot load".
- Both servers: the late-bound `PascalJavaBridgeCom.dll` and every generated `<unit>ComServer`.
- Tests: a server copy with an `.ini` in a temporary directory; VBScript calls `jdemo.Greeter`
  without `Start`.

### 3b. Java collections as COM collections

VBA and VB6 code expects `list(0)`, `list.Count` and `map("key")`. Now a `List` result has `size`,
`get(int)` and For Each, and its default member (DISPID 0) is `toString`.

- For wrapped types assignable to `java.util.List`, `Map`, `Collection` and arrays seen as
  variants: add `Count` (property, from `size()`) and `Item(index)` / `Item(key)` (property get
  and put, from `get`/`set`/`put`) to the dual interface, with names claimed through the normal
  `Table` so they never clash with Java members.
- The default member becomes `Item` for these types, so `list(0)` and `map("k")` work, and `CStr`
  of a collection no longer gives `toString` (decision 3).
- Late binding (`TJavaDispatch`) gets the same members, so both servers behave alike.
- Tests in VBScript, VBA (`For i = 0 To list.Count - 1`) and C# (`list[0]` through the interop
  assembly's indexer).

### 3c. Missing type mappings

| COM | Java | Now | Proposal |
|---|---|---|---|
| `Date` (VT_DATE) | `java.time.LocalDateTime` / `java.util.Date` | in: a `Double` (the OLE date number); out: no mapping | `LocalDateTime` both ways for `Object` parameters and results; declared `Date` / `LocalDateTime` / `LocalDate` parameters typed as `Date` in the type library |
| `Currency`, `Decimal` | `java.math.BigDecimal` | in: a `Double` (precision lost) | `Decimal` (VT_DECIMAL) ↔ `BigDecimal` both ways |
| `Byte()` (VT_UI1 array) | `byte[]` | in: any numeric array; out: a variant array of numbers | out as a real `Byte()` array: binary data for VBA (files, images) |
| `long` in VBScript | `long` | late binding: I4 when it fits; early binding: always VT_I8, which VBScript can't use | decide whether early-bound `long` results also go out as I4/R8 `VARIANT`s (decision 4) |
| 2-D `SAFEARRAY` | `Object[][]` | late binding: in as `Object[][]` (an Excel range); out: nested 1-D arrays; early binding: an error (`JrVarToObjectArray` takes 1-D only) | 2-D both ways in both bindings, so `Range.Value = javaResult` works: the most common VBA data shape |

Each mapping is a change in `JavaToVariant` / `JavaFromVariant` (late binding) and in
`ctype` / `argIn` / `assignOut` (early binding), tested in Delphi and from VBA.

### 3d. Out-of-process server (decision 1, revisited)

The in-process DLL was decision 1, and it stays the default. It has three hard limits that only an
out-of-process server removes:

- **Bitness**: 32-bit Office (still common in companies) needs a 32-bit JVM, and JDK 24 removed
  the 32-bit Windows port. The newest 32-bit JDKs are 17 to 23. A 64-bit EXE server lets 32-bit
  clients use a current 64-bit JDK.
- **One JVM per process, forever**: an Excel session can't switch class paths or restart the JVM.
- **Isolation**: a JVM crash (or `System.exit`) takes the host down.

Plan: `<unit>ComServerExe.dpr` (generated) and `PascalJavaBridgeComExe.dpr`.
- `CoRegisterClassObject` with `REGCLS_MULTIPLEUSE`, a message loop on an STA thread, exit when
  the last object is released, and `/regserver` / `/unregserver` / `/regserver /user`.
- Marshalling of the dual interfaces through the type library marshaler: interfaces registered
  with `ProxyStubClsid32 = {00020424-0000-0000-C000-000000000046}` and the `oleautomation` flag.
  All our types are automation types, so no `midl` proxy DLL is needed.
- Callbacks: a COM object passed to `Implement` arrives as a proxy, so Java threads can call it
  through COM (the owner-thread rule then only applies to in-process clients).
- Cost: tens of µs per call instead of about 0.1 µs. A note in the README on batching (pass
  arrays, not single values, in loops).
- Tests: the same VBScript/PowerShell/C# scripts against the EXE (`LocalServer32`), plus a 32-bit
  client (32-bit `cscript`) using the 64-bit server with JDK 25.

### 3e. Events (optional)

VBA's `WithEvents` needs connection points: a source interface in the type library and
`IConnectionPointContainer` on the object. Java has no event model, but its listener pattern
(`addFooListener(FooListener)`) does. A generator option could turn `addXListener` /
`removeXListener` pairs into a source interface per listener type, with the class implementing
`IConnectionPointContainer`. Typed callbacks (Part 2) already cover the same need with
`Implements`, so this only pays off if users ask for `WithEvents`.

### 3f. Smaller items

- `ComWrap_Foo` makes one `IsInstance` call per candidate. For a widely implemented interface in
  a large binding (`java.util.List` in `java.**`), cache per class: look up the run-time class
  once (`GetObjectClass`, then compare global refs), and map it to the wrapper in a small hash
  table.
- Versioned ProgIDs (`PascalJavaBridge.JDemo.1`, plus `VersionIndependentProgID`) and a type
  library version taken from the Maven project version, so a new build can be installed side by
  side.
- HKLM registration from an installer, documented: `regsvr32` elevated, or `DllRegisterServer`
  from a setup tool. Tests keep using HKCU.
- FPC: the COM units are Delphi only (`System.Win.ComObj`, `DispInvoke`). An FPC port of
  `JavaBridgeCom` is possible (FPC has `ComObj` and variants) but not needed for any client.
- FPC i386-win32 has not been tested (only the x86_64 FPC is installed here).

### Suggested order

3a first: it is small and removes the most likely first failure for Office users. Then 3b and
the Date/Decimal/byte/2-D array mappings of 3c, which are what VBA code needs most. Then 3d if
32-bit Office with a current JDK, or isolation, is a requirement. 3e only on demand. 3f items
whenever the files are touched anyway.

## Open decisions (for the user)

1. **In-process DLL vs out-of-process EXE server.** Decided: in-process DLL.
   - In-proc: fast (~100 ns per call + COM overhead). It loads the JVM into the host process
     (e.g. Excel): only one JVM per process, the JVM's bitness must match the host's (64-bit
     Office needs a 64-bit JDK), and a JVM crash kills the host.
   - Out-of-proc: isolates the JVM. Calls are marshalled across processes (tens of µs each).
   For Part 3: keep the DLL as the default, and decide whether an EXE server (3d) is needed too:
   yes if 32-bit Office must use a current (64-bit) JDK, or the JVM must not run inside Office.
2. **Which clients matter most.** VBA/VBScript/PowerShell mainly need Part 1. C#/C++/VB6
   gain most from Part 2.
3. **Default member of collections (3b).** `Item` (VBA-style `list(0)`, `map("k")`) or keep
   `toString` (`MsgBox list`, `CStr(list)`). Recommendation: `Item` for `List`, `Map`,
   `Collection`; `toString` stays the default for everything else.
4. **`long` for VBScript (3c).** Keep `Int64` (exact; VBA 64-bit, C#, Delphi), or send `long`
   results as `VARIANT` (I4 when it fits, else R8 or Decimal), which VBScript can use but which
   loses the type for early-bound clients. Recommendation: keep `Int64` in early binding (VBScript
   uses late binding, where `long` already becomes I4 when it fits).
5. **Configuration file format (3a).** `.ini` (no parser needed, VBA users know it) or `.json`.
   Recommendation: `.ini`.

Recommendation: Step 0, then Part 1 (`TJavaDispatch` + `PascalJavaBridge.JVM`), then Part 2.
For Part 3: 3a, then 3b and 3c, then 3d if decision 1 says so.

## Windows-specific reminders

- The Delphi debugger stops on first-chance exceptions that the JVM raises on purpose: on
  Windows the JVM uses SEH (access violations for safepoints and null checks) instead of
  SIGSEGV. Add them to the debugger's ignored exceptions, or run without the debugger.
  (Lazarus/FpDebug on Linux: see the README section "Debugging in Lazarus".)
- `jvm.dll` must be found from `JAVA_HOME\bin\server`. Don't copy it elsewhere.
- Registration: `regsvr32` for a DLL (needs an elevated prompt for HKLM, or register per user
  under HKCU), `/regserver` for an EXE.
