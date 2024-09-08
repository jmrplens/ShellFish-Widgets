#!/bin/bash

# Load to make widget command available
# shellcheck source=/dev/null
source /root/.shellfishrc

# Default values
DEFAULT_DISK=""
DEFAULT_SERVER_NAME=$(hostname)
DEFAULT_CPU_TEMP_SENSOR=""  # Blank to trigger auto-detection
DEFAULT_TARGET="Small_A"

# Parse flags for server_name, disk, and cpu_sensor
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --server_name) SERVER_NAME="$2"; shift ;;
        --disk) DISK="$2"; shift ;;
        --cpu_sensor) CPU_TEMP_SENSOR="$2"; shift ;;
        --target) TARGET="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

# Use defaults if flags are not provided
SERVER_NAME=${SERVER_NAME:-$DEFAULT_SERVER_NAME}
DISK=${DISK:-$DEFAULT_DISK}
CPU_TEMP_SENSOR=${CPU_TEMP_SENSOR:-$DEFAULT_CPU_TEMP_SENSOR}
TARGET=${TARGET:-$DEFAULT_TARGET}

# Function to calculate the interpolated color between green (min) and red (max)
calculate_color() {
    local value=$1
    local min_value=$2
    local max_value=$3

    # Ensure valid range
    if (( max_value <= min_value )); then
        echo "Error: max_value must be greater than min_value."
        return 1
    fi

    # If value is out of bounds, clamp to min/max
    if (( value <= min_value )); then
        echo "#00FF00"  # Green for below or equal to min
        return 0
    elif (( value >= max_value )); then
        echo "#FF0000"  # Red for above or equal to max
        return 0
    fi

    # Normalize value between 0 and 100
    local range=$((max_value - min_value))
    local normalized_value=$((100 * (value - min_value) / range))

    if (( normalized_value <= 50 )); then
        # Interpolating from green (#00FF00) to yellow (#FFFF00)
        local red=$((255 * normalized_value / 50))
        printf "#%02XFF00\n" $red
    else
        # Interpolating from yellow (#FFFF00) to red (#FF0000) via orange
        local green=$((255 - (255 * (normalized_value - 50) / 50)))
        printf "#FF%02X00\n" $green
    fi
}

# Try to automatically detect the main disk if it's not defined
if [ -z "$DISK" ]; then
    # Attempt 1: lsblk
    DISK=$(lsblk -J -o NAME,MOUNTPOINT | jq -r '.blockdevices[] | select(.children != null) | .children[] | select(.mountpoint == "/") | .name')

    # Attempt 2: df (fallback method)
    if [ -z "$DISK" ]; then
        DISK=$(df / | grep -Eo '^/dev/[a-zA-Z0-9]+' | cut -d'/' -f3)
    fi

    # Check if a disk was found
    if [ -z "$DISK" ]; then
        echo "The main disk could not be detected."
        exit 1
    fi
fi


# 1. Memory usage as a percentage
if [[ -f /proc/meminfo ]]; then
    memtotal=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    memavail=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    memused=$((memtotal - memavail))

    # Calculate memory usage as a percentage, round to nearest integer
    mem_percent=$(( (memused * 100) / memtotal ))
else
    echo "Memory information could not be retrieved."
    exit 1
fi

# String for memory usage as a percentage
mem_string="${mem_percent}%"

# 2. Disk usage as a percentage
disk_info_percent=$(df /dev/"${DISK}" -h --output=pcent | tail -1 | tr -d ' %')
disk_used_size=$(df /dev/"${DISK}" -h --output=used | tail -1)B

# String for disk usage as a percentage
disk_string="${disk_info_percent}%"

# 3. CPU temperature

# Function to get the temperature using 'sensors'
get_sensors_temp() {
    if command -v sensors &> /dev/null; then
        sensors_output=$(sensors)
        temp=$(echo "$sensors_output" | grep -E 'Package id 0:|Core 0:|temp1:|coretemp|k10temp|acpitz|Adapter: Virtual device|CPU:' | grep -Eo '[+-]?[0-9]+(\.[0-9]+)?°C' | head -n 1 | grep -Eo '[0-9]+(\.[0-9]+)?')
        if [ -n "$temp" ]; then
            echo "$temp"
            return 0
        fi
    fi
    return 1
}

# Function to get temperature from the system files in /sys/class/thermal/
get_sys_temp() {
    for zone in /sys/class/thermal/thermal_zone*/temp; do
        if [ -f "$zone" ]; then
            temp=$(cat "$zone" 2>/dev/null)
            if [[ -n "$temp" && "$temp" =~ ^[0-9]+$ ]]; then
                if [ "$temp" -gt 1000 ]; then
                    temp=$(echo "scale=1; $temp / 1000" | bc)
                fi
                echo "$temp"
                return 0
            fi
        fi
    done
    return 1
}

# Function to get temperature from /sys/class/hwmon/
get_hwmon_temp() {
    for hwmon in /sys/class/hwmon/*; do
        if [[ -f "$hwmon/name" ]]; then
            sensor_name=$(cat "$hwmon/name")
            if [[ "$sensor_name" == "coretemp" || "$sensor_name" == "k10temp" ]]; then
                for temp_input in "$hwmon"/temp*_input; do
                    if [ -f "$temp_input" ]; then
                        temp=$(cat "$temp_input" 2>/dev/null)
                        if [[ -n "$temp" && "$temp" =~ ^[0-9]+$ ]]; then
                            if [ "$temp" -gt 1000 ]; then
                                temp=$(echo "scale=1; $temp / 1000" | bc)
                            fi
                            echo "$temp"
                            return 0
                        fi
                    fi
                done
            fi
        fi
    done
    return 1
}

# Function to get the temperature using ACPI from /proc
get_acpi_proc_temp() {
    for zone in /proc/acpi/thermal_zone/*/temperature; do
        if [ -f "$zone" ]; then
            temp=$(grep -Eo '[0-9]+(\.[0-9]+)?' "$zone" 2>/dev/null)
            if [ -n "$temp" ]; then
                echo "$temp"
                return 0
            fi
        fi
    done
    return 1
}

# Function to get the CPU temperature using direct ACPI commands
get_acpi_temp() {
    if command -v acpi &> /dev/null; then
        acpi_output=$(acpi -t)
        temp=$(echo "$acpi_output" | grep -Eo '[0-9]+(\.[0-9]+)?' | head -n 1)
        if [ -n "$temp" ]; then
            echo "$temp"
            return 0
        fi
    fi
    return 1
}

# Function to find the first successful method to obtain temperature
find_working_temp_method() {
    temp=$(get_sensors_temp)
    if [ -n "$temp" ]; then
        echo "get_sensors_temp"
        return 0
    fi

    temp=$(get_sys_temp)
    if [ -n "$temp" ]; then
        echo "get_sys_temp"
        return 0
    fi

    temp=$(get_hwmon_temp)
    if [ -n "$temp" ]; then
        echo "get_hwmon_temp"
        return 0
    fi

    temp=$(get_acpi_proc_temp)
    if [ -n "$temp" ]; then
        echo "get_acpi_proc_temp"
        return 0
    fi

    temp=$(get_acpi_temp)
    if [ -n "$temp" ]; then
        echo "get_acpi_temp"
        return 0
    fi

    echo "No method found."
    return 1
}

# Function to average 5 temperature readings over a period of 2 seconds
get_linux_temp() {
    local total=0
    local count=5
    local method="$1"

    for i in $(seq 1 $count); do
        temp=$($method)
        if [ -n "$temp" ]; then
            total=$(echo "$total + $temp" | bc)
        else
            echo "Could not obtain temperature in attempt $i"
        fi
        sleep 0.4
    done

    # Calculate the average of the collected temperatures
    if [ "$total" != 0 ]; then
        average=$(echo "scale=2; $total / $count" | bc)
        echo "$average"
        return 0
    else
        echo "Could not obtain a valid temperature average."
        return 1
    fi
}

# Find the first working temperature method and cache it
temp_method=$(find_working_temp_method)
if [ -n "$temp_method" ]; then
    cpu_temp=$(printf "%.0f" "$(get_linux_temp "$temp_method")")
    cpu_temp_string="${cpu_temp}°C"
else
    echo "No valid temperature method found."
    cpu_temp="0"
    cpu_temp_string="N/A"
fi

# 4. CPU usage as a percentage
if command -v top >/dev/null 2>&1; then
    cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print int($2 + $4)}')  # Integer usage
else
    echo "The 'top' command is not available. Attempting other methods."

    # Fallback method 1: Read from `/proc/stat` (Linux)
    if [[ -f /proc/stat ]]; then
        prev_idle=$(awk '/^cpu / {print $5}' /proc/stat)
        prev_total=$(awk '/^cpu / {print $2+$3+$4+$5+$6+$7+$8}' /proc/stat)
        sleep 1
        idle=$(awk '/^cpu / {print $5}' /proc/stat)
        total=$(awk '/^cpu / {print $2+$3+$4+$5+$6+$7+$8}' /proc/stat)
        idle_diff=$((idle - prev_idle))
        total_diff=$((total - prev_total))
        cpu_usage=$((100 * (total_diff - idle_diff) / total_diff))
    fi

    # Fallback method 2: `mpstat` command
    if command -v mpstat >/dev/null 2>&1; then
        cpu_usage=$(mpstat 1 1 | awk '/^Average/ {print 100 - $NF}')
    fi

    # If no method works, default to 0
    if [ -z "$cpu_usage" ]; then
        echo "The CPU usage could not be retrieved."
        cpu_usage=0
    fi
fi

# String for CPU usage as a percentage
cpu_string="${cpu_usage}%"

# 5. Color calculations based on percentages
cpu_color=$(calculate_color "$cpu_usage" 10 95)
memory_color=$(calculate_color "$mem_percent" 10 95)
disk_color=$(calculate_color "$disk_info_percent" 20 95)
temp_color=$(calculate_color "$cpu_temp" 45 90)

# Widget command using SF Symbols and strings in the correct format with colors
widget \
    --target "${TARGET}" \
    --text "${SERVER_NAME} " --color "foreground" --icon thermometer --color "$temp_color" --text " $cpu_temp_string\n" \
    --color "foreground" --text " " --icon cpu           --text " $cpu_string\n"     --color "$cpu_color"    --progress "$cpu_string" --text "\n" \
    --color "foreground" --text " " --icon memorychip    --text " $mem_string\n"     --color "$memory_color" --progress "$mem_string" --text "\n" \
    --color "foreground" --text " " --icon externaldrive --text "$disk_used_size\n" --color "$disk_color"   --progress "$disk_string"
