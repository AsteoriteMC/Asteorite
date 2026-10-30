import java.lang.reflect.*;
public class BiomeDeco {
    public static void main(String[] a) throws Exception {
        Class<?> biome = Class.forName("ahu");
        Method all = null;
        for (Method m : biome.getDeclaredMethods()) {
            if (Modifier.isStatic(m.getModifiers()) && m.getParameterTypes().length == 0
                && m.getReturnType().isArray() && m.getReturnType().getComponentType() == biome) { all = m; break; }
        }
        all.setAccessible(true);
        Object[] arr = (Object[]) all.invoke(null);
        java.util.Map<Integer,Integer> pairs = new java.util.LinkedHashMap<Integer,Integer>();
        int[] ms = {149,151,130,133,134,158,155,156,163,164,157};
        int[] bs = {21,23,2,5,6,30,27,28,35,36,29};
        for (int k = 0; k < ms.length; k++) {
            Object m = arr[ms[k]], b = arr[bs[k]];
            Field df = null;
            for (Field f : m.getClass().getFields()) {
                if (f.getType().getSimpleName().equals("aia")) { df = f; break; }
            }
            if (df == null) { System.out.println(ms[k] + " nodeco-field"); continue; }
            Object dm = df.get(m), db = df.get(b);
            System.out.println(ms[k] + "->" + bs[k] + " sameDeco=" + (dm == db)
                + " mcls=" + m.getClass().getSimpleName() + " bcls=" + b.getClass().getSimpleName());
        }
    }
}
