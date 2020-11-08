class trilio::tripleo::api (
  $step = lookup('step'),
) {
  if $step >= 5 {
    # Trilio
    include ::trilio::api
  }
}
