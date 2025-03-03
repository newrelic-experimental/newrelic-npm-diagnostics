#!/usr/bin/bash

###--- GENERAL FUNCTIONS ---###

environmentCheck() {
  if [[ -f /etc/default/ktranslate.env ]]; then
    installMethod="BAREMETAL"
  elif [[ $(command -v docker) ]]; then
    if [[ $(docker ps -a --format '{{.Image}}' | grep 'ktranslate') ]]; then
      installMethod="DOCKER"
    fi
  elif [[ $(command -v podman) ]]; then
    if [[ $(podman ps -a --format '{{.Image}}' | grep 'ktranslate') ]]; then
      installMethod="PODMAN"
    fi
  else
    installMethod="UNKNOWN"
  fi
}

rootCheck() {
  # Checks for root user
  if [ "$EUID" -ne 0 ]; then
    echo "Please run this script as root or with sudo to use this function."
    exit 0
  fi
}

showHelpMenu() {
  echo ""
  echo "Usage: npmDiag [--collect|--time|--help] {--installMethod [DOCKER|PODMAN|BAREMETAL]}"
  echo ""
  echo "  --collect: Collects diagnostic info from containers. Outputs a zip file called 'npmDiag-output.zip'"
  echo "  --time: Run 'snmpwalk' against a device from the config. Outputs how long it takes to complete. Useful for calculating timeout settings."
  echo "  --help: Shows this help message."
  echo ""
  echo "In the event npmDiag can't determine what installation method you've used, you can override the auto-discovery by using '--installMethod'"
  echo "followed by the deployment method (DOCKER, PODMAN, or BAREMETAL)."
}

# Other menu functions have a few differences between them but this menu is used four times, so it's been turned into a function to reduce repeated code
deviceLevelContainerSelectMenu() {
  # Forces selection to be space-delimited list of integers, or a 'q' to exit
  # Outputs `menuSelectedOption` array
  menuLoopExit=false
  while [[ "$menuLoopExit" == false ]]; do
    echo ""
    echo "Enter the number associated with the container monitoring your device"
    read -ep "You can also use 'q' to exit the script > " menuSelection
    if [[ "$menuSelection" =~ ^[0-9]+$ ]]; then
      if [[ "$menuSelection" -ge "${#ktranslateContainerIDs[@]}" ]]; then
        echo ""
        echo "Container selection must be an integer shown in the listed options."
        menuLoopExit=false
        unset menuSelection
      else
        targetContainerID="${ktranslateContainerIDs[$menuSelection]}"
        menuLoopExit=true
        unset menuSelection
      fi
    elif [[ "${menuSelection,,}" = "q" ]]; then
      echo ""
      echo "Exiting..."
      exit 0
    else
      echo ""
      echo "Selection must be an integer, or a 'q' to exit"
    fi
  done
}

###--- COLLECT FUNCTIONS ---###

containerCollectPreReqCheck() {
  # Checks host for package dependencies
  if [[ ! $(command -v jq) || ! $(command -v zip) ]]; then
    echo "A package dependency is missing from the host."
    echo "Please ensure that both 'jq' and 'zip' are installed."
    echo ""
    echo "'jq' and 'zip' can be installed with 'sudo apt install jq zip -y' on Ubuntu"
    echo "or with 'sudo yum install jq zip -y' on RHEL/CentOS"
    echo ""
    echo "If the 'jq' package can't be found on RHEL/CentOS, see:"
    echo "https://github.com/newrelic-experimental/newrelic-npm-diagnostics?tab=readme-ov-file#installation"
    exit 0
  fi
}

baremetalCollectPreReqCheck() {
  if [[ ! $(command -v zip) ]]; then
    echo "A package dependency is missing from the host."
    echo "Please ensure that 'zip' is installed."
    echo ""
    echo "'zip' can be installed with 'sudo apt install zip -y' on Ubuntu"
    echo "or with 'sudo yum install zip -y' on RHEL/CentOS"
    exit 0
  fi
}

dockerCollectRoutine() {
  # Finds container IDs using Ktranslate image. Adds them to `foundContainerIDs` array.
  readarray -t allContainerIDs < <(docker ps -aq)
  for i in "${allContainerIDs[@]}"; do
    if [[ $(docker inspect "$i" | jq -r '.[] | .Config | .User') == 'ktranslate' ]]; then
      foundContainerIDs+=("$i")
    fi
  done

  # Displays menu and allows container selection.
  echo "=-=-=-=-=-=-=-=-=-=-="
  for i in "${!foundContainerIDs[@]}"; do
    echo "[$i] $(docker inspect "${foundContainerIDs[i]}" | jq -r '.[] | .Name' | sed 's/^\///')"
  done
  echo ""
  echo "[q] Exit npmDiag"
  echo "=-=-=-=-=-=-=-=-=-=-="

  # Forces selection to be space-delimited list of integers, or a 'q' to exit
  # Outputs `menuSelectedOption` array
  menuLoopExit=false
  while [[ "$menuLoopExit" == false ]]; do
    echo ""
    echo "Enter space-delimited list of containers you want diagnostic data from (0 1 2...)"
    read -ep "You can also use 'q' to exit the script > " menuSelection
    if [[ "$menuSelection" =~ ^[0-9]+($|[[:space:]]|[0-9]+){1,}$ ]]; then
      read -a menuSelectedOption <<< "$menuSelection"
      for i in "${menuSelectedOption[@]}"; do
        if [[ "$i" -ge "${#foundContainerIDs[@]}" ]]; then
          echo ""
          echo "Container selection must include only integers shown in the listed options."
          menuLoopExit=false
          unset menuSelectedOption
          break
        else
          menuLoopExit=true
        fi
      done
    elif [[ "${menuSelection,,}" = "q" ]]; then
      echo ""
      echo "Exiting..."
      exit 0
    else
      echo ""
      echo "Selection must be a space-delimited list of integers, or a 'q' to exit"
    fi
  done

  # Parses menu selection. Builds `targetContainerIDs` array.
  for i in "${menuSelectedOption[@]}"; do
    targetContainerIDs+=("${foundContainerIDs[i]}")
  done

  # Creates working directory in `/tmp`. 
  tmpFolderName="npmDiag-$(date +%s)"
  mkdir /tmp/"$tmpFolderName"
  for i in "${targetContainerIDs[@]}"; do

    targetContainerName=$(docker inspect "$i" | jq -r '.[] | .Name' | sed 's/^\///')
    targetContainerID=$(docker inspect "$i" | jq -r '.[] | .Id')

    # Gets config files for each container. Copies to a `/tmp` working folder. Renames with Docker container long ID.
    for configFiles in $(docker inspect "$i" | jq -r '.[] | .Mounts | .[] | .Source'); do
      if [ -d "$configFiles" ]; then
        cp -r "$configFiles" /tmp/"$tmpFolderName"/"$targetContainerID"-$(basename "$configFiles")
      else
        cp "$configFiles" /tmp/"$tmpFolderName"/"$targetContainerID"-$(basename "$configFiles")
      fi
    done
    
    # Restarts container to regenerate logs. Sends to a `/tmp` working folder.
    echo ""
    echo "Stopping $targetContainerName"
    docker stop "$i" > /dev/null
    echo -e "\n------------\n                        ____  _             \n  _ __  _ __  _ __ ___ |  _ \\(_) __ _  __ _ \n | '_ \| '_ \| '_ \` _ \| | | | |/ _\` |/ _\` |\n | | | | |_) | | | | | | |_| | | (_| | (_| |\n |_| |_| .__/|_| |_| |_|____/|_|\\__,_|\\__, |\n       |_|                            |___/  \n\n" >> $(docker inspect "$i" | jq -r '.[] | .LogPath')
    echo "Refreshing log file..."
    docker start "$i" > /dev/null

    # Sleeps script for 3 minutes to allow container logs to regenerate
    timer=180
    while [[ "$timer" -gt 0 ]]; do
        minutes=$((timer / 60))
        seconds=$((timer % 60))
        printf "\rTime remaining: %02d:%02d" $minutes $seconds
        sleep 1
        timer=$((timer - 1))
    done
    printf "\rTime remaining: %02d:%02d\n" 0 
    echo "Done recreating logs for $targetContainerName"
    docker logs "$i" > /tmp/"$tmpFolderName"/"$targetContainerID".log

    # Gets `inspect` for each container. Copies to a `/tmp` working folder.
    docker inspect "$i" > /tmp/"$tmpFolderName"/"$targetContainerID"-"$targetContainerName".dockerInspect.out

    # Unsets `target` variables for next collection execution
    unset targetContainerName
    unset targetContainerID
  done
}

podmanCollectRoutine() {
  # Finds container IDs using Ktranslate image. Adds them to `foundContainerIDs` array.
  readarray -t allContainerIDs < <(podman ps -aq)
  for i in "${allContainerIDs[@]}"; do
    if [[ $(podman inspect "$i" | jq -r '.[] | .Config | .User') == 'ktranslate' ]]; then
      foundContainerIDs+=("$i")
    fi
  done

  # Displays menu and allows container selection.
  echo "=-=-=-=-=-=-=-=-=-=-="
  for i in "${!foundContainerIDs[@]}"; do
    echo "[$i] $(podman inspect "${foundContainerIDs[i]}" | jq -r '.[] | .Name' | sed 's/^\///')"
  done
  echo ""
  echo "[q] Exit npmDiag"
  echo "=-=-=-=-=-=-=-=-=-=-="

  # Forces selection to be space-delimited list of integers, or a 'q' to exit
  # Outputs `menuSelectedOption` array
  menuLoopExit=false
  while [[ "$menuLoopExit" == false ]]; do
    echo ""
    echo "Enter space-delimited list of containers you want diagnostic data from (0 1 2...)"
    read -ep "You can also use 'q' to exit the script > " menuSelection
    if [[ "$menuSelection" =~ ^[0-9]+($|[[:space:]]|[0-9]+){1,}$ ]]; then
      read -a menuSelectedOption <<< "$menuSelection"
      for i in "${menuSelectedOption[@]}"; do
        if [[ "$i" -ge "${#foundContainerIDs[@]}" ]]; then
          echo ""
          echo "Container selection must include only integers shown in the listed options."
          menuLoopExit=false
          unset menuSelectedOption
          break
        else
          menuLoopExit=true
        fi
      done
    elif [[ "${menuSelection,,}" = "q" ]]; then
      echo ""
      echo "Exiting..."
      exit 0
    else
      echo ""
      echo "Selection must be a space-delimited list of integers, or a 'q' to exit"
    fi
  done

  # Parses menu selection. Builds `targetContainerIDs` array.
  for i in "${menuSelectedOption[@]}"; do
    targetContainerIDs+=("${foundContainerIDs[i]}")
  done

  # Creates working directory in `/tmp`. 
  tmpFolderName="npmDiag-$(date +%s)"
  mkdir /tmp/"$tmpFolderName"
  for i in "${targetContainerIDs[@]}"; do

    targetContainerName=$(podman inspect "$i" | jq -r '.[] | .Name' | sed 's/^\///')
    targetContainerID=$(podman inspect "$i" | jq -r '.[] | .Id')

    # Gets config files for each container. Copies to a `/tmp` working folder. Renames with Docker container long ID.
    for configFiles in $(podman inspect "$i" | jq -r '.[] | .Mounts | .[] | .Source'); do
      if [ -d "$configFiles" ]; then
        cp -r "$configFiles" /tmp/"$tmpFolderName"/"$targetContainerID"-$(basename "$configFiles")
      else
        cp "$configFiles" /tmp/"$tmpFolderName"/"$targetContainerID"-$(basename "$configFiles")
      fi
    done
    
    # Restarts container to regenerate logs. Sends to a `/tmp` working folder.
    echo ""
    echo "Stopping $targetContainerName"
    podman stop "$i" > /dev/null
    echo "Refreshing log file..."
    podman start "$i" > /dev/null

    # Sleeps script for 3 minutes to allow container logs to regenerate
    timer=180
    while [[ "$timer" -gt 0 ]]; do
      minutes=$((timer / 60))
      seconds=$((timer % 60))
      printf "\rTime remaining: %02d:%02d" $minutes $seconds
      sleep 1
      timer=$((timer - 1))
    done
    printf "\rTime remaining: %02d:%02d\n" 0 
    echo "Done recreating logs for $targetContainerName"
    podman logs "$i" > /tmp/"$tmpFolderName"/"$targetContainerID".log

    # Gets `inspect` for each container. Copies to a `/tmp` working folder.
    podman inspect "$i" > /tmp/"$tmpFolderName"/"$targetContainerID"-"$targetContainerName".podmanInspect.out
    
    # Unsets `target` variables for next collection execution
    unset targetContainerName
    unset targetContainerID
  done
}

baremetalCollectRoutine() {
  # Creates working directory in `/tmp`. 
  tmpFolderName="npmDiag-$(date +%s)"
  mkdir /tmp/"$tmpFolderName"

  # Grabs related files
  cp /etc/default/ktranslate.env /tmp/"$tmpFolderName"/ktranslate.env
  cp $(grep -- '-snmp' /etc/default/ktranslate.env | awk '{print $2}') /tmp/"$tmpFolderName"/$(grep -- '-snmp' /etc/default/ktranslate.env | awk '{print $2}' | xargs basename)
  # Switch to rsync for this so we don't pick up junk from GitHub
  rsync -a --exclude='.git' /etc/ktranslate/profiles /tmp/"$tmpFolderName"

  # Restarts the service to regenerate logs. Sends to a `/tmp` working folder
  systemctl stop ktranslate.service
  echo -e "\n------------\n                        ____  _             \n  _ __  _ __  _ __ ___ |  _ \\(_) __ _  __ _ \n | '_ \| '_ \| '_ \` _ \| | | | |/ _\` |/ _\` |\n | | | | |_) | | | | | | |_| | | (_| | (_| |\n |_| |_| .__/|_| |_| |_|____/|_|\\__,_|\\__, |\n       |_|                            |___/  \n\n" >> /var/log/syslog
  echo "Refreshing log file..."
  systemctl start ktranslate.service

  # Sleeps script for 3 minutes to allow container logs to regenerate
  timer=180
  while [[ "$timer" -gt 0 ]]; do
      minutes=$((timer / 60))
      seconds=$((timer % 60))
      printf "\rTime remaining: %02d:%02d" $minutes $seconds
      sleep 1
      timer=$((timer - 1))
  done
  printf "\rTime remaining: %02d:%02d\n" 0
  echo "Done recreating service logs"

  cat /var/log/syslog | grep ktranslate > /tmp/"$tmpFolderName"/ktranslate.service.log
}

diagZip() {
  # Bundles output files into zip file and places it in the current directory
    activeDirectory=$(pwd)
    outputFileName="npmDiag-output-$(date +%Y-%m-%d-%H-%M-%S).zip"
    runByUsername=$(logname)
    cd /tmp/"$tmpFolderName"
    zip -qr "$activeDirectory"/"$outputFileName" ./*
    cd "$activeDirectory"
    chown "$runByUsername:$runByUsername" "$outputFileName"
    chmod 666 "$outputFileName"
    echo ""
    echo "Created output file '"$outputFileName"' in working directory."
}

postCollectCleanup() {
  # Deletes files from `/tmp`
    rm -rd /tmp/"$tmpFolderName" > /dev/null 2>&1
}

###--- TIME FUNCTIONS ---###

containerTimePreReqCheck() {
  # Checks host for package dependencies
  if [[ ! $(command -v yq) || ! $(command -v jq) ]]; then
    echo "A package dependency is missing from the host."
    echo "Please ensure that both 'yq' and 'jq' are installed."
    echo ""
    echo "'yq' can be installed with 'sudo snap install yq'"
    echo "or you can download a copy from GitHub using"
    echo ""
    echo "sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq \\"
    echo "  && sudo chmod +x /usr/bin/yq"
    echo ""
    echo "'jq' can be installed with 'sudo apt install jq -y' on Ubuntu"
    echo "or with 'sudo yum install jq -y' on RHEL/CentOS"
    echo ""
    echo "If the 'jq' package can't be found on RHEL/CentOS, see:"
    echo "https://github.com/newrelic-experimental/newrelic-npm-diagnostics?tab=readme-ov-file#installation"
  fi
}

baremetalTimePreReqCheck() {
  # Checks host for package dependencies
  if [[ ! $(command -v yq) ]]; then
    echo "A package dependency is missing from the host."
    echo "Please ensure that 'yq' is installed."
    echo ""
    echo "'yq' can be installed with 'sudo snap install yq'"
    echo "You can also download a copy from GitHub using"
    echo ""
    echo "sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq \\"
    echo "  && sudo chmod +x /usr/bin/yq"
    echo ""
    exit 0
  fi
}

dockerTimeRoutine() {
  # Finds container IDs using Ktranslate image. Adds them to `foundContainerIDs` array.
  readarray -t allContainerIDs < <(docker ps -aq)
  for i in "${allContainerIDs[@]}"; do
    if [[ $(docker inspect "$i" | jq -r '.[] | .Config | .User') == 'ktranslate' ]]; then
      ktranslateContainerIDs+=("$i")
    fi
  done

  # Displays menu and allows container selection.
  echo "=-=-=-=-=-=-=-=-=-=-="
  for i in "${!ktranslateContainerIDs[@]}"; do
    echo "[$i] $(docker inspect "${ktranslateContainerIDs[i]}" | jq -r '.[] | .Name' | sed 's/^\///')"
  done
  echo ""
  echo "[q] Exit npmDiag"
  echo "=-=-=-=-=-=-=-=-=-=-="

  # Runs container selection menu for device-level functions
  deviceLevelContainerSelectMenu

  # Creates a temp directory for keeping configs and profiles in
  timeTmpDir="/tmp/npmDiag-tmp-$(date +%s)"
  mkdir -p "$timeTmpDir"
  docker exec -u 0 "$targetContainerID" /bin/sh -c "cat /snmp-base.yaml" >> "$timeTmpDir/snmp-base.yaml"
  configPath="$timeTmpDir/snmp-base.yaml"
  deviceList=($(cat "$configPath" | yq e ".devices | to_entries[] | .key"))

  # Displays menu and allows device selection
  echo ""
  echo "=-=-=-=-=-=-=-=-=-=-="
  for i in "${!deviceList[@]}"; do
    echo "[$i] ${deviceList[i]}"
  done
  echo ""
  echo "[q] Exit npmDiag"
  echo "=-=-=-=-=-=-=-=-=-=-=" 

  # Forces selection to be an integer, or a q to exit
  menuLoopExit=false
  while [[ "$menuLoopExit" == false ]]; do
    echo ""
    echo "Enter the number of the device you want to time"
    read -ep "You can also use 'q' to exit the script > " menuSelection
    if [[ "$menuSelection" =~ ^[0-9]+$ ]]; then
      if [[ "$menuSelection" -ge "${#deviceList[@]}" ]]; then
        echo ""
        echo "Device selection must be an integer shown in the listed options."
        menuLoopExit=false
        unset menuSelection
      else
        targetDevice="${deviceList[$menuSelection]}"
        menuLoopExit=true
      fi
    elif [[ "${menuSelection,,}" = "q" ]]; then
      echo ""
      echo "Exiting..."
      rm -rd "$timeTmpDir"
      exit 0
    else
      echo ""
      echo "Selection must be an integer, or a 'q' to exit"
    fi
  done

  # Gets the assigned profile for a device
  targetDeviceProfile=$(cat "$configPath" | yq e ".devices.\"$targetDevice\".mib_profile")

  # Skip the OID retrieval process if no device profile is defined
  if [[ -z "$targetDeviceProfile" ]]; then
    echo ""
    echo "SNMP profile not found for $targetDevice"
    echo "Polling will not work without a profile being set"
    echo "Exiting..."
    rm -rd "$timeTmpDir"
    exit 1
  fi

  # Grabs copy of device's assigned profile and saves it to a temp directory
  docker exec -u 0 "$targetContainerID" /bin/sh -c "cat \$(find /etc/ktranslate -type f -name \"$targetDeviceProfile\")" >> "$timeTmpDir/$targetDeviceProfile"
  profileLocation="$timeTmpDir/$targetDeviceProfile"

  # Gets the `extends` block from the assigned profile - assigns to the $profileExtensions array
  readarray -t profileExtensions < <(cat "$profileLocation" | yq e '.extends | to_entries[] .value')

  # Grabs copies of device's extension profiles and saves them to a temp directory
  for extension in "${profileExtensions[@]}"; do
    docker exec -u 0 "$targetContainerID" /bin/sh -c "cat \$(find /etc/ktranslate -type f -name \"$extension\")" >> "$timeTmpDir/$extension"
    profileExtensionsLocations+=("$timeTmpDir/$extension")
  done

  # Declares array for storing OIDs to poll
  declare -a selectedOIDs

  # Extract OIDs from a given YAML file
  # Checks if new OID is contained within another discovered OID
  # Prevents long walks (on the beach?) caused by polling whole tables 
  extract_oids() {
    local file="$1"
    local foundOIDs=($(cat "$file" | yq e '.. | select(has("OID")) | .OID' -))
    local filteredOIDs=()

    for unfilteredOID in "${foundOIDs[@]}"; do
    # Only add OID to the filtered list if it is not a substring of any other OID
      isSubOID=false
      for comparisonOID in "${foundOIDs[@]}"; do
        if [[ "$unfilteredOID" != "$comparisonOID" && "$comparisonOID" == *"$unfilteredOID"* ]]; then
          # Checks that the substring is followed by a period, or is an exact match
          if [[ "${comparisonOID:${#unfilteredOID}:1}" == "." || "${#comparisonOID}" == "${#unfilteredOID}" ]]; then
            isSubOID=true
            break
          fi
        fi
      done
      if [ "$isSubOID" = false ]; then
        filteredOIDs+=("$unfilteredOID")
      fi
    done
    echo "${filteredOIDs[@]}"
  }

  # Declaring this higher to capture additional output
  timingOutputFile=./"$targetDevice"_timing_results-$(date +%s).txt

  # Extract OIDs from primary profile
  echo "" | tee -a "$timingOutputFile"
  if [[ -f "$profileLocation" ]]; then
    echo "Grabbing OIDs from assigned profile: $profileLocation" | tee -a "$timingOutputFile"
    selectedOIDs+=($(extract_oids "$profileLocation"))
  fi
  # Extract OIDs from extension profiles
  echo "" | tee -a "$timingOutputFile"
  for profile in "${profileExtensionsLocations[@]}"; do
    if [[ -f "$profile" ]]; then
      echo "Grabbing OIDs from extension profile: $profile" | tee -a "$timingOutputFile"
      selectedOIDs+=($(extract_oids "$profile"))
    fi
  done
  echo "" | tee -a "$timingOutputFile"

  # Retrieves SNMP credentials to determine if it's v1/v2c or v3
  targetDeviceCommString=$(cat "$configPath" | yq e ".devices.\"$targetDevice\".snmp_comm" -)
  targetDeviceV3Creds=$(cat "$configPath" | yq e ".devices.\"$targetDevice\".snmp_v3" -)
  targetDeviceIP=$(cat "$configPath" | yq e ".devices.\"$targetDevice\".device_ip")

  if [[ -n "$targetDeviceCommString" && "$targetDeviceCommString" != "null" ]]; then
    echo "Device $targetDevice is using SNMP v1/v2c"
    startTimeMs=$(date +%s%3N)

    for oid in "${selectedOIDs[@]}"; do
      timestamp=[$(date '+%Y-%m-%d %H:%M:%S,%3N')]
      snmpOutput=$(snmpwalk -v 2c -On -c "$targetDeviceCommString" "$targetDeviceIP" ."$oid")
      # 'Tee' buffers output and slows down loop, skewing results. Double 'echo' statement seems to avoid this issue
      echo "$timestamp $snmpOutput"
      echo "$timestamp $snmpOutput" >> "$timingOutputFile"
    done

    endTimeMs=$(date +%s%3N)
    totalDuration=$(echo "scale=3; ($endTimeMs - $startTimeMs) / 1000" | bc)
    echo "" | tee -a "$timingOutputFile"
    echo "Total time to walk device's assigned profiles: ${totalDuration}s" | tee -a "$timingOutputFile"
    echo ""
    echo "Saved results to $timingOutputFile"

  elif [[ -n "$targetDeviceV3Creds" && "$targetDeviceV3Creds" != "null" ]]; then
    echo ""
    echo "Device $targetDevice is using SNMP v3"
    echo ""
    v3UserName=$(echo "$targetDeviceV3Creds" | yq e '.user_name')
    v3AuthProt=$(echo "$targetDeviceV3Creds" | yq e '.authentication_protocol')
    v3AuthPass=$(echo "$targetDeviceV3Creds" | yq e '.authentication_passphrase')
    v3PrivProt=$(echo "$targetDeviceV3Creds" | yq e '.privacy_protocol')
    v3PrivPass=$(echo "$targetDeviceV3Creds" | yq e '.privacy_passphrase')

    if [[ -n "$v3AuthProt" && "$v3AuthProt" != "null" && -n "$v3PrivProt" && "$v3PrivProt" != "null" ]]; then
      v3Level=authPriv
    elif [[ -n "$v3AuthProt" && "$v3AuthProt" != "null" && ( -z "$v3PrivProt" || "$v3PrivProt" == "null" ) ]]; then
      v3Level=authNoPriv
    elif [[ ( -z "$v3AuthProt" || "$v3AuthProt" == "null" ) && ( -z "$v3PrivProt" || "$v3PrivProt" == "null" ) ]]; then
      v3Level=noAuthNoPriv
    else
      echo "Couldn't determine snmpwalk authentication level. Are 'snmp_v3.authentication_protocol' and 'snmp_v3.privacy_protocol' set for the device?"
      rm -rd "$timeTmpDir"
      exit 1
    fi

    startTimeMs=$(date +%s%3N)

    for oid in "${selectedOIDs[@]}"; do
      timestamp=[$(date '+%Y-%m-%d %H:%M:%S,%3N')]
      snmpOutput=$(snmpwalk -v 3 -l "$v3Level" -u "$v3UserName" -a "$v3AuthProt" -A "$v3AuthPass" -x "$v3PrivProt" -X "$v3PrivPass" -ObentU -Cc "$targetDeviceIP" ."$oid")
      # 'Tee' buffers output and slows down loop, skewing results. Double 'echo' statement seems to avoid this issue
      echo "$timestamp $snmpOutput"
      echo "$timestamp $snmpOutput" >> "$timingOutputFile"
    done

    endTimeMs=$(date +%s%3N)
    totalDuration=$(echo "scale=3; ($endTimeMs - $startTimeMs) / 1000" | bc)
    echo "" | tee -a "$timingOutputFile"
    echo "Total time to walk device's assigned profiles: ${totalDuration}s" | tee -a "$timingOutputFile"
    echo ""
    echo "Saved results to $timingOutputFile"

  else
    echo "SNMP configuration not found for $targetDevice"
    echo "Polling will not work against a device that does not have SNMP credentials configured"
    echo "Check that your device has either '<deviceName>.snmp_comm' or <deviceName>.snmp_v3[]' set"
    echo "Exiting..."
    rm -rd "$timeTmpDir"
    rm "$timingOutputFile"
    exit 1
  fi

  rm -rd "$timeTmpDir"
}

podmanTimeRoutine() {
  # Finds container IDs using Ktranslate image. Adds them to `foundContainerIDs` array.
  readarray -t allContainerIDs < <(podman ps -aq)
  for i in "${allContainerIDs[@]}"; do
    if [[ $(podman inspect "$i" | jq -r '.[] | .Config | .User') == 'ktranslate' ]]; then
      ktranslateContainerIDs+=("$i")
    fi
  done

  # Displays menu and allows container selection.
  echo "=-=-=-=-=-=-=-=-=-=-="
  for i in "${!ktranslateContainerIDs[@]}"; do
    echo "[$i] $(podman inspect "${ktranslateContainerIDs[i]}" | jq -r '.[] | .Name')"
  done
  echo ""
  echo "[q] Exit npmDiag"
  echo "=-=-=-=-=-=-=-=-=-=-="

  # Runs container selection menu for device-level functions
  deviceLevelContainerSelectMenu

  # Creates a temp directory for keeping configs and profiles in
  timeTmpDir="/tmp/npmDiag-tmp-$(date +%s)"
  mkdir -p "$timeTmpDir"
  podman exec "$targetContainerID" /bin/sh -c "cat /snmp-base.yaml" >> "$timeTmpDir/snmp-base.yaml"
  configPath="$timeTmpDir/snmp-base.yaml"
  deviceList=($(cat "$configPath" | yq e ".devices | to_entries[] | .key"))

  # Displays menu and allows device selection
  echo ""
  echo "=-=-=-=-=-=-=-=-=-=-="
  for i in "${!deviceList[@]}"; do
    echo "[$i] ${deviceList[i]}"
  done
  echo ""
  echo "[q] Exit npmDiag"
  echo "=-=-=-=-=-=-=-=-=-=-=" 

  # Forces selection to be an integer, or a q to exit
  menuLoopExit=false
  while [[ "$menuLoopExit" == false ]]; do
    echo ""
    echo "Enter the number of the device you want to time"
    read -ep "You can also use 'q' to exit the script > " menuSelection
    if [[ "$menuSelection" =~ ^[0-9]+$ ]]; then
      if [[ "$menuSelection" -ge "${#deviceList[@]}" ]]; then
        echo ""
        echo "Device selection must be an integer shown in the listed options."
        menuLoopExit=false
        unset menuSelection
      else
        targetDevice="${deviceList[$menuSelection]}"
        menuLoopExit=true
      fi
    elif [[ "${menuSelection,,}" = "q" ]]; then
      echo ""
      echo "Exiting..."
      rm -rd "$timeTmpDir"
      exit 0
    else
      echo ""
      echo "Selection must be an integer, or a 'q' to exit"
    fi
  done

  # Gets the assigned profile for a device
  targetDeviceProfile=$(cat "$configPath" | yq e ".devices.\"$targetDevice\".mib_profile")

  # Skip the OID retrieval process if no device profile is defined
  if [[ -z "$targetDeviceProfile" ]]; then
    echo ""
    echo "SNMP profile not found for $targetDevice"
    echo "Polling will not work without a profile being set"
    echo "Exiting..."
    rm -rd "$timeTmpDir"
    exit 1
  fi

  # Grabs copy of device's assigned profile and saves it to a temp directory
  podman exec "$targetContainerID" /bin/sh -c "cat \$(find /etc/ktranslate -type f -name \"$targetDeviceProfile\")" >> "$timeTmpDir/$targetDeviceProfile"
  profileLocation="$timeTmpDir/$targetDeviceProfile"

  # Gets the `extends` block from the assigned profile - assigns to the $profileExtensions array
  readarray -t profileExtensions < <(cat "$profileLocation" | yq e '.extends | to_entries[] .value')

  # Grabs copies of device's extension profiles and saves them to a temp directory
  for extension in "${profileExtensions[@]}"; do
    podman exec "$targetContainerID" /bin/sh -c "cat \$(find /etc/ktranslate -type f -name \"$extension\")" >> "$timeTmpDir/$extension"
    profileExtensionsLocations+=("$timeTmpDir/$extension")
  done

  # Declares array for storing OIDs to poll
  declare -a selectedOIDs

  # Extract OIDs from a given YAML file
  # Checks if new OID is contained within another discovered OID
  # Prevents long walks (on the beach?) caused by polling whole tables 
  extract_oids() {
    local file="$1"
    local foundOIDs=($(cat "$file" | yq e '.. | select(has("OID")) | .OID' -))
    local filteredOIDs=()

    for unfilteredOID in "${foundOIDs[@]}"; do
    # Only add OID to the filtered list if it is not a substring of any other OID
      isSubOID=false
      for comparisonOID in "${foundOIDs[@]}"; do
        if [[ "$unfilteredOID" != "$comparisonOID" && "$comparisonOID" == *"$unfilteredOID"* ]]; then
          # Checks that the substring is followed by a period, or is an exact match
          if [[ "${comparisonOID:${#unfilteredOID}:1}" == "." || "${#comparisonOID}" == "${#unfilteredOID}" ]]; then
            isSubOID=true
            break
          fi
        fi
      done
      if [ "$isSubOID" = false ]; then
        filteredOIDs+=("$unfilteredOID")
      fi
    done
    echo "${filteredOIDs[@]}"
  }

  # Declaring this higher to capture additional output
  timingOutputFile=./"$targetDevice"_timing_results-$(date +%s).txt

  # Extract OIDs from primary profile
  echo "" | tee -a "$timingOutputFile"
  if [[ -f "$profileLocation" ]]; then
    echo "Grabbing OIDs from assigned profile: $profileLocation" | tee -a "$timingOutputFile"
    selectedOIDs+=($(extract_oids "$profileLocation"))
  fi
  # Extract OIDs from extension profiles
  echo "" | tee -a "$timingOutputFile"
  for profile in "${profileExtensionsLocations[@]}"; do
    if [[ -f "$profile" ]]; then
      echo "Grabbing OIDs from extension profile: $profile" | tee -a "$timingOutputFile"
      selectedOIDs+=($(extract_oids "$profile"))
    fi
  done
  echo "" | tee -a "$timingOutputFile"

  # Retrieves SNMP credentials to determine if it's v1/v2c or v3
  targetDeviceCommString=$(cat "$configPath" | yq e ".devices.\"$targetDevice\".snmp_comm" -)
  targetDeviceV3Creds=$(cat "$configPath" | yq e ".devices.\"$targetDevice\".snmp_v3" -)
  targetDeviceIP=$(cat "$configPath" | yq e ".devices.\"$targetDevice\".device_ip")

  if [[ -n "$targetDeviceCommString" && "$targetDeviceCommString" != "null" ]]; then
    echo "Device $targetDevice is using SNMP v1/v2c"
    startTimeMs=$(date +%s%3N)

    for oid in "${selectedOIDs[@]}"; do
      timestamp=[$(date '+%Y-%m-%d %H:%M:%S,%3N')]
      snmpOutput=$(snmpwalk -v 2c -On -c "$targetDeviceCommString" "$targetDeviceIP" ."$oid")
      # 'Tee' buffers output and slows down loop, skewing results. Double 'echo' statement seems to avoid this issue
      echo "$timestamp $snmpOutput"
      echo "$timestamp $snmpOutput" >> "$timingOutputFile"
    done

    endTimeMs=$(date +%s%3N)
    totalDuration=$(echo "scale=3; ($endTimeMs - $startTimeMs) / 1000" | bc)
    echo "" | tee -a "$timingOutputFile"
    echo "Total time to walk device's assigned profiles: ${totalDuration}s" | tee -a "$timingOutputFile"
    echo ""
    echo "Saved results to $timingOutputFile"

  elif [[ -n "$targetDeviceV3Creds" && "$targetDeviceV3Creds" != "null" ]]; then
    echo ""
    echo "Device $targetDevice is using SNMP v3"
    echo ""
    v3UserName=$(echo "$targetDeviceV3Creds" | yq e '.user_name')
    v3AuthProt=$(echo "$targetDeviceV3Creds" | yq e '.authentication_protocol')
    v3AuthPass=$(echo "$targetDeviceV3Creds" | yq e '.authentication_passphrase')
    v3PrivProt=$(echo "$targetDeviceV3Creds" | yq e '.privacy_protocol')
    v3PrivPass=$(echo "$targetDeviceV3Creds" | yq e '.privacy_passphrase')

    if [[ -n "$v3AuthProt" && "$v3AuthProt" != "null" && -n "$v3PrivProt" && "$v3PrivProt" != "null" ]]; then
      v3Level=authPriv
    elif [[ -n "$v3AuthProt" && "$v3AuthProt" != "null" && ( -z "$v3PrivProt" || "$v3PrivProt" == "null" ) ]]; then
      v3Level=authNoPriv
    elif [[ ( -z "$v3AuthProt" || "$v3AuthProt" == "null" ) && ( -z "$v3PrivProt" || "$v3PrivProt" == "null" ) ]]; then
      v3Level=noAuthNoPriv
    else
      echo "Couldn't determine snmpwalk authentication level. Are 'snmp_v3.authentication_protocol' and 'snmp_v3.privacy_protocol' set for the device?"
      rm -rd "$timeTmpDir"
      exit 1
    fi

    startTimeMs=$(date +%s%3N)

    for oid in "${selectedOIDs[@]}"; do
      timestamp=[$(date '+%Y-%m-%d %H:%M:%S,%3N')]
      snmpOutput=$(snmpwalk -v 3 -l "$v3Level" -u "$v3UserName" -a "$v3AuthProt" -A "$v3AuthPass" -x "$v3PrivProt" -X "$v3PrivPass" -ObentU -Cc "$targetDeviceIP" ."$oid")
      # 'Tee' buffers output and slows down loop, skewing results. Double 'echo' statement seems to avoid this issue
      echo "$timestamp $snmpOutput"
      echo "$timestamp $snmpOutput" >> "$timingOutputFile"
    done

    endTimeMs=$(date +%s%3N)
    totalDuration=$(echo "scale=3; ($endTimeMs - $startTimeMs) / 1000" | bc)
    echo "" | tee -a "$timingOutputFile"
    echo "Total time to walk device's assigned profiles: ${totalDuration}s" | tee -a "$timingOutputFile"
    echo ""
    echo "Saved results to $timingOutputFile"

  else
    echo "SNMP configuration not found for $targetDevice"
    echo "Polling will not work against a device that does not have SNMP credentials configured"
    echo "Check that your device has either '<deviceName>.snmp_comm' or <deviceName>.snmp_v3[]' set"
    echo "Exiting..."
    rm -rd "$timeTmpDir"
    rm "$timingOutputFile"
    rm 
    exit 1
  fi

  rm -rd "$timeTmpDir"
}

baremetalTimeRoutine() {
  configPath=$(grep -- '-snmp' /etc/default/ktranslate.env | awk '{print $2}')
  profileRepository=/etc/ktranslate/profiles
  deviceList=($(cat "$configPath" | yq e ".devices | to_entries[] .key"))

  # Displays menu and allows device selection
  echo "=-=-=-=-=-=-=-=-=-=-="
  for i in "${!deviceList[@]}"; do
    echo "[$i] ${deviceList[i]}"
  done
  echo ""
  echo "[q] Exit npmDiag"
  echo "=-=-=-=-=-=-=-=-=-=-=" 

  # Forces selection to be an integer, or a q to exit
  menuLoopExit=false
  while [[ "$menuLoopExit" == false ]]; do
    echo ""
    echo "Enter the number of the device you want to time"
    read -ep "You can also use 'q' to exit the script > " menuSelection
    if [[ "$menuSelection" =~ ^[0-9]+$ ]]; then
      if [[ "$menuSelection" -ge "${#deviceList[@]}" ]]; then
        echo ""
        echo "Device selection must be an integer shown in the listed options."
        menuLoopExit=false
        unset menuSelection
      else
        targetDevice="${deviceList[$menuSelection]}"
        menuLoopExit=true
      fi
    elif [[ "${menuSelection,,}" = "q" ]]; then
      echo ""
      echo "Exiting..."
      exit 0
    else
      echo ""
      echo "Selection must be an integer, or a 'q' to exit"
    fi
  done

  # Gets the assigned profile for a device
  targetDeviceProfile=$(cat "$configPath" | yq e ".devices.\"$targetDevice\".mib_profile")

  # Skip the OID retrieval process if no device profile is defined
  if [[ -z "$targetDeviceProfile" ]]; then
    echo ""
    echo "SNMP profile not found for $targetDevice"
    echo "Polling will not work without a profile being set"
    echo "Exiting..."
    exit 1
  fi

  # Gets the location of the assigned profile
  profileLocation=$(find "$profileRepository" -type f -name "$targetDeviceProfile")

  # Gets the `extends` block from the assigned profile - assigns to the $profileExtensions array
  readarray -t profileExtensions < <(yq e '.extends | to_entries[] .value' < "$profileLocation")

  # Gets the location of the extension profiles
  declare -a profileExtensionsLocations
  for extension in "${profileExtensions[@]}"; do
    result=$(find "$profileRepository" -type f -name "$extension")
    profileExtensionsLocations+=("$result")
  done

  # Declares array for storing OIDs to poll
  declare -a selectedOIDs

  # Extract OIDs from a given YAML file
  # Checks if new OID is contained within another discovered OID
  # Prevents long walks (on the beach?) caused by polling whole tables 
  extract_oids() {
    local file="$1"
    local foundOIDs=($(cat "$file" | yq e '.. | select(has("OID")) | .OID' -))
    local filteredOIDs=()

    for unfilteredOID in "${foundOIDs[@]}"; do
    # Only add OID to the filtered list if it is not a substring of any other OID
      isSubOID=false
      for comparisonOID in "${foundOIDs[@]}"; do
        if [[ "$unfilteredOID" != "$comparisonOID" && "$comparisonOID" == *"$unfilteredOID"* ]]; then
          # Checks that the substring is followed by a period, or is an exact match
          if [[ "${comparisonOID:${#unfilteredOID}:1}" == "." || "${#comparisonOID}" == "${#unfilteredOID}" ]]; then
            isSubOID=true
            break
          fi
        fi
      done
      if [ "$isSubOID" = false ]; then
        filteredOIDs+=("$unfilteredOID")
      fi
    done
    echo "${filteredOIDs[@]}"
  }

  # Declaring this higher to capture additional output
  timingOutputFile=./"$targetDevice"_timing_results-$(date +%s).txt

  # Extract OIDs from primary profile
  echo "" | tee -a "$timingOutputFile"
  if [[ -f "$profileLocation" ]]; then
    echo "Grabbing OIDs from assigned profile: $profileLocation" | tee -a "$timingOutputFile"
    selectedOIDs+=($(extract_oids "$profileLocation"))
  fi
  # Extract OIDs from extension profiles
  echo "" | tee -a "$timingOutputFile"
  for profile in "${profileExtensionsLocations[@]}"; do
    if [[ -f "$profile" ]]; then
      echo "Grabbing OIDs from extension profile: $profile" | tee -a "$timingOutputFile"
      selectedOIDs+=($(extract_oids "$profile"))
    fi
  done
  echo "" | tee -a "$timingOutputFile"

  # Retrieves SNMP credentials to determine if it's v1/v2c or v3
  targetDeviceCommString=$(cat "$configPath" | yq e ".devices.\"$targetDevice\".snmp_comm" -)
  targetDeviceV3Creds=$(cat "$configPath" | yq e ".devices.\"$targetDevice\".snmp_v3" -)
  targetDeviceIP=$(cat "$configPath" | yq e ".devices.\"$targetDevice\".device_ip")

  if [[ -n "$targetDeviceCommString" && "$targetDeviceCommString" != "null" ]]; then
    echo "Device $targetDevice is using SNMP v1/v2c"
    startTimeMs=$(date +%s%3N)

    for oid in "${selectedOIDs[@]}"; do
      timestamp=[$(date '+%Y-%m-%d %H:%M:%S,%3N')]
      snmpOutput=$(snmpwalk -v 2c -On -c "$targetDeviceCommString" "$targetDeviceIP" ."$oid")
      # 'Tee' buffers output and slows down loop, skewing results. Double 'echo' statement seems to avoid this issue
      echo "$timestamp $snmpOutput"
      echo "$timestamp $snmpOutput" >> "$timingOutputFile"
    done

    endTimeMs=$(date +%s%3N)
    totalDuration=$(echo "scale=3; ($endTimeMs - $startTimeMs) / 1000" | bc)
    echo "" | tee -a "$timingOutputFile"
    echo "Total time to walk device's assigned profiles: ${totalDuration}s" | tee -a "$timingOutputFile"
    echo ""
    echo "Saved results to $timingOutputFile"

  elif [[ -n "$targetDeviceV3Creds" && "$targetDeviceV3Creds" != "null" ]]; then
    echo ""
    echo "Device $targetDevice is using SNMP v3"
    echo ""
    v3UserName=$(echo "$targetDeviceV3Creds" | yq e '.user_name')
    v3AuthProt=$(echo "$targetDeviceV3Creds" | yq e '.authentication_protocol')
    v3AuthPass=$(echo "$targetDeviceV3Creds" | yq e '.authentication_passphrase')
    v3PrivProt=$(echo "$targetDeviceV3Creds" | yq e '.privacy_protocol')
    v3PrivPass=$(echo "$targetDeviceV3Creds" | yq e '.privacy_passphrase')

    if [[ -n "$v3AuthProt" && "$v3AuthProt" != "null" && -n "$v3PrivProt" && "$v3PrivProt" != "null" ]]; then
      v3Level=authPriv
    elif [[ -n "$v3AuthProt" && "$v3AuthProt" != "null" && ( -z "$v3PrivProt" || "$v3PrivProt" == "null" ) ]]; then
      v3Level=authNoPriv
    elif [[ ( -z "$v3AuthProt" || "$v3AuthProt" == "null" ) && ( -z "$v3PrivProt" || "$v3PrivProt" == "null" ) ]]; then
      v3Level=noAuthNoPriv
    else
      echo "Couldn't determine snmpwalk authentication level. Are 'snmp_v3.authentication_protocol' and 'snmp_v3.privacy_protocol' set for the device?"
      rm -rd "$timeTmpDir"
      exit 1
    fi

    startTimeMs=$(date +%s%3N)

    for oid in "${selectedOIDs[@]}"; do
      timestamp=[$(date '+%Y-%m-%d %H:%M:%S,%3N')]
      snmpOutput=$(snmpwalk -v 3 -l "$v3Level" -u "$v3UserName" -a "$v3AuthProt" -A "$v3AuthPass" -x "$v3PrivProt" -X "$v3PrivPass" -ObentU -Cc "$targetDeviceIP" ."$oid")
      # 'Tee' buffers output and slows down loop, skewing results. Double 'echo' statement seems to avoid this issue
      echo "$timestamp $snmpOutput"
      echo "$timestamp $snmpOutput" >> "$timingOutputFile"
    done

    endTimeMs=$(date +%s%3N)
    totalDuration=$(echo "scale=3; ($endTimeMs - $startTimeMs) / 1000" | bc)
    echo "" | tee -a "$timingOutputFile"
    echo "Total time to walk device's assigned profiles: ${totalDuration}s" | tee -a "$timingOutputFile"
    echo ""
    echo "Saved results to $timingOutputFile"

  else
    echo "SNMP configuration not found for $targetDevice"
    echo "Polling will not work against a device that does not have SNMP credentials configured"
    echo "Check that your device has either '<deviceName>.snmp_comm' or <deviceName>.snmp_v3[]' set"
    echo "Exiting..."
    exit 1
  fi
}

###--- WALK FUNCTIONS ---###

dockerWalkRoutine() {
  # Finds container IDs using Ktranslate image. Adds them to `foundContainerIDs` array.
  readarray -t allContainerIDs < <(docker ps -aq)
  for i in "${allContainerIDs[@]}"; do
    if [[ $(docker inspect "$i" | jq -r '.[] | .Config | .User') == 'ktranslate' ]]; then
      ktranslateContainerIDs+=("$i")
    fi
  done

  # Displays menu and allows container selection.
  echo "=-=-=-=-=-=-=-=-=-=-="
  for i in "${!ktranslateContainerIDs[@]}"; do
    echo "[$i] $(docker inspect "${ktranslateContainerIDs[i]}" | jq -r '.[] | .Name' | sed 's/^\///')"
  done
  echo ""
  echo "[q] Exit npmDiag"
  echo "=-=-=-=-=-=-=-=-=-=-="

  # Runs container selection menu for device-level functions
  deviceLevelContainerSelectMenu

  # Creates a temp directory for keeping configs and profiles in
  walkTmpDir="/tmp/npmDiag-tmp-$(date +%s)"
  mkdir -p "$walkTmpDir"
  docker exec -u 0 "$targetContainerID" /bin/sh -c "cat /snmp-base.yaml" >> "$walkTmpDir/snmp-base.yaml"
  configPath="$walkTmpDir/snmp-base.yaml"
  deviceList=($(cat "$configPath" | yq e ".devices | to_entries[] | .key"))

  # Displays menu and allows device selection
  echo ""
  echo "=-=-=-=-=-=-=-=-=-=-="
  for i in "${!deviceList[@]}"; do
    echo "[$i] ${deviceList[i]}"
  done
  echo ""
  echo "[q] Exit npmDiag"
  echo "=-=-=-=-=-=-=-=-=-=-=" 

  # Forces selection to be an integer, or a q to exit
  menuLoopExit=false
  while [[ "$menuLoopExit" == false ]]; do
    echo ""
    echo "Enter the number of the device you want to time"
    read -ep "You can also use 'q' to exit the script > " menuSelection
    if [[ "$menuSelection" =~ ^[0-9]+$ ]]; then
      if [[ "$menuSelection" -ge "${#deviceList[@]}" ]]; then
        echo ""
        echo "Device selection must be an integer shown in the listed options."
        menuLoopExit=false
        unset menuSelection
      else
        targetDevice="${deviceList[$menuSelection]}"
        menuLoopExit=true
      fi
    elif [[ "${menuSelection,,}" = "q" ]]; then
      echo ""
      echo "Exiting..."
      rm -rd "$walkTmpDir"
      exit 0
    else
      echo ""
      echo "Selection must be an integer, or a 'q' to exit"
    fi
  done

  walkOutputFile=./"$targetDevice"_snmpwalk_results-$(date +%s).txt

  # Retrieves SNMP credentials to determine if it's v1/v2c or v3
  targetDeviceCommString=$(cat "$configPath" | yq e ".devices.\"$targetDevice\".snmp_comm" -)
  targetDeviceV3Creds=$(cat "$configPath" | yq e ".devices.\"$targetDevice\".snmp_v3" -)
  targetDeviceIP=$(cat "$configPath" | yq e ".devices.\"$targetDevice\".device_ip")

  if [[ -n "$targetDeviceCommString" && "$targetDeviceCommString" != "null" ]]; then
    echo "Device $targetDevice is using SNMP v1/v2c"
    snmpwalk -v 2c -On -c "$targetDeviceCommString" "$targetDeviceIP" . | tee -a "$walkOutputFile"
    echo ""
    echo "Saved results to $walkOutputFile"

  elif [[ -n "$targetDeviceV3Creds" && "$targetDeviceV3Creds" != "null" ]]; then
    echo ""
    echo "Device $targetDevice is using SNMP v3"
    echo ""
    v3UserName=$(echo "$targetDeviceV3Creds" | yq e '.user_name')
    v3AuthProt=$(echo "$targetDeviceV3Creds" | yq e '.authentication_protocol')
    v3AuthPass=$(echo "$targetDeviceV3Creds" | yq e '.authentication_passphrase')
    v3PrivProt=$(echo "$targetDeviceV3Creds" | yq e '.privacy_protocol')
    v3PrivPass=$(echo "$targetDeviceV3Creds" | yq e '.privacy_passphrase')

    if [[ -n "$v3AuthProt" && "$v3AuthProt" != "null" && -n "$v3PrivProt" && "$v3PrivProt" != "null" ]]; then
      v3Level=authPriv
    elif [[ -n "$v3AuthProt" && "$v3AuthProt" != "null" && ( -z "$v3PrivProt" || "$v3PrivProt" == "null" ) ]]; then
      v3Level=authNoPriv
    elif [[ ( -z "$v3AuthProt" || "$v3AuthProt" == "null" ) && ( -z "$v3PrivProt" || "$v3PrivProt" == "null" ) ]]; then
      v3Level=noAuthNoPriv
    else
      echo "Couldn't determine snmpwalk authentication level. Are 'snmp_v3.authentication_protocol' and 'snmp_v3.privacy_protocol' set for the device?"
      rm -rd "$walkTmpDir"
      exit 1
    fi

    snmpwalk -v 3 -l "$v3Level" -u "$v3UserName" -a "$v3AuthProt" -A "$v3AuthPass" -x "$v3PrivProt" -X "$v3PrivPass" -ObentU -Cc "$targetDeviceIP" . | tee -a "$walkOutputFile"
    echo ""
    echo "Saved results to $walkOutputFile"

  else
    echo ""
    echo "SNMP configuration not found for $targetDevice"
    echo "Polling will not work against a device that does not have SNMP credentials configured"
    echo "Check that your device has either '<deviceName>.snmp_comm' or <deviceName>.snmp_v3[]' set"
    echo "Exiting..."
    rm -rd "$walkTmpDir"
    exit 1
  fi

  rm -rd "$walkTmpDir"
}

podmanWalkRoutine() {
  # Finds container IDs using Ktranslate image. Adds them to `foundContainerIDs` array.
  readarray -t allContainerIDs < <(podman ps -aq)
  for i in "${allContainerIDs[@]}"; do
    if [[ $(podman inspect "$i" | jq -r '.[] | .Config | .User') == 'ktranslate' ]]; then
      ktranslateContainerIDs+=("$i")
    fi
  done

  # Displays menu and allows container selection.
  echo "=-=-=-=-=-=-=-=-=-=-="
  for i in "${!ktranslateContainerIDs[@]}"; do
    echo "[$i] $(podman inspect "${ktranslateContainerIDs[i]}" | jq -r '.[] | .Name')"
  done
  echo ""
  echo "[q] Exit npmDiag"
  echo "=-=-=-=-=-=-=-=-=-=-="

  # Runs container selection menu for device-level functions
  deviceLevelContainerSelectMenu

  # Creates a temp directory for keeping configs and profiles in
  walkTmpDir="/tmp/npmDiag-tmp-$(date +%s)"
  mkdir -p "$walkTmpDir"
  podman exec "$targetContainerID" /bin/sh -c "cat /snmp-base.yaml" >> "$walkTmpDir/snmp-base.yaml"
  configPath="$walkTmpDir/snmp-base.yaml"
  deviceList=($(cat "$configPath" | yq e ".devices | to_entries[] | .key"))

  # Displays menu and allows device selection
  echo ""
  echo "=-=-=-=-=-=-=-=-=-=-="
  for i in "${!deviceList[@]}"; do
    echo "[$i] ${deviceList[i]}"
  done
  echo ""
  echo "[q] Exit npmDiag"
  echo "=-=-=-=-=-=-=-=-=-=-=" 

  # Forces selection to be an integer, or a q to exit
  menuLoopExit=false
  while [[ "$menuLoopExit" == false ]]; do
    echo ""
    echo "Enter the number of the device you want to time"
    read -ep "You can also use 'q' to exit the script > " menuSelection
    if [[ "$menuSelection" =~ ^[0-9]+$ ]]; then
      if [[ "$menuSelection" -ge "${#deviceList[@]}" ]]; then
        echo ""
        echo "Device selection must be an integer shown in the listed options."
        menuLoopExit=false
        unset menuSelection
      else
        targetDevice="${deviceList[$menuSelection]}"
        menuLoopExit=true
      fi
    elif [[ "${menuSelection,,}" = "q" ]]; then
      echo ""
      echo "Exiting..."
      rm -rd "$walkTmpDir"
      exit 0
    else
      echo ""
      echo "Selection must be an integer, or a 'q' to exit"
    fi
  done

  walkOutputFile=./"$targetDevice"_snmpwalk_results-$(date +%s).txt

  # Retrieves SNMP credentials to determine if it's v1/v2c or v3
  targetDeviceCommString=$(cat "$configPath" | yq e ".devices.\"$targetDevice\".snmp_comm" -)
  targetDeviceV3Creds=$(cat "$configPath" | yq e ".devices.\"$targetDevice\".snmp_v3" -)
  targetDeviceIP=$(cat "$configPath" | yq e ".devices.\"$targetDevice\".device_ip")

  if [[ -n "$targetDeviceCommString" && "$targetDeviceCommString" != "null" ]]; then
    echo "Device $targetDevice is using SNMP v1/v2c"
    snmpwalk -v 2c -On -c "$targetDeviceCommString" "$targetDeviceIP" . | tee -a "$walkOutputFile"
    echo ""
    echo "Saved results to $walkOutputFile"

  elif [[ -n "$targetDeviceV3Creds" && "$targetDeviceV3Creds" != "null" ]]; then
    echo ""
    echo "Device $targetDevice is using SNMP v3"
    echo ""
    v3UserName=$(echo "$targetDeviceV3Creds" | yq e '.user_name')
    v3AuthProt=$(echo "$targetDeviceV3Creds" | yq e '.authentication_protocol')
    v3AuthPass=$(echo "$targetDeviceV3Creds" | yq e '.authentication_passphrase')
    v3PrivProt=$(echo "$targetDeviceV3Creds" | yq e '.privacy_protocol')
    v3PrivPass=$(echo "$targetDeviceV3Creds" | yq e '.privacy_passphrase')

    if [[ -n "$v3AuthProt" && "$v3AuthProt" != "null" && -n "$v3PrivProt" && "$v3PrivProt" != "null" ]]; then
      v3Level=authPriv
    elif [[ -n "$v3AuthProt" && "$v3AuthProt" != "null" && ( -z "$v3PrivProt" || "$v3PrivProt" == "null" ) ]]; then
      v3Level=authNoPriv
    elif [[ ( -z "$v3AuthProt" || "$v3AuthProt" == "null" ) && ( -z "$v3PrivProt" || "$v3PrivProt" == "null" ) ]]; then
      v3Level=noAuthNoPriv
    else
      echo "Couldn't determine snmpwalk authentication level. Are 'snmp_v3.authentication_protocol' and 'snmp_v3.privacy_protocol' set for the device?"
      rm -rd "$walkTmpDir"
      exit 1
    fi

    snmpwalk -v 3 -l "$v3Level" -u "$v3UserName" -a "$v3AuthProt" -A "$v3AuthPass" -x "$v3PrivProt" -X "$v3PrivPass" -ObentU -Cc "$targetDeviceIP" . | tee -a "$walkOutputFile"
    echo ""
    echo "Saved results to $walkOutputFile"

  else
    echo ""
    echo "SNMP configuration not found for $targetDevice"
    echo "Polling will not work against a device that does not have SNMP credentials configured"
    echo "Check that your device has either '<deviceName>.snmp_comm' or <deviceName>.snmp_v3[]' set"
    echo "Exiting..."
    rm -rd "$walkTmpDir"
    exit 1
  fi

  rm -rd "$walkTmpDir"
}

baremetalWalkRouting() {
  configPath=$(grep -- '-snmp' /etc/default/ktranslate.env | awk '{print $2}')
  deviceList=($(cat "$configPath" | yq e ".devices | to_entries[] .key"))

  # Displays menu and allows device selection
  echo "=-=-=-=-=-=-=-=-=-=-="
  for i in "${!deviceList[@]}"; do
    echo "[$i] ${deviceList[i]}"
  done
  echo ""
  echo "[q] Exit npmDiag"
  echo "=-=-=-=-=-=-=-=-=-=-=" 

  # Forces selection to be an integer, or a q to exit
  menuLoopExit=false
  while [[ "$menuLoopExit" == false ]]; do
    echo ""
    echo "Enter the number of the device you want to time"
    read -ep "You can also use 'q' to exit the script > " menuSelection
    if [[ "$menuSelection" =~ ^[0-9]+$ ]]; then
      if [[ "$menuSelection" -ge "${#deviceList[@]}" ]]; then
        echo ""
        echo "Device selection must be an integer shown in the listed options."
        menuLoopExit=false
        unset menuSelection
      else
        targetDevice="${deviceList[$menuSelection]}"
        menuLoopExit=true
      fi
    elif [[ "${menuSelection,,}" = "q" ]]; then
      echo ""
      echo "Exiting..."
      exit 0
    else
      echo ""
      echo "Selection must be an integer, or a 'q' to exit"
    fi
  done

  walkOutputFile=./"$targetDevice"_snmpwalk_results-$(date +%s).txt

  # Retrieves SNMP credentials to determine if it's v1/v2c or v3
  targetDeviceCommString=$(cat "$configPath" | yq e ".devices.\"$targetDevice\".snmp_comm" -)
  targetDeviceV3Creds=$(cat "$configPath" | yq e ".devices.\"$targetDevice\".snmp_v3" -)
  targetDeviceIP=$(cat "$configPath" | yq e ".devices.\"$targetDevice\".device_ip")

  if [[ -n "$targetDeviceCommString" && "$targetDeviceCommString" != "null" ]]; then
    echo "Device $targetDevice is using SNMP v1/v2c"
    snmpwalk -v 2c -On -c "$targetDeviceCommString" "$targetDeviceIP" . | tee -a "$walkOutputFile"
    echo ""
    echo "Saved results to $walkOutputFile"

  elif [[ -n "$targetDeviceV3Creds" && "$targetDeviceV3Creds" != "null" ]]; then
    echo ""
    echo "Device $targetDevice is using SNMP v3"
    echo ""
    v3UserName=$(echo "$targetDeviceV3Creds" | yq e '.user_name')
    v3AuthProt=$(echo "$targetDeviceV3Creds" | yq e '.authentication_protocol')
    v3AuthPass=$(echo "$targetDeviceV3Creds" | yq e '.authentication_passphrase')
    v3PrivProt=$(echo "$targetDeviceV3Creds" | yq e '.privacy_protocol')
    v3PrivPass=$(echo "$targetDeviceV3Creds" | yq e '.privacy_passphrase')

    if [[ -n "$v3AuthProt" && "$v3AuthProt" != "null" && -n "$v3PrivProt" && "$v3PrivProt" != "null" ]]; then
      v3Level=authPriv
    elif [[ -n "$v3AuthProt" && "$v3AuthProt" != "null" && ( -z "$v3PrivProt" || "$v3PrivProt" == "null" ) ]]; then
      v3Level=authNoPriv
    elif [[ ( -z "$v3AuthProt" || "$v3AuthProt" == "null" ) && ( -z "$v3PrivProt" || "$v3PrivProt" == "null" ) ]]; then
      v3Level=noAuthNoPriv
    else
      echo "Couldn't determine snmpwalk authentication level. Are 'snmp_v3.authentication_protocol' and 'snmp_v3.privacy_protocol' set for the device?"
      rm -rd "$walkTmpDir"
      exit 1
    fi

    snmpwalk -v 3 -l "$v3Level" -u "$v3UserName" -a "$v3AuthProt" -A "$v3AuthPass" -x "$v3PrivProt" -X "$v3PrivPass" -ObentU -Cc "$targetDeviceIP" . | tee -a "$walkOutputFile"
    echo ""
    echo "Saved results to $walkOutputFile"

  else
    echo ""
    echo "SNMP configuration not found for $targetDevice"
    echo "Polling will not work against a device that does not have SNMP credentials configured"
    echo "Check that your device has either '<deviceName>.snmp_comm' or <deviceName>.snmp_v3[]' set"
    echo "Exiting..."
    exit 1
  fi
}

###--- SCRIPT FLOW ---###

# Checks number of arguments
if [ $# -lt 1 ]; then
    showHelpMenu
    exit 1
fi

# Validates argument passed to script
if [ "$1" != "--collect" ] && [ "$1" != "--time" ] && [ "$1" != "--walk" ] && [ "$1" != "--help" ]; then
    echo "Invalid argument: $1"
    showHelpMenu
    exit 1
fi

# Executes a routine based on passed argument. Skips environmentCheck() if an override is specified 
if ([[ "$1" == "--collect" ]] || [[ "$1" == "--time" ]] || [[ "$1" == "--walk" ]]) && [[ "$2" == "--installMethod" && -n "$3" ]]; then
    envOverride=true
    installMethod="$3"
elif ([[ "$1" == "--collect" ]] || [[ "$1" == "--time" ]] || [[ "$1" == "--walk" ]]) && [[ "$2" == "--installMethod" && -z "$3" ]]; then
    echo "No override environment provided. Use '--installMethod [DOCKER|PODMAN|BAREMETAL]' instead"
    exit 0
else
    environmentCheck
fi

if [ "$1" = "--collect" ]; then
  if [[ "$installMethod" == "BAREMETAL" ]]; then
    rootCheck
    echo ""
    if [[ "$envOverride" == "true" ]]; then
        echo "Environment override specified. Using $installMethod"
    else
        echo "Found /etc/default/ktranslate.env - Assuming $installMethod instance."
    fi
    baremetalCollectPreReqCheck
    baremetalCollectRoutine
    diagZip
    postCollectCleanup
    exit 0
  elif [[ "$installMethod" == "DOCKER" ]]; then
    rootCheck
    echo ""
    if [[ "$envOverride" == "true" ]]; then
        echo "Environment override specified. Using $installMethod"
    else
        echo "Found container running Ktranslate image - Assuming $installMethod instance."
    fi
    containerCollectPreReqCheck
    dockerCollectRoutine
    diagZip
    postCollectCleanup
    exit 0
  elif [[ "$installMethod" == "PODMAN" ]]; then
    echo ""
    if [[ "$envOverride" == "true" ]]; then
        echo "Environment override specified. Using $installMethod"
    else
        echo "Found container running Ktranslate image - Assuming $installMethod instance."
    fi
    containerCollectPreReqCheck
    podmanCollectRoutine
    diagZip
    postCollectCleanup
    exit 0
  elif [[ "$installMethod" == "UNKNOWN" ]]; then
    echo "Was not able to automatically locate a Ktranslate instance"
    exit 0
  else
    echo "Unexpected \$installMethod value caused script to exit"
    exit 1
  fi
elif [[ "$1" = "--time" ]]; then
  if [[ "$installMethod" == "BAREMETAL" ]]; then
    echo ""
    if [[ "$envOverride" == "true" ]]; then
        echo "Environment override specified. Using $installMethod"
    else
        echo "Found /etc/default/ktranslate.env - Assuming $installMethod instance."
    fi
    baremetalTimePreReqCheck
    baremetalTimeRoutine
    exit 0
  elif [[ "$installMethod" == "DOCKER" ]]; then
    echo ""
    if [[ "$envOverride" == "true" ]]; then
        echo "Environment override specified. Using $installMethod"
    else
        echo "Found container running Ktranslate image - Assuming $installMethod instance."
    fi
    containerTimePreReqCheck
    dockerTimeRoutine
    exit 0
  elif [[ "$installMethod" == "PODMAN" ]]; then
    echo ""
    if [[ "$envOverride" == "true" ]]; then
        echo "Environment override specified. Using $installMethod"
    else
        echo "Found container running Ktranslate image - Assuming $installMethod instance."
    fi
    containerTimePreReqCheck
    podmanTimeRoutine
    exit 0
  elif [[ "$installMethod" == "UNKNOWN" ]]; then
    echo "Was not able to automatically locate a Ktranslate instance"
    exit 0
  else
    echo "Unexpected \$installMethod value caused script to exit"
    exit 1
  fi
elif [[ $1 = "--walk" ]]; then
  if [[ "$installMethod" == "BAREMETAL" ]]; then
    echo ""
    if [[ "$envOverride" == "true" ]]; then
        echo "Environment override specified. Using $installMethod"
    else
        echo "Found /etc/default/ktranslate.env - Assuming $installMethod instance."
    fi
    # Using this because the reqs are the same
    baremetalTimePreReqCheck
    baremetalWalkRouting
    exit 0
  elif [[ "$installMethod" == "DOCKER" ]]; then
    echo ""
    if [[ "$envOverride" == "true" ]]; then
        echo "Environment override specified. Using $installMethod"
    else
        echo "Found container running Ktranslate image - Assuming $installMethod instance."
    fi
    # Using this because the reqs are the same
    containerTimePreReqCheck
    dockerWalkRoutine
    exit 0
  elif [[ "$installMethod" == "PODMAN" ]]; then
    echo ""
    if [[ "$envOverride" == "true" ]]; then
        echo "Environment override specified. Using $installMethod"
    else
        echo "Found container running Ktranslate image - Assuming $installMethod instance."
    fi
    # Using this because the reqs are the same
    containerTimePreReqCheck
    podmanWalkRoutine
    exit 0
  elif [[ "$installMethod" == "UNKNOWN" ]]; then
    echo "Was not able to automatically locate a Ktranslate instance"
    exit 0
  else
    echo "Unexpected \$installMethod value caused script to exit"
    exit 1
  fi
else
  showHelpMenu
fi
