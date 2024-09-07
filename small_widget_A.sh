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

    # If value is lee than min_value, clip it to min_value
    if (( value < min_value )); then
        value=$min_value
    fi

    # Normalize value between 0 and 1
    local range=$((max_value - min_value))
    local normalized_value=$((100 * (value - min_value) / range))

    if (( normalized_value <= 33 )); then
        # Interpolating between green (#00FF00) and yellow (#FFFF00)
        local red=$((255 * normalized_value / 33))
        printf "#%02XFF00\n" $red
    elif (( normalized_value <= 66 )); then
        # Interpolating between yellow (#FFFF00) and orange (#FFA500)
        local green=$((255 - (90 * (normalized_value - 33) / 33)))
        printf "#FFA5%02X\n" $green
    else
        # Interpolating between orange (#FFA500) and red (#FF0000)
        local green=$((165 - (165 * (normalized_value - 66) / 34)))
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

# Check various methods to get the temperature
if command -v sensors >/dev/null 2>&1; then
    # Use 'sensors' to get the CPU temperature for AMD Zen (look for 'Tctl' under 'k10temp')
    temp=$(sensors | grep -E 'Tctl|Tdie' | awk '{print $2}' | sed 's/[^0-9.]//g')
    if [ -z "$temp" ]; then
        # Fallback: try getting other sensor temperatures if 'Tctl' is not found
        temp=$(sensors | grep -E "Core|Package|temp1|Composite|edge" | awk '{print $2}' | sed 's/[^0-9.]//g' | head -n 1)
    fi
fi
if [ -d "/sys/class/thermal" ] && [ -z "$temp" ]; then
    temp=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | head -n 1)
    if [ "$temp" ]; then
        # Some systems report the temperature in millidegrees Celsius (e.g., 50000 means 50.0°C)
        temp=$((temp / 1000))
    fi
fi
# Function to fetch CPU temperature from /proc/cpuinfo for ARM-based systems (e.g., Raspberry Pi)
if command -v vcgencmd >/dev/null 2>&1 && [ -z "$temp" ]; then
    temp=$(vcgencmd measure_temp | grep -oE '[0-9]*\.[0-9]*')
fi
# Ensure we have a temperature value
if [ -z "$temp" ]; then
    echo "Unable to retrieve CPU temperature. Ensure necessary tools are installed (e.g., lm-sensors)." >&2
    echo "Failed to get CPU temperature" >&2
    exit 1
fi

# String for CPU temperature
cpu_temp=$(printf "%.0f" "$temp")
cpu_temp_string="${cpu_temp}°C"

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
cpu_color=$(calculate_color "$cpu_usage" 20 95)
memory_color=$(calculate_color "$mem_percent" 20 95)
disk_color=$(calculate_color "$disk_info_percent" 30 95)
temp_color=$(calculate_color "$cpu_temp" 45 90)

# Widget command using SF Symbols and strings in the correct format with colors
widget \
    --target "${TARGET}" \
    --text "${SERVER_NAME} " --color "foreground" --icon thermometer --color "$temp_color" --text " $cpu_temp_string\n" \
    --color "foreground" --text " " --icon cpu           --text " $cpu_string\n"     --color "$cpu_color"    --progress "$cpu_string" --text "\n" \
    --color "foreground" --text " " --icon memorychip    --text " $mem_string\n"     --color "$memory_color" --progress "$mem_string" --text "\n" \
    --color "foreground" --text " " --icon externaldrive --text "$disk_used_size\n" --color "$disk_color"   --progress "$disk_string"
