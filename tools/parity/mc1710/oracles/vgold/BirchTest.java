import java.lang.reflect.*;
import java.util.Random;
public class BirchTest {
  public static void main(String[] args) throws Exception {
    Class<?> vw = Class.forName("VGold$FakeWorld");
    sun.misc.Unsafe u = null;
    Field f = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
    f.setAccessible(true);
    u = (sun.misc.Unsafe) f.get(null);
    Class<?> aji0 = Class.forName("aji");
    Method reg = null;
    for (Method m : aji0.getDeclaredMethods())
      if (m.getName().equals("p") && m.getParameterTypes().length == 0) reg = m;
    reg.setAccessible(true);
    reg.invoke(null);
    Object w = u.allocateInstance(vw);
    Class<?> ahu = Class.forName("ahu");
    Class<?> ajn = Class.forName("ajn");
    Field fa = ajn.getDeclaredField("a"); fa.setAccessible(true);
    Field fb = ajn.getDeclaredField("b"); fb.setAccessible(true);
    Field fc = ajn.getDeclaredField("c"); fc.setAccessible(true);
    Object air = fa.get(null), stone = fb.get(null), grass = fc.get(null);
    Field bf = ahu.getDeclaredField("s"); bf.setAccessible(true);
    Object forest = bf.get(null);
    Method init = vw.getDeclaredMethod("init", int.class, int.class, int.class, int.class, ahu, aji0);
    init.setAccessible(true);
    init.invoke(w, 48, 48, -16, -16, forest, air);
    java.lang.reflect.Field blocksF = vw.getDeclaredField("blocks");
    blocksF.setAccessible(true);
    Object[] blocks = (Object[]) blocksF.get(w);
    for (int x = 0; x < 48; x++) for (int z = 0; z < 48; z++)
      for (int y = 0; y < 256; y++)
        blocks[(x * 48 + z) * 256 + y] = y < 70 ? stone : (y == 70 ? grass : air);
    Random rand = new Random(123L);
    Class<?> are = Class.forName("are");
    Object tree = are.getDeclaredConstructor(boolean.class, boolean.class).newInstance(false, false);
    Method gen = null;
    for (Method m : are.getDeclaredMethods())
      if (m.getReturnType() == boolean.class && m.getParameterTypes().length == 5) gen = m;
    gen.setAccessible(true);
    System.out.println("placed=" + gen.invoke(tree, w, rand, 5, 71, 5));
    Method getId = null;
    for (Method m : aji0.getDeclaredMethods()) {
      if (Modifier.isStatic(m.getModifiers()) && m.getReturnType() == int.class
          && m.getParameterTypes().length == 1 && m.getParameterTypes()[0] == aji0) { getId = m; break; }
    }
    getId.setAccessible(true);
    int logs = 0, leaves = 0;
    for (int x = -16; x < 32; x++) for (int y = 60; y < 90; y++) for (int z = -16; z < 32; z++) {
      int lx = x + 16, lz = z + 16;
      if (lx < 0 || lx >= 48 || lz < 0 || lz >= 48) continue;
      int id = (Integer) getId.invoke(null, blocks[(lx * 48 + lz) * 256 + y]);
      if (id == 17) logs++;
      if (id == 18) leaves++;
    }
    System.out.println("logs=" + logs + " leaves=" + leaves);
  }
}
