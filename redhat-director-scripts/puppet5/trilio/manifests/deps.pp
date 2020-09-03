# == Class: trilio::deps
#
#  trilio anchors and dependency management
#
class trilio::deps {
  # Setup anchors for install, config and service phases of the module.  These
  # anchors allow external modules to hook the begin and end of any of these
  # phases.  Package or service management can also be replaced by ensuring the
  # package is absent or turning off service management and having the
  # replacement depend on the appropriate anchors.  When applicable, end tags
  # should be notified so that subscribers can determine if installation,
  # config or service state changed and act on that if needed.
  anchor { 'trilio::install::begin': }
  -> Package<| tag == 'trilio-package'|>
  ~> anchor { 'trilio::install::end': }
  -> anchor { 'trilio::config::begin': }
  -> trilio_config<||>
  ~> anchor { 'trilio::config::end': }
  -> anchor { 'trilio::db::begin': }
  -> anchor { 'trilio::db::end': }
  ~> anchor { 'trilio::dbsync::begin': }
  -> anchor { 'trilio::dbsync::end': }
  ~> anchor { 'trilio::service::begin': }
  ~> Service<| tag == 'trilio-service' |>
  ~> anchor { 'trilio::service::end': }

  # paste-api.ini config should occur in the config block also.
  Anchor['trilio::config::begin']
  -> Trilio_api_paste_ini<||>
  ~> Anchor['trilio::config::end']

  # all db settings should be applied and all packages should be installed
  # before dbsync starts
  Oslo::Db<||> -> Anchor['trilio::dbsync::begin']

  # policy config should occur in the config block also.
  Anchor['trilio::config::begin']
  -> Openstacklib::Policy::Base<||>
  ~> Anchor['trilio::config::end']

  # Support packages need to be installed in the install phase, but we don't
  # put them in the chain above because we don't want any false dependencies
  # between packages with the trilio-package tag and the trilio-support-package
  # tag.  Note: the package resources here will have a 'before' relationshop on
  # the trilio::install::end anchor.  The line between trilio-support-package and
  # trilio-package should be whether or not trilio services would need to be
  # restarted if the package state was changed.
  Anchor['trilio::install::begin']
  -> Package<| tag == 'trilio-support-package'|>
  -> Anchor['trilio::install::end']

  # Support services need to be started in the service phase, but we don't
  # put them in the chain above because we don't want any false dependencies
  # between them and trilio services. Note: the service resources here will
  # have a 'before' relationshop on the trilio::service::end anchor.
  # The line between trilio-support-service and trilio-service should be
  # whether or not trilio services would need to be restarted if the service
  # state was changed.
  Anchor['trilio::service::begin']
  -> Service<| tag == 'trilio-support-service'|>
  -> Anchor['trilio::service::end']

  # We need openstackclient before marking service end so that trilio
  # will have clients available to create resources. This tag handles the
  # openstackclient but indirectly since the client is not available in
  # all catalogs that don't need the client class (like many spec tests)
  Package<| tag == 'openstack'|>
  ~> Anchor['trilio::service::end']

  # The following resources need to be provisioned after the service is up.
  Anchor['trilio::service::end']
  -> Trilio_type<||>

  # Installation or config changes will always restart services.
  Anchor['trilio::install::end'] ~> Anchor['trilio::service::begin']
  Anchor['trilio::config::end']  ~> Anchor['trilio::service::begin']
}