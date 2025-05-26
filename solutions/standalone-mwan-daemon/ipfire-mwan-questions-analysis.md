# IPFire MWAN Questions Analysis

## Question 1: Original connectd Purpose and My Extension

### **Original connectd Purpose**
Looking at the original `/etc/init.d/connectd` code:

```bash
# Original connectd logic (simplified):
1. Monitor if RED connection is active (/var/ipfire/red/active)
2. If connection drops, check if pppd process died
3. Attempt reconnection up to MAXRETRIES times
4. If all attempts fail AND BACKUPPROFILE is set:
   - Switch to backup profile permanently
   - Copy backup settings to main settings
   - Restart RED with backup settings
5. Exit (no monitoring after switch)
```

**Original Purpose**: connectd was designed as a **simple reconnection daemon** for PPP connections that:
- Monitors PPP connection health
- Attempts automatic reconnection when connection drops
- Provides **one-time failover** to a backup profile after max retries
- **NOT designed for continuous monitoring or failback**

### **My Extension vs Original Purpose**

**What I Preserved**:
- ✅ Basic reconnection logic for failed connections
- ✅ MAXRETRIES mechanism
- ✅ Backup profile switching concept
- ✅ Same configuration file structure

**What I Enhanced**:
- ❌ **MAJOR CHANGE**: Added continuous health monitoring (original only monitored during reconnection attempts)
- ❌ **MAJOR CHANGE**: Added automatic failback (original was one-way switch only)
- ❌ **MAJOR CHANGE**: Added proactive health checking (original was reactive to connection drops)

**Conclusion**: My extension **significantly changed** connectd's original purpose from a simple reconnection daemon to a full WAN monitoring and failover system.

## Question 2: Original Backup Profile Purpose

### **Original BACKUPPROFILE Design**

From the original code:
```bash
if [ "${ATTEMPTS}" -ge "${MAXRETRIES}" ]; then
    echo "0" > /var/ipfire/red/keepconnected
    if [ "$BACKUPPROFILE" != '' ]; then
        rm -f /var/ipfire/ppp/settings
        cp "/var/ipfire/ppp/settings-${BACKUPPROFILE}" /var/ipfire/ppp/settings
        msg_log "Switched to backup profile ${BACKUPPROFILE}"
        # Update secrets and exit
    fi
fi
```

**Original Purpose**: 
- **Emergency fallback only** - used when primary connection completely fails after all retries
- **One-time permanent switch** - no monitoring or failback capability
- **Manual intervention required** - to switch back to primary, user must manually reconfigure
- **Simple profile replacement** - just copies backup settings over main settings

**Use Case**: Designed for scenarios like:
- ISP completely down for extended period
- Hardware failure of primary connection device
- Need to manually switch to backup ISP temporarily

**NOT designed for**: Automatic failover/failback or continuous monitoring

## Question 3: IPFire Auto-Updates Problem

### **The Critical Issue**

You are **absolutely correct** - this is a **major problem**:

1. **IPFire Auto-Updates**: IPFire automatically updates system files including `/etc/init.d/connectd`
2. **Modifications Lost**: Any direct modifications to system files will be **overwritten** during updates
3. **Unacceptable Solution**: Manual re-application after every update is not viable

### **Alternative Approaches That Survive Updates**

#### **Option A: Hook-Based Implementation (Recommended)**

**Concept**: Use IPFire's existing hook system instead of modifying core files.

```bash
# Create custom hooks that survive updates
/etc/init.d/networking/red.up/15-mwan-monitor     # Start MWAN monitoring
/etc/init.d/networking/red.down/15-mwan-cleanup   # Stop MWAN monitoring
```

**Implementation**:
```bash
# File: /etc/init.d/networking/red.up/15-mwan-monitor
#!/bin/bash
# Start custom MWAN monitoring daemon
/usr/local/bin/mwan-monitor start

# File: /etc/init.d/networking/red.down/15-mwan-cleanup  
#!/bin/bash
# Stop custom MWAN monitoring daemon
/usr/local/bin/mwan-monitor stop
```

**Custom MWAN Daemon**:
```bash
# File: /usr/local/bin/mwan-monitor (survives updates)
#!/bin/bash
# Standalone MWAN monitoring daemon
# - Monitors primary connection health
# - Handles failover/failback independently
# - Does NOT modify connectd
```

#### **Option B: Wrapper/Proxy Approach**

**Concept**: Create a wrapper that intercepts connectd calls.

```bash
# Rename original connectd
mv /etc/init.d/connectd /etc/init.d/connectd.original

# Create wrapper connectd
cat > /etc/init.d/connectd << 'EOF'
#!/bin/bash
# MWAN-enhanced connectd wrapper
# Check if MWAN is enabled
if [ -f /var/ipfire/mwan/enabled ]; then
    exec /usr/local/bin/mwan-connectd "$@"
else
    exec /etc/init.d/connectd.original "$@"
fi
EOF
```

**Problem**: Still requires modifying system files that get overwritten.

#### **Option C: Systemd Override (If Available)**

**Concept**: Use systemd service overrides if IPFire supports them.

```bash
# Create override directory
mkdir -p /etc/systemd/system/connectd.service.d/

# Create override file
cat > /etc/systemd/system/connectd.service.d/mwan.conf << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/local/bin/mwan-connectd start
EOF
```

**Problem**: Need to verify if IPFire uses systemd and allows overrides.

#### **Option D: IPFire Addon/Package System**

**Concept**: Create a proper IPFire addon package.

```bash
# Create IPFire addon structure
/opt/pakfire/db/mwan/
/opt/pakfire/db/mwan/files
/opt/pakfire/db/mwan/meta
```

**Advantages**:
- Proper integration with IPFire package system
- Survives updates
- Can be distributed to other users

**Disadvantages**:
- Complex to create and maintain
- Requires understanding IPFire package system

### **Recommended Solution: Standalone MWAN Daemon with Hooks**

#### **Architecture**:
```
IPFire System (untouched)
├── /etc/init.d/connectd (original, unmodified)
├── /etc/init.d/networking/red (original, unmodified)
└── Hook System (survives updates)
    ├── /etc/init.d/networking/red.up/15-mwan-start
    └── /etc/init.d/networking/red.down/15-mwan-stop

Custom MWAN System (survives updates)
├── /usr/local/bin/mwan-daemon (main monitoring daemon)
├── /usr/local/bin/mwan-config (configuration tool)
├── /var/ipfire/mwan/ (configuration directory)
└── /var/log/mwan.log (logging)
```

#### **How It Works**:

1. **Normal Operation**: Original connectd works unchanged
2. **MWAN Monitoring**: Custom daemon monitors connection health independently
3. **Failover Trigger**: When primary fails, MWAN daemon:
   - Stops original connectd
   - Switches to backup profile
   - Starts RED with backup settings
   - Monitors for primary recovery
4. **Failback**: When primary recovers:
   - Stops backup connection
   - Restores primary settings
   - Restarts original connectd
5. **Update Survival**: All custom code in `/usr/local/` and `/var/ipfire/mwan/`

#### **Implementation Files**:

```bash
# Hook to start MWAN monitoring
/etc/init.d/networking/red.up/15-mwan-start

# Hook to stop MWAN monitoring  
/etc/init.d/networking/red.down/15-mwan-stop

# Main MWAN daemon (independent of connectd)
/usr/local/bin/mwan-daemon

# MWAN configuration tool
/usr/local/bin/mwan-config

# MWAN configuration files
/var/ipfire/mwan/enabled
/var/ipfire/mwan/settings
/var/ipfire/mwan/profiles/
```

### **Why This Approach Works**:

1. **Update Survival**: No system files modified
2. **Clean Integration**: Uses existing hook system
3. **Independent Operation**: Doesn't interfere with original connectd
4. **Maintainable**: Easy to update and configure
5. **Reversible**: Can be completely disabled/removed

Would you like me to implement this standalone MWAN daemon approach that survives IPFire updates?