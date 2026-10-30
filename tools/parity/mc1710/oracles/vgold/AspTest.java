import java.lang.reflect.*;
import java.util.Random;
public class AspTest {
  public static void main(String[] args) throws Exception {
    Class<?> vw = Class.forName("VGold$FakeWorld");
    sun.misc.Unsafe u = null;
    Field f = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
    f.setAccessible(true);
    u = (sun.misc.Unsafe) f.get(null);
    Class<?> aji0 = Class.forName("aji");
    Method reg0 = null;
    for (Method m : aji0.getDeclaredMethods())
      if (m.getName().equals("p") && m.getParameterTypes().length == 0) reg0 = m;
    reg0.setAccessible(true);
    reg0.invoke(null);
    Object w = u.allocateInstance(vw);
    Class<?> ahu = Class.forName("ahu");
    Class<?> ajn = Class.forName("ajn");
    Field fa = ajn.getDeclaredField("a"); fa.setAccessible(true);
    Field fb = ajn.getDeclaredField("b"); fb.setAccessible(true);
    Field fc = ajn.getDeclaredField("c"); fc.setAccessible(true);
    Object air = fa.get(null), stone = fb.get(null), grass = fc.get(null);
    Field bf = ahu.getDeclaredField("p"); bf.setAccessible(true);
    Object plains = bf.get(null);
    Method init = vw.getDeclaredMethod("init", int.class, int.class, int.class, int.class, ahu, aji0);
    init.setAccessible(true);
    init.invoke(w, 48, 48, -16, -16, plains, air);
    Field blocksF = vw.getDeclaredField("blocks");
    blocksF.setAccessible(true);
    Object[] blocks = (Object[]) blocksF.get(w);
    System.out.println("blocks len=" + (blocks == null ? "null" : blocks.length));
    System.out.println("air=" + air + " stone=" + stone + " grass=" + grass);
    System.out.println("sample(27,38,82)=" + blocks[(27 * 48 + 38) * 256 + 82]);
    for (int x = 0; x < 48; x++) for (int z = 0; z < 48; z++)
      for (int y = 0; y < 256; y++)
        blocks[(x * 48 + z) * 256 + y] = y < 70 ? stone : (y == 70 ? grass : air);
    // single asp.generate at (11,82,22) with Random(0)
    Class<?> asp = Class.forName("asp");
    Field fh = ajn.getDeclaredField("H"); fh.setAccessible(true);
    Object tallgrass = fh.get(null);
    Object gen = asp.getDeclaredConstructor(aji0, int.class).newInstance(tallgrass, 1);
    Method gen_m = null;
    for (Method m : asp.getDeclaredMethods())
      if (m.getReturnType() == boolean.class && m.getParameterTypes().length == 5) gen_m = m;
    gen_m.setAccessible(true);
    Random rand = new Random(0L);
    System.out.println("placed=" + gen_m.invoke(gen, w, rand, 11, 82, 22));
    Method getId = null;
    for (Method m : aji0.getDeclaredMethods()) {
      if (Modifier.isStatic(m.getModifiers()) && m.getReturnType() == int.class
          && m.getParameterTypes().length == 1 && m.getParameterTypes()[0] == aji0) { getId = m; break; }
    }
    getId.setAccessible(true);
    int n = 0;
    StringBuilder sb = new StringBuilder();
    for (int x = 0; x < 16; x++) for (int y = 0; y < 256; y++) for (int z = 0; z < 16; z++) {
      int id = (Integer) getId.invoke(null, blocks[(x * 48 + z) * 256 + y]);
      if (id == 31) { n++; if (n < 10) sb.append(" (").append(x).append(",").append(y).append(",").append(z).append(")"); }
    }
    System.out.println("count=" + n + sb);
  }
}
