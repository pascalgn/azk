#!/bin/sh

main() {
    if [ "${1}" = "list" ]; then
        if [ "${#}" -eq 1 ]; then
            list
        else
            fatal "usage: ${0} list"
        fi
    elif [ "${1}" = "create" ]; then
        if [ "${#}" -eq 2 ] || [ "${#}" -eq 3 ]; then
            create "${2}" "${3}"
        else
            fatal "usage: ${0} create <config.yaml> [--confirm]"
        fi
    elif [ "${1}" = "delete" ]; then
        if [ "${#}" -eq 2 ]; then
            delete "${2}"
        else
            fatal "usage: ${0} delete <name>"
        fi
    elif [ "${1}" = "setup-aad" ]; then
        if [ "${#}" -eq 3 ]; then
            setup_aad "${2}" "${3}"
        else
            fatal "usage: ${0} setup-aad <server-name> <client-name>"
        fi
    else
        fatal "usage: ${0} [-h] <command> [<args>]"
    fi
}

list() {
    currentTenant="$(az account show | jq -r .tenantId)"

    subscriptions="$(az account list | jq -r ".[] | select(.tenantId == \"${currentTenant}\") | .id")"
    for subscriptionId in ${subscriptions}; do
        names="$(az aks list --subscription "${subscriptionId}" | jq -r .[].name)"

        echo "Subscription: ${subscriptionId}"
        for name in ${names}; do
            echo " - ${name}"
            echo "   az aks get-credentials --subscription '${subscriptionId}' --resource-group '${name}' --name '${name}'"
            echo "   kubectl config set-context '${name}' --namespace=default"
        done
        echo
    done
}

create() {
    read_config "${1}"

    check_az_extension "aks-preview"

    echo "Subscription: ${subscription}"
    echo "Name: ${aksName}"
    echo "Node resource group: ${aksResName}"
    echo "VM size: ${vmSize}"
    echo "VM count: ${vmCount}"

    if [ "${2}" != "--confirm" ]; then
        echo "Not creating cluster unless --confirm given"
        exit 0
    fi

    set_tags

    if ! resource_group_exists "${aksName}"; then
        create_resource_group "${aksName}"
    fi

    if ! aks_exists "${aksName}"; then
        if ! sp_exists "${aksName}"; then
            create_sp "${aksName}"
        fi

        reset_sp_password "${appId}"

        create_aks
    fi

    set_resource_group_tags "${aksResName}"

    if [ -n "${aadGroupId}" ]; then
        apply_clusterrolebinding "${aadGroupId}"
    fi

    info "Successfully created AKS cluster: ${aksName}"
}

delete() {
    aksName="${1}"

    subscription="$(az account show | jq -r .id)"

    if aks_exists "${aksName}"; then
        delete_aks "${aksName}"
    fi

    if resource_group_exists "${aksName}"; then
        delete_resource_group "${aksName}"
    fi

    if sp_exists "${aksName}"; then
        delete_sp "${appId}"
    fi

    info "AKS cluster has been deleted: ${aksName}"
}

setup_aad() {
    serverName="${1}"
    clientName="${2}"

    info "Creating app ${serverName} ..."

    serverApplicationId=$(az ad app create \
        --display-name "${serverName}" \
        --query appId -o tsv) || fatal "Could not create server app!"

    az ad app update --id "${serverApplicationId}" \
        --set groupMembershipClaims=All >/dev/null ||
        fatal "Could not update app!"

    az ad sp create --id "${serverApplicationId}" >/dev/null ||
        fatal "Could not create SP!"

    serverApplicationSecret=$(az ad sp credential reset \
        --name "${serverApplicationId}" \
        --credential-description "AKS" \
        --query password -o tsv) || fatal "Could not reset credentials"

    az ad app permission add \
        --id "${serverApplicationId}" \
        --api 00000003-0000-0000-c000-000000000000 \
        --api-permissions \
        e1fe6dd8-ba31-4d61-89e7-88639da4683d=Scope \
        06da0dbc-49e2-44d2-8312-53f166ab848a=Scope \
        7ab1d382-f21e-4acd-a863-ba3e13f7da61=Role >/dev/null ||
        fatal "Could not add permissions!"

    sleep 30

    az ad app permission grant --id "${serverApplicationId}" \
        --api 00000003-0000-0000-c000-000000000000 >/dev/null ||
        fatal "Could not grant permissions"

    sleep 30

    az ad app permission admin-consent --id "${serverApplicationId}" \
        >/dev/null || fatal "Could not consent to permissions"

    info "Creating app ${clientName} ..."

    clientApplicationId=$(az ad app create \
        --display-name "${clientName}" \
        --native-app \
        --reply-urls "http://localhost" \
        --query appId -o tsv) || fatal "Could not create client app!"

    az ad sp create --id "${clientApplicationId}" >/dev/null ||
        fatal "Could not create SP"

    oAuthPermissionId=$(az ad app show --id "${serverApplicationId}" \
        --query "oauth2Permissions[0].id" -o tsv) ||
        fatal "Could not get permission ID"

    az ad app permission add --id "${clientApplicationId}" \
        --api "${serverApplicationId}" \
        --api-permissions "${oAuthPermissionId}=Scope" >/dev/null ||
        fatal "Could not add permissions"

    az ad app permission grant --id "${clientApplicationId}" \
        --api "${serverApplicationId}" >/dev/null ||
        fatal "Could not grant permissions"

    info "App registrations created successfully!"
    info "Server: ${serverName} (${serverApplicationId})"
    info "Secret: ${serverApplicationSecret}"
    info "Client: ${clientName} (${clientApplicationId})"
}

read_config() {
    name=""
    aadTenantId=""
    aadServerAppId=""
    aadServerAppSecret=""
    aadClientAppId=""
    aadGroupId=""

    if [ "${1}" = "-" ]; then
        read_config_lines
    else
        read_config_lines <"${1}"
    fi

    aksName="${name}"
    if [ -z "${aksName}" ]; then
        fatal "Invalid configuration file: Missing field 'name'"
    fi

    if [ -z "${subscription}" ]; then
        subscription="$(az account show | jq -r .id)"
    fi

    aksResName="${nodeResourceGroup:-${aksName}-res}"
    location="${location:-westeurope}"

    vmSize="${vmSize:-Standard_DS2_v2}"
    vmCount="${vmCount:-1}"
}

read_config_lines() {
    while IFS= read -r line; do
        key="$(echo "${line}" | sed -En 's/^([a-z][a-zA-Z0-9]+):.+$/\1/p')"
        val="$(echo "${line}" | sed -En "s/^${key}: +('([^']*)'|\"([^\"]*)\"|(.*))\$/\\2\\3\\4/p")"
        if [ -n "${key}" ] && [ -n "${val}" ]; then
            eval "$key"=\"\$val\"
        fi
    done
}

set_tags() {
    currentUser="$(az account show | jq -r .user.name)"
    if [ -z "${currentUser}" ]; then
        fatal "Could not get current user!"
    fi
    tags="Creator=${currentUser}"
}

check_az_extension() {
    if ! az extension list | grep -q "${1}"; then
        fatal "Extension ${1} is not installed!"
        fatal "You can install it using 'az extension add --name ${1}'"
    fi
}

resource_group_exists() {
    az group exists --subscription "${subscription}" -n "${1}" | grep -q "true"
}

create_resource_group() {
    info "Creating group ${1} ..."
    az group create --subscription "${subscription}" --tags "${tags}" \
        --location "${location}" --name "${1}" >/dev/null ||
        fatal "Could not create group!"
}

delete_resource_group() {
    info "Deleting group ${1} ..."
    az group delete --yes --subscription "${subscription}" \
        --name "${1}" >/dev/null ||
        fatal "Could not delete group!"
}

set_resource_group_tags() {
    az group update --subscription "${subscription}" -n "${1}" \
        --tags "${tags}" >/dev/null ||
        fatal "Could not set tags!"
}

sp_exists() {
    appId="$(az ad sp list --filter "DisplayName eq '${1}'" --query "[0].appId" | tr -d '"')"
    echo "${appId}" | grep -q "."
}

create_sp() {
    info "Creating service principal ${1} ..."
    if ! appId="$(az ad sp create-for-rbac --skip-assignment -n "${1}" | jq -r .appId)"; then
        fatal "Could not create service principal!"
    fi
}

reset_sp_password() {
    info "Resetting service principal password for ${1} ..."
    if ! appPassword="$(az ad sp credential reset -n "${1}" \
        --end-date 2099-12-31 --query 'password' | tr -d '"')"; then
        fatal "Could not reset password!"
    fi
    sleep 60
}

delete_sp() {
    info "Deleting service principal ${1} ..."
    az ad sp delete --id "${1}" >/dev/null ||
        fatal "Could not delete service principal!"
}

aks_exists() {
    az aks show --subscription "${subscription}" \
        --resource-group "${1}" --name "${1}" -o none 2>/dev/null
}

create_aks() {
    info "Creating AKS cluster ${aksName} ..."
    az aks create --verbose \
        --name "${aksName}" \
        --subscription "${subscription}" \
        --location "${location}" \
        --resource-group "${aksName}" \
        --node-resource-group "${aksResName}" \
        --service-principal "${appId}" \
        --client-secret "${appPassword}" \
        --aad-tenant-id "${aadTenantId}" \
        --aad-server-app-id "${aadServerAppId}" \
        --aad-server-app-secret "${aadServerAppSecret}" \
        --aad-client-app-id "${aadClientAppId}" \
        --node-vm-size "${vmSize}" \
        --node-count "${vmCount}" \
        --tags "${tags}" \
        --no-ssh-key >/dev/null ||
        fatal "Could not create AKS cluster!"
}

delete_aks() {
    info "Deleting AKS cluster ${1} ..."
    az aks delete \
        --name "${1}" \
        --subscription "${subscription}" \
        --resource-group "${1}" ||
        fatal "Could not delete AKS cluster!"
}

apply_clusterrolebinding() {
    kubeconfigFile=".kubeconfig-$(date +%Y%m%d%H%M%S).json"
    az aks get-credentials \
        --subscription "${subscription}" \
        --resource-group "${aksName}" \
        --name "${aksName}" \
        --file "${kubeconfigFile}" \
        --admin ||
        fatal "Could not get credentials!"
    get_clusterrolebinding "${1}" |
        kubectl --kubeconfig "${kubeconfigFile}" apply -f -
    rm -f "${kubeconfigFile}"
}

get_clusterrolebinding() {
    echo "apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: aad-default-group-cluster-admin-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:"
    IFS=" "
    for id in $1; do
        echo "- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: $id"
    done
}

info() {
    echo "$@" >&2
}

fatal() {
    echo "$@" >&2
    exit 1
}

main "$@"
