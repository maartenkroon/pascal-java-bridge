package pascaljavabridge.internal;

import java.lang.invoke.MethodType;
import java.lang.ref.Cleaner;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.util.HashMap;
import java.util.Map;

/**
 * Routes calls on a Java proxy to a Pascal object (pascal-java-bridge callbacks).
 *
 * <p>The class is not loaded from the classpath: JavaBridge.pas embeds its bytecode and defines
 * it in the system class loader on first use, then registers the two native methods, which
 * are implemented in Pascal. Compile with {@code --release 17} and regenerate the include file
 * with {@code runtime/gen-handler.sh} after changing this file.
 */
public final class PascalInvocationHandler implements InvocationHandler {

    private static final Cleaner CLEANER = Cleaner.create();
    private static final Object[] NO_ARGS = new Object[0];

    private final long handle;
    private final Class<?> iface;
    private final Map<Method, Integer> index = new HashMap<>();

    private PascalInvocationHandler(Class<?> iface, long handle) {
        this.iface = iface;
        this.handle = handle;
    }

    /**
     * Creates a proxy for {@code iface} whose abstract methods, listed in {@code sigs}
     * ("name(descriptor)" separated by '\n', in dispatch-index order), call Pascal.
     */
    public static Object create(Class<?> iface, String sigs, long handle) throws ReflectiveOperationException {
        PascalInvocationHandler h = new PascalInvocationHandler(iface, handle);
        ClassLoader cl = iface.getClassLoader();
        int i = 0;
        for (String s : sigs.split("\n")) {
            int p = s.indexOf('(');
            MethodType mt = MethodType.fromMethodDescriptorString(s.substring(p), cl);
            h.index.put(iface.getMethod(s.substring(0, p), mt.parameterArray()), i++);
        }
        Object proxy = Proxy.newProxyInstance(cl, new Class<?>[]{iface}, h);
        CLEANER.register(proxy, new Release(handle));
        return proxy;
    }

    @Override
    public Object invoke(Object proxy, Method m, Object[] args) throws Throwable {
        Integer i = index.get(m);
        if (i != null) return invoke0(handle, i, args == null ? NO_ARGS : args);
        if (m.isDefault()) return InvocationHandler.invokeDefault(proxy, m, args);
        switch (m.getName()) {
            case "equals":
                if (m.getParameterCount() == 1) return proxy == args[0];
                break;
            case "hashCode":
                if (m.getParameterCount() == 0) return System.identityHashCode(proxy);
                break;
            case "toString":
                if (m.getParameterCount() == 0)
                    return "PascalCallback[" + iface.getName() + "]@"
                            + Integer.toHexString(System.identityHashCode(proxy));
                break;
            default:
                break;
        }
        throw new UnsupportedOperationException("Not implemented in Pascal: " + m);
    }

    /** Releases the Pascal side once the proxy is unreachable (runs on the Cleaner thread). */
    private static final class Release implements Runnable {
        private final long handle;
        Release(long handle) { this.handle = handle; }
        @Override public void run() { release0(handle); }
    }

    private static native Object invoke0(long handle, int index, Object[] args);

    private static native void release0(long handle);
}
