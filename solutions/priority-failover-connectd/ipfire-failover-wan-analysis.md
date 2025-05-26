# IPFire Priority-Based Failover WAN Analysis

## Current Issues with My Previous MWAN Approach

### 1. **Misunderstanding of Requirements**
- **My approach**: Load balancing with multiple active WANs
- **Actual requirement**: Priority-based failover with single active WAN
- **Key difference**: Only ONE WAN should be active at any time, not multiple

### 2. **Integration Problems**
- **My approach**: Created separate MWAN type replacing RED entirely
- **Actual requirement**: Extend existing RED interface with failover capability
- **Key difference**: Keep existing PPPoE as primary, add secondary as backup

### 3. **State Management Issues**
- **My approach**: Multiple red interfaces (red0, red1, etc.)
- **Actual requirement**: Single RED interface that can switch between devices
- **Key difference**: All services expect ONE red interface, not multiple

## Complete IPFire Network Ecosystem Analysis

### 1. **Core RED Interface Dependencies**

#### **A. State Files Used by System**
```bash
/var/ipfire/red/active              # Indicates RED is up and running
/var/ipfire/red/device              # Physical device name (e.g., ppp0, eth0)
/var/ipfire/red/iface               # Interface name (usually same as device)
/var/ipfire/red/local-ipaddress     # Current RED IP address
/var/ipfire/red/remote-ipaddress    # Gateway/remote IP
/var/ipfire/red/dns1                # Primary DNS server
/var/ipfire/red/dns2                # Secondary DNS server
/var/ipfire/red/keepconnected       # Connection persistence flag
```

#### **B. Services That Monitor RED State**
1. **Firewall** (`/etc/init.d/firewall`)
   - Checks `/var/ipfire/red/active` before applying rules
   - Uses `/var/ipfire/red/local-ipaddress` for anti-spoofing
   - Configures MASQUERADE based on RED state

2. **NTP** (`/etc/init.d/ntp`)
   - Waits for `/var/ipfire/red/active` before time sync
   - Has 30-second timeout waiting for connection

3. **DNS/Unbound** (`/etc/init.d/unbound`)
   - Updates forwarders when RED comes up
   - Triggered by `red.up/25-update-dns-forwarders`

4. **Connection Daemon** (`/etc/init.d/connectd`)
   - Monitors `/var/ipfire/red/active` for connection state
   - Handles reconnection attempts and backup profiles
   - **KEY**: Already has backup profile mechanism!

5. **Squid Proxy** (`/etc/init.d/squid`)
   - Restarts when RED interface changes
   - Triggered by `red.up/27-RS-squid`

### 2. **Existing Backup Mechanism in connectd**

#### **A. Current Backup Profile System**
```bash
# In /var/ipfire/ppp/settings
BACKUPPROFILE=backup1               # Name of backup profile
MAXRETRIES=3                        # Max attempts before switching

# Backup profile stored as:
/var/ipfire/ppp/settings-backup1    # Backup connection settings
```

#### **B. Backup Profile Logic Flow**
```bash
1. Primary connection fails
2. connectd attempts reconnection up to MAXRETRIES
3. If all attempts fail AND BACKUPPROFILE is set:
   - Copy backup settings to main settings
   - Update PPP secrets
   - Restart RED interface with backup settings
4. If backup also fails, exit
```

### 3. **Hook System Execution Order**

#### **A. RED Up Hooks** (executed in numerical order)
```bash
01-conntrack-cleanup     # Clean connection tracking
10-multicast            # Setup multicast routing
10-static-routes        # Add static routes
20-firewall             # Update firewall rules
23-suricata             # Restart IDS/IPS
24-RS-qos               # Restart QoS
25-update-dns-forwarders # Update DNS
27-RS-squid             # Restart proxy
30-ddns                 # Update dynamic DNS
50-ipsec                # Restart IPSec VPN
50-ovpn                 # Restart OpenVPN
60-collectd             # Update monitoring
98-leds                 # Update status LEDs
99-beep                 # Status beep
99-fireinfo             # Update system info
99-pakfire-update       # Check for updates
```

#### **B. RED Down Hooks**
```bash
20-firewall             # Update firewall (block traffic)
```

## Proper Failover WAN Implementation Strategy

### 1. **Extend Existing connectd Mechanism**

#### **A. Enhanced Backup Profile System**
Instead of creating a new MWAN system, extend the existing backup profile mechanism:

```bash
# Enhanced /var/ipfire/ppp/settings
BACKUPPROFILE=wan2                  # Backup connection name
MAXRETRIES=3                        # Attempts before failover
FAILOVER_ENABLED=on                 # Enable automatic failover
FAILOVER_CHECK_INTERVAL=30          # Health check interval (seconds)
FAILOVER_CHECK_HOST=8.8.8.8         # Host to ping for health check
FAILBACK_ENABLED=on                 # Enable automatic failback
FAILBACK_DELAY=300                  # Wait time before failback (seconds)
```

#### **B. Multiple Backup Profiles**
```bash
# Primary connection (current)
/var/ipfire/ppp/settings

# Backup connections
/var/ipfire/ppp/settings-wan2       # Secondary WAN (e.g., USB modem)
/var/ipfire/ppp/settings-wan3       # Tertiary WAN (e.g., WiFi hotspot)
```

### 2. **Modified connectd Logic**

#### **A. Enhanced Connection Monitoring**
```bash
# File: /etc/init.d/connectd (modifications)

# Add health check function
check_connection_health() {
    local check_host="${FAILOVER_CHECK_HOST:-8.8.8.8}"
    local interface=$(cat /var/ipfire/red/device 2>/dev/null)
    
    if [ -n "${interface}" ] && [ -f /var/ipfire/red/active ]; then
        # Ping test through current interface
        if ping -c 3 -W 5 -I "${interface}" "${check_host}" >/dev/null 2>&1; then
            return 0  # Connection healthy
        fi
    fi
    return 1  # Connection failed
}

# Add failover function
initiate_failover() {
    local current_profile="$1"
    local backup_profile="$2"
    
    msg_log "Primary connection failed, switching to backup profile: ${backup_profile}"
    
    # Stop current connection
    /etc/rc.d/init.d/network stop red
    
    # Switch to backup profile
    cp "/var/ipfire/ppp/settings" "/var/ipfire/ppp/settings-primary-backup"
    cp "/var/ipfire/ppp/settings-${backup_profile}" "/var/ipfire/ppp/settings"
    
    # Update secrets
    eval $(/usr/local/bin/readhash /var/ipfire/ppp/settings)
    echo "'$USERNAME' * '$PASSWORD'" > /var/ipfire/ppp/secrets
    
    # Mark as using backup
    echo "${backup_profile}" > /var/ipfire/red/current-profile
    
    # Start backup connection
    /etc/rc.d/init.d/network start red
}

# Add failback function
check_failback() {
    if [ ! -f /var/ipfire/red/current-profile ]; then
        return  # Not using backup
    fi
    
    local backup_profile=$(cat /var/ipfire/red/current-profile)
    
    # Test primary connection availability
    if test_profile_connection "primary"; then
        msg_log "Primary connection restored, failing back from ${backup_profile}"
        
        # Stop backup connection
        /etc/rc.d/init.d/network stop red
        
        # Restore primary profile
        cp "/var/ipfire/ppp/settings-primary-backup" "/var/ipfire/ppp/settings"
        rm -f /var/ipfire/red/current-profile
        
        # Update secrets
        eval $(/usr/local/bin/readhash /var/ipfire/ppp/settings)
        echo "'$USERNAME' * '$PASSWORD'" > /var/ipfire/ppp/secrets
        
        # Start primary connection
        /etc/rc.d/init.d/network start red
    fi
}
```

#### **B. Enhanced Monitoring Loop**
```bash
# Replace existing monitoring with enhanced version
case "$1" in
  start)
    boot_mesg "Starting enhanced connection daemon with failover..."
    echo_ok
    
    while [ "$COUNT" -lt "$MAX" ]; do
        if [ ! -e "/var/ipfire/red/keepconnected" ]; then
            msg_log "Stopping by user request. Exiting."
            /etc/rc.d/init.d/network stop red
            exit 0
        fi
        
        if [ -e "/var/ipfire/red/active" ]; then
            # Connection is up, check health
            if [ "${FAILOVER_ENABLED}" = "on" ]; then
                if ! check_connection_health; then
                    msg_log "Connection health check failed"
                    if [ -n "${BACKUPPROFILE}" ]; then
                        initiate_failover "primary" "${BACKUPPROFILE}"
                        exit 0
                    fi
                else
                    # Check for failback if using backup
                    if [ "${FAILBACK_ENABLED}" = "on" ]; then
                        check_failback
                    fi
                fi
            fi
            
            # Reset counter and sleep
            echo "0" > /var/ipfire/red/keepconnected
            sleep "${FAILOVER_CHECK_INTERVAL:-30}"
            COUNT=0
        else
            # Connection is down, normal reconnection logic
            if ( ! ps ax | grep -q [p]ppd ); then
                msg_log "No pppd is running. Trying reconnect."
                break
            fi
            sleep 5
            (( COUNT+=1 ))
        fi
    done
    
    # Rest of existing logic...
    ;;
esac
```

### 3. **Configuration Management**

#### **A. Backup Profile Creation**
```bash
# Script: /usr/local/bin/create-backup-profile
#!/bin/bash

PROFILE_NAME="$1"
CONNECTION_TYPE="$2"  # DHCP, STATIC, PPPOE, etc.

case "${CONNECTION_TYPE}" in
    "DHCP")
        cat > "/var/ipfire/ppp/settings-${PROFILE_NAME}" << EOF
TYPE=DHCP
DEVICE=eth1
AUTOCONNECT=on
EOF
        ;;
    "PPPOE")
        cat > "/var/ipfire/ppp/settings-${PROFILE_NAME}" << EOF
TYPE=PPPOE
DEVICE=eth1
USERNAME=backup_user
PASSWORD=backup_pass
AUTOCONNECT=on
EOF
        ;;
    "QMI")
        cat > "/var/ipfire/ppp/settings-${PROFILE_NAME}" << EOF
TYPE=QMI
DEVICE=/dev/cdc-wdm0
APN=internet
USERNAME=
PASSWORD=
AUTOCONNECT=on
EOF
        ;;
esac
```

#### **B. Profile Testing**
```bash
# Function to test a profile without switching
test_profile_connection() {
    local profile="$1"
    local test_interface="test-red"
    
    # Load profile settings
    if [ "${profile}" = "primary" ]; then
        eval $(/usr/local/bin/readhash /var/ipfire/ppp/settings-primary-backup)
    else
        eval $(/usr/local/bin/readhash /var/ipfire/ppp/settings-${profile})
    fi
    
    # Test connection based on type
    case "${TYPE}" in
        "DHCP")
            # Test DHCP on device
            timeout 30 dhcpcd -t 10 "${DEVICE}" >/dev/null 2>&1
            ;;
        "PPPOE")
            # Test PPPoE connection
            timeout 30 pppd call test-profile >/dev/null 2>&1
            ;;
    esac
    
    return $?
}
```

### 4. **Integration Points**

#### **A. No Changes Needed to Existing Services**
- All existing services continue to monitor `/var/ipfire/red/active`
- All existing hooks continue to work
- All existing state files remain the same
- **Key advantage**: Zero impact on existing functionality

#### **B. Enhanced Logging**
```bash
# Add to existing hooks for better monitoring
# File: /etc/init.d/networking/red.up/01-log-failover-status
#!/bin/bash

if [ -f /var/ipfire/red/current-profile ]; then
    PROFILE=$(cat /var/ipfire/red/current-profile)
    logger "RED interface up using backup profile: ${PROFILE}"
else
    logger "RED interface up using primary profile"
fi
```

### 5. **Implementation Steps**

#### **Phase 1: Enhance connectd**
1. Modify `/etc/init.d/connectd` with health checking
2. Add failover and failback functions
3. Implement enhanced monitoring loop

#### **Phase 2: Configuration Tools**
1. Create backup profile management scripts
2. Add profile testing functionality
3. Create web interface for backup configuration

#### **Phase 3: Monitoring and Logging**
1. Enhanced logging for failover events
2. Status indicators for current profile
3. Health check reporting

### 6. **Advantages of This Approach**

#### **A. Minimal Impact**
- Uses existing connectd infrastructure
- No changes to core network scripts
- All existing services work unchanged
- Maintains single RED interface paradigm

#### **B. Robust Failover**
- Health checking with configurable intervals
- Automatic failback when primary recovers
- Multiple backup profiles support
- Graceful switching with proper cleanup

#### **C. Easy Configuration**
- Extends existing backup profile system
- Simple configuration files
- Web interface integration possible
- Testing capabilities built-in

This approach addresses your actual requirements: priority-based failover that keeps your existing PPPoE as primary and only switches to backup when needed, with automatic failback when the primary recovers.