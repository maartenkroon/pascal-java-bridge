package pascaljavabridge;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

import pascaljavabridge.BindingGenerator.MKind;
import pascaljavabridge.BindingGenerator.Member;
import pascaljavabridge.BindingGenerator.Scope;
import pascaljavabridge.BindingGenerator.TInfo;

/**
 * Writes {@code <unit>Com.pas} (option {@code --com}, Delphi only): early-bound COM Automation
 * wrappers over the generated Pascal wrappers.
 *
 * <ul>
 * <li>per Java type a dual interface {@code IJFooDisp} (instance members, same parent chain as
 * {@code IJFoo}) and {@code IJFooClass} (constructors New, New_1, ..., statics, Cast, IsInstance,
 * Implement), implemented by {@code TJFooAuto} / {@code TJFooClassAuto}, which delegate to
 * {@code IJFoo} / {@code TJFoo};</li>
 * <li>per callback type (as {@code IJFooCallback}) a dual interface {@code IJFooCallbackDisp} with
 * the abstract methods, for clients to implement: {@code Implement} calls such an object through
 * its vtable (a generated {@code ComDispatch_Foo}), any other object by name;</li>
 * <li>an entry interface and coclass ({@code I<unit>Entry}, ProgID {@code PascalJavaBridge.<unit>})
 * with Start, Running, JvmPath and one property per type returning its class object;</li>
 * <li>the type library description ({@code <unit>TypeLib} builds it in memory for IDispatch; a COM
 * server writes it as a .tlb at registration);</li>
 * <li>{@code <unit>ComServer.dpr}, the in-process COM server.</li>
 * </ul>
 *
 * <p>With unit-per-package output there is still one COM unit and one type library for all
 * types: the COM unit uses the types unit and every package unit (generated names are global, so
 * nothing clashes).
 *
 * <p>COM has no overloads, so every member gets a unique name ({@code over}, {@code over_1}, ...),
 * case-insensitively and per interface chain. The Delphi classes map interface methods to
 * {@code C_n} methods with resolution clauses (one per name, which Delphi accepts here because
 * the names are unique).
 */
final class ComGenerator {

    /** Names no COM member may take: IUnknown/IDispatch methods. */
    static final Set<String> RESERVED_MEMBERS = Set.of("queryinterface", "addref", "release", "_addref",
            "_release", "gettypeinfocount", "gettypeinfo", "getidsofnames", "invoke");

    /** JavaBridgeCom / JavaBridgeAuto exports and RTL names the generated COM unit uses. */
    static final Set<String> RESERVED = Set.of("javabridgecom", "javabridgeauto", "tjavadispatch",
            "javacomjvm", "javatovariant", "javafromvariant", "javacomreleasepending", "javacomimplement",
            "javacomenum", "tjavatypelibbuilder", "tjavainvokekind", "jimethod", "jiget", "jiput",
            "tjavatypelibfunc", "tjavaautoobject", "javacomobject", "javaregistertypelib",
            "javaunregistertypelib", "jrcomchar", "jrcomstart", "jrcomensurevm", "tjavacomcreatefunc",
            "tjavatypelibmaker", "javacomclassobject", "javacomregisterserver", "jrvartobooleanarray",
            "jrvartobytearray", "jrvartochararray", "jrvartoshortarray", "jrvartointarray",
            "jrvartolongarray", "jrvartofloatarray", "jrvartodoublearray", "jrvartostringarray",
            "jrvartoobjectarray", "jrbooleanarraytovar", "jrbytearraytovar", "jrchararraytovar",
            "jrshortarraytovar", "jrintarraytovar", "jrlongarraytovar", "jrfloatarraytovar",
            "jrdoublearraytovar", "jrstringarraytovar", "jrobjectarraytovar", "olevariant",
            "widestring", "wordbool", "idispatch", "iunknown", "itypelib", "tguid", "winapi", "activex",
            "syncobjs", "tcriticalsection", "lr", "lb", "lt", "lc", "lv", "javacomimplementtyped",
            "javacomtypedtarget", "tjavadispatchfunc", "jvalue", "jarray", "jobject", "jclass", "atarget", "aindex",
            "aargs");

    enum Kind { METHOD, GET, PUT }

    /** A COM type: Delphi spelling, type library spelling, Java type. */
    record CType(String pas, String tlb, Class<?> java, TInfo wrapped) {
        boolean managed() { return pas.equals("WideString") || pas.equals("OleVariant") || wrapped != null
                || pas.equals("IDispatch") || pas.equals("IUnknown"); }
    }

    /** One vtable entry of a dual interface. */
    final class Func {
        String comName;        // name in the type library / for clients
        String pasName;        // Delphi interface method name (Get_x / Set_x for properties)
        String cName;          // implementing class method
        int dispId;
        Kind kind;
        List<CType> params = new ArrayList<>();
        CType ret;             // null for none
        Member member;         // the Java member (null for specials)
        String special;        // body of a special function, or null
        String vars;           // extra local variables of a special function, or null
        String property;       // property name for GET/PUT pairs (Delphi property declaration)
    }

    /** Member names (lower case) and next DISPID of an interface chain. */
    static final class Table {
        final Set<String> names = new HashSet<>();
        int nextDispId = 1;
        Table copy() {
            Table t = new Table();
            t.names.addAll(names);
            t.nextDispId = nextDispId;
            return t;
        }
        boolean free(String n) {
            return !names.contains(n.toLowerCase(Locale.ROOT)) && !RESERVED_MEMBERS.contains(n.toLowerCase(Locale.ROOT));
        }
        String claim(String base) {
            String n = base;
            for (int i = 1; !free(n); i++) n = base + "_" + i;
            names.add(n.toLowerCase(Locale.ROOT));
            return n;
        }
        /** A property name whose Get_/Set_ accessors are free too. */
        String claimProperty(String base) {
            String n = base;
            for (int i = 1; !free(n) || !free("Get_" + n) || !free("Set_" + n); i++) n = base + "_" + i;
            names.add(n.toLowerCase(Locale.ROOT));
            names.add(("Get_" + n).toLowerCase(Locale.ROOT));
            names.add(("Set_" + n).toLowerCase(Locale.ROOT));
            return n;
        }
    }

    final BindingGenerator g;
    final Scope scope;
    final String unit, comUnit;
    final Map<TInfo, String> disp = new HashMap<>(), clsIntf = new HashMap<>(), auto = new HashMap<>(),
            clsAuto = new HashMap<>();
    final Map<TInfo, List<Func>> inst = new LinkedHashMap<>(), stat = new LinkedHashMap<>();
    final Map<TInfo, Table> tables = new HashMap<>();
    /** Typed callbacks, per callback type: the dual interface IJFooCallbackDisp a client implements
     *  (its funcs in vtable order, and in dispatch order = cbMethods order) and the dispatch
     *  function. */
    final Map<TInfo, String> cbDisp = new HashMap<>(), typedDispatch = new HashMap<>();
    final Map<TInfo, List<Func>> cbFuncs = new LinkedHashMap<>(), cbDispatchOrder = new HashMap<>();
    final List<Func> entry = new ArrayList<>();
    final Map<Func, TInfo> entryType = new HashMap<>();
    String entryIntf, entryClass, typeLibFn, describeFn, makerFn, entryFn, libVar, lockVar, coName, progId;
    int cCounter = 0;

    ComGenerator(BindingGenerator g) {
        this.g = g;
        this.unit = g.unitName;
        this.comUnit = unit + "Com";
        this.scope = new Scope(g.global);
    }

    // ------------------------------------------------------------------ names

    void assignNames() {
        for (String r : RESERVED) scope.used.add(r);
        for (String part : comUnit.split("\\.")) scope.claim(part);
        List<TInfo> order = g.topoOrder();
        for (TInfo t : g.sortedTypes()) {
            disp.put(t, scope.claim("IJ" + t.base + "Disp"));
            clsIntf.put(t, scope.claim("IJ" + t.base + "Class"));
        }
        for (TInfo t : g.sortedTypes()) {
            auto.put(t, scope.claim("TJ" + t.base + "Auto"));
            clsAuto.put(t, scope.claim("TJ" + t.base + "ClassAuto"));
        }
        String u = unit.replace(".", "_");
        entryIntf = scope.claim("I" + u + "Entry");
        entryClass = scope.claim("T" + u + "Entry");
        typeLibFn = scope.claim(u + "TypeLib");
        describeFn = scope.claim(u + "DescribeTypeLib");
        makerFn = scope.claim(u + "NewTypeLibBuilder");
        entryFn = scope.claim(u + "ComEntry");
        libVar = scope.claim("G" + u + "TypeLib");
        lockVar = scope.claim("G" + u + "TypeLibLock");
        coName = u;
        progId = "PascalJavaBridge." + unit;
        for (TInfo t : g.sortedTypes())
            if (t.hasCallback()) {
                cbDisp.put(t, scope.claim("IJ" + t.base + "CallbackDisp"));
                typedDispatch.put(t, scope.claim("ComDispatch_" + t.base));
            }
        classesVar = scope.claim("G" + u + "ComClasses");

        for (TInfo t : order) {
            Table tab = t.parent == null ? new Table() : tables.get(t.parent).copy();
            tables.put(t, tab);
            List<Func> fs = new ArrayList<>();
            Map<String, Func> getters = new HashMap<>();
            for (Member m : comOrder(t.newInst)) {
                switch (m.kind) {
                    case METHOD -> {
                        Func f = func(m.javaName.equals("toString") && m.params.length == 0 && t.parent == null
                                ? tab.claim("toString") : tab.claim(BindingGenerator.mangle(m.javaName)), Kind.METHOD);
                        // Object.toString is the default member: MsgBox obj, CStr(obj)
                        f.dispId = f.comName.equals("toString") && t.parent == null ? 0 : tab.nextDispId++;
                        f.member = m;
                        for (Class<?> p : m.params) f.params.add(ctype(p));
                        f.ret = m.ret == void.class ? null : ctype(m.ret);
                        fs.add(f);
                    }
                    case GETTER -> {
                        String prop = tab.claimProperty(BindingGenerator.mangle(m.javaName));
                        Func f = func(prop, Kind.GET);
                        f.dispId = tab.nextDispId++;
                        f.member = m;
                        f.ret = ctype(m.ret);
                        fs.add(f);
                        getters.put(m.javaName, f);
                    }
                    case SETTER -> {
                        Func gf = getters.get(m.javaName);
                        Func f = func(gf.comName, Kind.PUT);
                        f.dispId = gf.dispId;
                        f.member = m;
                        f.params.add(ctype(m.params[0]));
                        fs.add(f);
                    }
                    default -> throw new IllegalStateException();
                }
            }
            // For Each over Iterables (and Maps), unless an ancestor already has it
            if (isEnumerable(t.cls) && (t.parent == null || !isEnumerable(t.parent.cls)) && tab.free("_NewEnum")) {
                Func f = func(tab.claimProperty("_NewEnum"), Kind.GET);
                f.dispId = -4;   // DISPID_NEWENUM
                f.ret = new CType("IUnknown", "UNKNOWN", null, null);
                f.special = "  Result := JavaComEnum(FJava);\n";
                fs.add(f);
            }
            inst.put(t, fs);
            if (cbDisp.containsKey(t)) callbackFuncs(t);
            stat.put(t, classFuncs(t));
        }
        // entry object
        Table et = new Table();
        Func start = func(et.claim("Start"), Kind.METHOD);
        start.params.add(new CType("WideString", "BSTR", String.class, null));
        start.params.add(new CType("OleVariant", "VARIANT", Object.class, null));
        start.ret = new CType("WordBool", "BOOL", boolean.class, null);
        start.special = "  Result := JrComStart(FJvmPath, p0, p1);\n";
        Func running = func(et.claimProperty("Running"), Kind.GET);
        running.ret = new CType("WordBool", "BOOL", boolean.class, null);
        running.special = "  Result := JavaVMRunning;\n";
        String jp = et.claimProperty("JvmPath");
        Func jpGet = func(jp, Kind.GET);
        jpGet.ret = new CType("WideString", "BSTR", String.class, null);
        jpGet.special = "  Result := FJvmPath;\n";
        Func jpPut = func(jp, Kind.PUT);
        jpPut.params.add(new CType("WideString", "BSTR", String.class, null));
        jpPut.special = "  FJvmPath := p0;\n";
        entry.addAll(List.of(start, running, jpGet, jpPut));
        for (Func f : entry) f.dispId = et.nextDispId++;
        jpPut.dispId = jpGet.dispId;
        et.nextDispId--;
        for (TInfo t : g.sortedTypes()) {
            Func f = func(et.claimProperty(t.base), Kind.GET);
            f.dispId = et.nextDispId++;
            f.ret = new CType(clsIntf.get(t), clsIntf.get(t), null, null);
            f.special = "  JrComEnsureVM(FJvmPath);\n  Result := " + clsAuto.get(t) + ".Create(nil, "
                    + clsIntf.get(t) + ", " + typeLibFn + ");\n";
            entry.add(f);
            entryType.put(f, t);
        }
    }

    /**
     * Members in COM naming order: methods and constructors by name, then by parameter count (so
     * the simplest overload gets the plain name: List.add(E) is add, add(int, E) add_1), then
     * fields in their order (a setter right after its getter).
     */
    static List<Member> comOrder(List<Member> ms) {
        List<Member> calls = new ArrayList<>(), fields = new ArrayList<>();
        for (Member m : ms) (m.kind == MKind.METHOD || m.kind == MKind.CTOR ? calls : fields).add(m);
        calls.sort(java.util.Comparator.comparing((Member m) -> m.javaName)
                .thenComparingInt(m -> m.params.length).thenComparing(ComGenerator::rankKey)
                .thenComparing(m -> m.jniSig));
        calls.addAll(fields);
        return calls;
    }

    /** Overloads with the same parameter count: the usual types first (String before char). */
    static String rankKey(Member m) {
        StringBuilder sb = new StringBuilder();
        for (Class<?> p : m.params) sb.append((char) ('a' + rank(p)));
        return sb.toString();
    }

    static int rank(Class<?> c) {
        if (c == String.class) return 0;
        if (c == int.class) return 1;
        if (c == long.class) return 2;
        if (c == double.class) return 3;
        if (c == boolean.class) return 4;
        if (!c.isPrimitive() && !c.isArray()) return c == Object.class ? 6 : 5;
        if (c == float.class) return 7;
        if (c == char.class) return 8;
        if (c == short.class) return 9;
        if (c == byte.class) return 10;
        return 11;   // arrays
    }

    static boolean isEnumerable(Class<?> c) {
        return Iterable.class.isAssignableFrom(c) || Map.class.isAssignableFrom(c)
                || java.util.Iterator.class.isAssignableFrom(c) || java.util.Enumeration.class.isAssignableFrom(c);
    }

    Func func(String name, Kind kind) {
        Func f = new Func();
        f.comName = name;
        f.kind = kind;
        f.pasName = switch (kind) {
            case METHOD -> name;
            case GET -> "Get_" + name;
            case PUT -> "Set_" + name;
        };
        if (kind != Kind.METHOD) f.property = name;
        f.cName = "C_" + (++cCounter);
        return f;
    }

    List<Func> classFuncs(TInfo t) {
        Table tab = new Table();
        List<Func> fs = new ArrayList<>();
        String rec = t.comp;
        // constructors first, so they get New, New_1, ...
        for (Member m : comOrder(t.statics)) {
            if (m.kind != MKind.CTOR) continue;
            Func f = func(tab.claim("New"), Kind.METHOD);
            f.dispId = tab.nextDispId++;
            f.member = m;
            for (Class<?> p : m.params) f.params.add(ctype(p));
            f.ret = ctype(t.cls);
            fs.add(f);
        }
        Func cast = func(tab.claim("Cast"), Kind.METHOD);
        cast.dispId = tab.nextDispId++;
        cast.params.add(new CType("OleVariant", "VARIANT", Object.class, null));
        cast.ret = ctype(t.cls);
        cast.special = resultOut(t.cls, rec + ".Cast(JavaFromVariant(p0))");
        fs.add(cast);
        Func isInst = func(tab.claim("IsInstance"), Kind.METHOD);
        isInst.dispId = tab.nextDispId++;
        isInst.params.add(new CType("OleVariant", "VARIANT", Object.class, null));
        isInst.ret = new CType("WordBool", "BOOL", boolean.class, null);
        isInst.special = "  Result := " + rec + ".IsInstance(JavaFromVariant(p0));\n";
        fs.add(isInst);
        if (t.hasCallback()) {
            Func impl = func(tab.claim("Implement"), Kind.METHOD);
            impl.dispId = tab.nextDispId++;
            impl.params.add(new CType("IDispatch", "DISPATCH", null, null));
            impl.ret = ctype(t.cls);
            String name = BindingGenerator.pasStr(t.cls.getName());
            String late = rec + ".Cast(JavaComImplement(" + name + ", p0))";
            if (!cbDisp.containsKey(t)) {
                impl.special = resultOut(t.cls, late);
            } else {
                // the client implements IJFooCallbackDisp: call it through the vtable, else by name
                String sigs = t.cbMethods.stream().map(m -> m.javaName + m.jniSig)
                        .collect(java.util.stream.Collectors.joining("\n"));
                impl.vars = "  LT: " + cbDisp.get(t) + ";\n";
                impl.special = "  if System.SysUtils.Supports(p0, " + cbDisp.get(t) + ", LT) then\n    LR := " + rec
                        + ".Cast(JavaComImplementTyped(" + name + ", LT, " + typedDispatch.get(t) + ",\n      "
                        + BindingGenerator.pasStr(sigs) + "))\n  else\n    LR := " + late + ";\n"
                        + wrapResult(t, "LR");
            }
            fs.add(impl);
        }
        Map<String, Func> getters = new HashMap<>();
        for (Member m : comOrder(t.statics)) {
            switch (m.kind) {
                case CTOR -> { }
                case METHOD -> {
                    Func f = func(tab.claim(BindingGenerator.mangle(m.javaName)), Kind.METHOD);
                    f.dispId = tab.nextDispId++;
                    f.member = m;
                    for (Class<?> p : m.params) f.params.add(ctype(p));
                    f.ret = m.ret == void.class ? null : ctype(m.ret);
                    fs.add(f);
                }
                case GETTER -> {
                    Func f = func(tab.claimProperty(BindingGenerator.mangle(m.javaName)), Kind.GET);
                    f.dispId = tab.nextDispId++;
                    f.member = m;
                    f.ret = ctype(m.ret);
                    fs.add(f);
                    getters.put(m.javaName, f);
                }
                case SETTER -> {
                    Func gf = getters.get(m.javaName);
                    Func f = func(gf.comName, Kind.PUT);
                    f.dispId = gf.dispId;
                    f.member = m;
                    f.params.add(ctype(m.params[0]));
                    fs.add(f);
                }
            }
        }
        return fs;
    }

    /** Class slots of this unit (JNI name -> index): element classes of object arrays returned by
     *  typed callbacks. */
    final Map<String, Integer> classSlots = new LinkedHashMap<>();
    String classesVar;

    /** The members of IJFooCallbackDisp: t's abstract methods, named in COM order. */
    void callbackFuncs(TInfo t) {
        for (Member m : t.cbMethods)
            if (m.ret.isArray() && !m.ret.getComponentType().isPrimitive() && m.ret.getComponentType() != String.class)
                classSlots.computeIfAbsent(BindingGenerator.c2jni(m.ret.getComponentType()), k -> classSlots.size());
        Table tab = new Table();
        Map<Member, Func> byMember = new HashMap<>();
        List<Func> fs = new ArrayList<>();
        for (Member m : comOrder(t.cbMethods)) {
            Func f = func(tab.claim(BindingGenerator.mangle(m.javaName)), Kind.METHOD);
            f.dispId = tab.nextDispId++;
            f.member = m;
            for (Class<?> p : m.params) f.params.add(ctype(p));
            f.ret = m.ret == void.class ? null : ctype(m.ret);
            fs.add(f);
            byMember.put(m, f);
        }
        cbFuncs.put(t, fs);
        List<Func> order = new ArrayList<>();
        for (Member m : t.cbMethods) order.add(byMember.get(m));
        cbDispatchOrder.put(t, order);
    }

    /** Pascal value of Java argument LV (from JrArgValue) of type c. */
    String pasFromJava(Class<?> c) {
        if (c.isPrimitive()) return switch (c.getName()) {
            case "boolean" -> "(LV.z <> 0)";
            case "char" -> "WideChar(LV.c)";
            default -> "LV." + BindingGenerator.jvalueField(c);
        };
        if (c == String.class) return "JrTakeString(LV.l)";
        if (c.isArray()) {
            Class<?> e = c.getComponentType();
            if (e.isPrimitive()) return "JrTake" + BindingGenerator.cap(e.getName()) + "Array(LV.l)";
            if (e == String.class) return "JrTakeStringArray(LV.l)";
            return "JrTakeObjectArray(LV.l)";
        }
        TInfo t = g.types.get(c);
        if (t != null && c != Object.class) return t.comp + ".Cast(JavaWrapLocal(LV.l))";
        return "JavaWrapLocal(LV.l)";
    }

    /** The dispatch function of a typed callback: Java arguments to COM, the client's vtable, back. */
    void emitTypedDispatch(StringBuilder sb, TInfo t) {
        List<Func> fs = cbDispatchOrder.get(t);
        sb.append("function ").append(typedDispatch.get(t))
          .append("(const ATarget: IInterface; AIndex: Integer; AArgs: jarray): jobject;\nvar\n  LC: ")
          .append(cbDisp.get(t)).append(";\n  LV: jvalue;\n");
        for (int k = 0; k < fs.size(); k++) {
            Func f = fs.get(k);
            for (int i = 0; i < f.params.size(); i++) {
                CType p = f.params.get(i);
                sb.append("  LB").append(k).append('_').append(i).append(": ").append(p.pas()).append(";\n");
                if (p.wrapped() != null)
                    sb.append("  LO").append(k).append('_').append(i).append(": ").append(p.wrapped().intf)
                      .append(";\n");
            }
            if (f.ret != null) sb.append("  LR").append(k).append(": ").append(f.ret.pas()).append(";\n");
        }
        sb.append("begin\n  Result := nil;\n  LV.j := 0;\n  LC := ").append(cbDisp.get(t))
          .append("(JavaComTypedTarget(ATarget, ").append(BindingGenerator.pasStr(t.cls.getName()))
          .append("));\n  case AIndex of\n");
        for (int k = 0; k < fs.size(); k++) {
            Func f = fs.get(k);
            Member m = f.member;
            sb.append("    ").append(k).append(":\n      begin\n");
            List<String> args = new ArrayList<>();
            for (int i = 0; i < m.params.length; i++) {
                String b = "LB" + k + "_" + i;
                args.add(b);
                sb.append("        LV := JrArgValue(AArgs, ").append(i).append(", ")
                  .append(BindingGenerator.kind(m.params[i])).append(");\n");
                sb.append(assignOut(m.params[i], pasFromJava(m.params[i]), b, "LO" + k + "_" + i)
                        .replace("\n  ", "\n        ").replaceFirst("^  ", "        "));
            }
            String call = "LC." + BindingGenerator.esc(f.pasName) + (args.isEmpty() ? "" : "(" + String.join(", ", args) + ")");
            Class<?> r = m.ret;
            if (r == void.class) {
                sb.append("        ").append(call).append(";\n");
            } else {
                String lr = "LR" + k;
                sb.append("        ").append(lr).append(" := ").append(call).append(";\n");
                String conv;
                if (r.isArray() && !r.getComponentType().isPrimitive() && r.getComponentType() != String.class) {
                    // the element class from this unit's slots (g.argToJava would use the Pascal unit's)
                    String jn = BindingGenerator.c2jni(r.getComponentType());
                    conv = "JrNewObjectArray(" + argIn(r, lr) + ", JrResolveClass(" + classesVar + "["
                            + classSlots.get(jn) + "], " + BindingGenerator.pasStr(jn) + "))";
                } else {
                    conv = g.argToJava(r, argIn(r, lr));
                }
                if (r.isPrimitive()) {
                    sb.append("        LV.").append(BindingGenerator.jvalueField(r)).append(" := ").append(conv)
                      .append(";\n        Result := JrBox(LV, ").append(BindingGenerator.kind(r)).append(");\n");
                } else {
                    if (conv.startsWith("JrHandle(")) conv = "JrNewLocalRef(" + conv + ")";
                    sb.append("        Result := ").append(conv).append(";\n");
                }
            }
            sb.append("      end;\n");
        }
        sb.append("  end;\nend;\n\n");
    }

    // ------------------------------------------------------------------ types

    CType ctype(Class<?> c) {
        if (c.isPrimitive()) return switch (c.getName()) {
            case "boolean" -> new CType("WordBool", "BOOL", c, null);
            case "byte", "short" -> new CType("SmallInt", "I2", c, null);
            case "char" -> new CType("WideString", "BSTR", c, null);
            case "int" -> new CType("Integer", "I4", c, null);
            case "long" -> new CType("Int64", "I8", c, null);
            case "float" -> new CType("Single", "R4", c, null);
            case "double" -> new CType("Double", "R8", c, null);
            default -> throw new IllegalStateException(c.getName());
        };
        if (c == String.class) return new CType("WideString", "BSTR", c, null);
        TInfo t = g.types.get(c);
        if (t != null && c != Object.class) return new CType(disp.get(t), disp.get(t), c, t);
        return new CType("OleVariant", "VARIANT", c, null);   // arrays, Object, unwrapped types
    }

    /** Expression converting COM parameter v (of Java type c) for the Pascal wrapper. */
    String argIn(Class<?> c, String v) {
        if (c.isPrimitive()) return switch (c.getName()) {
            case "boolean" -> "(" + v + " <> False)";
            case "byte" -> "ShortInt(" + v + ")";
            case "char" -> "JrComChar(" + v + ")";
            case "short" -> "SmallInt(" + v + ")";
            default -> v;
        };
        if (c == String.class) return "UnicodeString(" + v + ")";
        if (c.isArray()) {
            Class<?> e = c.getComponentType();
            if (e.isPrimitive()) return "JrVarTo" + BindingGenerator.cap(e.getName()) + "Array(" + v + ")";
            if (e == String.class) return "JrVarToStringArray(" + v + ")";
            return "JrVarToObjectArray(" + v + ")";
        }
        TInfo t = g.types.get(c);
        if (t != null && c != Object.class) return t.comp + ".Cast(JavaComObject(" + v + "))";
        return "JavaFromVariant(" + v + ")";
    }

    /** Statements assigning Pascal value expression e (of Java type c) to Result. */
    String resultOut(Class<?> c, String e) {
        return assignOut(c, e, "Result", "LR");
    }

    /** Statements assigning Pascal value expression e (of Java type c) to COM variable target;
     *  tmp is a variable of the Pascal interface type, for wrapped types. */
    String assignOut(Class<?> c, String e, String target, String tmp) {
        String a = "  " + target + " := ";
        if (c.isPrimitive()) return switch (c.getName()) {
            case "char" -> a + "WideString(" + e + ");\n";
            default -> a + e + ";\n";
        };
        if (c == String.class) return a + e + ";\n";
        if (c.isArray()) {
            Class<?> el = c.getComponentType();
            if (el.isPrimitive()) return a + "Jr" + BindingGenerator.cap(el.getName()) + "ArrayToVar(" + e + ");\n";
            if (el == String.class) return a + "JrStringArrayToVar(" + e + ");\n";
            return a + "JrObjectArrayToVar(" + e + ");\n";
        }
        TInfo t = g.types.get(c);
        if (t != null && c != Object.class) return "  " + tmp + " := " + e + ";\n" + wrapInto(t, tmp, target);
        return a + "JavaToVariant(" + e + ");\n";
    }

    String wrapResult(TInfo t, String v) {
        return wrapInto(t, v, "Result");
    }

    String wrapInto(TInfo t, String v, String target) {
        return "  if " + v + " = nil then " + target + " := nil else " + target + " := " + auto.get(t) + ".Create("
                + v + ", " + disp.get(t) + ", " + typeLibFn + ");\n";
    }

    // ------------------------------------------------------------------ emission

    String heading(Func f, String name, String owner) {
        List<String> ps = new ArrayList<>();
        for (int i = 0; i < f.params.size(); i++) {
            CType p = f.params.get(i);
            ps.add((p.managed() ? "const " : "") + "p" + i + ": " + p.pas());
        }
        String params = ps.isEmpty() ? "" : "(" + String.join("; ", ps) + ")";
        String n = (owner == null ? "" : owner + ".") + name;
        return (f.ret == null ? "procedure " + n + params : "function " + n + params + ": " + f.ret.pas())
                + "; safecall;";
    }

    void emitInterface(StringBuilder sb, String name, String parent, String guid, List<Func> fs, String doc) {
        sb.append("  { ").append(doc).append(" }\n");
        sb.append("  ").append(name).append(" = interface(").append(parent).append(")\n");
        sb.append("    ['{").append(guid).append("}']\n");
        for (Func f : fs) sb.append("    ").append(heading(f, BindingGenerator.esc(f.pasName), null)).append('\n');
        Set<String> props = new java.util.LinkedHashSet<>();
        for (Func f : fs) if (f.property != null) props.add(f.property);
        for (String p : props) {
            Func get = null, put = null;
            for (Func f : fs) if (p.equals(f.property)) { if (f.kind == Kind.GET) get = f; else put = f; }
            sb.append("    property ").append(BindingGenerator.esc(p)).append(": ").append(get.ret.pas())
                    .append(" read ").append(get.pasName);
            if (put != null) sb.append(" write ").append(put.pasName);
            sb.append(";\n");
        }
        sb.append("  end;\n\n");
    }

    /** All funcs of t's chain, ancestors first (the order of the vtable). */
    List<Func> chain(TInfo t) {
        List<Func> r = new ArrayList<>();
        if (t.parent != null) r.addAll(chain(t.parent));
        r.addAll(inst.get(t));
        return r;
    }

    void emitClass(StringBuilder sb, String name, String parent, String intf, List<Func> all, List<Func> own,
                   String extra) {
        sb.append("  ").append(name).append(" = class(").append(parent).append(", ").append(intf).append(")\n");
        if (extra != null) sb.append(extra);
        sb.append("  public\n");
        for (Func f : all)
            sb.append("    ").append(f.ret == null ? "procedure " : "function ").append(intf).append('.')
                    .append(BindingGenerator.esc(f.pasName)).append(" = ").append(f.cName).append(";\n");
        for (Func f : own) sb.append("    ").append(heading(f, f.cName, null)).append('\n');
        sb.append("  end;\n\n");
    }

    void emitBody(StringBuilder sb, String owner, Func f, TInfo t, boolean isStatic) {
        sb.append(heading(f, f.cName, owner)).append('\n');
        boolean needLR = (f.ret != null && f.ret.wrapped() != null);
        if (needLR || f.vars != null) sb.append("var\n");
        if (needLR) sb.append("  LR: ").append(f.ret.wrapped().intf).append(";\n");
        if (f.vars != null) sb.append(f.vars);
        sb.append("begin\n");
        if (f.special != null) {
            sb.append(f.special);
        } else {
            Member m = f.member;
            String target = isStatic ? t.comp : t.intf + "(FJava)";
            String name = BindingGenerator.esc(m.entry.pas);
            List<String> args = new ArrayList<>();
            for (int i = 0; i < m.params.length; i++) args.add(argIn(m.params[i], "p" + i));
            String call = target + "." + name + (args.isEmpty() ? "" : "(" + String.join(", ", args) + ")");
            if (f.ret == null) sb.append("  ").append(call).append(";\n");
            else sb.append(resultOut(m.kind == MKind.CTOR ? t.cls : m.ret, call));
        }
        sb.append("end;\n\n");
    }

    String emit() {
        assignNames();
        List<TInfo> order = g.topoOrder();
        StringBuilder sb = new StringBuilder();
        sb.append("{ Generated by pascal-java-bridge BindingGenerator (--com) - do not edit.\n")
          .append("  Early-bound COM Automation wrappers over unit ").append(unit).append(". Delphi only.\n")
          .append("  Entry: ProgID ").append(progId).append(" (").append(entryIntf).append("), or ")
          .append(entryFn).append(" in-process.\n  Java types:\n");
        for (TInfo t : g.sortedTypes())
            sb.append("    ").append(t.cls.getName()).append(" -> ").append(disp.get(t)).append(" / ")
                    .append(clsIntf.get(t)).append(cbDisp.containsKey(t) ? " / " + cbDisp.get(t) : "")
                    .append('\n');
        sb.append("}\nunit ").append(comUnit).append(";\n\ninterface\n\nuses\n")
          .append("  Winapi.ActiveX, System.SysUtils, System.SyncObjs, JavaBridge, JavaBridgeCom, JavaBridgeAuto,\n  ")
          .append(unit);
        // unit-per-package: the records (TJFoo) are in the package units
        for (BindingGenerator.PUnit u : g.units) sb.append(",\n  ").append(u.name);
        sb.append(";\n\nconst\n");
        sb.append("  LIBID_").append(coName).append(": TGUID = '{").append(libId()).append("}';\n");
        sb.append("  CLASS_").append(coName).append(": TGUID = '{").append(clsid()).append("}';\n");
        sb.append("  PROGID_").append(coName).append(" = '").append(progId).append("';\n\ntype\n");
        for (TInfo t : order) sb.append("  ").append(disp.get(t)).append(" = interface;\n");
        for (TInfo t : order) sb.append("  ").append(clsIntf.get(t)).append(" = interface;\n");
        sb.append('\n');
        for (TInfo t : order)
            emitInterface(sb, disp.get(t), t.parent == null ? "IDispatch" : disp.get(t.parent),
                    BindingGenerator.guid("pascal-java-bridge-com-iid:" + t.cls.getName()), inst.get(t),
                    t.cls.getName() + ": instance members");
        for (TInfo t : order)
            emitInterface(sb, clsIntf.get(t), "IDispatch",
                    BindingGenerator.guid("pascal-java-bridge-com-class-iid:" + t.cls.getName()), stat.get(t),
                    t.cls.getName() + ": constructors and static members");
        for (TInfo t : order)
            if (cbDisp.containsKey(t))
                emitInterface(sb, cbDisp.get(t), "IDispatch", callbackIid(t), cbFuncs.get(t),
                        t.cls.getName() + ": implement this in a COM client and pass it to "
                                + clsIntf.get(t) + ".Implement");
        emitInterface(sb, entryIntf, "IDispatch", BindingGenerator.guid("pascal-java-bridge-com-entry-iid:" + unit),
                entry, "entry object of " + unit);
        sb.append("{ The type library (built once, in memory). }\nfunction ").append(typeLibFn).append(": ITypeLib;\n");
        sb.append("{ A builder holding the type library description, e.g. to save it as a .tlb. }\nfunction ")
          .append(makerFn).append(": TJavaTypeLibBuilder;\n");
        sb.append("procedure ").append(describeFn).append("(B: TJavaTypeLibBuilder);\n");
        sb.append("{ A new entry object, without COM registration. }\nfunction ").append(entryFn).append(": ")
          .append(entryIntf).append(";\n\nimplementation\n\ntype\n");
        for (TInfo t : order) {
            List<Func> all = chain(t);
            emitClass(sb, auto.get(t), t.parent == null ? "TJavaAutoObject" : auto.get(t.parent), disp.get(t),
                    all, inst.get(t), null);
        }
        for (TInfo t : order)
            emitClass(sb, clsAuto.get(t), "TJavaAutoObject", clsIntf.get(t), stat.get(t), stat.get(t), null);
        emitClass(sb, entryClass, "TJavaAutoObject", entryIntf, entry, entry, "  private\n    FJvmPath: string;\n");
        sb.append("var\n  ").append(libVar).append(": ITypeLib;\n  ").append(lockVar)
          .append(": TCriticalSection;\n");
        if (!classSlots.isEmpty())
            sb.append("  ").append(classesVar).append(": array[0..").append(classSlots.size() - 1)
              .append("] of jclass;\n");
        sb.append('\n');
        // type library description
        sb.append("procedure ").append(describeFn).append("(B: TJavaTypeLibBuilder);\nbegin\n");
        for (TInfo t : order)
            describe(sb, disp.get(t), t.parent == null ? "" : disp.get(t.parent), t.cls.getName(), inst.get(t));
        for (TInfo t : order)
            describe(sb, clsIntf.get(t), "", t.cls.getName() + " (class)", stat.get(t));
        for (TInfo t : order)
            if (cbDisp.containsKey(t))
                describe(sb, cbDisp.get(t), "", t.cls.getName() + " (callback)", cbFuncs.get(t));
        describe(sb, entryIntf, "", "entry object of " + unit, entry);
        sb.append("  B.AddCoClass('").append(coName).append("', CLASS_").append(coName).append(", '")
          .append(entryIntf).append("', ").append(BindingGenerator.pasStr("Java classes of " + unit))
          .append(");\nend;\n\n");
        sb.append("function ").append(makerFn).append(": TJavaTypeLibBuilder;\nbegin\n  Result := TJavaTypeLibBuilder.Create('")
          .append(coName).append("', LIBID_").append(coName).append(", ")
          .append(BindingGenerator.pasStr("pascal-java-bridge: Java classes of " + unit)).append(");\n  ")
          .append(describeFn).append("(Result);\nend;\n\n");
        sb.append("function ").append(typeLibFn).append(": ITypeLib;\nvar\n  LB: TJavaTypeLibBuilder;\nbegin\n  if ")
          .append(libVar).append(" = nil then\n  begin\n    ").append(lockVar).append(".Acquire;\n    try\n      if ")
          .append(libVar).append(" = nil then\n      begin\n        LB := ").append(makerFn)
          .append(";\n        try\n          ").append(libVar).append(" := LB.BuildInMemory;\n        finally\n")
          .append("          LB.Free;\n        end;\n      end;\n    finally\n      ").append(lockVar)
          .append(".Release;\n    end;\n  end;\n  Result := ").append(libVar).append(";\nend;\n\n");
        sb.append("function ").append(entryFn).append(": ").append(entryIntf).append(";\nbegin\n  Result := ")
          .append(entryClass).append(".Create(nil, ").append(entryIntf).append(", ").append(typeLibFn)
          .append(");\nend;\n\n");
        // typed callbacks (before the Implement bodies that use them)
        for (TInfo t : order) if (typedDispatch.containsKey(t)) emitTypedDispatch(sb, t);
        // bodies
        for (TInfo t : order) for (Func f : inst.get(t)) emitBody(sb, auto.get(t), f, t, false);
        for (TInfo t : order) for (Func f : stat.get(t)) emitBody(sb, clsAuto.get(t), f, t, true);
        for (Func f : entry) emitBody(sb, entryClass, f, entryType.get(f), true);
        sb.append("initialization\n  ").append(lockVar).append(" := TCriticalSection.Create;\n\nfinalization\n  ")
          .append(libVar).append(" := nil;\n  FreeAndNil(").append(lockVar).append(");\n\nend.\n");
        return sb.toString();
    }

    void describe(StringBuilder sb, String name, String parent, String doc, List<Func> fs) {
        sb.append("  B.AddInterface('").append(name).append("', ").append(name).append(", '").append(parent)
          .append("', ").append(BindingGenerator.pasStr(doc)).append(");\n");
        for (Func f : fs) {
            List<String> types = new ArrayList<>(), names = new ArrayList<>();
            for (int i = 0; i < f.params.size(); i++) {
                types.add("'" + f.params.get(i).tlb() + "'");
                names.add("'p" + i + "'");
            }
            sb.append("  B.AddFunc('").append(f.comName).append("', ").append(f.dispId).append(", ")
              .append(switch (f.kind) { case METHOD -> "jiMethod"; case GET -> "jiGet"; case PUT -> "jiPut"; })
              .append(", '").append(f.ret == null ? "" : f.ret.tlb()).append("', [")
              .append(String.join(", ", types)).append("], [").append(String.join(", ", names)).append("]);\n");
        }
    }

    String callbackIid(TInfo t) {
        return BindingGenerator.guid("pascal-java-bridge-com-callback-iid:" + t.cls.getName());
    }

    String libId() { return BindingGenerator.guid("pascal-java-bridge-com-libid:" + unit); }
    String clsid() { return BindingGenerator.guid("pascal-java-bridge-com-clsid:" + unit); }

    /** The in-process COM server project for this unit. */
    String emitServer() {
        String lib = comUnit + "Server";
        return "{ Generated by pascal-java-bridge BindingGenerator (--com) - do not edit.\n"
                + "  In-process COM server for " + unit + ": ProgID " + progId + ".\n"
                + "    regsvr32 " + lib + ".dll              all users (elevated prompt)\n"
                + "    regsvr32 /n /i:user " + lib + ".dll   current user only\n"
                + "    regsvr32 /u [/n /i:user] " + lib + ".dll\n"
                + "  Registration also writes and registers " + lib + ".tlb next to the DLL. }\n"
                + "library " + lib + ";\n\nuses\n  Winapi.Windows, Winapi.ActiveX, System.SysUtils, JavaBridge, JavaBridgeAuto,\n  "
                + comUnit + ";\n\n"
                + "function NewEntry: IDispatch;\nbegin\n  Result := " + entryFn + ";\nend;\n\n"
                + "function DllGetClassObject(const CLSID, IID: TGUID; var Obj): HResult; stdcall;\nbegin\n"
                + "  Result := JavaComClassObject(CLSID, IID, Obj, CLASS_" + coName + ", NewEntry);\nend;\n\n"
                + "function DllCanUnloadNow: HResult; stdcall;\nbegin\n"
                + "  Result := S_FALSE;   { a loaded JVM can't be unloaded }\nend;\n\n"
                + "function Reg(Install, PerUser: Boolean): HResult;\nbegin\n"
                + "  Result := JavaComRegisterServer(Install, PerUser, CLASS_" + coName + ", PROGID_" + coName
                + ",\n    " + BindingGenerator.pasStr("pascal-java-bridge: Java classes of " + unit) + ", "
                + makerFn + ");\nend;\n\n"
                + "function DllRegisterServer: HResult; stdcall;\nbegin\n  Result := Reg(True, False);\nend;\n\n"
                + "function DllUnregisterServer: HResult; stdcall;\nbegin\n  Result := Reg(False, False);\nend;\n\n"
                + "function DllInstall(bInstall: BOOL; pszCmdLine: PWideChar): HResult; stdcall;\nbegin\n"
                + "  Result := Reg(bInstall, SameText(pszCmdLine, 'user'));\nend;\n\n"
                + "exports\n  DllGetClassObject,\n  DllCanUnloadNow,\n  DllRegisterServer,\n  DllUnregisterServer,\n"
                + "  DllInstall;\n\nbegin\n  IsMultiThread := True;\nend.\n";
    }
}
