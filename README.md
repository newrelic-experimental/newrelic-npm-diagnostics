<a href="https://opensource.newrelic.com/oss-category/#new-relic-experimental"><picture><source media="(prefers-color-scheme: dark)" srcset="https://github.com/newrelic/opensource-website/raw/main/src/images/categories/dark/Experimental.png"><source media="(prefers-color-scheme: light)" srcset="https://github.com/newrelic/opensource-website/raw/main/src/images/categories/Experimental.png"><img alt="New Relic Open Source experimental project banner." src="https://github.com/newrelic/opensource-website/raw/main/src/images/categories/Experimental.png"></picture></a>

# npmDiag

 A script for retrieving configuration files and logs from Network Performance Monitoring containers, or for running `snmpwalk` against a configured device. Outputs a file called `npmDiag-output.zip` with `--collect` mode, or `<deviceName>-snmpwalk.out` with `--walk` mode.

## Installation
 Script requires different packages depending on the use case. Required packages are:
  - `--collect`: [jq](https://packages.ubuntu.com/focal/jq), [zip](https://packages.ubuntu.com/focal/zip)
  - `--walk`: [yq](https://snapcraft.io/yq), [jq](https://packages.ubuntu.com/focal/jq), [snmp](https://packages.ubuntu.com/focal/snmp)
  
_Note: If you're currently running the Docker container on a RHEL or CentOS host, the `jq` package is not available in the base image repositories. You will need to add the Extra Packages for Enterprise Linux repository to your environment with the command below:_

**RHEL7**
```
subscription-manager repos --enable rhel-*-optional-rpms \
                           --enable rhel-*-extras-rpms \
                           --enable rhel-ha-for-rhel-*-server-rpms
yum install https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
```
**CentOS**
```
yum install epel-release
```

Documentation on the process of adding the EPEL repository can be found ([here](https://docs.fedoraproject.org/en-US/epel/)).

No additional installation steps are necessary; Just follow the instructions in [Usage](#usage) to run the script.

## Usage
 1. Download the script with `wget https://raw.githubusercontent.com/newrelic-experimental/newrelic-npm-diagnostics/main/npmDiag.sh`
 2. Use `chmod +x ./npmDiag.sh` to make it executable
 3. Run the script with either `sudo ./npmDiag.sh --collect` or `./npmDiag.sh --walk` depending on what you want to do
     - `--collect`: Collects diagnostic info from containers. Outputs a zip file called `npmDiag-output.zip`
     - `--walk`: Run `snmpwalk` against a device from the config. Outputs `<deviceName>-snmpwalk.out`
 
_Note: `--collect` mode must be run with `sudo` in order to restart Docker containers. Running this mode without `sudo` will throw an error, and the script will exit._

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
