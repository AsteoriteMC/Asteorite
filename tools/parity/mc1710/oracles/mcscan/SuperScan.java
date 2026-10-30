import java.io.*;
import java.nio.file.*;
import java.util.*;
public class SuperScan {
  static class Reader { byte[] b; int p; Reader(byte[] b){this.b=b;} int u1(){return b[p++]&255;} int u2(){return (u1()<<8)|u1();} }
  public static void main(String[] a) throws Exception {
    File dir = new File(a[0]);
    File[] fs = dir.listFiles((d,n)->n.endsWith(".class"));
    Arrays.sort(fs, Comparator.comparing(File::getName));
    for (File f : fs) {
      try {
        byte[] b = Files.readAllBytes(f.toPath());
        Reader r = new Reader(b);
        if (r.u1()!=0xCA||r.u1()!=0xFE||r.u1()!=0xBA||r.u1()!=0xBE) continue;
        r.u2(); r.u2();
        int cpCount = r.u2();
        Object[] cp = new Object[cpCount];
        for (int i=1;i<cpCount;i++) {
          int tag=r.u1();
          switch(tag){
            case 1: int len=r.u2(); String s=new String(b,r.p,len,"UTF-8"); r.p+=len; cp[i]=s; break;
            case 3: case 4: r.p+=4; break;
            case 5: case 6: r.p+=8; i++; break;
            case 7: case 8: case 16: cp[i]=r.u2(); break;
            case 9: case 10: case 11: case 12: case 18: r.p+=4; break;
            case 15: r.p+=3; break;
            default: throw new RuntimeException("tag "+tag+" in "+f.getName());
          }
        }
        r.u2(); int thisC=r.u2(); int superC=r.u2();
        String tn = thisC==0?"-":(String)cp[(Integer)cp[thisC]];
        String sn = superC==0?"-":(String)cp[(Integer)cp[superC]];
        // read interfaces count + fields/methods skip? not needed
        System.out.println(tn.replace('/','.')+" "+sn.replace('/','.'));
      } catch (Exception e) { System.out.println("ERR "+f.getName()+" "+e.getMessage()); }
    }
  }
}
