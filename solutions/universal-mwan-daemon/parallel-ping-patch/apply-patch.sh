#!/bin/bash
###############################################################################
# Apply Parallel Ping Testing Patch to Universal MWAN Daemon
###############################################################################

MWAN_DAEMON="/usr/local/bin/mwan-daemon-universal"
PATCH_FILE="parallel-ping-testing.patch"
BACKUP_FILE="/usr/local/bin/mwan-daemon-universal.backup"

echo "=== Universal MWAN Daemon - Parallel Ping Testing Patch ==="
echo ""

# Check if daemon exists
if [ ! -f "${MWAN_DAEMON}" ]; then
    echo "❌ ERROR: Universal MWAN daemon not found at ${MWAN_DAEMON}"
    echo "   Please install the universal-mwan-daemon first."
    exit 1
fi

# Check if patch file exists
if [ ! -f "${PATCH_FILE}" ]; then
    echo "❌ ERROR: Patch file ${PATCH_FILE} not found"
    echo "   Please run this script from the patch directory."
    exit 1
fi

# Create backup
echo "📦 Creating backup of current daemon..."
cp "${MWAN_DAEMON}" "${BACKUP_FILE}"
if [ $? -eq 0 ]; then
    echo "✅ Backup created: ${BACKUP_FILE}"
else
    echo "❌ ERROR: Failed to create backup"
    exit 1
fi

# Apply patch
echo ""
echo "🔧 Applying parallel ping testing patch..."
if patch "${MWAN_DAEMON}" < "${PATCH_FILE}"; then
    echo "✅ Patch applied successfully!"
else
    echo "❌ ERROR: Failed to apply patch"
    echo "   Restoring backup..."
    cp "${BACKUP_FILE}" "${MWAN_DAEMON}"
    exit 1
fi

# Verify patch
echo ""
echo "🔍 Verifying patch installation..."
if grep -q "test_connectivity_through_interface" "${MWAN_DAEMON}"; then
    echo "✅ Parallel ping testing functions found"
else
    echo "❌ ERROR: Patch verification failed"
    echo "   Restoring backup..."
    cp "${BACKUP_FILE}" "${MWAN_DAEMON}"
    exit 1
fi

# Set permissions
chmod +x "${MWAN_DAEMON}"

echo ""
echo "🎉 Parallel ping testing patch installed successfully!"
echo ""
echo "📋 What's New:"
echo "   • Real connectivity testing with ping to 8.8.8.8, 1.1.1.1, 208.67.222.222"
echo "   • Parallel testing without disrupting backup connection"
echo "   • Connection-type specific testing (PPPoE, Static, DHCP, QMI)"
echo "   • Temporary routing tables (100-102) for test isolation"
echo "   • Clean cleanup of temporary configuration"
echo ""
echo "🧪 Test the Enhancement:"
echo "   /usr/local/bin/mwan-config test-primary"
echo ""
echo "📊 Monitor Parallel Testing:"
echo "   tail -f /var/log/mwan.log | grep -E '(parallel|connectivity|ping)'"
echo ""
echo "🔄 Rollback if Needed:"
echo "   cp ${BACKUP_FILE} ${MWAN_DAEMON}"
echo ""