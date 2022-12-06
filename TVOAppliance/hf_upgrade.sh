#!/bin/bash

BASE_DIR="$(pwd)"

#function to display usage...
function usage()
{
  echo "Usage: ./hf_upgrade.sh 	[ -h | --help ]
				[ -d | --downloadonly ]
                               	[ -i | --installonly ] 
                               	[ -a | --all   ]"
  exit 2
}


#function to download the package and extract...
function download_package()
{
	#define file id and filename which we want to download.
	fileid=16JM1Z1jZvISwmo0Bqnj0wJSUu2C1ZJ7G
	outfile="offline_pkgs.tar.gz"

	#run the wget command to download the package.
	wget_command=`wget --load-cookies /tmp/cookies.txt "https://docs.google.com/uc?export=download&confirm=$(wget --quiet --save-cookies /tmp/cookies.txt --keep-session-cookies --no-check-certificate 'https://docs.google.com/uc?export=download&id=$fileid' -O- | sed -rn 's/.confirm=([0-9A-Za-z_]+)./\1\n/p')&id=$fileid" -O $outfile && rm -rf /tmp/cookies.txt`

	#now the package is downloaded. Extract the package.
	extract_packages=`tar -xzf $outfile`	
}


#function to install the package on the system...
function install_package()
{
	#it is expected that package is available in current directory.
	outfile="$BASE_DIR/offline_pkgs.tar.gz"
	if [[ -f $outfile ]]
	then
		echo "$outfile present. we can continue with the installation."
	else
		echo "$outfile is not present. Cannot proceed with the installation. Exiting."
		exit 2
	fi

	#extract offline_dist_pkgs.tar.gz file
	extract_offline_dist_pkg=`tar -xzf offline_dist_pkgs.tar.gz`
	cd offline_dist_pkgs*/
	install_cmd=`yum -y install ./*.rpm`

	#move to base dir again
	cd $BASE_DIR

	#extract Python-3.8.12.tgz
	extract_python_pkg=`tar -xf Python-3.8.12.tgz`
	cd Python-3.8.12*/
	config_cmd=`./configure --enable-optimizations`
	make_cmd=`sudo make altinstall`

	#move to base dir again
	cd $BASE_DIR

	#now move existing myansible enviornment
	date=`date '+%Y-%m-%d-%H:%M:%S'`
	mv /home/stack/myansible /home/stack/myansible_old_$date
	mkdir -p /home/stack/myansible 

	#extract the package at the / directory.
	extract_myansible_pkg=`tar -xzf myansible_py38.tar.gz -C /`

	#set the default python3
	update_python_cmd=`update-alternatives --install /usr/bin/python3 python3 /usr/local/bin/python3.8 0`

	#restart the services post install
	service_restart_cmd=`systemctl restart tvault-config wlm-workloads wlm-api wlm-cron wlm-workloads`

	#restart s3 related services.
	service_restart_s3_cmd=`systemctl restart tvault-object-store`
	
}

########  Start of the script.  ########

CMDLINE_ARGUMENTS=$(getopt -o hdia --long help,downloadonly,installonly,all -- "$@")
CMD_OUTPUT=$?
if [ "$CMD_OUTPUT" != "0" ]; then
  usage
fi

eval set -- "$CMDLINE_ARGUMENTS"

echo "TVO Upgrade for Yoga release from previous 4.2GA/4.2HF"

#command line arguments.
if [ $# -le 1 ]; then
  echo "Invalid number of arguments"
  usage
fi


while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit;;
    -d|--downloadonly) download_package ;;
    -i|--installonly)  install_package ;;
    -a|--all) download_package; install_package ;;
  esac
  shift
done

