class trilio::tripleo::horizon (
  $step = lookup('step'),
) {
  if $step >= 5 {
    # Trilio
    include ::trilio::horizon
  }
}
