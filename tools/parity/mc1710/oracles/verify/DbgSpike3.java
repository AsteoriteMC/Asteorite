import java.lang.reflect.*;
import java.util.*;
public class DbgSpike3 {
    public static void main(String[] args) throws Exception {
        Field f = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
        f.setAccessible(true);
        sun.misc.Unsafe U = (sun.misc.Unsafe) f.get(null);
        Class<?> VW = Class.forName("VGold$FakeWorld");
        Class<?> AHU = Class.forName("ahu");
        Class<?> AJI = Class.forName("aji");
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
        System.out.println("registry=" + registry);
        Method byId = null;
        for (Method m : registry.getClass().getDeclaredMethods()) {
            if (m.getReturnType() == Object.class && m.getParameterTypes().length == 1
                && m.getParameterTypes()[0] == int.class) { byId = m; break; }
        }
        byId.setAccessible(true);
        Object snow = byId.invoke(registry, 80);
        Object air = byId.invoke(registry, 0);
        System.out.println("snow=" + snow + " air=" + air);
        Object w = U.allocateInstance(VW);
        Field bf = AHU.getDeclaredField("p"); bf.setAccessible(true);
        Method init = VW.getDeclaredMethod("init", int.class, int.class, int.class, int.class, AHU, AJI);
        init.setAccessible(true);
        init.invoke(w, 48, 48, 0, 0, bf.get(null), air);
        Field blocksF = VW.getDeclaredField("blocks");
        Object[] arr = (Object[]) blocksF.get(w);
        System.out.println("arr0=" + arr[0]);
        arr[(24 * 48 + 24) * 256 + 70] = snow;
        Method get = VW.getMethod("a", int.class, int.class, int.class);
        System.out.println("get(24,70,24)=" + get.invoke(w, 24, 70, 24) + " ==snow? " + (get.invoke(w, 24, 70, 24) == snow));
        Method fh = VW.getMethod("f", int.class, int.class);
        System.out.println("f(24,24)=" + fh.invoke(w, 24, 24));
    }
}
