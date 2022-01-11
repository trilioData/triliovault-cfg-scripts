Facter.add(:which_cryptography) do
  setcode do
  result = Facter::Core::Execution::exec("python -c 'import cryptography;print cryptography.__path__[0]'")
  result
  end
end

Facter.add(:which_libvirt) do
  setcode do
  result = Facter::Core::Execution::exec("python -c 'import libvirtmod;print libvirtmod.__file__'")
  result
  end
end

Facter.add(:which_cffi) do
  setcode do
  result = Facter::Core::Execution::exec("python -c 'import cffi;print cffi.__path__[0]'")
  result
  end
end

Facter.add(:which_cffi_so) do
  setcode do
  result = Facter::Core::Execution::exec("python -c 'import _cffi_backend;print _cffi_backend.__file__'")
  result
  end
end


Facter.add(:is_cpu_exists) do
  setcode do
  Facter::Core::Execution::exec("/usr/bin/test -d /sys/fs/cgroup/cpu")
  $?.exitstatus == 0
  end
end

Facter.add(:is_blkio_exists) do
  setcode do
  Facter::Core::Execution::exec("/usr/bin/test -d /sys/fs/cgroup/blkio")
  $?.exitstatus == 0
  end
end

Facter.add(:is_trilio_exists) do
  setcode do
  Facter::Core::Execution::exec("/usr/bin/test -d /sys/fs/cgroup/cpu/trilio")
  $?.exitstatus == 0
  end
end

contego_version = %x{/bin/rpm -q --queryformat "%{VERSION}" tvault-contego}

Facter.add(:contego_installed_version) do
    setcode do
        contego_version
    end
end
