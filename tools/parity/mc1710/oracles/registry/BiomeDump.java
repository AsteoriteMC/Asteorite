import java.lang.reflect.*;

// Parity oracle for tools/parity registry/biomes area.
// Dumps every slot of the vanilla 1.7.10 biome registry: `id:name` or `id:-`.
// Field roles (`ay` = numeric id, `af` = registry name) established by the
// rescued smoke/Ids.java oracle. Joins against biome.zig `// N Name`
// comments, which must match exactly (vanilla spacing is inconsistent:
// "Ice Plains" but "FrozenOcean").
public class BiomeDump {
    public static void main(String[] args) throws Exception {
        Class<?> biome = Class.forName("ahu");
        Method all = null;
        for (Method m : biome.getDeclaredMethods()) {
            if (Modifier.isStatic(m.getModifiers()) && m.getParameterTypes().length == 0
                && m.getReturnType().isArray() && m.getReturnType().getComponentType() == biome) {
                all = m;
                break;
            }
        }
        if (all == null) throw new RuntimeException("no biome array accessor");
        all.setAccessible(true);
        Object[] arr = (Object[]) all.invoke(null);
        Field idF = biome.getDeclaredField("ay");
        Field nameF = biome.getDeclaredField("af");
        idF.setAccessible(true);
        nameF.setAccessible(true);
        for (int i = 0; i < arr.length; i++) {
            if (arr[i] == null) {
                System.out.println(i + ":-");
                continue;
            }
            int id = idF.getInt(arr[i]);
            Object name = nameF.get(arr[i]);
            if (id != i) System.out.println(i + ":ID_MISMATCH(" + id + ")");
            else System.out.println(i + ":" + name);
        }
    }
}
