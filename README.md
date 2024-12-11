<div align="center">
  <img align="center" width="320" src="assets/logos/corecci_500px.png" alt="CoreCCI Orb"><br /><br />
  <h1>CoreCCI</h1>
  <i>An unofficial CircleCI orb providing extended core functionality to your CI pipelines.</i><br /><br />
</div>

[![CircleCI Build Status](https://circleci.com/gh/juburr/corecci.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/juburr/corecci) [![CircleCI Orb Version](https://badges.circleci.com/orbs/juburr/corecci.svg)](https://circleci.com/developer/orbs/orb/juburr/corecci) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/juburr/corecci/master/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)


## Features
- **Enhanced Checkout Command**  
  - **FIPS Support**  
  The built-in CircleCI `checkout` command fails in certain jobs when FIPS mode is enabled. CircleCI generates ED25519 deploy keys by default, which are not FIPS compliant. When using newer container images such as `rockylinux:9` or `ubi:9` in these FIPS-enabled environments, the code checkout fails. This does not appear to be an issue on the public cloud version at app.circleci.com, as FIPS mode depends on the underlying host configuration, which doesn't appear to be enabled on CircleCI servers. The issue will definitely be present in self-hosted CircleCI instances that are running in environments maintained to comply with NIST SP 800-171 or DoD CMMC requirements. This orb therefore provides a custom checkout command that allows you to use custom ECDSA keys until this issue is resolved by CircleCI.

  - **CNSA 2.0 Compliant Encryption**  
  This orb was also built to adhere to the NSA's Commercial National Security Algorithm Suite (CNSA) 2.0, using the cryptographic algorithms recommended for use with SSH by [RFC-9212](https://datatracker.ietf.org/doc/html/rfc9212). One exception allowing `ecdsa-sha2-nistp256` is still present to support GitHub integration, as documented [here](https://github.com/juburr/corecci/blob/ad0091743adec142c7f0fe7e81388e442a28a50f/src/commands/checkout.yml#L35-L44). The goal is for this orb to eventually be fully CNSA-2.0 compliant, or for these feature to be added directly to CircleCI's built-in `checkout` command.

  - **Blazing Fast Shallow Checkouts**  
  Many organizations have enormous git respositories that have built up over the course of more than a decade, to include monorepos that host multiple services or applications. CircleCI's built-in `checkout` command for these repositories can often take a ridiculous amount of time. This orb provides a shallow checkout command to pull source code for the current head commit only, with a depth of 1. This allows for extremely fast checkouts when using massive repositories as compared to the built-in checkout command. For example, one of my repositories saw the duration of code checkouts fall **from ~20-35 seconds to ~2 seconds**.

  - **Easy Submodule Checkouts**  
  The checkout command includes convenience parameters to checkout all submodules, as this is such a common use case. The submodules can also be checked out with a shallow option to improve checkout speeds.

- **Persist to S3 command**  
After many years of working with CircleCI, I also observed that the `persist_to_workspace` command could also suck up tons of time, especially to tar and un-tar files. Many companies also persist certain release artifacts to an S3 storage for long-term storage. This orb therefore offers a `persist_to_s3` command as a convenience command. Development of this feature is still in progress.

## Getting Started: Checkout in FIPS Mode

First, generate a FIPS compliant SSH key using `ecdsa-sha2-nistp384`, per NSA guidance in CNSA Suite 2.0.
```bash
ssh-keygen -t ecdsa -b 384 -C github_<repo_name>
```

In your GitHub repository settings, click Deploy Keys on the left sidebar, and then press the "Add deploy key" button. Paste in your SSH public key. If you didn't change the default output location while running the previous command, you can find it using `cat ~/.ssh/id_ecdsa`. The file contents should begin with `ecdsa-sha2-nistp384`.

Navigate the project settings for your application within the CircleCI app. On the left hand sidebar, click SSH keys. Under Additional SSH Keys, add a new key for github.com (or your self-hosted GitHub Enterprise Server domain).

Avoid pressing the "Add deploy key" button, as it will automatically generate one using ED25519, which will not work in FIPS mode. This is the reason why we're using the "additional SSH keys" section as a workaround, allowing us to manage the process ourselves.

> [!TIP]
> For organizations with multiple repositories who desire a simpler approach, you may be able to add your new SSH key to your GitHub service account for CCI, add read access for the CI account to your repositories, and then inject the key fingerprint organization-wide via use of a context. Additional instructions will be added after this approach is formally tested and verified.

The app will display the fingerprint of the key you just added. Place this fingerprint in your CircleCI config file as a parameter to the `corecci/checkout` command:

```yaml
  version: 2.1

  orbs:
    corecci: juburr/corecci@0.3.0

  jobs:
    ubi9_fips_job:
      docker:
        - image: registry.access.redhat.com/ubi9/ubi:9.5
      resource_class: small
      steps:
        - corecci/checkout:
            depth: "shallow"
            fingerprint: "SHA256:1wS2Fom3QTXyH5G2DS88+II0U9ajqGKOeq1wBA740Fc"
            submodules: "recursive-shallow"

  workflows:
    use-my-orb:
      jobs:
        - corecci/ubi9_fips_job:
            filters:
              tags:
                only: /.*/
```
