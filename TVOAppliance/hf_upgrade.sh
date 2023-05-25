#!/bin/bash

BASE_DIR="$(pwd)"
PYTHON_VERSION="Python 3.8.12"
OFFLINE_PKG_NAME="4.2-offlinePkgs.tar.gz"
PKG_DIR_NAME="4.2.*offlinePkgs"
BRANCH_NAME="triliodata-4-2"
UUID_NUM=`uuidgen`

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
	echo "Downloading $outfile for 4.2 maintenance release"

	#run the wget command to download the package from rpm server.
	wget_command_rpm_server=`wget --backups 0 http://repos.trilio.io:8283/$BRANCH_NAME/offlinePkgs/$OFFLINE_PKG_NAME`

}

function check_package_status()
{
        all_pkgs=`ls -1`

	# iterate through all packages to check installation status.
        for pkg_name in $all_pkgs
        do
                if [[ $pkg_name = *"rpm"* ]]; then
                        #remove last 4 chars of (.rpm)
                        total_len="${#pkg_name}"
                        rpm_pkg_info="${pkg_name:0:$total_len-4}"

                        #check result for this package
                        rpm_result=`rpm -qa | grep $rpm_pkg_info`
                        result=$?
                        if [[ $result == 1 ]]; then
                                echo "Package $rpm_pkg_info not found on the system."
				# perform yum command to install package.
				install_cmd=`yum -y install $rpm_pkg_info.rpm`	
			else
				echo "Package $rpm_pkg_info.rpm present on the system."
                        fi
                fi
        done
}
#function to change system settings
function change_system_settings()
{
	#set sshd option UseDNS to "no"
	sed -i '/UseDNS/c UseDNS no' /etc/ssh/sshd_config
	#Create task flow dir and change permissions. Implemented from TVO-4.2.7 release
	mkdir -p /var/lib/workloadmgr/taskflow
	chown -R nova:nova /var/lib/workloadmgr/
}

#function to restart the services.
function restart_services()
{
	#get the service name passed.
        service_name=$1

        #check if the service is in active state or not.
        systemctl is-active $service_name

	#check the result code. 0 - Success AND 3 - Inactive 
        if [ $? -eq 0 ]
        then
		echo "Service {$service_name} is in active state. Restarting {$service_name} service"
                #restart the service as it is in active state.
                systemctl restart $service_name
        else
		#print failure message and continue ahead.
                echo "Service {$service_name} is in Inactive state. Cannot restart the service"
        fi
}


#function to reconfigure s3 service path...
function reconfigure_s3_service_path()
{
	file_name="/etc/systemd/system/tvault-object-store.service"
	src_string="ExecStart=/home/stack/myansible/bin/python3 /home/stack/myansible/lib/python3.6/site-packages/s3fuse/s3vaultfuse.py --config-file=/etc/workloadmgr/workloadmgr.conf"
	dest_string="ExecStart=/home/stack/myansible/bin/python3 /home/stack/myansible/bin/s3vaultfuse.py --config-file=/etc/workloadmgr/workloadmgr.conf"

	sed  -i "s~$src_string~$dest_string~g" $file_name

}
#function to install the package on the system...
function install_upgrade_package()
{
	#it is expected that package is available in current directory.
	outfile="$BASE_DIR/$OFFLINE_PKG_NAME"
	if [[ -f $outfile ]]
	then
		echo "$outfile present. we can continue with the installation."

		echo "Extracting $outfile now"
		#now the package is downloaded. Extract the package.
		#1. create directory with unique number and extract package inside it. 
		mkdir $UUID_NUM

		extract_packages=`tar -xzf $outfile -C $UUID_NUM/`	
	else
		echo "$outfile is not present. Cannot proceed with the installation. Exiting."
		exit 2
	fi

	echo "Installing $outfile for 4.2 maintenance release"
	
	#get the current date and time. 
	date=`date '+%Y-%m-%d-%H-%M-%S'`

	#before performing further installation take backup.
	tar -czvf /home/stack/tvault_backup_$date.tar.gz /etc/tvault /etc/tvault-config /etc/workloadmgr

	echo "Before installation disabling old and deleted MariaDB and Rabbitmq-server yum repositories"
	yum-config-manager --disable bintray-rabbitmq-server
	yum-config-manager --disable mariadb

	#make sure to be in base directory for installation.
	cd $BASE_DIR/$UUID_NUM/$PKG_DIR_NAME*/

	#extract Python-3.8.12.tgz - first check if python 3.8.12 version is availble or not.
	python_version=`python3 --version`
	if [ "$python_version" == "$PYTHON_VERSION" ]; then
	  echo "Python 3.8.12 package is already installed. We can skip Python package installation."

	else
	  echo "Python 3.8.12 package is missing. We need to install Python package."

	  #extract offline_dist_pkgs.tar.gz file to install dependancy packages first.
	  extract_offline_dist_pkg=`tar -xzf offline_dist_pkgs.tar.gz`
	  cd offline_dist_pkgs*/
	  #check if the packages are already installed or not. call function check_package_status() 
	  check_package_status

	  #move to base dir again
	  cd $BASE_DIR/$UUID_NUM/$PKG_DIR_NAME*/

	  #Install python 3.8.12 package on the TVO appliance.
	  extract_python_pkg=`tar -xf Python-3.8.12.tgz`
	  cd Python-3.8.12*/
          config_cmd=`./configure --enable-optimizations`
          make_cmd=`sudo make altinstall`

	fi

	#move to base dir/UUID_NUM/PKG_DIR_NAME again for further installation.
	cd $BASE_DIR/$UUID_NUM/$PKG_DIR_NAME*/

	#move myansible env to myansible_old_$date folder.
	mv /home/stack/myansible /home/stack/myansible_old_$date
	mkdir -p /home/stack/myansible 

	#extract the package at the / directory.
	extract_myansible_pkg=`tar -xzf myansible_py38.tar.gz -C /`

	#set the default python3
	update-alternatives --install /usr/bin/python3 python3 /usr/local/bin/python3.8 0

	#get the OLD and NEW user json. 
	USER_JSON_OLD=`/home/stack/myansible_old_$date/bin/python3 -c 'import tvault_configurator; print(tvault_configurator.__path__[0])'`/conf/users.json

	USER_JSON_NEW=`/home/stack/myansible/bin/python3 -c 'import tvault_configurator; print(tvault_configurator.__path__[0])'`/conf/users.json

	#replace / copy the user.json file from USER_JSON_OLD to USER_JSON_NEW path. 
	yes | cp $USER_JSON_OLD $USER_JSON_NEW --backup=numbered
	
	#function to change system settings (set sshd option UseDNS to "no")
	change_system_settings
	
	#call function - before restarting service replace the service path in tvault-object-store.service file
	reconfigure_s3_service_path
	
	#before restarting the s3 service reload the modified service file. 
	systemctl daemon-reload

	#restart all active services
	SERVICE_NAMES=('tvault-config' 'wlm-api' 'wlm-workloads' 'wlm-cron' 'tvault-object-store' 'wlm-scheduler')
	for service in "${SERVICE_NAMES[@]}"
	do
        	restart_services $service
	done

	if [ $(awk -F "=" '/config_status/ {print $2}' ${TVAULT_CONF} | xargs ) == "configured" ];then
		echo "Performing DB upgrade steps"
        	#DB upgrade to be performed post upgrade of all packages is successful and services restarted only if TVO is already configured
	        sed -i "/script_location = /c \script_location = /home/stack/myansible/lib/python3.8/site-packages/workloadmgr/db/sqlalchemy/migrate_repo" $WORKLOADMGR_CONF
	        sed -i "/version_locations = /c \version_locations = /home/stack/myansible/lib/python3.8/site-packages/workloadmgr/db/sqlalchemy/migrate_repo/versions" $WORKLOADMGR_CONF
        	source /home/stack/myansible/bin/activate && alembic -c ${WORKLOADMGR_CONF} upgrade head
	fi
	echo "TVO appliance upgrade is complete. If TVO configuration is not done, please proceed with the same."
}

########  Start of the script.  ########

WORKLOADMGR_CONF=/etc/workloadmgr/workloadmgr.conf
TVAULT_CONF=/etc/tvault-config/tvault-config.conf
CMDLINE_ARGUMENTS=$(getopt -o hdia --long help,downloadonly,installonly,all -- "$@")

CMD_OUTPUT=$?
if [ "$CMD_OUTPUT" != "0" ]; then
  usage
fi

eval set -- "$CMDLINE_ARGUMENTS"

echo "TVO Upgrade from current release to latest 4.2 maintenance release"


#command line arguments.
if [ $# -le 1 ]; then
  echo "Invalid number of arguments"
  usage
fi


if [ $# -gt 0 ]; then
  case "$1" in
    -h|--help) usage; exit;;
    -d|--downloadonly) download_package ;;
    -i|--installonly)  install_upgrade_package ;;
    -a|--all) download_package; install_upgrade_package ;;
  esac
  shift
fi

