<a href="https://opensource.newrelic.com/oss-category/#new-relic-experimental"><picture><source media="(prefers-color-scheme: dark)" srcset="https://github.com/newrelic/opensource-website/raw/main/src/images/categories/dark/Experimental.png"><source media="(prefers-color-scheme: light)" srcset="https://github.com/newrelic/opensource-website/raw/main/src/images/categories/Experimental.png"><img alt="New Relic Open Source experimental project banner." src="https://github.com/newrelic/opensource-website/raw/main/src/images/categories/Experimental.png"></picture></a>

# npmDiag.sh

 A multi-use script for assisting in troubleshooting Network Performance Monitoring installations. `npmDiag.sh` has three modes for different use-cases:

 - `--collect`: Creates an output file containing your configuration file and logs from Ktranslate. If Ktranslate is installed as a Linux service, the `/etc/ktranslate/profiles` directory is gathered. If Ktranslate is running in a container, only files mounted to the container directly are included. Outputs a file called `npmDiag-output-<date>.zip`.
 
 - `--time`: Uses the `snmp-base.yaml` configuration file to list available devices. The selected device has `snmpwalk` run against it with all OIDs included in it's assigned (and extension) profiles. Outputs the time required to poll the device, as well as a file called `<targetDevice>_timing_results-<date>.txt` in the current directory. Useful if the best timeout setting for a device is unknown.
 
 - `--walk`: Uses the `snmp-base.yaml` configuration file to list available devices. The selected device has `snmpwalk` run against it in order to return _all_ of it's supported OIDs. Outputs a file called `<targetDevice>_snmpwalk_results-<date>.txt`. This process _can_ take a long time depending on how many OIDs the device supports.

## Installation
  The script requires different packages depending on the use-case. Required packages and install commands are below:
  - `--collect`: [jq](https://packages.ubuntu.com/focal/jq), [zip](https://packages.ubuntu.com/focal/zip)

    **Ubuntu:**
    ```
    sudo apt install jq zip -y
    ```
    **RHEL/CentOS:**
    ```
    sudo yum install jq zip -y
    ```
  - `--time`/`--walk`
  : [yq](https://snapcraft.io/yq), [jq](https://packages.ubuntu.com/focal/jq), [snmp](https://packages.ubuntu.com/focal/snmp)

    **Ubuntu:**
    ```
    sudo apt install jq snmp -y; \
      sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq; \
      sudo chmod +x /usr/bin/yq
    
    # OR #
    
    sudo apt install jq snmp -y; sudo snap install yq
    ```
    **RHEL/CentOS:**
    ```
    sudo yum install jq net-snmp-utils -y; \
      sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq; \
      sudo chmod +x /usr/bin/yq

    # OR #

    sudo yum install jq net-snmp-utils -y; sudo snap install yq
    ```

_**Installation Notes:**_
- _If pulling the `yq` dependency from GitHub is not an option, it can be installed using the `snap` package manager on Ubuntu & RHEL/CentOS. It's important to note that the [Go-based `yq` package](https://github.com/mikefarah/yq) is required. Installing the `Python`-based `yq` package will cause the script to fail unexpectedly. When checking the version of `yq` you should see something like this:_
  ```
  user@hostname:~$ yq --version
  yq (https://github.com/mikefarah/yq/) version v#.#.#
  ```
- _If you're currently running the Docker container on RHEL or CentOS, the `jq` and `snap` packages may not be available in the base image's repository list. Documentation on the process of adding the Extra Packages for Enterprise Linux (EPEL) repository can be found ([here](https://docs.fedoraproject.org/en-US/epel/))_


## Usage
 1. Download the script with `wget https://raw.githubusercontent.com/newrelic-experimental/newrelic-npm-diagnostics/main/npmDiag.sh`
 2. Use `chmod +x ./npmDiag.sh` to make it executable
 3. Run the script with `./npmDiag.sh --collect`, `./npmDiag.sh --time`, or `./npmDiag.sh --walk` depending on what you want to do
     - `--collect`: Collects diagnostic info from Ktranslate's container or service. Outputs `npmDiag-output-<date>.zip`

     - `--time`: Run `snmpwalk` against a device from the config using it's assigned profile. Outputs time to complete, as well as `<targetDevice>_timing_results-<date>.txt`
     
     - `--walk`: Run `snmpwalk` against a device from the config using it's assigned profile. Outputs the complete list of OIDs supported by the device, as well as `<targetDevice>_snmpwalk_results-<date>.txt`
 
_**Note:** `--collect` mode must be run with `sudo` if Ktranslate is installed in a Docker container or as a Linux service. Running this mode without `sudo` for either installation will throw an error, and the script will exit._

_**Note:** `npmDiag.sh` will do it's best to automatically determine what installation method you've used. If it's failing to do so, you can include `--installMethod [DOCKER|PODMAN|BAREMETAL]` in the run command to force a method._

## Note on collecting debug-level logs:
By default the Ktranslate container runs with info-level logs being generated. Ktranslate isn't able to update the verbosity of the logs on the fly, so if you want to collect debug-level logs you will need to launch a new container. This can be achieved by doing the following:
1) Find your existing Ktranslate container's short ID with the command `docker ps -a`
2) Stop the container with the command `docker stop <shortID>`
3) Once the container is stopped, you'll need to launch a new container with debug-level logs enabled. This can be done by modifying your container's run command to include `-log_level=debug` in the Ktranslate arguments. For example, you would change your run command from

```
docker run -d --name ktranslate-info-level-container --restart unless-stopped --pull=always -p 162:1620/udp \
-v `pwd`/snmp-base.yaml:/snmp-base.yaml \
-e NEW_RELIC_API_KEY=$LICENSE_KEY \
kentik/ktranslate:v2 \
  -snmp /snmp-base.yaml \
  -nr_account_id=$ACCOUNT_ID \
  -metrics=jchf \
  -tee_logs=true \
  -service_name=debug-level-test \
  -snmp_discovery_on_start=true \
  -snmp_discovery_min=180 \
  nr1.snmp
```
to
```
docker run -d --name ktranslate-debug-level-container --restart unless-stopped --pull=always -p 162:1620/udp \
-v `pwd`/snmp-base.yaml:/snmp-base.yaml \
-e NEW_RELIC_API_KEY=$LICENSE_KEY \
kentik/ktranslate:v2 \
  -snmp /snmp-base.yaml \
  -nr_account_id=$ACCOUNT_ID \
  -metrics=jchf \
  -tee_logs=true \
  -service_name=debug-level-test \
  -snmp_discovery_on_start=true \
  -snmp_discovery_min=180 \
  -log_level=debug \ # <- Debug-level logs are enabled here
  nr1.snmp
```

4) Once the new container is up and running with debug mode enabled, you can target it with the script to collect more-informative logs. This new container can be stopped and deleted once the script is finished running, and the old container can be started up again.


## Planned changes:
N/A

## Support

Requests for support can be filed as an [Issue](https://github.com/newrelic-experimental/newrelic-npm-diagnostics/issues).

## Contributing
We encourage your contributions to improve `npmDiag`! Keep in mind when you submit your pull request, you'll need to sign the CLA via the click-through using CLA-Assistant. You only have to sign the CLA one time per project.
If you have any questions, or to execute our corporate CLA, required if your contribution is on behalf of a company,  please drop us an email at opensource@newrelic.com.

**A note about vulnerabilities**

As noted in our [security policy](../../security/policy), New Relic is committed to the privacy and security of our customers and their data. We believe that providing coordinated disclosure by security researchers and engaging with the security community are important means to achieve our security goals.

If you believe you have found a security vulnerability in this project or any of New Relic's products or websites, we welcome and greatly appreciate you reporting it to New Relic through [HackerOne](https://hackerone.com/newrelic).

## License
`npmDiag` is licensed under the [Apache 2.0](http://apache.org/licenses/LICENSE-2.0.txt) License.
