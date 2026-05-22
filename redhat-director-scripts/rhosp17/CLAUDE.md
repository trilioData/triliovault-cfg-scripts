# RHOSP 17 Deployment Scripts

## Overview
Deployment scripts for TrilioVault (T4O) on Red Hat OpenStack Platform 17.1 (Wallaby release).
RHOSP 17 uses TripleO for deployment — services are configured via Puppet manifests and orchestrated via Heat templates.

Reference: https://docs.redhat.com/en/documentation/red_hat_openstack_platform/17.1/html/installing_and_managing_red_hat_openstack_platform_with_director/index

## Directory Structure

```
rhosp17/
├── environments/                   # Heat environment files (deployment parameters)
│   ├── trilio_env.yaml             # Main environment — primary entry point
│   ├── trilio_defaults.yaml        # Default parameter values
│   ├── trilio_endpoint_data.yaml   # Service endpoint config
│   ├── endpoint_map.yaml           # Full endpoint map (generated)
│   ├── trilio_nfs_map.yaml         # NFS backup target mappings
│   └── trilio_env_tls_*.yaml       # TLS variant environments
├── puppet/trilio/                  # Puppet module for TrilioVault
│   ├── manifests/                  # Puppet manifests (.pp)
│   │   ├── init.pp                 # Module entry point
│   │   ├── config.pp               # Shared configuration
│   │   ├── wlmapi.pp               # Workload Manager API service
│   │   ├── dmapi.pp                # DataMover API service
│   │   ├── contego.pp              # DataMover (contego) service
│   │   ├── horizon.pp              # Horizon plugin
│   │   └── tripleo/                # TripleO-specific integration manifests
│   │       ├── api.pp
│   │       ├── keystone.pp         # Keystone endpoint/service registration
│   │       ├── mysql_wlmapi.pp     # WLM database
│   │       └── mysql_dmapi.pp      # DMAPI database
│   ├── templates/                  # ERB config file templates
│   │   ├── triliovault_wlm_conf.erb
│   │   ├── triliovault_datamover_conf.erb
│   │   ├── triliovault_datamover_api_conf.erb (dmapi.conf)
│   │   ├── api_paste_ini.erb
│   │   ├── local_settings.erb      # Horizon plugin settings
│   │   └── *.erb                   # Other service config templates
│   ├── files/                      # Static files bundled into the module
│   │   ├── tvault_*.py             # Horizon plugin static files
│   │   └── *.pem                   # S3 certificates
│   └── spec/                       # Puppet unit tests (rspec-puppet)
├── services/                       # Heat service templates (yaml)
│   ├── triliovault-wlm-api.yaml
│   ├── triliovault-datamover-api.yaml
│   ├── triliovault-datamover.yaml
│   └── triliovault-horizon.yaml
└── scripts/                        # Utility scripts
    ├── generate_endpoint_map.sh    # Generate endpoint_map.yaml
    ├── prepare_trilio_images.sh    # Stage container images
    ├── generate_passwords.sh       # Create random service passwords
    └── create_wlm_ids_conf.sh      # Generate WLM IDs config
```

## Technology Stack
- **Puppet**: Primary configuration management language (`.pp` manifests, `.erb` templates)
- **Heat**: OpenStack Orchestration for service lifecycle management (`.yaml` templates)
- **TripleO**: OpenStack-on-OpenStack deployment pattern; `puppet/trilio/manifests/tripleo/` has TripleO-specific classes
- **ERB**: Ruby embedded templating used inside Puppet for config files

## Key Conventions

### Puppet Manifests
- Each T4O service has its own manifest: `wlmapi.pp`, `dmapi.pp`, `contego.pp`, `horizon.pp`
- TripleO integration lives in `manifests/tripleo/` — these classes are called by Heat
- ERB templates in `templates/` are referenced from manifests via `template()` or `epp()`
- Static files in `files/` are served via `puppet:///modules/trilio/`

### Heat Service Templates
- Each YAML in `services/` defines a single composable service in TripleO terms
- Services reference the Puppet manifest via `PuppetServiceName` parameter
- Deployed by passing `services/` YAMLs in the TripleO `--environment` flags

### Environment Files
- `trilio_env.yaml` is the main file — always included in deployment
- TLS variants (`trilio_env_tls_*.yaml`) are included additionally for TLS deployments
- `trilio_nfs_map.yaml` defines per-project NFS mounts for backup targets

### Deployment Flow
1. Run `scripts/prepare_trilio_images.sh` — pull and tag images
2. Run `scripts/generate_passwords.sh` — create password environment file
3. Include `environments/trilio_env.yaml` (and TLS env if needed) in `openstack overcloud deploy`
4. TripleO calls Heat → Heat calls Puppet classes → Puppet configures services

## T4O Installation Guide
https://docs.trilio.io/openstack/deployment/installing-on-rhosp/rhosp17
