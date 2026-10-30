import java.util.Random;
public class LakeDbg {
  public static void main(String[] a) {
    Random r = new Random(42L);
    long l = r.nextLong() / 2L * 2L + 1L;
    long l1 = r.nextLong() / 2L * 2L + 1L;
    r.setSeed((long) 0 * l + (long) 0 * l1 ^ 42L);
    r.nextInt(4); r.nextInt(8);
    int inner = r.nextInt(248);
    int wy = r.nextInt(inner + 8);
    int wx = r.nextInt(16) + 8, wz = r.nextInt(16) + 8;
    int layers = r.nextInt(4) + 4;
    System.out.println("layers=" + layers + " at " + wx + "," + wy + "," + wz);
    for (int i = 0; i < 2; i++) {
      double rx = r.nextDouble() * 6.0 + 3.0;
      double ry = r.nextDouble() * 4.0 + 2.0;
      double rz = r.nextDouble() * 6.0 + 3.0;
      double ox = r.nextDouble() * (16.0 - rx - 2.0) + 1.0 + rx / 2.0;
      double oy = r.nextDouble() * (8.0 - ry - 4.0) + 1.0 + ry / 2.0;
      double oz = r.nextDouble() * (16.0 - rz - 2.0) + 1.0 + rz / 2.0;
      System.out.println("L" + i + " rx=" + rx + " ry=" + ry + " rz=" + rz + " ox=" + ox + " oy=" + oy + " oz=" + oz);
    }
  }
}
