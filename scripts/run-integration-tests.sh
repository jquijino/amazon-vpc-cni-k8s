#!/usr/bin/env bash

set -euo pipefail

DIR=$(cd "$(dirname "$0")"; pwd)
source $DIR/lib/cluster.sh

OS=$(go env GOOS)
ARCH=amd64
REGION=${AWS_REGION:-us-west-2}
K8S_VERSION=${K8S_VERSION:-1.14.6}
PROVISION=${PROVISION:-true}
DEPROVISION=${DEPROVISION:-true}
BUILD=${BUILD:-true}

# test specific config, results location
TEST_ID=${TEST_ID:-$RANDOM}
TEST_DIR=/tmp/cni-test/$(date "+%Y%M%d%H%M%S")-$TEST_ID
REPORT_DIR=${TEST_DIR}/report

# test cluster config location
# Pass in CLUSTER_ID to reuse a test cluster
CLUSTER_ID=${CLUSTER_ID:-$RANDOM}
CLUSTER_NAME=cni-test-$CLUSTER_ID
TEST_CLUSTER_DIR=/tmp/cni-test/cluster-$CLUSTER_NAME
CLUSTER_CONFIG=${CLUSTER_CONFIG:-${TEST_CLUSTER_DIR}/${CLUSTER_NAME}.yaml}
SSH_KEY_PATH=${SSH_KEY_PATH:-${TEST_CLUSTER_DIR}/id_rsa}
KUBECONFIG_PATH=${KUBECONFIG_PATH:-${TEST_CLUSTER_DIR}/kubeconfig}

# shared binaries
TESTER_DOWNLOAD_URL=https://github.com/aws/aws-k8s-tester/releases/download/v0.4.3/aws-k8s-tester-v0.4.3-$OS-$ARCH
TESTER_DIR=${TESTER_DIR:-/tmp/aws-k8s-tester}
TESTER_PATH=${TESTER_PATH:-$TESTER_DIR/aws-k8s-tester}
AUTHENTICATOR_PATH=${AUTHENTICATOR_PATH:-/tmp/aws-k8s-tester/aws-iam-authenticator}
KUBECTL_PATH=${KUBECTL_PATH:-/tmp/aws-k8s-tester/kubectl}

# The version substituted in ./config/X/aws-k8s-cni.yaml
CNI_TEMPLATE_VERSION=${CNI_TEMPLATE_VERSION:-v1.5}

echo "Running $TEST_ID on $CLUSTER_NAME in $REGION"
echo "+ Cluster config dir: $TEST_CLUSTER_DIR"
echo "+ Result dir:         $TEST_DIR"
echo "+ Tester:             $TESTER_PATH"
echo "+ Kubeconfig:         $KUBECONFIG_PATH"
echo "+ Node SSH key:       $SSH_KEY_PATH"
echo "+ Cluster config:     $CLUSTER_CONFIG"
echo ""

mkdir -p $TEST_DIR
mkdir -p $REPORT_DIR
mkdir -p $TEST_CLUSTER_DIR

# Download aws-k8s-tester if not yet
if [[ ! -e $TESTER_PATH ]]; then
  mkdir -p $TESTER_DIR
  echo "Downloading aws-k8s-tester from $TESTER_DOWNLOAD_URL to $TESTER_PATH"
  curl -s -L -X GET $TESTER_DOWNLOAD_URL -o $TESTER_PATH
  chmod +x $TESTER_PATH
fi

if [[ "$PROVISION" = true ]]; then
    up-test-cluster
fi

if [[ "$BUILD" = true ]]; then
    # Push test image
    eval $(aws ecr get-login --region $REGION --no-include-email)
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    IMAGE_NAME="$AWS_ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/amazon/amazon-k8s-cni"
    IMAGE_VERSION=$(git describe --tags --always --dirty)

    make docker IMAGE=$IMAGE_NAME VERSION=$IMAGE_VERSION
    docker push $IMAGE_NAME:$IMAGE_VERSION

    echo "Using ./config/$CNI_TEMPLATE_VERSION/aws-k8s-cni.yaml as a template"
    if [[ ! -f "./config/$CNI_TEMPLATE_VERSION/aws-k8s-cni.yaml" ]]; then
        echo "./config/$CNI_TEMPLATE_VERSION/aws-k8s-cni.yaml DOES NOT exist. Set \$CNI_TEMPLATE_VERSION to an existing directory in ./config/"
        exit
    fi

    sed -i'.bak' "s,602401143452.dkr.ecr.us-west-2.amazonaws.com/amazon-k8s-cni,$IMAGE_NAME," ./config/$CNI_TEMPLATE_VERSION/aws-k8s-cni.yaml
    sed -i'.bak' "s,v1.5.3,$IMAGE_VERSION," ./config/$CNI_TEMPLATE_VERSION/aws-k8s-cni.yaml
fi

echo "Deploying CNI"
export KUBECONFIG=$KUBECONFIG_PATH
kubectl apply -f ./config/$CNI_TEMPLATE_VERSION/aws-k8s-cni.yaml

# Run the test
pushd ./test/integration
go test -v -timeout 0 ./... --kubeconfig=$KUBECONFIG --ginkgo.focus="\[cni-integration\]" --ginkgo.skip="\[Disruptive\]" \
    --assets=./assets
TEST_PASS=$?
popd

if [[ "$DEPROVISION" = true ]]; then
    down-test-cluster
fi

if [[ $TEST_PASS -ne 0 ]]; then
  exit 1
fi
