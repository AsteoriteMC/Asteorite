import java.util.Random;

// Parity oracle for tools/parity rng area (pure JDK, no MC jar).
// Mirrors worldgen_dump section 1 ("fresh-stream first draws"): every value
// comes from a FRESH Random(seed), one stream per line group.
public class RndProbe {
    public static void main(String[] a) {
        long seed = Long.parseLong(a[0]);
        Random r0 = new Random(seed);
        System.out.println("nextInt=" + r0.nextInt());
        Random r1 = new Random(seed);
        System.out.println("nextLong=" + r1.nextLong());
        Random r2 = new Random(seed);
        System.out.println("nextInt(100)=" + r2.nextInt(100) + "," + r2.nextInt(100) + "," + r2.nextInt(100));
        Random r3 = new Random(seed);
        System.out.println("nextFloat=" + r3.nextFloat() + " nextDouble=" + r3.nextDouble());
        Random r4 = new Random(seed);
        byte[] b = new byte[8];
        r4.nextBytes(b);
        StringBuilder sb = new StringBuilder("nextBytes=");
        for (byte x : b) sb.append(String.format("%02x", x & 0xff));
        System.out.println(sb.toString());
        Random r5 = new Random(seed);
        System.out.println("nextGaussian=" + r5.nextGaussian() + ", " + r5.nextGaussian());
    }
}
