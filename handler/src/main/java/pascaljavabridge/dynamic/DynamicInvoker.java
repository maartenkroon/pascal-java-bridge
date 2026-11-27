package pascaljavabridge.dynamic;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.lang.reflect.Array;
import java.lang.reflect.Constructor;
import java.lang.reflect.Executable;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.Deque;
import java.util.Enumeration;
import java.util.HashSet;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Late-bound access to Java objects by member name, for the COM/Automation layer
 * (JavaBridgeCom.pas): member lookup, overload resolution from the run-time argument types, and
 * value conversion. All arguments arrive boxed ({@code Integer}, {@code Long}, {@code Double},
 * {@code Float}, {@code Short}, {@code Byte}, {@code Boolean}, {@code String}, {@code Object[]}
 * for arrays) or as Java objects.
 *
 * <p>Like {@code PascalInvocationHandler}, the class is not loaded from the classpath:
 * JavaBridgeCom.pas embeds its bytecode (JavaBridgeDynamic.inc) and defines it in the system
 * class loader on first use.
 *
 * <p>Members are only taken from types that are accessible from outside (public, in an exported
 * package), and invoked through {@link MethodHandles#publicLookup()} with that type as the
 * reference class. So a public method declared in a non-public class (e.g. the iterator class
 * that {@code ArrayList.iterator()} returns) is called through its public interface.
 */
public final class DynamicInvoker {

    /** Invoke flags, the same values as COM's DISPATCH_* flags. */
    public static final int METHOD = 1, PROPERTYGET = 2, PROPERTYPUT = 4, PROPERTYPUTREF = 8;

    /** Type codes returned by {@link #typeCode}. */
    public static final int T_NULL = 0, T_BOOLEAN = 1, T_BYTE = 2, T_SHORT = 3, T_INT = 4, T_LONG = 5,
            T_FLOAT = 6, T_DOUBLE = 7, T_CHAR = 8, T_STRING = 9, T_ARRAY = 10, T_OBJECT = 11;

    /** Member ids: one per distinct (case-sensitive) name; 0 is never used (COM's DISPID_VALUE). */
    private static final Map<String, Integer> IDS = new ConcurrentHashMap<>();
    private static final List<String> NAMES = new ArrayList<>(List.of(""));

    private static final Map<Class<?>, Members> INSTANCE = new ConcurrentHashMap<>();
    private static final Map<Class<?>, Members> STATIC = new ConcurrentHashMap<>();
    private static final Map<Class<?>, List<Method>> ABSTRACT = new ConcurrentHashMap<>();
    private static final MethodHandles.Lookup LOOKUP = MethodHandles.publicLookup();

    private DynamicInvoker() {
    }

    // ------------------------------------------------------------------ entry points (JNI)

    /** Class.forName with the system class loader. */
    public static Class<?> findClass(String name) throws ClassNotFoundException {
        return Class.forName(name, true, ClassLoader.getSystemClassLoader());
    }

    /**
     * Id of {@code name} as a member of {@code view} (statics only when {@code statics}), or -1.
     * A name is a member if it is a method or field name, or X for a getter/setter getX/isX/setX.
     */
    public static int memberId(Class<?> view, boolean statics, String name) {
        if (name == null || name.isEmpty() || !members(view, statics).has(name)) return -1;
        return idOf(name);
    }

    /**
     * Invokes member {@code id} on {@code target} (null: a static member of {@code view}).
     * {@code flags} are COM's DISPATCH_* flags; for a property put, the last argument is the value.
     */
    public static Object invoke(Object target, Class<?> view, int id, int flags, Object[] args)
            throws Throwable {
        String name = nameOf(id);
        Members ms = members(view, target == null);
        if (args == null) args = new Object[0];
        if ((flags & (PROPERTYPUT | PROPERTYPUTREF)) != 0) return put(ms, target, name, args);
        List<Member> methods = ms.methods(name);
        if ((flags & METHOD) != 0 || !methods.isEmpty()) {
            if (!methods.isEmpty() && (args.length > 0 || (flags & PROPERTYGET) == 0
                    || ms.property(name) == null))
                return call(methods, target, args, name);
        }
        if ((flags & PROPERTYGET) != 0 && args.length == 0) {
            Member p = ms.property(name);
            if (p != null) return p.get(target);
        }
        if (!methods.isEmpty()) return call(methods, target, args, name);
        throw new NoSuchMethodException(describe(view, name, args));
    }

    /** Creates an instance of {@code cls}, choosing the constructor from the argument types. */
    public static Object newInstance(Class<?> cls, Object[] args) throws Throwable {
        if (args == null) args = new Object[0];
        if (cls.isInterface() || Modifier.isAbstract(cls.getModifiers()))
            throw new InstantiationException(cls.getName() + " is abstract");
        if (!accessible(cls)) throw new IllegalAccessException(cls.getName() + " is not public");
        List<Member> ctors = new ArrayList<>();
        Constructor<?>[] cs = cls.getConstructors();
        Arrays.sort(cs, Comparator.comparing(Constructor::toGenericString));
        for (Constructor<?> c : cs) ctors.add(new Member(cls, c));
        if (ctors.isEmpty()) throw new InstantiationException(cls.getName() + " has no public constructor");
        return call(ctors, null, args, "<init>");
    }

    /** Returns {@code obj} if it is an instance of {@code cls}, else throws ClassCastException. */
    public static Object cast(Object obj, Class<?> cls) {
        if (obj != null && !cls.isInstance(obj))
            throw new ClassCastException(obj.getClass().getName() + " cannot be cast to " + cls.getName());
        return obj;
    }

    public static int typeCode(Object v) {
        if (v == null) return T_NULL;
        if (v instanceof Boolean) return T_BOOLEAN;
        if (v instanceof Byte) return T_BYTE;
        if (v instanceof Short) return T_SHORT;
        if (v instanceof Integer) return T_INT;
        if (v instanceof Long) return T_LONG;
        if (v instanceof Float) return T_FLOAT;
        if (v instanceof Double) return T_DOUBLE;
        if (v instanceof Character) return T_CHAR;
        if (v instanceof String) return T_STRING;
        if (v.getClass().isArray()) return T_ARRAY;
        return T_OBJECT;
    }

    public static long longValue(Object v) {
        return v instanceof Character c ? c : ((Number) v).longValue();
    }

    public static double doubleValue(Object v) {
        return ((Number) v).doubleValue();
    }

    public static boolean booleanValue(Object v) {
        return (Boolean) v;
    }

    public static String stringValue(Object v) {
        return String.valueOf(v);
    }

    /** The elements of any Java array, boxed. */
    public static Object[] arrayElements(Object array) {
        if (array instanceof Object[] a) return a;
        int n = Array.getLength(array);
        Object[] r = new Object[n];
        for (int i = 0; i < n; i++) r[i] = Array.get(array, i);
        return r;
    }

    /** Iterator over an Iterable, Iterator, Enumeration, Map (its entries) or array, for For Each. */
    public static Iterator<?> iterator(Object v) {
        if (v instanceof Iterable<?> it) return it.iterator();
        if (v instanceof Iterator<?> it) return it;
        if (v instanceof Map<?, ?> m) return m.entrySet().iterator();
        if (v instanceof Enumeration<?> e) return e.asIterator();
        if (v != null && v.getClass().isArray()) return Arrays.asList(arrayElements(v)).iterator();
        throw new IllegalArgumentException((v == null ? "null" : v.getClass().getName())
                + " cannot be enumerated");
    }

    public static boolean hasNext(Iterator<?> it) {
        return it.hasNext();
    }

    public static Object next(Iterator<?> it) {
        return it.next();
    }

    /**
     * The abstract methods of interface {@code iface} as "name(descriptor)" lines, in the order
     * the Pascal side dispatches them (for PascalInvocationHandler.create).
     */
    public static String abstractMethods(Class<?> iface) {
        if (!iface.isInterface()) throw new IllegalArgumentException(iface.getName() + " is not an interface");
        StringBuilder sb = new StringBuilder();
        for (Method m : abstracts(iface)) {
            if (sb.length() > 0) sb.append('\n');
            sb.append(m.getName()).append(MethodType.methodType(m.getReturnType(), m.getParameterTypes())
                    .toMethodDescriptorString());
        }
        return sb.toString();
    }

    /** Converts a callback result to the return type of abstract method {@code index}. */
    public static Object coerceResult(Class<?> iface, int index, Object value) {
        Class<?> t = abstracts(iface).get(index).getReturnType();
        if (t == void.class) return null;
        if (value == null) {
            if (t.isPrimitive()) throw new NullPointerException("callback " + abstracts(iface).get(index).getName()
                    + " must return a " + t.getName());
            return null;
        }
        if (cost(value, t) < 0)
            throw new ClassCastException("callback " + abstracts(iface).get(index).getName() + " returned "
                    + value.getClass().getName() + ", expected " + t.getName());
        Object r = convert(value, t);
        return r;
    }

    // ------------------------------------------------------------------ members

    private static int idOf(String name) {
        Integer id = IDS.get(name);
        if (id != null) return id;
        synchronized (NAMES) {
            return IDS.computeIfAbsent(name, n -> {
                NAMES.add(n);
                return NAMES.size() - 1;
            });
        }
    }

    private static String nameOf(int id) {
        synchronized (NAMES) {
            if (id <= 0 || id >= NAMES.size()) throw new IllegalArgumentException("Unknown member id " + id);
            return NAMES.get(id);
        }
    }

    private static Members members(Class<?> view, boolean statics) {
        return (statics ? STATIC : INSTANCE).computeIfAbsent(view, c -> new Members(c, statics));
    }

    private static List<Method> abstracts(Class<?> iface) {
        return ABSTRACT.computeIfAbsent(iface, c -> {
            List<Method> r = new ArrayList<>();
            for (Method m : c.getMethods())
                if (Modifier.isAbstract(m.getModifiers()) && !isObjectMethod(m)) r.add(m);
            r.sort(Comparator.comparing(Method::getName).thenComparing(m -> MethodType
                    .methodType(m.getReturnType(), m.getParameterTypes()).toMethodDescriptorString()));
            return r;
        });
    }

    /** equals/hashCode/toString redeclared in an interface (e.g. Comparator.equals). */
    private static boolean isObjectMethod(Method m) {
        try {
            Object.class.getMethod(m.getName(), m.getParameterTypes());
            return true;
        } catch (NoSuchMethodException e) {
            return false;
        }
    }

    /** Public, in an exported package, and (for nested classes) all enclosing classes too. */
    static boolean accessible(Class<?> c) {
        for (Class<?> k = c; k != null; k = k.getDeclaringClass())
            if (!Modifier.isPublic(k.getModifiers())) return false;
        return c.getModule().isExported(c.getPackageName());
    }

    /** c, its superclasses, then all its interfaces, keeping only accessible ones. */
    private static List<Class<?>> accessibleTypes(Class<?> c) {
        List<Class<?>> r = new ArrayList<>();
        Set<Class<?>> seen = new HashSet<>();
        Deque<Class<?>> todo = new ArrayDeque<>();
        for (Class<?> k = c; k != null; k = k.getSuperclass()) todo.add(k);
        while (!todo.isEmpty()) {
            Class<?> k = todo.poll();
            if (!seen.add(k)) continue;
            if (accessible(k)) r.add(k);
            todo.addAll(Arrays.asList(k.getInterfaces()));
        }
        return r;
    }

    /** The members of one class (instance view: also statics, callable on an instance in Java too). */
    static final class Members {
        final Map<String, List<Member>> methods = new LinkedHashMap<>();
        final Map<String, Member> fields = new LinkedHashMap<>();
        final Set<String> lowerNames = new HashSet<>();

        Members(Class<?> c, boolean statics) {
            Set<String> sigs = new HashSet<>();
            List<Class<?>> types = statics ? (accessible(c) ? List.of(c) : List.of()) : accessibleTypes(c);
            for (Class<?> t : types) {
                Method[] ms = t.getMethods();
                Arrays.sort(ms, Comparator.comparing(Method::toGenericString));
                for (Method m : ms) {
                    if (statics && !Modifier.isStatic(m.getModifiers())) continue;
                    if (statics && t.isInterface() && m.getDeclaringClass() != t) continue;
                    String sig = m.getName() + Arrays.toString(m.getParameterTypes());
                    if (!sigs.add(sig)) continue;    // the most specific accessible type wins
                    methods.computeIfAbsent(m.getName(), k -> new ArrayList<>()).add(new Member(t, m));
                }
                for (Field f : t.getFields()) {
                    if (statics && !Modifier.isStatic(f.getModifiers())) continue;
                    fields.putIfAbsent(f.getName(), new Member(t, f));
                }
            }
            for (String n : methods.keySet()) lowerNames.add(n.toLowerCase(Locale.ROOT));
            for (String n : fields.keySet()) lowerNames.add(n.toLowerCase(Locale.ROOT));
        }

        boolean has(String name) {
            String l = name.toLowerCase(Locale.ROOT);
            return lowerNames.contains(l) || lowerNames.contains("get" + l) || lowerNames.contains("is" + l)
                    || lowerNames.contains("set" + l);
        }

        /** Methods named {@code name}: exact case if there are any, else case-insensitive matches. */
        List<Member> methods(String name) {
            List<Member> exact = methods.get(name);
            if (exact != null) return exact;
            List<Member> r = new ArrayList<>();
            for (Map.Entry<String, List<Member>> e : methods.entrySet())
                if (e.getKey().equalsIgnoreCase(name)) r.addAll(e.getValue());
            return r;
        }

        Member field(String name) {
            Member f = fields.get(name);
            if (f != null) return f;
            for (Map.Entry<String, Member> e : fields.entrySet())
                if (e.getKey().equalsIgnoreCase(name)) return e.getValue();
            return null;
        }

        /** A readable property: a field, or a no-argument getX / isX method. */
        Member property(String name) {
            Member f = field(name);
            if (f != null) return f;
            for (String prefix : new String[]{"get", "is"})
                for (Member m : methods(prefix + name))
                    if (m.params().length == 0 && m.returnType() != void.class) return m;
            return null;
        }
    }

    /** A method, constructor or field with the accessible type it is looked up through. */
    static final class Member {
        final Class<?> refc;
        final Executable exec;
        final Field field;
        private volatile MethodHandle handle, setter;

        Member(Class<?> refc, Executable e) { this.refc = refc; this.exec = e; this.field = null; }
        Member(Class<?> refc, Field f) { this.refc = refc; this.exec = null; this.field = f; }

        Class<?>[] params() { return exec.getParameterTypes(); }
        Class<?> returnType() { return exec instanceof Method m ? m.getReturnType() : exec.getDeclaringClass(); }
        boolean isStatic() {
            return Modifier.isStatic(exec != null ? exec.getModifiers() : field.getModifiers());
        }

        MethodHandle handle() throws ReflectiveOperationException {
            MethodHandle h = handle;
            if (h == null) {
                if (field != null) {
                    h = isStatic() ? LOOKUP.findStaticGetter(refc, field.getName(), field.getType())
                            : LOOKUP.findGetter(refc, field.getName(), field.getType());
                } else if (exec instanceof Constructor<?> c) {
                    h = LOOKUP.findConstructor(refc, MethodType.methodType(void.class, c.getParameterTypes()));
                } else {
                    Method m = (Method) exec;
                    MethodType mt = MethodType.methodType(m.getReturnType(), m.getParameterTypes());
                    h = isStatic() ? LOOKUP.findStatic(refc, m.getName(), mt)
                            : LOOKUP.findVirtual(refc, m.getName(), mt);
                }
                // match() already packed varargs; a varargs collector would wrap them again
                h = h.asFixedArity();
                handle = h;
            }
            return h;
        }

        Object get(Object target) throws Throwable {
            if (field == null) return invoke(target, new Object[0]);
            return isStatic() ? handle().invoke() : handle().invoke(target);
        }

        void set(Object target, Object value) throws Throwable {
            if (Modifier.isFinal(field.getModifiers()))
                throw new IllegalAccessException("field " + field.getName() + " is final");
            MethodHandle h = setter;
            if (h == null) {
                h = isStatic() ? LOOKUP.findStaticSetter(refc, field.getName(), field.getType())
                        : LOOKUP.findSetter(refc, field.getName(), field.getType());
                setter = h;
            }
            if (cost(value, field.getType()) < 0)
                throw new IllegalArgumentException("cannot assign " + typeName(value) + " to field "
                        + field.getName() + " of type " + field.getType().getName());
            Object v = convert(value, field.getType());
            if (isStatic()) h.invoke(v); else h.invoke(target, v);
        }

        Object invoke(Object target, Object[] converted) throws Throwable {
            MethodHandle h = handle();
            if (exec instanceof Constructor<?> || isStatic()) return h.invokeWithArguments(converted);
            if (target == null) throw new NullPointerException("instance method " + exec.getName()
                    + " called without an object");
            Object[] all = new Object[converted.length + 1];
            all[0] = target;
            System.arraycopy(converted, 0, all, 1, converted.length);
            return h.invokeWithArguments(all);
        }
    }

    // ------------------------------------------------------------------ calls

    private static Object put(Members ms, Object target, String name, Object[] args) throws Throwable {
        if (args.length == 0) throw new IllegalArgumentException("property put without a value");
        if (args.length == 1) {
            Member f = ms.field(name);
            if (f != null) {
                f.set(target, args[0]);
                return null;
            }
        }
        List<Member> setters = new ArrayList<>(ms.methods("set" + name));
        if (setters.isEmpty()) setters.addAll(ms.methods(name));
        if (setters.isEmpty()) throw new NoSuchFieldException("no field or setter " + name);
        call(setters, target, args, "set" + name);
        return null;
    }

    private static Object call(List<Member> candidates, Object target, Object[] args, String name)
            throws Throwable {
        Member best = null;
        Object[] bestArgs = null;
        int bestCost = Integer.MAX_VALUE;
        for (Member m : candidates) {
            if (target == null && !m.isStatic() && !(m.exec instanceof Constructor<?>)) continue;
            int[] c = new int[1];
            Object[] conv = match(m.exec, args, c);
            if (conv != null && c[0] < bestCost) {
                best = m;
                bestArgs = conv;
                bestCost = c[0];
            }
        }
        if (best == null) {
            Class<?> owner = candidates.isEmpty() ? Object.class : candidates.get(0).exec.getDeclaringClass();
            throw new NoSuchMethodException("no overload of " + describe(owner, name, args) + " matches");
        }
        return best.invoke(target, bestArgs);
    }

    /** Converts args for e, or returns null if they don't fit; adds the conversion cost to cost[0]. */
    private static Object[] match(Executable e, Object[] args, int[] cost) {
        Class<?>[] ps = e.getParameterTypes();
        int n = ps.length;
        if (args.length == n) {
            Object[] r = convertAll(ps, args, cost);
            if (r != null || !e.isVarArgs()) return r;
            cost[0] = 0;
        }
        if (!e.isVarArgs() || args.length < n - 1) return null;
        // varargs: pack the trailing arguments into the array parameter
        Class<?> comp = ps[n - 1].getComponentType();
        Object packed = Array.newInstance(comp, args.length - n + 1);
        int total = 10;
        for (int i = n - 1; i < args.length; i++) {
            int c = cost(args[i], comp);
            if (c < 0) return null;
            total += c;
            Array.set(packed, i - n + 1, convert(args[i], comp));
        }
        Object[] fixed = Arrays.copyOf(args, n - 1);
        Object[] r = convertAll(Arrays.copyOf(ps, n - 1), fixed, cost);
        if (r == null) return null;
        r = Arrays.copyOf(r, n);
        r[n - 1] = packed;
        cost[0] += total;
        return r;
    }

    private static Object[] convertAll(Class<?>[] ps, Object[] args, int[] cost) {
        Object[] r = new Object[ps.length];
        int total = 0;
        for (int i = 0; i < ps.length; i++) {
            int c = cost(args[i], ps[i]);
            if (c < 0) return null;
            total += c;
            r[i] = convert(args[i], ps[i]);
        }
        cost[0] += total;
        return r;
    }

    private static Class<?> unbox(Class<?> c) {
        if (c == Integer.class) return int.class;
        if (c == Long.class) return long.class;
        if (c == Double.class) return double.class;
        if (c == Float.class) return float.class;
        if (c == Short.class) return short.class;
        if (c == Byte.class) return byte.class;
        if (c == Character.class) return char.class;
        if (c == Boolean.class) return boolean.class;
        return null;
    }

    private static boolean integral(Object a) {
        return a instanceof Integer || a instanceof Long || a instanceof Short || a instanceof Byte;
    }

    private static boolean fits(long v, Class<?> p) {
        if (p == int.class) return v >= Integer.MIN_VALUE && v <= Integer.MAX_VALUE;
        if (p == short.class) return v >= Short.MIN_VALUE && v <= Short.MAX_VALUE;
        if (p == byte.class) return v >= Byte.MIN_VALUE && v <= Byte.MAX_VALUE;
        return p == long.class;
    }

    /**
     * Cost of passing {@code a} as a {@code p}: 0 for an exact match, higher for conversions,
     * -1 if not possible.
     */
    static int cost(Object a, Class<?> p) {
        if (a == null) return p.isPrimitive() ? -1 : (p == Object.class ? 2 : 0);
        if (p.isPrimitive()) return primCost(a, p);
        if (p.isInstance(a)) {
            if (a.getClass() == p) return 0;
            return p == Object.class ? 3 : 1;
        }
        Class<?> prim = unbox(p);
        if (prim != null) {
            int c = primCost(a, prim);
            return c < 0 ? -1 : c + 1;
        }
        if (p == String.class && a instanceof Character) return 2;
        if (p.isArray() && a instanceof Object[] arr) {
            int max = 0;
            for (Object x : arr) {
                int c = cost(x, p.getComponentType());
                if (c < 0) return -1;
                max = Math.max(max, c);
            }
            return 4 + max;
        }
        return -1;
    }

    private static int primCost(Object a, Class<?> p) {
        if (a instanceof Boolean) return p == boolean.class ? 0 : -1;
        if (a instanceof Character) return p == char.class ? 0 : (p == int.class || p == long.class ? 3 : -1);
        if (a instanceof String s) return p == char.class && s.length() == 1 ? 3 : -1;
        if (integral(a)) {
            long v = ((Number) a).longValue();
            Class<?> own = unbox(a.getClass());
            if (p == own) return 0;
            if (p == long.class) return 1;
            if (p == int.class || p == short.class || p == byte.class) return fits(v, p) ? 2 : -1;
            if (p == double.class) return 3;
            if (p == float.class) return 4;
            return -1;
        }
        if (a instanceof Double || a instanceof Float) {
            double d = ((Number) a).doubleValue();
            if (p == double.class) return a instanceof Double ? 0 : 1;
            if (p == float.class) return a instanceof Float ? 0 : 2;
            // whole numbers, e.g. an Excel cell value 3.0 passed to an int parameter
            if ((p == int.class || p == long.class || p == short.class || p == byte.class)
                    && d == Math.rint(d) && !Double.isInfinite(d) && fits((long) d, p)
                    && (p != long.class || Math.abs(d) <= 0x1p53)) return 5;
            return -1;
        }
        return -1;
    }

    /** Converts {@code a} to {@code p}; only called when cost(a, p) >= 0. */
    static Object convert(Object a, Class<?> p) {
        if (a == null) return null;
        Class<?> prim = p.isPrimitive() ? p : unbox(p);
        if (prim == null) {
            if (p.isInstance(a)) return a;
            if (p == String.class) return a.toString();
            if (p.isArray() && a instanceof Object[] arr) {
                Object r = Array.newInstance(p.getComponentType(), arr.length);
                for (int i = 0; i < arr.length; i++) Array.set(r, i, convert(arr[i], p.getComponentType()));
                return r;
            }
            return a;
        }
        if (prim == boolean.class) return a;
        if (prim == char.class) return a instanceof String s ? s.charAt(0) : a;
        if (a instanceof Character c) return prim == int.class ? (Object) (int) c : (Object) (long) c;
        Number n = (Number) a;
        if (prim == int.class) return n.intValue();
        if (prim == long.class) return n.longValue();
        if (prim == short.class) return n.shortValue();
        if (prim == byte.class) return n.byteValue();
        if (prim == double.class) return n.doubleValue();
        if (prim == float.class) return n.floatValue();
        return a;
    }

    private static String typeName(Object a) {
        return a == null ? "null" : a.getClass().getSimpleName();
    }

    private static String describe(Class<?> c, String name, Object[] args) {
        StringBuilder sb = new StringBuilder(c.getName()).append('.').append(name).append('(');
        for (int i = 0; i < args.length; i++) sb.append(i > 0 ? ", " : "").append(typeName(args[i]));
        return sb.append(')').toString();
    }
}
