import java.lang.reflect.*;
public class AxrDump {
    public static void main(String[] a) throws Exception {
        long seed = Long.parseLong(a[0]);
        int x = Integer.parseInt(a[1]), z = Integer.parseInt(a[2]);
        int w = Integer.parseInt(a[3]), h = Integer.parseInt(a[4]);
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
        // Walk root[0] chain to the axr node (first riverMix, two axn parents).
        Object node = roots[0];
        Object axr = null;
        for (int depth = 0; depth < 30 && node != null; depth++) {
            if (node.getClass().getSimpleName().equals("axr")) { axr = node; break; }
            Object next = null;
            for (Class<?> kc = node.getClass(); kc != null; kc = kc.getSuperclass()) {
                for (Field pf : kc.getDeclaredFields()) {
                    if (!gl.isAssignableFrom(pf.getType())) continue;
                    pf.setAccessible(true);
                    Object v = pf.get(node);
                    if (v != null && next == null) next = v;
                }
            }
            node = next;
        }
        if (axr == null) throw new RuntimeException("no axr found");
        // axr has (Logger c, axn d): find the BIOME parent (the one whose
        // 16x16 window contains jungle-range ids, not river markers).
        for (Class<?> kc = axr.getClass(); kc != null; kc = kc.getSuperclass()) {
            for (Field pf : kc.getDeclaredFields()) {
                if (!gl.isAssignableFrom(pf.getType())) continue;
                pf.setAccessible(true);
                Object par = pf.get(axr);
                if (par == null) continue;
                int[] out = (int[]) getInts.invoke(par, x, z, w, h);
                StringBuilder sb = new StringBuilder(pf.getName() + ":");
                int n = Math.min(out.length, w * h);
                for (int i = 0; i < n; i++) sb.append(' ').append(out[i]);
                System.out.println(sb.toString());
            }
        }
        int[] out = (int[]) getInts.invoke(axr, x, z, w, h);
        StringBuilder sb = new StringBuilder("axr:");
        int n = Math.min(out.length, w * h);
        for (int i = 0; i < n; i++) sb.append(' ').append(out[i]);
        System.out.println(sb.toString());
    }
}
