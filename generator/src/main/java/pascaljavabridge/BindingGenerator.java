package pascaljavabridge;

import java.io.IOException;
import java.lang.invoke.MethodType;
import java.lang.reflect.*;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.stream.Collectors;

/**
 * Generates an Object Pascal unit (Free Pascal + Delphi) with wrappers for Java classes.
 *
 * <p>For every Java type T the unit contains:
 * <ul>
 *   <li>{@code IJ<T>}: a reference counted interface with T's public instance methods
 *       (and getters/setters for public instance fields),</li>
 *   <li>{@code TJ<T>}: a record with T's constructors ({@code New}), static methods,
 *       static field accessors, {@code Cast} and {@code IsInstance},</li>
 *   <li>a hidden implementation class in the implementation section.</li>
 * </ul>
 *
 * <p>Name-collision strategy (see README): all generated identifiers are allocated through
 * case-insensitive scopes; Pascal keywords are escaped with {@code &}; identifiers used by the
 * generated method bodies and by the runtime unit are reserved; implementation methods use
 * mangled names and are bound to the interface methods with method resolution clauses, so no
 * Java name can ever clash with TObject/TInterfacedObject members.
 *
 * <p>Command line: {@code java -jar pascal-java-bridge-generator.jar --unit Name [--out dir]
 * [--cp path] [--depth n] [--exclude pattern]... [--with-runtime] pattern...}; from Java or the
 * Maven plugin: {@link #generate(Options)}.
 */
public final class BindingGenerator {

    // ------------------------------------------------------------------ constants

    /** Words escaped with '&' when used as identifiers (Delphi + FPC reserved words and directives). */
    static final Set<String> KEYWORDS = Set.of(
            "and", "array", "as", "asm", "begin", "case", "class", "const", "constructor",
            "destructor", "dispinterface", "div", "do", "downto", "else", "end", "except", "exports",
            "file", "finalization", "finally", "for", "function", "goto", "if", "implementation", "in",
            "inherited", "initialization", "inline", "interface", "is", "label", "library", "mod", "nil",
            "not", "object", "of", "or", "out", "packed", "procedure", "program", "property", "raise",
            "record", "repeat", "resourcestring", "set", "shl", "shr", "string", "then", "threadvar",
            "to", "try", "type", "unit", "until", "uses", "var", "while", "with", "xor", "operator",
            "on", "at", "absolute", "abstract", "automated", "cdecl", "default", "dispid", "dynamic",
            "export", "external", "far", "forward", "helper", "implements", "index", "message", "name",
            "near", "nodefault", "overload", "override", "pascal", "platform", "private", "protected",
            "public", "published", "read", "readonly", "register", "reintroduce", "safecall", "sealed",
            "static", "stdcall", "stored", "strict", "unsafe", "varargs", "virtual", "write",
            "writeonly", "deprecated", "experimental", "final", "generic", "specialize", "bitpacked",
            "otherwise", "cppdecl", "mwpascal", "softfloat", "local", "noreturn", "assembler",
            "interrupt", "nostackframe", "oldfpccall", "weakexternal", "cvar", "enumerator",
            "reference", "contains", "requires", "package", "delayed", "winapi", "vectorcall");

    /**
     * Identifiers that generated members must never use: everything the generated declarations
     * and method bodies refer to (runtime unit exports, System identifiers, local variable names),
     * so a Java member name can never shadow them.
     */
    static final Set<String> RESERVED = new HashSet<>(List.of(
            // System / RTL identifiers used by generated code
            "self", "result", "true", "false", "boolean", "shortint", "widechar", "smallint", "integer",
            "int64", "single", "double", "unicodestring", "fillchar", "sizeof", "ord", "iinterface",
            "iunknown", "tobject", "system", "exit", "queryinterface", "_addref", "_release",
            // local variables in generated bodies
            "la", "lv", "lh",
            // JavaBridge exports
            "javabridge", "jboolean", "jbyte", "jchar", "jshort", "jint", "jlong", "jfloat", "jdouble",
            "jsize", "jobject", "jclass", "jstring", "jarray", "jthrowable", "jmethodid", "jfieldid",
            "pjvalue", "jvalue", "tjavafunctable", "pjavafunctable", "pjnienv", "ppjnienv", "pjavavm",
            "ppjavavm", "tjavakind", "jkobject", "jkboolean", "jkbyte", "jkchar", "jkshort", "jkint",
            "jklong", "jkfloat", "jkdouble", "jkvoid", "tjavabooleanarray", "tjavabytearray",
            "tjavachararray", "tjavashortarray", "tjavaintarray", "tjavalongarray", "tjavafloatarray",
            "tjavadoublearray", "tjavastringarray", "tjavaobjectarray", "ijavaobject", "ijavahandle",
            "tjavaobjectimpl", "tjavaobjectimplclass", "ejavaexception", "ejavaerror", "ejavacasterror",
            "javastartvm", "javausevm", "javastopvm", "javavmrunning", "javadetachthread", "javaenv",
            "javahandleof", "javasameobject", "javaclassnameof", "javawraplocal", "jrenv",
            "jrresolveclass", "jrresolvemethod", "jrresolvefield", "jrcall", "jrnewobject", "jrgetfield",
            "jrsetfield", "jrhandle", "jrnewglobalref", "jrdeletelocal", "jrnewstring", "jrtakestring",
            "jrisinstance", "jrcheckcast", "jrnewbooleanarray", "jrnewbytearray", "jrnewchararray",
            "jrnewshortarray", "jrnewintarray", "jrnewlongarray", "jrnewfloatarray",
            "jrnewdoublearray", "jrnewstringarray", "jrnewobjectarray", "jrtakebooleanarray",
            "jrtakebytearray", "jrtakechararray", "jrtakeshortarray", "jrtakeintarray",
            "jrtakelongarray", "jrtakefloatarray", "jrtakedoublearray", "jrtakestringarray",
            "jrtakeobjectarray", "tjavadispatchfunc", "jrcreateproxy", "jrargvalue", "jrbox",
            "jrnewlocalref", "jrdefineclass", "javacallbackcount"));

    /**
     * TJavaObjectImpl members that generated bodies call on impl classes. Interface methods may
     * use these names (FPC maps them with a resolution clause), but never with more than one
     * overload: under Delphi overloaded names become impl-class methods (see delphiForwarders)
     * and would hide these.
     */
    static final Set<String> IMPL_MEMBERS = Set.of("javaglobalref", "createfromlocal", "createfromglobal");

    // ------------------------------------------------------------------ model

    /** Case-insensitive identifier scope. */
    static final class Scope {
        final Set<String> used = new HashSet<>();
        final Scope outer;
        Scope(Scope outer) { this.outer = outer; }
        boolean taken(String id) {
            String l = id.toLowerCase(Locale.ROOT);
            return used.contains(l) || RESERVED.contains(l) || (outer != null && outer.taken(id));
        }
        String claim(String base) {
            String id = base;
            for (int i = 1; taken(id); i++) id = base + "_" + i;
            used.add(id.toLowerCase(Locale.ROOT));
            return id;
        }
    }

    /** A Pascal member name within an interface/record chain (may hold several overloads). */
    static final class Entry {
        final String pas;          // unescaped identifier
        final String javaName;     // Java name it was created for ("<field>" entries are not overloadable)
        final boolean overloadable;
        final int implIndex;       // J_<n>
        final Set<String> pasSigs = new HashSet<>();
        boolean isProcedure;
        Entry(String pas, String javaName, boolean overloadable, int implIndex) {
            this.pas = pas; this.javaName = javaName; this.overloadable = overloadable; this.implIndex = implIndex;
        }
    }

    /** Member names of one interface (inheriting its Pascal parent's names) or one record. */
    static final class MemberTable {
        final Map<String, Entry> byName = new LinkedHashMap<>();
        final Set<String> javaKeys = new HashSet<>();   // methods/fields already present (inherited)
        MemberTable copy() {
            MemberTable t = new MemberTable();
            t.byName.putAll(byName);
            t.javaKeys.addAll(javaKeys);
            return t;
        }
    }

    enum MKind { METHOD, CTOR, GETTER, SETTER }

    static final class Member {
        MKind kind;
        boolean isStatic;
        String javaName;          // method or field name
        Class<?>[] params;
        Class<?> ret;             // void.class for procedures / setters
        String jniSig;            // method descriptor or field descriptor
        Entry entry;              // assigned Pascal name
        int idSlot;               // index in GMethods / GFields
        Class<?> fieldType;       // for GETTER/SETTER
    }

    final class TInfo {
        final Class<?> cls;
        String base, intf, comp, impl;
        String guid;
        TInfo parent;
        int clsSlot;
        MemberTable inst = new MemberTable();
        MemberTable stat = new MemberTable();
        final List<Member> newInst = new ArrayList<>();
        final List<Member> statics = new ArrayList<>();
        String instParam = "p", statParam = "p";
        /** all instance methods by key "m:name(params)", including inherited ones */
        final Map<String, Member> allInst = new HashMap<>();
        /** callback support (Java interfaces with abstract methods only) */
        List<String> abstractKeys = List.of();
        final List<Member> cbMethods = new ArrayList<>();
        String cbIntf, cbGuid, dispatch;
        TInfo(Class<?> c) { cls = c; }
        boolean hasCallback() { return !abstractKeys.isEmpty(); }
        String jniName() { return c2jni(cls); }
    }

    /** Unit-per-package mode: one generated package unit (one package, or a cycle of them). */
    static final class PUnit {
        String name;
        final List<String> packages = new ArrayList<>();
        List<TInfo> types = new ArrayList<>();          // in topological order
        final Map<String, Integer> classes = new LinkedHashMap<>();
        final Map<Integer, Integer> methods = new HashMap<>();
        final Map<Integer, Integer> fields = new HashMap<>();
        final Set<PUnit> implUses = new HashSet<>();   // units whose implementation classes are used
    }

    // ------------------------------------------------------------------ state

    final String unitName;
    final ClassLoader loader;
    final Map<Class<?>, TInfo> types = new LinkedHashMap<>();
    final Scope global = new Scope(null);
    final Map<String, Integer> classSlots = new LinkedHashMap<>();
    int methodSlots = 0, fieldSlots = 0, implCounter = 0;
    String varClasses, varMethods, varFields;
    boolean unitPerPackage;
    final List<PUnit> units = new ArrayList<>();
    final Map<TInfo, PUnit> unitOf = new HashMap<>();
    PUnit cur;   // package unit being emitted (null in single-unit mode)

    BindingGenerator(String unitName, ClassLoader loader) {
        this.unitName = unitName;
        this.loader = loader;
    }

    // ------------------------------------------------------------------ API

    /** Settings for {@link #generate(Options)}; also used by the Maven plugin. */
    public static final class Options {
        /** Name of the Pascal unit (also the file name). Required. */
        public String unit;
        /** Directory the unit (and, with {@link #withRuntime}, the runtime) is written to. */
        public Path outputDirectory = Path.of(".");
        /** Directories and jars to search; the JDK is always available. */
        public List<Path> classpath = new ArrayList<>();
        /** Class names or wildcard patterns to wrap. Required. */
        public List<String> includes = new ArrayList<>();
        /** Wildcard patterns of classes to leave out. */
        public List<String> excludes = new ArrayList<>();
        /** Also wrap types referenced by the selected classes, this many levels deep. */
        public int depth;
        /** Also write the Pascal runtime ({@link #RUNTIME_FILES}). */
        public boolean withRuntime;
        /**
         * Write the interface types to the unit {@link #unit} and the records and implementation
         * code to one unit per Java package, named {@code <unit>_<package>} (e.g. JJava_java_util).
         */
        public boolean unitPerPackage;
        /**
         * Also write {@code <unit>Com.pas} (Delphi only): early-bound COM Automation wrappers, the type
         * library description, and the COM server project {@code <unit>ComServer.dpr}.
         */
        public boolean com;
        public java.util.function.Consumer<String> info = System.out::println;
        public java.util.function.Consumer<String> warn = m -> System.err.println("warning: " + m);
    }

    /** Runtime files shipped in the generator jar (see generator/pom.xml). */
    public static final List<String> RUNTIME_FILES = List.of("JavaBridge.pas", "JavaBridgeHandler.inc",
            "JavaBridgeCom.pas", "JavaBridgeDynamic.inc", "JavaBridgeAuto.pas");

    /** Generates the unit(s); returns the path of the written .pas file (the types unit). */
    public static Path generate(Options o) throws Exception {
        if (o.unit == null || !o.unit.matches("[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)*"))
            throw new IllegalArgumentException("Invalid or missing unit name: " + o.unit);
        if (o.includes.isEmpty()) throw new IllegalArgumentException("No classes or patterns given");
        List<URL> urls = new ArrayList<>();
        for (Path p : o.classpath) urls.add(p.toUri().toURL());
        // parent = platform loader: only the JDK and the given classpath are visible, never the
        // generator's own (or Maven's) classes
        try (URLClassLoader loader = new URLClassLoader(urls.toArray(URL[]::new),
                ClassLoader.getPlatformClassLoader())) {
            BindingGenerator g = new BindingGenerator(o.unit, loader);
            g.classpath = o.classpath;
            g.info = o.info;
            g.warn = o.warn;
            g.unitPerPackage = o.unitPerPackage;
            g.collect(o.includes, o.excludes, o.depth);
            g.assignNames();
            Path file = o.outputDirectory.resolve(o.unit + ".pas");
            Files.createDirectories(o.outputDirectory);
            if (!o.unitPerPackage) {
                writeIfChanged(file, g.emit());
                o.info.accept("Wrote " + file + " (" + g.types.size() + " Java types)");
            } else {
                for (PUnit u : g.units)
                    writeIfChanged(o.outputDirectory.resolve(u.name + ".pas"), g.emitPackageUnit(u));
                writeIfChanged(file, g.emitTypesUnit());
                o.info.accept("Wrote " + file + " and " + g.units.size() + " package units to "
                        + o.outputDirectory + " (" + g.types.size() + " Java types)");
            }
            if (o.com) {
                ComGenerator cg = new ComGenerator(g);
                Path com = o.outputDirectory.resolve(o.unit + "Com.pas");
                writeIfChanged(com, cg.emit());
                writeIfChanged(o.outputDirectory.resolve(o.unit + "ComServer.dpr"), cg.emitServer());
                o.info.accept("Wrote " + com + " and " + o.unit + "ComServer.dpr (COM Automation)");
            }
            if (o.withRuntime) writeRuntime(o.outputDirectory);
            return file;
        }
    }

    /** Copies the Pascal runtime unit from the generator jar to dir. */
    public static void writeRuntime(Path dir) throws IOException {
        Files.createDirectories(dir);
        for (String f : RUNTIME_FILES) {
            try (var in = BindingGenerator.class.getResourceAsStream("runtime/" + f)) {
                byte[] bytes;
                if (in != null) {
                    bytes = in.readAllBytes();
                } else {
                    Path src = sourceRuntimeDir();
                    if (src == null || !Files.isRegularFile(src.resolve(f)))
                        throw new IOException("Runtime file " + f + " is not packaged with the generator "
                                + "(run the generator from its jar)");
                    bytes = Files.readAllBytes(src.resolve(f));
                }
                writeIfChanged(dir.resolve(f), new String(bytes, StandardCharsets.UTF_8));
            }
        }
    }

    /**
     * The repository's runtime folder when the generator runs from {@code generator/target/classes}
     * (an IDE launch) instead of its jar; null otherwise.
     */
    static Path sourceRuntimeDir() {
        try {
            var cs = BindingGenerator.class.getProtectionDomain().getCodeSource();
            if (cs == null) return null;
            Path classes = Path.of(cs.getLocation().toURI());
            if (!Files.isDirectory(classes)) return null;   // a jar
            for (Path p = classes; p != null; p = p.getParent()) {
                Path r = p.resolve("runtime");
                if (Files.isRegularFile(r.resolve("JavaBridge.pas"))) return r;
            }
        } catch (Exception e) {
            // no fallback
        }
        return null;
    }

    /** Writes the file only if its content differs, so incremental builds don't recompile. */
    static void writeIfChanged(Path file, String content) throws IOException {
        if (Files.exists(file) && Files.readString(file, StandardCharsets.UTF_8).equals(content)) return;
        Files.writeString(file, content, StandardCharsets.UTF_8);
    }

    // ------------------------------------------------------------------ command line

    public static void main(String[] args) throws Exception {
        Options o = new Options();
        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {
                case "--unit" -> o.unit = args[++i];
                case "--out" -> o.outputDirectory = Path.of(args[++i]);
                case "--cp" -> {
                    for (String p : args[++i].split(java.io.File.pathSeparator))
                        if (!p.isEmpty()) o.classpath.add(Path.of(p));
                }
                case "--depth" -> o.depth = Integer.parseInt(args[++i]);
                case "--exclude" -> o.excludes.add(args[++i]);
                case "--with-runtime" -> o.withRuntime = true;
                case "--unit-per-package" -> o.unitPerPackage = true;
                case "--com" -> o.com = true;
                case "-h", "--help" -> { usage(); return; }
                default -> o.includes.add(args[i]);
            }
        }
        if (o.unit == null || o.includes.isEmpty()) { usage(); System.exit(2); }
        generate(o);
    }

    static void usage() {
        System.err.println("""
                usage: java -jar pascal-java-bridge-generator.jar --unit <PascalUnitName> [--out <dir>]
                         [--cp <classpath>] [--depth <n>] [--exclude <pattern>]... [--with-runtime]
                         [--unit-per-package] [--com] <pattern>...

                  <pattern>       a class name (java.util.ArrayList, java.util.Map$Entry) or a
                                  wildcard pattern:
                                    java.util.*       all public classes in package java.util
                                    java.util.**      ... and in all its subpackages
                                    java.util.*Map    '*' matches within one name segment,
                                                      '**' matches across packages
                                  Wildcards search the JDK (exported packages only) and --cp.
                  --exclude       leave out classes matching the pattern (repeatable)
                  --depth n       also wrap the public types referenced by the selected classes,
                                  up to n levels deep (default 0)
                  --with-runtime  also write the Pascal runtime (JavaBridge.pas, JavaBridgeCom.pas, .inc)
                  --unit-per-package
                                  write the interface types to <PascalUnitName> and the records
                                  and implementation code to one unit per Java package, named
                                  <PascalUnitName>_<package> (e.g. JJava_java_util)
                  --com           (Delphi) also write <PascalUnitName>Com.pas, early-bound COM
                                  Automation wrappers with a type library, and the COM server
                                  project <PascalUnitName>ComServer.dpr""");
    }

    // ------------------------------------------------------------------ collection

    List<Path> classpath = List.of();
    java.util.function.Consumer<String> info = System.out::println;
    java.util.function.Consumer<String> warn = m -> System.err.println("warning: " + m);

    void collect(List<String> names, List<String> excludes, int depth) throws Exception {
        List<java.util.regex.Pattern> ex = excludes.stream().map(BindingGenerator::globToRegex).toList();
        java.util.function.Predicate<Class<?>> excluded =
                c -> c != Object.class && ex.stream().anyMatch(r -> r.matcher(c.getName()).matches());
        Set<Class<?>> set = new LinkedHashSet<>();
        set.add(Object.class);
        List<Class<?>> frontier = new ArrayList<>();
        for (String n : names) {
            if (n.contains("*")) {
                int matched = 0;
                for (String cn : expandPattern(n)) {
                    Class<?> c = tryLoad(cn);
                    if (c == null || !isWrappable(c) || excluded.test(c)) continue;
                    matched++;
                    if (set.add(c)) frontier.add(c);
                }
                info.accept(n + ": " + matched + " public types");
                if (matched == 0) warn.accept("no public classes match " + n);
                continue;
            }
            Class<?> c = Class.forName(n, false, loader);
            if (!isWrappable(c)) throw new IllegalArgumentException("Not a public class/interface: " + n);
            if (!isUsable(c)) throw new IllegalArgumentException("Cannot inspect " + n + " (missing dependencies?)");
            if (!excluded.test(c) && set.add(c)) frontier.add(c);
        }
        for (int d = 0; d < depth; d++) {
            List<Class<?>> next = new ArrayList<>();
            for (Class<?> c : frontier)
                for (Class<?> r : referencedTypes(c))
                    if (!excluded.test(r) && isUsable(r) && set.add(r)) next.add(r);
            frontier = next;
        }
        for (Class<?> c : set) types.put(c, new TInfo(c));
    }

    /**
     * Glob for class names: '**' matches anything (including '.'), '*' matches within one
     * name segment (no '.'). Nested classes ('$') count as part of their segment.
     */
    static java.util.regex.Pattern globToRegex(String glob) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < glob.length(); i++) {
            char ch = glob.charAt(i);
            if (ch == '*') {
                if (i + 1 < glob.length() && glob.charAt(i + 1) == '*') {
                    sb.append(".*");
                    i++;
                } else sb.append("[^.]*");
            } else sb.append(java.util.regex.Pattern.quote(String.valueOf(ch)));
        }
        return java.util.regex.Pattern.compile(sb.toString());
    }

    /** All class names (binary names) matching a wildcard pattern, from the JDK and --cp. */
    List<String> expandPattern(String pattern) throws IOException {
        int star = pattern.indexOf('*');
        int dot = pattern.lastIndexOf('.', star);
        if (dot < 0) throw new IllegalArgumentException("Pattern needs a package prefix: " + pattern);
        String pkgPath = pattern.substring(0, dot).replace('.', '/');
        java.util.regex.Pattern re = globToRegex(pattern);
        boolean deep = pattern.substring(dot).contains("**") || pattern.substring(dot + 1).contains(".");
        Set<String> found = new TreeSet<>();
        java.util.function.Consumer<String> consider = rel -> {   // rel: a/b/C$D.class
            if (!rel.endsWith(".class") || rel.endsWith("module-info.class")
                    || rel.endsWith("package-info.class")) return;
            String cn = rel.substring(0, rel.length() - 6).replace('/', '.');
            if (re.matcher(cn).matches()) found.add(cn);
        };
        // JDK modules
        FileSystem jrt = FileSystems.getFileSystem(java.net.URI.create("jrt:/"));
        try (DirectoryStream<Path> mods = Files.newDirectoryStream(jrt.getPath("/modules"))) {
            for (Path mod : mods) {
                Path dir = mod.resolve(pkgPath);
                if (Files.isDirectory(dir)) walk(dir, mod, deep, consider);
            }
        }
        // classpath entries
        for (Path e : classpath) {
            if (Files.isDirectory(e)) {
                Path dir = e.resolve(pkgPath);
                if (Files.isDirectory(dir)) walk(dir, e, deep, consider);
            } else if (Files.isRegularFile(e)) {
                try (java.util.jar.JarFile jar = new java.util.jar.JarFile(e.toFile())) {
                    String prefix = pkgPath + "/";
                    jar.stream().map(java.util.zip.ZipEntry::getName)
                            .filter(n -> n.startsWith(prefix))
                            .filter(n -> deep || n.indexOf('/', prefix.length()) < 0)
                            .forEach(consider);
                }
            }
        }
        return new ArrayList<>(found);
    }

    private static void walk(Path dir, Path root, boolean deep, java.util.function.Consumer<String> consider)
            throws IOException {
        try (var st = Files.walk(dir, deep ? Integer.MAX_VALUE : 1)) {
            st.filter(Files::isRegularFile)
                    .forEach(f -> consider.accept(root.relativize(f).toString().replace('\\', '/')));
        }
    }

    /** Loads a class found by a wildcard; null (with a warning) if it cannot be used. */
    Class<?> tryLoad(String name) {
        try {
            Class<?> c = Class.forName(name, false, loader);
            Module m = c.getModule();
            if (m.isNamed() && !m.isExported(c.getPackageName())) return null;   // JDK internals
            return isUsable(c) ? c : null;
        } catch (ClassNotFoundException | LinkageError e) {
            warn.accept("skipping " + name + ": " + e);
            return null;
        }
    }

    /** False if reflecting over the class fails (e.g. missing dependencies on the classpath). */
    boolean isUsable(Class<?> c) {
        try {
            c.getMethods();
            c.getDeclaredMethods();
            c.getFields();
            c.getDeclaredFields();
            c.getConstructors();
            return true;
        } catch (LinkageError | SecurityException e) {
            warn.accept("skipping " + c.getName() + ": " + e);
            return false;
        }
    }

    static boolean isWrappable(Class<?> c) {
        if (c.isPrimitive() || c.isArray() || c == String.class || c.isSynthetic() || c.isAnonymousClass()
                || c.isLocalClass() || c.isHidden()) return false;
        for (Class<?> x = c; x != null; x = x.getEnclosingClass())
            if (!Modifier.isPublic(x.getModifiers())) return false;
        return true;
    }

    List<Class<?>> referencedTypes(Class<?> c) {
        List<Class<?>> out = new ArrayList<>();
        java.util.function.Consumer<Class<?>> add = t -> {
            while (t.isArray()) t = t.getComponentType();
            if (isWrappable(t)) out.add(t);
        };
        if (c.getSuperclass() != null) add.accept(c.getSuperclass());
        for (Class<?> i : c.getInterfaces()) add.accept(i);
        for (Method m : publicMethods(c)) {
            add.accept(m.getReturnType());
            for (Class<?> p : m.getParameterTypes()) add.accept(p);
        }
        for (Method m : declaredStatics(c)) {
            add.accept(m.getReturnType());
            for (Class<?> p : m.getParameterTypes()) add.accept(p);
        }
        for (Field f : c.getFields()) add.accept(f.getType());
        for (Constructor<?> k : c.getConstructors())
            for (Class<?> p : k.getParameterTypes()) add.accept(p);
        return out;
    }

    /** Public instance methods, covariant duplicates removed (most specific return type wins). */
    static List<Method> publicMethods(Class<?> c) {
        Map<String, Method> best = new TreeMap<>();
        for (Method m : c.getMethods()) {
            if (Modifier.isStatic(m.getModifiers()) || m.isSynthetic() || m.isBridge()) continue;
            String key = m.getName() + paramDesc(m.getParameterTypes());
            Method prev = best.get(key);
            if (prev == null || prev.getReturnType().isAssignableFrom(m.getReturnType())
                    && prev.getReturnType() != m.getReturnType())
                best.put(key, m);
        }
        return new ArrayList<>(best.values());
    }

    static List<Method> declaredStatics(Class<?> c) {
        return Arrays.stream(c.getDeclaredMethods())
                .filter(m -> Modifier.isStatic(m.getModifiers()) && Modifier.isPublic(m.getModifiers())
                        && !m.isSynthetic() && !m.isBridge())
                .sorted(Comparator.comparing(Method::getName)
                        .thenComparing(m -> paramDesc(m.getParameterTypes())))
                .toList();
    }

    // ------------------------------------------------------------------ naming

    void assignNames() {
        // reserve the unit name (and its dotted parts) and the runtime unit
        for (String part : unitName.split("\\.")) global.claim(part);
        for (TInfo t : types.values()) t.parent = pascalParent(t);
        if (unitPerPackage) assignUnits();

        // 1. type base names: simple name, qualified when ambiguous (case-insensitive)
        Map<TInfo, String> simple = new HashMap<>();
        Map<String, Integer> counts = new HashMap<>();
        for (TInfo t : types.values()) {
            String s = mangle(simpleBinaryName(t.cls));
            simple.put(t, s);
            counts.merge(s.toLowerCase(Locale.ROOT), 1, Integer::sum);
        }
        for (TInfo t : sortedTypes()) {
            String s = simple.get(t);
            if (counts.get(s.toLowerCase(Locale.ROOT)) > 1) s = mangle(t.cls.getName().replace('.', '_'));
            t.base = s;
        }
        // 2. public type identifiers
        Set<String> bases = new HashSet<>();
        for (TInfo t : sortedTypes()) {
            String b = t.base;
            for (int i = 1; !bases.add(b.toLowerCase(Locale.ROOT)); i++) b = t.base + "_" + i;
            t.base = b;
        }
        for (TInfo t : sortedTypes()) {
            t.intf = global.claim("IJ" + t.base);
            t.comp = global.claim("TJ" + t.base);
        }
        for (TInfo t : sortedTypes()) {
            t.abstractKeys = abstractMethodKeys(t.cls);
            if (t.hasCallback()) t.cbIntf = global.claim("IJ" + t.base + "Callback");
        }
        // 3. implementation-only identifiers
        for (TInfo t : sortedTypes()) t.impl = global.claim("TJ" + t.base + "Impl");
        for (TInfo t : sortedTypes())
            if (t.hasCallback()) t.dispatch = global.claim("Dispatch_" + t.base);
        varClasses = global.claim("GClasses");
        varMethods = global.claim("GMethods");
        varFields = global.claim("GFields");

        // 4. hierarchy, guid, class slot
        for (TInfo t : types.values()) {
            t.guid = guid("pascal-java-bridge:" + t.cls.getName());
            t.cbGuid = guid("pascal-java-bridge-callback:" + t.cls.getName());
            t.clsSlot = classSlot(t.jniName());
        }
        // 5. members, parents first
        for (TInfo t : topoOrder()) {
            assignInstanceMembers(t);
            assignStaticMembers(t);
            for (String k : t.abstractKeys) {
                Member m = t.allInst.get(k);
                if (m == null) throw new IllegalStateException("abstract method not found: " + k);
                t.cbMethods.add(m);
            }
        }
    }

    static String packageOf(Class<?> c) {
        String n = c.getName();
        int dot = n.lastIndexOf('.');
        return dot < 0 ? "" : n.substring(0, dot);
    }

    /**
     * Groups the types into package units. An implementation class inherits from its parent's,
     * so a unit's interface section uses the units of the parent types; Pascal forbids cycles
     * there, so packages whose parent relations form a cycle share one unit. That unit is named
     * after the package that contains the others, or else the one they inherit from most.
     */
    void assignUnits() {
        Map<String, Set<String>> edges = new TreeMap<>();
        Map<String, Integer> inherited = new HashMap<>();
        for (TInfo t : types.values()) {
            String p = packageOf(t.cls);
            edges.computeIfAbsent(p, k -> new TreeSet<>());
            if (t.parent != null && !packageOf(t.parent.cls).equals(p)) {
                edges.get(p).add(packageOf(t.parent.cls));
                inherited.merge(packageOf(t.parent.cls), 1, Integer::sum);
            }
        }
        // Tarjan's strongly connected components
        Map<String, Integer> index = new HashMap<>(), low = new HashMap<>();
        Deque<String> stack = new ArrayDeque<>();
        Set<String> onStack = new HashSet<>();
        List<List<String>> sccs = new ArrayList<>();
        for (String p : edges.keySet()) if (!index.containsKey(p)) tarjan(p, edges, index, low, stack, onStack, sccs);

        Map<String, PUnit> byPackage = new HashMap<>();
        for (List<String> scc : sccs) {
            PUnit u = new PUnit();
            u.packages.addAll(new TreeSet<>(scc));
            // a package containing all others (java.nio.channels for .spi), else the most inherited
            String main = u.packages.stream()
                    .filter(p -> u.packages.stream().allMatch(q -> q.equals(p) || q.startsWith(p + ".")))
                    .findFirst()
                    .orElseGet(() -> u.packages.stream()
                            .max(Comparator.comparing((String p) -> inherited.getOrDefault(p, 0))
                                    .thenComparing(Comparator.reverseOrder())).orElseThrow());
            u.packages.remove(main);
            u.packages.add(0, main);
            u.name = claimUnitName(main.isEmpty() ? "default" : mangle(main));
            if (u.packages.size() > 1)
                warn.accept("packages " + String.join(", ", u.packages) + " depend on each other through "
                        + "class inheritance, so they share unit " + u.name);
            for (String p : u.packages) byPackage.put(p, u);
            units.add(u);
        }
        units.sort(Comparator.comparing(u -> u.name.toLowerCase(Locale.ROOT)));
        for (TInfo t : types.values()) unitOf.put(t, byPackage.get(packageOf(t.cls)));
        for (TInfo t : topoOrder()) unitOf.get(t).types.add(t);
    }

    private String claimUnitName(String suffix) {
        int dot = unitName.lastIndexOf('.');
        String last = global.claim(unitName.substring(dot + 1) + "_" + suffix);
        return unitName.substring(0, dot + 1) + last;
    }

    private static void tarjan(String v, Map<String, Set<String>> edges, Map<String, Integer> index,
                               Map<String, Integer> low, Deque<String> stack, Set<String> onStack,
                               List<List<String>> out) {
        index.put(v, index.size());
        low.put(v, index.get(v));
        stack.push(v);
        onStack.add(v);
        for (String w : edges.getOrDefault(v, Set.of())) {
            if (!index.containsKey(w)) {
                tarjan(w, edges, index, low, stack, onStack, out);
                low.put(v, Math.min(low.get(v), low.get(w)));
            } else if (onStack.contains(w)) {
                low.put(v, Math.min(low.get(v), index.get(w)));
            }
        }
        if (low.get(v).equals(index.get(v))) {
            List<String> scc = new ArrayList<>();
            String w;
            do { w = stack.pop(); onStack.remove(w); scc.add(w); } while (!w.equals(v));
            out.add(scc);
        }
    }

    static String guid(String seed) {
        return UUID.nameUUIDFromBytes(seed.getBytes(StandardCharsets.UTF_8)).toString().toUpperCase(Locale.ROOT);
    }

    /** Keys of the abstract methods a Pascal callback must implement (Java interfaces only). */
    static List<String> abstractMethodKeys(Class<?> c) {
        if (!c.isInterface()) return List.of();
        List<String> keys = new ArrayList<>();
        for (Method m : publicMethods(c)) {
            if (!Modifier.isAbstract(m.getModifiers()) || m.isDefault()) continue;
            try {   // equals/hashCode/toString redeclared by the interface are implemented by Object
                Method om = Object.class.getMethod(m.getName(), m.getParameterTypes());
                if (Modifier.isPublic(om.getModifiers())) continue;
            } catch (NoSuchMethodException ignored) {
                // not an Object method
            }
            keys.add("m:" + m.getName() + paramDesc(m.getParameterTypes()));
        }
        return keys;
    }

    List<TInfo> sortedTypes() {
        return types.values().stream().sorted(Comparator.comparing(t -> t.cls.getName())).toList();
    }

    List<TInfo> topoOrder() {
        List<TInfo> out = new ArrayList<>();
        Set<TInfo> done = new HashSet<>();
        for (TInfo t : sortedTypes()) visit(t, done, out);
        return out;
    }

    private void visit(TInfo t, Set<TInfo> done, List<TInfo> out) {
        if (done.contains(t)) return;
        if (t.parent != null) visit(t.parent, done, out);
        done.add(t);
        out.add(t);
    }

    TInfo pascalParent(TInfo t) {
        Class<?> c = t.cls;
        if (c == Object.class) return null;
        if (!c.isInterface()) {
            for (Class<?> s = c.getSuperclass(); s != null; s = s.getSuperclass())
                if (types.containsKey(s)) return types.get(s);
            return types.get(Object.class);
        }
        // interface: breadth-first over super-interfaces
        Deque<Class<?>> q = new ArrayDeque<>(List.of(c.getInterfaces()));
        Set<Class<?>> seen = new HashSet<>();
        while (!q.isEmpty()) {
            Class<?> i = q.poll();
            if (!seen.add(i)) continue;
            if (types.containsKey(i)) return types.get(i);
            q.addAll(List.of(i.getInterfaces()));
        }
        return types.get(Object.class);
    }

    int classSlot(String jniName) {
        return classSlots.computeIfAbsent(jniName, k -> classSlots.size());
    }

    /** Allocates a Pascal name in a member table; overloads share a name when possible. */
    Entry allocate(MemberTable table, String javaName, String base, boolean overloadable,
                   String pasSig, boolean isProcedure) {
        String candidate = base;
        for (int i = 1; ; i++) {
            String l = candidate.toLowerCase(Locale.ROOT);
            Entry e = table.byName.get(l);
            if (e == null && !global.taken(candidate)) {
                e = new Entry(candidate, javaName, overloadable, ++implCounter);
                e.isProcedure = isProcedure;
                e.pasSigs.add(pasSig);
                table.byName.put(l, e);
                return e;
            }
            if (e != null && overloadable && e.overloadable && e.javaName.equals(javaName)
                    && !e.pasSigs.contains(pasSig) && !IMPL_MEMBERS.contains(l)) {
                e.pasSigs.add(pasSig);
                return e;
            }
            candidate = base + "_" + i;
        }
    }

    void assignInstanceMembers(TInfo t) {
        t.inst = t.parent == null ? new MemberTable() : t.parent.inst.copy();
        if (t.parent != null) t.allInst.putAll(t.parent.allInst);
        for (Method m : publicMethods(t.cls)) {
            String key = "m:" + m.getName() + paramDesc(m.getParameterTypes());
            if (!t.inst.javaKeys.add(key)) continue;           // inherited from the Pascal parent
            Member mm = new Member();
            mm.kind = MKind.METHOD;
            mm.javaName = m.getName();
            mm.params = m.getParameterTypes();
            mm.ret = m.getReturnType();
            mm.jniSig = MethodType.methodType(mm.ret, mm.params).toMethodDescriptorString();
            mm.entry = allocate(t.inst, mm.javaName, mangle(mm.javaName), true, pasSig(mm.params),
                    mm.ret == void.class);
            mm.idSlot = methodSlots++;
            t.newInst.add(mm);
            t.allInst.put(key, mm);
        }
        List<Field> fields = Arrays.stream(t.cls.getFields())
                .filter(f -> !Modifier.isStatic(f.getModifiers()) && !f.isSynthetic())
                .sorted(Comparator.comparing(Field::getName)).toList();
        for (Field f : fields) {
            String key = "f:" + f.getName() + ":" + f.getDeclaringClass().getName();
            if (!t.inst.javaKeys.add(key)) continue;
            addFieldAccessors(t, t.inst, t.newInst, f);
        }
        t.instParam = paramPrefix(t.inst);
    }

    void assignStaticMembers(TInfo t) {
        MemberTable st = t.stat;
        // fixed helpers first so they keep their names
        allocate(st, "<cast>", "Cast", false, "", false);
        allocate(st, "<isinstance>", "IsInstance", false, "", false);
        if (t.hasCallback()) allocate(st, "<implement>", "Implement", false, "", false);
        if (!t.cls.isInterface() && !Modifier.isAbstract(t.cls.getModifiers())) {
            Constructor<?>[] ctors = t.cls.getConstructors();
            Arrays.sort(ctors, Comparator.comparing(k -> paramDesc(k.getParameterTypes())));
            for (Constructor<?> k : ctors) {
                if (k.isSynthetic()) continue;
                Member mm = new Member();
                mm.kind = MKind.CTOR;
                mm.isStatic = true;
                mm.javaName = "<init>";
                mm.params = k.getParameterTypes();
                mm.ret = t.cls;
                mm.jniSig = MethodType.methodType(void.class, mm.params).toMethodDescriptorString();
                mm.entry = allocate(st, "<init>", "New", true, pasSig(mm.params), false);
                mm.idSlot = methodSlots++;
                t.statics.add(mm);
            }
        }
        for (Method m : declaredStatics(t.cls)) {
            Member mm = new Member();
            mm.kind = MKind.METHOD;
            mm.isStatic = true;
            mm.javaName = m.getName();
            mm.params = m.getParameterTypes();
            mm.ret = m.getReturnType();
            mm.jniSig = MethodType.methodType(mm.ret, mm.params).toMethodDescriptorString();
            mm.entry = allocate(st, mm.javaName, mangle(mm.javaName), true, pasSig(mm.params),
                    mm.ret == void.class);
            mm.idSlot = methodSlots++;
            t.statics.add(mm);
        }
        List<Field> fields = Arrays.stream(t.cls.getDeclaredFields())
                .filter(f -> Modifier.isStatic(f.getModifiers()) && Modifier.isPublic(f.getModifiers())
                        && !f.isSynthetic())
                .sorted(Comparator.comparing(Field::getName)).toList();
        for (Field f : fields) addFieldAccessors(t, st, t.statics, f);
        t.statParam = paramPrefix(st);
    }

    void addFieldAccessors(TInfo t, MemberTable table, List<Member> out, Field f) {
        boolean isStatic = Modifier.isStatic(f.getModifiers());
        int slot = fieldSlots++;
        Member g = new Member();
        g.kind = MKind.GETTER;
        g.isStatic = isStatic;
        g.javaName = f.getName();
        g.fieldType = f.getType();
        g.params = new Class<?>[0];
        g.ret = f.getType();
        g.jniSig = f.getType().descriptorString();
        g.entry = allocate(table, "<field>", mangle(f.getName()), false, "", false);
        g.idSlot = slot;
        out.add(g);
        if (!Modifier.isFinal(f.getModifiers())) {
            Member s = new Member();
            s.kind = MKind.SETTER;
            s.isStatic = isStatic;
            s.javaName = f.getName();
            s.fieldType = f.getType();
            s.params = new Class<?>[]{f.getType()};
            s.ret = void.class;
            s.jniSig = g.jniSig;
            s.entry = allocate(table, "<field>", "Set_" + mangle(f.getName()), false, "", true);
            s.idSlot = slot;
            out.add(s);
        }
    }

    /** Parameter name prefix that cannot clash with any member name in the table. */
    static String paramPrefix(MemberTable table) {
        String prefix = "p";
        while (true) {
            String pre = prefix.toLowerCase(Locale.ROOT);
            boolean clash = table.byName.keySet().stream()
                    .anyMatch(n -> n.startsWith(pre) && n.substring(pre.length()).matches("\\d+"));
            if (!clash) return prefix;
            prefix += "_";
        }
    }

    static String simpleBinaryName(Class<?> c) {
        String n = c.getName();
        int dot = n.lastIndexOf('.');
        return n.substring(dot + 1);
    }

    /** Converts a Java identifier to an ASCII Pascal identifier. */
    static String mangle(String javaName) {
        StringBuilder sb = new StringBuilder();
        javaName.codePoints().forEach(cp -> {
            if ((cp >= 'a' && cp <= 'z') || (cp >= 'A' && cp <= 'Z') || (cp >= '0' && cp <= '9') || cp == '_')
                sb.append((char) cp);
            else if (cp == '$' || cp == '.') sb.append('_');
            else sb.append(String.format("_u%04X", cp));
        });
        if (sb.isEmpty() || Character.isDigit(sb.charAt(0))) sb.insert(0, '_');
        return sb.toString();
    }

    static String esc(String id) {
        return KEYWORDS.contains(id.toLowerCase(Locale.ROOT)) ? "&" + id : id;
    }

    // ------------------------------------------------------------------ type mapping

    static String paramDesc(Class<?>[] ps) {
        return Arrays.stream(ps).map(Class::descriptorString).collect(Collectors.joining("", "(", ")"));
    }

    String pasSig(Class<?>[] ps) {
        return Arrays.stream(ps).map(p -> pasType(p, true).toLowerCase(Locale.ROOT))
                .collect(Collectors.joining(","));
    }

    /** Pascal type of a Java type. Object parameters accept any wrapper (IJavaObject). */
    String pasType(Class<?> c, boolean asParam) {
        if (c.isPrimitive()) return switch (c.getName()) {
            case "boolean" -> "Boolean";
            case "byte" -> "ShortInt";
            case "char" -> "WideChar";
            case "short" -> "SmallInt";
            case "int" -> "Integer";
            case "long" -> "Int64";
            case "float" -> "Single";
            case "double" -> "Double";
            default -> throw new IllegalStateException(c.getName());
        };
        if (c == String.class) return "UnicodeString";
        if (c.isArray()) {
            Class<?> e = c.getComponentType();
            if (e.isPrimitive()) return "TJava" + cap(e.getName()) + "Array";
            if (e == String.class) return "TJavaStringArray";
            return "TJavaObjectArray";
        }
        if (c == Object.class && asParam) return "IJavaObject";
        TInfo t = types.get(c);
        return t != null ? t.intf : "IJavaObject";
    }

    static String cap(String s) { return Character.toUpperCase(s.charAt(0)) + s.substring(1); }

    static char jvalueField(Class<?> c) {
        if (!c.isPrimitive()) return 'l';
        return switch (c.getName()) {
            case "boolean" -> 'z'; case "byte" -> 'b'; case "char" -> 'c'; case "short" -> 's';
            case "int" -> 'i'; case "long" -> 'j'; case "float" -> 'f'; case "double" -> 'd';
            default -> throw new IllegalStateException();
        };
    }

    static String kind(Class<?> c) {
        if (c == void.class) return "jkVoid";
        if (!c.isPrimitive()) return "jkObject";
        return "jk" + cap(c.getName());
    }

    static boolean isManaged(Class<?> c) { return !c.isPrimitive(); }

    /** Expression converting Pascal parameter value to a jvalue field; null if a plain assignment. */
    String argToJava(Class<?> c, String v) {
        if (c.isPrimitive()) return switch (c.getName()) {
            case "boolean" -> "Ord(" + v + ")";
            case "char" -> "Ord(" + v + ")";
            default -> v;
        };
        if (c == String.class) return "JrNewString(" + v + ")";
        if (c.isArray()) {
            Class<?> e = c.getComponentType();
            if (e.isPrimitive()) return "JrNew" + cap(e.getName()) + "Array(" + v + ")";
            if (e == String.class) return "JrNewStringArray(" + v + ")";
            int slot = cSlot(c2jni(e));
            return "JrNewObjectArray(" + v + ", JrResolveClass(" + varClasses + "[" + slot + "], "
                    + pasStr(c2jni(e)) + "))";
        }
        return "JrHandle(" + v + ")";
    }

    /** True if the converted argument is a new local reference that must be deleted. */
    static boolean argIsLocalRef(Class<?> c) {
        return c == String.class || c.isArray();
    }

    /** Statement(s) converting jvalue LV to Result. */
    String javaToResult(Class<?> c) {
        return javaToVar(c, "Result");
    }

    /** Statement(s) converting jvalue LV (a local reference for objects) to variable v. */
    String javaToVar(Class<?> c, String v) {
        if (c.isPrimitive()) return switch (c.getName()) {
            case "boolean" -> v + " := LV.z <> 0;";
            case "char" -> v + " := WideChar(LV.c);";
            default -> v + " := LV." + jvalueField(c) + ";";
        };
        if (c == String.class) return v + " := JrTakeString(LV.l);";
        if (c.isArray()) {
            Class<?> e = c.getComponentType();
            if (e.isPrimitive()) return v + " := JrTake" + cap(e.getName()) + "Array(LV.l);";
            if (e == String.class) return v + " := JrTakeStringArray(LV.l);";
            return v + " := JrTakeObjectArray(LV.l);";
        }
        TInfo t = types.get(c);
        if (t == null) return v + " := JavaWrapLocal(LV.l);";
        return "if LV.l = nil then " + v + " := nil else " + v + " := " + implRef(t) + ".CreateFromLocal(LV.l);";
    }

    static String c2jni(Class<?> c) {
        return c.getName().replace('.', '/');
    }

    /** Pascal string literal; non-ASCII as UTF-8 byte escapes (JNI expects modified UTF-8). */
    static String pasStr(String s) {
        StringBuilder sb = new StringBuilder();
        boolean open = false;
        int run = 0;    // elements in the current literal: Delphi allows at most 255
        for (byte b : s.getBytes(StandardCharsets.UTF_8)) {
            int v = b & 0xff;
            if (run == 250) {
                if (open) { sb.append('\''); open = false; }
                sb.append(" + ");
                run = 0;
            }
            run++;
            if (v >= 32 && v < 127) {
                if (!open) { sb.append('\''); open = true; }
                sb.append(v == '\'' ? "''" : String.valueOf((char) v));
            } else {
                if (open) { sb.append('\''); open = false; }
                sb.append(String.format("#$%02X", v));
            }
        }
        if (open) sb.append('\'');
        return sb.isEmpty() ? "''" : sb.toString();
    }

    // ------------------------------------------------------------------ emission

    String paramList(Class<?>[] ps, String prefix) {
        if (ps.length == 0) return "";
        List<String> parts = new ArrayList<>();
        for (int i = 0; i < ps.length; i++)
            parts.add((isManaged(ps[i]) ? "const " : "") + prefix + i + ": " + pasType(ps[i], true));
        return "(" + String.join("; ", parts) + ")";
    }

    String heading(Member m, String name, String prefix, boolean isClassMethod) {
        String params = paramList(m.params, prefix);
        String head;
        if (m.ret == void.class) head = "procedure " + name + params;
        else head = "function " + name + params + ": " + pasType(m.ret, false);
        return (isClassMethod ? "class " : "") + head + ";";
    }

    String describe(Member m) {
        return switch (m.kind) {
            case METHOD -> (m.isStatic ? "static " : "") + m.javaName + m.jniSig;
            case CTOR -> "constructor " + m.jniSig;
            case GETTER -> (m.isStatic ? "static " : "") + "field " + m.javaName + " (read)";
            case SETTER -> (m.isStatic ? "static " : "") + "field " + m.javaName + " (write)";
        };
    }

    /** Single-unit mode: everything in one unit. */
    String emit() {
        StringBuilder sb = new StringBuilder();
        List<TInfo> order = topoOrder();
        emitHeader(sb, unitName, sortedTypes(), null);
        sb.append("interface\n\nuses\n  JavaBridge;\n\ntype\n");
        emitInterfaces(sb, order);
        emitRecords(sb, order);
        sb.append("implementation\n\ntype\n");
        emitImplClasses(sb, order);
        // generate bodies first (they may allocate additional class slots), then globals
        String bodies = emitBodies(order);
        emitSlotVars(sb);
        sb.append(bodies);
        sb.append("end.\n");
        return sb.toString();
    }

    /** Unit-per-package mode: the unit that declares every interface type. */
    String emitTypesUnit() {
        StringBuilder sb = new StringBuilder();
        emitHeader(sb, unitName, sortedTypes(), "Interface types. The companion records (TJ...) are in the "
                + "package units:\n" + units.stream().map(u -> "    " + u.name + ": "
                + String.join(", ", u.packages)).collect(Collectors.joining("\n")));
        sb.append("interface\n\nuses\n  JavaBridge;\n\ntype\n");
        emitInterfaces(sb, topoOrder());
        sb.append("implementation\n\nend.\n");
        return sb.toString();
    }

    /** Unit-per-package mode: companion records and implementation classes of one package unit. */
    String emitPackageUnit(PUnit u) {
        cur = u;
        try {
            String bodies = emitBodies(u.types);
            // interface section: the types unit, plus the units of parent implementation classes
            Set<PUnit> intfUses = new TreeSet<>(Comparator.comparing((PUnit x) -> x.name));
            for (TInfo t : u.types)
                if (t.parent != null && unitOf.get(t.parent) != u) intfUses.add(unitOf.get(t.parent));
            Set<PUnit> implUses = new TreeSet<>(Comparator.comparing((PUnit x) -> x.name));
            implUses.addAll(u.implUses);
            implUses.remove(u);
            implUses.removeAll(intfUses);

            StringBuilder sb = new StringBuilder();
            emitHeader(sb, u.name, u.types.stream().sorted(Comparator.comparing(t -> t.cls.getName())).toList(),
                    "Package unit for " + String.join(", ", u.packages) + "; the interface types are in "
                    + unitName + ".");
            sb.append("interface\n\nuses\n  JavaBridge, ").append(unitName);
            for (PUnit x : intfUses) sb.append(", ").append(x.name);
            sb.append(";\n\ntype\n");
            emitRecords(sb, u.types);
            sb.append("  { Implementation classes: internal, use the interfaces and records instead }\n");
            emitImplClasses(sb, u.types);
            sb.append("implementation\n\n");
            if (!implUses.isEmpty())
                sb.append("uses\n  ").append(implUses.stream().map(x -> x.name).collect(Collectors.joining(", ")))
                        .append(";\n\n");
            emitSlotVars(sb);
            sb.append(bodies);
            sb.append("end.\n");
            return sb.toString();
        } finally {
            cur = null;
        }
    }

    void emitHeader(StringBuilder sb, String unit, List<TInfo> listed, String note) {
        sb.append("{ Generated by pascal-java-bridge BindingGenerator - do not edit.\n");
        if (note != null) sb.append("  ").append(note).append('\n');
        sb.append("  Java types:\n");
        for (TInfo t : listed)
            sb.append("    ").append(t.cls.getName()).append(" -> ").append(t.intf).append(" / ")
                    .append(t.comp).append('\n');
        sb.append("}\nunit ").append(unit).append(";\n\n");
        sb.append("{$IFDEF FPC}\n  {$MODE DELPHI}\n  {$H+}\n{$ENDIF}\n\n");
    }

    void emitInterfaces(StringBuilder sb, List<TInfo> order) {
        for (TInfo t : order) sb.append("  ").append(t.intf).append(" = interface;\n");
        for (TInfo t : order)
            if (t.hasCallback()) sb.append("  ").append(t.cbIntf).append(" = interface;\n");
        sb.append('\n');

        // interfaces
        for (TInfo t : order) {
            String parent = t.parent == null ? "IJavaObject" : t.parent.intf;
            sb.append("  { ").append(t.cls.isInterface() ? "interface " : "class ").append(t.cls.getName())
                    .append(" }\n");
            sb.append("  ").append(t.intf).append(" = interface(").append(parent).append(")\n");
            sb.append("    ['{").append(t.guid).append("}']\n");
            for (Member m : t.newInst) {
                sb.append("    { ").append(describe(m)).append(" }\n");
                sb.append("    ").append(heading(m, esc(m.entry.pas), t.instParam, false))
                        .append(m.kind == MKind.METHOD ? " overload;" : "").append('\n');
            }
            sb.append("  end;\n\n");
        }
        // callback interfaces (implemented by Pascal classes)
        for (TInfo t : order) {
            if (!t.hasCallback()) continue;
            sb.append("  { Implement this in Pascal and pass it to ").append(t.comp)
                    .append(".Implement to get a Java ").append(t.cls.getName()).append(" }\n");
            sb.append("  ").append(t.cbIntf).append(" = interface(IInterface)\n");
            sb.append("    ['{").append(t.cbGuid).append("}']\n");
            for (Member m : t.cbMethods) {
                sb.append("    { ").append(describe(m)).append(" }\n");
                sb.append("    ").append(callbackHeading(m, esc(m.entry.pas), t.instParam)).append(" overload;\n");
            }
            sb.append("  end;\n\n");
        }
    }

    void emitRecords(StringBuilder sb, List<TInfo> order) {
        for (TInfo t : order) {
            String p = t.statParam;
            sb.append("  { ").append(t.cls.getName()).append(": constructors and static members }\n");
            sb.append("  ").append(t.comp).append(" = record\n  public\n");
            sb.append("    { Checked cast; raises EJavaCastError if the object is not a ")
                    .append(t.cls.getName()).append(" }\n");
            sb.append("    class function Cast(const ").append(p).append("0: IJavaObject): ").append(t.intf)
                    .append("; static;\n");
            sb.append("    class function IsInstance(const ").append(p).append("0: IJavaObject): Boolean; static;\n");
            if (t.hasCallback()) {
                sb.append("    { Wraps a Pascal implementation in a Java ").append(t.cls.getName())
                        .append(" (a java.lang.reflect.Proxy) }\n");
                sb.append("    class function Implement(const ").append(p).append("0: ").append(t.cbIntf)
                        .append("): ").append(t.intf).append("; static;\n");
            }
            for (Member m : t.statics) {
                sb.append("    { ").append(describe(m)).append(" }\n");
                String h = heading(m, esc(m.entry.pas), p, true);
                if (m.kind == MKind.CTOR) h = h.replace(": " + pasType(m.ret, false) + ";", ": " + t.intf + ";");
                // Delphi requires "overload" before "static" (FPC accepts both orders)
                sb.append("    ").append(h)
                        .append(m.kind == MKind.METHOD || m.kind == MKind.CTOR ? " overload;" : "")
                        .append(" static;\n");
            }
            sb.append("  end;\n\n");
        }
    }

    void emitImplClasses(StringBuilder sb, List<TInfo> order) {
        for (TInfo t : order) {
            String parentImpl = t.parent == null ? "TJavaObjectImpl" : t.parent.impl;
            sb.append("  ").append(t.impl).append(" = class(").append(parentImpl).append(", ").append(t.intf)
                    .append(")\n  public\n");
            Set<Entry> overloaded = overloadedEntries(t);
            for (Entry e : t.inst.byName.values()) {
                String clause = (e.isProcedure ? "procedure " : "function ") + t.intf + '.' + esc(e.pas)
                        + " = J_" + e.implIndex + ";";
                // Delphi: a resolution clause maps only one overload; see delphiForwarders
                sb.append("    ").append(overloaded.contains(e) ? "{$IFDEF FPC}" + clause + "{$ENDIF}" : clause)
                        .append('\n');
            }
            for (Member m : t.newInst)
                sb.append("    ").append(heading(m, "J_" + m.entry.implIndex, t.instParam, false))
                        .append(" overload;\n");
            List<Member> fwd = delphiForwarders(t);
            if (!fwd.isEmpty()) {
                sb.append("    {$IFNDEF FPC}\n");
                for (Member m : fwd)
                    sb.append("    ").append(heading(m, esc(m.entry.pas), t.instParam, false))
                            .append(" reintroduce; overload;\n");
                sb.append("    {$ENDIF}\n");
            }
            sb.append("  end;\n\n");
        }
    }

    /** Instance members of t, inherited ones included, grouped by their Pascal name. */
    Map<Entry, List<Member>> membersByEntry(TInfo t) {
        Map<Entry, List<Member>> r = new HashMap<>();
        for (Member m : t.allInst.values()) r.computeIfAbsent(m.entry, k -> new ArrayList<>()).add(m);
        return r;
    }

    /** Pascal names of t's interface that hold more than one overload. */
    Set<Entry> overloadedEntries(TInfo t) {
        Set<Entry> r = new HashSet<>();
        membersByEntry(t).forEach((e, ms) -> { if (ms.size() > 1) r.add(e); });
        return r;
    }

    /**
     * Delphi can't map overloaded interface methods with a method resolution clause (one clause
     * binds one overload, and a name can't have two clauses). Instead the impl class implements
     * them by name: a forwarder per overload that calls J_n. Forwarders an ancestor impl class
     * already declares are inherited, so only the new ones are returned. "reintroduce" because a
     * Java name may hide a TObject member (Free, ToString, ...). Entry names the generated code
     * itself calls on impl classes are never overloaded (see IMPL_MEMBERS).
     */
    List<Member> delphiForwarders(TInfo t) {
        Set<Member> inherited = new HashSet<>();
        if (t.parent != null) {
            membersByEntry(t.parent).forEach((e, ms) -> { if (ms.size() > 1) inherited.addAll(ms); });
        }
        List<Member> r = new ArrayList<>();
        membersByEntry(t).forEach((e, ms) -> {
            if (ms.size() > 1) for (Member m : ms) if (!inherited.contains(m)) r.add(m);
        });
        r.sort(Comparator.comparingInt((Member m) -> m.entry.implIndex).thenComparingInt(m -> m.idSlot));
        return r;
    }

    void emitDelphiForwarders(StringBuilder sb, TInfo t) {
        List<Member> fwd = delphiForwarders(t);
        if (fwd.isEmpty()) return;
        sb.append("{$IFNDEF FPC}\n");
        for (Member m : fwd) {
            sb.append(heading(m, t.impl + "." + esc(m.entry.pas), t.instParam, false)).append("\nbegin\n  ");
            if (m.ret != void.class) sb.append("Result := ");
            sb.append("J_").append(m.entry.implIndex);
            if (m.params.length > 0) {
                List<String> args = new ArrayList<>();
                for (int i = 0; i < m.params.length; i++) args.add(t.instParam + i);
                sb.append('(').append(String.join(", ", args)).append(')');
            }
            sb.append(";\nend;\n\n");
        }
        sb.append("{$ENDIF}\n\n");
    }

    String emitBodies(List<TInfo> order) {
        StringBuilder bodies = new StringBuilder();
        for (TInfo t : order) if (t.hasCallback()) emitDispatcher(bodies, t);
        for (TInfo t : order) {
            for (Member m : t.newInst) emitBody(bodies, t, m, false);
            emitDelphiForwarders(bodies, t);
            emitCastHelpers(bodies, t);
            for (Member m : t.statics) emitBody(bodies, t, m, true);
        }
        return bodies.toString();
    }

    void emitSlotVars(StringBuilder sb) {
        int nc = cur == null ? classSlots.size() : cur.classes.size();
        int nm = cur == null ? methodSlots : cur.methods.size();
        int nf = cur == null ? fieldSlots : cur.fields.size();
        if (nc + nm + nf == 0) return;
        sb.append("var\n");
        if (nc > 0) sb.append("  ").append(varClasses).append(": array[0..").append(nc - 1).append("] of jclass;\n");
        if (nm > 0) sb.append("  ").append(varMethods).append(": array[0..").append(nm - 1).append("] of jmethodID;\n");
        if (nf > 0) sb.append("  ").append(varFields).append(": array[0..").append(nf - 1).append("] of jfieldID;\n");
        sb.append('\n');
    }

    // slot numbers: global in single-unit mode, per unit in unit-per-package mode
    int cSlot(String jniName) {
        return cur == null ? classSlot(jniName) : cur.classes.computeIfAbsent(jniName, k -> cur.classes.size());
    }

    int mSlot(int global) {
        return cur == null ? global : cur.methods.computeIfAbsent(global, k -> cur.methods.size());
    }

    int fSlot(int global) {
        return cur == null ? global : cur.fields.computeIfAbsent(global, k -> cur.fields.size());
    }

    /** Name of t's implementation class, recording the unit that declares it. */
    String implRef(TInfo t) {
        if (cur != null) cur.implUses.add(unitOf.get(t));
        return t.impl;
    }

    void emitCastHelpers(StringBuilder sb, TInfo t) {
        String p = t.statParam + "0";
        String cls = "JrResolveClass(" + varClasses + "[" + cSlot(t.jniName()) + "], " + pasStr(t.jniName()) + ")";
        sb.append("class function ").append(t.comp).append(".Cast(const ").append(p).append(": IJavaObject): ")
                .append(t.intf).append(";\nvar\n  LH: jobject;\nbegin\n");
        sb.append("  LH := JrCheckCast(").append(p).append(", ").append(cls).append(", ")
                .append(pasStr(t.cls.getName())).append(");\n");
        sb.append("  if LH = nil then Result := nil else Result := ").append(t.impl)
                .append(".CreateFromGlobal(JrNewGlobalRef(LH));\nend;\n\n");
        sb.append("class function ").append(t.comp).append(".IsInstance(const ").append(p)
                .append(": IJavaObject): Boolean;\nbegin\n");
        sb.append("  Result := JrIsInstance(").append(p).append(", ").append(cls).append(");\nend;\n\n");
        if (t.hasCallback()) {
            String sigs = t.cbMethods.stream().map(m -> m.javaName + m.jniSig).collect(Collectors.joining("\n"));
            sb.append("class function ").append(t.comp).append(".Implement(const ").append(p).append(": ")
                    .append(t.cbIntf).append("): ").append(t.intf).append(";\nvar\n  LV: jvalue;\nbegin\n");
            sb.append("  LV.l := JrCreateProxy(").append(cls).append(", ").append(p).append(", ")
                    .append(t.dispatch).append(",\n    ").append(pasStr(sigs)).append(");\n");
            sb.append("  Result := ").append(t.impl).append(".CreateFromLocal(LV.l);\nend;\n\n");
        }
    }

    /** Heading of a callback method: Java hands us its arguments, Pascal returns a value. */
    String callbackHeading(Member m, String name, String prefix) {
        List<String> parts = new ArrayList<>();
        for (int i = 0; i < m.params.length; i++)
            parts.add((isManaged(m.params[i]) ? "const " : "") + prefix + i + ": " + pasType(m.params[i], false));
        String params = parts.isEmpty() ? "" : "(" + String.join("; ", parts) + ")";
        if (m.ret == void.class) return "procedure " + name + params + ";";
        return "function " + name + params + ": " + pasType(m.ret, true) + ";";
    }

    void emitDispatcher(StringBuilder sb, TInfo t) {
        sb.append("function ").append(t.dispatch)
                .append("(const ATarget: IInterface; AIndex: Integer; AArgs: jarray): jobject;\nvar\n");
        boolean needLV = t.cbMethods.stream().anyMatch(m -> m.params.length > 0
                || (m.ret.isPrimitive() && m.ret != void.class));
        sb.append("  LC: ").append(t.cbIntf).append(";\n");
        if (needLV) sb.append("  LV: jvalue;\n");
        for (int k = 0; k < t.cbMethods.size(); k++) {
            Member m = t.cbMethods.get(k);
            for (int i = 0; i < m.params.length; i++)
                sb.append("  LA").append(k).append('_').append(i).append(": ").append(pasType(m.params[i], false))
                        .append(";\n");
        }
        sb.append("begin\n  Result := nil;\n");
        if (needLV) sb.append("  LV.j := 0;\n");
        sb.append("  LC := ").append(t.cbIntf).append("(ATarget);\n  case AIndex of\n");
        for (int k = 0; k < t.cbMethods.size(); k++) {
            Member m = t.cbMethods.get(k);
            sb.append("    ").append(k).append(":\n      begin\n");
            List<String> args = new ArrayList<>();
            for (int i = 0; i < m.params.length; i++) {
                String v = "LA" + k + "_" + i;
                args.add(v);
                sb.append("        LV := JrArgValue(AArgs, ").append(i).append(", ").append(kind(m.params[i]))
                        .append(");\n");
                sb.append("        ").append(javaToVar(m.params[i], v)).append('\n');
            }
            String call = "LC." + esc(m.entry.pas) + (args.isEmpty() ? "" : "(" + String.join(", ", args) + ")");
            Class<?> r = m.ret;
            if (r == void.class) {
                sb.append("        ").append(call).append(";\n");
            } else if (r.isPrimitive()) {
                sb.append("        LV.").append(jvalueField(r)).append(" := ").append(argToJava(r, call)).append(";\n");
                sb.append("        Result := JrBox(LV, ").append(kind(r)).append(");\n");
            } else {
                String conv = argToJava(r, call);
                if (conv.startsWith("JrHandle(")) conv = "JrNewLocalRef(" + conv + ")";
                sb.append("        Result := ").append(conv).append(";\n");
            }
            sb.append("      end;\n");
        }
        sb.append("  end;\nend;\n\n");
    }

    void emitBody(StringBuilder sb, TInfo t, Member m, boolean inRecord) {
        String prefix = inRecord ? t.statParam : t.instParam;
        String owner = inRecord ? t.comp : t.impl;
        String name = inRecord ? esc(m.entry.pas) : "J_" + m.entry.implIndex;
        String head = heading(m, owner + "." + name, prefix, inRecord);
        if (m.kind == MKind.CTOR) head = head.replace(": " + pasType(m.ret, false) + ";", ": " + t.intf + ";");
        sb.append(head).append('\n');

        int cs = cSlot(t.jniName());
        String clsExpr = "JrResolveClass(" + varClasses + "[" + cs + "], " + pasStr(t.jniName()) + ")";
        String target = m.isStatic || m.kind == MKind.CTOR ? clsExpr : "JavaGlobalRef";
        int n = m.params.length;
        boolean anyLocal = Arrays.stream(m.params).anyMatch(BindingGenerator::argIsLocalRef);
        boolean needLV = m.kind == MKind.CTOR || m.kind == MKind.SETTER || m.ret != void.class;

        List<String> vars = new ArrayList<>();
        if (n > 0 && m.kind != MKind.SETTER) vars.add("LA: array[0.." + (n - 1) + "] of jvalue;");
        if (needLV) vars.add("LV: jvalue;");
        if (!vars.isEmpty()) {
            sb.append("var\n");
            for (String v : vars) sb.append("  ").append(v).append('\n');
        }
        sb.append("begin\n");

        switch (m.kind) {
            case GETTER, SETTER -> {
                String fid = "JrResolveField(" + varFields + "[" + fSlot(m.idSlot) + "], " + varClasses + "["
                        + cs + "], " + pasStr(t.jniName()) + ", " + pasStr(m.javaName) + ", "
                        + pasStr(m.jniSig) + ", " + (m.isStatic ? "True" : "False") + ")";
                String args = target + ", " + fid + ", " + kind(m.fieldType) + ", "
                        + (m.isStatic ? "True" : "False");
                if (m.kind == MKind.GETTER) {
                    sb.append("  LV := JrGetField(").append(args).append(");\n");
                    sb.append("  ").append(javaToResult(m.fieldType)).append('\n');
                } else {
                    String v = prefix + "0";
                    sb.append("  LV.j := 0;\n");
                    sb.append("  LV.").append(jvalueField(m.fieldType)).append(" := ")
                            .append(argToJava(m.fieldType, v)).append(";\n");
                    if (argIsLocalRef(m.fieldType)) {
                        sb.append("  try\n    JrSetField(").append(args).append(", LV);\n");
                        sb.append("  finally\n    JrDeleteLocal(LV.l);\n  end;\n");
                    } else {
                        sb.append("  JrSetField(").append(args).append(", LV);\n");
                    }
                }
            }
            case METHOD, CTOR -> {
                String ind = anyLocal ? "    " : "  ";
                if (anyLocal) sb.append("  FillChar(LA, SizeOf(LA), 0);\n  try\n");
                for (int i = 0; i < n; i++)
                    sb.append(ind).append("LA[").append(i).append("].").append(jvalueField(m.params[i]))
                            .append(" := ").append(argToJava(m.params[i], prefix + i)).append(";\n");
                String mid = "JrResolveMethod(" + varMethods + "[" + mSlot(m.idSlot) + "], " + varClasses + "["
                        + cs + "], " + pasStr(t.jniName()) + ", " + pasStr(m.javaName) + ", "
                        + pasStr(m.jniSig) + ", "
                        + (m.isStatic && m.kind != MKind.CTOR ? "True" : "False") + ")";
                String argPtr = n > 0 ? "@LA[0]" : "nil";
                if (m.kind == MKind.CTOR) {
                    sb.append(ind).append("LV.l := JrNewObject(").append(clsExpr).append(", ").append(mid)
                            .append(", ").append(argPtr).append(");\n");
                } else {
                    sb.append(ind).append(m.ret == void.class ? "" : "LV := ").append("JrCall(").append(target)
                            .append(", ").append(mid).append(", ").append(argPtr).append(", ")
                            .append(kind(m.ret)).append(", ").append(m.isStatic ? "True" : "False").append(");\n");
                }
                if (anyLocal) {
                    sb.append("  finally\n");
                    for (int i = 0; i < n; i++)
                        if (argIsLocalRef(m.params[i]))
                            sb.append("    JrDeleteLocal(LA[").append(i).append("].l);\n");
                    sb.append("  end;\n");
                }
                if (m.kind == MKind.CTOR)
                    sb.append("  Result := ").append(t.impl).append(".CreateFromLocal(LV.l);\n");
                else if (m.ret != void.class)
                    sb.append("  ").append(javaToResult(m.ret)).append('\n');
            }
        }
        sb.append("end;\n\n");
    }
}
