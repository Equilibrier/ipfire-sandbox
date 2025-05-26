# IPFire Multi-WAN (MWAN) Extension Architecture Analysis

## Current Network Interface Management Architecture

### 1. **Core Network Script Flow**

```bash
/etc/init.d/network {start|stop|restart} [green|red|blue|orange]
    ↓
/etc/init.d/networking/{color} {start|stop}
    ↓
Hook System: /etc/init.d/networking/red.{up|down}/
```

### 2. **Red Interface Management Deep Dive**

#### **A. Configuration Loading Sequence**
```bash
# File: /etc/init.d/networking/red
. /etc/sysconfig/rc                           # System RC configuration
. ${rc_functions}                             # Core utility functions
. /etc/init.d/networking/functions.network    # Network-specific functions

# Configuration hash loading
eval $(/usr/local/bin/readhash /var/ipfire/main/settings)
eval $(/usr/local/bin/readhash /var/ipfire/ethernet/settings)
eval $(/usr/local/bin/readhash /var/ipfire/dns/settings)
eval $(/usr/local/bin/readhash /var/ipfire/mac/settings)
```

#### **B. Connection Type Support Matrix**
Current red interface supports:
- **STATIC**: Static IP configuration
- **DHCP**: DHCP client configuration
- **PPPOE**: PPPoE over Ethernet
- **PPTP**: PPTP VPN connection
- **QMI**: Qualcomm MSM Interface (cellular)
- **VDSL**: VDSL with VLAN tagging
- **ATM**: ATM bridge connections

#### **C. Interface Startup Function Flow**

```bash
red start:
├── Configuration Validation
│   ├── Check RED_TYPE and RED_DEV
│   └── Validate required parameters
├── Device Preparation
│   ├── Remove leftover state files
│   ├── Bring up physical interface
│   ├── Set MAC address (if configured)
│   └── Set MTU (if configured)
├── Connection Type Specific Setup
│   ├── STATIC: ip addr add, route setup
│   ├── DHCP: dhcpcd_start()
│   ├── PPPOE: pppd with plugin
│   ├── QMI: qmi_configure_apn()
│   └── etc.
├── State File Creation
│   ├── /var/ipfire/red/iface
│   ├── /var/ipfire/red/local-ipaddress
│   ├── /var/ipfire/red/remote-ipaddress
│   └── /var/ipfire/red/active
└── Hook Execution
    └── run_subdir ${rc_base}/init.d/networking/red.up/
```

#### **D. Hook System Architecture**

The hook system uses `run_subdir()` function:
```bash
# From /etc/init.d/functions line 707-722
run_subdir() {
    DIR=$1
    for i in $(ls -v ${DIR}* 2> /dev/null); do
        check_script_status
        OUT=$(echo $(basename ${i}) | awk -F- '{ print $2 }')
        case "$OUT" in
            S) ${i} start   ;;
            K) ${i} stop    ;;
            RS) ${i} restart ;;
            RL) ${i} reload ;;
            U) ${i} up      ;;
            D) ${i} down    ;;
            *) ${i}         ;;
        esac
    done
}
```

**Current Red Hooks:**
- `red.up/`: Executed when red interface comes up
- `red.down/`: Executed when red interface goes down

**Hook Naming Convention:**
- `NN-service-action` where NN is execution order (01-99)
- Action suffix determines the argument passed to the script

### 3. **Key Network Helper Functions**

#### **A. DHCP Management**
```bash
dhcpcd_start(device, [options])     # Start DHCP client
dhcpcd_stop(device)                 # Stop DHCP client
dhcpcd_get_pid(device)              # Get DHCP client PID
dhcpcd_is_running(pid)              # Check if DHCP client is running
```

#### **B. QMI (Cellular) Management**
```bash
qmi_find_device(interface)          # Find QMI control device
qmi_enable_rawip_mode(device)       # Enable raw IP mode
qmi_configure_apn(device, apn, auth, user, pass)  # Configure APN
qmi_reset(device)                   # Reset QMI device
```

#### **C. State Management**
```bash
# State files in /var/ipfire/red/
active                  # Indicates interface is active
device                  # Physical device name
iface                   # Interface name
local-ipaddress         # Local IP address
remote-ipaddress        # Gateway/remote IP
dns1, dns2             # DNS servers
dial-on-demand         # Dial-on-demand flag
```

## Multi-WAN Extension Strategy

### 1. **Proposed MWAN Architecture**

#### **A. New Connection Type: "MWAN"**
Add MWAN as a new RED_TYPE alongside existing types:
```bash
TYPE="${RED_TYPE}"  # Add "MWAN" as new type
```

#### **B. MWAN Configuration Structure**
```bash
# New configuration files
/var/ipfire/mwan/settings           # Main MWAN configuration
/var/ipfire/mwan/interfaces/        # Per-interface configurations
/var/ipfire/mwan/policies/          # Load balancing policies
/var/ipfire/mwan/rules/             # Traffic routing rules
```

#### **C. MWAN Interface Naming Convention**
```bash
# Multiple red interfaces
red0    # Primary WAN (existing)
red1    # Secondary WAN
red2    # Tertiary WAN
...
```

### 2. **Code Injection Points**

#### **A. Main Red Script Modification**
**File:** `/etc/init.d/networking/red`

**Injection Point 1:** Connection type detection (around line 47)
```bash
if [ "$TYPE" == "STATIC" ] || [ "$TYPE" == "DHCP" ] || [ "$TYPE" == "MWAN" ]; then
    # Add MWAN device validation
fi
```

**Injection Point 2:** Connection type handling (around line 109)
```bash
elif [ "${TYPE}" == "MWAN" ]; then
    # Call MWAN initialization function
    mwan_start_interfaces
    exit 0
```

#### **B. New MWAN Functions**
**File:** `/etc/init.d/networking/functions.mwan` (new file)

```bash
#!/bin/bash
# MWAN-specific functions

mwan_load_config() {
    # Load MWAN configuration
    eval $(/usr/local/bin/readhash /var/ipfire/mwan/settings)
}

mwan_start_interfaces() {
    # Start all configured MWAN interfaces
    local interface_count="${MWAN_INTERFACE_COUNT:-1}"
    
    for i in $(seq 0 $((interface_count - 1))); do
        mwan_start_interface "red${i}" "${i}"
    done
    
    # Setup load balancing
    mwan_setup_load_balancing
    
    # Setup monitoring
    mwan_setup_monitoring
}

mwan_start_interface() {
    local interface="$1"
    local index="$2"
    
    # Load interface-specific configuration
    eval $(/usr/local/bin/readhash /var/ipfire/mwan/interfaces/${interface})
    
    # Start interface based on its type
    case "${INTERFACE_TYPE}" in
        "DHCP")
            mwan_start_dhcp_interface "${interface}" "${index}"
            ;;
        "STATIC")
            mwan_start_static_interface "${interface}" "${index}"
            ;;
        "PPPOE")
            mwan_start_pppoe_interface "${interface}" "${index}"
            ;;
    esac
}

mwan_setup_load_balancing() {
    # Configure routing tables and rules for load balancing
    # Use iproute2 advanced routing features
}

mwan_setup_monitoring() {
    # Setup interface monitoring and failover
}
```

#### **C. Hook System Extension**
**New Directories:**
```bash
/etc/init.d/networking/mwan.up/     # MWAN-specific up hooks
/etc/init.d/networking/mwan.down/   # MWAN-specific down hooks
```

**Modified Hook Execution:**
```bash
# In red script, replace:
run_subdir ${rc_base}/init.d/networking/red.up/

# With conditional execution:
if [ "${TYPE}" == "MWAN" ]; then
    run_subdir ${rc_base}/init.d/networking/mwan.up/
else
    run_subdir ${rc_base}/init.d/networking/red.up/
fi
```

### 3. **Routing Table Management**

#### **A. Multiple Routing Tables**
```bash
# /etc/iproute2/rt_tables additions
200 wan1
201 wan2
202 wan3
```

#### **B. Load Balancing Implementation**
```bash
mwan_setup_load_balancing() {
    # Create nexthop groups for load balancing
    ip route add default scope global \
        nexthop via ${WAN1_GATEWAY} dev red0 weight ${WAN1_WEIGHT} \
        nexthop via ${WAN2_GATEWAY} dev red1 weight ${WAN2_WEIGHT}
    
    # Setup per-interface routing tables
    ip route add default via ${WAN1_GATEWAY} dev red0 table wan1
    ip route add default via ${WAN2_GATEWAY} dev red1 table wan2
    
    # Setup routing rules
    ip rule add from ${WAN1_NETWORK} table wan1
    ip rule add from ${WAN2_NETWORK} table wan2
}
```

### 4. **Monitoring and Failover**

#### **A. Interface Health Monitoring**
```bash
mwan_monitor_interface() {
    local interface="$1"
    local gateway="$2"
    
    # Ping-based monitoring
    if ! ping -c 3 -W 5 -I "${interface}" "${gateway}" >/dev/null 2>&1; then
        mwan_interface_down "${interface}"
    else
        mwan_interface_up "${interface}"
    fi
}
```

#### **B. Failover Logic**
```bash
mwan_interface_down() {
    local interface="$1"
    
    # Remove interface from load balancing
    # Update routing tables
    # Trigger hooks
    run_subdir ${rc_base}/init.d/networking/mwan.down/
}
```

### 5. **Integration Points**

#### **A. Firewall Integration**
**File:** `/etc/init.d/networking/mwan.up/20-firewall`
```bash
#!/bin/bash
# Update firewall rules for MWAN
exec /etc/rc.d/init.d/firewall mwan-up
```

#### **B. DNS Integration**
**File:** `/etc/init.d/networking/mwan.up/25-update-dns-forwarders`
```bash
#!/bin/bash
# Update DNS forwarders for multiple WANs
/usr/local/bin/update-mwan-dns
```

### 6. **Configuration Management**

#### **A. Hash-based Configuration**
```bash
# /var/ipfire/mwan/settings
MWAN_ENABLED=on
MWAN_INTERFACE_COUNT=2
MWAN_LOAD_BALANCE_METHOD=weight
MWAN_FAILOVER_ENABLED=on
MWAN_MONITOR_INTERVAL=30

# /var/ipfire/mwan/interfaces/red0
INTERFACE_TYPE=DHCP
INTERFACE_DEVICE=eth0
INTERFACE_WEIGHT=1
INTERFACE_PRIORITY=1
INTERFACE_MONITOR_IP=8.8.8.8

# /var/ipfire/mwan/interfaces/red1
INTERFACE_TYPE=DHCP
INTERFACE_DEVICE=eth1
INTERFACE_WEIGHT=1
INTERFACE_PRIORITY=2
INTERFACE_MONITOR_IP=1.1.1.1
```

### 7. **Implementation Steps**

#### **Phase 1: Core Infrastructure**
1. Create `/etc/init.d/networking/functions.mwan`
2. Modify `/etc/init.d/networking/red` to support MWAN type
3. Create MWAN configuration structure
4. Implement basic multi-interface startup

#### **Phase 2: Load Balancing**
1. Implement routing table management
2. Add load balancing algorithms
3. Create traffic distribution logic

#### **Phase 3: Monitoring and Failover**
1. Implement interface health monitoring
2. Add failover logic
3. Create recovery mechanisms

#### **Phase 4: Integration**
1. Update firewall integration
2. Modify DNS handling
3. Update web interface
4. Add monitoring tools

### 8. **Testing Strategy**

#### **A. Unit Testing**
- Test individual MWAN functions
- Validate configuration loading
- Test interface state management

#### **B. Integration Testing**
- Test with different connection types
- Validate failover scenarios
- Test load balancing distribution

#### **C. Performance Testing**
- Measure throughput with load balancing
- Test failover time
- Monitor resource usage

This architecture provides a clean, modular approach to extending IPFire with multi-WAN capabilities while maintaining compatibility with the existing codebase and following established patterns.