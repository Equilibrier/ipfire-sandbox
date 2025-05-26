# Universal MWAN Daemon - Enhanced Solution

## Overview

The **Universal MWAN Daemon** is the most advanced and recommended solution for implementing Multi-WAN failover in IPFire. It provides connection-type agnostic failover with enhanced primary connection testing using parallel connectivity verification.

## Key Features

### 🌐 **Universal Connection Support**
- **PPPoE**: DSL, Cable, Fiber connections
- **STATIC**: Fixed IP configurations  
- **DHCP**: Dynamic IP configurations
- **QMI**: 4G/LTE USB dongles
- **PPTP**: VPN-based connections
- **Future-Proof**: Automatically adapts to new connection types

### 📡 **Enhanced Primary Testing**
- **Parallel Connectivity**: Tests primary without disrupting backup
- **Real Ping Tests**: Actual connectivity verification to external targets
- **Temporary Routes**: Uses custom routing tables for testing
- **Multiple Targets**: Tests against 8.8.8.8, 1.1.1.1, 208.67.222.222
- **Robust Cleanup**: No leftover configuration after testing

### 🔧 **System Integration**
- **Hook-Based**: Integrates with IPFire's network hook system
- **Update-Proof**: Survives IPFire system updates
- **Non-Intrusive**: Doesn't modify core IPFire files
- **State Management**: Comprehensive backup and restore system

## Architecture

```
┌─────────────────┐    ┌─────────────────┐
│   Primary ISP   │    │   Backup ISP    │
│   (PPPoE/etc)   │    │   (4G/Eth/etc)  │
└─────────┬───────┘    └─────────┬───────┘
          │                      │
          │                      │
┌─────────▼──────────────────────▼───────┐
│           IPFire System                │
│  ┌─────────────┐  ┌─────────────────┐  │
│  │ MWAN Daemon │  │ Primary Backup  │  │
│  │             │  │ & State Mgmt    │  │
│  └─────────────┘  └─────────────────┘  │
│  ┌─────────────────────────────────────┐ │
│  │     Enhanced Testing System        │ │
│  │  • Parallel Routes                 │ │
│  │  • Real Connectivity Tests         │ │
│  │  • Temporary Interfaces            │ │
│  └─────────────────────────────────────┘ │
└────────────────┬───────────────────────┘
                 │
         ┌───────▼───────┐
         │  LAN Devices  │
         │ 192.168.1.0/24│
         └───────────────┘
```

## Files and Components

### Core Implementation
- **`universal-mwan-implementation.md`**: Complete implementation with enhanced testing
- **`enhanced-primary-testing.md`**: Detailed parallel testing solution
- **`architecture-overview.md`**: Comprehensive architecture diagrams

### Analysis and Documentation
- **`ipfire-files-analysis.md`**: Verification that all IPFire files are real (not invented)

## Enhanced Primary Testing Solution

### Problem Solved
The original implementation only checked if the primary device was available:
```bash
# ❌ Old approach - only device availability
if [ -n "${RED_DEV}" ] && ip link show "${RED_DEV}" >/dev/null 2>&1; then
    return 0  # Device exists, but can it reach internet?
fi
```

### New Solution
Enhanced testing with real connectivity verification:
```bash
# ✅ New approach - actual connectivity testing
test_primary_connection() {
    # 1. Detect connection type automatically
    # 2. Set up temporary testing infrastructure
    # 3. Test real connectivity with ping
    # 4. Clean up temporary configuration
    # 5. Return reliable result
}
```

### How Parallel Testing Works

1. **🔧 Temporary Setup**: Creates temporary interfaces/routes for primary testing
2. **🌐 Parallel Operation**: Tests primary while backup remains fully functional
3. **📡 Real Connectivity**: Uses ping tests to external DNS servers
4. **🛣️ Custom Routes**: Uses routing tables 100-102 for testing isolation
5. **🧹 Clean Cleanup**: Removes all temporary configuration after testing

### Connection-Specific Testing

#### PPPoE Testing
```bash
# Creates temporary PPP connection for testing
test_ppp_connectivity_parallel() {
    # 1. Create temporary pppd configuration
    # 2. Establish test PPP connection (ppp99)
    # 3. Test connectivity through PPP interface
    # 4. Clean up temporary PPP connection
}
```

#### Static IP Testing
```bash
# Tests static configuration with temporary routes
test_static_connectivity_parallel() {
    # 1. Save current interface state
    # 2. Configure interface with static settings
    # 3. Add routes to custom routing table
    # 4. Test connectivity with source binding
    # 5. Restore original interface state
}
```

#### DHCP Testing
```bash
# Tests DHCP with temporary lease
test_dhcp_connectivity_parallel() {
    # 1. Start temporary DHCP client
    # 2. Wait for lease acquisition
    # 3. Test connectivity through DHCP interface
    # 4. Clean up DHCP client and lease
}
```

## Installation and Usage

### 1. Install Universal MWAN
```bash
# Copy implementation files to IPFire
cp universal-mwan-implementation.md /usr/local/bin/mwan-daemon-universal
chmod +x /usr/local/bin/mwan-daemon-universal

# Install hook scripts
mkdir -p /etc/init.d/networking/red.up
mkdir -p /etc/init.d/networking/red.down
cp hook-scripts/* /etc/init.d/networking/red.*/
```

### 2. Configure Backup Profiles
```bash
# Create backup profile directory
mkdir -p /var/ipfire/mwan/profiles

# Configure GSM backup (example)
cat > /var/ipfire/mwan/profiles/gsm-backup << EOF
BACKUP_TYPE="GSM"
BACKUP_DEVICE="/dev/ttyUSB0"
BACKUP_APN="internet"
BACKUP_PIN="1234"
EOF
```

### 3. Start MWAN System
```bash
# Enable MWAN
echo "ENABLED=on" > /var/ipfire/mwan/settings

# Start daemon (automatically starts on RED interface up)
/usr/local/bin/mwan-daemon-universal start
```

## Configuration Options

### Main Configuration (`/var/ipfire/mwan/settings`)
```bash
ENABLED=on                    # Enable MWAN system
PRIMARY_CHECK_INTERVAL=30     # Primary health check interval (seconds)
FAILOVER_THRESHOLD=3          # Failed checks before failover
FAILBACK_ATTEMPTS=3           # Successful checks required for failback
BACKUP_PROFILE=gsm-backup     # Default backup profile to use
```

### Backup Profile Example (`/var/ipfire/mwan/profiles/gsm-backup`)
```bash
BACKUP_TYPE="GSM"
BACKUP_DEVICE="/dev/ttyUSB0"
BACKUP_APN="internet"
BACKUP_USERNAME=""
BACKUP_PASSWORD=""
BACKUP_PIN="1234"
BACKUP_PRIORITY=100
```

## Monitoring and Logs

### Log Files
- **`/var/log/mwan.log`**: MWAN daemon logs
- **`/var/log/messages`**: System integration logs

### Status Commands
```bash
# Check MWAN status
/usr/local/bin/mwan-config status

# View current connection
cat /var/ipfire/mwan/state/current-profile

# Check primary backup
ls -la /var/ipfire/mwan/state/primary-backup/
```

## Advantages Over Other Solutions

### vs. Load Balancing MWAN
- ✅ **Priority-based**: No traffic splitting, clean failover
- ✅ **Simpler**: No complex routing rules or traffic distribution

### vs. connectd Modification  
- ✅ **Update-proof**: Doesn't modify core IPFire files
- ✅ **Non-intrusive**: Uses hook system for integration

### vs. Basic Standalone MWAN
- ✅ **Universal**: Works with any connection type automatically
- ✅ **Enhanced Testing**: Real connectivity verification
- ✅ **Parallel Testing**: Tests primary without disrupting backup
- ✅ **Future-proof**: Adapts to new connection types

## Real-World Scenarios

### Scenario 1: PPPoE Primary + 4G Backup
```
Primary: PPPoE DSL connection
Backup: 4G USB dongle
Result: Automatic failover when DSL fails, failback when DSL recovers
```

### Scenario 2: Static IP Primary + DHCP Backup
```
Primary: Static IP fiber connection  
Backup: DHCP cable connection
Result: Seamless failover with real connectivity testing
```

### Scenario 3: DHCP Primary + GSM Backup
```
Primary: DHCP cable modem
Backup: GSM 4G dongle
Result: Reliable failover with parallel primary testing
```

## Technical Details

### Connection Type Detection
The system automatically detects the primary connection type by examining:
- `/var/ipfire/ethernet/settings` (STATIC/DHCP)
- `/var/ipfire/ppp/settings` (PPPoE/PPTP)
- Device characteristics (QMI dongles)

### State Management
Comprehensive state tracking includes:
- Primary connection backup (all settings)
- Current active profile
- Failover timestamps
- Interference prevention status

### System Override
During failover, the system:
1. Stops connectd daemon
2. Takes control of RED interface
3. Configures backup connection
4. Updates all dependent services
5. Prevents IPFire interference

## Troubleshooting

### Common Issues

#### Primary Testing Fails
```bash
# Check if parallel testing is working
tail -f /var/log/mwan.log | grep "parallel"

# Verify routing tables
ip route show table 100
ip route show table 101
ip route show table 102
```

#### Backup Connection Issues
```bash
# Check backup profile
cat /var/ipfire/mwan/profiles/your-backup-profile

# Verify backup device
ip link show your-backup-device
```

#### Failback Problems
```bash
# Check primary backup integrity
ls -la /var/ipfire/mwan/state/primary-backup/

# Test primary restoration manually
/usr/local/bin/mwan-daemon-universal test-primary
```

## Future Enhancements

- **Multiple Backup Profiles**: Support for multiple backup connections with priorities
- **Load Balancing Mode**: Optional load balancing when both connections are available
- **Web Interface**: GUI configuration through IPFire web interface
- **Advanced Monitoring**: Detailed statistics and performance metrics
- **Cloud Integration**: Support for cloud-based backup connections

---

This Universal MWAN Daemon provides the most robust, flexible, and future-proof solution for Multi-WAN failover in IPFire, with enhanced testing capabilities that ensure reliable failover and failback operations.