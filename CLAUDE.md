# CLAUDE.md

Calls Java from Free Pascal and Delphi in-process through JNI. A generator turns Java classes into
reference-counted Object Pascal interface wrappers. README.md is the user documentation; this
file covers what you need to know to work on the code.

## Build and test

```bash
FPC=~/Software/fpcupdeluxe/fpc/bin/x86_64-linux/fpc.sh ./build.sh          # mvn verify + Pascal tests
FPC=~/Software/fpcupdeluxe/fpc/bin/x86_64-linux/fpc.sh ./build.sh clean    # mvn clean verify
mvn -B verify                                                              # Java modules only (no FPC)
```

- `build.sh` puts extra arguments *before* `verify`, so `./build.sh clean` means `mvn clean verify`.
- The FPC here is 3.2.2 from fpcupdeluxe, not on the PATH. JDK 25 (sdkman); the generator targets
  Java 17 (`maven.compiler.release`).
- Pascal tests run only when `-Dfpc.executable` is set (profile `pascal-tests` in `tests/pom.xml`).
  They run `TestBindings` twice, against the single-unit `JDemo` and the per-package `JDemo`
  (`-dUNIT_PER_PACKAGE`), with `--checkjni`. Every test must pass in both layouts; the output
  ends with `ALL TESTS PASSED`.
- Windows machine: Delphi 11 (`dcc64`/`dcc32` on the PATH), JDK 25 in `C:\Software`, no FPC.
  `mvn -B verify -Ddcc.executable=dcc64` (profile `delphi-tests`) does the same with Delphi,
  output in `tests/target/delphi/{single,per-package}`; it also runs `TestCom` (single layout) and `TestComEarly` (both).
  Both profiles can run in one build. `-Dcom.scripts` (profile `com-script-tests`) also runs
  `tests/src/test/script/RunComScripts.ps1`: registers the COM server DLL for the current user,
  runs the .vbs/.js/.ps1 tests, always unregisters. Never leave it registered. Delphi source files
  without a BOM are read as ANSI: use `#$xxxx` for non-ASCII characters in string literals.
- Quick generator iteration: `mvn -q -B install -pl generator -Dmaven.install.skip=true`, then
  `java -jar generator/target/pascal-java-bridge-generator-0.1.0-SNAPSHOT.jar --unit X --out <dir> --with-runtime ...`
  and compile with `fpc.sh -vwn -Sew -FU<dir> -Fu<dir>`. Keep scratch output out of the repo.
- Don't run `mvn install` into `~/.m2` unless asked.

## Layout

- `runtime/JavaBridge.pas`: the runtime unit. Plain Pascal for FPC and Delphi (`{$MODE DELPHI}`,
  `{$IFDEF FPC}`/`MSWINDOWS`). Exported names use the prefixes `Jr*`, `TJava*`, `IJava*`,
  `EJava*`, `Java*`, `jk*`. Don't add exports outside these prefixes: the generator reserves them.
- `runtime/JavaBridgeHandler.inc`: **generated** by the `handler` module (`HandlerIncludeWriter`)
  from the compiled `PascalInvocationHandler` bytecode. It is committed and only rewritten when
  its content changes. If it shows up as modified without handler changes, Eclipse (ECJ) probably
  compiled `handler/target/classes`; `mvn clean` restores it.
- `runtime/JavaBridgeCom.pas` (Delphi/Windows only, used by `--com` output, not by the plain
  wrappers): late-bound `IDispatch` over Java objects (`TJavaDispatch`), the entry object
  `JavaComJVM` and `Implement` callbacks (by name; typed ones through `JavaComImplementTyped`,
  with the same owner-thread rule and deferred release). `runtime/JavaBridgeDynamic.inc` is generated the same way from
  `pascaljavabridge.dynamic.DynamicInvoker` (writer args: `<classes> <inc> <pkg-dir> DYNAMIC <src>`),
  defined through `JrDefineClass`. Its `{$IF DYNAMIC_CLASS_COUNT <> 3}` guard must follow the
  number of (nested) classes. Both are in `RUNTIME_FILES`, so `--with-runtime` copies them.
- `handler/`: `pascaljavabridge.internal.PascalInvocationHandler` (Proxy-based callbacks; natives
  `invoke0`/`release0` are registered from Pascal; Cleaner releases the Pascal object), and
  `pascaljavabridge.dynamic.DynamicInvoker` (member lookup by name, run-time overload choice,
  value conversion for COM). It uses `MethodHandles.publicLookup()` with the accessible
  reference class (so public methods of non-public classes work) and `asFixedArity()` (it packs
  varargs itself).
- `runtime/JavaBridgeAuto.pas` (Delphi only): `TJavaTypeLibBuilder` (type library from a
  description, through `ICreateTypeLib2`: in memory or as .tlb), `TJavaAutoObject` (base of the
  generated automation classes: `IDispatch` via `DispInvoke` on the vtable half of the dual
  interface, `SafeCallException` -> `IErrorInfo`), array/char helpers, and the COM server helpers
  (`JavaComClassObject`, `JavaComRegisterServer`). ICreateTypeLib2 gotchas: `SetTypeFlags(FDUAL)`
  only after `AddImplType`; `SetFuncAndParamNames` wants a name for the retval too; never pass an
  interface variable as both `Self` and `out` argument (Delphi clears the `out` first).
- `generator/`: `pascaljavabridge.BindingGenerator` (~1,500 lines). It is both the CLI (`main`)
  and the API (`Options`, `generate`) the Maven plugin uses. The jar bundles the runtime files as
  resources (`pascaljavabridge/runtime/`). `ComGenerator` (same package) writes the `--com`
  output from BindingGenerator's model (after `assignNames`): its own `Scope` (outer = the global
  one), a COM `Table` per interface chain (unique names, `claimProperty` also claims
  `Get_`/`Set_`, DISPIDs), `C_n` implementing methods mapped by resolution clauses. The Delphi
  interface order must equal the `AddFunc` order (vtable). With `--unit-per-package` it is still
  one COM unit and one type library; its `uses` adds every package unit (names are global).
  Callback types also get `IJFooCallbackDisp` (only the abstract methods, parent `IDispatch`) and
  `ComDispatch_Foo`; `Implement` uses them when the object supports the interface. The COM unit
  has its own class slots (`G<unit>ComClasses`, for `Object[]` results): don't call
  `g.argToJava` for object arrays, it would allocate slots in the Pascal unit's model.
  A type library keeps one spelling per name (case-insensitive, first one wins).
- `comserver/PascalJavaBridgeCom.dpr`: Delphi in-process COM server (hand-written class factory
  and `DllRegisterServer`/`DllInstall`, no TComObject/type library). CLSID is name-based
  (`pascal-java-bridge-com-clsid:PascalJavaBridge.JVM`); keep it stable. PowerShell sees no
  properties without type info, so every entry member also works as a method call.
- `maven-plugin/`: `GenerateMojo` (`pascal-java-bridge:generate`, phase `process-classes`).
- `tests/`: demo Java classes (`demo.*`: `Torture` covers name collisions, `CallbackHost`
  covers callbacks) and `src/test/pascal/TestBindings.pas`; `TestCom.pas` (Delphi) tests
  JavaBridgeCom through `OleVariant` late binding, without COM registration; `TestComEarly.pas`
  tests the generated `JDemoCom` in both layouts (both `JDemo`s are generated with `<com>true</com>`;
  the per-package server is compiled only, since it has the same CLSID as the one the scripts register).
  `src/test/script/TestComEarly.ps1` converts the registered .tlb with .NET's `TypeLibConverter`
  (no tlbimp needed) and compiles a C# early-bound client with `Add-Type`.

## Generated code model (keep these invariants)

- For each Java type: interface `IJFoo` (instance members, parent = nearest wrapped superclass /
  first wrapped super-interface, root `IJavaObject`); record `TJFoo` (`New`, statics, `Cast`,
  `IsInstance`, `Implement`); class `TJFooImpl` with **one method resolution clause per name**
  (`function IJFoo.bar = J_7;`), mapping to overloaded `J_n` methods. FPC can't have one clause per overload.
  Delphi binds only one overload per clause, so for overloaded names the clause is `{$IFDEF FPC}` and
  Delphi gets `reintroduce; overload;` forwarders with the interface name (`delphiForwarders`).
  `IMPL_MEMBERS` (`JavaGlobalRef`, `CreateFrom*`, called by bodies) are therefore never overloaded.
- **No naming collisions, ever.** Pascal is case-insensitive. All identifiers go through `Scope.claim`
  (global) or `allocate` (per member table); keywords are escaped with `&`, and `RESERVED` holds runtime
  and System names. Use `_n` suffixes, `p`/`p_` parameter prefixes chosen per table, `_uXXXX`
  for non-ASCII, and qualified type names when simple names clash. Any new generated identifier must be
  claimed the same way. `demo.Torture` exists to break this; extend it when adding naming logic.
- GUIDs are name-based (`pascal-java-bridge:` / `pascal-java-bridge-callback:` + class name) so
  output is deterministic. Output files are written only when changed (`writeIfChanged`).
- Bodies are generated **before** the `var GClasses/GMethods/GFields` block is printed because
  they can allocate class slots. Use `cSlot/mSlot/fSlot`; they are global in single-unit mode
  and per unit in per-package mode.
- Unit-per-package mode: all `IJ*` interfaces in `<unit>`; records and impl classes in
  `<unit>_<package>` (impl classes in the interface section, because subclasses in other units
  inherit them). Packages whose impl-parent relations form a cycle (Tarjan SCC) share one unit.
  Cross-unit references from bodies go through `implRef()` so the implementation `uses` is right.
- Single-unit output must stay byte-identical unless a change is intended. Diff the generated
  `tests/target/generated-sources/pascal/JDemo.pas` before and after.

## Runtime gotchas learned the hard way

- Constructors: `GetMethodID`, not `GetStaticMethodID` (`isStatic=False` for CTOR).
- Threads auto-attach as **daemon** threads; `JavaStopVM` hangs if a non-daemon thread stays
  attached. Hidden temporaries released after `JavaDetachThread` re-attach the thread, so avoid
  them in shutdown paths and tests.
- FPU exceptions are masked per thread (the JVM needs it). FPC on Unix needs `cthreads` first in
  the program's `uses`.
- The JVM uses SIGSEGV internally; signal handlers installed after `JavaStartVM` need `libjsig`.

## Known issues / limits

- FPC 3.2.2 crashes with an internal error (`EListError: List index exceeds bounds (-1)`) on huge
  single units (e.g. `java.**`, 430k lines). This is a compiler bug; `--unit-per-package` avoids it.
- Delphi 11 (dcc64/dcc32) compiles both layouts and passes the tests.
  Delphi differences found so far: no `PtrUInt` (use `NativeUInt`), directive
  order `overload; static;` (not `static; overload;`), string literals max 255 elements (`pasStr`
  splits them), `'lit' + AnsiChar` is a UnicodeString. No FPC-only syntax, no macros.
  FPC on Windows has not been tested.
- Callbacks support Java interfaces only (Proxy).

## Maven / Eclipse

- m2e can't resolve a Maven plugin built in the same workspace, so the plugin execution in
  `tests/pom.xml` lives in profile `generate-pascal` (active when `!m2e.version`), and the
  handler's exec execution has `<?m2e ignore?>`. Check Eclipse compatibility with
  `mvn -B verify -Dm2e.version=2.6.0`.
- Plugin executions need an explicit `<phase>`, or `mvn clean` tries to resolve the unbuilt plugin.
- FPC does not create `-FU` directories; point them at a directory that already exists.
- XML comments in POMs must not contain `--`.

## Repository conventions

- GitHub: `maartenkroon/pascal-java-bridge`, MIT license. Commit as `maartenkroon`
  `<10675549+maartenkroon@users.noreply.github.com>` (already the local git config).
- Commit or push only when asked. The user pushes with their own token.
- `.gitignore` uses `/build/` (root only). A plain `build/` would ignore the source package
  `handler/src/main/java/pascaljavabridge/build/`.
- Update README.md (parameter tables, limitations, test counts) along with any user-visible change.
