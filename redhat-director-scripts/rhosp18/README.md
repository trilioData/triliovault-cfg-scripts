# TrilioVault for OpenStack Operator for Openshift and Kubernetes

## Create TVO-operator from helm chart
```
cd build/
chmod +x create_operator_from_helm_chart.sh
./create_operator_from_helm_chart.sh
```

## Build TVO-operator image
```
cd build/
chmod +x build_operator.sh
./build_operator.sh
```

## Publish TVO-operator image to DockerHub
```
cd build/
chmod +x publish_operator.sh
./publish_operator.sh
```

## Install TVO-operator CRD and TVO-Operator on Openshift/K8s
```
cd utils/
chmod +x install_operator.sh
./install_operator.sh
```

## Install TVOControlPlane Services on Openshift/K8s
```
cd utils/
chmod +x deploy_tvo_control_plane.sh
./deploy_tvo_control_plane.sh
```