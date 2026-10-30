import java.util.Random;
public class Prefix {
  public static void main(String[] a) {
    Random r = new Random(0L);
    r.setSeed(42L);
    long l = r.nextLong() / 2L * 2L + 1L;
    long l1 = r.nextLong() / 2L * 2L + 1L;
    r.setSeed((long) 0 * l + (long) 0 * l1 ^ 42L);
    System.out.print("wg=" + r.nextInt(4));
    System.out.print(" lg=" + r.nextInt(8));
    int inner = r.nextInt(248);
    int wy = r.nextInt(inner + 8);
    int wx = r.nextInt(16), wz = r.nextInt(16);
    int layers = r.nextInt(4);
    int dbls = 0;
    for (int i = 0; i < (layers + 4) * 6; i++) { r.nextDouble(); dbls++; }
    for (int i = 0; i < 8; i++) { r.nextInt(2); r.nextInt(2); r.nextInt(16); r.nextInt(256); r.nextInt(16); }
    System.out.print(" inner=" + inner + " y=" + wy + " x=" + wx + " z=" + wz + " layers=" + layers + " dbls=" + dbls);
    System.out.println(" dirt=" + r.nextInt(16) + "," + r.nextInt(256) + "," + r.nextInt(16));
  }
}
