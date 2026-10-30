import java.lang.reflect.*;
import java.util.Random;
public class Struct2 {
  public static void main(String[] args) throws Exception {
    // FakeWorld from VGold (default package)
    Class<?> vw = Class.forName("VGold$FakeWorld");
    sun.misc.Unsafe u = null;
    Field f = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
    f.setAccessible(true);
    u = (sun.misc.Unsafe) f.get(null);
    Object w = u.allocateInstance(vw);
    Class<?> ahu = Class.forName("ahu");
    Field bf = ahu.getDeclaredField("p");
    bf.setAccessible(true);
    Object plains = bf.get(null);
    Class<?> ajn = Class.forName("ajn");
    Class<?> aji = Class.forName("aji");
    Method reg = null;
    for (Method m : aji.getDeclaredMethods())
      if (m.getName().equals("p") && m.getParameterTypes().length == 0) reg = m;
    reg.setAccessible(true);
    reg.invoke(null);
    Field fa = ajn.getDeclaredField("a"); fa.setAccessible(true);
    Object air = fa.get(null);
    Method init = vw.getDeclaredMethod("init", int.class, int.class, int.class, int.class, ahu, aji);
    init.setAccessible(true);
    init.invoke(w, 48, 48, -16, -16, plains, air);
    // WorldInfo with seed 42
    Class<?> ays = Class.forName("ays");
    Object wi = u.allocateInstance(ays);
    Field fa_ = ays.getDeclaredField("a");
    fa_.setAccessible(true);
    fa_.setLong(wi, 42L);
    // set FakeWorld.x (WorldInfo field)
    Class<?> ahb = Class.forName("ahb");
    Field fx = null;
    for (Field ff : ahb.getDeclaredFields()) {
      if (ff.getType() == ays) { fx = ff; break; }
    }
    fx.setAccessible(true);
    fx.set(w, wi);
    // ahb.s random (world rand, used by structure placement)
    for (Field ff : ahb.getDeclaredFields()) {
      if (ff.getType() == java.util.Random.class) { ff.setAccessible(true); ff.set(w, new Random(987654321L)); }
    }
    String[] cls = {"asw", "avn", "aug", "atx"};
    for (String cn : cls) {
      Class<?> c = Class.forName(cn);
      Object inst = c.getDeclaredConstructor().newInstance();
      // set world field (ave.c)
      Class<?> ave = Class.forName("ave");
      boolean hit = false;
      for (int x = -16; x <= 16 && !hit; x++) for (int z = -16; z <= 16; z++) {
        try {
          Method can = null;
          for (Method m : c.getDeclaredMethods()) {
            if (m.getParameterTypes().length == 2 && m.getReturnType() == boolean.class
                && Modifier.isProtected(m.getModifiers())) { can = m; break; }
          }
          can.setAccessible(true);
          // inject world first (field c lives in aqx)
          for (Class<?> k = c; k != null; k = k.getSuperclass())
            for (Field ff : k.getDeclaredFields()) {
              if (ff.getType() == ahb) { ff.setAccessible(true); ff.set(inst, w); }
            }
          boolean r = (Boolean) can.invoke(inst, x, z);
          if (r) { System.out.print(cn + " HIT at (" + x + "," + z + ") "); hit = true; break; }
        } catch (Throwable t) { System.out.println(cn + " ERR " + t.getCause()); break; }
      }
      if (!hit) System.out.println(cn + ": none in radius 16");
    }
  }
}
