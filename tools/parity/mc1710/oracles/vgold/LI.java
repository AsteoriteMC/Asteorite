import java.util.Random;
public class LI {
  public static void main(String[] a) {
    Random r = new Random(999L);
    System.out.println("layers=" + (r.nextInt(4) + 4));
  }
}
