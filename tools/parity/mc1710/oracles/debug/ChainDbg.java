import java.lang.reflect.*;

// Debug: print root[i]'s parent-chain values for single cells.
public class ChainDbg {
    public static void main(String[] a) throws Exception {
        long seed = Long.parseLong(a[0]);
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
        Class<?> gl = Class.forName("axn");
        Method initAll = null;
        for (Method m : gl.getDeclaredMethods()) {
            if (Modifier.isStatic(m.getModifiers()) && m.getReturnType().isArray()
                && m.getParameterTypes().length == 2
                && m.getParameterTypes()[0] == long.class) { initAll = m; break; }
        }
        initAll.setAccessible(true);
        Object[] roots = (Object[]) initAll.invoke(null, seed, def);
        Method getInts = null;
        for (Method m : gl.getDeclaredMethods()) {
            if (m.getReturnType() == int[].class && m.getParameterTypes().length == 4) { getInts = m; break; }
        }
        getInts.setAccessible(true);
        java.util.List<Field> parents = new java.util.ArrayList<Field>();
        for (Field f : gl.getDeclaredFields()) {
            if (f.getType() == gl) { f.setAccessible(true); parents.add(f); }
        }
        for (int i = 1; i + 1 < a.length; i += 2) {
            int x = Integer.parseInt(a[i]), z = Integer.parseInt(a[i + 1]);
            Object node = roots[0];
            StringBuilder sb = new StringBuilder("cell " + x + "," + z + ":");
            for (int depth = 0; depth < 40 && node != null; depth++) {
                int[] out = (int[]) getInts.invoke(node, x - 2, z - 2, 5, 5);
                int mid = out.length >= 13 ? out[12] : out[0];
                sb.append(" ").append(node.getClass().getSimpleName()).append("=").append(mid).append("(n=").append(out.length).append(")");
                Object next = null;
                for (Class<?> kc = node.getClass(); kc != null; kc = kc.getSuperclass()) {
                    for (Field pf : kc.getDeclaredFields()) {
                        if (!gl.isAssignableFrom(pf.getType())) continue;
                        pf.setAccessible(true);
                        Object v = pf.get(node);
                        if (v != null && next == null) { next = v; sb.append("[" + kc.getSimpleName() + "." + pf.getName() + "]"); }
                    }
                }
                if (next == node) break;
                node = next;
            }
            System.out.println(sb.toString());
        }
    }
}
