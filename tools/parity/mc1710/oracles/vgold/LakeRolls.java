import java.util.Random;
import java.lang.reflect.Field;
public class LakeRolls {
    public static void main(String[] args) throws Exception {
        aji.p();
        Field field = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
        field.setAccessible(true);
        sun.misc.Unsafe unsafe = (sun.misc.Unsafe) field.get(null);
        LakeParity.World world = (LakeParity.World) unsafe.allocateInstance(LakeParity.World.class);
        world.init(32,32,0,0,ahu.p,ajn.a);
        long seed = -1493931639823207632L;
        Random random = new Random(seed);
        long first = random.nextLong()/2*2+1, second = random.nextLong()/2*2+1;
        long water = 0, lava = 0, hash = 0;
        int waterLakes = 0, lavaLakes = 0;
        for (int sample = 0; sample < 256; sample++) {
            for (int i = 0; i < world.blocks.length; i++) world.blocks[i] = i%256 < 70 ? ajn.d : i%256 == 70 ? ajn.c : ajn.a;
            int cx = sample%16-8, cz = sample/16-8;
            random.setSeed((cx*first+cz*second)^seed);
            if (random.nextInt(4)==0) {
                int x=random.nextInt(16)+8, y=random.nextInt(256), z=random.nextInt(16)+8;
                if (new arx(ajn.j).a(world,random,x,y,z)) waterLakes++;
            }
            if (random.nextInt(8)==0) {
                int x=random.nextInt(16)+8, y=random.nextInt(random.nextInt(248)+8), z=random.nextInt(16)+8;
                if (y<63 || random.nextInt(10)==0) if (new arx(ajn.l).a(world,random,x,y,z)) lavaLakes++;
            }
            hash = hash*31+random.nextInt();
            for (aji block : world.blocks) {
                if (block == ajn.j) water++;
                if (block == ajn.l) lava++;
            }
        }
        System.out.println("waterLakes="+waterLakes+" lavaLakes="+lavaLakes+" waterBlocks="+water+" lavaBlocks="+lava+" randomHash="+hash);
    }
}
