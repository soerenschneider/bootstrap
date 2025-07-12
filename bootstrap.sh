#!/usr/bin/env bash

set -e

GIT_HOST=${1:-git@github.com:soerenschneider}
GIT_PROJECTS=${2:-~/src/github}
REPOS=(ansible ansible-inventory-prod)

log() {
    echo "*** $1"
}

installRequirements() {
    log "installing required packages..."
    sudo dnf -qy install git ansible gnupg2 pcsc-lite stow pcsc-cyberjack make
    log "done!"
    log "making sure pcscd is started"
    sudo systemctl start pcscd
}

restartGpgAgent() {
    # create gpg dir with correct permissions
    gpg2 --list-keys > /dev/null

    # if the gpg-agent is not running, start it
    if ! gpg-connect-agent /bye ; then
        gpg-agent --daemon --enable-ssh-support
    fi

    # check if gpg-agent needs to be restarted with ssh support
    if ! gpgconf --list-options gpg-agent | grep -q enable-ssh-support ; then
        log "restarting gpg-agent"
        gpgconf --kill gpg-agent
        gpg-agent --daemon --enable-ssh-support
        log "done!"
    else
        log "restarting gpg-agent not necessary..."
    fi

    # set env vars to make ssh use gpg agent
    GPG_TTY=$(/usr/bin/tty)
    export SSH_AUTH_SOCK="${XDG_RUNTIME_DIR}/gnupg/S.gpg-agent.ssh"
    export GPG_TTY SSH_AUTH_SOCK
    gpg-connect-agent updatestartuptty /bye > /dev/null
}

fetchCardKeys() {
    GENERAL_KEY_INFO=$(gpg2 --card-status | grep -e "^General key info" | awk -F ":" '{print $2}' | tr -d "[:space:]")
    
    if [ '[none]' = "${GENERAL_KEY_INFO}" ]; then
        log "Trying to fetch key"
        # fetch key
        KEY_SOURCE=$(gpg2 --card-status | grep ^URL | cut -d":" -f 2-3 | tr -d "[:space:]")
        if [ ! -z ${KEY_SOURCE} ]; then
            curl -sSL ${KEY_SOURCE} | gpg2 --import -
        fi
    else
        log "Not fetching key"
    fi
}

checkoutProjects() {
    if [ ! -d ${GIT_PROJECTS} ]; then
        log "creating dir: ${GIT_PROJECTS}"
        mkdir -p ${GIT_PROJECTS}
    fi

    for repo in "${REPOS[@]}"; do
        if [ -d ${GIT_PROJECTS}/${repo} ]; then
            log "pulling changes from ${GIT_PROJECTS}/${repo}"
            git -C ${GIT_PROJECTS}/${repo} pull
        else
            log "cloning ${GIT_PROJECTS}/${repo}"
            git clone ${GIT_HOST}/${repo} ${GIT_PROJECTS}/${repo}
        fi
    done
}

runAnsibleBootstrapPlaybook() {
    # invoke ansible to create .ansible dir
    ansible --help > /dev/null

    if [ ! -L ~/.ansible/roles ]; then
        ln -s ${GIT_PROJECTS}/ansible/roles ~/.ansible/roles
    fi

    # get aboslute path of the dir this file resides in
    HERE=$(dirname $(readlink -f $0))
    ansible-playbook "${HERE}/playbook/playbook.yaml"
}

populateSecrets() {
    echo -n "Populate PIM secrets? "
    read answer
    case $answer in
        [Yy]* ) sh ${GIT_PROJECTS}/dotfiles/populate-secrets.sh;;
        * ) return ;;
    esac

    echo -n "Populate ansible secrets? "
    read answer
    case $answer in
        [Yy]* ) sh ${GIT_PROJECTS}/dotfiles/populate-ansible.sh;;
        * ) return ;;
    esac

    echo -n "Populate taskwarrior secrets? "
    read answer
    case $answer in
        [Yy]* ) sh ${GIT_PROJECTS}/dotfiles/populate-taskwarrior.sh;;
        * ) return ;;
    esac
}

# moves the content of the "old" xdg directories to its new counterparts
moveOldXdgDirs() {
    egrep "^[[:alpha:]]{1,}=[[:alpha:]]{1,}" /etc/xdg/user-dirs.defaults | while read line; do
        key=$(echo "${line}" | awk -F "=" '{print $1}');
        val=$(echo "${line}" | awk -F "=" '{print $2}');
        if [ -d ~/${val} ]; then
            NEW_DIR=$(xdg-user-dir ${key})
            log "${HOME}/${val} exists, moving to ${NEW_DIR}"
            if [ -n "$(ls -A ${val})" ]; then
                mv ~/${val}/* ${NEW_DIR}/
            fi
            rmdir ~/${val}
        fi
    done
}

installRequirements
restartGpgAgent
fetchCardKeys
checkoutProjects
runAnsibleBootstrapPlaybook
populateSecrets
moveOldXdgDirs
