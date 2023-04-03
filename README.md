<a href="https://opensource.newrelic.com/oss-category/#new-relic-experimental"><picture><source media="(prefers-color-scheme: dark)" srcset="https://github.com/newrelic/opensource-website/raw/main/src/images/categories/dark/Experimental.png"><source media="(prefers-color-scheme: light)" srcset="https://github.com/newrelic/opensource-website/raw/main/src/images/categories/Experimental.png"><img alt="New Relic Open Source experimental project banner." src="https://github.com/newrelic/opensource-website/raw/main/src/images/categories/Experimental.png"></picture></a>

# npmDiag

 A script for retrieving configuration files and logs from Network Performance Monitoring containers, or for running `snmpwalk` against a configured device. Outputs a file called `npmDiag-output.zip` with `--collect` mode, or `<deviceName>-snmpwalk.out` with `--walk` mode.

## Installation
 Script requires different packages depending on the use case. Required packages are:
  - `--collect`: [jq](https://packages.ubuntu.com/focal/jq), [zip](https://packages.ubuntu.com/focal/zip)
  - `--walk`: [yq](https://snapcraft.io/yq), [snmp](https://packages.ubuntu.com/focal/snmp), [jq](https://packages.ubuntu.com/focal/jq)
  
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

Documentation on the process of adding the EPEL repository can be found [(here)](https://docs.fedoraproject.org/en-US/epel/).

No additional installation steps are necessary; Just follow the instructions in [Usage](#usage) to run the script.

## Usage
 1. Download the script with `wget https://raw.githubusercontent.com/newrelic-experimental/newrelic-npm-diagnostics/main/npmDiag.sh`
 2. Use `chmod +x ./npmDiag.sh` to make it executable
 3. Run the script with either `sudo ./npmDiag.sh --collect` or `./npmDiag.sh --walk` depending on what you want to do
     - `--collect`: Collects diagnostic info from containers. Outputs a zip file called `npmDiag-output.zip`
     - `--walk`: Run `snmpwalk` against a device from the config. Outputs `<deviceName>-snmpwalk.out`
 
_Note: `--collect` mode must be run with `sudo` in order to restart Docker containers. Running this mode without `sudo` will throw an error, and the script will exit._

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
