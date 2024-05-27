# Copyright 2017 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.
#
# == Class: tripleo::profile::pacemaker::cinder::volume_bundle
#
# Containerized Redis Pacemaker HA profile for tripleo
#
# === Parameters
#
# [*cinder_volume_docker_image*]
#   (Optional) The docker image to use for creating the pacemaker bundle
#   Defaults to hiera('tripleo::profile::pacemaker::cinder::volume_bundle::cinder_docker_image', undef)
#
# [*docker_volumes*]
#   (Optional) The list of volumes to be mounted in the docker container
#   Defaults to []
#
# [*docker_environment*]
#   (Optional) List or Hash of environment variables set in the docker container
#   Defaults to {'KOLLA_CONFIG_STRATEGY' => 'COPY_ALWAYS'}
#
# [*pcs_tries*]
#   (Optional) The number of times pcs commands should be retried.
#   Defaults to hiera('pcs_tries', 20)
#
# [*bootstrap_node*]
#   (Optional) The hostname of the node responsible for bootstrapping tasks
#   Defaults to hiera('redis_short_bootstrap_node_name')
#
# [*step*]
#   (Optional) The current step in deployment. See tripleo-heat-templates
#   for more details.
#   Defaults to hiera('step')
#
# [*container_backend*]
#   (optional) Container backend to use when creating the bundle
#   Defaults to 'docker'
#
# [*log_driver*]
#   (optional) Container log driver to use. When set to undef it uses 'k8s-file'
#   when container_cli is set to podman and 'journald' when it is set to docker.
#   Defaults to undef
#
# [*log_file*]
#   (optional) Container log file to use. Only relevant when log_driver is
#   set to 'k8s-file'.
#   Defaults to '/var/log/containers/stdouts/openstack-cinder-volume.log'
#
# [*tls_priorities*]
#   (optional) Sets PCMK_tls_priorities in /etc/sysconfig/pacemaker when set
#   Defaults to hiera('tripleo::pacemaker::tls_priorities', undef)
#
# [*bundle_user*]
#   (optional) Set the --user= switch to be passed to pcmk
#   Defaults to 'root'
#
class trilio::wlmapi::wlm_cron_bundle (
  $bootstrap_node             = hiera('triliovault_wlm_cron_short_bootstrap_node_name'),
  $triliovault_wlm_cron_docker_image = hiera('trilio::wlmapi::wlm_cron.bundle::triliovault_wlm_cron_docker_image', undef),
  $docker_volumes             = [],
  $docker_environment         = {'KOLLA_CONFIG_STRATEGY' => 'COPY_ALWAYS'},
  $pcs_tries                  = hiera('pcs_tries', 20),
  $step                       = Integer(hiera('step')),
  $container_backend          = 'docker',
  $log_driver                 = undef,
  $log_file                   = '/var/log/containers/triliovault-wlm-cron/triliovault-wlm-cron.log',
  $tls_priorities             = hiera('tripleo::pacemaker::tls_priorities', undef),
  $bundle_user                = 'root',
) {
  if $bootstrap_node and $::hostname == downcase($bootstrap_node) {
    $pacemaker_master = true
  } else {
    $pacemaker_master = false
  }

  if $log_driver == undef {
    if hiera('container_cli', 'docker') == 'podman' {
      $log_driver_real = 'k8s-file'
    } else {
      $log_driver_real = 'journald'
    }
  } else {
    $log_driver_real = $log_driver
  }
  if $log_driver_real == 'k8s-file' {
    $log_file_real = " --log-opt path=${log_file}"
  } else {
    $log_file_real = ''
  }

  if $step >= 2 and $pacemaker_master {
    $triliovault_wlm_cron_short_node_names = hiera('triliovault_wlm_cron_short_node_names')

    if (hiera('pacemaker_short_node_names_override', undef)) {
      $pacemaker_short_node_names = hiera('pacemaker_short_node_names_override')
    } else {
      $pacemaker_short_node_names = hiera('pacemaker_short_node_names')
    }

    $pcmk_triliovault_wlm_cron_nodes = intersection($triliovault_wlm_cron_short_node_names, $pacemaker_short_node_names)
    $pcmk_triliovault_wlm_cron_nodes.each |String $node_name| {
      pacemaker::property { "triliovault-wlm-cron-role-${node_name}":
        property => 'triliovault-wlm-cron-role',
        value    => true,
        tries    => $pcs_tries,
        node     => downcase($node_name),
        before   => Pacemaker::Resource::Bundle['triliovault-wlm-cron'],
      }
    }
  }

  if $step >= 5 {
    if $pacemaker_master {
      $docker_vol_arr = delete(any2array($docker_volumes), '').flatten()

      unless empty($docker_vol_arr) {
        $storage_maps = docker_volumes_to_storage_maps($docker_vol_arr, 'triliovault-wlm-cron')
      } else {
        notice('Using fixed list of docker volumes for triliovault_wlm_cron bundle')
        # Default to previous hard-coded list
        $storage_maps = {
          'triliovault-wlm-cron-cfg-files'               => {
            'source-dir' => '/var/lib/kolla/config_files/triliovault_wlm_cron.json',
            'target-dir' => '/var/lib/kolla/config_files/config.json',
            'options'    => 'ro',
          },
          'triliovault-wlm-cron-cfg-data'                => {
            'source-dir' => '/var/lib/config-data/puppet-generated/triliovaultwlmcron/',
            'target-dir' => '/var/lib/kolla/config_files/triliovaultwlmcron',
            'options'    => 'ro',
          },
          'triliovault-wlm-cron-hosts'                   => {
            'source-dir' => '/etc/hosts',
            'target-dir' => '/etc/hosts',
            'options'    => 'ro',
          },
          'triliovault-wlm-cron-localtime'               => {
            'source-dir' => '/etc/localtime',
            'target-dir' => '/etc/localtime',
            'options'    => 'ro',
          },
          'triliovault-wlm-cron-pki-extracted'           => {
            'source-dir' => '/etc/pki/ca-trust/extracted',
            'target-dir' => '/etc/pki/ca-trust/extracted',
            'options'    => 'ro',
          },
          'triliovault-wlm-cron-pki-ca-bundle-crt'       => {
            'source-dir' => '/etc/pki/tls/certs/ca-bundle.crt',
            'target-dir' => '/etc/pki/tls/certs/ca-bundle.crt',
            'options'    => 'ro',
          },
          'triliovault-wlm-cron-pki-ca-bundle-trust-crt' => {
            'source-dir' => '/etc/pki/tls/certs/ca-bundle.trust.crt',
            'target-dir' => '/etc/pki/tls/certs/ca-bundle.trust.crt',
            'options'    => 'ro',
          },
          'triliovault-wlm-cron-pki-cert'                => {
            'source-dir' => '/etc/pki/tls/cert.pem',
            'target-dir' => '/etc/pki/tls/cert.pem',
            'options'    => 'ro',
          },
          'triliovault-wlm-cron-var-log'                 => {
            'source-dir' => '/var/log/containers/triliovault-wlm-cron',
            'target-dir' => '/var/log/triliovault',
            'options'    => 'rw',
          },
        }
      }

      if is_hash($docker_environment) {
        $docker_env = join($docker_environment.map |$index, $value| { "-e ${index}=${value}" }, ' ')
      } else {
        $docker_env_arr = delete(any2array($docker_environment), '').flatten()
        $docker_env = join($docker_env_arr.map |$var| { "-e ${var}" }, ' ')
      }

      if $tls_priorities != undef {
        $tls_priorities_real = " -e PCMK_tls_priorities=${tls_priorities}"
      } else {
        $tls_priorities_real = ''
      }

      pacemaker::resource::bundle { 'triliovault-wlm-cron':
        image             => $triliovault_wlm_cron_docker_image,
        replicas          => 1,
        location_rule     => {
          resource_discovery => 'exclusive',
          score              => 0,
          expression         => ['triliovault-wlm-cron-role eq true'],
        },
        container_options => 'network=host',
        # lint:ignore:140chars
        options           => "--ipc=host --privileged=true --user=${bundle_user} --log-driver=${log_driver_real}${log_file_real} ${docker_env}${tls_priorities_real}",
        # lint:endignore
        run_command       => '/bin/bash /usr/local/bin/kolla_start',
        storage_maps      => $storage_maps,
        container_backend => $container_backend,
      }
    }
  }
}
