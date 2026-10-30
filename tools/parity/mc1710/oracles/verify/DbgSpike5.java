import java.lang.reflect.*;
import java.util.*;
public class DbgSpike5 {
    public static void main(String[] args) throws Exception {
        Field f = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
        f.setAccessible(true);
        sun.misc.Unsafe U = (sun.misc.Unsafe) f.get(null);
        Class<?> VW = Class.forName("VGold$FakeWorld");
        Class<?> AHU = Class.forName("ahu");
        Class<?> AJI = Class.forName("aji");
        Class<?> AHB = Class.forName("ahb");
        Class<?> AJN = Class.forName("ajn");
        Method reg = null;
        for (Method m : AJI.getDeclaredMethods())
            if (m.getName().equals("p") && m.getParameterTypes().length == 0) reg = m;
        reg.setAccessible(true);
        reg.invoke(null);
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
        Object packed = byId.invoke(registry, 169);
        System.out.println("packed169=" + packed);
        // assign cj via Unsafe
        Field cj = AJN.getDeclaredField("cj");
        U.putObject(AJN, U.staticFieldOffset(cj), packed);
        System.out.println("cj readback=" + cj.get(null));
        // what does arw see? call a static-final read via a fresh reflective get
        Object w = U.allocateInstance(VW);
        Field bf = AHU.getDeclaredField("p"); bf.setAccessible(true);
        Field airF = AJN.getDeclaredField("a"); airF.setAccessible(true);
        // assign air too
        Object air = byId.invoke(registry, 0);
        U.putObject(AJN, U.staticFieldOffset(airF), air);
        Method init = VW.getDeclaredMethod("init", int.class, int.class, int.class, int.class, AHU, AJI);
        init.setAccessible(true);
        init.invoke(w, 48, 48, 0, 0, bf.get(null), air);
        Field blocksF = VW.getDeclaredField("blocks");
        Object[] arr = (Object[]) blocksF.get(w);
        Object snow = byId.invoke(registry, 80);
        Object stone = byId.invoke(registry, 1);
        Object dirt = byId.invoke(registry, 3);
        for (int lx = 0; lx < 48; lx++)
            for (int lz = 0; lz < 48; lz++)
                for (int y = 0; y < 256; y++)
                    arr[(lx * 48 + lz) * 256 + y] = y < 68 ? stone : (y < 70 ? dirt : (y == 70 ? snow : air));
        Class<?> arw = Class.forName("arw");
        Method genW = null;
        for (Method m : arw.getDeclaredMethods())
            if (m.getReturnType() == boolean.class && m.getParameterTypes().length == 5) genW = m;
        genW.setAccessible(true);
        Object spike = arw.getDeclaredConstructor().newInstance();
        Method fh = VW.getMethod("f", int.class, int.class);
        boolean ok = (Boolean) genW.invoke(spike, w, new Random(1), 24, fh.invoke(w, 24, 24), 24);
        Object cell = arr[(24 * 48 + 24) * 256 + 72];
        System.out.println("ok=" + ok + " cell(24,72,24)=" + cell + " ==packed? " + (cell == packed));
        // blockId probe
        Method bid = VW.getDeclaredMethod("blockId", AJI);
        bid.setAccessible(true);
        System.out.println("blockId(packed)=" + bid.invoke(null, packed));
    }
}
