import java.lang.reflect.*;
import java.util.Random;
public class TerrainOracle {
    static class World extends ahb {
        aib manager; ays info; long seed;
        World() { super(null,"oracle",(ahj)null,(aqo)null,null); }
        protected apu j() { return null; }
        protected int p() { return 0; }
        public sa a(int id) { return null; }
        public aib v() { return manager; }
        public ays N() { return info; }
        public long H() { return seed; }
    }
    static void digest(String stage, aji[] blocks, byte[] meta) {
        long bc=0, mc=0;
        java.util.Map<Integer,Integer> counts=new java.util.TreeMap<>();
        for (aji b: blocks) { int id=b==null?0:aji.b(b); bc=bc*31+id; counts.put(id,counts.getOrDefault(id,0)+1); }
        for (byte m: meta) mc=mc*31+(m&255);
        System.out.println(stage+" blocks="+bc+" meta="+mc);
        System.out.println(counts);
    }
    public static void main(String[] args) throws Exception {
        aji.p();
        if(args[0].equals("forest")) {
            aib manager=new aib(42,ahm.b);
            for(int z=0;z<100;z++) for(int x=0;x<100;x++)
                if(manager.a(x*16+16,z*16+16).ay==29) { System.out.println(x+","+z); return; }
            return;
        }
        long seed=Long.parseLong(args[0]);
        int cx=Integer.parseInt(args[1]), cz=Integer.parseInt(args[2]);
        ahj settings=new ahj(seed, ahk.a(0), false, false, ahm.b);
        Field uf=sun.misc.Unsafe.class.getDeclaredField("theUnsafe"); uf.setAccessible(true);
        World world=(World)((sun.misc.Unsafe)uf.get(null)).allocateInstance(World.class);
        world.seed=seed; world.manager=new aib(seed,ahm.b); world.info=new ays(settings,"oracle");
        aqz gen=new aqz(world,seed,false);
        Field random=aqz.class.getDeclaredField("i"); random.setAccessible(true);
        ((Random)random.get(gen)).setSeed((long)cx*341873128712L+(long)cz*132897987541L);
        aji[] blocks=new aji[65536]; byte[] meta=new byte[65536];
        gen.a(cx,cz,blocks);
        ahu[] biomes=world.v().b(null,cx*16,cz*16,16,16);
        gen.a(cx,cz,blocks,meta,biomes);
        digest("surface",blocks,meta);
        for(String field:new String[]{"t","y"}) {
            Field f=aqz.class.getDeclaredField(field); f.setAccessible(true);
            ((aqx)f.get(gen)).a(gen,world,cx,cz,blocks);
        }
        digest("carved",blocks,meta);
        System.out.println("biome0="+biomes[0].ay+" population="+world.v().a(cx*16+16,cz*16+16).ay);
    }
}
