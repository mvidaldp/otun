#!/usr/bin/env bash

# Destination directory for the script and systemd files
otun_dir="/opt/otun"
script_name="otun.sh"
config_json="telegram_config.json"
config_yaml="telegram_config.yaml"
service_file="otun.service"
timer_file="otun.timer"
systemd_dir="/etc/systemd/system"

# Print messages with different styles
print_message() {
    local message=$1
    local style=$2

    case $style in
    "info")
        echo -e "\e[32m${message}\e[0m" # green text
        ;;
    "warning")
        echo -e "\e[33m${message}\e[0m" # yellow text
        ;;
    "error")
        echo -e "\e[31m${message}\e[0m" # red text
        ;;
    esac
}

# Check if script is run with sudo
check_sudo() {
    # check if user has sudo privileges by checking the output of sudo -l
    # output = privileges, no output = no privileges
    sudo_permissions=$(sudo -n -v 2>&1)
    if [ -n "$sudo_permissions" ]; then
        print_message "This script requires sudo privileges. Please enter your password to continue." "info"
        sudo -v || {
            print_message "Authentication failed. Exiting." "error"
            exit 1
        }
    fi
}

# Create directory if it's not yet created
create_directory() {
    local dir=$1
    sudo mkdir -p "$dir"
}

# OTUN's file existence check
file_existence_check() {
    if [ -e "$otun_dir/$script_name" ] && [ -e "$otun_dir/$config_json" ] && [ -e "$otun_dir/$config_yaml" ]; then
        echo ""
        while true; do
            read -r -p "Files in $otun_dir already exist. Do you want to overwrite them? (y/N): " overwrite_files
            case $overwrite_files in
            [yY])
                copy_files
                break
                ;;
            [nN] | "")
                echo ""
                print_message "Exiting without overwriting files." "info"
                exit 1
                ;;
            *)
                print_message "Invalid input. Please enter 'y/Y' to overwrite or 'n/N/ENTER' to exit." "warning"
                echo ""
                ;;
            esac
        done
    else
        copy_files
    fi
}

# Copy files to directory
copy_files() {
    sudo cp "$script_name" "$config_json" "$config_yaml" "$otun_dir/"
    sudo chmod +x "$otun_dir/$script_name"
}

# Prompt for bot_token and chat_id
prompt_bot_info() {
    echo ""
    while true; do
        read -r -p "Enter your Telegram bot token: " bot_token
        # validate Telegram bot token format
        if [[ $bot_token =~ ^[0-9]+:[a-zA-Z0-9_-]+$ ]]; then
            break
        else
            print_message "Invalid bot token format." "warning"
            echo ""
        fi
    done
    while true; do
        read -r -p "Enter your Telegram chat ID: " chat_id
        # validate Telegram bot token format
        if [[ $chat_id =~ ^(-?[0-9]+)$ ]]; then
            break
        else
            print_message "Invalid chat ID format." "warning"
            echo ""
        fi
    done
}

# Replace placeholders in configuration files
set_telegram_config() {
    sudo sed -i "s/BOT_TOKEN_PLACEHOLDER/$bot_token/" "$otun_dir/$config_json"
    sudo sed -i "s/CHAT_ID_PLACEHOLDER/$chat_id/" "$otun_dir/$config_json"
    sudo sed -i "s/BOT_TOKEN_PLACEHOLDER/$bot_token/" "$otun_dir/$config_yaml"
    sudo sed -i "s/CHAT_ID_PLACEHOLDER/$chat_id/" "$otun_dir/$config_yaml"
}

# systemd unit files existence check
systemd_existence_check() {
    if [ -e "$systemd_dir/$timer_file" ] && [ -e "$systemd_dir/$service_file" ]; then
        echo ""
        while true; do
            read -r -p "OTUN's systemd service and timer unit files already exist. Do you want to overwrite them? (y/N): " overwrite_systemd
            case $overwrite_systemd in
            [yY])
                break
                ;;
            [nN] | "")
                echo ""
                print_message "Exiting without overwriting OTUN's systemd service and timer unit files." "info"
                exit 1
                ;;
            *)
                print_message "Invalid input. Please enter 'y/Y' to overwrite or 'n/N/ENTER' to exit." "warning"
                echo ""
                ;;
            esac
        done
    fi
}

# Inform the user to manually modify the OnCalendar field if desired
inform_user() {
    echo ""
    read -r -d '' message <<EOF
This install script allows you to specify the time (HH:mm format) you want to
run OTUN once a day. If you wish to schedule OTUN differently, please manually
modify the OnCalendar field in the $systemd_dir/$timer_file file based on your
desired schedule. See the following link for allowed formats:

https://www.freedesktop.org/software/systemd/man/latest/systemd.time.html#Calendar%20Events

After modifying $systemd_dir/$timer_file, do not forget to reload the systemd 
manager configuration:

sudo systemctl daemon-reload
EOF
    print_message "$message" "info"
}

# Prompt for and validate desired time
prompt_time() {
    echo ""
    while true; do
        read -r -p "Enter the desired time for the script to run in HH:mm format: " run_time
        # Validate the input format (HH:mm)
        if [[ $run_time =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
            break
        else
            print_message "Invalid time format. Please use HH:mm format (24-hour clock)." "warning"
            echo ""
        fi
    done
}

# Copy systemd timer and service files
copy_systemd_files() {
    sudo cp "$service_file" "$systemd_dir/"
    sudo cp "$timer_file" "$systemd_dir/"
}

# Replace placeholders in the timer file
replace_timer() {
    sudo sed -i "s/HOUR_MINUTE/$run_time/" "$systemd_dir/$timer_file"
}

# Perform systemctl commands
manage_systemd() {
    sudo systemctl daemon-reload
    sudo systemctl enable "$timer_file"
    sudo systemctl start "$timer_file"
}

# Main script starts here
main() {
    # check sudo privileges
    check_sudo
    # create /opt/otun directory if not yet created
    create_directory "$otun_dir"
    # check if files (all of them) in /opt/otun already exist
    file_existence_check
    # prompt for bot_token and chat_id
    prompt_bot_info
    # replace placeholders in configuration files
    set_telegram_config
    # check if systemd service and timer files (both) already exist
    systemd_existence_check
    # inform the user to manually modify the OnCalendar field if desired
    inform_user
    # prompt for and validate desired time
    prompt_time
    # copy systemd timer and service files
    copy_systemd_files
    # replace placeholders in the timer file
    replace_timer
    # perform systemctl commands
    manage_systemd
    # successfull installation print
    print_message "\nOTUN's installation completed successfully." "info"
}

# Run the script
main "$@"
