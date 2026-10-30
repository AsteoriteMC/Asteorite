import java.util.Random;
public class DD999 {
  public static void main(String[] a) {
    Random r = new Random(999L);
    System.out.println("layers=" + (r.nextInt(4)+4));
    for (int i = 0; i < 6; i++) System.out.println("D"+i+"="+r.nextDouble());
  }
}
