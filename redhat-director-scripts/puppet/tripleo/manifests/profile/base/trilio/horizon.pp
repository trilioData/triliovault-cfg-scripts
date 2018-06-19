class tripleo::profile::base::trilio::horizon (
  $step = hiera('step'),
) {
  if $step >= 5 {
    # Trilio
    include ::trilio::horizon
  }
}
