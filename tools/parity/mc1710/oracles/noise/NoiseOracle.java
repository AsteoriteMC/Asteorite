import java.lang.reflect.*;
import java.util.Random;

// Parity oracle for tools/parity noise area: vanilla 1.7.10 noise
// (awj Improved via awk octaves, awl simplex octaves). All floats print
// as raw long bits (hex) so comparison is bit-exact, no formatting risk.
public class NoiseOracle {
    static String bits(double[] a) {
        StringBuilder sb = new StringBuilder();
        sb.append(a.length);
        for (double v : a) sb.append(' ').append(Long.toHexString(Double.doubleToRawLongBits(v)));
        return sb.toString();
    }
    public static void main(String[] args) throws Exception {
        String mode = args[0];
        long seed = Long.parseLong(args[1]);
        Random r = new Random(seed);
        if (mode.equals("oct")) {
            int count = Integer.parseInt(args[2]);
            int x = Integer.parseInt(args[3]), y = Integer.parseInt(args[4]), z = Integer.parseInt(args[5]);
            int xs = Integer.parseInt(args[6]), ys = Integer.parseInt(args[7]), zs = Integer.parseInt(args[8]);
            double sx = Double.parseDouble(args[9]), sy = Double.parseDouble(args[10]), sz = Double.parseDouble(args[11]);
            Class<?> k = Class.forName("awk");
            Object gen = k.getDeclaredConstructor(Random.class, int.class).newInstance(r, count);
            Method m = null;
            for (Method mm : k.getMethods()) {
                if (mm.getParameterTypes().length == 10) { m = mm; break; }
            }
            m.setAccessible(true);
            double[] out = (double[]) m.invoke(gen, null, x, y, z, xs, ys, zs, sx, sy, sz);
            System.out.println("oct=" + bits(out));
        } else if (mode.equals("oct2")) {
            int count = Integer.parseInt(args[2]);
            int x = Integer.parseInt(args[3]), z = Integer.parseInt(args[4]);
            int xs = Integer.parseInt(args[5]), zs = Integer.parseInt(args[6]);
            double sx = Double.parseDouble(args[7]), sz = Double.parseDouble(args[8]);
            Class<?> k = Class.forName("awk");
            Object gen = k.getDeclaredConstructor(Random.class, int.class).newInstance(r, count);
            Method m = null;
            for (Method mm : k.getMethods()) {
                if (mm.getParameterTypes().length == 8) { m = mm; break; }
            }
            m.setAccessible(true);
            double[] out = (double[]) m.invoke(gen, null, x, z, xs, zs, sx, sz, 0.0);
            System.out.println("oct2=" + bits(out));
        } else if (mode.equals("simplex")) {
            int count = Integer.parseInt(args[2]);
            double x = Double.parseDouble(args[3]), z = Double.parseDouble(args[4]);
            Class<?> k = Class.forName("awl");
            Object gen = k.getDeclaredConstructor(Random.class, int.class).newInstance(r, count);
            Method m = k.getDeclaredMethod("a", double.class, double.class);
            m.setAccessible(true);
            double v = (Double) m.invoke(gen, x, z);
            System.out.println("simplex=" + Long.toHexString(Double.doubleToRawLongBits(v)));
        } else if (mode.equals("sgrid")) {
            int count = Integer.parseInt(args[2]);
            double x = Double.parseDouble(args[3]), z = Double.parseDouble(args[4]);
            int xs = Integer.parseInt(args[5]), zs = Integer.parseInt(args[6]);
            double sx = Double.parseDouble(args[7]), sz = Double.parseDouble(args[8]);
            double fm = Double.parseDouble(args[9]), am = Double.parseDouble(args[10]);
            Class<?> k = Class.forName("awl");
            Object gen = k.getDeclaredConstructor(Random.class, int.class).newInstance(r, count);
            Method m = null;
            for (Method mm : k.getMethods()) {
                if (mm.getParameterTypes().length == 9) { m = mm; break; }
            }
            m.setAccessible(true);
            double[] out = (double[]) m.invoke(gen, null, x, z, xs, zs, sx, sz, fm, am);
            System.out.println("sgrid=" + bits(out));
        } else {
            throw new RuntimeException("unknown mode " + mode);
        }
    }
}
