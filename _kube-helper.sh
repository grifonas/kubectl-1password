#!/bin/bash

KUBECONFIG_CRED_ITEM_TAG="kubeconfig_cred_for_sourcing"
KUBECONFIG_FOLDER="${HOME}/.kube"
# Get the absolute path of the script itself
script_path=$(realpath "$0")

# Function to get items with a specific tag
function list_kube_cred_items(){
  op item list --tags ${KUBECONFIG_CRED_ITEM_TAG} | awk '{print $1}' | grep -v ID
}

function get_full_item() {
  local ITEM_ID="$1"
  op item get ${ITEM_ID} --format json
}

function get_item_field() {
  local FIELD_LABEL="$1"
  local FULL_ITEM="$2"
  local FIELD_VALUE=$(echo $FULL_ITEM | jq -r ".fields[] | select(.label == \"${FIELD_LABEL}\") | .value" 2>&1)
  if [[ $? != "0" ]]; then
    echo "The item $ITEM_TITLE does not have a ${FIELD_LABEL} set."
    return 1
  fi
  echo $FIELD_VALUE
}

# Function to generate YAML and save to a file
generate_yaml() {
    local ITEM_ID="$1"
    local YAML_OUTPUT=""
    local FULL_ITEM=$(get_full_item $ITEM_ID)
    local ITEM_TITLE=$(echo $FULL_ITEM | jq -r '.title')
    local VAULT_NAME=$(echo $FULL_ITEM | jq -r '.vault.name')
    echo "Prepping kubeconfig for ${ITEM_TITLE} ($ITEM_ID)..."
    mkdir -p ${KUBECONFIG_FOLDER}
    local FULL_KUBECONFIG=$(get_item_field "full_kubeconfig" "$FULL_ITEM")

    CONTEXT_NAME=$(get_item_field "context-name" "$FULL_ITEM")
    if [[ $? != "0" ]]; then
      CONTEXT_NAME=$ITEM_TITLE
    fi
    if [[ ${FULL_KUBECONFIG} != "" ]]; then
        # Save full_kubeconfig to a file in the ~/.kube/ directory
        echo "Full kubeconfig for $ITEM_TITLE found."
        # YAML_OUTPUT=${FULL_KUBECONFIG}
        # echo op read "op://${VAULT_NAME}/${ITEM_TITLE}/full_kubeconfig"
        YAML_OUTPUT=$(op read "op://${VAULT_NAME}/${ITEM_TITLE}/full_kubeconfig")
    else
      echo "Generating kubeconfig for $ITEM_TITLE..."
      local SERVER=$(get_item_field "server" "$FULL_ITEM")
      local CERTIFICATE_AUTHORITY_DATA=$(get_item_field "certificate-authority-data" "$FULL_ITEM")
      local NAMESPACE=$(get_item_field "default_namespace" "$FULL_ITEM")
      if [[ $? != "0" ]]; then
        echo "The item $ITEM_TITLE does not have a default_namespace set. Using 'default' namespace."
        NAMESPACE="default"
      fi


    # Proceed with the original YAML generation if "full_kubeconfig" is not present
    YAML_OUTPUT=$(cat <<EOF
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: ${CERTIFICATE_AUTHORITY_DATA}
    server: ${SERVER}
  name: ${CONTEXT_NAME}
contexts:
- context:
    cluster: ${CONTEXT_NAME}
    namespace: ${NAMESPACE}
    user: ${CONTEXT_NAME}
  name: ${CONTEXT_NAME}
kind: Config
preferences: {}
users:
- name: ${CONTEXT_NAME}
  user:
    exec:
      command: "/bin/bash"
      apiVersion: "client.authentication.k8s.io/v1"
      args:
      - "$script_path"
      - "--item-id"
      - "$ITEM_ID"
      installHint: |
        github.com/grifonas/kubectl-1password helper script is required to authenticate to the Kubernetes cluster.
        The script is used to manage your kubeconfig contexts.
      provideClusterInfo: true
      interactiveMode: Never
EOF
    )
    fi
    # echo ------------------------------------------------------- ${CONTEXT_NAME} -------------------------------------------------------
    # printf "%s" "${YAML_OUTPUT}"
    printf "%s" "${YAML_OUTPUT}" > ${KUBECONFIG_FOLDER}/${CONTEXT_NAME}.yaml
    # echo -e "\n-------------------------------------------------------------------------------------------------------------------------------"
}

# Check script arguments
if [[ "$1" == "prep-contexts" ]]; then
    kubeconfig_files=()
    mkdir -p ${KUBECONFIG_FOLDER}
    echo "Preparing kubeconfig files..."
    ALL_ITEMS=$(list_kube_cred_items)
    for ITEM_ID in $ALL_ITEMS; do
        generate_yaml "$ITEM_ID"
        kubeconfig_files+=("${KUBECONFIG_FOLDER}/${CONTEXT_NAME}.yaml")
    done

    # Export KUBECONFIG variable
    export KUBECONFIG=$(IFS=:; echo "${kubeconfig_files[*]}")
    # echo "KUBECONFIG=$KUBECONFIG"
    # Merge the kubeconfig files into a single file
    # backup current kube/config:
    cp ${KUBECONFIG_FOLDER}/config ${KUBECONFIG_FOLDER}/config-$(date +%Y-%m-%d-%s).bak
    MERGED_PATH=${KUBECONFIG_FOLDER}/config
    kubectl config view --merge --flatten > ${MERGED_PATH}

    echo "Merged kubeconfig saved to ${MERGED_PATH}"
    # cleanup temp files:
    rm -f ${KUBECONFIG_FOLDER}/*.yaml
    exit 0
fi

# Parse script arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --item-id) ITEM_ID="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

# Check if required parameters are provided
if [[ -z "$ITEM_ID" ]]; then
    echo "Usage: $0 --item-id [ITEM ID]"
    exit 1
fi

# Construct the paths for client certificate and key data
FULL_ITEM=$(get_full_item $ITEM_ID)
# Retrieve the client certificate data
clientCertificateData=$(get_item_field "client-certificate-data" "$FULL_ITEM")
# Retrieve the client key data
clientKeyData=$(get_item_field "client-key-data" "$FULL_ITEM")

# Base64 decode the retrieved values and escape newline characters
decodedClientCertificateData=$(echo "$clientCertificateData" | base64 --decode | awk '{printf "%s\\n", $0}')
decodedClientKeyData=$(echo "$clientKeyData" | base64 --decode | awk '{printf "%s\\n", $0}')

# Construct the JSON output
json_output=$(cat <<EOF
{
  "apiVersion": "client.authentication.k8s.io/v1",
  "kind": "ExecCredential",
  "status": {
    "clientCertificateData": "$decodedClientCertificateData",
    "clientKeyData": "$decodedClientKeyData"
  }
}
EOF
)

# Print the JSON output
echo "$json_output"