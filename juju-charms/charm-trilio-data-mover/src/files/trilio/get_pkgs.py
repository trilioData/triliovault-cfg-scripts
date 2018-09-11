import cryptography
import libvirtmod
import cffi
import _cffi_backend

print(cryptography.__path__[0])
print(libvirtmod.__file__)
print(cffi.__path__[0])
print(_cffi_backend.__file__)
