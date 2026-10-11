#!/bin/bash

user=$(whoami)
if [ "$user" != "root" ] # only runs if using sudo or root
then
 echo "You must run this script with root privileges. Please use sudo" >&2
 exit 1
fi

# Backups go in the home folder of whoever ran sudo (falls back to root's home)
run_user="${SUDO_USER:-root}"
user_home=$(getent passwd "$run_user" | cut -d: -f6)
backup_path="${user_home}/backups/"

xml_path="/etc/libvirt/qemu/"
shutdown_timeout=60 # seconds to wait for a clean shutdown before giving up
max_jobs=4 # number of VMs backed up at the same time

# Split CPU cores between parallel jobs for pigz
pigz_threads=$(( $(nproc) / max_jobs ))
[ "$pigz_threads" -lt 1 ] && pigz_threads=1

# Use pigz (parallel gzip) if installed, otherwise fall back to gzip
if command -v pigz >/dev/null 2>&1
then
 compress_cmd=(pigz -p "$pigz_threads")
else
 echo "pigz not found, falling back to single-threaded gzip (sudo apt install pigz)" >&2
 compress_cmd=(gzip)
fi

# Timestamp used to tag each backup file with the date/time it was taken
timestamp=$(date +%Y-%m-%d_%H-%M-%S)

# Make sure the backup destination actually exists before we try to write to it
mkdir -p "$backup_path"
if [ ! -d "$backup_path" ] || [ ! -w "$backup_path" ]
then
 echo "Backup path '${backup_path}' does not exist or is not writable. Aborting." >&2
 exit 4
fi

# Make sure the backup folder belongs to the user who ran the script, not root
chown "$run_user":"$(id -gn "$run_user")" "$backup_path"

# --- Pull VM names automatically ---
vm_names=()
if command -v virsh >/dev/null 2>&1
then
 mapfile -t vm_names < <(virsh list --all --name | sed '/^$/d')
fi

if [ ${#vm_names[@]} -eq 0 ]
then
 for xmlfile in "${xml_path}"*.xml
 do
  [ -e "$xmlfile" ] || continue
  name=$(grep -oPm1 "(?<=<name>)[^<]+" "$xmlfile")
  [ -n "$name" ] && vm_names+=("$name")
 done
fi

if [ ${#vm_names[@]} -eq 0 ]
then
 echo "No VMs found via virsh or in ${xml_path}. Aborting." >&2
 exit 3
fi

# --- Format a number of seconds as "Xh Ym Zs" ---
format_duration() {
 local total="$1"
 local h=$((total / 3600))
 local m=$(( (total % 3600) / 60 ))
 local s=$((total % 60))

 if [ "$h" -gt 0 ]
 then
  echo "${h}h ${m}m ${s}s"
 elif [ "$m" -gt 0 ]
 then
  echo "${m}m ${s}s"
 else
  echo "${s}s"
 fi
}

# --- Resolve a VM's real disk image path via libvirt, instead of guessing ---
get_disk_path() {
 local vm_name="$1"
 local disk_path=""

 if command -v virsh >/dev/null 2>&1
 then
  disk_path=$(virsh domblklist "$vm_name" --details 2>/dev/null \
   | awk '$2=="disk" {print $NF; exit}')
 fi

 if [ -z "$disk_path" ]
 then
  local xmlfile="${xml_path}${vm_name}.xml"
  if [ -f "$xmlfile" ]
  then
   disk_path=$(grep -oPm1 "(?<=<source file=')[^']+" "$xmlfile")
  fi
 fi

 echo "$disk_path"
}

# --- Gracefully shut down a VM before backing it up ---
# Returns 0 if the VM is safe to back up, 1 if shutdown failed.
shutdown_vm_for_backup() {
 local vm_name="$1"
 local state
 state=$(virsh domstate "$vm_name" 2>/dev/null)

 if [ "$state" != "running" ]
 then
  echo "  ${vm_name} is already ${state:-unknown}; no action needed."
  return 0
 fi

 echo "  ${vm_name} is running. Requesting graceful shutdown..."
 virsh shutdown "$vm_name" >/dev/null 2>&1

 local waited=0
 while [ "$(virsh domstate "$vm_name" 2>/dev/null)" = "running" ]
 do
  if [ "$waited" -ge "$shutdown_timeout" ]
  then
   echo "  ${vm_name} did not shut down within ${shutdown_timeout}s. Skipping backup for safety." >&2
   return 1
  fi
  sleep 2
  waited=$((waited+2))
 done

 echo "  ${vm_name} shut down cleanly."
 return 0
}

backup_vm() {
 local vm="$1"
 local disk_path out_file xml_out

 shutdown_vm_for_backup "$vm" || return 1

 # --- Back up the domain's XML definition ---
 xml_out="${backup_path}${vm}_${timestamp}.xml"
 if virsh dumpxml "$vm" > "$xml_out" 2>/dev/null && [ -s "$xml_out" ]
 then
  echo "${vm} XML definition saved (${xml_out})"
 else
  echo "Could not dump XML definition for ${vm}." >&2
  rm -f "$xml_out" 2>/dev/null
 fi

 # --- Back up the disk image ---
 disk_path=$(get_disk_path "$vm")

 if [ -z "$disk_path" ] || [ ! -f "$disk_path" ]
 then
  echo "Could not locate disk image for ${vm} (looked up: '${disk_path}'). Skipping." >&2
 else
  local ext="${disk_path##*.}"
  out_file="${backup_path}${vm}_${timestamp}.${ext}.gz"
  echo "Backing up VM ${vm} (source: ${disk_path})"

  if "${compress_cmd[@]}" < "$disk_path" > "$out_file"
  then
   echo "${vm} BACKUP DONE (${out_file})"
  else
   echo "${vm} BACKUP FAILED -- could not write ${out_file}" >&2
   rm -f "$out_file" 2>/dev/null
  fi
 fi
}

# --- Run backup_vm for each given VM, up to $max_jobs at a time ---
run_backups() {
 local vm
 for vm in "$@"
 do
  while [ "$(jobs -rp | wc -l)" -ge "$max_jobs" ]
  do
   wait -n
  done
  backup_vm "$vm" &
 done
 wait
}

# --- Parse a selection string like "1,3-5,7" into a sorted list of unique
# indices, validated against 1..max. Prints one index per line, or prints
# nothing and returns 1 if the input was invalid. ---
parse_selection() {
 local input="$1" max="$2"
 local -a result=()
 local part start end i

 IFS=',' read -ra parts <<< "$input"
 [ ${#parts[@]} -eq 0 ] && return 1

 for part in "${parts[@]}"
 do
  part="${part// /}" # strip stray spaces
  [ -z "$part" ] && return 1

  if [[ "$part" =~ ^[0-9]+-[0-9]+$ ]]
  then
   start="${part%-*}"
   end="${part#*-}"
   if [ "$start" -lt 1 ] || [ "$end" -gt "$max" ] || [ "$start" -gt "$end" ]
   then
    return 1
   fi
   for ((i=start; i<=end; i++)); do result+=("$i"); done

  elif [[ "$part" =~ ^[0-9]+$ ]]
  then
   if [ "$part" -lt 1 ] || [ "$part" -gt "$max" ]
   then
    return 1
   fi
   result+=("$part")

  else
   return 1
  fi
 done

 printf '%s\n' "${result[@]}" | sort -nu
}

# prompt if all VMs to be backed-up
read -p "Backup all VMs? (y|n): " answer

if [ "$answer" = "y" ]
then
 run_backups "${vm_names[@]}"

elif [ "$answer" = "n" ]
then
 selected=()

 # Loop until the user picks a selection AND confirms it
 while true
 do
  echo "Select VM(s) to back up:"
  for i in "${!vm_names[@]}"
  do
   echo "$((i+1)). ${vm_names[$i]}"
  done

  read -p "Enter selection (e.g. 2 or 1,3 or 1-3, max ${#vm_names[@]}): " numanswer
  mapfile -t selected < <(parse_selection "$numanswer" "${#vm_names[@]}")

  until [ ${#selected[@]} -gt 0 ]
  do
   read -p "Invalid selection. Try again (e.g. 2 or 1,3 or 1-3): " numanswer
   mapfile -t selected < <(parse_selection "$numanswer" "${#vm_names[@]}")
  done

  echo ""
  echo "You selected the following VM(s):"
  for idx in "${selected[@]}"
  do
   echo "  - ${vm_names[$((idx-1))]}"
  done

  read -p "Proceed with backing up these VM(s)? (y|n): " confirm
  case "$confirm" in
   y|Y) break ;;
   n|N) echo "" ; continue ;; # go back and let them re-select
   *) echo "Please enter y or n." ; echo "" ; continue ;;
  esac
 done

 sel_vms=()
 for idx in "${selected[@]}"
 do
  sel_vms+=("${vm_names[$((idx-1))]}")
 done
 run_backups "${sel_vms[@]}"
else
 echo "Invalid Selection... Aborting program"
 exit 2
fi

# Hand this run's backup files over to the user who ran the script
chown "$run_user":"$(id -gn "$run_user")" "${backup_path}"*"${timestamp}"* 2>/dev/null

echo ""
echo "All done. Total time to complete: $(format_duration "$SECONDS")"
