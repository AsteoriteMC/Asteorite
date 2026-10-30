import java.util.Random;
public class SeqD {
  public static void main(String[] a) {
    Random r = new Random(42L);
    long l = r.nextLong() / 2L * 2L + 1L;
    long l1 = r.nextLong() / 2L * 2L + 1L;
    r.setSeed((long) 0 * l + (long) 0 * l1 ^ 42L);
    r.nextInt(4); r.nextInt(8);
    int inner = r.nextInt(248);
    r.nextInt(inner + 8); r.nextInt(16); r.nextInt(16);
    int layers = r.nextInt(4);
    System.out.println("layers=" + layers);
    for (int i = 0; i < layers * 6; i++) System.out.println("D" + i + "=" + r.nextDouble());
  }
}
