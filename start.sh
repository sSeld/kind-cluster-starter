#!/bin/bash

KIND_NODE_IMAGE_VERSION=kindest/node:1.27.1@sha256:4992b70e56a3de9c917adfb4fefe24ca2ee6fb1b8f3e31257e9ae8836ab8a271
KUBERNETES_DASHBOARD_VERSION=2.3.1
CLUSTER_NAME=jeremy
reg_name='kind-registry'
reg_port='5001'
DASHBOARD_URL=https://localhost:8080

info(){
    echo "[INFO] $1"
}
error(){
    echo "[ERROR] $1"
}

if ! command -v docker &> /dev/null
then
    error "Docker is not installed or is not on the path"
    exit 1
fi

if ! command -v kind &> /dev/null
then
    error "Kind is not installed or is not on the path"
    exit 1
fi



info "Docker and Kind are both available"

install_kind(){
    # Install Kind
    curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.11.1/kind-linux-amd64
    chmod +x ./kind
    sudo mv ./kind /usr/local/bin/kind
}

setup_registry(){
    ## Create or start a local registry container
    docker run -d --restart=no -p "127.0.0.1:${reg_port}:5000" --name "${reg_name}" registry:2
}
start_registry(){
    docker container start kind-registry
}
setup_ingress(){
    info "Setting up NGINX Ingress"
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
    kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s
}

setup_cluster(){
info "Cannot find $CLUSTER_NAME. Setting up $CLUSTER_NAME cluster."

# Create Kind cluster with one worker node
cat <<EOF | kind create cluster --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: $CLUSTER_NAME
runtimeConfig:
  "api/all": "true"
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:5001"]
      endpoint = ["http://kind-registry:5000"]
nodes:
  - role: control-plane
    image: $KIND_NODE_IMAGE_VERSION
    kubeadmConfigPatches:
        - |
          kind: InitConfiguration
          nodeRegistration:
              kubeletExtraArgs:
                  node-labels: "ingress-ready=true"
    extraPortMappings:
    - containerPort: 80
      hostPort: 80
      protocol: TCP
    - containerPort: 443
      hostPort: 443
      protocol: TCP
  - role: worker
    image: $KIND_NODE_IMAGE_VERSION
EOF


# connect the registry to the cluster network if not already connected
if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${reg_name}")" = 'null' ]; then
  docker network connect "kind" "${reg_name}"
fi

# Document the local registry
# https://github.com/kubernetes/enhancements/tree/master/keps/sig-cluster-lifecycle/generic/1755-communicating-a-local-registry
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${reg_port}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

setup_ingress
setup_dashboard
}



setup_dashboard(){
    info "Setting up Kubernetes Dashboard"
# Deploy the Kubernetes dashboard
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v$KUBERNETES_DASHBOARD_VERSION/aio/deploy/recommended.yaml

# Create a service account and cluster role binding for the dashboard
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard

---

apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: kubernetes-dashboard
EOF

# Print the dashboard token to the console
# kubectl -n kubernetes-dashboard describe secret $(kubectl -n kubernetes-dashboard get secret | grep admin-user | awk '{print $1}') | grep '^token:' | awk '{print $2}'

}


start_control_plane(){
    docker container start $CLUSTER_NAME-control-plane
}
start_worker_node(){
    docker container start $CLUSTER_NAME-worker
}

docker container ls --all | grep -q "kind-registry" && info "$reg_name exists" || setup_registry
docker inspect -f '{{.State.Running}}' "kind-registry" 2>/dev/null | grep -q "true" && info "$reg_name is running" || start_registry
kind get clusters | grep -q "$CLUSTER_NAME" && info "cluster $CLUSTER_NAME exists" || setup_cluster
docker inspect -f '{{.State.Running}}' "$CLUSTER_NAME-control-plane" 2>/dev/null | grep -q "true" && info "$CLUSTER_NAME control plane is running" || start_control_plane
docker inspect -f '{{.State.Running}}' "$CLUSTER_NAME-worker" 2>/dev/null | grep -q "true" && info "$CLUSTER_NAME worker node is running" || start_worker_node


kubectl cluster-info --context kind-$CLUSTER_NAME
echo "Login to dashboard at $DASHBOARD_URL with the token $(kubectl -n kubernetes-dashboard create token admin-user)"
kubectl port-forward -n kubernetes-dashboard service/kubernetes-dashboard 8080:443