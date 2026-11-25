package demo;

public class Greeter {

    public static int add(int a, int b) {
        return a + b;
    }

    public static String greet(String name) {
        return "Hello " + name + " from Java " + Runtime.version();
    }

    private final String prefix;

    public Greeter(String prefix) {
        this.prefix = prefix;
    }

    public String decorate(String s) {
        return prefix + s;
    }
}
