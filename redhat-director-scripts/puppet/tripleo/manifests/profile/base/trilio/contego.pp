class tripleo::profile::base::trilio::contego (
  $step = hiera('step'),
) {
  if $step >= 5 {
    # Trilio
    include ::trilio::contego
  }
}
