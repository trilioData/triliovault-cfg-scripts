class trilio::tripleo::horizon (
  $step = hiera('step'),
) {
  if $step >= 5 {
    # Trilio
    include ::trilio::horizon
  }
}
