#!/bin/sh
# =============================================================================
#  esxi-patch.sh -- Interactive ESXi Patch Utility
#  Run on ESXi host shell via SSH from a Windows VM on the same host.
#
#  Pull and run:
#    wget -O /tmp/esxi-patch.sh "https://your-host/esxi-patch.sh" && sh /tmp/esxi-patch.sh
#    curl -o /tmp/esxi-patch.sh "https://your-host/esxi-patch.sh" && sh /tmp/esxi-patch.sh
#
#  What happens to your management VM:
#    - A graceful guest shutdown is sent before the host reboots.
#    - Your SSH session drops as the VM shuts down -- that's expected.
#    - The patch and reboot continue in a background process on the host.
#    - The VM auto-starts when the host comes back up (already configured).
#    - Reconnect after the host comes back up.
# =============================================================================

SEP="========================================================================"
SEP_S="------------------------------------------------------------------------"
LOG_FILE="/tmp/esxi-patch-$(date +%Y%m%d-%H%M%S).log"
EXEC_SCRIPT="/tmp/esxi_patch_exec.sh"

# ESXi doesn't always set a full PATH when running scripts from a datastore
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:$PATH

# ------------------------------------------------------------------------------
# LOGGING
# ------------------------------------------------------------------------------

log()    { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }
info()   { log "INFO  $*"; }
ok()     { log "OK    $*"; }
warn()   { log "WARN  $*"; }
fail()   {
    log "FAIL  $*"
    log "Aborted -- no changes made to the host."
    log "Log: $LOG_FILE"
    exit 1
}
sep()    { log "$SEP"; }
seps()   { log "$SEP_S"; }
pf_ok()  { printf "  [PASS] %s\n" "$*" | tee -a "$LOG_FILE"; }
pf_warn(){ printf "  [WARN] %s\n" "$*" | tee -a "$LOG_FILE"; }
pf_fail(){ printf "  [FAIL] %s\n" "$*" | tee -a "$LOG_FILE"; PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS+1)); }

# ------------------------------------------------------------------------------
# HEADER
# ------------------------------------------------------------------------------

clear
printf "\n%s\n" "$SEP"
printf "  ESXi Interactive Patch Utility\n"
printf "  Log: %s\n" "$LOG_FILE"
printf "%s\n\n" "$SEP"

sep
info "Session started"
seps

# ------------------------------------------------------------------------------
# PREFLIGHT CHECKS
# ------------------------------------------------------------------------------

printf "\n  Running preflight checks...\n\n"

PREFLIGHT_ERRORS=0

pf_ok "Running as root"

# ESXi
if ! /bin/esxcli system version get > /dev/null 2>&1; then
    pf_fail "/bin/esxcli not responding at /bin/esxcli"
    fail "Not an ESXi host."
fi
pf_ok "/bin/esxcli available"

# vim-cmd
if [ ! -x "/bin/vim-cmd" ]; then
    pf_fail "vim-cmd not found at /bin/vim-cmd"
    fail "vim-cmd is required for VM management."
fi
pf_ok "vim-cmd available"

# Host info
HOSTNAME=$(/bin/esxcli system hostname get 2>/dev/null | awk '/Fully Qualified/ {print $NF}')
VERSION=$(/bin/esxcli system version get 2>/dev/null | awk '/Version/ {print $2}')
BUILD=$(/bin/esxcli system version get 2>/dev/null | awk '/Build/ {print $2}')
pf_ok "Host: ${HOSTNAME:-unknown}  |  ESXi ${VERSION:-?}  build ${BUILD:-?}"

# nohup
if [ ! -x "/bin/nohup" ]; then
    pf_fail "nohup not found at /bin/nohup"
    fail "nohup is required."
fi
pf_ok "nohup available"

# Maintenance mode
MM_STATE=$(/bin/esxcli system maintenanceMode get 2>/dev/null)
if [ "$MM_STATE" = "Enabled" ]; then
    pf_warn "Host is already in maintenance mode"
else
    pf_ok "Maintenance mode currently disabled"
fi

# Datastores
if [ ! -d "/vmfs/volumes" ] || [ -z "$(ls /vmfs/volumes 2>/dev/null)" ]; then
    pf_fail "/vmfs/volumes empty or not mounted"
    fail "No datastores available."
fi
DS_COUNT=0
for p in /vmfs/volumes/*; do [ -L "$p" ] && DS_COUNT=$((DS_COUNT+1)); done
[ "$DS_COUNT" -eq 0 ] && fail "No named datastores found."
pf_ok "$DS_COUNT named datastore(s) available"

# rc.local.d
RC_LOCAL_OK=0
if [ -w "/etc/rc.local.d/local.sh" ]; then
    pf_ok "/etc/rc.local.d/local.sh writable"
    RC_LOCAL_OK=1
else
    pf_warn "/etc/rc.local.d/local.sh not writable -- auto-exit maintenance mode unavailable"
fi

# Scratch space
SCRATCH_FREE=$(df /scratch 2>/dev/null | awk 'NR==2 {print $4}')
if [ -n "$SCRATCH_FREE" ] && [ "$SCRATCH_FREE" -lt 204800 ]; then
    pf_warn "Scratch space low (${SCRATCH_FREE}KB) -- VIB staging may fail"
else
    pf_ok "Scratch space OK (${SCRATCH_FREE:-unknown}KB free)"
fi

printf "\n"
[ "$PREFLIGHT_ERRORS" -gt 0 ] && fail "$PREFLIGHT_ERRORS preflight check(s) failed."
info "All preflight checks passed"
seps

# ------------------------------------------------------------------------------
# SELECT DATASTORE
# ------------------------------------------------------------------------------

printf "\n%s\n" "$SEP_S"
printf "  Step 1/5 -- Select Datastore\n"
printf "%s\n\n" "$SEP_S"

IDX=0
for path in /vmfs/volumes/*; do
    [ -L "$path" ] || continue
    IDX=$((IDX+1))
    NAME=$(basename "$path")
    FREE=$(df "$path" 2>/dev/null | awk 'NR==2 {printf "%.0fGB free", $4/1048576}')
    printf "  [%d] %-30s %s\n" "$IDX" "$NAME" "${FREE}"
    eval "DSNAME_${IDX}=${NAME}"
done
DS_TOTAL=$IDX

printf "\n  Select [1-%d]: " "$DS_TOTAL"
read DS_IDX
case "$DS_IDX" in ''|*[!0-9]*) fail "Invalid input." ;; esac
[ "$DS_IDX" -lt 1 ] || [ "$DS_IDX" -gt "$DS_TOTAL" ] && fail "Out of range."

eval "SELECTED_DS=\$DSNAME_${DS_IDX}"
DS_PATH="/vmfs/volumes/${SELECTED_DS}"
info "Datastore: $SELECTED_DS"

if [ -d "${DS_PATH}/patch" ]; then
    PATCH_DIR="${DS_PATH}/patch"
elif [ -d "${DS_PATH}/Patch" ]; then
    PATCH_DIR="${DS_PATH}/Patch"
elif [ -d "${DS_PATH}/PATCH" ]; then
    PATCH_DIR="${DS_PATH}/PATCH"
else
    fail "No patch/Patch/PATCH directory found on ${SELECTED_DS}"
fi
info "Patch directory: $PATCH_DIR"

# ------------------------------------------------------------------------------
# SELECT PATCH FILE
# ------------------------------------------------------------------------------

printf "\n%s\n" "$SEP_S"
printf "  Step 2/5 -- Select Patch File  (%s/patch/)\n" "$SELECTED_DS"
printf "%s\n\n" "$SEP_S"

IDX=0
for f in "${PATCH_DIR}"/*.zip "${PATCH_DIR}"/*.ZIP \
          "${PATCH_DIR}"/*.vib "${PATCH_DIR}"/*.VIB; do
    [ -e "$f" ] || continue
    IDX=$((IDX+1))
    FNAME=$(basename "$f")
    FSIZE=$(ls -lh "$f" 2>/dev/null | awk '{print $5}')
    printf "  [%d] %-50s %s\n" "$IDX" "$FNAME" "${FSIZE}"
    eval "FILENAME_${IDX}=${FNAME}"
done
FILE_TOTAL=$IDX

[ "$FILE_TOTAL" -eq 0 ] && fail "No .zip files found in ${PATCH_DIR}"

printf "\n  Select [1-%d]: " "$FILE_TOTAL"
read FILE_IDX
case "$FILE_IDX" in ''|*[!0-9]*) fail "Invalid input." ;; esac
[ "$FILE_IDX" -lt 1 ] || [ "$FILE_IDX" -gt "$FILE_TOTAL" ] && fail "Out of range."

eval "SELECTED_FILE=\$FILENAME_${FILE_IDX}"
DEPOT_PATH="${PATCH_DIR}/${SELECTED_FILE}"
[ -r "$DEPOT_PATH" ] || fail "Cannot read: $DEPOT_PATH"

info "Patch file: $SELECTED_FILE"

# ------------------------------------------------------------------------------
# SELECT PROFILE
# ------------------------------------------------------------------------------

printf "\n%s\n" "$SEP_S"
printf "  Step 3/5 -- Select Profile\n"
printf "%s\n\n" "$SEP_S"
printf "  Reading profiles from depot (this may take a moment)...\n\n"

IDX=0
while IFS= read -r line; do
    # Skip header line and empty lines
    printf "%s" "$line" | grep -q "^Name\|^---\|^$" && continue
    PNAME=$(printf "%s" "$line" | awk '{print $1}')
    [ -z "$PNAME" ] && continue
    IDX=$((IDX+1))
    printf "  [%d] %s\n" "$IDX" "$PNAME"
    eval "PROFILE_${IDX}=${PNAME}"
done << PROFLIST
$(/bin/esxcli software sources profile list -d "$DEPOT_PATH" 2>/dev/null)
PROFLIST
PROFILE_TOTAL=$IDX

if [ "$PROFILE_TOTAL" -eq 0 ]; then
    fail "No profiles found in depot. Check the zip is a valid ESXi depot."
fi

printf "\n  Select [1-%d]: " "$PROFILE_TOTAL"
read PROFILE_IDX
case "$PROFILE_IDX" in ''|*[!0-9]*) fail "Invalid input." ;; esac
[ "$PROFILE_IDX" -lt 1 ] || [ "$PROFILE_IDX" -gt "$PROFILE_TOTAL" ] && fail "Out of range."

eval "SELECTED_PROFILE=\$PROFILE_${PROFILE_IDX}"
info "Profile: $SELECTED_PROFILE"

# ------------------------------------------------------------------------------
# PROFILE COMMAND
# ------------------------------------------------------------------------------

printf "\n%s\n" "$SEP_S"
printf "  Step 4/5 -- Profile Command\n"
printf "%s\n\n" "$SEP_S"
printf "  [1] update   Apply profile, keep third-party VIBs (recommended)\n"
printf "  [2] install  Apply profile, removes any VIBs not in the profile\n"
printf "\n  Select [1-2] (default 1): "
read PROFILE_CMD_IDX
case "$PROFILE_CMD_IDX" in
    2) PROFILE_CMD="install" ;;
    *) PROFILE_CMD="update"  ;;
esac
info "Profile command: $PROFILE_CMD"

# ------------------------------------------------------------------------------
# SELECT MANAGEMENT VM
# Only used to send a graceful shutdown before reboot.
# Auto-start is already configured -- we don't touch it.
# ------------------------------------------------------------------------------

printf "\n%s\n" "$SEP_S"
printf "  Step 5/5 -- Select Your Management VM\n"
printf "\n  This VM will receive a graceful shutdown signal before the host\n"
printf "  reboots. Auto-start is already configured so it comes back on its own.\n"
printf "%s\n\n" "$SEP_S"

IDX=0
while IFS= read -r line; do
    VMID=$(printf "%s" "$line" | awk '{print $1}')
    VMNAME=$(printf "%s" "$line" | awk '{print $2}')
    GUESTOS=$(printf "%s" "$line" | awk '{print $5}')
    [ -z "$VMID" ] && continue
    IDX=$((IDX+1))
    printf "  [%d] %-35s %-30s (VMID: %s)\n" "$IDX" "$VMNAME" "$GUESTOS" "$VMID"
    eval "VMID_${IDX}=${VMID}"
    eval "VMNAME_${IDX}=${VMNAME}"
done << VMLIST
$(/bin/vim-cmd vmsvc/getallvms 2>/dev/null | tail -n +2)
VMLIST
VM_TOTAL=$IDX

MGMT_VMID=""
MGMT_VMNAME="(none)"

if [ "$VM_TOTAL" -eq 0 ]; then
    warn "No VMs found -- skipping shutdown step"
else
    printf "\n  Your management VM [1-%d]: " "$VM_TOTAL"
    read VM_IDX
    case "$VM_IDX" in ''|*[!0-9]*) fail "Invalid input." ;; esac
    [ "$VM_IDX" -lt 1 ] || [ "$VM_IDX" -gt "$VM_TOTAL" ] && fail "Out of range."

    eval "MGMT_VMID=\$VMID_${VM_IDX}"
    eval "MGMT_VMNAME=\$VMNAME_${VM_IDX}"
    info "Management VM: $MGMT_VMNAME (VMID $MGMT_VMID)"

    VM_STATE=$(/bin/vim-cmd vmsvc/power.getstate "$MGMT_VMID" 2>/dev/null | tail -1)
    printf "%s" "$VM_STATE" | grep -qi "on" \
        || warn "VM does not appear to be powered on (state: ${VM_STATE})"
fi

# ------------------------------------------------------------------------------
# AUTO-EXIT MAINTENANCE MODE
# ------------------------------------------------------------------------------

AUTO_EXIT_MM=0
if [ "$RC_LOCAL_OK" -eq 1 ]; then
    printf "\n%s\n" "$SEP_S"
    printf "  Post-Reboot Maintenance Mode\n"
    printf "%s\n\n" "$SEP_S"
    printf "  After rebooting, the host stays in maintenance mode until cleared.\n"
    printf "  Auto-exit maintenance mode on first boot? [y/N]: "
    read AUTO_EXIT_REPLY
    case "$AUTO_EXIT_REPLY" in
        y|Y|yes|YES) AUTO_EXIT_MM=1 ; info "Auto-exit MM: yes" ;;
        *)           info "Auto-exit MM: no (manual)" ;;
    esac
fi

# ------------------------------------------------------------------------------
# SUMMARY + CONFIRM
# ------------------------------------------------------------------------------

printf "\n%s\n" "$SEP"
printf "  Summary\n"
printf "%s\n" "$SEP"
printf "  Host          : %s  (ESXi %s build %s)\n" "${HOSTNAME:-unknown}" "${VERSION:-?}" "${BUILD:-?}"
printf "  Datastore     : %s\n" "$SELECTED_DS"
printf "  Patch file    : %s\n" "$SELECTED_FILE"
printf "  Profile       : %s\n" "$SELECTED_PROFILE"
printf "  Command       : /bin/esxcli software profile %s\n" "$PROFILE_CMD"
printf "  Management VM : %s\n" "$MGMT_VMNAME"
printf "  Auto-exit MM  : %s\n" "$([ $AUTO_EXIT_MM -eq 1 ] && printf yes || printf no)"
printf "\n  Sequence:\n"
printf "    1. Hand off to background process\n"
printf "    2. Gracefully shut down '%s'  <-- your session drops here\n" "$MGMT_VMNAME"
printf "    3. Enter maintenance mode\n"
printf "    4. Apply patch\n"
printf "    5. Reboot host\n"
[ "$AUTO_EXIT_MM" -eq 1 ] && \
printf "    6. Exit maintenance mode automatically on first boot\n"
printf "\n  Your VM is already on auto-start and will come back on its own.\n"
printf "  Reconnect to %s after the host is back up.\n" "${HOSTNAME:-the host}"
printf "\n%s\n\n" "$SEP"

printf "  Proceed? [y/N]: "
read CONFIRM
case "$CONFIRM" in
    y|Y|yes|YES) ;;
    *) printf "\nAborted. No changes made.\n\n"; exit 0 ;;
esac

sep
info "User confirmed -- building execution plan"
seps

# ------------------------------------------------------------------------------
# AUTO-EXIT MM HOOK
# Write this now so it survives into the next boot regardless of what happens.
# ------------------------------------------------------------------------------

if [ "$AUTO_EXIT_MM" -eq 1 ]; then
    info "Writing auto-exit MM hook to /etc/rc.local.d/local.sh"
    sed -i '/ESXI_PATCH_EXIT_MM/d' /etc/rc.local.d/local.sh 2>/dev/null
    sed -i '/maintenanceMode set --enable false/d' /etc/rc.local.d/local.sh 2>/dev/null
    cat >> /etc/rc.local.d/local.sh << 'RC_EOF'

# ESXI_PATCH_EXIT_MM -- written by esxi-patch.sh, self-removes after one boot
/bin/esxcli system maintenanceMode set --enable false
sed -i '/ESXI_PATCH_EXIT_MM/d' /etc/rc.local.d/local.sh
sed -i '/maintenanceMode set --enable false/d' /etc/rc.local.d/local.sh
RC_EOF
    grep -q "ESXI_PATCH_EXIT_MM" /etc/rc.local.d/local.sh \
        && ok "Auto-exit MM hook written" \
        || warn "Hook may not have written correctly -- check /etc/rc.local.d/local.sh"
fi

# ------------------------------------------------------------------------------
# BUILD AND LAUNCH BACKGROUND EXEC SCRIPT
# All host changes happen here -- nothing runs in the foreground after this.
# Correct order: shutdown VM -> enter MM -> apply patch -> reboot
# ------------------------------------------------------------------------------

info "Writing background execution script..."

cat > "$EXEC_SCRIPT" << EXECEOF
#!/bin/sh
LOG_FILE="${LOG_FILE}"
MGMT_VMID="${MGMT_VMID}"
MGMT_VMNAME="${MGMT_VMNAME}"
DEPOT_PATH="${DEPOT_PATH}"
SELECTED_PROFILE="${SELECTED_PROFILE}"
PROFILE_CMD="${PROFILE_CMD}"
AUTO_EXIT_MM="${AUTO_EXIT_MM}"

log() { printf "[%s] %s\n" "\$(date '+%H:%M:%S')" "\$*" >> "\$LOG_FILE"; }
info() { log "INFO  \$*"; }
ok()   { log "OK    \$*"; }
warn() { log "WARN  \$*"; }

abort() {
    warn "\$*"
    warn "Aborting -- exiting maintenance mode if active"
    /bin/esxcli system maintenanceMode set --enable false 2>/dev/null
    [ "\$AUTO_EXIT_MM" = "1" ] && {
        sed -i '/ESXI_PATCH_EXIT_MM/d' /etc/rc.local.d/local.sh 2>/dev/null
        sed -i '/maintenanceMode set --enable false/d' /etc/rc.local.d/local.sh 2>/dev/null
    }
    exit 1
}

info "========================================================"
info "Background exec started (PID \$\$)"
info "========================================================"

# -- STEP 1: Shut down management VM --
# Must happen before maintenance mode so the host isn't blocked by running VMs.
if [ -n "\$MGMT_VMID" ]; then
    info "[1/3] Sending graceful shutdown to '\${MGMT_VMNAME}' (VMID \${MGMT_VMID})"
    VM_STATE=\$(/bin/vim-cmd vmsvc/power.getstate "\$MGMT_VMID" 2>/dev/null | tail -1)

    if printf "%s" "\$VM_STATE" | grep -qi "on"; then
        /bin/vim-cmd vmsvc/power.shutdown "\$MGMT_VMID" >> "\$LOG_FILE" 2>&1
        info "      Shutdown signal sent -- waiting up to 90s..."

        WAITED=0
        while [ \$WAITED -lt 90 ]; do
            sleep 5
            WAITED=\$((WAITED+5))
            STATE=\$(/bin/vim-cmd vmsvc/power.getstate "\$MGMT_VMID" 2>/dev/null | tail -1)
            info "      State: \${STATE}  (\${WAITED}s)"
            printf "%s" "\$STATE" | grep -qi "off" && { ok "      VM powered off cleanly"; break; }
        done

        # Force off if graceful shutdown timed out
        STATE=\$(/bin/vim-cmd vmsvc/power.getstate "\$MGMT_VMID" 2>/dev/null | tail -1)
        if ! printf "%s" "\$STATE" | grep -qi "off"; then
            warn "      Graceful shutdown timed out -- forcing power off"
            /bin/vim-cmd vmsvc/power.off "\$MGMT_VMID" >> "\$LOG_FILE" 2>&1
            sleep 10
        fi
    else
        warn "      VM not powered on (state: \${VM_STATE}) -- skipping shutdown"
    fi
else
    info "[1/3] No management VM selected -- skipping shutdown"
fi

# -- STEP 2: Enter maintenance mode --
info "[2/3] Entering maintenance mode..."
/bin/esxcli system maintenanceMode set --enable true

WAITED=0
while [ "\$(/bin/esxcli system maintenanceMode get 2>/dev/null)" != "Enabled" ]; do
    sleep 5
    WAITED=\$((WAITED+5))
    info "      Waiting... (\${WAITED}s)"
    if [ "\$WAITED" -ge 120 ]; then
        abort "Timed out waiting for maintenance mode after 120s"
    fi
done
ok "[2/3] Maintenance mode active"

# -- STEP 3: Apply patch --
info "[3/3] Applying patch..."
info "      /bin/esxcli software profile \${PROFILE_CMD} -d \${DEPOT_PATH} -p \${SELECTED_PROFILE}"

/bin/esxcli software profile "\$PROFILE_CMD" -d "\$DEPOT_PATH" -p "\$SELECTED_PROFILE" >> "\$LOG_FILE" 2>&1
PATCH_RC=\$?

if [ \$PATCH_RC -ne 0 ]; then
    if tail -5 "\$LOG_FILE" | grep -qiE "no upgrade|already installed|up-to-date"; then
        warn "Patch appears already applied -- rebooting anyway"
    else
        abort "Patch FAILED (exit code \$PATCH_RC) -- reconnect and check: \$LOG_FILE"
    fi
fi

ok "[3/3] Patch applied -- rebooting in 5 seconds"
sleep 5
reboot
EXECEOF

chmod +x "$EXEC_SCRIPT"
ok "Execution script ready"

/bin/nohup sh "$EXEC_SCRIPT" >> "$LOG_FILE" 2>&1 &
EXEC_PID=$!
ok "Background process launched (PID $EXEC_PID)"
seps

# ------------------------------------------------------------------------------
# DONE -- hand off complete
# ------------------------------------------------------------------------------

printf "\n%s\n" "$SEP"
printf "  Handed off to background process (PID %s)\n\n" "$EXEC_PID"
printf "  What happens next:\n"
printf "    - '%s' will be shut down gracefully\n" "$MGMT_VMNAME"
printf "    - Your SSH session will disconnect\n"
printf "    - Patch will be applied and host will reboot\n"
printf "    - Your VM auto-starts when the host comes back up\n"
printf "\n  Check the log after reconnecting:\n"
printf "    cat %s\n" "$LOG_FILE"
printf "%s\n\n" "$SEP"

exit 0