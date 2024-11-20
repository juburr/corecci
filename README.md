<div align="center">
  <img align="center" width="320" src="assets/logos/corecci_500px.png" alt="CoreCCI Orb"><br /><br />
  <h1>CoreCCI</h1>
  <i>An unofficial CircleCI orb providing extended core functionality to your CI pipelines.</i><br /><br />
</div>

[![CircleCI Build Status](https://circleci.com/gh/juburr/corecci.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/juburr/corecci) [![CircleCI Orb Version](https://badges.circleci.com/orbs/juburr/corecci.svg)](https://circleci.com/developer/orbs/orb/juburr/corecci) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/juburr/corecci/master/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)


## Features
- **FIPS-compliant checkout command**  
The built-in CircleCI checkout command may fail in certain jobs when FIPS mode is enabled. This occurs because CircleCI deploy keys all use ED25519 by default, which is not FIPS compliant. FIPS mode depends heavily on the underlying host configuration, so this issue primarily affects self-hosted CircleCI servers, particularly in environments maintained to comply with NIST SP 800-171 or DoD CMMC requirements. When using newer container images such as rocky:9 or ubi:9 in these FIPS-enabled environments, the checkout command fails. This does not appear to be an issue on the public cloud version at app.circleci.com. This orb therefore provides a custom checkout command that allows you to use custom ECDSA keys until this issue is resolved by CircleCI.

- **Shallow checkout command**  
Many organizations have enormous git respositories that have built up over the course of more than a decade, to include monorepos that host multiple services or applications. The checkout command for these repositories can often take a ridiculous amount of time. This orb provides a shallow checkout command to pull source code for the current head commit only, with a depth of 1. This allows for extremely fast checkouts when using massive repositories as compared to the built-in checkout command. Development of this feature is still in progress.

- **Persist to S3 command**  
After many years of working with CircleCI, I also observed that the `persist_to_workspace` command could also suck up tons of time, especially to tar and un-tar files. Many companies also persist certain release artifacts to an S3 storage for long-term storage. This orb therefore offers a `persist_to_s3` command as a convenience command. Development of this feature is still in progress.

## Getting Started: Checkout in FIPS Mode

First, generate a FIPS compliant SSH key using `ecdsa-sha2-nistp384`, per NSA guidance in CNSA Suite 2.0.
```bash
ssk-keygen -t ecdsa -b 384 -C github_<repo_name>
```

Next, navigate the project settings for your application within the CircleCI app. On the left hand sidebar, click SSH keys. Under Additional SSH Keys, add a new key for github.com (or your self-hosted GitHub Enterprise Server domain).

Avoid pressing the "Add deploy key" button, as it will automatically generate one using ED25519, which will not work in FIPS mode. This is the reason why we're using the "additional SSH keys" section as a workaround, allowing us to manage the process ourselves.

The app will display the fingerprint of the key you just added. Place this fingerprint in your CircleCI config file as a parameter to the `corecci/checkout_fips` command:

```yaml
  version: 2.1

  orbs:
    corecci: juburr/corecci@0.0.1

  jobs:
    ubi9_fips_job:
      docker:
        - image: registry.access.redhat.com/ubi9/ubi:9.5
      resource_class: small
      steps:
        - corecci/checkout_fips:
            fingerprint: "SHA256:1wS2Fom3QTXyH5G2DS88+II0U9ajqGKOeq1wBA740Fc"

  workflows:
    use-my-orb:
      jobs:
        - corecci/ubi9_fips_job:
            filters:
              tags:
                only: /.*/
```
