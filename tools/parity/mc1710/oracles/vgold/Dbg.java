import java.lang.reflect.*;
import java.util.*;
public class Dbg {
  public static void main(String[] args) throws Exception {
    Class<?> ahb = Class.forName("ahb");
    for (Field ff : ahb.getDeclaredFields()) {
      if (ff.getType().getName().equals("aqo")) {
        System.out.println("FOUND provider field: " + ff.getName() + " mods=" + Modifier.toString(ff.getModifiers()));
      }
    }
    Class<?> fp = Class.forName("VGold$FakeProvider");
    System.out.println("FakeProvider: " + fp + " superclass=" + fp.getSuperclass().getName());
    Object prov = fp.getDeclaredConstructor().newInstance();
    System.out.println("provider inst: " + prov);
  }
}
