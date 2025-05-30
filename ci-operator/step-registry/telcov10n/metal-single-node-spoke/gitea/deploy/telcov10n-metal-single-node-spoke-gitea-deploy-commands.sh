#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telcov10n Fix user IDs in a container ************"
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

source ${SHARED_DIR}/common-telcov10n-bash-functions.sh

function set_hub_cluster_kubeconfig {
  echo "************ telcov10n Set Hub kubeconfig from \${SHARED_DIR}/hub-kubeconfig location ************"
  export KUBECONFIG="${SHARED_DIR}/hub-kubeconfig"

  if [ -n "${SOCKS5_PROXY}" ]; then
    _curl="curl -x ${SOCKS5_PROXY}"
  else
    _curl="curl"
  fi
}

function create_gitea_deployment {

  echo "************ telcov10n Deploy Gitea as a service into the Hub cluster ************"

  gitea_project="${GITEA_NAMESPACE}"

  cat <<EOF | oc apply -f -
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${gitea_project}
  annotations:
  labels:
    kubernetes.io/metadata.name: ${gitea_project}
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/warn: privileged
EOF

helm_gitea_values=$(mktemp --dry-run)
gitea_admin_pass="$(cat /var/run/telcov10n/ztp-left-shifting/gitea-admin-pass)"

cat <<EOF > ${helm_gitea_values}
replicaCount: 1

image:
  registry: "${GITEA_REGISTRY}"
  repository: "${GITEA_REPO}"

serviceAccount:
  name: gitea

redis-cluster:
  enabled: false
redis:
  enabled: false
postgresql:
  enabled: false
postgresql-ha:
  enabled: false

persistence:
  enabled: false

gitea:
  admin:
    username: "${GITEA_ADMIN_USERNAME}"
    password: "${gitea_admin_pass}"
  config:
    database:
      DB_TYPE: sqlite3
    session:
      PROVIDER: memory
    cache:
      ADAPTER: memory
    queue:
      TYPE: level
EOF

  # cat ${helm_gitea_values}
  oc adm policy add-scc-to-user anyuid system:serviceaccount:${gitea_project}:gitea
  oc -n ${gitea_project} create serviceaccount gitea || echo
  helm repo add gitea-charts https://dl.gitea.com/charts/ || echo

  set -x
  helm status gitea -n ${gitea_project} 2> /dev/null || \
  helm install gitea gitea-charts/gitea --version ${GITEA_HELM_VERSION} --values ${helm_gitea_values} -n ${gitea_project} --wait
  set +x

  create_nodeport_extra_ssh_service

  setup_openshift_route

}

function create_nodeport_extra_ssh_service {

  echo "************ telcov10n Create Extra Gitea Node Port service into the Hub cluster ************"

  set -x
  gitea_ssh_service_name=$(oc -n ${gitea_project} get svc -oname|grep 'ssh'|grep -v '\-np$'|cut -d'/' -f2)
  set +x

  cat <<EOF | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  labels:
    app: gitea
  name: ${gitea_ssh_service_name}-np
  namespace: ${gitea_project}
spec:
  ports:
  - name: ssh-np
    protocol: TCP
    port: $(oc -n ${gitea_project} get svc ${gitea_ssh_service_name} -ojsonpath='{.spec.ports[0].port}')
    targetPort: $(oc -n ${gitea_project} get svc ${gitea_ssh_service_name} -ojsonpath='{.spec.ports[0].targetPort}')
  selector:
    app.kubernetes.io/instance: gitea
    app.kubernetes.io/name: gitea
  type: NodePort
EOF
}

function setup_openshift_route {

  echo "************ telcov10n Setup route to Gitea repo ************"

  set -x
  gitea_k8s_service_name=$(oc -n ${gitea_project} get service --no-headers -o custom-columns=":metadata.name"|grep http)
  gitea_k8s_service_port=$(oc -n ${gitea_project} get service ${gitea_k8s_service_name} -ojsonpath='{.spec.ports[?(.name=="http")].port}' | jq -r)
  set +x
  cat << EOF | oc apply -f -
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: gitea
  namespace: ${gitea_project}
spec:
  to:
    kind: Service
    name: ${gitea_k8s_service_name}
  port:
    targetPort: ${gitea_k8s_service_port}
  tls:
    termination: edge
  wildcardPolicy: None
EOF

  gitea_url_k8s_service="http://${gitea_k8s_service_name}.${gitea_project}:${gitea_k8s_service_port}"
  gitea_url="https://$(oc -n ${gitea_project} get route gitea -ojsonpath='{.spec.host}')"
  echo -n "${gitea_url}" > ${SHARED_DIR}/gitea-url.txt
  echo "Wait until Gitea endpoint is reachable via openshift route..."
  wait_until_command_is_ok "${_curl} -sSIk -w %{http_code} ${gitea_url} | tail -1 | grep -w '200'"
}

function generate_gitea_ssh_keys {

  echo "************ telcov10n Generate SSH keys for Gitea repo ************"

  ssh_pri_key_file=${SHARED_DIR}/ssh-key-${gitea_project}
  ssh_pub_key_file="${ssh_pri_key_file}.pub"
  if [[ ! -f ${ssh_pri_key_file} || ! -f ${ssh_pub_key_file} ]]; then
    yes | ssh-keygen -N '' -f ${ssh_pri_key_file} -C "${gitea_project}-SSH-Public-Key"
    chmod 0600 ${ssh_pri_key_file}*

    cp -v ${ssh_pri_key_file}* ${ARTIFACT_DIR}/

    echo
    cat ${ssh_pri_key_file}
    echo
  else
    echo
    echo "Skipping SSH keys generation. Using available ones."
    echo
  fi
}

function use_shared_ssh_keys_from_vault {

  echo "************ telcov10n use shared ssh keys from vault ************"

  ssh_pri_key_file=${SHARED_DIR}/ssh-key-${gitea_project}
  ssh_pub_key_file="${ssh_pri_key_file}.pub"

  #### SSH Private key
  cat /var/run/telcov10n/ansible-group-all/ansible_ssh_private_key >| ${ssh_pri_key_file}
  chmod 0600 ${ssh_pri_key_file}

  #### SSH Public key
  cat /var/run/telcov10n/ansible-group-all/ssh_public_key >| ${ssh_pub_key_file}
  chmod 0644 ${ssh_pub_key_file}

  ls -lhtr ${ssh_pri_key_file}*
}

function upload_gitea_ssh_keys {

  echo "************ telcov10n Upload SSH Public key for Gitea repo ************"

  ssh_key_json=$(mktemp --dry-run)
  echo '{"title":"Gitea ZTP SSH Pub key", "key":"'"$(cat ${ssh_pub_key_file})"'"}' > ${ssh_key_json}
  set -x
  ${_curl} -vLk -X POST \
    -u ${GITEA_ADMIN_USERNAME}:${gitea_admin_pass} \
    -H "Content-Type: application/json" \
    -d @${ssh_key_json} \
    "$(cat ${SHARED_DIR}/gitea-url.txt)/api/v1/admin/users/${GITEA_ADMIN_USERNAME}/keys"
  set +x
}

function create_ztp_gitea_repo {

  echo "************ telcov10n Create ZTP Gitea repo ************"

  repo_name="telcov10n"
  set -x
  ${_curl} -vLk -X POST \
    -u ${GITEA_ADMIN_USERNAME}:${gitea_admin_pass} \
    -H "Content-Type: application/json" \
    -d '{"name":"'${repo_name}'"}' \
    -o /tmp/repo-request.json \
    "$(cat ${SHARED_DIR}/gitea-url.txt)/api/v1/user/repos"
  set +x

  new_repo_created="no"
  cat /tmp/repo-request.json | \
    grep 'The repository with the same name already exists.' || new_repo_created="yes"

  echo -n "${gitea_url_k8s_service}/${GITEA_ADMIN_USERNAME}/${repo_name}" > ${SHARED_DIR}/gitea-http-repo-uri.txt
}

function generate_gitea_ssh_uri {

  echo "************ telcov10n Generate ZTP Git SSH uri ************"

  gitea_ssh_host="gitea-ssh.${gitea_project}"
  gitea_ssh_port="2222"
  gitea_ssh_uri="ssh://git@${gitea_ssh_host}:${gitea_ssh_port}/${GITEA_ADMIN_USERNAME}/${repo_name}.git"
  gitea_ssh_nodeport_host=$(oc get node -ojsonpath='{.items[0].status.addresses[?(.type=="InternalIP")].address}')
  gitea_ssh_nodeport_service_name=$(oc -n ${gitea_project} get service -oname|grep 'ssh-np$'|cut -d'/' -f2)
  gitea_ssh_nodeport_service_port=$(oc -n ${gitea_project} get service -ojsonpath='{.items[?(.metadata.name == "'${gitea_ssh_nodeport_service_name}'")].spec.ports[0].nodePort}')
  gitea_ssh_nodeport_service="ssh://git@${gitea_ssh_nodeport_host}:${gitea_ssh_nodeport_service_port}/${GITEA_ADMIN_USERNAME}/${repo_name}.git"
  set -x
  echo -n "${gitea_ssh_uri}" > ${SHARED_DIR}/gitea-ssh-uri.txt
  echo -n "${gitea_ssh_nodeport_service}" > ${SHARED_DIR}/gitea-ssh-nodeport-uri.txt
  set +x
}

function create_ztp_branch {

  echo "************ telcov10n Create ZTP Git branch ************"

  run_script=$(mktemp --dry-run)

  cat <<EOF > ${run_script}
set -o nounset
set -o errexit
set -o pipefail

echo "$(cat ${ssh_pri_key_file})" > /tmp/ssh-prikey
chmod 0400 /tmp/ssh-prikey

set -x
nc -vz ${gitea_ssh_host} ${gitea_ssh_port}

if [[ "${new_repo_created}" == "yes" ]]; then

  ztp_repo_dir=\$(mktemp -d)
  cd \${ztp_repo_dir}
  echo "# Telco Verification" > README.md
  echo "$(cat ${ssh_pri_key_file}.pub)" >> README.md
  echo "$(cat ${ssh_pri_key_file})" >> troubleshooting-info.md
  git config --global user.email "${gitea_project}@telcov10n.com"
  git config --global user.name "ZTP Gitea Telco Verification"
  git config --global init.defaultBranch main
  git init
  git checkout -b main
  git add README.md
  git add troubleshooting-info.md
  git commit -m "First commit by ${NAMESPACE}"
  git remote add origin ${gitea_ssh_uri}
  GIT_SSH_COMMAND="ssh -v -o StrictHostKeyChecking=no -i /tmp/ssh-prikey" git push -u origin main
else
    set +x
    echo
    echo "The ZTP GitOps repo '${repo_name}' already exist. Do nothing..."
    echo
fi
EOF

  run_script_on_ocp_cluster ${run_script} ${gitea_project} "${NAMESPACE}-helper"
}

function main {
  set_hub_cluster_kubeconfig
  create_gitea_deployment
  # generate_gitea_ssh_keys
  use_shared_ssh_keys_from_vault
  upload_gitea_ssh_keys
  create_ztp_gitea_repo
  generate_gitea_ssh_uri
  create_ztp_branch
}

main
