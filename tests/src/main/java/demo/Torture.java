package demo;

import java.util.List;

/**
 * Deliberately awkward API used to test the generator's collision handling.
 * Every member name here would break a naive Java-to-Pascal wrapper generator.
 */
public class Torture extends Base implements Runnable {

    // --- Pascal keywords and directives as names
    public int type() { return 1; }
    public int begin() { return 2; }
    public int end() { return 3; }
    public int read() { return 4; }
    public int index() { return 5; }
    public int string() { return 6; }

    // --- names of TObject / TInterfacedObject / runtime members
    public String Destroy() { return "Destroy"; }
    public String Free() { return "Free"; }
    public String ClassName() { return "ClassName"; }
    public int QueryInterface() { return 7; }
    public int _AddRef() { return 8; }
    public int RefCount() { return 9; }
    public int JavaGlobalRef() { return 10; }
    public int CreateFromLocal() { return 11; }
    public int JrCall() { return 12; }
    public int Result() { return 13; }
    public int Self() { return 14; }
    public int LV() { return 15; }
    public int IJObject() { return 16; }   // equals a generated type name
    public int Integer() { return 17; }    // equals a Pascal type used in signatures
    public int p0() { return 18; }         // equals the default parameter name
    // overloaded: Delphi implements these by name in the impl class (TObject members there)
    public String Free(int n) { return "Free" + n; }
    public String toString(int n) { return "toString" + n; }
    public int RefCount(int n) { return 9 + n; }
    // overloaded runtime member names that generated code calls: the overload is renamed
    public int JavaGlobalRef(int n) { return 10 + n; }
    public int CreateFromLocal(int n) { return 11 + n; }
    // IUnknown/IDispatch method names: renamed in the COM interfaces (--com) only
    public int Invoke() { return 19; }
    public int Release() { return 20; }

    // --- case-only differences (Pascal is case-insensitive)
    public String getUrl() { return "getUrl"; }
    public String getURL() { return "getURL"; }

    // --- overloads, including ones that map to the same Pascal signature
    public String over(int x) { return "int"; }
    public String over(long x) { return "long"; }
    public String over(String s) { return "String"; }
    public String over(int a, String b) { return "int,String"; }
    public String over(Thread t) { return "Thread"; }        // Thread not wrapped -> IJavaObject
    public String over(StringBuilder b) { return "StringBuilder"; } // also IJavaObject -> must be renamed
    public void over() { }                                    // procedure overload of a function

    // --- a field and a method with the same name, plus a static/instance pair
    public int counter = 41;
    public int counter() { return counter + 1; }
    public static int instances = 0;
    public static String describe(int n) { return "static " + n; }
    public String describe() { return "instance"; }

    // --- static members named like the generated helpers
    public static String cast(String s) { return "cast:" + s; }
    public static String New() { return "static New"; }

    // --- constructors
    public Torture() { instances++; }
    public Torture(int start) { this(); counter = start; }
    public Torture(String s) { this(); counter = s.length(); }

    // --- arrays and strings
    public int[] squares(int n) { int[] r = new int[n]; for (int i = 0; i < n; i++) r[i] = i * i; return r; }
    public int sum(int[] values) { int s = 0; for (int v : values) s += v; return s; }
    public String[] split(String s) { return s.split(","); }
    public String join(String[] parts) { return String.join("+", parts); }
    public String unicode(String s) { return s + " é中😀"; }
    public String nullString() { return null; }
    public List<String> list(String a, String b) { return new java.util.ArrayList<>(List.of(a, b)); }

    // --- exceptions
    public void fail(String msg) { throw new IllegalStateException(msg); }

    // --- inner class
    public static class Inner {
        public String hello() { return "inner"; }
    }

    // --- non-ASCII identifier
    public String café() { return "café"; }

    @Override public void run() { counter++; }

    // --- covariant override and plain override of Base methods
    @Override public Torture self() { return this; }
    @Override public String who() { return "Torture"; }
}
