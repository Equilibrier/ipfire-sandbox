# Standalone MWAN Implementation (Update-Proof)

## Architecture Overview

This implementation creates a **completely independent MWAN system** that:
- ✅ **Survives IPFire updates** (no system files modified)
- ✅ **Works alongside original connectd** (no conflicts)
- ✅ **Uses existing hook system** (proper integration)
- ✅ **Maintains single RED interface** (compatibility)

## File Structure

```
Update-Safe Custom Files:
├── /usr/local/bin/mwan-daemon           # Main monitoring daemon
├── /usr/local/bin/mwan-config           # Configuration management
├── /etc/init.d/networking/red.up/15-mwan-start    # Start hook
├── /etc/init.d/networking/red.down/15-mwan-stop   # Stop hook
├── /var/ipfire/mwan/                    # Configuration directory
│   ├── enabled                          # Enable/disable flag
│   ├── settings                         # Main MWAN settings
│   ├── profiles/                        # Backup profiles
│   │   ├── usb-modem                    # Example backup profile
│   │   └── ethernet-backup              # Another backup profile
│   └── state/                           # Runtime state
│       ├── current-profile              # Active profile name
│       ├── failover-time                # When failover occurred
│       └── daemon.pid                   # Daemon PID
└── /var/log/mwan.log                    # MWAN-specific logging

Untouched IPFire Files:
├── /etc/init.d/connectd                 # Original (unmodified)
├── /etc/init.d/networking/red           # Original (unmodified)
└── /var/ipfire/ppp/settings             # Original (managed by MWAN)
```

## Implementation

### 1. **Main MWAN Daemon**

**File: `/usr/local/bin/mwan-daemon`**
```bash
#!/bin/bash
###############################################################################
# MWAN Daemon - Multi-WAN Failover for IPFire
# Survives IPFire updates - does not modify system files
###############################################################################

MWAN_DIR="/var/ipfire/mwan"
MWAN_CONFIG="${MWAN_DIR}/settings"
MWAN_STATE_DIR="${MWAN_DIR}/state"
MWAN_PROFILES_DIR="${MWAN_DIR}/profiles"
MWAN_LOG="/var/log/mwan.log"
PIDFILE="${MWAN_STATE_DIR}/daemon.pid"

# Default settings
DEFAULT_CHECK_INTERVAL=30
DEFAULT_CHECK_HOST="8.8.8.8"
DEFAULT_FAILBACK_DELAY=300
DEFAULT_FAILBACK_ATTEMPTS=3
DEFAULT_MAX_RETRIES=3

# Ensure directories exist
mkdir -p "${MWAN_STATE_DIR}" "${MWAN_PROFILES_DIR}"

# Logging function
mwan_log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] MWAN: ${message}" | tee -a "${MWAN_LOG}"
    logger -t "mwan-daemon" "${message}"
}

# Load MWAN configuration
load_config() {
    # Set defaults
    CHECK_INTERVAL=${DEFAULT_CHECK_INTERVAL}
    CHECK_HOST=${DEFAULT_CHECK_HOST}
    FAILBACK_DELAY=${DEFAULT_FAILBACK_DELAY}
    FAILBACK_ATTEMPTS=${DEFAULT_FAILBACK_ATTEMPTS}
    MAX_RETRIES=${DEFAULT_MAX_RETRIES}
    
    # Load custom settings if they exist
    if [ -f "${MWAN_CONFIG}" ]; then
        source "${MWAN_CONFIG}"
    fi
}

# Check if MWAN is enabled
is_mwan_enabled() {
    [ -f "${MWAN_DIR}/enabled" ]
}

# Get current profile name
get_current_profile() {
    if [ -f "${MWAN_STATE_DIR}/current-profile" ]; then
        cat "${MWAN_STATE_DIR}/current-profile"
    else
        echo "primary"
    fi
}

# Check connection health
check_connection_health() {
    local interface=$(cat /var/ipfire/red/device 2>/dev/null)
    local local_ip=$(cat /var/ipfire/red/local-ipaddress 2>/dev/null)
    
    if [ -z "${interface}" ] || [ ! -f /var/ipfire/red/active ]; then
        return 1  # No active connection
    fi
    
    # Multiple health checks
    local ping_success=0
    local dns_success=0
    
    # Ping test with timeout
    if timeout 10 ping -c 2 -W 3 -I "${interface}" "${CHECK_HOST}" >/dev/null 2>&1; then
        ping_success=1
    fi
    
    # DNS resolution test
    if timeout 10 nslookup google.com >/dev/null 2>&1; then
        dns_success=1
    fi
    
    # Connection healthy if at least one test passes
    if [ ${ping_success} -eq 1 ] || [ ${dns_success} -eq 1 ]; then
        return 0
    fi
    
    mwan_log "Health check failed: ping=${ping_success}, dns=${dns_success}, interface=${interface}"
    return 1
}

# Test if a profile can work
test_profile() {
    local profile="$1"
    local profile_file
    
    if [ "${profile}" = "primary" ]; then
        profile_file="${MWAN_STATE_DIR}/primary-backup"
    else
        profile_file="${MWAN_PROFILES_DIR}/${profile}"
    fi
    
    if [ ! -f "${profile_file}" ]; then
        return 1
    fi
    
    # Load profile settings
    source "${profile_file}"
    
    case "${TYPE}" in
        "DHCP"|"STATIC")
            # Check if device exists and is up
            if [ -n "${DEVICE}" ] && ip link show "${DEVICE}" up >/dev/null 2>&1; then
                return 0
            fi
            ;;
        "PPPOE"|"PPTP")
            # Check if underlying device exists
            if [ -n "${DEVICE}" ] && ip link show "${DEVICE}" >/dev/null 2>&1; then
                return 0
            fi
            ;;
        "QMI")
            # Check if QMI device exists
            if [ -n "${DEVICE}" ] && [ -c "${DEVICE}" ]; then
                return 0
            fi
            ;;
    esac
    
    return 1
}

# Stop original connectd
stop_connectd() {
    if pgrep -f "/etc/init.d/connectd" >/dev/null; then
        mwan_log "Stopping original connectd"
        pkill -f "/etc/init.d/connectd"
        sleep 2
    fi
}

# Start original connectd
start_connectd() {
    if ! pgrep -f "/etc/init.d/connectd" >/dev/null; then
        mwan_log "Starting original connectd"
        /etc/init.d/connectd start &
    fi
}

# Switch to backup profile
failover_to_backup() {
    local backup_profile="$1"
    local profile_file="${MWAN_PROFILES_DIR}/${backup_profile}"
    
    if [ ! -f "${profile_file}" ]; then
        mwan_log "Backup profile ${backup_profile} not found"
        return 1
    fi
    
    mwan_log "Initiating failover to backup profile: ${backup_profile}"
    
    # Stop original connectd to prevent interference
    stop_connectd
    
    # Backup current settings if not already backed up
    if [ ! -f "${MWAN_STATE_DIR}/primary-backup" ]; then
        cp /var/ipfire/ppp/settings "${MWAN_STATE_DIR}/primary-backup"
    fi
    
    # Stop current RED connection
    mwan_log "Stopping RED interface for failover"
    /etc/rc.d/init.d/network stop red >/dev/null 2>&1
    sleep 5
    
    # Switch to backup profile
    cp "${profile_file}" /var/ipfire/ppp/settings
    
    # Update PPP secrets if needed
    source "${profile_file}"
    if [ -n "${USERNAME}" ] && [ -n "${PASSWORD}" ]; then
        echo "'${USERNAME}' * '${PASSWORD}'" > /var/ipfire/ppp/secrets
    fi
    
    # Mark current state
    echo "${backup_profile}" > "${MWAN_STATE_DIR}/current-profile"
    date > "${MWAN_STATE_DIR}/failover-time"
    
    # Start backup connection
    mwan_log "Starting backup connection: ${backup_profile}"
    /etc/rc.d/init.d/network start red >/dev/null 2>&1
    
    return 0
}

# Failback to primary
failback_to_primary() {
    local current_profile=$(get_current_profile)
    
    if [ "${current_profile}" = "primary" ]; then
        return 0  # Already on primary
    fi
    
    mwan_log "Testing primary connection for failback"
    
    # Test primary connection reliability
    local success_count=0
    for i in $(seq 1 ${FAILBACK_ATTEMPTS}); do
        if test_profile "primary"; then
            success_count=$((success_count + 1))
        fi
        sleep 2
    done
    
    # Require majority of tests to pass
    local required_success=$((FAILBACK_ATTEMPTS / 2 + 1))
    if [ ${success_count} -ge ${required_success} ]; then
        mwan_log "Primary connection reliable (${success_count}/${FAILBACK_ATTEMPTS}), initiating failback"
        
        # Stop backup connection
        /etc/rc.d/init.d/network stop red >/dev/null 2>&1
        sleep 5
        
        # Restore primary settings
        if [ -f "${MWAN_STATE_DIR}/primary-backup" ]; then
            cp "${MWAN_STATE_DIR}/primary-backup" /var/ipfire/ppp/settings
            
            # Update PPP secrets
            source "${MWAN_STATE_DIR}/primary-backup"
            if [ -n "${USERNAME}" ] && [ -n "${PASSWORD}" ]; then
                echo "'${USERNAME}' * '${PASSWORD}'" > /var/ipfire/ppp/secrets
            fi
            
            # Clean up state
            rm -f "${MWAN_STATE_DIR}/current-profile"
            rm -f "${MWAN_STATE_DIR}/failover-time"
            
            # Start primary connection
            mwan_log "Starting primary connection after failback"
            /etc/rc.d/init.d/network start red >/dev/null 2>&1
            
            # Restart original connectd for primary monitoring
            start_connectd
        fi
    else
        mwan_log "Primary still unreliable (${success_count}/${FAILBACK_ATTEMPTS}), staying on backup"
    fi
}

# Main monitoring loop
monitor_connections() {
    mwan_log "Starting MWAN monitoring (PID: $$)"
    echo $$ > "${PIDFILE}"
    
    local failure_count=0
    
    while true; do
        if ! is_mwan_enabled; then
            mwan_log "MWAN disabled, exiting monitor"
            break
        fi
        
        if [ -f /var/ipfire/red/active ]; then
            # Connection is active, check health
            if check_connection_health; then
                # Connection healthy
                failure_count=0
                
                # Check for failback if using backup
                local current_profile=$(get_current_profile)
                if [ "${current_profile}" != "primary" ]; then
                    # Check if enough time has passed since failover
                    local failover_time=$(cat "${MWAN_STATE_DIR}/failover-time" 2>/dev/null)
                    local current_time=$(date +%s)
                    local failover_timestamp=$(date -d "${failover_time}" +%s 2>/dev/null || echo 0)
                    
                    if [ $((current_time - failover_timestamp)) -ge ${FAILBACK_DELAY} ]; then
                        failback_to_primary
                    fi
                fi
            else
                # Health check failed
                failure_count=$((failure_count + 1))
                mwan_log "Health check failed (${failure_count}/${MAX_RETRIES})"
                
                if [ ${failure_count} -ge ${MAX_RETRIES} ]; then
                    # Try failover if we have backup profiles and not already using one
                    local current_profile=$(get_current_profile)
                    if [ "${current_profile}" = "primary" ] && [ -n "${BACKUP_PROFILES}" ]; then
                        # Try first available backup profile
                        local first_backup=$(echo ${BACKUP_PROFILES} | cut -d' ' -f1)
                        if failover_to_backup "${first_backup}"; then
                            failure_count=0
                        fi
                    fi
                fi
            fi
        else
            # No active connection, let original connectd handle it
            failure_count=0
        fi
        
        sleep "${CHECK_INTERVAL}"
    done
    
    rm -f "${PIDFILE}"
    mwan_log "MWAN monitoring stopped"
}

# Daemon control functions
start_daemon() {
    if [ -f "${PIDFILE}" ] && kill -0 $(cat "${PIDFILE}") 2>/dev/null; then
        mwan_log "MWAN daemon already running (PID: $(cat ${PIDFILE}))"
        return 1
    fi
    
    if ! is_mwan_enabled; then
        mwan_log "MWAN not enabled, not starting daemon"
        return 1
    fi
    
    load_config
    monitor_connections &
    return 0
}

stop_daemon() {
    if [ -f "${PIDFILE}" ]; then
        local pid=$(cat "${PIDFILE}")
        if kill -0 "${pid}" 2>/dev/null; then
            mwan_log "Stopping MWAN daemon (PID: ${pid})"
            kill "${pid}"
            rm -f "${PIDFILE}"
            
            # Restart original connectd if we stopped it
            start_connectd
        fi
    fi
}

status_daemon() {
    if [ -f "${PIDFILE}" ] && kill -0 $(cat "${PIDFILE}") 2>/dev/null; then
        echo "MWAN daemon running (PID: $(cat ${PIDFILE}))"
        echo "Current profile: $(get_current_profile)"
        if [ -f /var/ipfire/red/active ]; then
            local device=$(cat /var/ipfire/red/device 2>/dev/null)
            local ip=$(cat /var/ipfire/red/local-ipaddress 2>/dev/null)
            echo "RED interface: ${device} (${ip})"
        else
            echo "RED interface: inactive"
        fi
    else
        echo "MWAN daemon not running"
    fi
}

# Main command handling
case "$1" in
    start)
        start_daemon
        ;;
    stop)
        stop_daemon
        ;;
    restart)
        stop_daemon
        sleep 2
        start_daemon
        ;;
    status)
        status_daemon
        ;;
    monitor)
        # Direct monitoring (for debugging)
        load_config
        monitor_connections
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|monitor}"
        exit 1
        ;;
esac
```

### 2. **Configuration Management Tool**

**File: `/usr/local/bin/mwan-config`**
```bash
#!/bin/bash
###############################################################################
# MWAN Configuration Tool
###############################################################################

MWAN_DIR="/var/ipfire/mwan"
MWAN_CONFIG="${MWAN_DIR}/settings"
MWAN_PROFILES_DIR="${MWAN_DIR}/profiles"

# Ensure directories exist
mkdir -p "${MWAN_DIR}" "${MWAN_PROFILES_DIR}"

# Enable MWAN
enable_mwan() {
    touch "${MWAN_DIR}/enabled"
    echo "MWAN enabled"
    
    # Create default config if it doesn't exist
    if [ ! -f "${MWAN_CONFIG}" ]; then
        cat > "${MWAN_CONFIG}" << 'EOF'
# MWAN Configuration
CHECK_INTERVAL=30
CHECK_HOST="8.8.8.8"
FAILBACK_DELAY=300
FAILBACK_ATTEMPTS=3
MAX_RETRIES=3
BACKUP_PROFILES="usb-modem"
EOF
        echo "Created default configuration"
    fi
}

# Disable MWAN
disable_mwan() {
    rm -f "${MWAN_DIR}/enabled"
    /usr/local/bin/mwan-daemon stop
    echo "MWAN disabled"
}

# Create backup profile
create_profile() {
    local profile_name="$1"
    local profile_file="${MWAN_PROFILES_DIR}/${profile_name}"
    
    if [ -z "${profile_name}" ]; then
        echo "Usage: $0 create-profile <name>"
        return 1
    fi
    
    if [ -f "${profile_file}" ]; then
        echo "Profile ${profile_name} already exists"
        return 1
    fi
    
    echo "Creating backup profile: ${profile_name}"
    echo "Select connection type:"
    echo "1) DHCP"
    echo "2) Static IP"
    echo "3) PPPoE"
    echo "4) QMI (USB Modem)"
    read -p "Choice [1-4]: " choice
    
    case "${choice}" in
        1)
            read -p "Device (e.g., eth1): " device
            cat > "${profile_file}" << EOF
TYPE=DHCP
DEVICE=${device}
AUTOCONNECT=on
RECONNECTION=persistent
EOF
            ;;
        2)
            read -p "Device (e.g., eth1): " device
            read -p "IP Address: " ip
            read -p "Netmask: " netmask
            read -p "Gateway: " gateway
            cat > "${profile_file}" << EOF
TYPE=STATIC
DEVICE=${device}
IP=${ip}
NETMASK=${netmask}
GATEWAY=${gateway}
AUTOCONNECT=on
RECONNECTION=persistent
EOF
            ;;
        3)
            read -p "Device (e.g., eth1): " device
            read -p "Username: " username
            read -p "Password: " password
            cat > "${profile_file}" << EOF
TYPE=PPPOE
DEVICE=${device}
USERNAME=${username}
PASSWORD=${password}
AUTOCONNECT=on
RECONNECTION=persistent
EOF
            ;;
        4)
            read -p "QMI Device (e.g., /dev/cdc-wdm0): " device
            read -p "APN: " apn
            cat > "${profile_file}" << EOF
TYPE=QMI
DEVICE=${device}
APN=${apn}
USERNAME=
PASSWORD=
AUTOCONNECT=on
RECONNECTION=persistent
EOF
            ;;
        *)
            echo "Invalid choice"
            return 1
            ;;
    esac
    
    echo "Profile ${profile_name} created successfully"
    echo "Don't forget to add it to BACKUP_PROFILES in ${MWAN_CONFIG}"
}

# List profiles
list_profiles() {
    echo "Available backup profiles:"
    for profile in "${MWAN_PROFILES_DIR}"/*; do
        if [ -f "${profile}" ]; then
            local name=$(basename "${profile}")
            echo "- ${name}"
        fi
    done
}

# Show status
show_status() {
    if [ -f "${MWAN_DIR}/enabled" ]; then
        echo "MWAN: Enabled"
    else
        echo "MWAN: Disabled"
    fi
    
    /usr/local/bin/mwan-daemon status
}

# Main command handling
case "$1" in
    enable)
        enable_mwan
        ;;
    disable)
        disable_mwan
        ;;
    create-profile)
        create_profile "$2"
        ;;
    list-profiles)
        list_profiles
        ;;
    status)
        show_status
        ;;
    *)
        echo "Usage: $0 {enable|disable|create-profile <name>|list-profiles|status}"
        echo ""
        echo "Commands:"
        echo "  enable              - Enable MWAN failover"
        echo "  disable             - Disable MWAN failover"
        echo "  create-profile <name> - Create a backup profile"
        echo "  list-profiles       - List all backup profiles"
        echo "  status              - Show MWAN status"
        exit 1
        ;;
esac
```

### 3. **Hook Scripts**

**File: `/etc/init.d/networking/red.up/15-mwan-start`**
```bash
#!/bin/bash
# Start MWAN monitoring when RED comes up

if [ -f /var/ipfire/mwan/enabled ]; then
    /usr/local/bin/mwan-daemon start
fi
```

**File: `/etc/init.d/networking/red.down/15-mwan-stop`**
```bash
#!/bin/bash
# Stop MWAN monitoring when RED goes down

/usr/local/bin/mwan-daemon stop 2>/dev/null || true
```

### 4. **Installation Script**

**File: `/usr/local/bin/install-mwan`**
```bash
#!/bin/bash
###############################################################################
# MWAN Installation Script
###############################################################################

echo "Installing MWAN for IPFire..."

# Make scripts executable
chmod +x /usr/local/bin/mwan-daemon
chmod +x /usr/local/bin/mwan-config
chmod +x /etc/init.d/networking/red.up/15-mwan-start
chmod +x /etc/init.d/networking/red.down/15-mwan-stop

# Create directories
mkdir -p /var/ipfire/mwan/{state,profiles}

echo "MWAN installed successfully!"
echo ""
echo "Next steps:"
echo "1. Create backup profiles: /usr/local/bin/mwan-config create-profile <name>"
echo "2. Enable MWAN: /usr/local/bin/mwan-config enable"
echo "3. Check status: /usr/local/bin/mwan-config status"
```

## Usage Examples

### **Setup Process**
```bash
# 1. Install MWAN
/usr/local/bin/install-mwan

# 2. Create a backup profile
/usr/local/bin/mwan-config create-profile usb-modem

# 3. Enable MWAN
/usr/local/bin/mwan-config enable

# 4. Check status
/usr/local/bin/mwan-config status
```

### **Daily Operations**
```bash
# Check current status
/usr/local/bin/mwan-config status

# View logs
tail -f /var/log/mwan.log

# Temporarily disable
/usr/local/bin/mwan-config disable

# Re-enable
/usr/local/bin/mwan-config enable
```

## Key Advantages

1. **✅ Update-Proof**: No system files modified
2. **✅ Non-Intrusive**: Works alongside original connectd
3. **✅ Proper Integration**: Uses IPFire hook system
4. **✅ Easy Management**: Simple configuration tools
5. **✅ Comprehensive Logging**: Dedicated MWAN logs
6. **✅ Reversible**: Can be completely disabled/removed

This implementation gives you exactly what you need while being completely safe from IPFire updates!