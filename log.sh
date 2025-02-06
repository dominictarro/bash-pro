DATE_FORMAT="%Y-%m-%d %H:%M:%S"

export DATE_FORMAT

function log_raw() {
    timestamp=$(date +"$DATE_FORMAT")
    level=$1
    color=$2
    message=$3
    echo -e "[${timestamp}] \033[1;${color}m$(printf '%-8s' $level)\033[0m| ${message}"
}

function log_info() {
    log_raw INFO 32 "$1"
}

function log_error() {
    log_raw ERROR 31 "$1" >&2
}

function log_warning() {
    log_raw WARNING 33 "$1" >&2
}

function log_debug() {
    log_raw DEBUG 34 "$1"
}

function log_verbose() {
    if [ "$VERBOSE" == "true" ]; then
        log_raw VERBOSE 36 "$1"
    fi
}

function run_with_verbosity() {
    if [ "$VERBOSE" == "true" ]; then
        "$@" 2> >(while read -r line; do log_warning "$line"; done) | while read -r line; do log_verbose "$line"; done
    else
        "$@" 2> >(while read -r line; do log_warning "$line"; done)
    fi
}

WRAP_LINE_LENGTH=$(( $(tput cols) * 90 / 100 ))
export WRAP_LINE_LENGTH


function echo_wrapped() {
    wrapped_indent_length=$(( $1 ))
    if [ $wrapped_indent_length -lt 0 ]; then
        log_error "Indent length must be greater than or equal to 0."
        return 1
    elif [ $wrapped_indent_length -ge $WRAP_LINE_LENGTH ]; then
        log_error "Indent length must be less than or equal to $WRAP_LINE_LENGTH."
        return 1
    fi
    shift
    local message="$*"
    if [ ${#message} -le $WRAP_LINE_LENGTH ]; then
        echo -e "$message"
        return
    fi
    is_wrapped_line=false
    while true; do
        end=$WRAP_LINE_LENGTH
        if [[ $is_wrapped_line == true ]]; then
            message="$(printf "%${wrapped_indent_length}s" " ")${message# }"
        fi
        if [ $end -ge ${#message} ]; then
            echo -e "$message"
            break
        fi
        while [ "${message:$end:1}" != " " ] && [ $end -gt 0 ]; do
            end=$((end-1))
        done
        if [[ $is_wrapped_line == false ]]; then
            echo -e "${message:0:$end}"
            is_wrapped_line=true
        else
            echo -e "${message:0:$end}"
        fi
        message="${message:$end:${#message}}"
    done
}


export -f log_info log_error log_warning log_debug log_verbose run_with_verbosity echo_wrapped
