import java.util.Random;
public class CarveFill {
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
    // terrain: stone<70 grass 70, base y = 12-4 = 8 (no scan, stone at (4,12,15))
    int ybase = 8, wx = 12, wz = 23;
    int lava = 0;
    int[] yhist = new int[256];
    for (int i = 0; i < 16; i++) for (int k = 0; k < 16; k++) for (int j = 0; j < 8; j++) {
      if (!hollow[(i * 16 + k) * 8 + j]) continue;
      if (j < 4) { lava++; yhist[ybase + j]++; }
    }
    System.out.println("manual lava=" + lava);
    StringBuilder sb = new StringBuilder("yhist=");
    for (int y = 0; y < 256; y++) if (yhist[y] > 0) sb.append(y).append(":").append(yhist[y]).append(" ");
    System.out.println(sb);
  }
}
