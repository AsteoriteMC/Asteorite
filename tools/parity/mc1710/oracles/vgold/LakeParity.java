import java.util.Random;
import java.lang.reflect.Field;

/** Executes supplied server arx; synthetic flat, sky-lit plains fixture. */
public class LakeParity {
    public static class World extends VGold.FakeWorld {
        World() { super(); }
        public int b(ahn type, int x, int y, int z) { return 15; }
        public boolean r(int x, int y, int z) { return false; }
    }
    public static void main(String[] args) throws Exception {
        aji.p();
        Field field = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
        field.setAccessible(true);
        sun.misc.Unsafe unsafe = (sun.misc.Unsafe) field.get(null);
        for (aji liquid : new aji[]{ajn.j, ajn.l}) {
            World world = (World) unsafe.allocateInstance(World.class);
            world.init(16, 16, 0, 0, ahu.p, ajn.a);
            for (int x = 0; x < 16; x++) for (int z = 0; z < 16; z++)
                for (int y = 0; y <= 70; y++) world.d(x,y,z,y == 70 ? ajn.c : ajn.d,0,2);
            Random random = new Random(999);
            boolean placed = new arx(liquid).a(world,random,8,100,8);
            java.util.Map<Integer,Integer> counts = new java.util.TreeMap<>();
            long hash = 0;
            for (aji block : world.blocks) {
                int id = aji.b(block);
                counts.put(id,counts.getOrDefault(id,0)+1);
                hash = hash * 31 + id;
            }
            System.out.println("liquid="+aji.b(liquid)+" placed="+placed+" hash="+hash+" next="+random.nextInt()+" counts="+counts);
        }
    }
}
