#!/bin/sh

GIT_HOST=${1:-git@gitlab.com:soerenschneider}
GIT_PROJECTS=${2:-~/src/gitlab}
REPOS=(ansibles ansible-roles)

function log() {
    echo "*** $1"
}

function installRequirements() {
    log "installing required packages..."
    sudo dnf -qy install git ansible gnupg2
    log "done!"
}

function restartGpgAgent() {
    # restart gpg-agent and start it again with ssh support
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
        ln -s ${GIT_PROJECTS}/ansible-roles ~/.ansible/roles
    fi

    ansible-playbook ${GIT_PROJECTS}/ansibles/playbooks/desktop/fedora.yaml
}

populateSecrets() {
    echo -n "Populate secrets? "
    read answer
    case $answer in
        [Yy]* ) sh ${GIT_PROJECTS}/dotfiles/populate-secrets.sh ; break;;
        * ) return ;;
    esac
}

installRequirements
restartGpgAgent
checkoutProjects
runAnsibleBootstrapPlaybook
populateSecrets
