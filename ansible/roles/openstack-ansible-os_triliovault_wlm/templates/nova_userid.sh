#!/bin/bash
user_id=42436
group_id=42436

user_name=nova
gps=$(id -Gn $user_name)

userdel $user_name
groupdel $user_name
old_name=$(awk -v val=$user_id -F ":" '$3==val{print $1}' /etc/passwd)
old_grp=$(awk -v val=$group_id -F ":" '$3==val{print $1}' /etc/group)

if [ ! -z "$old_name" ]; then
if id $old_name > /dev/null 2>&1; then
   old_grp1=$(id -G $old_name)
   old_grp1_name=$(id -G -n $old_name)
   userdel $old_name
   if [ "$old_grp1" != "$user_id" ]; then
      groupdel $old_grp1_name
   fi
   groupadd $old_name
   useradd -g $old_name $old_name
fi
fi

if [ ! -z "$old_grp" ]; then
if getent group $group_id  > /dev/null 2>&1; then
   if ! id $old_grp > /dev/null 2>&1; then
      groupdel $old_grp
      groupadd $old_grp
   else
        userdel $old_grp
        groupdel $old_grp
        groupadd $old_grp
        useradd -g $old_grp $old_grp
   fi
fi
fi

groupadd -g $group_id $user_name || true
useradd -u $user_id -g $group_id $user_name || true
for i in $gps; do
    usermod -a -G $i $user_name
done