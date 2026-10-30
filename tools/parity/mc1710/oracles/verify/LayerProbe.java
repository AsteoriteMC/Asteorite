import java.lang.reflect.*;

// Vanilla 1.7.10 GenLayer oracle: initializeAllBiomeGenerators(seed, DEFAULT)
// then getInts on all 3 returned roots for a given window. Compares against
// Asteorite's Chain roots [final_mix, voronoi, final_mix].
public class LayerProbe {
    public static void main(String[] args) throws Exception {
        long seed = Long.parseLong(args[0]);
        int x = Integer.parseInt(args[1]);
        int z = Integer.parseInt(args[2]);
        int w = Integer.parseInt(args[3]);
        int h = Integer.parseInt(args[4]);

        Class<?> wt = Class.forName("ahm");
        Object def = null;
        for (Field f : wt.getDeclaredFields()) {
            if (Modifier.isStatic(f.getModifiers()) && f.getType() == wt) {
                f.setAccessible(true);
                Object v = f.get(null);
                Method did = wt.getMethod("d");
                did.setAccessible(true);
                if (((Integer) did.invoke(v)).intValue() == 0) { def = v; break; }
            }
        }
        if (def == null) throw new RuntimeException("no DEFAULT worldtype");
        System.out.println("worldtype=id0 ok");

        Class<?> gl = Class.forName("axn");
        Method initAll = null;
        for (Method m : gl.getDeclaredMethods()) {
            if (Modifier.isStatic(m.getModifiers()) && m.getReturnType().isArray()
                && m.getParameterTypes().length == 2
                && m.getParameterTypes()[0] == long.class
                && m.getParameterTypes()[1] == wt) { initAll = m; break; }
        }
        if (initAll == null) throw new RuntimeException("no initAll");
        initAll.setAccessible(true);
        Object[] roots = (Object[]) initAll.invoke(null, seed, def);
        System.out.println("nroots=" + roots.length);

        Method getInts = null;
        for (Method m : gl.getDeclaredMethods()) {
            if (m.getReturnType() == int[].class && m.getParameterTypes().length == 4) { getInts = m; break; }
        }
        getInts.setAccessible(true);
        for (int i = 0; i < roots.length; i++) {
            int[] out = (int[]) getInts.invoke(roots[i], x, z, w, h);
            StringBuilder sb = new StringBuilder();
            sb.append("R").append(i).append(":");
            for (int v : out) sb.append(' ').append(v);
            System.out.println(sb.toString());
        }
    }
}
