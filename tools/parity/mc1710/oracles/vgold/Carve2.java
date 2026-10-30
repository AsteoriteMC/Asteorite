import java.util.Random;
public class Carve2 {
  public static void main(String[] args) {
    Random rand = new Random(999L);
    int layers = rand.nextInt(4) + 4;
    boolean[] hollow = new boolean[2048];
    for (int l = 0; l < layers; l++) {
      double rx = rand.nextDouble() * 6.0 + 3.0;
      double ry = rand.nextDouble() * 4.0 + 2.0;
      double rz = rand.nextDouble() * 6.0 + 3.0;
      double ox = rand.nextDouble() * (16.0 - rx - 2.0) + 1.0 + rx / 2.0;
      double oy = rand.nextDouble() * (8.0 - ry - 4.0) + 1.0 + ry / 2.0;
      double oz = rand.nextDouble() * (16.0 - rz - 2.0) + 1.0 + rz / 2.0;
      for (int i = 1; i < 15; i++) for (int k = 1; k < 15; k++) for (int j = 1; j < 7; j++) {
        double dx = ((double) i - ox) / (rx / 2.0);
        double dy = ((double) j - oy) / (ry / 2.0);
        double dz = ((double) k - oz) / (rz / 2.0);
        if (dx * dx + dy * dy + dz * dz < 1.0) hollow[(i * 16 + k) * 8 + j] = true;
      }
    }
    int n = 0; long chk = 0;
    for (int i = 0; i < 2048; i++) if (hollow[i]) { n++; chk = chk * 31 + i; }
    System.out.println("layers=" + layers + " hollow=" + n + " chk=" + chk);
  }
}
