import java.lang.reflect.*;
public class DecoFields {
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
            Object b = arr[Integer.parseInt(s)];
            Field df = null;
            for (Field f : b.getClass().getFields()) {
                if (f.getType().getSimpleName().equals("aia")) { df = f; break; }
            }
            Object d = df.get(b);
            StringBuilder sb = new StringBuilder(s + " deco:");
            for (Field f : d.getClass().getDeclaredFields()) {
                if (f.getType() != int.class && f.getType() != boolean.class) continue;
                f.setAccessible(true);
                try { sb.append(" ").append(f.getName()).append("=").append(f.get(d)); }
                catch (Exception e) { }
            }
            System.out.println(sb.toString());
        }
    }
}
