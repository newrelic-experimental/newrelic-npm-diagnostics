#!/usr/bin/env bash

# Checks for root-capabilities so we can grab Docker logs and interact with `/tmp`
if [ "$EUID" -ne 0 ]; then
    echo "Please run this as either root, or with sudo."
    exit 0
fi

# Checks to make sure `zip` is installed
if ! [[ $(command -v zip) ]]; then
    echo "Please install the \`zip\` package to continue."
    exit 0
fi

declare -a containerIDs=()
containerLogCollect() {
    # Find all containers on system that contain "ktranslate" in the name, regardless of container state
    foundContainers=( $(docker ps -a --format '{{.Names}}' | grep "ktranslate") )

    # Display found container options
    echo "=-=-=-=-=-=-=-=-=-=-="
    echo ""
    for i in "${!foundContainers[@]}"; do 
        echo "[$i] ${foundContainers[i]}"
    done
    echo ""
    echo "[-] Enter container name(s) manually"

    exitStatement=false
    while [[ "$exitStatement" == "false" ]]; do
        echo ""
        echo "Enter space-delimited list of containers you want diagnostic data from (0 1 2...)"
        echo "You can also enter a hyphen to chose a container not shown above, or leave"
        read -ep "the selection blank to choose all containers that ARE shown above > " containerOptions
    
        if [[ "$containerOptions" = "-" ]]; then
            echo ""
            echo "Containers currently on host:"
            docker ps -a --format '{{.Names}}'
            echo ""
            read -ep "Enter a space-delimited list of container names to collect logs from > " customContainerTarget
            read -a selectedContainers <<< $customContainerTarget

            # Retrieve full-length container IDs for selected containers
            for i in "${!selectedContainers[@]}"; do
                containerIDs+=( $(docker ps -aqf "name=^${selectedContainers[i]}$" --no-trunc) )
            done
            exitStatement=true

        elif [[ "$containerOptions" =~ ^[0-9]+($|[[:space:]]|[0-9]+){1,}$ ]]; then
            # Read their selection into array
            read -a selectedContainers <<< $containerOptions
            passingValue=true
            for i in "${!selectedContainers[@]}"; do
                if [[ "${selectedContainers[i]}" -ge "${#foundContainers[@]}" ]]; then
                    passingValue=false
                fi
            done
            if [[ "$passingValue" == true ]]; then
                # Retrieve full-length container IDs for selected containers
                for i in "${!selectedContainers[@]}"; do
                    containerIDs+=( $(docker ps -aqf "name=^${foundContainers[${selectedContainers[i]}]}$" --no-trunc) )
                done
                exitStatement=true
            else
                echo ""
                echo "Container selection must include only integers shown in the listed options."
            fi
        elif [[ -z "$containerOptions" ]]; then
            selectedContainers=($(docker ps -a --format '{{.Names}}' | grep "ktranslate"))

            # Retrieve full-length container IDs for selected containers
            for i in "${!selectedContainers[@]}"; do
                containerIDs+=( $(docker ps -aqf "name=^${selectedContainers[i]}$" --no-trunc) )
            done

            exitStatement=true
        else
            echo ""
            echo "Selection must be a space-delimited list of integers, a single hyphen to denote wanting a custom target, or an empty selection to indicate the default choice (all containers with \"ktranslate\" in the name)."
        fi
    done

    # Create a temporary directory for file storage prior to zipping everything up
    rm -rd /tmp/npmDiag > /dev/null 2>&1
    mkdir /tmp/npmDiag

    # Start log-collection loop
    for i in "${!containerIDs[@]}"; do
        echo ""
        echo "=-=-=-=-=-=-=-=-=-=-="
        echo "Restarting $(docker ps -a --format '{{.Names}}' -f "id=${containerIDs[i]}") to generate fresh logs..."

        docker stop ${containerIDs[i]} > /dev/null 2>&1
        rm /var/lib/docker/containers/"${containerIDs[i]}"/"${containerIDs[i]}"-json.log > /dev/null 2>&1
        docker start ${containerIDs[i]} > /dev/null 2>&1

        waitTime=59
        while [ $waitTime -gt -1 ]; do
           echo -ne "Seconds remaining: $waitTime\033[0K\r"
           sleep 1
           : $((waitTime--))
        done

        cp /var/lib/docker/containers/"${containerIDs[i]}"/"${containerIDs[i]}"-json.log /tmp/npmDiag/"$(docker ps -a --format '{{.Names}}' -f "id=${containerIDs[i]}")"-json.log
    done
    echo "Seconds remaining: 0"
    echo "=-=-=-=-=-=-=-=-=-=-="
    echo "Done regenerating log files!"
    echo "=-=-=-=-=-=-=-=-=-=-="
}

yamlFileCollect() {
    # Display found YAML options
    foundYAML=( $(ls | grep '.yaml\|.yml') )

    echo ""
    for i in "${!foundYAML[@]}"; do 
        echo "[$i] ${foundYAML[i]}"
    done
    echo ""
    echo "[-] Enter file name(s) manually"
    echo ""

    # Allow user to specify which YAML files to gather
    exitStatement=false
    while [[ "$exitStatement" == "false" ]]; do
        echo ""
        echo "Enter space-delimited list of YAML files you want to collect (0 1 2...)"
        echo "You can also enter a hyphen to choose files not shown above"
        read -ep "or leave the selection blank to choose config files that are currently in use > " yamlOptions

        if [[ "$yamlOptions" = "-" ]]; then
            echo ""
            echo "Enter a space-delimited list of files to include in the output ZIP file."
            echo "File names without a prepended file path are assumed to be local to the directory this script was run from."
            echo "This prompt supports tab-completion."
            read -ep "> " yamlOptions
            read -a targetFiles <<< $yamlOptions
            for i in "${!targetFiles[@]}"; do
                if [[ -f "${targetFiles[i]}" ]]; then
                    cp "${targetFiles[i]}" /tmp/npmDiag/"$(basename "${targetFiles[i]}")"
                else
                    echo ""
                    echo "${targetFiles[i]} couldn't be found at the path provided."
                fi
            done
            exitStatement=true

        elif [[ "$yamlOptions" =~ ^[0-9]+($|[[:space:]]|[0-9]+){1,}$ ]]; then
            read -a selectedYAML <<< $yamlOptions
            passingValue=true
            for i in "${!selectedYAML[@]}"; do
                if [[ "${selectedYAML[i]}" -ge "${#foundYAML[@]}" ]]; then
                    passingValue=false
                fi
            done
            if [[ "$passingValue" == true ]]; then
                for i in "${!selectedYAML[@]}"; do
                    cp ./"${foundYAML[${selectedYAML[i]}]}" /tmp/npmDiag/"${foundYAML[${selectedYAML[i]}]}"
                done
                exitStatement=true
            else
                echo ""
                echo "YAML selection must include only integers shown in the listed options."
            fi
        elif [[ -z "$yamlOptions" ]]; then

            declare -a targetFiles=()
            for i in "${!containerIDs[@]}"; do
            targetFiles+=( $(docker container inspect "${containerIDs[i]}" --format '{{.Args}}' | grep -oe '[^\/]*\.yaml\|[^\/]*\.yml') )
            done

            declare -a uniqTargetFiles=()
            uniqTargetFiles=( $(echo "${targetFiles[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' ') )

            for i in "${!uniqTargetFiles[@]}"; do
                if [[ -f "${uniqTargetFiles[i]}" ]]; then
                    cp "${uniqTargetFiles[i]}" /tmp/npmDiag/"$(basename "${uniqTargetFiles[i]}")"
                fi
            done
            exitStatement=true
        else
            echo ""
            echo "Selection must be a space-delimited list of integers, or a single hyphen to denote wanting a custom target."
        fi
    done
    echo ""
    echo "Done collecting files to include in output."
    echo 
    echo "Placing npmDiag-output.zip in the current directory."
    echo ""
}

diagZip() {
    zip -qj npmDiag-output /tmp/npmDiag/*
}

postCleanup() {
    rm -rd /tmp/npmDiag > /dev/null 2>&1
}

containerLogCollect
yamlFileCollect
diagZip
postCleanup
