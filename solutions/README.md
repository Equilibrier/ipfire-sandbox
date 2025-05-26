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
- **Status**: ✅ Recommended solution
- **Reason**: Update-proof, non-intrusive, proper system integration

## Current Focus

Working on **Standalone MWAN Daemon** with specific focus on:
1. **System Override Capability**: Proving it can take control during failover
2. **GSM 4G Dongle Support**: Real-world scenario with manual configuration
3. **LAN Device Routing**: Ensuring backup connection works for all LAN devices

## User Requirements

- ✅ Priority-based failover (not load balancing)
- ✅ PPPoE primary connection remains primary
- ✅ Secondary WAN activates only on failure
- ✅ Automatic failback when primary recovers
- ✅ Survives IPFire auto-updates
- ✅ Works with GSM 4G dongles
- ✅ Proper LAN device routing during failover