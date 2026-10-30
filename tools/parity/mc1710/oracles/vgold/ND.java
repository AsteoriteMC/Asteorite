import java.util.Random;
public class ND {
  public static void main(String[] a) {
    Random r = new Random(12345L);
    for (int i = 0; i < 5; i++) System.out.println(r.nextDouble());
  }
}
