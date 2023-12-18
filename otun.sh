#!/usr/bin/env bash

# TODO:
#   - Make --config and -c file work, check if right keys are there (bot_token and chat_id). Show error and exit 1 if it fails
#   - Enable/disable send notification also if no updates via parameter
#   - Enable/disable spinner via parameter
#   - Time operations, show time per operation plus total, then remove sleeps. (verbose option?)
#   - Packages dependencies: util-linux (rev), ncurses (tput), jq, yq, hostname (inetutils)
#   - Format the output via terminal (colors, bold) and also via Telegram (Markup/HTML). Check Telegram screenshots for ideas
#   - Include option to disable format/colors (just plain text)
#   - Show error if curl fails or message is not send (currently it doesn't show anything if it doesn't work)
#   - Include systemd, openrc and runit init script / service file and --install and --install-service options
#   - Test all scenarios (make it fail and see what happens, multiple parameters, etc.)
#   - Include manpage
#   - Consistent error messages (format)
#   - Comment everything, write consistent variables (upper and lowercase)
# EXTRA:
#   - Include updates check for: slackware, pclinuxos, void, easyos, puppy, alpine, solus, termux
#   - Try it on debian, ubuntu, redhat, centos, slackware, pclinuxos, void, easyos, puppy, alpine, solus, linux mint via docker
#   - Try it on Termux
#   - Check updates for flatpak, snap, appimage, etc.?
#   - Create release and AUR/GURU package

readonly PROGNAME="otun (On-Telegram Updates Notifier)"
readonly SCRIPTNAME=${0##*/}
readonly VERSION="1.0"

prefix_path=""
config_extension=""

# Define supported distros/families
readonly DISTROS=("arch" "centos" "debian" "fedora" "gentoo" "opensuse" "rhel" "suse")

# Show help/usage multi-line message using a Here Document
help_message() {
    # Define the multi-line string
    read -r -d '' message <<EOF
${PROGNAME} v${VERSION}

Check for updates and notify them (if any) via Telegram bot.

Usage: ${SCRIPTNAME} [OPTIONS]

Options:

-h, --help      Display this help message and exit.
-c, --config    Specify the Telegram bot configuration file (default: telegram_config.json/jaml).
-d, --distro    Specify the Linux family distro manually, disabling auto-detection (supported: arch, debian, gentoo, rhel, suse).
-p, --prefix    Specify the prefix path (location) if you want to run it on your local prefix.
-v, --version   Display script version.
EOF

    # Pretty print the multi-line string
    echo "$message"
}

parse_options() {
    update_current_task "Cheking the command-line options..."
    # Parse command-line options
    while [[ $# -gt 0 ]]; do
        case $1 in
        -h | --help)
            stop_spinner
            help_message
            exit 0
            ;;
        -c | --config)
            config="$2"
            ;;
        -d | --distro)
            auto_distro=false
            supported_distro "$2"
            shift 2
            ;;
        -p | --prefix)
            # It consumes two arguments: option and its value. Otherwise it doesn't work
            check_prefix_path "$2"
            shift 2
            ;;
        -v | --version)
            stop_spinner
            display_version
            exit 0
            ;;
        *)
            stop_spinner
            invalid_option_message "$1"
            exit 1
            ;;
        esac
        shift
    done
}

# Trap signals and call show_cursor function
trap show_cursor EXIT

display_version() {
    echo "$PROGNAME $VERSION"
}

invalid_option_message() {
    echo "$SCRIPTNAME: invalid option '$1'"
    echo "Try '$SCRIPTNAME --help' or '$SCRIPTNAME -h' for more information."
}

# Detect distro family
detect_distro() {
    update_current_task "Detecting the Linux distro/family..."
    # Steps:
    #   - Filter only ID_LIKE from /etc/os-release
    #   - Get only the right side after the =
    #   - Remove double quotes if any
    #   - In case of multiple results (e.g. manjaro arch or ubuntu debian), keep only the latest
    #   - Ensure lowercase
    #   - If no result, try just ID (case for pure Gentoo, Debian, etc.)
    distro=$(cat "$prefix_path"/etc/os-release | grep -w ID_LIKE | awk -F= '{print $2}' | tr -d '"' | rev | cut -d' ' -f1 | rev | tr '[:upper:]' '[:lower:]')
    # In case of no results, so no ID_LIKE, check for ID (no multiple results)
    if [ -z "$distro" ]; then # or [[ $(echo "$distro" | wc -l) -eq 1 ]] since an empty line gives a 1
        distro=$(cat "$prefix_path"/etc/os-release | grep -w ID | awk -F= '{print $2}' | tr -d '"' | tr '[:upper:]' '[:lower:]')
    fi
    if [[ $(echo "$distro" | wc -l) -ne 0 ]]; then
        supported_distro "$distro"
    else
        stop_spinner
        unsupported_distro_message "$distro"
        exit 1
    fi
}

supported_distro() {
    # Ensure lowercase
    distro=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    # Check if the target string is present in the array using the 'in' operator
    if [[ "${DISTROS[*]}" =~ $distro ]]; then
        add_dependencies "" # empty arg to avoid linter multiple warning (exception adding does not fully work)
    else
        stop_spinner
        unsupported_distro_message "$distro"
        exit 1
    fi
}

check_prefix_path() {
    if [ -e "$1" ]; then
        prefix_path=$1
    else
        stop_spinner
        wrong_prefix_path_message "$1"
        exit 1
    fi
}

# Show unsupported distro multi-line message using a Here Document
wrong_prefix_path_message() {
    # Define the multi-line string
    echo "$SCRIPTNAME: the prefix specified prefix path '$1' does not exist."
    echo "Ensure the specified prefix path exists to be able to run the script."
}

add_dependencies() {
    # Include dependencies for each distro to check, also define the udpates check command
    pre_check=""
    case "$distro" in
    arch)
        DISTRO_DEP+=(aur checkupdates)
        updates_check="checkupdates & pacman -Qm | aur vercmp & wait"
        ;;
    debian)
        DISTRO_DEP+=(aptitude)
        updates_check="aptitude search '~U' -F '%p %v -> %V' | tr -s ' '"
        ;;
    gentoo)
        DISTRO_DEP+=(eix)
        pre_check="emerge-webrsync -q >/dev/null 2>&1 && eix-update -q >/dev/null 2>&1"
        updates_check="NAMEVERSION=\"<category>/<name> <version>\" INSTFORMAT=\"{last}<version>\" eix --upgrade --format '<installedversions:NAMEVERSION> -> <bestslotupgradeversions:INSTFORMAT>\n' | head -n -1"
        ;;
    rhel | fedora | centos)
        pre_check="dnf list --installed > installed_packages.txt && dnf check-update > available_packages.txt"
        updates_check="awk 'NR==FNR{a[\$1]=\$2;next} \$1 in a{print \$1, a[\$1], \"->\", \$2}' installed_packages.txt available_packages.txt"
        ;;
    suse | opensuse)
        updates_check="zypper list-updates | sed '1,/^Reading installed packages...$/d' | sed '1,2d' | sed -n 's/.*| \([^ ]*\) *| \([^ ]*\) *| \([^ ]*\) *| [^|]*$/\1 \2 -> \3/p'"
        ;;
    esac
    DEPENDENCIES+=("${DISTRO_DEP[@]}")
}

# Show unknown distro multi-line message using a Here Document
unknown_distro_message() {
    # Define the multi-line string
    read -r -d '' message <<EOF
$SCRIPTNAME: unknown Linux distribution/family '$distro'.

Make sure your distro or distro family is specified on /etc/os-release via ID_LIKE or ID variables.
Otherwise, specify your distro family via --distro or -d parameter (possible values: arch, debian, gentoo, rhel, suse).
Alternatively, you can always open an issue or a pull request to include your distro or family distro on https://github.com/mvidaldp/otun"
EOF
    # Pretty print the multi-line string
    echo "$message"
}

# Show unsupported distro multi-line message using a Here Document
unsupported_distro_message() {
    # Define the multi-line string
    read -r -d '' message <<EOF
$SCRIPTNAME: the distro '$distro' is not (yet) supported.

The possible distro/family values are arch, debian, gentoo, rhel, suse.
You can always open an issue or a pull request to include your distro or family distro on https://github.com/mvidaldp/otun"
EOF
    # Pretty print the multi-line string
    echo "$message"
}

# Check for depenencies to run the script, include distro-based dependencies (e.g. eix for Gentoo, aptitude for Debian, etc.)
# Separate distro dependencies than others (e.g. checkupdates for Arch)
DEPENDENCIES=("awk" "curl" "hostname" "jq" "lsb_release" "uname" "yq")
DISTRO_DEP=()

check_dependencies() {
    update_current_task "Checking the required dependencies..."
    REQUIRED=()
    for i in "${DEPENDENCIES[@]}"; do
        command -v "$i" >/dev/null 2>&1 || {
            REQUIRED+=("$i")
        }
    done

    # Show the missing commands/dependencies found and exit the script if any
    if [[ "${#REQUIRED[*]}" -gt 0 ]]; then
        stop_spinner
        echo "$SCRIPTNAME: to run this script, you need the following commands/dependencies:"
        echo "${REQUIRED[@]}"
        exit 1
    fi
}

read_telegram_config() {
    update_current_task "Reading the Telegram bot configuration..."
    # Read Telegram bot configuration
    command=""
    if [ "$config_extension" = "yaml" ]; then
        command="yq"
    else
        command="jq"
    fi
    TELEGRAM_BOT_TOKEN=$($command -r .bot_token telegram_config.$config_extension)
    CHAT_ID=$($command -r .chat_id telegram_config.$config_extension)
}

fetch_system_info() {
    update_current_task "Fetching the system information..."
    # Get current hostname
    HOSTNAME=$(hostname)

    # Get OS description
    os_description=$(lsb_release -s -d | tr -d '\n"')
    # Get OS release
    os_release=$(lsb_release -s -r | tr -d '\n" ')
    # Put description and release together if release is not in description already
    if [[ $os_description == *"$os_release"* ]]; then
        OS="$os_description"
    else
        OS="$os_description $os_release"
    fi
    ARCH=$(uname -m)

    # Get current IP address
    IP=$(curl -s ifconfig.me)

    # Append message content
    MESSAGE="HOSTNAME: $HOSTNAME\n"
    MESSAGE+="OS: $OS ($ARCH)\n"
    MESSAGE+="IP: $IP\n"
}

pre_updates_error() {
    echo -e "$SCRIPTNAME: something went wrong running '$1'.\n"
    echo "Ensure this pre-update check command runs to be able to check for updates."
}

check_for_updates() {
    update_current_task "Checking for updates..."
    # Evaluates if pre-check is an empty string
    if [[ -n $pre_check ]]; then
        # Execute the pre updates check command
        eval "$pre_check"
        exit_status=$?
        # Evaluates if running the pre-check command failed (non-zero exit status)
        if [ $exit_status -ne 0 ] && [ $exit_status -ne 100 ]; then
            stop_spinner
            pre_updates_error "$pre_check"
            exit 1
        fi
    fi
    # Check if updates are available
    UPDATES=$(eval "$updates_check")
    # Updates states:
    # 0: Normal exit condition. => list of results
    # 1: Unknown cause of failure. => error
    # 2: No updates available. => 0 results

    # Updates counter
    N_UPDATES=$(echo "$UPDATES" | wc -l)

    updates_found=false

    # Code block executed if there are updates available:
    # [[ ... ]] -> if var not empty
    # -n $VAR -> if string length is nonzero
    if [[ -n $UPDATES ]]; then
        updates_found=true
        send_info "$N_UPDATES" "$updates_found"
    else
        # Append message content
        MESSAGE+="\nNo updates were found. This system is up to date."
        send_info "$N_UPDATES" "$updates_found"
    fi

    # Stop the spinner
    stop_spinner
    printf "\r%s\n\n" "Process completed!"
    # Log message via terminal
    echo -e "$MESSAGE"
}

# Maximum message length for Telegram is 4096 characters
readonly MAX_MESSAGE_LENGTH=4096

send_info() {
    update_current_task "Sending the updates notification via Telegram..."

    local n_updates=$1
    local updates_found=$2

    if "$updates_found"; then
        # Use "is" and "update if only 1 udpate, otherwise "are" and "updates"
        IS_ARE=$([ "$n_updates" == 1 ] && echo "is" || echo "are")
        S=$([ "$IS_ARE" == "is" ] && echo "" || echo "s")

        # Append message content
        MESSAGE+="\nThere $IS_ARE $n_updates update$S available:\n"
        MESSAGE+="$UPDATES"
    fi
    # Check if the message exceeds the maximum length
    if [ ${#MESSAGE} -gt $MAX_MESSAGE_LENGTH ]; then

        max_size=4096
        current_chunk=""
        current_size=0

        # Use readarray to populate the array with lines
        readarray -t lines <<<"$MESSAGE"

        # Iterate over each line
        for line in "${lines[@]}"; do
            line_size=${#line}

            # Check if adding the line exceeds the chunk size
            if ((current_size + line_size > max_size - 256)); then
                # Remove the last line break
                current_chunk=$(echo "$current_chunk" | sed '$s/\\n$//')
                # Output the current chunk
                chunk=$(echo -e "$current_chunk")
                # Send message via telegram bot
                curl -s -o /dev/null -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" -d "chat_id=$CHAT_ID" -d "text=$chunk"
                # Start a new chunk with the current line
                current_chunk="$line\n"
                current_size=$line_size
            else
                # Append the line to the current chunk
                current_chunk+="$line\n"
                current_size=$((current_size + line_size + 1))
            fi
        done
        # Send last chunk
        chunk=$(echo -e "$current_chunk")
        # Send message via telegram bot
        curl -s -o /dev/null -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" -d "chat_id=$CHAT_ID" -d "text=$chunk"
    else
        # Include linebreaks
        MESSAGE=$(echo -e "$MESSAGE")
        # Send message via telegram bot
        curl -s -o /dev/null -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" -d "chat_id=$CHAT_ID" -d "text=$MESSAGE"
    fi
}

current_task=""
# Global variable to store the spinner process ID
spinner_pid=""

run_spinner() {
    local chars="/-\|"
    local delay=0.04
    local i=0
    while true; do
        printf "\r%s %s" "${chars:$i:1}" "$current_task"
        ((i = (i + 1) % ${#chars}))
        sleep $delay
    done
}

# Stop the spinner
stop_spinner() {
    if [[ -n "$spinner_pid" ]]; then
        kill "$spinner_pid" &>/dev/null
        wait "$spinner_pid" &>/dev/null
        tput el
    fi
}

# Function to update the current task
update_current_task() {
    tput el
    echo -ne "$1"\\r
}

# Hide the cursor
hide_cursor() {
    tput civis
}

# Show the cursor
show_cursor() {
    tput cnorm
}

# Show unsupported distro multi-line message using a Here Document
config_file_not_found() {
    # Define the multi-line string
    read -r -d '' message <<EOF
$SCRIPTNAME: No config file (telegram_config.yaml/json) was found.

Make sure you have your telegram bot config file on the same folder of this script with the following content:

telegram_config.yaml
====================
bot_token: "yourtoken"
chat_id: "-yourchatid"

telegram_config.json
====================
{
    "bot_token": "yourtoken",
    "chat_id": "-yourchatid"
}
EOF
    # Pretty print the multi-line string
    echo "$message"
}

check_config() {
    # TODO: include case for custom YAML/JSON
    update_current_task "Checking if Telegram config file (YAML/JSON) exists..."
    # check if YAML config file exists
    if [ -e telegram_config.yaml ]; then
        config_extension="yaml"
    # check if JSON config file exists
    else
        if [ -e telegram_config.json ]; then
            config_extension="json"
        else
            stop_spinner
            config_file_not_found
            exit 1
        fi
    fi
}

# Script flow entry point
main() {
    hide_cursor
    # Start the spinner in the background
    run_spinner &
    # Get the PID of the spinner process
    spinner_pid=$!
    # Set automatically detect distro boolean to true
    auto_distro=true
    if [[ $# -ne 0 ]]; then
        parse_options "$@"
    fi
    # case still true, autodetect distro
    if "$auto_distro"; then
        detect_distro
    fi
    # sleep only for demonstration purpose
    sleep 0.5
    check_config
    sleep 0.5
    check_dependencies
    sleep 0.5
    read_telegram_config
    sleep 0.5
    fetch_system_info
    sleep 0.5
    check_for_updates
}

# Run the script
main "$@"

# Wait for the spinner process to finish (only run if spinner is on)
wait

show_cursor
