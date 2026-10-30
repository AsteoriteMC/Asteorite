import java.lang.reflect.*;
import java.util.Random;
public class LakeOnly {
  public static void main(String[] args) throws Exception {
    // 1. register blocks FIRST (before any ajn/ahu init)
    Class<?> ajiC = Class.forName("aji");
    Method reg = null;
    for (Method m : ajiC.getDeclaredMethods())
      if (m.getName().equals("p") && m.getParameterTypes().length == 0) reg = m;
    reg.setAccessible(true);
    reg.invoke(null);
    // 2. Unsafe world + terrain
    sun.misc.Unsafe u = null;
    Field f = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
    f.setAccessible(true);
    u = (sun.misc.Unsafe) f.get(null);
    Class<?> vw = Class.forName("VGold$FakeWorld");
    Object w = u.allocateInstance(vw);
    Class<?> ahu = Class.forName("ahu");
    Class<?> ajn = Class.forName("ajn");
    Field fa = ajn.getDeclaredField("a"); fa.setAccessible(true);
    Field fb = ajn.getDeclaredField("b"); fb.setAccessible(true);
    Field fc = ajn.getDeclaredField("c"); fc.setAccessible(true);
    Field fl = ajn.getDeclaredField("l"); fl.setAccessible(true);
    Object air = fa.get(null), stone = fb.get(null), grass = fc.get(null), lava = fl.get(null);
    System.out.println("air=" + (air != null) + " stone=" + (stone != null));
    Field bf = ahu.getDeclaredField("p"); bf.setAccessible(true);
    Object plains = bf.get(null);
    Method init = vw.getDeclaredMethod("init", int.class, int.class, int.class, int.class, ahu, ajiC);
    init.setAccessible(true);
    init.invoke(w, 48, 48, -16, -16, plains, air);
    Field blocksF = vw.getDeclaredField("blocks");
    blocksF.setAccessible(true);
    Object[] blocks = (Object[]) blocksF.get(w);
    for (int x = 0; x < 48; x++) for (int z = 0; z < 48; z++)
      for (int y = 0; y < 256; y++)
        blocks[(x * 48 + z) * 256 + y] = y < 70 ? stone : (y == 70 ? grass : air);
    Random rand = new Random(42L);
    long l = rand.nextLong() / 2L * 2L + 1L;
    long l1 = rand.nextLong() / 2L * 2L + 1L;
    rand.setSeed((long) 0 * l + (long) 0 * l1 ^ 42L);
    rand.nextInt(4);
    rand.nextInt(8);
    int inner = rand.nextInt(248);
    int wy = rand.nextInt(inner + 8);
    int wx = rand.nextInt(16) + 8, wz = rand.nextInt(16) + 8;
    System.out.println("lake at " + wx + "," + wy + "," + wz);
    Class<?> arx = Class.forName("arx");
    java.lang.reflect.Constructor<?> k = arx.getDeclaredConstructor(ajiC);
    k.setAccessible(true);
    Object lake = k.newInstance(lava);
    Method gen = null;
    for (Method m : arx.getDeclaredMethods())
      if (m.getReturnType() == boolean.class && m.getParameterTypes().length == 5) gen = m;
    gen.setAccessible(true);
    System.out.println("placed=" + gen.invoke(lake, w, rand, wx, wy, wz));
    Method getId = null;
    for (Method m : ajiC.getDeclaredMethods()) {
      if (Modifier.isStatic(m.getModifiers()) && m.getReturnType() == int.class
          && m.getParameterTypes().length == 1 && m.getParameterTypes()[0] == ajiC) { getId = m; break; }
    }
    getId.setAccessible(true);
    int lavaN = 0, airN = 0, stoneN = 0;
    long crc = 0;
    for (int x = 0; x < 48; x++) for (int y = 0; y < 256; y++) for (int z = 0; z < 48; z++) {
      int id = (Integer) getId.invoke(null, blocks[(x * 48 + z) * 256 + y]);
      crc = crc * 31 + id;
      if (id == 11) lavaN++; else if (id == 0) airN++; else if (id == 1) stoneN++;
    }
    System.out.println("lava=" + lavaN + " air=" + airN + " stone=" + stoneN + " crc=" + crc);
  }
}
