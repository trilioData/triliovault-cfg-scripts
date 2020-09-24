#!/bin/bash
source /openstack/venvs/horizon*/bin/activate
PIP_INS=`pip --version || true`
EASY_INS=`easy_install --version`
  if [[ $PIP_INS == pip* ]];then
     echo "uninstalling packages"
     echo "PIP already installed"
     pip uninstall tvault-horizon-plugin -y
     pip uninstall python-workloadmgrclient -y
  elif [[ $EASY_INS == setuptools* ]];then
       echo "uninstalling packages"
       easy_install --no-deps pip  &> /dev/null
       if [ $? -ne 0 ];then
          echo "installing pip-7.1.2.tar.gz"
          easy_install --no-deps http://{{IP_ADDRESS}}:{{PYPI_PORT}}/packages/pip-7.1.2.tar.gz &> /dev/null
          if [ $? -eq 0 ]; then
             echo "pip installation done successfully"
          else
              echo "Error : easy_install http://{{IP_ADDRESS}}:{{PYPI_PORT}}/packages/pip-7.1.2.tar.gz"
              exit 1
          fi
          pip uninstall tvault-horizon-plugin -y
          pip uninstall python-workloadmgrclient -y
       else
           pip uninstall tvault-horizon-plugin -y
           pip uninstall python-workloadmgrclient -y
       fi
       pip uninstall pip -y
  else
      echo "pip and easy_install not available hence skipping trilio pip package cleanup."
  fi