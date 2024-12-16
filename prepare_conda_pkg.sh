#!/bin/bash

source $(dirname "${BASH_SOURCE[0]}")/argparse.sh
source $(dirname "${BASH_SOURCE[0]}")/log.sh

function display_help() {
    echo "Usage: ${0##*/} [PACKAGE] [OPTIONS]"
    echo_wrapped 0 "Prepare a PyPI package for submission to conda-forge. This script will"
    echo
    echo_wrapped 6 " 1. Fork the 'conda-forge/staged-recipes' repository if not already forked,"
    echo_wrapped 6 " 2. Create a new branch,"
    echo_wrapped 6 " 3. Generate a recipe for the specified package using 'grayskull',"
    echo_wrapped 6 " 4. And open the recipe for editing."
    echo ""
    echo "Arguments:"
    echo "  PACKAGE             The name of the PyPI package to prepare."
    echo ""
    echo "Options:"
    echo_wrapped 22 "  -h, --help          Display this help message."
    echo_wrapped 22 "  -v, --verbose       Enable verbose mode."
    echo_wrapped 22 "  -d, --work-dir      Specify the directory where conda-forge/staged-recipes will be cloned to. Defaults to '.'"
    echo_wrapped 22 "  -u, --github-user   Specify the GitHub username. Defaults to the user set in the git configuration or associated with the token (in that order)."
    echo_wrapped 22 "  -e, --github-email  Specify the GitHub email. Defaults to the email set in the git configuration or associated with the token (in that order)."
    echo_wrapped 22 "  -y, --yes           Skip all prompts and confirmations."
    echo ""
    echo "Extra:"
    echo_wrapped 4 "  - This script requires the 'gh' CLI and 'grayskull' to be installed."
    echo_wrapped 4 "  - The 'gh' CLI must be authenticated with GitHub."
    echo_wrapped 4 "  - The 'grayskull' package can be installed with 'python -m pip install grayskull'."
    echo ""
    echo "About:"
    echo "  Author: Dominic Tarro"
    echo "  GitHub: https://github.com/dominictarro"
    echo "  License: MIT"
}

# # Check for help flag
if check_flag "-h" "--help" "$@"; then
    display_help
    exit 0
fi

args="$@"

# Check for verbose flag
VERBOSE=`check_flag "-v" "--verbose" $args && echo "true" || echo "false"`
if [[ "$VERBOSE" == "true" ]]; then
    args=$(consume_flag "-v" "--verbose" $args)
fi
# Get work directory
WORK_DIR=`get_param_value "-d" "--work-dir" $args`
if [ -z "$WORK_DIR" ]; then
    WORK_DIR="."
else
    args=$(consume_param_value "-d" "--work-dir" $args)
fi
# Get GitHub user
GITHUB_USER=`get_param_value "-u" "--github-user" $args`
if [ -z "$GITHUB_USER" ]; then
    GITHUB_USER=""
else
    args=$(consume_param_value "-u" "--github-user" $args)
fi
# Get GitHub email
GITHUB_EMAIL=`get_param_value "-e" "--github-email" $args`
if [ -z "$GITHUB_EMAIL" ]; then
    GITHUB_EMAIL=""
else
    args=$(consume_param_value "-e" "--github-email" $args)
fi
# Check for yes flag
NO_PROMPT=`check_flag "-y" "--yes" $args && echo "true" || echo "false"`
if [[ "$NO_PROMPT" == "true" ]]; then
    args=$(consume_flag "-y" "--yes" $args)
fi

# Get the package name
PACKAGE=`get_positional_arg 0 $args`
if [ -z "$PACKAGE" ]; then
    log_error "Package name is required."
    exit 1
fi

if [ ! -d "$WORK_DIR" ]; then
    log_error "Directory '$WORK_DIR' does not exist."
    exit 1
fi

# Validate git installed/in path
if ! command -v git &> /dev/null; then
    log_error "git is not installed or in PATH (remarkably. you live under a rock?). Please install it and try again."
    exit 1
fi

# Validate gh installed/in path
if ! command -v gh &> /dev/null; then
    log_error "gh CLI is not installed or in PATH. Please install it and try again."
    exit 1
fi

# Validate gh authenticated
if ! gh auth status &> /dev/null; then
    log_error "You are not authenticated with GitHub. Please authenticate and try again."
    exit 1
fi
GH_VALIDATED=true

# Validate grayskull installed
if ! command -v grayskull &> /dev/null; then
    if [ -z "`python -m pip show grayskull`" ]; then
        log_error "grayskull is not installed. Please install it with `python -m pip install grayskull` and try again."
        exit 1
    fi
fi

# Set the github user
GITHUB_USER=`get_param_value "-u" "--github-user" "$@"`
if [ -z "$GITHUB_USER" ]; then
    log_verbose "Attempting to retrieve GitHub user from git configuration."
    GITHUB_USER=`git config --get remote.origin.url | sed 's/.*github.com\///' | sed 's/\/.*\.git//'`
    if [ -z "$GITHUB_USER" ]; then
        log_verbose "Attempting to retrieve GitHub user from gh CLI."
        GITHUB_USER=`gh api user | jq -r .login | sed 's/null//'`
        if [ -z "$GITHUB_USER" ]; then
            log_error "Unable to retrieve GitHub user."
            exit 1
        fi
    fi

    if [[ $NO_PROMPT == "false" ]]; then
        read -p "GitHub user [$GITHUB_USER]: " input
        GITHUB_USER=${input:-$GITHUB_USER}
    else
        log_info "GitHub user: $GITHUB_USER"
    fi
fi

# Get the GitHub email
GITHUB_EMAIL=`get_param_value "-e" "--github-email" "$@"`
if [ -z "$GITHUB_EMAIL" ]; then
    log_verbose "Attempting to retrieve GitHub email from git configuration."
    GITHUB_EMAIL=`git config --get user.email`
    if [ -z "$GITHUB_EMAIL" ]; then
        log_verbose "Attempting to retrieve GitHub email from gh CLI."
        GITHUB_EMAIL=`gh api user | jq -r .email | sed 's/null//'`
        if [ -z "$GITHUB_EMAIL" ]; then
            log_error "Unable to retrieve GitHub email."
            exit 1
        fi
    fi
    if [[ $NO_PROMPT == "false" ]]; then
        read -p "GitHub email [$GITHUB_EMAIL]: " input
        GITHUB_EMAIL=${input:-$GITHUB_EMAIL}
    else
        log_info "GitHub email: $GITHUB_EMAIL"
    fi
fi

cd $WORK_DIR

# Set up the repository on local and remote
if [[ `gh repo view "$GITHUB_USER/staged-recipes" --json parent --jq .parent.owner.login` == "conda-forge" ]]; then
    log_verbose "Repository 'conda-forge/staged-recipes' has already been forked. Fetching the latest changes..."
    if ! [ -d "staged-recipes" ]; then
        run_with_verbosity gh repo clone $GITHUB_USER/staged-recipes
        cd staged-recipes
    else
        cd staged-recipes
        if ! [ -d ".git" ]; then
            log_error "Directory 'staged-recipes' exists but is not a git repository."
            exit 1
        fi

        # Check for local changes that need to be stashed
        if ! [ -z "`git diff-index --quiet HEAD --`" ]; then
            log_error "There are local changes that need to be stashed before fetching the latest changes."
            run_with_verbosity git status
            exit 1
        fi
    fi
    run_with_verbosity git checkout main
    # Get the latest changes
    run_with_verbosity gh repo sync
else
    log_verbose "Forking 'conda-forge/staged-recipes'."
    run_with_verbosity gh repo fork conda-forge/staged-recipes --clone --remote
    cd staged-recipes
fi

# Create a new branch
run_with_verbosity git checkout -b "add-"$PACKAGE""

cd recipes

run_with_verbosity python -m grayskull pypi "$PACKAGE"
if [ $? -ne 0 ]; then
    log_error "Failed to generate the recipe for "$PACKAGE"."
    exit 1
fi

log_info "Please review and edit the recipe at '`pwd`/"$PACKAGE"/meta.yaml'."
