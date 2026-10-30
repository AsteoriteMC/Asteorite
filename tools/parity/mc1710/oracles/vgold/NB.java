import java.util.Random;
public class NB {
  public static void main(String[] a) {
    Random r = new Random(42L);
    for (int i = 0; i < 8; i++) System.out.println(r.nextInt(100));
  }
}
