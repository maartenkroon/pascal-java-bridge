package demo;

/** Superclass for Torture: tests inherited members, overloads across levels and covariance. */
public class Base {
    public String over(double d) { return "Base.double"; }
    public Base self() { return this; }
    public String who() { return "Base"; }
    public int baseField = 7;
}
