## The shim a user writes for P18: same names, switch points added.
import ./fakeatomics as fa
import nimlinear/intercept
interceptAtomics(fa, writes = [store, fetchAdd], reads = [load])
