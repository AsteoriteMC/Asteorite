import java.util.Random;
public class Seq {
  static Random r;
  static void ni(String n, int bound) { System.out.println(n + "=" + r.nextInt(bound)); }
  public static void main(String[] a) {
    r = new Random(42L);
    long l = r.nextLong() / 2L * 2L + 1L;
    long l1 = r.nextLong() / 2L * 2L + 1L;
    r.setSeed((long) 0 * l + (long) 0 * l1 ^ 42L);
    ni("waterGate", 4);
    ni("lavaGate", 8);
    int inner = r.nextInt(248); System.out.println("inner=" + inner);
    System.out.println("outerY=" + r.nextInt(inner + 8));
    System.out.println("lx=" + r.nextInt(16));
    System.out.println("lz=" + r.nextInt(16));
    int layers = r.nextInt(4) + 4; System.out.println("layers=" + layers);
    for (int i = 0; i < layers * 6; i++) System.out.println("d" + i + "=" + r.nextDouble());
    for (int d = 0; d < 8; d++) {
      System.out.println("iw=" + (r.nextInt(2)+2) + " il=" + (r.nextInt(2)+2));
      System.out.println("dpos=" + r.nextInt(16) + "," + r.nextInt(256) + "," + r.nextInt(16));
    }
    System.out.println("dirt=" + r.nextInt(16) + "," + r.nextInt(256) + "," + r.nextInt(16));
  }
}
