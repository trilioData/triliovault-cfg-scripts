class trilio::tripleo::contego (
  $step = lookup('step'),
) {
  if $step >= 5 {
    # Trilio
    include ::trilio::contego
  }
}
