#!/bin/sh
# Enable Hyper-V Enhanced Session on Debian 13 Trixie (Gnome) guests via XRDP

###############################################################################
# Pre-flight preparations

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo 'This script must be run with root privileges' >&2
    exit 1
fi

# Update packages to latest versions
apt update && apt upgrade -y

# Compare running and target kernels to check if reboot is required
# Manual check since needrestart is not installed by default
if [ -L /vmlinuz ] && [[ "$(readlink /vmlinuz)" != *"-$(uname -r)"* ]]; then
    echo "A reboot is required in order to proceed with the install." >&2
    echo "Please reboot and re-run this script to finish the install." >&2
    exit 1
fi

###############################################################################
# Package installation

# Prevent services from starting automatically during installation
systemctl mask xrdp.service
systemctl mask xrdp-sesman.service

# Install required packages
apt install -y xrdp xorgxrdp pipewire-module-xrdp

# Unmask services to allow standard operation
systemctl unmask xrdp.service
systemctl unmask xrdp-sesman.service

###############################################################################
# Configure XRDP ini files

# Backup original ini files
if [ ! -f /etc/xrdp/xrdp.ini_orig ]; then
    cp /etc/xrdp/xrdp.ini /etc/xrdp/xrdp.ini_orig
fi

if [ ! -f /etc/xrdp/sesman.ini_orig ]; then
    cp /etc/xrdp/sesman.ini /etc/xrdp/sesman.ini_orig
fi

# XRDP bypasses GDM and misses early environment variables
# Wrapper sets XDG_CURRENT_DESKTOP before D-Bus initializes
# Prevents systemd portal failures and application freezes
if [ ! -e /etc/xrdp/startdebian.sh ]; then
    cat > /etc/xrdp/startdebian.sh << 'EOF'
#!/bin/sh

# Inject GNOME environment variable early for systemd and D-Bus
export XDG_CURRENT_DESKTOP=GNOME
exec /etc/xrdp/startwm.sh
EOF
    chmod a+x /etc/xrdp/startdebian.sh
fi

# Configure XRDP to execute custom session wrapper
sed -i -e 's/=startwm\.sh/=startdebian.sh/g' /etc/xrdp/sesman.ini

# Use vsock transport to enable Enhanced session
sed -i -e 's/port=3389/port=vsock:\/\/-1:3389/g' /etc/xrdp/xrdp.ini

# Unencrypted RDP required as XRDP < v0.10.4 lacks vsock TLS support
# Security impact is limited since vsock connections are local-only

# Use RDP security
sed -i -e 's/security_layer=negotiate/security_layer=rdp/g' /etc/xrdp/xrdp.ini

# Disable encryption for local vsock connection
sed -i -e 's/crypt_level=high/crypt_level=none/g' /etc/xrdp/xrdp.ini

# Disable redundant bitmap compression for memory-based vsock
sed -i -e 's/bitmap_compression=true/bitmap_compression=false/g' /etc/xrdp/xrdp.ini

# Rename redirected drive mount point to shared-drives
sed -i -e 's/FuseMountName=thinclient_drives/FuseMountName=shared-drives/g' /etc/xrdp/sesman.ini

###############################################################################
# Define polkit rules for XRDP sessions
# Adjust group to "users" if target user lacks sudo privileges

# Fix "Interactive authentication required" errors (colord, packagekit)
POLKIT_DIR="/etc/polkit-1/rules.d"

if [ ! -e "$POLKIT_DIR/45-allow-colord.rules" ]; then
    cat > "$POLKIT_DIR/45-allow-colord.rules" << 'EOF'
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.color-manager.") === 0 &&
        subject.isInGroup("sudo")) {
        return polkit.Result.YES;
    }
});
EOF
fi

if [ ! -e "$POLKIT_DIR/46-allow-update-repo.rules" ]; then
    cat > "$POLKIT_DIR/46-allow-update-repo.rules" << 'EOF'
polkit.addRule(function(action, subject) {
    if (action.id === "org.freedesktop.packagekit.system-sources-refresh" &&
        subject.isInGroup("sudo")) {
        return polkit.Result.YES;
    }
});
EOF
fi

# Bypass administrative prompts for power management actions
if [ ! -e "$POLKIT_DIR/47-allow-power-off.rules" ]; then
    cat > "$POLKIT_DIR/47-allow-power-off.rules" << 'EOF'
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.login1.power-off" ||
         action.id == "org.freedesktop.login1.power-off-multiple-sessions" ||
         action.id == "org.freedesktop.login1.reboot" ||
         action.id == "org.freedesktop.login1.reboot-multiple-sessions" ||
         action.id == "org.freedesktop.login1.suspend" ||
         action.id == "org.freedesktop.login1.suspend-multiple-sessions" ||
         action.id == "org.freedesktop.login1.hibernate" ||
         action.id == "org.freedesktop.login1.hibernate-multiple-sessions") &&
        subject.isInGroup("sudo")) {
        return polkit.Result.YES;
    }
});
EOF
fi

###############################################################################
# Ensure proper modules are loaded

# Blacklist VMware vsock module to prevent potential conflicts in Hyper-V
if [ ! -e /etc/modprobe.d/blacklist-vmw_vsock_vmci_transport.conf ]; then
    echo "blacklist vmw_vsock_vmci_transport" > /etc/modprobe.d/blacklist-vmw_vsock_vmci_transport.conf
fi

# Ensure hv_sock gets loaded
if [ ! -e /etc/modules-load.d/hv_sock.conf ]; then
    echo "hv_sock" > /etc/modules-load.d/hv_sock.conf
fi

###############################################################################

# Enable XRDP services on system startup
systemctl enable xrdp
systemctl enable xrdp-sesman

echo ""
echo "Install is complete."
echo "Please turn off your VM and execute the following in PowerShell (Admin):"
echo "  Set-VM \"Debian\" -EnhancedSessionTransportType HvSocket"
echo "Then turn on your VM again."
