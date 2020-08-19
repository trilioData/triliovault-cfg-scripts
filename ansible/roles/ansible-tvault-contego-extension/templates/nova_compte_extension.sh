#!/bin/sh

"{{virtual_env}}"
xtrace=$(set +o | grep xtrace)
set +o xtrace
file="{{NOVA_COMPUTE_FILTERS_FILE}}"
section="Filters"
option="qemu-img: EnvFilter"
remove="yes"
other="yes"
line=$(sed -ne "/^\[$section\]/,/^\[.*\]/ { /^$option[ \t]*=/ p; }" "$file")
if [ "$other" = "yes" ] && [ "$remove" = "yes" ]; then
   line=$(sed -ne "/^\[$section\]/,/^\[.*\]/ { /^$option[ \t]*,/ p; }" "$file")
fi
#$xtrace
echo "$line"
if [ "$remove" = "yes" ] && [ ! -z "$line" ]; then
    grep -v "$line" "$file" > "$file.bak"
    mv "$file.bak" "$file"
fi