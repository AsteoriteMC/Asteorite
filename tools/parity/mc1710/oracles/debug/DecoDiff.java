import java.lang.reflect.*;
public class DecoDiff {
    public static void main(String[] a) throws Exception {
        Class<?> biome = Class.forName("ahu");
        Method all = null;
        for (Method m : biome.getDeclaredMethods()) {
            if (Modifier.isStatic(m.getModifiers()) && m.getParameterTypes().length == 0
                && m.getReturnType().isArray() && m.getReturnType().getComponentType() == biome) { all = m; break; }
        }
        all.setAccessible(true);
        Object[] arr = (Object[]) all.invoke(null);
        int[][] pairs = {{149,21},{151,23},{130,2},{133,5},{134,6},{158,30},{155,27},{156,28},{163,35},{164,36},{157,29},{132,4},{129,1}};
        for (int[] pr : pairs) {
            Object m = arr[pr[0]], b = arr[pr[1]];
            Field df = null;
            for (Field f : m.getClass().getFields()) {
                if (f.getType().getSimpleName().equals("aia")) { df = f; break; }
            }
            Object dm = df.get(m), db = df.get(b);
            StringBuilder sb = new StringBuilder(pr[0] + "->" + pr[1]);
            for (Field f : dm.getClass().getDeclaredFields()) {
                if (f.getType() != int.class && f.getType() != boolean.class) continue;
                f.setAccessible(true);
                Object vm, vb;
                try { vm = f.get(dm); vb = f.get(db); }
                catch (Exception e) { continue; }
                if (!vm.equals(vb)) sb.append(" ").append(f.getName()).append("=").append(vm).append("!=").append(vb);
            }
            System.out.println(sb.toString());
        }
    }
}
