#!/bin/bash  -x

set -e
    
CONTEGO_DIR=$1 
TVAULT_APPLIANCE_IP=$2 
OPENSTACK_RELEASE=$3

#export CONTEGO_VERSION=`curl -s http://192.168.1.26:8081/packages/ | grep tvault-contego-[0-9] | awk -F 'tvault-contego-' '{print $2}' | cut -c-5`

export CONTEGO_VERSION=`curl -s http://${TVAULT_APPLIANCE_IP}:8081/packages/ | grep tvault-contego-[0-9] | awk -F 'tvault-contego-' '{print $2}' | awk -F 'tar.gz' '{print $1}' | sed 's/.\{1\}$//'`
	
   ###Check if current contego package is latest
   if [ -d $CONTEGO_DIR/.virtenv ]; then
       cd $CONTEGO_DIR/
       source .virtenv/bin/activate
       CONTEGO_VERSION_INSTALLED=`pip list | grep tvault-contego | cut -d'(' -f2 | cut -d')' -f1`

       if [ "$CONTEGO_VERSION" == "$CONTEGO_VERSION_INSTALLED" ]; then
          echo -e "Latest Tvault-contego package is already installed, exiting\n"
          deactivate
          exit 0
       elif[ "$CONTEGO_VERSION_INSTALLED" != "" ]
              systemctl stop tvault-contego
	      pip uninstall tvault-contego -y
              deactivate
	      rm -rf .virtenv
       fi
	      
   else
       mkdir -p $CONTEGO_DIR/
       cd $CONTEGO_DIR/
   fi	   
      
   ###Install new contego package
   
   #Set library paths as per openstack release
   if [[ "$OPENSTACK_RELEASE" == "mitaka" ]];then
      which_cryptography=$(python -c "import cryptography;print cryptography.__path__[0]")
      which_crypto=$(python -c "import Crypto;print Crypto.__path__[0]")
   fi
   if [[ "$OPENSTACK_RELEASE" == "newton" ]];then
      which_cryptography=$(python -c "import cryptography;print cryptography.__path__[0]")
      which_libvirt=$(python -c "import libvirtmod;print libvirtmod.__file__")
      which_cffi=$(python -c "import cffi;print cffi.__path__[0]")
      which_cffi_so=$(python -c "import _cffi_backend;print _cffi_backend.__file__")
   fi
   rm -f tvault-contego-virtenv.tar.gz
   curl -O http://$TVAULT_APPLIANCE_IP:8081/packages/$OPENSTACK_RELEASE/tvault-contego-virtenv.tar.gz
   tar -zxf tvault-contego-virtenv.tar.gz
   source .virtenv/bin/activate
   if [ $? -ne 0 ]
   then
        echo -e "Activating contego virtual environment failed....exiting\n"
        exit 1
   fi
   pip install http://$TVAULT_APPLIANCE_IP:8081/packages/tvault-contego-$CONTEGO_VERSION.tar.gz
   systemctl stop tvault-contego
   if [[ "$OPENSTACK_RELEASE" == "mitaka" ]];then
      rm -rf .virtenv/lib/python2.7/site-packages/cryptography
      ln -s $which_cryptography .virtenv/lib/python2.7/site-packages/cryptography
      rm -rf .virtenv/lib/python2.7/site-packages/Crypto
      ln -s $which_crypto .virtenv/lib/python2.7/site-packages/Crypto
   fi
   if [[ "$OPENSTACK_RELEASE" == "newton" ]];then
      rm -rf .virtenv/lib/python2.7/site-packages/cryptography
      ln -s $which_cryptography .virtenv/lib/python2.7/site-packages/cryptography
      cp $which_libvirt .virtenv/lib/python2.7/site-packages/libvirtmod.so
      rm -rf .virtenv/lib/python2.7/site-packages/cffi
      ln -s $which_cffi .virtenv/lib/python2.7/site-packages/cffi
      cp $which_cffi_so .virtenv/lib/python2.7/site-packages/_cffi_backend.so
   fi
   CONTEGO_VERSION_INSTALLED=`pip list | grep tvault-contego | cut -d'(' -f2 | cut -d')' -f1`
   deactivate
   

   if [ "$CONTEGO_VERSION" != "$CONTEGO_VERSION_INSTALLED" ]; then
        echo -e "Unable to install latest datamover package, please have a look at logs\n"
        exit 1
   else
        echo -e "Installed latest datamover package:$CONTEGO_VERSION sucessfully\n"
   fi
