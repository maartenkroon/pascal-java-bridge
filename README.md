# pascal-java-bridge

Call Java from Object Pascal (Free Pascal and Delphi) through generated, reference-counted
wrapper interfaces, and implement Java interfaces in Pascal (callbacks). The JVM runs
**inside** the Pascal process (JNI Invocation API). On a modern x86-64 machine a Pascal→Java
call costs about 75 ns and a Java→Pascal callback about 335 ns.

```pascal
JavaStartVM('', ['-Djava.class.path=myapp.jar']);   // libjvm from JAVA_HOME

L := TJArrayList.New;                 // constructor
L.add(TJStringBuilder.New('hello'));  // instance method
WriteLn(L.get(0).toString);           // returned objects are wrapped automatically
WriteLn(TJInteger.MAX_VALUE);         // static field
// no Free needed: wrappers are interfaces, the Java object is released with the last reference
```

## Layout

| Path | What |
|---|---|
| `runtime/JavaBridge.pas` | Runtime unit: JVM start/attach, JNI helpers, `TJavaObjectImpl`, exceptions, callbacks |
| `runtime/JavaBridgeHandler.inc` | Embedded bytecode of the callback proxy handler (generated) |
| `runtime/java/.../PascalInvocationHandler.java` | Source of that handler; `runtime/gen-handler.sh` regenerates the `.inc` |
| `generator/src/pascaljavabridge/BindingGenerator.java` | Generator (JDK 25, single file, no dependencies) |
| `test/TestBindings.pas` | Test program for the generated `JDemo` unit |
| `java/demo/*.java` | Test classes (`Torture.java`: naming collisions, `CallbackHost.java`: callbacks) |
| `fpc/RawJniDemo.pas` | The original hand-written JNI demo (raw JNI, no generator) |
| `build.sh` | Compiles the Java classes, generates `JDemo.pas` (using `'demo.*'`), compiles and links the test |

## Generating bindings

```bash
java generator/src/pascaljavabridge/BindingGenerator.java --unit MyJava --out src --cp myapp.jar \
     'com.example.**' --exclude 'com.example.internal.**' java.util.ArrayList 'java.util.Map$Entry'
```

Arguments are class names or wildcard patterns (quote them so the shell doesn't expand `*`):

| Pattern | Selects |
|---|---|
| `java.util.ArrayList` | one class; nested classes use the binary name: `java.util.Map$Entry` |
| `java.util.*` | all public classes and interfaces in package `java.util` (including public nested ones) |
| `java.util.**` | the same for `java.util` and all its subpackages |
| `java.util.*Map` | `*` matches within one name segment (no `.`) |
| `java.**.spi.*` | `**` matches across packages |

* Wildcards search the JDK's modules and every directory or jar on `--cp`. For JDK modules,
  only packages the module exports are included (no `sun.*` / `jdk.internal.*`
  implementation classes).
* A class that can't be loaded or inspected (e.g. a jar whose dependencies are missing) is
  skipped with a warning. For an explicitly named class, that's an error instead.
* `--exclude <pattern>` (repeatable, same syntax) removes classes from the selection,
  including from those added by `--depth`.
* `--depth n` also wraps the public types referenced by the selected classes, `n` levels deep.
* `--unit` sets the name of the Pascal unit (written to `<out>/<unit>.pas`); `--cp` is the
  classpath used to load the classes. JDK classes are always available.

`java.lang.Object` is always included. Types that are not wrapped show up as `IJavaObject`;
add them to the selection to get typed wrappers.

**Large selections**: generated code grows by roughly 200 lines per Java type.
`java.util.**` gives 386 types and 90k lines, and FPC compiles it in about 1 s. However,
**FPC 3.2.2 crashes with an internal error** ("Compilation raised exception internally",
`EListError`) on some very large units. It happened with `java.**` (2,110 types) and with
`java.lang.** java.io.** java.util.** java.time.** java.nio.**` (1,215 types), but not with
other selections of up to 1,184 types. It is a compiler bug, not invalid code. Select only
the packages you need or use `--exclude`. You can also generate several independent units:
each one is self-contained, and you pass objects between them as `IJavaObject` and use the
other unit's `Cast`.

## What gets generated

For each Java type `Foo`:

| Pascal | Contents |
|---|---|
| `IJFoo` (interface) | public instance methods, getters/setters for public instance fields |
| `TJFoo` (record) | `New(...)` constructors, static methods, static field getters/setters, `Cast`, `IsInstance` |
| `TJFooImpl` (implementation section) | hidden implementation class |

For each Java **interface** `Foo` with abstract methods, there are two more:

| Pascal | Contents |
|---|---|
| `IJFooCallback` (interface) | the abstract methods of `Foo`, to implement in a Pascal class |
| `TJFoo.Implement(cb)` | wraps a Pascal `IJFooCallback` in a Java object implementing `Foo` |

`IJFoo` inherits from the interface of the nearest wrapped Java superclass (for Java
interfaces: the first wrapped super-interface), ending in `IJObject` → `IJavaObject`. Other
interfaces that a Java class implements are reached with a checked cast:
`TJRunnable.Cast(Obj).run`.

### Type mapping

| Java | Pascal |
|---|---|
| `boolean byte char short int long float double` | `Boolean ShortInt WideChar SmallInt Integer Int64 Single Double` |
| `String` | `UnicodeString` (UTF-16 copy; Java `null` becomes `''`) |
| `Object` parameter | `IJavaObject` (accepts any wrapper) |
| `Object` result | `IJObject` |
| wrapped type `Foo` | `IJFoo` |
| other reference types | `IJavaObject` |
| `int[]`, … | `TJavaIntArray`, … (copied) |
| `String[]` | `TJavaStringArray` |
| other arrays | `TJavaObjectArray` (elements are `IJavaObject`) |
| `void` | procedure |

Generics are erased, as in the JVM: `List<String>.get` returns `IJObject`.

## Name collisions

The generator guarantees that the generated unit compiles and that no Java name can shadow
anything the generated code relies on:

* **Pascal keywords and directives** (`type`, `begin`, `end`, `read`, `index`, `string`, …) are
  escaped with `&`: `Obj.&type`.
* **Case-insensitivity**: all scopes compare names case-insensitively. When two Java names differ
  only in case (`getURL` / `getUrl`), the second one gets a suffix: `getUrl_1`.
* **Overloads** stay overloads. If two Java overloads map to the same Pascal parameter types
  (e.g. two unwrapped classes, both `IJavaObject`), the later one is renamed (`foo_1`).
* **Inherited members** keep the name they got in the ancestor; an overload added in a subclass
  joins the ancestor's name.
* **TObject / TInterfacedObject members** (`Destroy`, `Free`, `ClassName`, `ToString`, `RefCount`,
  …) are safe to use as Java method names. The implementation class only has mangled methods
  (`J_17`), which method-resolution clauses bind to the interface methods.
* **Reserved names** are renamed with a `_n` suffix:
  * `QueryInterface`, `_AddRef`, `_Release`, `Self`, `Result`
  * Pascal type names used in signatures (`Integer`, `UnicodeString`, …)
  * every identifier exported by `JavaBridge`
  * the generated type names
  * the local variable names used in generated bodies

  Example: Java `self()` becomes `self_1`.
* **Fields vs. methods**: a field getter never shares a name with a method. If a class has both a
  method `counter()` and a field `counter`, the method keeps the name and the getter becomes
  `counter_1`. Setters are `Set_<name>`.
* **Constructors** are `New`; a static Java method named `New` / `cast` / `isInstance` is renamed.
* **Type names**: the simple class name is used; when two wrapped classes share a simple name,
  both use the qualified name (`IJjava_util_List`, `IJjava_awt_List`). Every generated type
  name starts with `IJ` or `TJ`.
* **Parameters** are named `p0, p1, …`; if a member is called `p0`, parameters become `p_0, …`.
* **Non-ASCII identifiers** are mangled (`café` → `caf_u00E9`).

The interface declarations carry a comment with the original Java name and JNI signature
of each member, so renamed members are easy to find.

## Callbacks (Java → Pascal)

Implement the generated `...Callback` interface in an ordinary Pascal class and pass the
object to `Implement`. You get back a normal wrapper that you can hand to any Java API:

```pascal
type
  TByLength = class(TInterfacedObject, IJComparatorCallback)
    function compare(const p0, p1: IJObject): Integer;
  end;

function TByLength.compare(const p0, p1: IJObject): Integer;
begin
  Result := Length(p0.toString) - Length(p1.toString);
end;

List.sort(TJComparator.Implement(TByLength.Create));       // java.util.Comparator
Host.addListener(TJCallbackHost_Listener.Implement(MyListener));
TJCallbackHost.runInThread(TJRunnable.Implement(MyRunnable));
```

* **How it works**: `Implement` creates a `java.lang.reflect.Proxy`. Its handler class
  (`pascaljavabridge.internal.PascalInvocationHandler`) is embedded in `JavaBridge` as bytecode. It is
  defined in the system class loader on first use and calls two native methods implemented in
  Pascal (registered with `RegisterNatives`). You don't need a jar or a native library.
* **Types are mirrored**:
  * callback parameters use the *result* mapping (Java `Object` arrives as `IJObject`)
  * callback results use the *parameter* mapping (return any wrapper as `IJavaObject`)
  * primitives are boxed and unboxed automatically
* **Default methods** are not in the callback interface; they run their Java implementation.
  `equals`/`hashCode`/`toString` of the proxy use identity semantics.
* **Exceptions**:
  * A Pascal exception escaping a callback becomes a `java.lang.RuntimeException` with the
    message `EClassName: message`.
  * An `EJavaException` (a Java exception that passed through Pascal) is rethrown as the
    original Java exception.
  * Nothing ever unwinds through JVM frames.
* **Threads**: Java may call a callback on any thread, including threads that Java created.
  The callback runs on that thread; with FPC on Unix, `cthreads` must be in the program.
* **Lifetime**: Java holds a reference to the Pascal object until the proxy is garbage
  collected. The release then happens on Java's `Cleaner` thread, so the destructor of your
  callback class may run on that thread. `JavaCallbackCount` tells how many are alive.
  A Pascal variable, or a hidden temporary, holding the returned wrapper keeps the proxy
  reachable.
* **Classes implementing Java interfaces**: a wrapper of a Java class doesn't inherit the
  interfaces of the Java interfaces it implements. Use a checked cast:
  `TJList.Cast(MyArrayList)`.
* **Method names in your class**: callback methods carry the same (possibly escaped or renamed)
  names as in `IJFoo`. If one of them clashes with a member of your own class (e.g. a Java
  method `Destroy`), use a method resolution clause:
  `procedure IJFooCallback.Destroy = JavaDestroy;`.

## Runtime notes

* **FPU exceptions**: the JVM requires masked floating point exceptions. `JavaStartVM` masks
  them on every thread that calls Java (pass `MaskFPUExceptions = False` to opt out). As a
  result, Pascal code on those threads gets `Inf`/`NaN` instead of `EDivByZero` etc.
* **Threads**: threads are attached to the JVM automatically, as daemon threads, on their first
  Java call. Call `JavaDetachThread` before a thread ends. With FPC on Unix, put `cthreads`
  first in the program's `uses` clause.
* **Exceptions**: a Java exception becomes `EJavaException`, with `JavaClassName`, `Message`
  (`Throwable.toString()`) and `Throwable` (an `IJavaObject`; cast it with a generated wrapper).
  If a class or method can't be found, you get `EJavaError`; a failed `Cast` gives
  `EJavaCastError`.
* **Identity**: two wrappers can refer to the same Java object; use `JavaSameObject(A, B)`
  (Java `==`) or `A.equals(B)`.
* **Shutdown**: `JavaStopVM` destroys the JVM. Wrappers that are released afterwards don't
  touch the JVM. HotSpot cannot be restarted in the same process.
* **Signals**: the JVM uses `SIGSEGV` internally and chains to handlers installed *before* it
  started. That includes FPC's, so nothing is needed by default. If you install signal handlers
  after `JavaStartVM`, run with `LD_PRELOAD=$JAVA_HOME/lib/libjsig.so`.
* **Native library mode**: if the Pascal code is a library loaded by Java, call
  `JavaUseVM(vm)` from `JNI_OnLoad` instead of `JavaStartVM`.

## Building the test

```bash
./build.sh
JAVA_HOME=~/.sdkman/candidates/java/current build/TestBindings              # tests + benchmark
JAVA_HOME=~/.sdkman/candidates/java/current build/TestBindings --checkjni   # with -Xcheck:jni
```

## Status and limitations

* Tested with **FPC 3.2** on Linux x86-64 and **JDK 25**:
  * 73 tests pass, including with `-Xcheck:jni`
  * a 123-type JDK binding (42k lines, 67 callback interfaces) compiles without warnings
* **Delphi has not been compiled yet.** The code avoids FPC-only features (Delphi mode, no
  macros, `{$IFDEF}`s for unit names and library loading), but it has not been through dcc.
  The riskiest construct is method-resolution clauses on overloaded interface methods
  (`function IJFoo.bar = J_3;` where `J_3` is overloaded).
* Callbacks can implement Java **interfaces** only, not abstract classes
  (`java.lang.reflect.Proxy` cannot extend classes).
* A callback call (about 335 ns) goes through `Proxy` plus boxing. Generating a dedicated Java
  class per interface could bring it closer to the Pascal→Java cost.
* Static methods are taken from the class that declares them only: call
  `TJParent.staticMethod`, not `TJChild.staticMethod`.

## License

MIT, see [LICENSE](LICENSE).
