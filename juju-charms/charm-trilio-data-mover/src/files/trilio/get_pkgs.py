import cryptography
import libvirtmod
import cffi
import _cffi_backend
import contego

print(list(cryptography.__path__)[0])
print(libvirtmod.__file__)
print(list(cffi.__path__)[0])
print(_cffi_backend.__file__)
print(list(contego.__path__)[0])
