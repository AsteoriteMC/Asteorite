import java.lang.reflect.*;
import java.util.*;

// Golden oracle for 1.7.10 WorldGenIceSpike (arw) + WorldGenIcePath (arv).
// Reuses VGold$FakeWorld (48x48, synthetic stone/dirt/snow terrain).
// Prints placed-packed-ice cells per seed for the Zig port to match.
public class SpikeGold {
    static sun.misc.Unsafe U;
    static Class<?> VW, AHU, AJN, AJI, AHB;
    static Object AIR, SNOW, DIRT, STONE;
    static Method BLOCKID, FINIT, FW_F;

    static Object newWorld() throws Exception {
        Object w = U.allocateInstance(VW);
        Field bf = AHU.getDeclaredField("p"); bf.setAccessible(true);
        Object plains = bf.get(null);
        FINIT.invoke(w, 48, 48, 0, 0, plains, AIR);
        // world seed plumbing (unused by arw/arv, but harmless)
        Class<?> ays = Class.forName("ays");
        Object wi = U.allocateInstance(ays);
        Field fseed = ays.getDeclaredField("a"); fseed.setAccessible(true);
        fseed.setLong(wi, 42L);
        for (Field ff : AHB.getDeclaredFields()) {
            if (ff.getType() == ays) { ff.setAccessible(true); ff.set(w, wi); }
            if (ff.getType() == Random.class) { ff.setAccessible(true); ff.set(w, new Random(1L)); }
        }
        return w;
    }

    static void fillSnowTop(Object w) throws Exception {
        // blocks field of FakeWorld: aji[sx*256*sz], idx (lx*sz+lz)*256+y
        Field f = null;
        for (Field ff : VW.getDeclaredFields()) {
            if (ff.getType().isArray()) { f = ff; break; }
        }
        f.setAccessible(true);
        Object[] arr = (Object[]) f.get(w);
        for (int lx = 0; lx < 48; lx++)
            for (int lz = 0; lz < 48; lz++)
                for (int y = 0; y < 256; y++) {
                    int i = (lx * 48 + lz) * 256 + y;
                    arr[i] = y < 68 ? STONE : (y < 70 ? DIRT : (y == 70 ? SNOW : AIR));
                }
    }

    static String dump(Object w, String tag, long seed) throws Exception {
        Field f = null;
        for (Field ff : VW.getDeclaredFields()) {
            if (ff.getType().isArray()) { f = ff; break; }
        }
        f.setAccessible(true);
        Object[] arr = (Object[]) f.get(w);
        StringBuilder sb = new StringBuilder();
        sb.append(tag).append(" seed=").append(seed);
        int n = 0;
        long crc = 0;
        for (int lx = 0; lx < 48; lx++)
            for (int lz = 0; lz < 48; lz++)
                for (int y = 0; y < 256; y++) {
                    Object b = arr[(lx * 48 + lz) * 256 + y];
                    if (b == STONE || b == DIRT || b == SNOW || b == AIR) continue;
                    int id = (Integer) BLOCKID.invoke(null, b);
                    n++;
                    crc = crc * 31 + id + lx * 7919 + y * 104729 + lz * 1299709;
                    sb.append(' ').append(lx - 24).append(',').append(y).append(',').append(lz - 24).append('=').append(id);
                }
        sb.append(" n=").append(n).append(" crc=").append(crc);
        return sb.toString();
    }

    public static void main(String[] args) throws Exception {
        Field f = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
        f.setAccessible(true);
        U = (sun.misc.Unsafe) f.get(null);
        VW = Class.forName("VGold$FakeWorld");
        AHU = Class.forName("ahu");
        AJN = Class.forName("ajn");
        AJI = Class.forName("aji");
        AHB = Class.forName("ahb");
        Method reg = null;
        for (Method m : AJI.getDeclaredMethods())
            if (m.getName().equals("p") && m.getParameterTypes().length == 0) reg = m;
        reg.setAccessible(true);
        reg.invoke(null);
        // Blocks statics are never assigned in 1.7.10 (assigned nowhere post-p());
        // resolve instances from the block registry (aji.c) by wire id.
        Field regF = null;
        for (Field ff : AJI.getDeclaredFields()) {
            if (ff.getType().getName().equals("cw")) { regF = ff; break; }
        }
        regF.setAccessible(true);
        Object registry = regF.get(null);
        Method byId = null;
        for (Method m : registry.getClass().getDeclaredMethods()) {
            if (m.getReturnType() == Object.class && m.getParameterTypes().length == 1
                && m.getParameterTypes()[0] == int.class) { byId = m; break; }
        }
        byId.setAccessible(true);
        AIR = byId.invoke(registry, 0);
        STONE = byId.invoke(registry, 1);
        DIRT = byId.invoke(registry, 3);
        SNOW = byId.invoke(registry, 80);
        // 1.7.10 startup (Bootstrap) assigns Blocks statics; headless it
        // never runs, so the generators compare against null. Assign from
        // the registry: a=air b=stone d=dirt aE=snow aD=ice cj=packed_ice.
        Object ICE = byId.invoke(registry, 79);
        Object PACKED = byId.invoke(registry, 174);
        java.util.Map<String, Object> want = new java.util.HashMap<String, Object>();
        want.put("a", AIR);
        want.put("b", STONE);
        want.put("d", DIRT);
        want.put("aE", SNOW);
        want.put("aD", ICE);
        want.put("cj", PACKED);
        sun.misc.Unsafe uu = U;
        for (java.util.Map.Entry<String, Object> e : want.entrySet()) {
            Field ff = AJN.getDeclaredField(e.getKey());
            uu.putObject(AJN, uu.staticFieldOffset(ff), e.getValue());
        }
        BLOCKID = VW.getDeclaredMethod("blockId", AJI);
        BLOCKID.setAccessible(true);
        FINIT = VW.getDeclaredMethod("init", int.class, int.class, int.class, int.class, AHU, AJI);
        FINIT.setAccessible(true);
        FW_F = VW.getMethod("f", int.class, int.class);

        Class<?> arw = Class.forName("arw");
        Class<?> arv = Class.forName("arv");
        Method genW = null, genV = null;
        for (Method m : arw.getDeclaredMethods())
            if (m.getReturnType() == boolean.class && m.getParameterTypes().length == 5) genW = m;
        for (Method m : arv.getDeclaredMethods())
            if (m.getReturnType() == boolean.class && m.getParameterTypes().length == 5) genV = m;
        genW.setAccessible(true);
        genV.setAccessible(true);
        Object spike = arw.getDeclaredConstructor().newInstance();
        Object path = arv.getDeclaredConstructor(int.class).newInstance(4);

        long[] seeds = {1, 2, 3, 7, 42};
        {
            Object w = newWorld();
            fillSnowTop(w);
            Method get = VW.getMethod("a", int.class, int.class, int.class);
            System.out.println("DBG f=" + FW_F.invoke(w, 24, 24) + " g70snow=" + (get.invoke(w, 24, 70, 24) == SNOW));
        }
        for (long s : seeds) {
            Object w = newWorld();
            fillSnowTop(w);
            int hx = 24, hz = 24;
            int hy = (Integer) FW_F.invoke(w, hx, hz);
            boolean ok = (Boolean) genW.invoke(spike, w, new Random(s), hx, hy, hz);
            System.out.println(dump(w, "spike ok=" + ok, s));
        }
        for (long s : seeds) {
            Object w = newWorld();
            fillSnowTop(w);
            int hx = 24, hz = 24;
            int hy = (Integer) FW_F.invoke(w, hx, hz);
            boolean ok = (Boolean) genV.invoke(path, w, new Random(s), hx, hy, hz);
            System.out.println(dump(w, "path ok=" + ok, s));
        }
        // negative case: dirt top (no snow) -> expect false, n=0
        {
            Object w = newWorld();
            Field fb = null;
            for (Field ff : VW.getDeclaredFields()) {
                if (ff.getType().isArray()) { fb = ff; break; }
            }
            fb.setAccessible(true);
            Object[] arr = (Object[]) fb.get(w);
            for (int lx = 0; lx < 48; lx++)
                for (int lz = 0; lz < 48; lz++)
                    for (int y = 0; y < 256; y++) {
                        int i = (lx * 48 + lz) * 256 + y;
                        arr[i] = y < 69 ? STONE : (y == 69 ? DIRT : AIR);
                    }
            boolean ok = (Boolean) genW.invoke(spike, w, new Random(1), 24, (Integer) FW_F.invoke(w, 24, 24), 24);
            System.out.println(dump(w, "spike-dirt ok=" + ok, 1));
        }
    }
}
