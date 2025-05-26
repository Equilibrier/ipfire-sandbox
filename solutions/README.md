# IPFire MWAN Solutions

This directory contains different approaches to implementing Multi-WAN failover for IPFire.

## Solutions Overview

### 1. **Load Balancing MWAN** (`load-balancing-mwan/`)
- **Purpose**: Traditional multi-WAN with load balancing across multiple connections
- **Status**: ❌ Not suitable for user requirements
- **Reason**: User specifically needs priority-based failover, not load balancing

### 2. **Priority Failover via connectd** (`priority-failover-connectd/`)
- **Purpose**: Enhanced connectd daemon with priority-based failover
- **Status**: ⚠️ Functional but has update compatibility issues
- **Reason**: Modifies system files that get overwritten by IPFire updates

### 3. **Standalone MWAN Daemon** (`standalone-mwan-daemon/`)
- **Purpose**: Independent MWAN system that survives IPFire updates
- **Status**: ✅ Functional solution
- **Reason**: Update-proof, non-intrusive, proper system integration

### 4. **Universal MWAN Daemon** (`universal-mwan-daemon/`) ⭐ **RECOMMENDED**
- **Purpose**: Connection-type agnostic MWAN with enhanced testing
- **Status**: ✅ Enhanced recommended solution
- **Reason**: Works with ANY connection type, real connectivity testing, future-proof

## Current Focus

Working on **Universal MWAN Daemon** with specific focus on:
1. **Enhanced Primary Testing**: Real connectivity testing with parallel routes
2. **Connection Type Agnostic**: Works with PPPoE, STATIC, DHCP, QMI, etc.
3. **System Override Capability**: Proven ability to take control during failover
4. **GSM 4G Dongle Support**: Real-world scenario with manual configuration
5. **LAN Device Routing**: Ensuring backup connection works for all LAN devices

## User Requirements

- ✅ Priority-based failover (not load balancing)
- ✅ PPPoE primary connection remains primary
- ✅ Secondary WAN activates only on failure
- ✅ Automatic failback when primary recovers
- ✅ Survives IPFire auto-updates
- ✅ Works with GSM 4G dongles
- ✅ Proper LAN device routing during failover