[DEFAULT]
compute_driver = libvirt.LibvirtDriver
cpu_allocation_ratio = 3
default_ephemeral_format = ext4
disk_allocation_ratio = 1
instance_usage_audit = true
instance_usage_audit_period = hour
log_config_append = /etc/nova/logging.conf
metadata_listen_port = 8775
metadata_workers = 1
my_ip = 0.0.0.0
osapi_compute_listen = 0.0.0.0
osapi_compute_listen_port = 8774
osapi_compute_workers = 1
ram_allocation_ratio = 1
resume_guests_state_on_host_boot = true
state_path = /var/lib/nova
transport_url = rabbit://nova:password@rabbitmq-rabbitmq-0.rabbitmq.openstack.svc.cluster.local:5672,nova:password@rabbitmq-rabbitmq-1.rabbitmq.openstack.svc.cluster.local:5672/nova
[cache]
backend = dogpile.cache.memcached
enabled = true
memcache_servers = memcached.openstack.svc.cluster.local:11211
[cinder]
catalog_info = volumev3::internalURL
[conductor]
workers = 1
[glance]
api_servers = http://glance-api.openstack.svc.cluster.local:9292
num_retries = 3
[ironic]
api_endpoint = http://ironic-api.openstack.svc.cluster.local:6385
auth_type = password
auth_url = http://keystone-api.openstack.svc.cluster.local:5000/v3
auth_version = v3
memcache_secret_key = 7jLMUQiFUMTtTFqR3Nln9ahml7KgxCA5kkuBfGE7AHDBub3jM48jNDLmuKJuBeO4
memcache_servers = memcached.openstack.svc.cluster.local:11211
password = password
project_domain_name = service
project_name = service
region_name = RegionOne
user_domain_name = service
username = ironic
[keystone_authtoken]
auth_type = password
auth_uri = http://keystone-api.openstack.svc.cluster.local:5000/v3
auth_url = http://keystone-api.openstack.svc.cluster.local:5000/v3
auth_version = v3
memcache_secret_key = JrcNrm8yNFAkzthUDR68xDhKVlMzhQqM4ndkCVAFbCj4v1g91dWT03q3E5jr00AR
memcache_security_strategy = ENCRYPT
memcached_servers = memcached.openstack.svc.cluster.local:11211
password = password
project_domain_name = service
project_name = service
region_name = RegionOne
service_token_roles = service
service_token_roles_required = true
service_type = compute
user_domain_name = service
username = nova
[libvirt]
connection_uri = qemu+unix:///system?socket=/run/libvirt/libvirt-sock
disk_cachemodes = network=writeback
hw_disk_discard = unmap
images_rbd_ceph_conf = /etc/ceph/ceph.conf
images_rbd_pool = vms
images_type = qcow2
rbd_secret_uuid = 457eb676-33da-42ec-9a8c-9293d545c337
rbd_user = cinder
[neutron]
auth_type = password
auth_url = http://keystone-api.openstack.svc.cluster.local:5000/v3
auth_version = v3
metadata_proxy_shared_secret = password
password = password
project_domain_name = service
project_name = service
region_name = RegionOne
service_metadata_proxy = true
url = http://neutron-server.openstack.svc.cluster.local:9696
user_domain_name = service
username = neutron
[notifications]
notify_on_state_change = vm_and_task_state
[oslo_concurrency]
lock_path = /var/lib/nova/tmp
[oslo_messaging_notifications]
driver = messagingv2
[oslo_messaging_rabbit]
rabbit_ha_queues = true
[oslo_middleware]
enable_proxy_headers_parsing = true
[oslo_policy]
policy_file = /etc/nova/policy.yaml
[placement]
auth_type = password
auth_url = http://keystone-api.openstack.svc.cluster.local:5000/v3
auth_version = v3
password = password
project_domain_name = service
project_name = service
region_name = RegionOne
user_domain_name = service
username = placement
[scheduler]
discover_hosts_in_cells_interval = -1
max_attempts = 10
workers = 1
[service_user]
auth_type = password
auth_url = http://keystone-api.openstack.svc.cluster.local:5000/v3
password = password
project_domain_name = service
project_name = service
region_name = RegionOne
send_service_user_token = true
user_domain_name = service
username = nova
[spice]
html5proxy_host = 0.0.0.0
server_listen = 0.0.0.0
[upgrade_levels]
compute = auto
[vnc]
auth_schemes = none
enabled = true
novncproxy_base_url = http://novncproxy.openstack.svc.cluster.local/vnc_auto.html
novncproxy_host = 0.0.0.0
novncproxy_port = 6080
server_listen = 0.0.0.0
[wsgi]
api_paste_config = /etc/nova/api-paste.ini
