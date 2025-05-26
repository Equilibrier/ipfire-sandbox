# IPFire RED Files Analysis

## Question 1: Are `/var/ipfire/red/` files real or invented?

### **✅ REAL IPFire Files** (from actual IPFire source code):

Based on analysis of `/etc/init.d/networking/red` and `/etc/init.d/connectd`:

#### **Core RED State Files** (line 84 in red script):
```bash
# These are REAL files that IPFire creates/removes:
/var/ipfire/red/active              # ✅ REAL - touched when RED is active
/var/ipfire/red/device              # ✅ REAL - contains device name  
/var/ipfire/red/dial-on-demand      # ✅ REAL - for dial-on-demand connections
/var/ipfire/red/dns1                # ✅ REAL - primary DNS server
/var/ipfire/red/dns2                # ✅ REAL - secondary DNS server
/var/ipfire/red/local-ipaddress     # ✅ REAL - RED interface IP (line 124)
/var/ipfire/red/remote-ipaddress    # ✅ REAL - gateway IP (line 125)
/var/ipfire/red/resolv.conf         # ✅ REAL - DNS resolver config
```

#### **Connection Management Files**:
```bash
/var/ipfire/red/iface               # ✅ REAL - interface name (line 123, 168, 233)
/var/ipfire/red/keepconnected       # ✅ REAL - connectd retry counter (line 50-99 in connectd)
```

### **❌ Files I Invented** (not in IPFire source):
```bash
# These were my additions for MWAN:
/var/ipfire/red/device              # ❌ WAIT - this IS real (see line 84)
```

Actually, let me correct this - I need to check which specific files I used that aren't real:

Looking at my implementation, I used:
- `/var/ipfire/red/active` ✅ REAL
- `/var/ipfire/red/device` ✅ REAL  
- `/var/ipfire/red/iface` ✅ REAL
- `/var/ipfire/red/local-ipaddress` ✅ REAL
- `/var/ipfire/red/remote-ipaddress` ✅ REAL
- `/var/ipfire/red/dns1` ✅ REAL
- `/var/ipfire/red/dns2` ✅ REAL

**Conclusion**: All the `/var/ipfire/red/` files I used in my MWAN implementation are **REAL IPFire files**. I did not invent any fake files.

## Question 2: PPPoE Assumptions in My Implementation

### **Current PPPoE-Centric Issues**:

#### **Problem 1: Primary Connection Backup**
```bash
# In failover_to_backup():
if [ ! -f "${MWAN_STATE_DIR}/primary-backup" ]; then
    cp /var/ipfire/ppp/settings "${MWAN_STATE_DIR}/primary-backup"  # ❌ PPPoE assumption
fi
```
**Issue**: Assumes primary uses `/var/ipfire/ppp/settings` (PPPoE only)

#### **Problem 2: Primary Connection Testing**
```bash
# In test_primary_connection():
local primary_device=$(grep "^DEVICE=" "${MWAN_STATE_DIR}/primary-backup" 2>/dev/null | cut -d'=' -f2)
```
**Issue**: Assumes primary settings are in PPP format

#### **Problem 3: Primary Restoration**
```bash
# In failback_to_primary():
cp "${MWAN_STATE_DIR}/primary-backup" /var/ipfire/ppp/settings
source "${MWAN_STATE_DIR}/primary-backup"
if [ -n "${USERNAME}" ] && [ -n "${PASSWORD}" ]; then
    echo "'${USERNAME}' * '${PASSWORD}'" > /var/ipfire/ppp/secrets  # ❌ PPPoE assumption
fi
```
**Issue**: Assumes primary uses PPP authentication

#### **Problem 4: Connection Type Detection**
```bash
# Missing: Detection of actual primary connection type
# Should support: STATIC, DHCP, PPPOE, PPTP, QMI
```

### **What Needs to Change**:

1. **✅ Generic Primary Backup**: Backup actual IPFire settings, not just PPP
2. **✅ Connection Type Detection**: Detect and handle all connection types
3. **✅ Type-Specific Restoration**: Restore based on actual primary type
4. **✅ Universal Testing**: Test primary regardless of connection type
5. **✅ Configuration Abstraction**: Abstract away connection-specific details

## Summary of Required Changes

### **Major Changes Needed**:

1. **Replace PPP-centric backup with universal backup**
2. **Add connection type detection and handling**
3. **Implement type-specific restoration logic**
4. **Create universal primary connection testing**
5. **Abstract configuration management**

The implementation needs to be **completely connection-type agnostic** to work with any primary WAN type (STATIC, DHCP, PPPoE, PPTP, QMI, etc.).