Facter.add(:tvault_version) do
  setcode do
  version = Facter::Core::Execution::exec("/usr/bin/curl -s http://192.168.1.26:8081/packages/ | grep tvault-contego-[0-9] | awk -F 'tvault-contego-' '{print $2}' | cut -c-5")
  version
  end
end
