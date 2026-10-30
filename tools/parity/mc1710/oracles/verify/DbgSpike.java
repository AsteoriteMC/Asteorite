import java.lang.reflect.*;
import java.util.*;
public class DbgSpike {
    public static void main(String[] args) throws Exception {
        Field f = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
        f.setAccessible(true);
        sun.misc.Unsafe U = (sun.misc.Unsafe) f.get(null);
        Class<?> VW = Class.forName("VGold$FakeWorld");
        Class<?> AHU = Class.forName("ahu");
        Class<?> AJN = Class.forName("ajn");
        Class<?> AJI = Class.forName("aji");
        Method reg = null;
        for (Method m : AJI.getDeclaredMethods())
            if (m.getName().equals("p") && m.getParameterTypes().length == 0) reg = m;
        reg.setAccessible(true);
        reg.invoke(null);
        System.out.println("reg ok");
        for (String fn : new String[]{"a","b","d","aE","cj"}) {
            Field ff = AJN.getDeclaredField(fn); ff.setAccessible(true);
            Object v = ff.get(null);
            System.out.println("ajn." + fn + " = " + v);
        }
        Object w = U.allocateInstance(VW);
        Field bf = AHU.getDeclaredField("p"); bf.setAccessible(true);
        Object plains = bf.get(null);
        System.out.println("plains=" + plains);
        Field airF = AJN.getDeclaredField("a"); airF.setAccessible(true);
        Object air = airF.get(null);
        System.out.println("air=" + air);
        Method init = VW.getDeclaredMethod("init", int.class, int.class, int.class, int.class, AHU, AJI);
        init.setAccessible(true);
        init.invoke(w, 48, 48, 0, 0, plains, air);
        System.out.println("init ok");
        Field blocksF = VW.getDeclaredField("blocks");
        Object[] arr = (Object[]) blocksF.get(w);
        System.out.println("len=" + arr.length + " sample=" + arr[0]);
    }
}
