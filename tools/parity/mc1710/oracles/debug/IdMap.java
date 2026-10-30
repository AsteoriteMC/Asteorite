import java.lang.reflect.*;
public class IdMap {
    public static void main(String[] a) throws Exception {
        Class<?> biome = Class.forName("ahu");
        Field idF = biome.getDeclaredField("ay");
        idF.setAccessible(true);
        for (Field f : biome.getDeclaredFields()) {
            if (Modifier.isStatic(f.getModifiers()) && f.getType() == biome) {
                f.setAccessible(true);
                Object b = f.get(null);
                if (b != null) System.out.println(f.getName() + "=" + idF.getInt(b));
            }
        }
    }
}
