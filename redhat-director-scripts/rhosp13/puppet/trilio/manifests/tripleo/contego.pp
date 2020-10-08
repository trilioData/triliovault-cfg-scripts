class trilio::tripleo::contego (
  $step = hiera('step'),
) {
  if $step >= 5 {
    # Trilio
    include ::trilio::contego
  }
}
