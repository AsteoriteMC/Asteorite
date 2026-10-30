import java.lang.reflect.*;
public class Cols {
  public static void main(String[] args) throws Exception {
    Class<?> vw = Class.forName("VGold$FakeWorld");
    sun.misc.Unsafe u = null;
    Field f = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
    f.setAccessible(true);
    u = (sun.misc.Unsafe) f.get(null);
    Object w = u.allocateInstance(vw);
    // replicate VGold setup for plains seed 42 (0,0) then dump columns - too complex, use VGold directly?
    System.out.println("use VGold main instead");
  }
}
