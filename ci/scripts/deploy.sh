#!/bin/bash
set -eu

echo "Retrieving environment variables for deployment..."
# Load Vault environment variables
source ./vault-env.tmp

echo "operating in working dir: $(pwd)"

# Echo a version number into /version/number in one is not specified
# Create version number file if it doesn't exist
if [[ -z "${VERSION_FROM:-}" ]]; then
    export VERSION_FROM="./version/number"
fi
if [[ ! -f "${VERSION_FROM}" ]]; then
    mkdir -p "$(dirname "${VERSION_FROM}")"
    echo "0.0.1" > "${VERSION_FROM}"
fi

echo "VAULT_TOKEN: ${VAULT_TOKEN:-[not set]}"
echo "VAULT_URI: ${VAULT_URI:-[not set]}"

# Resource Directories
export CI_ROOT="git-ci"
export DEPLOY_ENV="${DEPLOY_ENV:-"ci-baseline"}"
export KEEP_STATE="${KEEP_STATE:-"false"}"
export GIT_NAME="${GIT_NAME:-"Genesis CI Bot"}"
export GIT_EMAIL="${GIT_EMAIL:-"genesis-ci@rubidiumstudios.com"}"

header() {
  echo
  echo "================================================================================"
  echo "$1"
  echo "--------------------------------------------------------------------------------"
  echo
}

bail() {
  echo >&2 "$*  Did you misconfigure Concourse?"
  exit 2
}
test -n "${KIT_SHORTNAME:-}"      || bail "KIT_SHORTNAME must be set to the short name of this kit."
test -n "${VAULT_URI:-}"          || bail "VAULT_URI must be set to an address for connecting to Vault."
test -n "${VAULT_TOKEN:-}"        || bail "VAULT_TOKEN must be set to something; it will be used for connecting to Vault."

[[ -n "${TAG_ROOT:-}" && -n "${BUILD_ROOT:-}" ]] && bail "Cannot specify both 'TAG_ROOT' and 'BUILD_ROOT'"

#  If neither TAG_ROOT nor BUILD_ROOT is set, assume current directory as BUILD_ROOT
#  NOTE: The tarball of the built kit is expected to be in the current directory if this is to work.
if [[ -z "${TAG_ROOT:-}" && -z "${BUILD_ROOT:-}" ]]; then
    echo "WARNING: Neither TAG_ROOT nor BUILD_ROOT was specified. Assuming current directory as BUILD_ROOT."
    echo "NOTE: The tarball of the built kit is expected to be in the current directory if this is to work."
    export BUILD_ROOT="$(pwd)"
fi

WORKDIR="work/${KIT_SHORTNAME}-deployments"
VERSION=
KIT=
if [[ -n "${TAG_ROOT:-}" ]]; then
  test -f "${TAG_ROOT}/.git/ref"   || bail "Version reference for $TAG_ROOT repo not found."
  VERSION="$(sed -e 's/^v//' < "${TAG_ROOT}/.git/ref")"
  re='^[0-9]+\.[0-9]+\.[0-9]+'
  [[ "${VERSION}" =~ $re ]]        || bail "Version reference for $TAG_ROOT repo was not a semver value."
  KIT="$KIT_SHORTNAME/$VERSION"
else
  test -f "${VERSION_FROM}"        || bail "Version file (${VERSION_FROM}) not found."
  VERSION=$(cat "${VERSION_FROM}")
  test -n "${VERSION}"             || bail "Version file (${VERSION_FROM}) was empty."
  KIT="$(cd "$BUILD_ROOT" && pwd)/${KIT_SHORTNAME}-${VERSION}.tar.gz"
fi
header "Setting up git..."
git config --global user.name  "$GIT_NAME"
git config --global user.email "$GIT_EMAIL"
git config --global init.defaultBranch develop

header "Connecting to vault..."
safe target da-vault "$VAULT_URI" -k
echo "$VAULT_TOKEN" | safe auth token
safe read secret/handshake

if [[ "${KEEP_STATE}" == "true" && -d "${WORKDIR}" ]] ; then
  header "Updating Genesis deployment directory for $KIT_SHORTNAME v$VERSION..."
  genesis -v
  if [[ -n "${TAG_ROOT:-}" ]] ; then
    genesis -C "${WORKDIR}" fetch-kit "${KIT}"
  else
    cp -av "$KIT" "${WORKDIR}/.genesis/kits/"
  fi
else
  header "Setting up Genesis deployment directory for $KIT_SHORTNAME v$VERSION..."
  rm -rf work/*; mkdir -p work/
  genesis -v
  genesis -C "$(dirname "$WORKDIR")" init -k "$KIT" --vault da-vault -d "$(basename "$WORKDIR")"
fi

header "Copying test environment YAMLs from $CI_ROOT/ci/envs..."
CI_PATH="$(cd "${CI_ROOT}" && pwd)"
cp -av "$CI_PATH"/ci/envs/*.yml "${WORKDIR}/"
test -f "${WORKDIR}/${DEPLOY_ENV}.yml" || \
  bail "Environment $DEPLOY_ENV.yml was not found in the $CI_ROOT ci/envs/ directory"

target="$(cat <<EOF
---
kit:
  name: $KIT_SHORTNAME
  version: $VERSION
EOF
)"
echo
echo "Merging kit name and version into ${WORKDIR}/ci.yml: "
spruce merge --skip-eval "$CI_PATH/ci/envs/ci.yml" <(echo "$target") > "${WORKDIR}/ci.yml"
cat "${WORKDIR}/ci.yml"

export PATH="$PATH:$CI_PATH/ci/scripts"

echo $'\n'"Handing off to ${CI_PATH}/ci/test-deployment..."
cd "${WORKDIR}"

echo $(ls -la $CI_PATH)
echo "$(cat $CI_PATH/ci/envs/ci-vsphere-baseline.yml)"
echo "$(cat ./ci-vsphere-baseline.yml)"


echo $(ls -lah $CI_PATH/ci/scripts/)
BOSH=bosh "$CI_PATH/ci/scripts/test-deployment.sh"

echo
echo "SUCCESS"
exit 0
