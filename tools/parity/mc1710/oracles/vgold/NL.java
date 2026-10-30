import java.util.Random;
public class NL {
  public static void main(String[] a) {
    Random r = new Random(42L);
    System.out.println("nextLong1=" + r.nextLong());
    System.out.println("nextLong2=" + r.nextLong());
  }
}
