[![New Relic Experimental header](https://github.com/newrelic/opensource-website/raw/master/src/images/categories/Experimental.png)](https://opensource.newrelic.com/oss-category/#new-relic-experimental)

# npmDiag

> A script for retrieving Network Performance Monitoring configuration files and logs from your Docker environment. Outputs a file called `npmDiag-output.zip` which can be supplied to New Relic for support.

## Installation

> Script requires the `zip` package ([info here](https://www.linux.org/docs/man1/zip.html)) in order to run correctly. No installation is necessary; Just follow the instructions in [Usage](#usage).

## Usage
> 1. Place `npmDiag.sh` into the same directory as your `snmp-base.yaml` configuration file(s).
> 2. Open a shell session in the same directory as the script
> 3. Run `npmDiag` as root, or with `sudo ./npmDiag` to begin. If this script is not run as root, or with `sudo`, it will automatically exit with an error message.

## Planned changes:
> - Add support for `--walk` argument flag, used to run full `snmpwalk` at the end of diagnostics file collection
>   - Pull needed `snmpwalk` arguments from configuration file
>  - Prompt user for which device to walk, using config file for list of options

## Support

New Relic hosts and moderates an online forum where customers can interact with New Relic employees as well as other customers to get help and share best practices. Like all official New Relic open source projects, there's a related Community topic in the New Relic Explorers Hub. You can find this project's topic/threads here:

>Add the url for the support thread here

## Contributing
We encourage your contributions to improve `npmDiag`! Keep in mind when you submit your pull request, you'll need to sign the CLA via the click-through using CLA-Assistant. You only have to sign the CLA one time per project.
If you have any questions, or to execute our corporate CLA, required if your contribution is on behalf of a company,  please drop us an email at opensource@newrelic.com.

**A note about vulnerabilities**

As noted in our [security policy](../../security/policy), New Relic is committed to the privacy and security of our customers and their data. We believe that providing coordinated disclosure by security researchers and engaging with the security community are important means to achieve our security goals.

If you believe you have found a security vulnerability in this project or any of New Relic's products or websites, we welcome and greatly appreciate you reporting it to New Relic through [HackerOne](https://hackerone.com/newrelic).

## License
`npmDiag` is licensed under the [Apache 2.0](http://apache.org/licenses/LICENSE-2.0.txt) License.
