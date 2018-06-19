class tripleo::profile::base::trilio (
  $step = hiera('step'),
) {
  if $step >= 5 {
    # Trilio
    include ::trilio
  }
}
