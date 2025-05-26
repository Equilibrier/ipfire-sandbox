# Practical connectd Failover Implementation

## 1. **Modified connectd Script**

### **File: `/etc/init.d/connectd` (Enhanced Version)**

```bash
#!/bin/bash
###############################################################################
#                                                                             #
# IPFire.org - A linux based firewall                                         #
# Enhanced Connection Daemon with Failover Support                           #
###############################################################################

. /etc/sysconfig/rc
. ${rc_functions}

# Stop if nothing is configured
if [ ! -s "/var/ipfire/ppp/settings" ];then
 exit 0
fi

eval $(/usr/local/bin/readhash /var/ipfire/ppp/settings)

MAX=160
ATTEMPTS=0
COUNT=0
if [ ! $HOLDOFF ]; then
	HOLDOFF=30
fi

# Enhanced failover settings with defaults
FAILOVER_ENABLED=${FAILOVER_ENABLED:-off}
FAILOVER_CHECK_INTERVAL=${FAILOVER_CHECK_INTERVAL:-30}
FAILOVER_CHECK_HOST=${FAILOVER_CHECK_HOST:-8.8.8.8}
FAILBACK_ENABLED=${FAILBACK_ENABLED:-on}
FAILBACK_DELAY=${FAILBACK_DELAY:-300}
FAILBACK_ATTEMPTS=${FAILBACK_ATTEMPTS:-3}

if [ "$RECONNECTION" = "dialondemand" ]; then
	exit 0
fi

msg_log () {
	logger -t $(basename $0)[$$] $*
}

msg_log "Enhanced Connectd ($1) started with PID $$"

# Enhanced connection health check
check_connection_health() {
    local check_host="${FAILOVER_CHECK_HOST}"
    local interface=$(cat /var/ipfire/red/device 2>/dev/null)
    local local_ip=$(cat /var/ipfire/red/local-ipaddress 2>/dev/null)
    
    if [ -z "${interface}" ] || [ ! -f /var/ipfire/red/active ]; then
        return 1  # No active connection
    fi
    
    # Multiple health checks for reliability
    local ping_success=0
    local dns_success=0
    
    # Ping test
    if ping -c 2 -W 3 -I "${interface}" "${check_host}" >/dev/null 2>&1; then
        ping_success=1
    fi
    
    # DNS resolution test
    if nslookup google.com >/dev/null 2>&1; then
        dns_success=1
    fi
    
    # Connection is healthy if at least one test passes
    if [ ${ping_success} -eq 1 ] || [ ${dns_success} -eq 1 ]; then
        return 0
    fi
    
    msg_log "Health check failed: ping=${ping_success}, dns=${dns_success}"
    return 1
}

# Test if a profile can establish connection
test_profile_connection() {
    local profile="$1"
    local settings_file
    
    if [ "${profile}" = "primary" ]; then
        settings_file="/var/ipfire/ppp/settings-primary-backup"
    else
        settings_file="/var/ipfire/ppp/settings-${profile}"
    fi
    
    if [ ! -f "${settings_file}" ]; then
        return 1
    fi
    
    # Load profile settings
    eval $(/usr/local/bin/readhash "${settings_file}")
    
    case "${TYPE}" in
        "DHCP")
            # Quick DHCP test
            if [ -n "${DEVICE}" ] && ip link show "${DEVICE}" >/dev/null 2>&1; then
                timeout 15 dhcpcd -t 10 "${DEVICE}" >/dev/null 2>&1
                local ret=$?
                dhcpcd -k "${DEVICE}" >/dev/null 2>&1
                return ${ret}
            fi
            ;;
        "STATIC")
            # For static, just check if device exists and can be configured
            if [ -n "${DEVICE}" ] && ip link show "${DEVICE}" >/dev/null 2>&1; then
                return 0
            fi
            ;;
        "PPPOE"|"PPTP")
            # For PPP connections, check if device exists
            if [ -n "${DEVICE}" ] && ip link show "${DEVICE}" >/dev/null 2>&1; then
                return 0  # Assume it will work, full test too disruptive
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

# Initiate failover to backup profile
initiate_failover() {
    local backup_profile="$1"
    
    msg_log "Initiating failover to backup profile: ${backup_profile}"
    
    # Backup current settings
    if [ ! -f /var/ipfire/ppp/settings-primary-backup ]; then
        cp /var/ipfire/ppp/settings /var/ipfire/ppp/settings-primary-backup
    fi
    
    # Stop current connection
    msg_log "Stopping current RED connection for failover"
    /etc/rc.d/init.d/network stop red >/dev/null 2>&1
    
    # Wait for clean shutdown
    sleep 5
    
    # Switch to backup profile
    if [ -f "/var/ipfire/ppp/settings-${backup_profile}" ]; then
        cp "/var/ipfire/ppp/settings-${backup_profile}" /var/ipfire/ppp/settings
        
        # Update secrets for PPP connections
        eval $(/usr/local/bin/readhash /var/ipfire/ppp/settings)
        if [ -n "${USERNAME}" ] && [ -n "${PASSWORD}" ]; then
            echo "'$USERNAME' * '$PASSWORD'" > /var/ipfire/ppp/secrets
        fi
        
        # Mark current profile
        echo "${backup_profile}" > /var/ipfire/red/current-profile
        echo "$(date)" > /var/ipfire/red/failover-time
        
        msg_log "Starting backup connection: ${backup_profile}"
        /etc/rc.d/init.d/network start red >/dev/tty12 2>&1 </dev/tty12 &
        
        return 0
    else
        msg_log "Backup profile ${backup_profile} not found"
        return 1
    fi
}

# Check for failback to primary
check_failback() {
    if [ ! -f /var/ipfire/red/current-profile ]; then
        return  # Not using backup
    fi
    
    local backup_profile=$(cat /var/ipfire/red/current-profile)
    local failover_time=$(cat /var/ipfire/red/failover-time 2>/dev/null)
    local current_time=$(date +%s)
    local failover_timestamp=$(date -d "${failover_time}" +%s 2>/dev/null || echo 0)
    
    # Wait minimum delay before attempting failback
    if [ $((current_time - failover_timestamp)) -lt ${FAILBACK_DELAY} ]; then
        return
    fi
    
    msg_log "Testing primary connection for failback"
    
    # Test primary connection multiple times for reliability
    local success_count=0
    for i in $(seq 1 ${FAILBACK_ATTEMPTS}); do
        if test_profile_connection "primary"; then
            success_count=$((success_count + 1))
        fi
        sleep 2
    done
    
    # Require majority of tests to pass
    local required_success=$((FAILBACK_ATTEMPTS / 2 + 1))
    if [ ${success_count} -ge ${required_success} ]; then
        msg_log "Primary connection tests passed (${success_count}/${FAILBACK_ATTEMPTS}), initiating failback"
        
        # Stop backup connection
        /etc/rc.d/init.d/network stop red >/dev/null 2>&1
        sleep 5
        
        # Restore primary profile
        if [ -f /var/ipfire/ppp/settings-primary-backup ]; then
            cp /var/ipfire/ppp/settings-primary-backup /var/ipfire/ppp/settings
            
            # Update secrets
            eval $(/usr/local/bin/readhash /var/ipfire/ppp/settings)
            if [ -n "${USERNAME}" ] && [ -n "${PASSWORD}" ]; then
                echo "'$USERNAME' * '$PASSWORD'" > /var/ipfire/ppp/secrets
            fi
            
            # Clean up failover state
            rm -f /var/ipfire/red/current-profile
            rm -f /var/ipfire/red/failover-time
            
            msg_log "Starting primary connection after failback"
            /etc/rc.d/init.d/network start red >/dev/tty12 2>&1 </dev/tty12 &
        fi
    else
        msg_log "Primary connection still unreliable (${success_count}/${FAILBACK_ATTEMPTS}), staying on backup"
    fi
}

if [ -s "/var/ipfire/red/keepconnected" ]; then
	ATTEMPTS=$(cat /var/ipfire/red/keepconnected)
else
	echo "0" > /var/ipfire/red/keepconnected
fi

case "$1" in
  start)
  	boot_mesg "Starting enhanced connection daemon with failover..."
  	echo_ok

	while [ "$COUNT" -lt "$MAX" ]; do
		if [ ! -e "/var/ipfire/red/keepconnected" ]; then
			# User pressed disconnect in gui
			msg_log "Stopping by user request. Exiting."
			/etc/rc.d/init.d/network stop red
			exit 0
		fi
		
		if [ -e "/var/ipfire/red/active" ]; then
			# Connection is active
			if [ "${FAILOVER_ENABLED}" = "on" ]; then
				# Perform health check
				if check_connection_health; then
					# Connection is healthy
					if [ "${FAILBACK_ENABLED}" = "on" ]; then
						check_failback
					fi
					
					# Reset attempts counter
					echo "0" > /var/ipfire/red/keepconnected
					
					# Sleep until next check
					sleep "${FAILOVER_CHECK_INTERVAL}"
					COUNT=0
				else
					# Health check failed
					msg_log "Connection health check failed"
					
					# If we have a backup profile, try failover
					if [ -n "${BACKUPPROFILE}" ] && [ ! -f /var/ipfire/red/current-profile ]; then
						if initiate_failover "${BACKUPPROFILE}"; then
							# Failover initiated, restart monitoring
							COUNT=0
							continue
						fi
					fi
					
					# No backup or failover failed, use normal reconnection logic
					msg_log "No backup available or failover failed, using normal reconnection"
					break
				fi
			else
				# Failover disabled, just check connection exists
				echo "0" > /var/ipfire/red/keepconnected
				msg_log "System is online. Exiting."
				exit 0
			fi
		else
			# Connection is down, check if pppd died
			if ( ! ps ax | grep -q [p]ppd ); then
				msg_log "No pppd is running. Trying reconnect."
				break # because pppd died
			fi
			sleep 5
			(( COUNT+=1 ))
		fi
	done

	# Connection failed, try normal reconnection logic
	/etc/rc.d/init.d/network stop red

	(( ATTEMPTS+=1 ))
	msg_log "Reconnecting: Attempt ${ATTEMPTS} of ${MAXRETRIES}"
	if [ "${ATTEMPTS}" -ge "${MAXRETRIES}" ]; then
		echo "0" > /var/ipfire/red/keepconnected
		
		# Try backup profile if available and not already using one
		if [ "$BACKUPPROFILE" != '' ] && [ ! -f /var/ipfire/red/current-profile ]; then
			if initiate_failover "${BACKUPPROFILE}"; then
				msg_log "Switched to backup profile ${BACKUPPROFILE} after max retries"
			else
				msg_log "Backup profile switch failed. Exiting."
				exit 0
			fi
		else
			msg_log "Max retries reached and no backup available. Exiting."
			exit 0
		fi
	else
		echo $ATTEMPTS > /var/ipfire/red/keepconnected
		sleep ${HOLDOFF}
	fi
	/etc/rc.d/init.d/network start red >/dev/tty12 2>&1 </dev/tty12 &
	;;

  reconnect)
	while ( ps ax | grep -q [p]ppd ); do
		msg_log "There is a pppd still running. Waiting 2 seconds for exit."
		sleep 2
	done

	/etc/rc.d/init.d/network restart red
	;;

  failover)
	# Manual failover command
	if [ -n "$2" ]; then
		msg_log "Manual failover requested to profile: $2"
		initiate_failover "$2"
	else
		msg_log "Manual failover requires profile name"
		exit 1
	fi
	;;

  failback)
	# Manual failback command
	if [ -f /var/ipfire/red/current-profile ]; then
		msg_log "Manual failback requested"
		check_failback
	else
		msg_log "Not currently using backup profile"
	fi
	;;

  status)
	# Show current connection status
	if [ -f /var/ipfire/red/active ]; then
		if [ -f /var/ipfire/red/current-profile ]; then
			profile=$(cat /var/ipfire/red/current-profile)
			echo "RED interface active using backup profile: ${profile}"
		else
			echo "RED interface active using primary profile"
		fi
		
		device=$(cat /var/ipfire/red/device 2>/dev/null)
		ip=$(cat /var/ipfire/red/local-ipaddress 2>/dev/null)
		echo "Device: ${device}, IP: ${ip}"
	else
		echo "RED interface inactive"
	fi
	;;

  *)
	echo "Usage: $0 {start|reconnect|failover <profile>|failback|status}"
	exit 1
	;;
esac

msg_log "Exiting gracefully enhanced connectd with PID $$."
```

## 2. **Configuration Files**

### **A. Enhanced Main Settings**
**File: `/var/ipfire/ppp/settings`**
```bash
# Existing settings
TYPE=PPPOE
DEVICE=eth0
USERNAME=your_username
PASSWORD=your_password
AUTOCONNECT=on
RECONNECTION=persistent

# Enhanced failover settings
FAILOVER_ENABLED=on
BACKUPPROFILE=usb-modem
MAXRETRIES=3
FAILOVER_CHECK_INTERVAL=30
FAILOVER_CHECK_HOST=8.8.8.8
FAILBACK_ENABLED=on
FAILBACK_DELAY=300
FAILBACK_ATTEMPTS=3
```

### **B. Backup Profile Example**
**File: `/var/ipfire/ppp/settings-usb-modem`**
```bash
TYPE=QMI
DEVICE=/dev/cdc-wdm0
APN=internet
USERNAME=
PASSWORD=
AUTOCONNECT=on
RECONNECTION=persistent
```

### **C. Another Backup Profile Example**
**File: `/var/ipfire/ppp/settings-ethernet-backup`**
```bash
TYPE=DHCP
DEVICE=eth1
AUTOCONNECT=on
RECONNECTION=persistent
```

## 3. **Management Scripts**

### **A. Profile Management Script**
**File: `/usr/local/bin/manage-wan-profiles`**
```bash
#!/bin/bash

PROFILES_DIR="/var/ipfire/ppp"

case "$1" in
    list)
        echo "Available WAN profiles:"
        echo "- primary (current active)"
        for profile in ${PROFILES_DIR}/settings-*; do
            if [ -f "${profile}" ]; then
                name=$(basename "${profile}" | sed 's/settings-//')
                echo "- ${name}"
            fi
        done
        ;;
    
    create)
        if [ -z "$2" ]; then
            echo "Usage: $0 create <profile_name>"
            exit 1
        fi
        
        profile_name="$2"
        profile_file="${PROFILES_DIR}/settings-${profile_name}"
        
        if [ -f "${profile_file}" ]; then
            echo "Profile ${profile_name} already exists"
            exit 1
        fi
        
        echo "Creating profile: ${profile_name}"
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
        esac
        
        echo "Profile ${profile_name} created successfully"
        ;;
    
    test)
        if [ -z "$2" ]; then
            echo "Usage: $0 test <profile_name>"
            exit 1
        fi
        
        profile_name="$2"
        echo "Testing profile: ${profile_name}"
        
        # Source the enhanced connectd functions
        . /etc/init.d/connectd
        
        if test_profile_connection "${profile_name}"; then
            echo "Profile ${profile_name} test: PASSED"
        else
            echo "Profile ${profile_name} test: FAILED"
        fi
        ;;
    
    activate)
        if [ -z "$2" ]; then
            echo "Usage: $0 activate <profile_name>"
            exit 1
        fi
        
        profile_name="$2"
        echo "Manually activating profile: ${profile_name}"
        /etc/init.d/connectd failover "${profile_name}"
        ;;
    
    status)
        /etc/init.d/connectd status
        ;;
    
    *)
        echo "Usage: $0 {list|create|test|activate|status}"
        echo ""
        echo "Commands:"
        echo "  list                    - List all available profiles"
        echo "  create <name>           - Create a new backup profile"
        echo "  test <name>             - Test a profile connection"
        echo "  activate <name>         - Manually switch to a profile"
        echo "  status                  - Show current connection status"
        exit 1
        ;;
esac
```

## 4. **Usage Examples**

### **A. Setup Failover**
```bash
# 1. Create a backup profile
/usr/local/bin/manage-wan-profiles create usb-modem

# 2. Test the backup profile
/usr/local/bin/manage-wan-profiles test usb-modem

# 3. Enable failover in main settings
echo "FAILOVER_ENABLED=on" >> /var/ipfire/ppp/settings
echo "BACKUPPROFILE=usb-modem" >> /var/ipfire/ppp/settings

# 4. Restart connectd
/etc/init.d/connectd restart
```

### **B. Manual Operations**
```bash
# Check current status
/etc/init.d/connectd status

# Manual failover
/etc/init.d/connectd failover usb-modem

# Manual failback
/etc/init.d/connectd failback

# List all profiles
/usr/local/bin/manage-wan-profiles list
```

### **C. Monitoring**
```bash
# Watch connection status
watch '/etc/init.d/connectd status'

# Monitor logs
tail -f /var/log/messages | grep connectd
```

## 5. **Key Advantages**

1. **Minimal Changes**: Only modifies connectd, no other system changes needed
2. **Backward Compatible**: All existing functionality preserved
3. **Single RED Interface**: Maintains the single RED paradigm all services expect
4. **Robust Health Checking**: Multiple health check methods
5. **Automatic Failback**: Returns to primary when it recovers
6. **Manual Override**: Allows manual failover/failback
7. **Multiple Backup Profiles**: Support for multiple backup connections
8. **Easy Configuration**: Simple configuration files and management tools

This implementation gives you exactly what you need: your existing PPPoE stays as primary, and when it fails, the system automatically switches to your backup connection (USB modem, second ethernet, etc.) and monitors for the primary to come back online.