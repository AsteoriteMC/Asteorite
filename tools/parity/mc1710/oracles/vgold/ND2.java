import java.util.Random;
public class ND2 {
  public static void main(String[] a) {
    Random r = new Random(999L);
    for (int i = 0; i < 8; i++) System.out.println(r.nextDouble());
  }
}
