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
- `handler/`: `pascaljavabridge.internal.PascalInvocationHandler` (Proxy-based callbacks; natives
  `invoke0`/`release0` are registered from Pascal; Cleaner releases the Pascal object).
- `generator/`: `pascaljavabridge.BindingGenerator`, a single file (~1,400 lines). It is both the
  CLI (`main`) and the API (`Options`, `generate`) the Maven plugin uses. The jar bundles the
  runtime files as resources (`pascaljavabridge/runtime/`).
- `maven-plugin/`: `GenerateMojo` (`pascal-java-bridge:generate`, phase `process-classes`).
- `tests/`: demo Java classes (`demo.*`: `Torture` covers name collisions, `CallbackHost`
  covers callbacks) and `src/test/pascal/TestBindings.pas`.

## Generated code model (keep these invariants)

- For each Java type: interface `IJFoo` (instance members, parent = nearest wrapped superclass /
  first wrapped super-interface, root `IJavaObject`); record `TJFoo` (`New`, statics, `Cast`,
  `IsInstance`, `Implement`); class `TJFooImpl` with **one method resolution clause per name**
  (`function IJFoo.bar = J_7;`), mapping to overloaded `J_n` methods. FPC can't have one clause per overload.
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
- Delphi has never actually been compiled. Keep code Delphi-compatible anyway: no FPC-only
  syntax, no macros.
- Callbacks support Java interfaces only (Proxy).

## Planned work

- **COM / Automation for Delphi** (late binding via a generic `TJavaDispatch`, early binding via
  generated dual interfaces and a type library): see [docs/com-automation.md](docs/com-automation.md).
  It is a proposal, not implemented, and it starts with getting Delphi to compile the project at
  all (step 0). The in-proc vs out-of-proc decision is still open.
- Lazarus/FpDebug stops on the JVM's intentional `SIGSEGV`: README "Debugging in Lazarus".

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
