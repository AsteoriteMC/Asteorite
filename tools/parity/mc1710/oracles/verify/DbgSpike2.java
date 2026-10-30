import java.lang.reflect.*;
public class DbgSpike2 {
    public static void main(String[] args) throws Exception {
        Class<?> AJI = Class.forName("aji");
        Class<?> AJN = Class.forName("ajn");
        int nAji = 0;
        for (Field f : AJN.getDeclaredFields()) {
            if (f.getType() == AJI) {
                nAji++;
                if (nAji <= 8) {
                    f.setAccessible(true);
                    System.out.println("field " + f.getName() + " = " + f.get(null));
                }
            }
        }
        System.out.println("total aji fields=" + nAji);
        // now run p() and recount non-null
        Method reg = null;
        for (Method m : AJI.getDeclaredMethods())
            if (m.getName().equals("p") && m.getParameterTypes().length == 0) reg = m;
        reg.setAccessible(true);
        reg.invoke(null);
        int nn = 0;
        for (Field f : AJN.getDeclaredFields()) {
            if (f.getType() == AJI) {
                f.setAccessible(true);
                if (f.get(null) != null) nn++;
            }
        }
        System.out.println("non-null after p()=" + nn);
    }
}
