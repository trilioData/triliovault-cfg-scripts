class trilio::tripleo::api (
  $step = hiera('step'),
) {
  if $step >= 5 {
    # Trilio
    include ::trilio::api
  }
}
