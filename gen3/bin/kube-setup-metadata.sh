#!/bin/bash
#
# Deploy the metdata service.
#

source "${GEN3_HOME}/gen3/lib/utils.sh"
gen3_load "gen3/gen3setup"


setup_database() {
  gen3_log_info "setting up metadata service ..."

  if [[ -n "$JENKINS_HOME" || ! -f "$(gen3_secrets_folder)/creds.json" ]]; then
    gen3_log_err "skipping db setup in non-adminvm environment"
    return 1
  fi
  if ! g3kubectl describe secret metadata-g3auto > /dev/null 2>&1; then
    if ! gen3 db setup metadata; then
      gen3_log_err "Failed setting up database for metadata service"
      return 1
    fi
  fi

  local secretsFolder="$(gen3_secrets_folder)/g3auto/metadata"
  if [[ ! -f "$secretsFolder/dbcreds.json" ]]; then
    gen3_log_err "dbcreds not present in Gen3Secrets/"
    return 1
  fi
  # Setup .env file that metadataservice consumes
  password="$(gen3 random)"
  cat - > "$secretsFolder/metadata.env" <<EOM
DEBUG=0
DB_HOST=$(jq -r .db_host < "$secretsFolder/dbcreds.json")
DB_USER=$(jq -r .db_username < "$secretsFolder/dbcreds.json")
DB_PASSWORD=$(jq -r .db_password < "$secretsFolder/dbcreds.json")
DB_DATABASE=$(jq -r .db_database < "$secretsFolder/dbcreds.json")
ADMIN_LOGINS=gateway:$password
EOM
  # make it easy for nginx to get the Authorization header ...
  echo -n "gateway:$password" | base64 > "$secretsFolder/base64Authz.txt"

  gen3 secrets sync 'setup metadata-g3auto secrets'
}

if !g3k_manifest_lookup .versions.metadata 2> /dev/null; then
  gen3_log_info "kube-setup-metadata exiting - metadata service not in manifest"
  exit 0
fi

if ! setup_database; then
  gen3_log_err "kube-setup-metadata bailing out - database failed setup"
  exit 0
fi

gen3 roll metadata
g3kubectl apply -f "${GEN3_HOME}/kube/services/metadata/metadata-service.yaml"

gen3_log_info "The metadata service has been deployed onto the kubernetes cluster"
