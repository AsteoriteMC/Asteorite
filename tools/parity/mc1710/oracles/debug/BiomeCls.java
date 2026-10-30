import java.lang.reflect.*;
public class BiomeCls {
    public static void main(String[] a) throws Exception {
        Class<?> biome = Class.forName("ahu");
        Method all = null;
        for (Method m : biome.getDeclaredMethods()) {
            if (Modifier.isStatic(m.getModifiers()) && m.getParameterTypes().length == 0
                && m.getReturnType().isArray() && m.getReturnType().getComponentType() == biome) { all = m; break; }
        }
        all.setAccessible(true);
        Object[] arr = (Object[]) all.invoke(null);
        for (String s : a) {
            int i = Integer.parseInt(s);
            Object b = arr[i];
            System.out.println(i + " " + (b == null ? "null" : b.getClass().getSimpleName()));
        }
    }
}
