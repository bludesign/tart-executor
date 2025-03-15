
# tart-executor

`tart-executor` is an app to launch ephemeral virtual machines on demand from Github action jobs using [Tart](https://github.com/cirruslabs/tart).

`tart-router` is an optional app to handle routing Github actions to multiple macOS computers running `tart-executor`.

## 🚀 Getting Started

### Tart

First install Tart if not already installed on all macOS computers running VMs:

```bash
brew install cirruslabs/cli/tart
```

### Tart Executor

Install `tart-executor` on all macOS computers that will run VMs:

```bash
brew tap bludesign/tart
brew install bludesign/tart/tart-executor
```

Create config file in home directory named `tart-executor.yaml`

```yaml
# Host name for metrics and logs (requried)
hostname: server
# Max CPUs to use (requried)
cpuLimit: 10
# Total memory in MB binary used only for metrics endpoint (requried)
totalMemory: 16384
tart:
  # Custom home folder to use for Tart if you use an external drive you will need to allow access when the dialog shows up (optional)
  homeFolder: /Volumes/Files/tart
  # Run VMs in headless mode (optional)
  isHeadless: true
  # Array of OCI registries that use insecure pulls (optional)
  insecureDomains:
    - 10.0.1.100
  # Max VMs to run at a time. This will not work higher then 2 because of Apple's EULA and Virtualization.Framework limit (required)
  numberOfVirtualMachines: 2
  # SSH username and password for Tart's images this is admin for username and password
  ssh:
    username: admin
    password: admin
  # Default CPU count to use per VM recommend setting this to machine CPU count/2. If not set will use jobs label if set or images default (optional)
  defaultCpu: 5
  # Default memory to use per VM. If not set will use jobs label if set or images default (optional)
  defaultMemory: 6144
github:
  # organization or repo (required)
  runnerScope: organization
  # Required for organization runner scope leave out for repo scope
  organizationName: bludesign
  # Required for repo runner scope leave out for organization scope
  ownerName: bludesign
  # Required for repo runner scope leave out for organization scope
  repositoryName: tart
  # Github app ID (required)
  appId: 1234567
  # Path to private key for github app (required)
  privateKey: /Users/server/private-key.pem
runner:
  # Runner label to look for in Github action job labels to create VM (required)
  labels: tartelet
webhook:
  # Port to listen for webhook calls (required)
  port: 3250
  # URL for tart-router no trailing slash only needed if using tart-router
  routerUrl: http://10.0.4.1:3251
```

Run by typing `tart-executor` into terminal.

### Tart Router

Optionally if running VMs on multiple macOS computers install `tart-router` on one computer. Make sure you are aware of the [licensing limits](https://tart.run/licensing/) for Tart. This can be run on a computer that is also running `tart-executor` as long as the webhook port is different or a seperate computer:

```bash
brew tap bludesign/tart
brew install bludesign/tart/tart-router
```

Create config file in home directory named `tart-router.yaml`

```yaml
# Host name for metrics and logs (requried)
hostname: macbook-router
# Runner label to look for in Github action job labels should match the tart-executors (required)
label: tartelet
# Port to listen on for Github webhook calls (required)
port: 3251
# Array of tart-executor hosts to forward Github action jobs to (required)
hosts:
    # Hostname set in config for tart-executor (required)
  - hostname: server-1
    # URL for tart-executor no trailing slash (required)
    url: http://127.0.0.1:3250
    # Priority to send jobs to host (required)
    priority: 0
    # Don't send jobs needing more CPU then this limit (optional)
    cpuLimit: 5
    # Don't send jobs needing more memory then this limit. Memory in MB binary (optional)
    memoryLimit: 8192
  - hostname: server-2
    url: http://10.0.4.2:3250
    priority: 1
  - hostname: server-3
    url: http://10.0.4.3:3250
    priority: 2
```

Run by typing `tart-router` into terminal.

### Github App

`tart-executor` will automatically register the virtual machine as a runner on a GitHub organization or on a specified repository. In order to do this it must be configured with the relevant credentials. Follow the steps below to add the credentials to `tart-executor`. You can reuse the credentials from the GitHub App on all host machines running `tart-executor`.

1. Create a GitHub App on your organization or account. This can be done by under "Developer settings" in your organization's or your personal settings or by following this link when creating the GitHub app on a personal account or the following link when creating the GitHub app on an organization: https://github.com/organizations/{YOUR_ORGANIZATION_NAME}/settings/apps. Remember to change the link to include the name of your organization if needed.
2. When creating the GitHub App, the required permissions depend on whether you are creating the app for an organization or a personal account. 3. 3. Organizations should enable the Organization: `Actions` and `Self-hosted` runners (Read and write) permission and personal accounts should enable the Repository: `Actions`, `Administration` and `Metadata` (Read and write) permissions.
4. Under subscribe to events check `Workflow job`.
5. Set the `Webhook URL` to the URL that is reachable by Github that goes to the webhook server on `tart-executor` or `tart-router` if using the router.
6. After creating the app install the GitHub app on your organization.
7. Select "Generate a private key". `tart-executor` will use this to send authorized requests to the API. The generated key should automatically be downloaded.
8. Transfer the generated private key to your `tart-executor` machines and set the path in the config.


### Brew Service

You can use a brew service to run the executor and router in the background and on startup:

`brew services start tart-executor`

`brew services start tart-router`

### MacOS Local Network Access

The first time a job starts on a host machine you will need to allow local network access when the popup message shows up once you allow this you will probably need to cancel the job, check that Tart has no leftover temporary VMs running `tart list`, and check Github settings to make sure there are no leftover runners. Then restart `tart-executor` and rerun the job. This will probably happen every time you update `tart-executor`.

## 👨‍🔧 How does it work?

For jobs that you want `tart-executor` to handle set the labels on a job as the label you have set in the config for example `tartelet` and then the image that you would like to use for example `ghcr.io/cirruslabs/macos-sequoia-xcode:latest` so in the action config you would have: `runs-on: [tartelet, "ghcr.io/cirruslabs/macos-sequoia-xcode:latest"]` when a new job runs `tart-executor` will get a callback and check if the labels in the job. If the labels contains the label set in config it handles creating a VM for that job. The lifecycle of a GitHub Actions runner managed by `tart-executor` is as follows:

1. `tart-executor` uses Tart to pull a virtual machine which will update the image if needed.
1. `tart-executor` uses Tart to clone a virtual machin to a temporary image.
2. The virtual machine is booted.
3. After the machine is booted, a setup script is being run. The script downloads the newest version of [GitHub's runner application](https://docs.github.com/en/actions/hosting-your-own-runners/adding-self-hosted-runners) and registers the runner on the GitHub organization.
4. The runner listens for a job and executes it.
5. After executing the job, the runner automatically removes itself from the GitHub organization.
6. The virtual machine is shutdown.
7. `tart-executor` uses Tart to delete the temporary virtual machine.

You can also set memory and CPU labels on jobs to override the number of CPUs or memory the VM will have that is created for that job. If you don't set these `tart-executor` will use the default set in the config or if no default is set the amount set on the VM image when it was created. For example:

`runs-on: [tartelet, "ghcr.io/cirruslabs/macos-sequoia-xcode:latest", "memory:24576", "cpu:6"]`

## 🏎 How is the performance?

From the time a job is started to a VM being booted and ready to start that job is around 25 seconds. The performace of the Tart VM depends on the CPUs and memory set for that VM.

## 👩‍💻 How can I contribute?

Pull requests with bugfixes and new features are much appreciated. We are happy to review PRs and merge them once they are ready.

### Linting the Codebase with SwiftLint

We use [SwiftLint](https://github.com/realm/SwiftLint) to ensure uniformity in the code. Install SwiftLint using [Homebrew](https://brew.sh) by running the following command in your terminal.

```bash
brew install swiftlint
```

## 🙏 Acknowledgements

- Forked from [Tartelet](https://github.com/shapehq/tartelet) which has a GUI instead of running from CLI.
- [Tart](https://github.com/cirruslabs/tart) does all the heavy-lifting of creating, cloning, and running virtual machines.
- Tartelet is heavily inspired by [Cilicon](https://github.com/traderepublic/Cilicon).