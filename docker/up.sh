#!/usr/bin/env bash

# "To provide additional docker-compose args, set the COMPOSE var. Ex:
# COMPOSE="-f FILE_PATH_HERE"

set -o errexit
set -o pipefail
set -o nounset
# set -o xtrace

ERROR() {
    /bin/echo -e "\e[101m\e[97m[ERROR]\e[49m\e[39m" "$@"
}

WARNING() {
    /bin/echo -e "\e[101m\e[97m[WARNING]\e[49m\e[39m" "$@"
}

INFO() {
    /bin/echo -e "\e[104m\e[97m[INFO]\e[49m\e[39m" "$@"
}

exists() {
    type "$1" > /dev/null 2>&1
}

JEPSEN_ROOT=${JEPSEN_ROOT:-""}

# Change directory to the source directory of this script. Taken from:
# https://stackoverflow.com/a/246128/3858681
pushd "$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

HELP=0
INIT_ONLY=0
DEV=""
COMPOSE=${COMPOSE:-""}
RUN_AS_DAEMON=0
POSITIONAL=()

while [[ $# -gt 0 ]]
do
    key="$1"

    case $key in
        --help)
            HELP=1
            shift # past argument
            ;;
        --init-only)
            INIT_ONLY=1
            shift # past argument
            ;;
        --dev)
            if [ ! "$JEPSEN_ROOT" ]; then
                JEPSEN_ROOT="$(cd ../ && pwd)"
                INFO "JEPSEN_ROOT is not set, defaulting to: $JEPSEN_ROOT"
            fi
            INFO "Running docker-compose with dev config"
            DEV="-f docker-compose.dev.yml"
            shift # past argument
            ;;
        --compose)
            COMPOSE="-f $2"
            shift # past argument
            shift # past value
            ;;
        -d|--daemon)
            INFO "Running docker-compose as daemon"
            RUN_AS_DAEMON=1
            shift # past argument
            ;;
        *)
            POSITIONAL+=("$1")
            ERROR "unknown option $1"
            shift # past argument
            ;;
    esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters

if [ "${HELP}" -eq 1 ]; then
    echo "Usage: $0 [OPTION]"
    echo "  --help                                                Display this message"
    echo "  --init-only                                           Initializes ssh-keys, but does not call docker-compose"
    echo "  --daemon                                              Runs docker-compose in the background"
    echo "  --dev                                                 Mounts dir at host's JEPSEN_ROOT to /jepsen on jepsen-control container, syncing files for development"
    echo "  --compose PATH                                        Path to an additional docker-compose yml config."
    echo "To provide multiple additional docker-compose args, set the COMPOSE var directly, with the -f flag. Ex: COMPOSE=\"-f FILE_PATH_HERE -f ANOTHER_PATH\" ./up.sh --dev"
    exit 0
fi

exists ssh-keygen || { ERROR "Please install ssh-keygen (apt-get install openssh-client)"; exit 1; }
exists perl || { ERROR "Please install perl (apt-get install perl)"; exit 1; }

# Generate SSH keys for the control node
if [ ! -f ./secret/node.env ]; then
    INFO "Generating key pair"
    mkdir -p secret
    ssh-keygen -t rsa -N "" -f ./secret/id_rsa

    INFO "Generating ./secret/control.env"
    { echo "# generated by jepsen/docker/up.sh, parsed by jepsen/docker/control/bashrc";
      echo "# NOTE: newline is expressed as ↩";
      echo "SSH_PRIVATE_KEY=$(perl -p -e "s/\n/↩/g" < ./secret/id_rsa)";
      echo "SSH_PUBLIC_KEY=$(cat ./secret/id_rsa.pub)"; } >> ./secret/control.env

    INFO "Generating ./secret/node.env"
    { echo "# generated by jepsen/docker/up.sh, parsed by the \"tutum/debian\" docker image entrypoint script";
      echo "ROOT_PASS=root";
      echo "AUTHORIZED_KEYS=$(cat ./secret/id_rsa.pub)"; } >> ./secret/node.env
else
    INFO "No need to generate key pair"
fi

# Make sure folders referenced in control Dockerfile exist and don't contain leftover files
rm -rf ./control/jepsen
mkdir -p ./control/jepsen/jepsen
# Copy the jepsen directory if we're not mounting the JEPSEN_ROOT
if [ -z "${DEV}" ]; then
    # Dockerfile does not allow `ADD ..`. So we need to copy it here in setup.
    INFO "Copying .. to control/jepsen"
    (
        (cd ..; tar --exclude=./docker --exclude=./.git --exclude-ignore=.gitignore -cf - .)  | tar Cxf ./control/jepsen -
    )
fi

if [ "${INIT_ONLY}" -eq 1 ]; then
    exit 0
fi

exists docker ||
    { ERROR "Please install docker (https://docs.docker.com/engine/installation/)";
      exit 1; }
exists docker-compose ||
    { ERROR "Please install docker-compose (https://docs.docker.com/compose/install/)";
      exit 1; }

INFO "Running \`docker-compose build\`"
# shellcheck disable=SC2086
docker-compose -f docker-compose.yml ${COMPOSE} ${DEV} build

INFO "Running \`docker-compose up\`"
if [ "${RUN_AS_DAEMON}" -eq 1 ]; then
    # shellcheck disable=SC2086
    docker-compose -f docker-compose.yml ${COMPOSE} ${DEV} up -d
    INFO "All containers started, run \`docker ps\` to view"
else
    INFO "Please run \`docker exec -it jepsen-control bash\` in another terminal to proceed"
    # shellcheck disable=SC2086
    docker-compose -f docker-compose.yml ${COMPOSE} ${DEV} up
fi

popd
