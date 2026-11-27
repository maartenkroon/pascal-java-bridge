package demo;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.function.Function;

/** Java side of the callback tests: calls interfaces that are implemented in Pascal. */
public class CallbackHost {

    public interface Listener {
        void onEvent(String name, int value);
    }

    public interface Calculator {
        int apply(int a, int b);
        double scale(double x);
        boolean test(long v, char c);
        String name();
        int[] range(int n);
        List<?> wrap(String s);
        default String describe() { return "calc:" + name(); }
    }

    /** A callback returning an object array (typed COM callbacks need the element class). */
    public interface Source {
        Object[] items(int n);
    }

    public static String joinItems(Source s, int n) {
        return Arrays.toString(s.items(n));
    }

    private final List<Listener> listeners = new ArrayList<>();

    public void addListener(Listener l) { listeners.add(l); }

    public void fire(String name, int value) {
        for (Listener l : listeners) l.onEvent(name, value);
    }

    public static String useCalculator(Calculator c) {
        return c.apply(2, 3) + "," + c.scale(1.5) + "," + c.test(5L, 'x') + "," + c.describe() + ","
                + Arrays.toString(c.range(3)) + "," + c.wrap("w").get(0) + "," + c;
    }

    public static Object applyTwice(Function<Object, Object> f, Object x) {
        return f.apply(f.apply(x));
    }

    public static void runInThread(Runnable r) throws InterruptedException {
        Thread t = new Thread(r, "java-worker");
        t.start();
        t.join();
    }

    public static String runCatching(Runnable r) {
        try {
            r.run();
            return "no exception";
        } catch (RuntimeException e) {
            return e.getClass().getName() + ": " + e.getMessage();
        }
    }

    /** Benchmark helper: n calls from Java into the Pascal implementation. */
    public static long sumApply(Calculator c, int n) {
        long sum = 0;
        for (int i = 0; i < n; i++) sum += c.apply(i, 1);
        return sum;
    }

    public static void gc() throws InterruptedException {
        for (int i = 0; i < 10; i++) {
            System.gc();
            Thread.sleep(20);
        }
    }
}
