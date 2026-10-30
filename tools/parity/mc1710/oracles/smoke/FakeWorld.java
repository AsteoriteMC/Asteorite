import java.io.File;
import java.util.HashMap;
import java.util.Map;

public class FakeWorld extends ahb {
    static { aji.p(); } // MUST run before any ajn/ahu touch (ajn fields snapshot registry at clinit)
    private final Map<String, aji> blocks = new HashMap<String, aji>();
    private final Map<String, Integer> metas = new HashMap<String, Integer>();
    private final aib chunkManager;
    private int entities = 0;

    static String key(int x, int y, int z) { return x + "," + y + "," + z; }

    public FakeWorld(azc h, String name, aqo p, ahj s, qi prof, long seed) {
        super(h, name, p, s, prof);
        this.chunkManager = new aib(seed, ahm.b);
    }

    // --- abstract impls ---
    protected apu j() { return null; }
    protected int p() { return 0; }
    public sa a(int id) { return null; }

    // --- chunk manager without real chunks ---
    public aib v() { return this.chunkManager; }

    // --- block storage (HashMap) ---
    public aji a(int x, int y, int z) {
        aji b = blocks.get(key(x, y, z));
        if (b != null) return b;
        if (y >= 64) return aji.e(0);
        if (y == 63) return aji.e(2);
        if (y >= 60) return aji.e(3);
        return aji.e(1);
    }
    private void put(int x, int y, int z, aji b, int meta) {
        blocks.put(key(x, y, z), b);
        metas.put(key(x, y, z), Integer.valueOf(meta));
    }
    public int e(int x, int y, int z) {
        Integer m = metas.get(key(x, y, z));
        return m == null ? 0 : m.intValue();
    }
    public boolean d(int x, int y, int z, aji b, int meta, int flags) { put(x, y, z, b, meta); return true; }
    public boolean b(int x, int y, int z, aji b) { put(x, y, z, b, 0); return true; }
    public boolean a(int x, int y, int z, aji b) { put(x, y, z, b, 0); return true; }
    public void a(int x, int y, int z, aji b, int meta) { put(x, y, z, b, meta); }
    public void a(int x, int y, int z, aji b, int meta, int flags) { put(x, y, z, b, meta); }
    public void b(int x, int y, int z, aji b, int meta, int flags) { put(x, y, z, b, meta); }
    public void c(int x, int y, int z, aji b, int meta, int flags) { put(x, y, z, b, meta); }
    public boolean a(aji b, int x, int y, int z, boolean b5, int i6, sa e, add it) { put(x, y, z, b, 0); return true; }
    // notifiers -> no-op
    public void c(int x, int y, int z, aji b) {}
    public void d(int x, int y, int z, aji b) {}
    public void b(int x, int y, int z, aji b, int i) {}
    public void e(int x, int y, int z, aji b) {}
    public void f(int x, int y, int z, aji b) {}

    // --- entities / tiles ---
    public boolean d(sa e) { entities++; return true; }
    public int countEntities() { return entities; }
    public aor o(int x, int y, int z) { return null; }
    public void a(int x, int y, int z, aor te) {}

    // --- terrain queries: flat plains, ground top at 63/64 ---
    public boolean i(int x, int y, int z) { return true; }
    public int h(int x, int z) { return 64; }
    public int i(int x, int z) { return 64; }
    public ahu a(int x, int z) { return this.chunkManager.a(x, z); }

    public int countBlocks() { return blocks.size(); }
}
