import java.lang.reflect.*;
import java.util.Random;

/** Headless vanilla 1.7.10 decorate oracle (default package: no signer clash
 *  with the unsigned jar). Calls real populate-level lakes/dungeons +
 *  real BiomeDecorator on synthetic flat terrain through an
 *  Unsafe-allocated ahb with array-backed get/set/height/biome. */
public class VGold {
    public static class FakeProvider extends aqo {
        public String l() { return "Overworld"; }
    }
    public static class FakeWorld extends ahb {
        FakeWorld() { super((azc) null, "", (aqo) null, (ahj) null, (qi) null); }
        public aji[] blocks;
        public int sx, sz, ox, oz;
        public ahu biome;
        public aji airBlock;
        void init(int sx, int sz, int ox, int oz, ahu biome, aji air) {
            this.sx = sx; this.sz = sz; this.ox = ox; this.oz = oz;
            this.biome = biome; this.airBlock = air;
            blocks = new aji[sx * 256 * sz];
            for (int i = 0; i < blocks.length; i++) blocks[i] = air;
        }
        int idx(int x, int y, int z) {
            int lx = x - ox, lz = z - oz;
            if (lx < 0 || lz < 0 || lx >= sx || lz >= sz || y < 0 || y >= 256) return -1;
            return (lx * sz + lz) * 256 + y;
        }
        public aji a(int x, int y, int z) {
            int i = idx(x, y, z);
            return i < 0 ? airBlock : blocks[i];
        }
        public boolean d(int x, int y, int z, aji b, int meta, int flags) {
            int i = idx(x, y, z);
            if (i < 0) return false;
            blocks[i] = b;
            if (System.getProperty("vlogset") != null) {
                int bid = blockId(b);
                System.out.println("SET@" + drawCount + " " + x + "," + y + "," + z + " id=" + bid);
            }
            return true;
        }
        static int blockId(aji b) {
            try {
                for (Method m : aji.class.getDeclaredMethods()) {
                    if (Modifier.isStatic(m.getModifiers()) && m.getReturnType() == int.class
                        && m.getParameterTypes().length == 1 && m.getParameterTypes()[0] == aji.class) {
                        m.setAccessible(true);
                        return (Integer) m.invoke(null, b);
                    }
                }
            } catch (Throwable t) {}
            return -1;
        }
        public int f(int x, int z) {
            for (int y = 255; y >= 0; y--) {
                int i = idx(x, y, z);
                if (i >= 0 && blocks[i] != airBlock) return y + 1;
            }
            return 0;
        }
        public int i(int x, int z) { return f(x, z); }
        public ahu a(int x, int z) { return biome; }
        public int e(int x, int y, int z) { return y >= f(x, z) ? 15 : 0; }
        public int j(int x, int y, int z) { return y >= f(x, z) ? 15 : 0; }
        public ayl a(Class c, String s) { return null; }
        public void a(String s, ayl d) {}
        protected apu j() { return null; }
        protected int p() { return 0; }
        public sa a(int i) { return null; }
    }

    public static void main(String[] args) throws Exception {
        String biomeField = args[0];
        long seed = Long.parseLong(args[1]);
        int cx = Integer.parseInt(args[2]), cz = Integer.parseInt(args[3]);
        // 1. register blocks FIRST
        Class<?> ajiC = Class.forName("aji");
        Method reg = null;
        for (Method m : ajiC.getDeclaredMethods())
            if (m.getName().equals("p") && m.getParameterTypes().length == 0) reg = m;
        reg.setAccessible(true);
        reg.invoke(null);
        Class<?> ahb = Class.forName("ahb");
        Class<?> ahu = Class.forName("ahu");
        Field bf = ahu.getDeclaredField(biomeField);
        bf.setAccessible(true);
        Object biome = bf.get(null);
        // tulip noise check
        Class<?> awl = Class.forName("awl");
        Object noise = awl.getDeclaredConstructor(Random.class, int.class).newInstance(new Random(2345L), 1);
        Method am = awl.getDeclaredMethod("a", double.class, double.class);
        am.setAccessible(true);
        System.out.println("noiseA=" + am.invoke(noise, 8.0/200.0, 8.0/200.0));
        Field f = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
        f.setAccessible(true);
        sun.misc.Unsafe u = (sun.misc.Unsafe) f.get(null);
        FakeWorld w = (FakeWorld) u.allocateInstance(FakeWorld.class);
        for (Field fw : ahb.getDeclaredFields()) {
            fw.setAccessible(true);
            try {
                if (fw.getType() == Random.class && fw.get(w) == null) fw.set(w, new Random(987654321L));
                else if (fw.getType() == java.util.List.class && fw.get(w) == null) fw.set(w, new java.util.ArrayList<Object>());
                else if (fw.getType() == java.util.Set.class && fw.get(w) == null) fw.set(w, new java.util.HashSet<Object>());
                else if (fw.getType() == java.util.Map.class && fw.get(w) == null) fw.set(w, new java.util.HashMap<Object,Object>());
            } catch (Throwable t) {}
        }
        Object prov = new FakeProvider();
        for (Field ff : ahb.getDeclaredFields())
            if (ff.getType().getName().equals("aqo")) { ff.setAccessible(true); ff.set(w, prov); }
        Class<?> ahm = Class.forName("ahm");
        Object wtype = null;
        for (Field ff : ahm.getDeclaredFields())
            if (Modifier.isStatic(ff.getModifiers()) && ff.getType() == ahm) { ff.setAccessible(true); if (wtype == null) wtype = ff.get(null); }
        Class<?> aib = Class.forName("aib");
        Object wcm = aib.getDeclaredConstructor(long.class, ahm).newInstance(seed, wtype);
        for (Field ff : Class.forName("aqo").getDeclaredFields())
            if (ff.getType() == aib) { ff.setAccessible(true); ff.set(prov, wcm); }
        Class<?> ajn = Class.forName("ajn");
        Field fAir = ajn.getDeclaredField("a"); fAir.setAccessible(true);
        Field fStone = ajn.getDeclaredField("b"); fStone.setAccessible(true);
        Field fGrass = ajn.getDeclaredField("c"); fGrass.setAccessible(true);
        aji air = (aji) fAir.get(null), stone = (aji) fStone.get(null), grass = (aji) fGrass.get(null);
        int S = 48;
        w.init(S, S, -16, -16, (ahu) biome, air);
        for (int x = 0; x < S; x++) for (int z = 0; z < S; z++)
            for (int y = 0; y < 256; y++)
                w.blocks[(x * S + z) * 256 + y] = y < 70 ? stone : (y == 70 ? grass : air);
        Random rand = new LoggingRandom(seed);
        long l = rand.nextLong() / 2L * 2L + 1L;
        long l1 = rand.nextLong() / 2L * 2L + 1L;
        rand.setSeed((long) cx * l + (long) cz * l1 ^ seed);
        // ---- populate-level lakes + dungeons ----
        Field fWater = ajn.getDeclaredField("j"); fWater.setAccessible(true);
        Field fLava = ajn.getDeclaredField("l"); fLava.setAccessible(true);
        aji waterB = (aji) fWater.get(null), lavaB = (aji) fLava.get(null);
        Class<?> arx = Class.forName("arx");
        java.lang.reflect.Constructor<?> arxK = arx.getDeclaredConstructor(ajiC);
        arxK.setAccessible(true);
        Method arxG = null;
        for (Method m : arx.getDeclaredMethods())
            if (m.getReturnType() == boolean.class && m.getParameterTypes().length == 5) arxG = m;
        arxG.setAccessible(true);
        Class<?> asd = Class.forName("asd");
        Object dung = asd.getDeclaredConstructor().newInstance();
        Method asdG = null;
        for (Method m : asd.getDeclaredMethods())
            if (m.getReturnType() == boolean.class && m.getParameterTypes().length == 5) asdG = m;
        asdG.setAccessible(true);
        int bx = 0, bz = 0;
        if (rand.nextInt(4) == 0) {
            int wxx = bx + rand.nextInt(16) + 8, wyy = rand.nextInt(256), wzz = bz + rand.nextInt(16) + 8;
            Object lake = arxK.newInstance(waterB);
            arxG.invoke(lake, w, rand, wxx, wyy, wzz);
        }
        if (rand.nextInt(8) == 0) {
            int lxx = bx + rand.nextInt(16) + 8;
            int ly = rand.nextInt(rand.nextInt(248) + 8);
            int lzz = bz + rand.nextInt(16) + 8;
            if (ly < 63 || rand.nextInt(10) == 0) {
                Object lake = arxK.newInstance(lavaB);
                arxG.invoke(lake, w, rand, lxx, ly, lzz);
            }
        }
        for (int di = 0; di < 8; di++)
            asdG.invoke(dung, w, rand, bx + rand.nextInt(16) + 8, rand.nextInt(256), bz + rand.nextInt(16) + 8);
        // ---- decorate ----
        Class<?> aia = Class.forName("aia");
        Field arF = ahu.getDeclaredField("ar");
        arF.setAccessible(true);
        Object dec = arF.get(biome);
        Method decorate = null;
        for (Method m : aia.getDeclaredMethods())
            if (m.getName().equals("a") && m.getParameterTypes().length == 5) decorate = m;
        decorate.setAccessible(true);
        decorate.invoke(dec, w, rand, biome, 0, 0);
        // ---- dump center chunk ----
        Method getId = null;
        for (Method m : ajiC.getDeclaredMethods()) {
            if (Modifier.isStatic(m.getModifiers()) && m.getReturnType() == int.class
                && m.getParameterTypes().length == 1 && m.getParameterTypes()[0] == ajiC) { getId = m; break; }
        }
        getId.setAccessible(true);
        long crc = 0;
        java.util.Map<Integer,Integer> counts = new java.util.TreeMap<>();
        for (int x = 16; x < 32; x++) for (int y = 0; y < 256; y++) for (int z = 16; z < 32; z++) {
            int id = (Integer) getId.invoke(null, w.blocks[(x * S + z) * 256 + y]);
            crc = crc * 31 + id;
            counts.put(id, counts.getOrDefault(id, 0) + 1);
        }
        System.out.println("crc=" + crc);
        System.out.println("counts=" + counts);
        {
            System.out.print("VSURFALL");
            for (int x = 0; x < 16; x++) for (int z = 0; z < 16; z++) {
                for (int y = 65; y <= 75; y++) {
                    int id = (Integer) getId.invoke(null, w.blocks[((x+16) * S + (z+16)) * 256 + y]);
                    if (id != 1 && id != 2 && id != 0 && id != 31) {
                        System.out.print(" (" + x + "," + y + "," + z + ")=" + id);
                    }
                }
            }
            System.out.println();
        }
        if (args.length > 4 && args[4].equals("cols")) {
            int[][] cells = {{11,15},{2,15},{5,13},{13,14},{13,10},{14,12},{5,7},{5,10},{5,14},{5,15},{6,7},{7,15},{11,15}};
            for (int[] cc : cells) {
                StringBuilder sb = new StringBuilder("VCOL " + cc[0] + "," + cc[1] + ":");
                for (int y = 68; y <= 73; y++) {
                    int id = (Integer) getId.invoke(null, w.blocks[((cc[0]+16) * S + (cc[1]+16)) * 256 + y]);
                    sb.append(" ").append(y).append("=").append(id);
                }
                System.out.println(sb);
            }
        }
    }

    static long drawCount = 0;
    static class LoggingRandom extends Random {
        LoggingRandom(long s) { super(s); }
        public int next(int bits) {
            int r = super.next(bits);
            drawCount++;
            if (System.getProperty("vlog") != null) System.out.println("RND next(" + bits + ")=" + r);
            return r;
        }
    }
}